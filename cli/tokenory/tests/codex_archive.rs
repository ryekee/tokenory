use serde_json::{json, Value};
use std::{
    fs,
    path::{Path, PathBuf},
    time::{Duration, SystemTime},
};
use tokenory::{
    codex_turns,
    collector::{collect_codex_changes, collect_once, persist, DiagnosticCache},
    config::Config,
    db::Database,
    queries::{overview, report, Filter},
};

const DAY: &str = "2026-11-21";
const PARENT: &str = "01912345-1234-7abc-8abc-abcdef123450";
const CHILD: &str = "01912345-1234-7abc-8abc-abcdef123451";

fn session_path(home: &Path, name: &str, archived: bool) -> PathBuf {
    let dir = home.join(if archived {
        ".codex/archived_sessions"
    } else {
        ".codex/sessions"
    });
    fs::create_dir_all(&dir).unwrap();
    dir.join(name)
}

fn config(home: &Path) -> Config {
    Config {
        home_dir: home.into(),
        timezone: "UTC".into(),
        ..Default::default()
    }
}

fn jsonl(rows: &[Value]) -> String {
    rows.iter().map(|row| format!("{row}\n")).collect()
}

fn encode(contents: &str) -> Vec<u8> {
    zstd::encode_all(contents.as_bytes(), 3).unwrap()
}

fn modified(path: &Path, seconds: u64) {
    fs::File::options()
        .write(true)
        .open(path)
        .unwrap()
        .set_modified(SystemTime::UNIX_EPOCH + Duration::from_secs(seconds))
        .unwrap();
}

fn meta(id: &str, source: Value, timestamp: &str) -> Value {
    json!({
        "timestamp": timestamp,
        "type": "session_meta",
        "payload": {"id": id, "source": source, "model_provider": "openai", "cwd": "/tmp/project"}
    })
}

fn context() -> Value {
    json!({"type":"turn_context","payload":{"turn_id":"turn-1","model":"gpt-5-codex"}})
}

fn token_count(input: i64, output: i64, timestamp: Option<&str>) -> Value {
    json!({
        "type": "event_msg",
        "timestamp": timestamp,
        "payload": {"type": "token_count", "info": {"total_token_usage": {
            "input_tokens": input, "output_tokens": output, "total_tokens": input + output
        }}}
    })
}

fn completed_rollout(id: &str) -> Vec<u8> {
    let started = format!("{DAY}T09:00:00Z");
    let completed = format!("{DAY}T09:00:10Z");
    encode(&jsonl(&[
        meta(id, json!("cli"), &started),
        json!({"type":"event_msg","timestamp":started,"payload":{"type":"task_started","turn_id":"turn-1"}}),
        context(),
        json!({"type":"event_msg","timestamp":started,"payload":{"type":"user_message","message":"Review archived output"}}),
        json!({"type":"token_usage_record","payload":{"turn_id":"turn-1","response_id":"parent-response","usage":{"output_tokens":20},"turn_token_usage":{"output_tokens":20}}}),
        token_count(100, 20, Some(&completed)),
        json!({"type":"event_msg","timestamp":completed,"payload":{"type":"task_complete","turn_id":"turn-1","duration_ms":10000,"time_to_first_token_ms":200}}),
    ]))
}

#[tokio::test]
async fn compressed_history_merges_later_events_and_keeps_existing_event_identity_and_time() {
    let home = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    let plain = session_path(home.path(), "old.jsonl", false);
    let archive = session_path(home.path(), "old.jsonl.zst", true);
    // No session_meta or event timestamp. Both forms must use the file stem
    // for identity, even though they have different modification dates.
    let first = [context(), token_count(100, 0, None)];
    fs::write(&plain, jsonl(&first)).unwrap();
    modified(&plain, 1_790_000_000);
    let config = config(home.path());
    let mut cache = DiagnosticCache::default();
    let mut db = Database::open(data.path()).unwrap();
    let initial = collect_once(&config, &mut cache).await.unwrap();
    let original = initial.records[0].clone();
    assert_eq!(original.session_id.as_deref(), Some("old"));
    persist(&mut db, initial).unwrap();

    let mut longer = Vec::from(first);
    longer.push(token_count(150, 0, Some("2026-11-21T09:00:00Z")));
    fs::write(&archive, encode(&jsonl(&longer))).unwrap();
    modified(&archive, 1_795_000_000);
    fs::write(archive.with_extension("zst.tmp"), b"temporary").unwrap();
    let report_before = collect_once(&config, &mut cache).await.unwrap();
    assert_eq!(report_before.records.len(), 2);
    let duplicate = report_before
        .records
        .iter()
        .find(|r| r.key == original.key)
        .unwrap();
    assert_eq!(duplicate.timestamp_ms, original.timestamp_ms);
    assert_eq!(persist(&mut db, report_before).unwrap().added, 1);

    fs::remove_file(plain).unwrap();
    let archive_change = collect_codex_changes(&config, &mut cache, Some(vec![archive]))
        .await
        .unwrap();
    assert_eq!(archive_change.records.len(), 2);
    let unchanged = persist(&mut db, archive_change).unwrap();
    assert_eq!(unchanged.changed, 0);
    let ledger = report(&mut db, &Filter::default()).unwrap();
    assert_eq!(ledger.summary.tokens, 150);
    assert!(ledger
        .details
        .iter()
        .any(|detail| detail.record.key == original.key
            && detail.record.timestamp_ms == original.timestamp_ms));
}

#[tokio::test]
async fn compressed_codex_history_drives_turns_and_subagent_attribution() {
    let home = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    let started = format!("{DAY}T09:00:00Z");
    let completed = format!("{DAY}T09:00:10Z");
    let parent = session_path(
        home.path(),
        &format!("rollout-{DAY}T09-00-00-{PARENT}.jsonl.zst"),
        true,
    );
    fs::write(parent, completed_rollout(PARENT)).unwrap();
    let child = session_path(
        home.path(),
        &format!("rollout-{DAY}T09-00-00-{CHILD}.jsonl.zst"),
        true,
    );
    fs::write(
        &child,
        encode(&jsonl(&[
            meta(
                CHILD,
                json!({"subagent":{"thread_spawn":{
                    "parent_thread_id": PARENT, "depth": 1, "agent_nickname": "Worker"
                }}}),
                &started,
            ),
            context(),
            token_count(30, 5, Some(&completed)),
        ])),
    )
    .unwrap();
    let config = config(home.path());
    let mut cache = DiagnosticCache::default();
    let mut db = Database::open(data.path()).unwrap();
    persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    let turns = codex_turns::query(&mut db, &Filter::default())
        .unwrap()
        .turns;
    assert_eq!(turns.len(), 1);
    assert_eq!(
        (turns[0].session_id.as_str(), turns[0].generated_tokens),
        (PARENT, 20)
    );
    let ledger = overview(&mut db, &Filter::default(), home.path()).unwrap();
    assert_eq!(ledger.summary.tokens, 155);
    let subagents = ledger.codex_subagents.unwrap();
    assert_eq!((subagents.starts, subagents.tokens), (1, 35));
    assert_eq!(subagents.conversations[0].main_turns, Some(1));
}

#[tokio::test]
async fn compressed_codex_rollout_keeps_openclaw_ownership_in_usage_and_turns() {
    let home = tempfile::tempdir().unwrap();
    let archive_dir = home
        .path()
        .join(".openclaw/agents/main/agent/codex-home/archived_sessions");
    fs::create_dir_all(&archive_dir).unwrap();
    fs::write(
        archive_dir.join(format!("rollout-{DAY}T09-00-00-{PARENT}.jsonl.zst")),
        completed_rollout(PARENT),
    )
    .unwrap();
    let scan = collect_once(&config(home.path()), &mut DiagnosticCache::default())
        .await
        .unwrap();
    assert_eq!(scan.records.len(), 1);
    assert_eq!(scan.records[0].client, "openclaw");
    assert_eq!(scan.records[0].tokens.checked_total().unwrap(), 120);
    assert_eq!(scan.codex_turns.len(), 1);
    assert_eq!(scan.codex_turns[0].client, "openclaw");
    assert_eq!(scan.codex_turns[0].generated_tokens, 20);
}

#[tokio::test]
async fn corrupt_archive_preserves_previous_history_without_blocking_other_rollouts() {
    let home = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    let archive = session_path(home.path(), "older.jsonl.zst", true);
    let initial = jsonl(&[context(), token_count(100, 0, Some("2026-11-20T09:00:00Z"))]);
    fs::write(&archive, encode(&initial)).unwrap();
    let config = config(home.path());
    let mut cache = DiagnosticCache::default();
    let mut db = Database::open(data.path()).unwrap();
    persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();

    // The first compressed frame is valid and reports newly increased usage.
    // The second is incomplete, so neither frame can replace or grow history.
    let mut broken = encode(&jsonl(&[
        context(),
        token_count(300, 0, Some("2026-11-21T09:00:00Z")),
    ]));
    let truncated = encode(&jsonl(&[token_count(400, 0, Some("2026-11-21T09:01:00Z"))]));
    broken.extend_from_slice(&truncated[..truncated.len() - 4]);
    fs::write(&archive, broken).unwrap();
    let healthy = session_path(home.path(), "other.jsonl.zst", true);
    fs::write(
        &healthy,
        encode(&jsonl(&[
            context(),
            token_count(25, 0, Some("2026-11-21T09:00:00Z")),
        ])),
    )
    .unwrap();

    let scan = collect_once(&config, &mut cache).await.unwrap();
    let source = scan
        .result
        .sources
        .iter()
        .find(|s| s.client == "codex")
        .unwrap();
    assert_eq!(source.status, "partial");
    assert!(source
        .errors
        .iter()
        .any(|error| error.contains("older.jsonl.zst")));
    assert_eq!(scan.records.len(), 1);
    assert_eq!(persist(&mut db, scan).unwrap().added, 1);
    assert_eq!(
        report(&mut db, &Filter::default()).unwrap().summary.tokens,
        125
    );
}

#[tokio::test]
async fn corrupt_archive_cannot_shadow_a_headless_capture() {
    let home = tempfile::tempdir().unwrap();
    let archive = session_path(
        home.path(),
        &format!("rollout-{DAY}T09-00-00-{PARENT}.jsonl.zst"),
        true,
    );
    fs::write(&archive, b"invalid archive").unwrap();
    let capture = home.path().join(".config/tokens/headless/codex/exec.jsonl");
    fs::create_dir_all(capture.parent().unwrap()).unwrap();
    fs::write(
        capture,
        jsonl(&[
            json!({"type":"thread.started","thread_id":PARENT}),
            json!({"type":"turn.completed","model":"gpt-5-codex","usage":{"input_tokens":65,"output_tokens":0}}),
        ]),
    )
    .unwrap();
    let mut cache = DiagnosticCache::default();
    let scan = collect_once(&config(home.path()), &mut cache)
        .await
        .unwrap();
    assert_eq!(scan.records.len(), 1);
    assert_eq!(scan.records[0].session_id.as_deref(), Some(PARENT));
    assert_eq!(scan.records[0].tokens.input, 65);
}
