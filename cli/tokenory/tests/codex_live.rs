use serde_json::{json, Value};
use std::{
    fs,
    io::{BufRead, BufReader, Write},
    process::{Command, Stdio},
    sync::mpsc,
    time::{Duration, Instant},
};
use tokenory::{
    collector::{collect_codex_changes, collect_once, persist, DiagnosticCache},
    config::Config,
    db::Database,
    queries::{report, Filter},
};

fn header() -> String {
    format!(
        "{}\n{}\n",
        json!({"timestamp":"2026-11-16T01:00:00Z","type":"session_meta","payload":{"id":"live-session","model_provider":"openai"}}),
        json!({"timestamp":"2026-11-16T01:00:00Z","type":"turn_context","payload":{"model":"gpt-5-codex"}})
    )
}
fn count(total: i64, minute: i32) -> String {
    json!({"timestamp":format!("2026-11-16T01:{minute:02}:00Z"),"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":total,"output_tokens":0,"cached_input_tokens":0,"reasoning_output_tokens":0,"total_tokens":total}}}}).to_string()+"\n"
}

#[tokio::test]
async fn zone_change_only_affects_new_archive_entries() {
    let home = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    let dir = home.path().join(".codex/sessions");
    fs::create_dir_all(&dir).unwrap();
    let path = dir.join("active.jsonl");
    fs::write(&path, header() + &count(100, 1)).unwrap();
    let mut config = Config {
        home_dir: home.path().into(),
        timezone: "Asia/Tokyo".into(),
        ..Default::default()
    };
    let mut db = Database::open(data.path()).unwrap();
    let mut cache = DiagnosticCache::default();
    let first = collect_once(&config, &mut cache).await.unwrap();
    assert_eq!(persist(&mut db, first).unwrap().added, 1);

    config.timezone = "America/Los_Angeles".into();
    let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
    file.write_all(count(125, 2).as_bytes()).unwrap();
    let next = collect_codex_changes(&config, &mut cache, Some(vec![path]))
        .await
        .unwrap();
    let result = persist(&mut db, next).unwrap();
    assert_eq!((result.added, result.updated), (1, 0));
    let report = report(&mut db, &Filter::default()).unwrap();
    let archive: Vec<_> = report.details.iter().map(|row| {
        (row.record.date.as_str(), row.record.timezone.as_deref(), row.record.tokens.input)
    }).collect();
    assert_eq!(archive, [
        ("2026-11-16", Some("Asia/Tokyo"), 100),
        ("2026-11-15", Some("America/Los_Angeles"), 25),
    ]);
}

#[tokio::test]
async fn compaction_usage_agrees_between_changed_file_and_full_scan_ledgers() {
    let home = tempfile::tempdir().unwrap();
    let active_data = tempfile::tempdir().unwrap();
    let full_data = tempfile::tempdir().unwrap();
    let dir = home.path().join(".codex/sessions");
    fs::create_dir_all(&dir).unwrap();
    let path = dir.join("active.jsonl");
    fs::write(&path, header() + &count(100, 1)).unwrap();
    let config = Config {
        home_dir: home.path().into(),
        ..Default::default()
    };
    let mut cache = DiagnosticCache::default();
    let mut active = Database::open(active_data.path()).unwrap();
    persist(
        &mut active,
        collect_once(&config, &mut cache).await.unwrap(),
    )
    .unwrap();

    let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
    let compaction_response = json!({"type":"token_usage_record","payload":{"thread_id":"live-session","turn_id":"compact-turn","response_id":"summary-response","usage":{"input_tokens":40,"cached_input_tokens":20,"output_tokens":10}}});
    let snapshot = json!({"type":"event_msg","timestamp":"2026-11-16T01:03:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100},"last_token_usage":{"input_tokens":0,"output_tokens":0}}}});
    let context =
        json!({"type":"turn_context","payload":{"turn_id":"compact-turn","model":"gpt-5-codex"}});
    for row in [
        &context,
        &compaction_response,
        &json!({"type":"compacted","payload":{"message":"","replacement_history":[]}}),
        &json!({"type":"world_state","payload":{}}),
        &context,
        &json!({"type":"event_msg","payload":{"type":"thread_settings_applied","thread_id":"live-session"}}),
        &snapshot,
        &snapshot,
    ] {
        writeln!(file, "{row}").unwrap();
    }
    file.write_all(count(125, 4).as_bytes()).unwrap();
    let batch = collect_codex_changes(&config, &mut cache, Some(vec![path.clone()]))
        .await
        .unwrap();
    persist(&mut active, batch).unwrap();
    let batch = collect_codex_changes(&config, &mut cache, Some(vec![path]))
        .await
        .unwrap();
    assert_eq!(persist(&mut active, batch).unwrap().changed, 0);

    let mut full = Database::open(full_data.path()).unwrap();
    let batch = collect_once(&config, &mut DiagnosticCache::default())
        .await
        .unwrap();
    persist(&mut full, batch).unwrap();
    let summary = report(&mut active, &Filter::default()).unwrap().summary;
    assert_eq!(summary.tokens, 175);
    assert_eq!(summary.token_breakdown.cache_read, 20);
    assert_eq!(summary.record_count, 3);
    let recorded_usage = |db: &Database| -> Vec<String> {
        db.connection
            .prepare("SELECT body FROM usage_records WHERE source='local' ORDER BY item_key")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .collect::<rusqlite::Result<_>>()
            .unwrap()
    };
    assert_eq!(recorded_usage(&active), recorded_usage(&full));
}

#[tokio::test]
async fn changed_files_preserve_identity_partial_tail_and_confirmed_history() {
    let home = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    let dir = home.path().join(".codex/sessions");
    fs::create_dir_all(&dir).unwrap();
    let path = dir.join("active.jsonl");
    fs::write(&path, header() + &count(100, 1)).unwrap();
    let config = Config {
        home_dir: home.path().into(),
        ..Default::default()
    };
    let mut cache = DiagnosticCache::default();
    let mut db = Database::open(data.path()).unwrap();
    persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    let next = count(150, 2);
    let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
    file.write_all(&next.as_bytes()[..20]).unwrap();
    persist(
        &mut db,
        collect_codex_changes(&config, &mut cache, Some(vec![path.clone()]))
            .await
            .unwrap(),
    )
    .unwrap();
    assert_eq!(
        report(&mut db, &Filter::default()).unwrap().summary.tokens,
        100
    );
    file.write_all(&next.as_bytes()[20..]).unwrap();
    let result = persist(
        &mut db,
        collect_codex_changes(&config, &mut cache, Some(vec![path.clone()]))
            .await
            .unwrap(),
    )
    .unwrap();
    assert_eq!(result.added, 1);
    assert_eq!(
        report(&mut db, &Filter::default()).unwrap().summary.tokens,
        150
    );
    // A copied archive is collected independently: stable event keys still count once.
    let copy = dir.join("copy.jsonl");
    fs::copy(&path, &copy).unwrap();
    persist(
        &mut db,
        collect_codex_changes(&config, &mut cache, Some(vec![copy]))
            .await
            .unwrap(),
    )
    .unwrap();
    assert_eq!(
        report(&mut db, &Filter::default()).unwrap().summary.tokens,
        150
    );
    // Rewriting a file invalidates append state; already confirmed history remains in the ledger.
    fs::write(&path, header() + &count(100, 1)).unwrap();
    persist(
        &mut db,
        collect_codex_changes(&config, &mut cache, Some(vec![path]))
            .await
            .unwrap(),
    )
    .unwrap();
    assert_eq!(
        report(&mut db, &Filter::default()).unwrap().summary.tokens,
        150
    );
}

#[test]
fn worker_watches_new_roots_and_appends_without_waiting_for_periodic_scan() {
    let home = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    Config {
        home_dir: home.path().into(),
        interval_seconds: 86400,
        ..Default::default()
    }
    .save(data.path())
    .unwrap();
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
    let dir = home.path().join(".codex/sessions/new/day");
    fs::create_dir_all(&dir).unwrap();
    let path = dir.join("active.jsonl");
    let start = Instant::now();
    fs::write(&path, header() + &count(100, 1)).unwrap();
    wait_for("event", "todayUsageChanged");
    eprintln!("new Codex root visible in {:?}", start.elapsed());
    let report = |input: &mut std::process::ChildStdin, id: &str| -> i64 {
        writeln!(
            input,
            "{}",
            json!({"version":1,"id":id,"operation":"overview","payload":{}})
        )
        .unwrap();
        input.flush().unwrap();
        wait_for("id", id)["result"]["summary"]["tokens"]
            .as_i64()
            .unwrap()
    };
    assert_eq!(report(&mut input, "first"), 100);
    let next = count(150, 2);
    let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
    file.write_all(&next.as_bytes()[..20]).unwrap();
    file.flush().unwrap();
    std::thread::sleep(Duration::from_millis(1400));
    assert_eq!(report(&mut input, "partial"), 100);
    let start = Instant::now();
    file.write_all(&next.as_bytes()[20..]).unwrap();
    file.flush().unwrap();
    wait_for("event", "todayUsageChanged");
    eprintln!("Codex append visible in {:?}", start.elapsed());
    assert_eq!(report(&mut input, "completed"), 150);
    // Replayed cumulative usage must not be charged twice, including after a full reconciliation.
    file.write_all(next.as_bytes()).unwrap();
    file.flush().unwrap();
    std::thread::sleep(Duration::from_millis(1400));
    assert_eq!(report(&mut input, "duplicate"), 150);
    writeln!(
        input,
        "{}",
        json!({"version":1,"id":"scan","operation":"scan"})
    )
    .unwrap();
    input.flush().unwrap();
    wait_for("event", "scanFinished");
    assert_eq!(report(&mut input, "reconciled"), 150);
    drop(input);
    assert!(child.wait().unwrap().success());
}

#[tokio::test]
async fn changed_headless_capture_does_not_duplicate_existing_rollout() {
    let home = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    let thread = "01a0b007-2e53-70a0-8b1f-04212dd8dd11";
    let sessions = home.path().join(".codex/sessions");
    let captures = home.path().join(".config/tokens/headless/codex");
    fs::create_dir_all(&sessions).unwrap();
    fs::create_dir_all(&captures).unwrap();
    let rollout = sessions.join(format!("rollout-2026-11-16T01-00-00-{thread}.jsonl"));
    fs::write(rollout, format!("{}\n{}\n{}",
        json!({"timestamp":"2026-11-16T01:00:00Z","type":"session_meta","payload":{"id":thread,"source":"exec","originator":"codex_exec"}}),
        json!({"timestamp":"2026-11-16T01:00:00Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}),count(100,1))).unwrap();
    let capture = captures.join("exec.jsonl");
    fs::write(&capture, format!("{}\n{}\n{}\n",
        json!({"type":"thread.started","thread_id":thread}),json!({"type":"turn.started"}),
        json!({"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":0}}))).unwrap();
    let config = Config {
        home_dir: home.path().into(),
        ..Default::default()
    };
    let mut cache = DiagnosticCache::default();
    let mut db = Database::open(data.path()).unwrap();
    persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    assert_eq!(
        report(&mut db, &Filter::default()).unwrap().summary.tokens,
        100
    );
    persist(
        &mut db,
        collect_codex_changes(&config, &mut cache, Some(vec![capture]))
            .await
            .unwrap(),
    )
    .unwrap();
    assert_eq!(
        report(&mut db, &Filter::default()).unwrap().summary.tokens,
        100
    );
}
