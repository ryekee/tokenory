use rusqlite::Connection;
use serde_json::{json, Value};
use std::{collections::BTreeMap, fs, path::Path};
use tokenory::{
    collector::{collect_once, persist, DiagnosticCache},
    config::Config,
    db::Database,
    queries::daily_source_usage,
};

fn write_journal(path: &Path, events: &[Value]) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let contents: String = events.iter().map(|event| format!("{event}\n")).collect();
    fs::write(path, contents).unwrap();
}

fn usage_checkpoint(day: u8, input: i64, output: i64, cache_read: i64) -> Value {
    json!({
        "type": "session.usage_checkpoint",
        "id": format!("checkpoint-{day}"),
        "timestamp": format!("2026-11-{day}T09:00:00.000Z"),
        "data": {"providerModelMetrics": [{
            "modelId": "gpt-5.4",
            "metrics": {
                "requests": {"count": i64::from(day) - 17},
                "usage": {"inputTokens": input, "outputTokens": output, "cacheReadTokens": cache_read}
            }
        }]}
    })
}

fn sdk_journal(home: &Path, session: &str) -> std::path::PathBuf {
    home.join(".copilot/session-state")
        .join(session)
        .join("events.jsonl")
}

fn session_start() -> Value {
    json!({
        "type": "session.start",
        "id": "session-start",
        "timestamp": "2026-11-18T08:00:00.000Z",
        "data": {"selectedModel": "gpt-5.4"}
    })
}

fn otel_span(session: &str) -> Value {
    json!({
        "type": "span",
        "traceId": "trace-1",
        "spanId": "span-1",
        "name": "chat gpt-5.4",
        "startTime": [1794990600, 0],
        "attributes": {
            "gen_ai.operation.name": "chat",
            "gen_ai.response.model": "gpt-5.4",
            "gen_ai.conversation.id": session,
            "gen_ai.usage.input_tokens": 11,
            "gen_ai.usage.output_tokens": 2
        }
    })
}

#[tokio::test]
async fn copilot_sdk_deltas_reach_the_ledger_and_already_covered_sessions_count_once() {
    let home = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    let legacy_session = "abcdef00-0000-0000-0000-000000000001";
    for session in [
        "sdk-only",
        "desktop-session",
        "otel-session",
        legacy_session,
    ] {
        write_journal(
            &sdk_journal(home.path(), session),
            &[
                session_start(),
                usage_checkpoint(18, 100, 10, 40),
                usage_checkpoint(19, 200, 25, 80),
            ],
        );
    }

    let desktop = Connection::open(home.path().join(".copilot/data.db")).unwrap();
    desktop
        .execute_batch(
            "CREATE TABLE sessions (id TEXT, title TEXT, model TEXT, total_input_tokens INTEGER,
                total_output_tokens INTEGER, total_cached_tokens INTEGER, total_reasoning_tokens INTEGER,
                total_nano_aiu INTEGER, created_at TEXT);
             INSERT INTO sessions VALUES ('desktop-session', 'Desktop', 'gpt-5.4', 90, 9, 0, 0, 0, '2026-11-18T08:15:00Z');",
        )
        .unwrap();
    drop(desktop);

    write_journal(
        &home.path().join(".copilot/otel/copilot.jsonl"),
        &[otel_span("otel-session")],
    );
    write_journal(
        &home.path().join(format!(
            "Library/Application Support/Code/User/workspaceStorage/project/chatSessions/{legacy_session}.jsonl"
        )),
        &[json!({"kind": 2, "k": ["requests"], "v": [{
            "requestId": "request-1",
            "timestamp": 1794992000000_i64,
            "modelId": "copilot/gpt-5.4",
            "promptTokens": 30,
            "completionTokens": 3
        }]})],
    );

    let duplicate_root = home.path().join("copilot-copy");
    write_journal(
        &duplicate_root.join("sdk-only/events.jsonl"),
        &[session_start(), usage_checkpoint(18, 100, 10, 40)],
    );
    let config = Config {
        home_dir: home.path().into(),
        timezone: "UTC".into(),
        extra_scan_paths: [("copilot".into(), vec![duplicate_root])].into(),
        ..Default::default()
    };
    let mut cache = DiagnosticCache::default();
    let mut db = Database::open(data.path()).unwrap();
    let batch = collect_once(&config, &mut cache).await.unwrap();
    let source = batch
        .result
        .sources
        .iter()
        .find(|s| s.client == "copilot")
        .unwrap();
    assert_eq!(
        (source.status.as_str(), source.files, source.records),
        ("ok", 8, 5)
    );
    let mut totals = BTreeMap::new();
    for record in &batch.records {
        *totals
            .entry(record.session_id.as_deref().unwrap())
            .or_insert(0) += record.tokens.checked_total().unwrap();
    }
    assert_eq!(
        totals,
        BTreeMap::from([
            ("sdk-only", 225),
            ("desktop-session", 99),
            ("otel-session", 13),
            (legacy_session, 33)
        ])
    );
    assert_eq!(
        batch
            .records
            .iter()
            .filter(|r| r.session_id.as_deref() == Some("sdk-only"))
            .map(|r| (
                r.date.as_str(),
                r.tokens.input,
                r.tokens.cache_read,
                r.tokens.output
            ))
            .collect::<Vec<_>>(),
        [("2026-11-18", 60, 40, 10), ("2026-11-19", 60, 40, 15)]
    );
    persist(&mut db, batch).unwrap();
    assert_eq!(
        persist(&mut db, collect_once(&config, &mut cache).await.unwrap())
            .unwrap()
            .changed,
        0
    );

    let parsed = tokens_core::parse_local_clients(tokens_core::LocalParseOptions {
        home_dir: Some(home.path().to_string_lossy().into_owned()),
        clients: Some(vec!["copilot".into()]),
        use_env_roots: false,
        ..Default::default()
    })
    .unwrap();
    let mut totals = BTreeMap::new();
    for message in parsed.messages {
        *totals.entry(message.session_id).or_insert(0) +=
            message.input + message.cache_read + message.output;
    }
    assert_eq!(
        totals,
        BTreeMap::from([
            ("sdk-only".into(), 225),
            ("desktop-session".into(), 99),
            ("otel-session".into(), 13),
            (legacy_session.into(), 33)
        ])
    );
}

#[tokio::test]
async fn copilot_sdk_missing_archive_preserves_saved_deltas_and_appends_new_usage() {
    let home = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    let path = sdk_journal(home.path(), "rotated-session");
    let mut start = session_start();
    let before = usage_checkpoint(18, 100, 10, 40);
    let baseline = usage_checkpoint(19, 200, 20, 80);
    write_journal(&path, &[start.clone(), before, baseline.clone()]);
    let config = Config {
        home_dir: home.path().into(),
        timezone: "UTC".into(),
        ..Default::default()
    };
    let mut cache = DiagnosticCache::default();
    let mut db = Database::open(data.path()).unwrap();
    persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();

    start["checkpoint"] = json!(true);
    let link = json!({"type": "session.journal_link", "data": {"previousFile": "events.1.jsonl"}});
    let next = usage_checkpoint(20, 300, 30, 120);
    write_journal(&path, &[start, link, baseline, next]);
    let result = persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    assert_eq!((result.added, result.removed), (1, 0));
    assert_eq!(
        daily_source_usage(&db)
            .unwrap()
            .iter()
            .map(|row| (row.date.as_str(), row.tokens))
            .collect::<Vec<_>>(),
        [
            ("2026-11-18", 110),
            ("2026-11-19", 110),
            ("2026-11-20", 110)
        ]
    );
    assert_eq!(
        persist(&mut db, collect_once(&config, &mut cache).await.unwrap())
            .unwrap()
            .changed,
        0
    );
}

#[tokio::test]
async fn partial_copilot_sdk_history_waits_for_complete_data_before_replacing_another_source() {
    let home = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    let session = "same-session";
    let otel_path = home.path().join(".copilot/otel/copilot.jsonl");
    write_journal(&otel_path, &[otel_span(session)]);
    let config = Config {
        home_dir: home.path().into(),
        timezone: "UTC".into(),
        ..Default::default()
    };
    let mut cache = DiagnosticCache::default();
    let mut db = Database::open(data.path()).unwrap();
    persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();

    fs::remove_file(otel_path).unwrap();
    let path = sdk_journal(home.path(), session);
    let start = session_start();
    let mut replayed = start.clone();
    replayed["checkpoint"] = json!(true);
    let baseline = usage_checkpoint(18, 100, 10, 40);
    let next = usage_checkpoint(19, 200, 20, 80);
    write_journal(&path, &[replayed, baseline.clone(), next.clone()]);
    let result = persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    assert_eq!(result.changed, 0);
    assert_eq!(daily_source_usage(&db).unwrap()[0].tokens, 13);

    write_journal(&path, &[start, baseline, next]);
    let result = persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    assert_eq!((result.added, result.removed), (2, 1));
    let rows = daily_source_usage(&db).unwrap();
    assert_eq!(rows.iter().map(|row| row.tokens).sum::<i64>(), 220);
}
