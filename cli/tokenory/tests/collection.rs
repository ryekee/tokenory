use serde_json::json;
use std::fs;
use tokenory::{
    collector::{collect_once, persist, DiagnosticCache},
    config::Config,
    db::Database,
    queries::{report, Filter},
};
#[tokio::test]
async fn provider_correction_updates_one_event_across_scans_and_legacy_keys_merge() {
    let home = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    let dir = home.path().join(".claude/projects/test");
    fs::create_dir_all(&dir).unwrap();
    let file = dir.join("session.jsonl");
    let first = json!({"type":"assistant","timestamp":"2026-11-05T01:00:00Z","message":{"id":"same-response","role":"assistant","model":"claude-sonnet-4-5","usage":{"input_tokens":100,"output_tokens":20}}});
    let mut corrected = first.clone();
    corrected["providerId"] = "bedrock".into();
    let config = Config {
        home_dir: home.path().into(),
        ..Default::default()
    };
    let mut cache = DiagnosticCache::default();
    let mut db = Database::open(data.path()).unwrap();
    fs::write(&file, format!("{first}\n")).unwrap();
    let batch = collect_once(&config, &mut cache).await.unwrap();
    let mut legacy_first = batch.records[0].clone();
    legacy_first.key = "claude:anthropic:message:same-response".into();
    persist(&mut db, batch).unwrap();
    fs::write(&file, format!("{first}\n{corrected}\n")).unwrap();
    let batch = collect_once(&config, &mut cache).await.unwrap();
    assert_eq!(batch.records.len(), 1);
    assert_eq!(batch.records[0].provider, "bedrock");
    let mut legacy_corrected = batch.records[0].clone();
    legacy_corrected.key = "claude:bedrock:message:same-response".into();
    persist(&mut db, batch).unwrap();
    let r = report(&mut db, &Filter::default()).unwrap();
    assert_eq!(r.summary.tokens, 120);
    assert_eq!(r.summary.record_count, 1);
    assert_eq!(r.providers[0].key, "bedrock");

    // Simulate the pre-fix database, including a duplicate already persisted.
    db.connection
        .execute("DELETE FROM usage_records", [])
        .unwrap();
    tokenory::db::put_record(&db.connection, "local", "", &legacy_first).unwrap();
    tokenory::db::put_record(&db.connection, "local", "", &legacy_corrected).unwrap();
    db.connection
        .execute_batch("PRAGMA user_version=2;")
        .unwrap();
    let backup = data.path().join("legacy.sqlite3");
    db.backup(&backup).unwrap();
    drop(db);
    let mut db = Database::open(data.path()).unwrap();
    assert_eq!(
        report(&mut db, &Filter::default()).unwrap().summary.tokens,
        120
    );
    let scan = persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    assert_eq!(scan.added, 0);
    assert_eq!(scan.changed, 0);
    assert_eq!(
        report(&mut db, &Filter::default()).unwrap().providers[0].key,
        "bedrock"
    );
    // A version-2 backup follows the same migration path on restore.
    db.restore(&backup).unwrap();
    assert_eq!(
        report(&mut db, &Filter::default()).unwrap().summary.tokens,
        120
    );
}
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

#[tokio::test]
async fn deepseek_anthropic_usage_is_one_event_per_response_not_per_observation() {
    let home = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    let dir = home.path().join(".claude/projects/test");
    fs::create_dir_all(&dir).unwrap();
    let row = |id: &str| {
        json!({"type":"assistant","timestamp":"2026-11-05T01:00:00Z","message":{"id":id,"role":"assistant","model":"deepseek-flash","usage":{"input_tokens":400,"output_tokens":200,"cache_read_input_tokens":600,"cache_creation_input_tokens":0}}}).to_string()+"\n"
    };
    fs::write(
        dir.join("a.jsonl"),
        row("response-a") + &row("response-a") + &row("response-b"),
    )
    .unwrap();
    let config = Config {
        home_dir: home.path().into(),
        ..Default::default()
    };
    let mut cache = DiagnosticCache::default();
    let mut db = Database::open(data.path()).unwrap();
    tokenory::pricing::initialize(&mut db).unwrap();
    persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    let r = report(&mut db, &Filter::default()).unwrap();
    assert_eq!(r.summary.record_count, 2);
    assert_eq!(r.summary.tokens, 2400);
    assert_eq!(r.summary.token_breakdown.input, 800);
    assert_eq!(r.summary.token_breakdown.cache_read, 1200);
    assert_eq!(r.summary.token_breakdown.output, 400);
    assert_eq!(r.providers[0].key, "deepseek");
    assert!((r.summary.known_estimated_cost_usd.unwrap() - 0.0007272).abs() < 1e-12);
}
