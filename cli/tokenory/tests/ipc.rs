// [INPUT]: 临时账本、配置和真正的 worker 进程。
// [OUTPUT]: 校验普通请求、错误、退出、进程锁和完整多帧快照。
// [POS]: Rust worker 的进程级 IPC 回归。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
use serde_json::{json, Value};
use std::{
    io::{BufRead, BufReader, Write},
    process::{Command, Stdio},
    sync::mpsc,
    time::Duration,
};
use tokenory::{
    db::{put_record, Database},
    usage::UsageRecord,
};

#[test]
#[cfg(target_os = "macos")]
fn manual_scan_waits_for_running_incremental_collection() {
    let data = tempfile::tempdir().unwrap();
    let home = tempfile::tempdir().unwrap();
    let sessions = home.path().join(".codex/sessions");
    std::fs::create_dir_all(&sessions).unwrap();
    tokenory::config::Config {
        home_dir: home.path().into(),
        interval_seconds: 86400,
        ..Default::default()
    }.save(data.path()).unwrap();
    let mut child = Command::new(assert_cmd::cargo::cargo_bin!("tokenory"))
        .args(["--data-dir", data.path().to_str().unwrap(), "worker", "--stdio"])
        .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::inherit())
        .spawn().unwrap();
    let mut input = child.stdin.take().unwrap();
    let output = child.stdout.take().unwrap();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(output).lines() {
            if tx.send(serde_json::from_str::<Value>(&line.unwrap()).unwrap()).is_err() { break; }
        }
    });
    let deadline = std::time::Instant::now() + Duration::from_secs(40);
    let receive = || rx.recv_timeout(deadline.saturating_duration_since(std::time::Instant::now())).expect("worker response timeout");
    while receive()["event"] != "scanFinished" {}

    // A large changed rollout keeps the incremental scan in flight long enough
    // to send the manual request while it runs.
    let path = sessions.join("rollout-live.jsonl");
    let mut file = std::fs::File::create(&path).unwrap();
    let line = format!("{}\n", " ".repeat(4095));
    for _ in 0..16_384 { file.write_all(line.as_bytes()).unwrap(); }
    drop(file);
    let mut in_live_scan = false;
    while std::time::Instant::now() < deadline {
        writeln!(input, "{}", json!({"version":1,"id":"status","operation":"status"})).unwrap();
        input.flush().unwrap();
        loop {
            let message = receive();
            if message["id"] == "status" {
                in_live_scan = message["result"]["scanning"] == true;
                break;
            }
        }
        if in_live_scan { break; }
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(in_live_scan, "fixture must enter an incremental scan");
    writeln!(input, "{}", json!({"version":1,"id":"scan","operation":"scan"})).unwrap();
    input.flush().unwrap();
    let mut replied = false;
    let mut started = false;
    let mut completed = false;
    while !completed {
        let message = receive();
        if message["id"] == "scan" {
            assert_eq!(message["result"]["started"], false, "manual request must arrive during the incremental scan");
            assert_eq!(message["result"]["queued"], true);
            replied = true;
        }
        if message["event"] == "scanStarted" { started = true; }
        if message["event"] == "scanFinished" { completed = true; }
    }
    assert!(replied, "manual request must receive a reply");
    assert!(started, "queued manual scan must publish scanStarted");
    drop(input);
    assert!(child.wait().unwrap().success());
}

#[test]
fn worker_streams_a_complete_snapshot_and_stays_available() {
    let data = tempfile::tempdir().unwrap();
    let home = tempfile::tempdir().unwrap();
    tokenory::config::Config {
        home_dir: home.path().into(),
        ..Default::default()
    }
    .save(data.path())
    .unwrap();
    let model = format!("model\"{}\\end", "程".repeat(400_000));
    {
        let db = Database::open(data.path()).unwrap();
        let record: UsageRecord = serde_json::from_value(json!({
            "key":"private-row", "client":"codex", "provider":"test", "model":model,
            "date":"2026-11-06", "tokens":{"input":7,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0}
        }))
        .unwrap();
        put_record(&db.connection, "local", "", &record).unwrap();
        db.connection
            .execute(
                "INSERT INTO coverage_choices VALUES ('2026-11-06','codex','local','')",
                [],
            )
            .unwrap();
    }
    let mut input = Vec::new();
    for (id, operation, payload) in [
        ("snapshot", "deviceUsageSnapshot", json!({"stream":true})),
        ("status", "status", json!({})),
    ] {
        writeln!(
            input,
            "{}",
            json!({"version":1,"id":id,"operation":operation,"payload":payload})
        )
        .unwrap();
    }
    let response = assert_cmd::Command::new(assert_cmd::cargo::cargo_bin!("tokenory"))
        .args([
            "--data-dir",
            data.path().to_str().unwrap(),
            "worker",
            "--stdio",
        ])
        .write_stdin(input)
        .timeout(Duration::from_secs(15))
        .assert()
        .success();
    let mut assembled = String::new();
    let mut chunks = 0;
    let mut completed = false;
    let mut worker_still_available = false;
    for line in BufReader::new(response.get_output().stdout.as_slice()).lines() {
        let line = line.unwrap();
        assert!(line.len() < 64 * 1024 * 1024);
        let message: Value = serde_json::from_str(&line).unwrap();
        match message["id"].as_str() {
            Some("snapshot") if message["snapshotChunk"].is_object() => {
                assert!(!completed, "received a chunk after completion");
                assert_eq!(message["snapshotChunk"]["index"], chunks);
                assembled.push_str(message["snapshotChunk"]["json"].as_str().unwrap());
                chunks += 1;
            }
            Some("snapshot") => {
                assert!(chunks > 1, "the fixture must span several worker messages");
                assert_eq!(message["result"]["chunks"], chunks);
                completed = true;
            }
            Some("status") => worker_still_available = message["result"].is_object(),
            _ => {}
        }
    }
    assert!(completed);
    let snapshot: Value = serde_json::from_str(&assembled).unwrap();
    assert_eq!(snapshot["buckets"].as_array().unwrap().len(), 1);
    assert_eq!(
        snapshot["buckets"][0]["model"].as_str(),
        Some(model.as_str())
    );
    assert_eq!(snapshot["buckets"][0]["summary"]["tokens"], 7);
    assert!(worker_still_available);
}

#[test]
fn worker_queries_errors_writer_lock_and_eof_are_real_process_behaviors() {
    let data = tempfile::tempdir().unwrap();
    let home = tempfile::tempdir().unwrap();
    let codex = home.path().join(".codex");
    let thread = "01912345-1234-7abc-8abc-abcdef123456";
    std::fs::create_dir(&codex).unwrap();
    std::fs::write(
        codex.join("session_index.jsonl"),
        json!({"id": thread, "thread_name": "Review usage filters"}).to_string(),
    )
    .unwrap();
    let config = tokenory::config::Config {
        home_dir: home.path().into(),
        ..Default::default()
    };
    config.save(data.path()).unwrap();
    let exe = assert_cmd::cargo::cargo_bin!("tokenory");
    let mut child = Command::new(exe)
        .args([
            "--data-dir",
            data.path().to_str().unwrap(),
            "worker",
            "--stdio",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    let output = child.stdout.take().unwrap();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(output).lines() {
            tx.send(line.unwrap()).ok();
        }
    });
    let request =
        |input: &mut std::process::ChildStdin, id: &str, operation: &str, payload: Value| {
            writeln!(
                input,
                "{}",
                json!({"version":1,"id":id,"operation":operation,"payload":payload})
            )
            .unwrap();
            input.flush().unwrap();
        };
    let response = |id: &str| -> Value {
        loop {
            let s = rx
                .recv_timeout(Duration::from_secs(10))
                .expect("worker response timeout");
            let v: Value = serde_json::from_str(&s).expect("stdout must only contain JSON lines");
            if v["id"] == id {
                return v;
            }
        }
    };
    request(&mut input, "report", "overview", json!({}));
    let v = response("report");
    assert_eq!(v["result"]["summary"]["tokens"], 0);
    request(&mut input, "usage", "dailySourceUsage", json!({}));
    assert_eq!(response("usage")["result"], json!([]));
    request(&mut input, "defaults", "defaultScanPaths", json!({}));
    let defaults = response("defaults");
    let codex_roots = defaults["result"]["codex"].as_array().unwrap();
    assert!(codex_roots.contains(&json!(home.path().join(".codex/sessions"))));
    let mut duplicate = config.clone();
    duplicate.extra_scan_paths.insert("codex".into(), vec![home.path().join(".codex/sessions")]);
    request(&mut input, "duplicate", "updateSettings", serde_json::to_value(duplicate).unwrap());
    assert!(response("duplicate")["error"].is_object());
    request(&mut input, "unchanged", "settings", json!({}));
    assert_eq!(response("unchanged")["result"]["extraScanPaths"], json!({}));
    let mut valid = config.clone();
    valid.extra_scan_paths.insert("codex".into(), vec![home.path().join("extra-sessions")]);
    request(&mut input, "savePaths", "updateSettings", serde_json::to_value(&valid).unwrap());
    assert!(response("savePaths")["error"].is_null());
    assert_eq!(tokenory::config::Config::load(data.path()).unwrap().extra_scan_paths, valid.extra_scan_paths);
    request(&mut input, "snapshot", "deviceUsageSnapshot", json!({}));
    let snapshot = response("snapshot");
    assert_eq!(snapshot["result"]["schemaVersion"], 1);
    assert_eq!(snapshot["result"]["timezone"], "Asia/Shanghai");
    assert_eq!(snapshot["result"]["buckets"], json!([]));
    assert_eq!(snapshot["result"]["subagentStarts"], json!([]));
    request(&mut input, "bad", "overview", json!({"from":"2026-02-30"}));
    assert!(response("bad")["error"].is_object());
    request(&mut input, "turns", "codexTurns", json!({"from":"2026-11-14","to":"2026-11-14"}));
    let turns = response("turns");
    assert_eq!(turns["result"]["turns"], json!([]));
    assert_eq!(turns["result"]["models"], json!([]));
    request(&mut input, "badTurns", "codexTurns", json!({"from":"2026-02-30"}));
    assert!(response("badTurns")["error"].is_object());
    request(&mut input, "turnAnalytics", "turnAnalytics", json!({}));
    let turns = response("turnAnalytics");
    assert_eq!(turns["result"]["clients"], json!([]));
    assert!(turns["result"]["capabilities"].is_array());
    let rollout = format!("rollout-2026-11-14T08-00-00-{thread}");
    for (client, session, title) in [
        ("codex", thread, Some("Review usage filters")),
        ("codex", rollout.as_str(), Some("Review usage filters")),
        ("claude", thread, None),
        ("codex", "untitled", None),
    ] {
        request(&mut input, "title", "conversationTitle", json!({"client": client, "sessionId": session}));
        assert_eq!(response("title")["result"], json!({"title": title}));
    }
    request(&mut input, "unknown", "invented", json!({}));
    assert_eq!(response("unknown")["error"]["code"], "invalidRequest");
    request(&mut input, "status", "status", json!({}));
    assert!(response("status")["result"].is_object());
    let other = Command::new(exe)
        .args(["--data-dir", data.path().to_str().unwrap(), "scan"])
        .output()
        .unwrap();
    assert!(!other.status.success());
    assert!(String::from_utf8_lossy(&other.stderr).contains("already running"));
    drop(input);
    let deadline = std::time::Instant::now() + Duration::from_secs(4);
    loop {
        if child.try_wait().unwrap().is_some() {
            break;
        }
        if std::time::Instant::now() > deadline {
            child.kill().unwrap();
            panic!("worker must exit on parent EOF");
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}
