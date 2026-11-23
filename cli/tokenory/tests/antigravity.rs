use chrono::TimeZone;
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use std::{
    fs,
    io::{BufRead, BufReader, Write},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::mpsc,
    time::{Duration, Instant},
};
use tokenory::{
    collector::{collect_live_changes, collect_once, persist, DiagnosticCache},
    config::Config,
    db::Database,
    queries::{conversations, report, ConversationQuery, Filter},
    turn_analytics,
};

fn legacy_cache_directory(home: &Path) -> PathBuf {
    tokens_core::ClientId::Antigravity
        .data()
        .resolve_path_with_env_strategy(&home.to_string_lossy(), false)
        .into()
}

fn encode_varint(mut value: u64) -> Vec<u8> {
    let mut out = Vec::new();
    loop {
        let mut byte = (value & 0x7f) as u8;
        value >>= 7;
        if value != 0 {
            byte |= 0x80;
        }
        out.push(byte);
        if value == 0 {
            break;
        }
    }
    out
}

fn enc_varint(field: u64, value: u64) -> Vec<u8> {
    let mut out = encode_varint(field << 3);
    out.extend(encode_varint(value));
    out
}

fn enc_len(field: u64, payload: &[u8]) -> Vec<u8> {
    let mut out = encode_varint((field << 3) | 2);
    out.extend(encode_varint(payload.len() as u64));
    out.extend_from_slice(payload);
    out
}

fn enc_ts(ms: i64) -> Vec<u8> {
    let secs = (ms / 1000) as u64;
    let nanos = ((ms % 1000) * 1_000_000) as u64;
    let mut out = enc_varint(1, secs);
    out.extend(enc_varint(2, nanos));
    out
}

fn build_gen_row(
    model: &str,
    input: u64,
    cache_read: u64,
    output: u64,
    reasoning: u64,
    response_id: &str,
) -> Vec<u8> {
    let mut usage = Vec::new();
    usage.extend(enc_varint(1, 1532)); // internal model enum id (must NOT be added to input)
    usage.extend(enc_varint(2, input));
    usage.extend(enc_varint(3, output + reasoning));
    usage.extend(enc_varint(5, cache_read));
    usage.extend(enc_varint(9, output));
    usage.extend(enc_varint(10, reasoning));
    usage.extend(enc_len(11, response_id.as_bytes()));

    let mut chat_model = Vec::new();
    chat_model.extend(enc_len(4, &usage));
    chat_model.extend(enc_len(19, model.as_bytes()));
    enc_len(1, &chat_model)
}

fn build_trajectory_meta(uri: &str, created_ms: i64) -> Vec<u8> {
    let workspace = enc_len(1, uri.as_bytes());
    let mut blob = Vec::new();
    blob.extend(enc_len(1, &workspace));
    blob.extend(enc_len(2, &enc_ts(created_ms)));
    blob
}

fn build_user_step_meta(created_ms: i64, turn_uuid: &str) -> Vec<u8> {
    let mut meta = Vec::new();
    meta.extend(enc_len(1, &enc_ts(created_ms)));
    meta.extend(enc_varint(3, 4)); // USER_EXPLICIT
    meta.extend(enc_len(12, turn_uuid.as_bytes()));
    meta
}

fn build_planner_step_meta(
    created_ms: i64,
    done_ms: i64,
    turn_uuid: &str,
    response_id: &str,
    gen_idx: u64,
) -> Vec<u8> {
    let mut meta = Vec::new();
    meta.extend(enc_len(1, &enc_ts(created_ms)));
    meta.extend(enc_varint(3, 2)); // MODEL
    meta.extend(enc_len(7, &enc_ts(done_ms)));
    meta.extend(enc_len(8, &enc_ts(done_ms)));
    meta.extend(enc_len(9, &enc_len(11, response_id.as_bytes())));
    meta.extend(enc_varint(11, 1532));
    meta.extend(enc_len(12, turn_uuid.as_bytes()));
    meta.extend(enc_len(20, &enc_varint(3, gen_idx)));
    meta
}

fn build_planner_payload(tool_calls: usize, response_text: Option<&str>) -> Vec<u8> {
    let mut p20 = Vec::new();
    if let Some(text) = response_text {
        p20.extend(enc_len(1, text.as_bytes()));
    }
    for i in 0..tool_calls {
        p20.extend(enc_len(7, format!("tool-{i}").as_bytes()));
    }
    enc_len(20, &p20)
}

fn build_tool_step_meta(start_ms: i64, end_ms: i64, turn_uuid: &str) -> Vec<u8> {
    let mut meta = Vec::new();
    meta.extend(enc_len(1, &enc_ts(start_ms)));
    meta.extend(enc_varint(3, 2)); // MODEL
    meta.extend(enc_len(7, &enc_ts(start_ms)));
    meta.extend(enc_len(8, &enc_ts(end_ms)));
    meta.extend(enc_len(12, turn_uuid.as_bytes()));
    meta
}

fn create_antigravity_db(path: &Path, subagent: bool, wal_mode: bool) -> Connection {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).unwrap();
    }
    let conn = Connection::open(path).unwrap();
    if wal_mode {
        conn.pragma_update(None, "journal_mode", "WAL").unwrap();
    }
    conn.execute_batch(
        "CREATE TABLE gen_metadata (idx integer PRIMARY KEY, data blob, size integer NOT NULL DEFAULT 0);
         CREATE TABLE trajectory_metadata_blob (id text PRIMARY KEY, data blob);
         CREATE TABLE steps (
             idx integer PRIMARY KEY,
             step_type integer NOT NULL DEFAULT 0,
             status integer NOT NULL DEFAULT 0,
             has_subtrajectory numeric NOT NULL DEFAULT false,
             metadata blob,
             step_payload blob
         );
         CREATE TABLE parent_references (idx integer PRIMARY KEY, data blob);",
    )
    .unwrap();
    if subagent {
        conn.execute(
            "INSERT INTO parent_references (idx, data) VALUES (0, X'01')",
            [],
        )
        .unwrap();
    }
    conn
}

#[tokio::test]
async fn discovers_antigravity_app_and_cli_dbs_dedupes_legacy_cache_and_tracks_hourly_titles_and_turns(
) {
    let home = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();

    let t0 = fixture_midmorning();
    let app_db = home
        .path()
        .join(".gemini/antigravity-insiders/conversations/sess-app.db");
    {
        let conn = create_antigravity_db(&app_db, false, false);
        conn.execute(
            "INSERT INTO trajectory_metadata_blob (id, data) VALUES ('main', ?1)",
            params![build_trajectory_meta("file:///Users/dev/tokenory", t0)],
        )
        .unwrap();
        // Turn 1: 2 requests, 2 parallel overlapping tool calls (wait = 2000ms merged)
        conn.execute(
            "INSERT INTO gen_metadata (idx, data) VALUES (0, ?1), (1, ?2)",
            params![
                build_gen_row("gemini-3.5-flash-high", 1000, 0, 120, 80, "resp-a1"),
                build_gen_row("gemini-3.5-flash-high", 200, 1000, 300, 100, "resp-a2"),
            ],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO steps (idx, step_type, status, metadata, step_payload) VALUES
             (0, 14, 3, ?1, NULL),
             (1, 15, 3, ?2, ?3),
             (2, 132, 3, ?4, NULL),
             (3, 132, 3, ?5, NULL),
             (4, 15, 3, ?6, ?7)",
            params![
                build_user_step_meta(t0, "turn-1"),
                build_planner_step_meta(t0 + 100, t0 + 3_000, "turn-1", "resp-a1", 0),
                build_planner_payload(2, None),
                build_tool_step_meta(t0 + 3_000, t0 + 4_500, "turn-1"),
                build_tool_step_meta(t0 + 3_500, t0 + 5_000, "turn-1"),
                build_planner_step_meta(t0 + 5_000, t0 + 10_000, "turn-1", "resp-a2", 1),
                build_planner_payload(0, Some("Done")),
            ],
        )
        .unwrap();
    }

    // Subagent DB: tokens MUST count in usage, turns MUST be excluded from turn analytics
    let sub_db = home
        .path()
        .join(".gemini/antigravity/conversations/sess-sub.db");
    {
        let conn = create_antigravity_db(&sub_db, true, false);
        conn.execute(
            "INSERT INTO gen_metadata (idx, data) VALUES (0, ?1)",
            params![build_gen_row(
                "gemini-3.5-flash-high",
                400,
                0,
                50,
                10,
                "resp-sub"
            )],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO steps (idx, step_type, status, metadata, step_payload) VALUES
             (0, 14, 3, ?1, NULL),
             (1, 15, 3, ?2, ?3)",
            params![
                build_user_step_meta(t0 + 20_000, "sub-turn"),
                build_planner_step_meta(t0 + 20_100, t0 + 22_000, "sub-turn", "resp-sub", 0),
                build_planner_payload(0, Some("Subagent done")),
            ],
        )
        .unwrap();
    }

    // Legacy RPC cache containing a duplicate of `sess-app` AND a unique older session `sess-legacy`
    let legacy_dir = legacy_cache_directory(home.path());
    fs::create_dir_all(&legacy_dir).unwrap();
    fs::write(
        legacy_dir.join("sess-app.jsonl"),
        format!(
            "{}\n",
            json!({"type":"usage","sessionId":"sess-app","modelId":"gemini-3.5-flash-high","timestamp":t0 + 100,"input":1000,"output":120,"cacheRead":0,"cacheWrite":0,"reasoning":80,"responseId":"resp-a1"})
        ),
    )
    .unwrap();
    fs::write(
        legacy_dir.join("sess-legacy.jsonl"),
        format!(
            "{}\n",
            json!({"type":"usage","sessionId":"sess-legacy","modelId":"gemini-3.5-flash-high","timestamp":t0 + 3_600_000,"input":300,"output":50,"cacheRead":0,"cacheWrite":0,"reasoning":0,"responseId":"resp-legacy"})
        ),
    )
    .unwrap();

    // Antigravity CLI DB
    let cli_db = home
        .path()
        .join(".gemini/antigravity-cli/conversations/sess-cli.db");
    {
        let conn = create_antigravity_db(&cli_db, false, false);
        conn.execute(
            "INSERT INTO trajectory_metadata_blob (id, data) VALUES ('main', ?1)",
            params![build_trajectory_meta("file:///Users/dev/cli-proj", t0)],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO gen_metadata (idx, data) VALUES (0, ?1)",
            params![build_gen_row(
                "gemini-3.5-flash-high",
                500,
                0,
                150,
                50,
                "resp-cli"
            )],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO steps (idx, step_type, status, metadata, step_payload) VALUES
             (0, 14, 3, ?1, NULL),
             (1, 15, 3, ?2, ?3)",
            params![
                build_user_step_meta(t0, "cli-turn-1"),
                build_planner_step_meta(t0 + 100, t0 + 4_000, "cli-turn-1", "resp-cli", 0),
                build_planner_payload(0, Some("CLI done")),
            ],
        )
        .unwrap();
    }

    // Insiders keeps conversation titles beside its conversation directory.
    let summaries_db = home
        .path()
        .join(".gemini/antigravity-insiders/conversation_summaries.db");
    {
        let conn = Connection::open(&summaries_db).unwrap();
        conn.execute_batch(
            "CREATE TABLE conversation_summaries (conversation_id text PRIMARY KEY, title text NOT NULL DEFAULT '');",
        )
        .unwrap();
        conn.execute(
            "INSERT INTO conversation_summaries (conversation_id, title) VALUES ('sess-app', '  Antigravity   Live   Monitor  ')",
            [],
        )
        .unwrap();
    }

    let config = Config {
        home_dir: home.path().into(),
        ..Default::default()
    };
    let mut db = Database::open(data.path()).unwrap();
    let batch = collect_once(&config, &mut DiagnosticCache::default())
        .await
        .unwrap();
    persist(&mut db, batch).unwrap();

    // 1. Verify Antigravity App usage:
    //    sess-app: (1000+120+80) + (200+1000+300+100) = 2800 (no #1 1532 overcount, no legacy dup)
    //    sess-sub: 400+50+10 = 460
    //    sess-legacy: 300+50 = 350
    //    Total antigravity = 3610
    let app_report = report(
        &mut db,
        &Filter {
            from: Some("2026-11-21".into()),
            to: Some("2026-11-21".into()),
            client: Some("antigravity".into()),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(app_report.summary.tokens, 3610);
    assert_eq!(app_report.summary.token_breakdown.input, 1900);
    assert_eq!(app_report.summary.token_breakdown.cache_read, 1000);
    assert_eq!(app_report.summary.token_breakdown.output, 520);
    assert_eq!(app_report.summary.token_breakdown.reasoning, 190);
    // Hourly buckets must allocate all 4 event-granularity records (0 unallocated)
    let hourly = app_report.hourly.as_ref().expect("single-day hourly");
    assert_eq!(hourly.unallocated.tokens, 0);
    assert_eq!(hourly.buckets.len(), 2);

    // 2. Verify Antigravity CLI usage: 500 + 150 + 50 = 700
    let cli_report = report(
        &mut db,
        &Filter {
            client: Some("antigravity-cli".into()),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(cli_report.summary.tokens, 700);

    // 3. Verify conversation title search
    let found = conversations(
        &db,
        home.path(),
        ConversationQuery {
            filter: Filter {
                client: Some("antigravity".into()),
                ..Default::default()
            },
            search: "live monitor".into(),
        },
    )
    .unwrap();
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].id.session_id, "sess-app");
    assert_eq!(found[0].title.as_deref(), Some("Antigravity Live Monitor"));

    // 4. Verify Turn Analytics for BOTH antigravity and antigravity-cli
    let turns_json =
        serde_json::to_value(turn_analytics::query(&mut db, &Filter::default()).unwrap()).unwrap();
    let caps = turns_json["capabilities"].as_array().unwrap();
    for id in ["antigravity", "antigravity-cli"] {
        let cap = caps.iter().find(|c| c["client"] == id).unwrap();
        assert_eq!(cap["supported"], true, "{id} must be supported");
    }
    let turns = turns_json["turns"].as_array().unwrap();
    // 1 main app turn + 1 cli turn (subagent excluded!)
    assert_eq!(turns.len(), 2);
    let app_turn = turns.iter().find(|t| t["client"] == "antigravity").unwrap();
    assert_eq!(app_turn["sessionId"], "sess-app");
    assert_eq!(app_turn["turnId"], "turn-1");
    assert_eq!(app_turn["project"], "tokenory");
    assert_eq!(app_turn["durationMs"], 10_000);
    assert_eq!(app_turn["toolWaitMs"], 2_000);
    assert_eq!(app_turn["generatedTokens"], 600); // (120+80) + (300+100)
    assert_eq!(app_turn["reasoningTokens"], 180); // 80 + 100
    assert_eq!(app_turn["requests"], 2);
    assert_eq!(app_turn["toolCalls"], 2);

    let cli_turn = turns
        .iter()
        .find(|t| t["client"] == "antigravity-cli")
        .unwrap();
    assert_eq!(cli_turn["generatedTokens"], 200);
    assert_eq!(cli_turn["toolWaitMs"], 0);
}

#[tokio::test]
async fn live_changes_and_worker_watch_antigravity_insiders_wal_updates_in_real_time() {
    let home = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    let conv_dir = home.path().join(".gemini/antigravity-insiders/conversations");
    fs::create_dir_all(&conv_dir).unwrap();
    Config {
        home_dir: home.path().into(),
        interval_seconds: 86400,
        ..Default::default()
    }
    .save(data.path())
    .unwrap();

    // Unit-level incremental check with WAL sidecar path passed directly
    let t0 = 1_795_226_400_000i64;
    let db_path = conv_dir.join("live-session.db");
    let conn = create_antigravity_db(&db_path, false, true);
    conn.execute(
        "INSERT INTO gen_metadata (idx, data) VALUES (0, ?1)",
        params![build_gen_row(
            "gemini-3.5-flash-high",
            250,
            0,
            50,
            0,
            "resp-live-1"
        )],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO steps (idx, step_type, status, metadata, step_payload) VALUES
         (0, 14, 3, ?1, NULL),
         (1, 15, 3, ?2, ?3)",
        params![
            build_user_step_meta(t0, "live-t1"),
            build_planner_step_meta(t0 + 100, t0 + 2_000, "live-t1", "resp-live-1", 0),
            build_planner_payload(0, Some("First reply")),
        ],
    )
    .unwrap();

    {
        let mut ledger = Database::open(data.path()).unwrap();
        let wal_path = conv_dir.join("live-session.db-wal");
        let batch = collect_live_changes(
            &Config {
                home_dir: home.path().into(),
                ..Default::default()
            },
            &mut DiagnosticCache::default(),
            Some(vec![wal_path]),
        )
        .await
        .unwrap();
        persist(&mut ledger, batch).unwrap();
        assert_eq!(
            report(&mut ledger, &Filter::default())
                .unwrap()
                .summary
                .tokens,
            300
        );
    }

    // End-to-end worker process check: append a second generation into WAL and verify `todayUsageChanged`
    let mut child = Command::new(assert_cmd::cargo::cargo_bin!("tokenory"))
        .args([
            "--data-dir",
            data.path().to_str().unwrap(),
            "worker",
            "--stdio",
        ])
        .env("XDG_CACHE_HOME", data.path().join("cache"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    let output = child.stdout.take().unwrap();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(output).lines() {
            if tx
                .send(serde_json::from_str::<Value>(&line.unwrap()).unwrap())
                .is_err()
            {
                break;
            }
        }
    });
    let wait_for = |field: &str, value: &str| -> Value {
        let deadline = Instant::now() + Duration::from_secs(12);
        loop {
            let message = rx
                .recv_timeout(deadline.saturating_duration_since(Instant::now()))
                .unwrap_or_else(|error| panic!("waiting for {field}={value}: {error}"));
            if message[field] == value {
                return message;
            }
        }
    };
    wait_for("event", "scanFinished");

    // Append a new completed turn while keeping the SQLite connection open (writes to -wal)
    let start = Instant::now();
    conn.execute(
        "INSERT INTO gen_metadata (idx, data) VALUES (1, ?1)",
        params![build_gen_row(
            "gemini-3.5-flash-high",
            100,
            250,
            80,
            20,
            "resp-live-2"
        )],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO steps (idx, step_type, status, metadata, step_payload) VALUES
         (2, 14, 3, ?1, NULL),
         (3, 15, 3, ?2, ?3)",
        params![
            build_user_step_meta(t0 + 10_000, "live-t2"),
            build_planner_step_meta(t0 + 10_100, t0 + 13_000, "live-t2", "resp-live-2", 1),
            build_planner_payload(0, Some("Second reply")),
        ],
    )
    .unwrap();

    wait_for("event", "todayUsageChanged");
    eprintln!("Antigravity WAL update visible in {:?}", start.elapsed());

    writeln!(
        input,
        "{}",
        json!({"version":1,"id":"ov","operation":"overview","payload":{"client":"antigravity"}})
    )
    .unwrap();
    input.flush().unwrap();
    assert_eq!(
        wait_for("id", "ov")["result"]["summary"]["tokens"]
            .as_i64()
            .unwrap(),
        750
    );

    writeln!(
        input,
        "{}",
        json!({"version":1,"id":"ta","operation":"turnAnalytics","payload":{"client":"antigravity"}})
    )
    .unwrap();
    input.flush().unwrap();
    assert_eq!(
        wait_for("id", "ta")["result"]["turns"]
            .as_array()
            .unwrap()
            .len(),
        2
    );

    drop(conn);
    drop(input);
    assert!(child.wait().unwrap().success());
}

const TEST_MODEL: &str = "gemini-3.5-flash-high";

fn fixture_midmorning() -> i64 {
    Config::system_timezone().with_ymd_and_hms(2026, 11, 21, 10, 0, 0)
        .earliest().unwrap().timestamp_millis()
}

struct LedgerFixture {
    _home: tempfile::TempDir,
    _data: tempfile::TempDir,
    config: Config,
    db: Database,
    cache: DiagnosticCache,
}

impl LedgerFixture {
    fn new() -> Self {
        let home = tempfile::tempdir().unwrap();
        let data = tempfile::tempdir().unwrap();
        let config = Config {
            home_dir: home.path().into(),
            ..Default::default()
        };
        let db = Database::open(data.path()).unwrap();
        Self {
            _home: home,
            _data: data,
            config,
            db,
            cache: DiagnosticCache::default(),
        }
    }

    fn legacy(&self, session: &str, rows: &[(&str, i64)]) -> PathBuf {
        let path = legacy_cache_directory(&self.config.home_dir).join(format!("{session}.jsonl"));
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let lines = rows
            .iter()
            .map(|(id, tokens)| {
                json!({
            "type":"usage", "sessionId":session, "modelId":TEST_MODEL, "timestamp":fixture_midmorning(),
            "input":tokens, "responseId":id
        }).to_string()
            })
            .collect::<Vec<_>>()
            .join("\n");
        fs::write(&path, format!("{lines}\n")).unwrap();
        path
    }

    fn sqlite(&self, client: &str, session: &str, rows: &[(&str, i64)]) -> std::path::PathBuf {
        let path = self
            .config
            .home_dir
            .join(".gemini")
            .join(client)
            .join("conversations")
            .join(format!("{session}.db"));
        let conn = create_antigravity_db(&path, false, false);
        conn.execute(
            "INSERT INTO trajectory_metadata_blob(id,data) VALUES ('main',?1)",
            [build_trajectory_meta("file:///test", fixture_midmorning())],
        )
        .unwrap();
        for (idx, (id, input)) in rows.iter().enumerate() {
            conn.execute(
                "INSERT INTO gen_metadata(idx,data) VALUES (?1,?2)",
                params![idx, build_gen_row(TEST_MODEL, *input as u64, 0, 0, 0, id)],
            )
            .unwrap();
        }
        path
    }

    async fn scan(
        &mut self,
        paths: Option<Vec<std::path::PathBuf>>,
    ) -> tokenory::collector::ScanResult {
        let batch = match paths {
            Some(paths) => collect_live_changes(&self.config, &mut self.cache, Some(paths)).await,
            None => collect_once(&self.config, &mut self.cache).await,
        }
        .unwrap();
        persist(&mut self.db, batch).unwrap()
    }

    async fn seed_v011(&mut self, responses: &[(&str, i64)]) {
        let mut batch = collect_once(&self.config, &mut self.cache).await.unwrap();
        // v0.1.11 stored Antigravity RPC requests under session-scoped snapshot keys.
        for r in &mut batch.records {
            let session = r.session_id.as_deref().unwrap();
            let (response, _) = responses
                .iter()
                .find(|(_, input)| *input == r.tokens.input)
                .unwrap();
            r.key = format!(
                "snapshot:{}",
                json!([r.client, session, ["event", response]])
            );
            r.metadata["granularity"] = "sourceRecord".into();
        }
        persist(&mut self.db, batch).unwrap();
    }

    fn tokens(&mut self) -> i64 {
        report(&mut self.db, &Filter::default())
            .unwrap()
            .summary
            .tokens
    }
}

#[tokio::test]
async fn legacy_notification_keeps_sqlite_snapshot_and_unrelated_legacy_sessions() {
    let mut f = LedgerFixture::new();
    f.legacy("older", &[("older", 7)]);
    let cache_path = f.legacy("both", &[("overlap", 250)]);
    let primary = f.sqlite(
        "antigravity",
        "both",
        &[("overlap", 100), ("sqlite-only", 300)],
    );
    f.scan(None).await;
    assert_eq!(f.tokens(), 407);
    f.legacy("both", &[("overlap", 251)]);
    let live = f.scan(Some(vec![cache_path.clone()])).await;
    assert_eq!(f.tokens(), 407);
    assert_eq!(live.changed, 0);
    assert_eq!(f.scan(None).await.changed, 0);

    fs::remove_file(primary).unwrap();
    f.scan(Some(vec![cache_path])).await;
    assert_eq!(
        f.tokens(),
        407,
        "a missing DB keeps its confirmed request history"
    );
}

#[tokio::test]
async fn sqlite_migrates_persisted_rpc_request_across_sessions_once() {
    let mut f = LedgerFixture::new();
    let rpc_rows = [("shared-response", 250), ("older-response", 7)];
    let legacy = f.legacy("rpc-session", &rpc_rows);
    f.seed_v011(&rpc_rows).await;
    assert_eq!(f.tokens(), 257);
    // The legacy file can already be gone by the time the upgrade sees SQLite.
    fs::remove_file(legacy).unwrap();
    let db_path = f.sqlite(
        "antigravity",
        "sqlite-session",
        &[("shared-response", 100), ("db-only", 300)],
    );
    let live = f.scan(Some(vec![db_path])).await;
    assert_eq!(f.tokens(), 407);
    assert_eq!(live.removed, 1);
    assert_eq!(f.scan(None).await.changed, 0);
    let by_session = |f: &mut LedgerFixture, id: &str| {
        f.db.connection
            .query_row(
                "SELECT sum(tokens) FROM usage_records WHERE json_extract(body,'$.sessionId')=?1",
                [id],
                |r| r.get::<_, i64>(0),
            )
            .unwrap()
    };
    assert_eq!(by_session(&mut f, "rpc-session"), 7);
    assert_eq!(by_session(&mut f, "sqlite-session"), 400);
}

#[tokio::test]
async fn granularity_upgrade_preserves_price_until_usage_changes() {
    use tokenory::pricing::{save_snapshot, PriceEntry, PriceSnapshot};
    let mut f = LedgerFixture::new();
    f.legacy("priced", &[("response-250", 250)]);
    let row = collect_once(&f.config, &mut f.cache)
        .await
        .unwrap()
        .records
        .pop()
        .unwrap();
    let prices = |rate: f64| {
        PriceSnapshot::new(vec![PriceEntry {
            schedule: None,
            remote_policy: None,
            model: row.model.clone(),
            provider: row.provider.clone(),
            matched_key: row.model.clone(),
            source: "fixture".into(),
            assumption: "fixed rate".into(),
            explicit_free: false,
            allow_fast: false,
            rates: serde_json::from_value(json!({"input_cost_per_token":rate})).unwrap(),
        }])
    };
    let old_price = save_snapshot(&mut f.db, prices(0.000001)).unwrap();
    f.seed_v011(&[("response-250", 250)]).await;
    let cost = |f: &LedgerFixture| {
        f.db.connection.query_row(
        "SELECT estimated_cost,json_extract(body,'$.priceSnapshotId'),json_extract(body,'$.costBasis') FROM usage_records WHERE source='local'", [],
        |r| Ok((r.get::<_,f64>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?))
    ).unwrap()
    };
    let saved = cost(&f);
    assert_eq!((saved.0, &saved.1), (0.00025, &old_price));
    let active = save_snapshot(&mut f.db, prices(0.000002)).unwrap();
    f.scan(None).await;
    assert_eq!(cost(&f), saved);
    let path = f.legacy("priced", &[("response-250", 500)]);
    f.scan(Some(vec![path])).await;
    let corrected = cost(&f);
    assert_eq!((corrected.0, corrected.1), (0.001, active));
}

#[tokio::test]
async fn hourly_buckets_require_a_request_timestamp_for_app_and_cli() {
    let mut f = LedgerFixture::new();
    let request_start = fixture_midmorning() + 3_600_000;
    for client in ["antigravity", "antigravity-cli"] {
        let path = f.sqlite(
            client,
            "session",
            &[("fallback", 300), ("timed", 100), ("", 20)],
        );
        let conn = Connection::open(path).unwrap();
        conn.execute(
            "INSERT INTO steps(idx,step_type,status,metadata) VALUES (0,15,3,?1),(1,15,3,?2)",
            params![
                build_planner_step_meta(
                    request_start,
                    request_start + 1_000,
                    "turn-1",
                    "timed",
                    1
                ),
                build_planner_step_meta(
                    request_start,
                    request_start + 1_000,
                    "turn-2",
                    "",
                    2
                ),
            ],
        )
        .unwrap();
    }
    f.scan(None).await;
    for client in ["antigravity", "antigravity-cli"] {
        let r = report(
            &mut f.db,
            &Filter {
                client: Some(client.into()),
                from: Some("2026-11-21".into()),
                to: Some("2026-11-21".into()),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(r.summary.tokens, 420);
        let hourly = r.hourly.unwrap();
        assert_eq!(hourly.unallocated.tokens, 300, "{client}");
        assert_eq!(hourly.buckets.len(), 1);
        assert_eq!(hourly.buckets[0].summary.tokens, 120);
    }
}

#[tokio::test]
async fn wal_update_reconciles_same_session_databases_and_preserves_history_on_read_failure() {
    let mut f = LedgerFixture::new();
    let app = f.sqlite("antigravity", "both", &[("first", 100), ("last", 300)]);
    let ide = f.sqlite("antigravity-ide", "both", &[("other", 7)]);
    f.scan(None).await;
    assert_eq!(f.tokens(), 407);

    let conn = Connection::open(&app).unwrap();
    conn.execute(
        "UPDATE gen_metadata SET data=?1 WHERE idx=0",
        [build_gen_row(TEST_MODEL, 110, 0, 0, 0, "first")],
    )
    .unwrap();
    f.scan(Some(vec![app.clone()])).await;
    assert_eq!(f.tokens(), 417);
    assert_eq!(f.scan(None).await.changed, 0);

    // A readable SQLite header and first generation do not prove a complete
    // snapshot: a later generation can fail SQLite's typed row conversion.
    conn.execute(
        "UPDATE gen_metadata SET data='unreadable as a blob' WHERE idx=1",
        [],
    )
    .unwrap();
    let partial = f.scan(Some(vec![ide.clone()])).await;
    assert!(partial
        .sources
        .iter()
        .any(|s| s.client == "antigravity" && s.status == "partial"));
    assert_eq!(f.tokens(), 417);
    assert_eq!(partial.removed, 0);

    conn.execute(
        "UPDATE gen_metadata SET data=?1 WHERE idx=1",
        [build_gen_row(TEST_MODEL, 280, 0, 0, 0, "last")],
    )
    .unwrap();
    f.scan(Some(vec![ide])).await;
    assert_eq!(f.tokens(), 397);
}
