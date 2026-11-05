use serde_json::json;
use std::fs;
use tokenory::{
    collector::{collect_once, persist, DiagnosticCache},
    config::Config,
    db::Database,
    queries::{report, Filter},
};
#[tokio::test]
async fn stream_update_partial_write_and_deleted_log_preserve_history() {
    let home = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    let dir = home.path().join(".claude/projects/test");
    fs::create_dir_all(&dir).unwrap();
    let file = dir.join("s.jsonl");
    let row = |n| {
        json!({"type":"assistant","timestamp":"2026-11-04T17:00:00Z","message":{"id":"msg_stable","role":"assistant","model":"deepseek-v4-pro","usage":{"input_tokens":n,"output_tokens":0,"cache_read_input_tokens":600}}}).to_string()+"\n"
    };
    let config = Config {
        home_dir: home.path().into(),
        ..Default::default()
    };
    let mut cache = DiagnosticCache::default();
    let mut db = Database::open(data.path()).unwrap();
    fs::write(&file, row(100)).unwrap();
    persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    let r = report(&mut db, &Filter::default()).unwrap();
    assert_eq!(r.summary.tokens, 700);
    assert_eq!(r.daily[0].key, "2026-11-05");
    assert_eq!(r.providers[0].key, "deepseek");
    let unchanged = persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    assert_eq!(unchanged.changed, 0);
    fs::write(&file, row(120) + "{incomplete").unwrap();
    let scan = persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    assert!(scan.sources.iter().any(|s| s.status == "partial"));
    assert_eq!(
        report(&mut db, &Filter::default()).unwrap().summary.tokens,
        700
    );
    fs::write(&file, row(120)).unwrap();
    persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    assert_eq!(
        report(&mut db, &Filter::default()).unwrap().summary.tokens,
        720
    );
    fs::remove_file(file).unwrap();
    persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    drop(db);
    let mut db = Database::open(data.path()).unwrap();
    assert_eq!(
        report(&mut db, &Filter::default()).unwrap().summary.tokens,
        720
    );
}
#[tokio::test]
async fn cumulative_codex_and_archived_copy_count_once() {
    let home = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    let active = home.path().join(".codex/sessions");
    let archive = home.path().join(".codex/archived_sessions");
    fs::create_dir_all(&active).unwrap();
    fs::create_dir_all(&archive).unwrap();
    let mut rows = vec![
        json!({"timestamp":"2026-11-05T01:00:00Z","type":"session_meta","payload":{"id":"session-stable","model_provider":"openai"}}),
        json!({"timestamp":"2026-11-05T01:00:00Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}),
    ];
    for (minute, total) in [(1, 100), (2, 150)] {
        rows.push(json!({"timestamp":format!("2026-11-05T01:0{minute}:00Z"),"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":total,"output_tokens":0,"cached_input_tokens":0,"reasoning_output_tokens":0,"total_tokens":total}}}}));
    }
    let body = rows
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join("\n")
        + "\n";
    fs::write(active.join("a.jsonl"), &body).unwrap();
    fs::write(archive.join("b.jsonl"), body).unwrap();
    let config = Config {
        home_dir: home.path().into(),
        ..Default::default()
    };
    let mut cache = DiagnosticCache::default();
    let mut db = Database::open(data.path()).unwrap();
    persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    assert_eq!(
        report(&mut db, &Filter::default()).unwrap().summary.tokens,
        150
    );
}
