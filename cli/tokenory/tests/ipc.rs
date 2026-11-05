use serde_json::{json, Value};
use std::{
    io::{BufRead, BufReader, Write},
    process::{Command, Stdio},
    sync::mpsc,
    time::Duration,
};
#[test]
fn worker_queries_errors_writer_lock_and_eof_are_real_process_behaviors() {
    let data = tempfile::tempdir().unwrap();
    let home = tempfile::tempdir().unwrap();
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
    request(&mut input, "bad", "overview", json!({"from":"2026-02-30"}));
    assert!(response("bad")["error"].is_object());
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
