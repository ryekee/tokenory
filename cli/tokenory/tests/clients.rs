use rusqlite::Connection;
use serde_json::{json, Value};
use std::{fs, path::Path};
use tokenory::{
    clients::CLIENTS,
    collector::{collect_once, persist, DiagnosticCache},
    config::Config,
    db::Database,
    queries::{report, Filter},
};

fn write(home: &Path, path: &str, value: Value) {
    let file = home.join(path);
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    fs::write(file, serde_json::to_vec(&value).unwrap()).unwrap();
}

#[test]
fn requested_products_and_extra_path_validation() {
    let catalog = serde_json::to_value(tokenory::clients::catalog()).unwrap();
    assert_eq!(catalog.as_array().unwrap().len(), 42);
    assert_eq!(CLIENTS.len(), 40);
    assert_eq!(
        catalog
            .as_array()
            .unwrap()
            .iter()
            .find(|c| c["id"] == "paseo")
            .unwrap()["collectsAs"],
        json!(["claude", "codex"])
    );
    assert_eq!(
        catalog
            .as_array()
            .unwrap()
            .iter()
            .find(|c| c["id"] == "orca")
            .unwrap()["collectsAs"],
        json!(["micode"])
    );
    let home = tempfile::tempdir().unwrap();
    let mut config = Config {
        home_dir: home.path().into(),
        ..Default::default()
    };
    config
        .extra_scan_paths
        .insert("gemini".into(), vec![home.path().join("custom")]);
    config.validate().unwrap();
    config
        .extra_scan_paths
        .insert("bogus".into(), vec![home.path().into()]);
    assert!(config.validate().is_err());
    config.extra_scan_paths.remove("bogus");
    config
        .extra_scan_paths
        .insert("goose".into(), vec![home.path().into()]);
    assert!(config.validate().is_err());
}

#[tokio::test]
async fn discovers_json_jsonl_and_cached_clients_without_event_ids() {
    let home = tempfile::tempdir().unwrap();
    write(
        home.path(),
        ".local/share/amp/threads/T-test.json",
        json!({"id":"amp-session","created":1793926800000_i64,"messages":[
            {"role":"assistant","messageId":1,"usage":{"model":"claude-sonnet-4-5","inputTokens":100,"outputTokens":20}},
            {"role":"assistant","messageId":2,"usage":{"model":"claude-sonnet-4-5","inputTokens":100,"outputTokens":20}}
        ]}),
    );
    write(
        home.path(),
        ".gemini/tmp/project/chats/session-test.json",
        json!({"sessionId":"gemini-session","projectHash":"p","startTime":"2026-11-06T01:00:00Z","lastUpdated":"2026-11-06T01:00:00Z","messages":[
            {"id":"a","type":"gemini","timestamp":"2026-11-06T01:00:00Z","model":"gemini-2.5-pro","tokens":{"input":100,"output":20}},
            {"id":"b","type":"gemini","timestamp":"2026-11-06T01:00:00Z","model":"gemini-2.5-pro","tokens":{"input":100,"output":20}}
        ]}),
    );
    for (extension, id) in [
        ("saoudrizwan.claude-dev", "cline"),
        ("rooveterinaryinc.roo-cline", "roo"),
        ("kilocode.kilo-code", "kilo"),
    ] {
        write(home.path(), &format!("Library/Application Support/Code/User/globalStorage/{extension}/tasks/{id}/ui_messages.json"), json!([{"type":"say","say":"api_req_started","ts":1793926800000_i64,"text":json!({"tokensIn":100,"tokensOut":20,"cost":0.1,"apiProtocol":"anthropic"}).to_string(),"modelInfo":{"modelId":"claude-sonnet-4-5","providerId":"anthropic"}}]));
    }
    write(
        home.path(),
        ".config/tokens/cursor-cache/usage.json",
        json!({"usageEventsDisplay":[{"conversationId":"cursor-session","timestamp":1793926800000_i64,"model":"claude-sonnet-4-5","chargedCents":1,"tokenUsage":{"inputTokens":100,"outputTokens":20}}]}),
    );
    let command = home.path().join(".commandcode/projects/test/session.jsonl");
    fs::create_dir_all(command.parent().unwrap()).unwrap();
    fs::copy(
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../tokens-core/tests/fixtures/commandcode/1.53.0.jsonl"),
        command,
    )
    .unwrap();
    let config = Config {
        home_dir: home.path().into(),
        ..Default::default()
    };
    let data = tempfile::tempdir().unwrap();
    let mut db = Database::open(data.path()).unwrap();
    let mut cache = DiagnosticCache::default();
    let batch = collect_once(&config, &mut cache).await.unwrap();
    for client in [
        "amp",
        "gemini",
        "cline",
        "roocode",
        "kilocode",
        "cursor",
        "commandcode",
    ] {
        let status = batch
            .result
            .sources
            .iter()
            .find(|s| s.client == client)
            .unwrap();
        assert_eq!(status.status, "ok", "{client}: {:?}", status.errors);
        assert!(status.files > 0 && status.records > 0, "{client}");
    }
    assert_eq!(
        batch.records.iter().filter(|r| r.client == "amp").count(),
        2
    );
    assert_eq!(
        batch
            .records
            .iter()
            .filter(|r| r.client == "gemini")
            .count(),
        2
    );
    persist(&mut db, batch).unwrap();
    let first = report(&mut db, &Filter::default()).unwrap().summary.tokens;
    let second = persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    assert_eq!(second.changed, 0);
    assert_eq!(
        report(&mut db, &Filter::default()).unwrap().summary.tokens,
        first
    );
}

#[tokio::test]
async fn session_snapshot_updates_replaces_stale_models_and_preserves_missing_or_invalid_sources() {
    let home = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    let path = ".mux/sessions/workspace/session-usage.json";
    let config = Config {
        home_dir: home.path().into(),
        ..Default::default()
    };
    let mut db = Database::open(data.path()).unwrap();
    let mut cache = DiagnosticCache::default();
    write(
        home.path(),
        path,
        json!({"lastRequest":{"timestamp":1793926800000_i64},"byModel":{
            "anthropic:claude-sonnet-4-5":{"input":{"tokens":100}},
            "openai:gpt-5":{"output":{"tokens":50}}
        }}),
    );
    persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    assert_eq!(
        report(&mut db, &Filter::default()).unwrap().summary.tokens,
        150
    );
    write(
        home.path(),
        path,
        json!({"lastRequest":{"timestamp":1794013200000_i64},"byModel":{
            "anthropic:claude-sonnet-4-5":{"input":{"tokens":200}}
        }}),
    );
    let scan = persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    assert_eq!(scan.removed, 1);
    let updated = report(&mut db, &Filter::default()).unwrap();
    assert_eq!(updated.summary.tokens, 200);
    assert_eq!(updated.summary.record_count, 1);
    assert_eq!(updated.daily[0].key, "2026-11-07");
    let hourly = report(
        &mut db,
        &Filter {
            from: Some("2026-11-07".into()),
            to: Some("2026-11-07".into()),
            ..Default::default()
        },
    )
    .unwrap()
    .hourly
    .unwrap();
    assert!(hourly.buckets.is_empty());
    assert_eq!(hourly.unallocated.tokens, 200);
    fs::write(home.path().join(path), "{incomplete").unwrap();
    let scan = persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    assert_eq!(
        scan.sources
            .iter()
            .find(|s| s.client == "mux")
            .unwrap()
            .status,
        "partial"
    );
    assert_eq!(
        report(&mut db, &Filter::default()).unwrap().summary.tokens,
        200
    );
    fs::remove_file(home.path().join(path)).unwrap();
    persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    assert_eq!(
        report(&mut db, &Filter::default()).unwrap().summary.tokens,
        200
    );
}

#[tokio::test]
async fn sqlite_orca_and_paseo_paths_are_discovered_and_not_double_counted() {
    let home = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    let orca = home
        .path()
        .join("Library/Application Support/orca/mimocode-hooks/shared/data/mimocode.db");
    fs::create_dir_all(orca.parent().unwrap()).unwrap();
    let source = Connection::open(&orca).unwrap();
    source.execute_batch("PRAGMA journal_mode=WAL; CREATE TABLE message(id TEXT PRIMARY KEY,session_id TEXT NOT NULL,data TEXT NOT NULL);").unwrap();
    let row = json!({"id":"orca-message","role":"assistant","modelID":"mimo-v2.5-pro","providerID":"mimo","tokens":{"input":100,"output":50},"time":{"created":1793926800000_i64}}).to_string();
    source
        .execute(
            "INSERT INTO message VALUES ('orca-message','orca-session',?1)",
            [&row],
        )
        .unwrap();
    let claude = home.path().join("custom-claude/projects/test/one.jsonl");
    fs::create_dir_all(claude.parent().unwrap()).unwrap();
    let row = json!({"type":"assistant","timestamp":"2026-11-06T01:00:00Z","message":{"id":"paseo-response","role":"assistant","model":"claude-sonnet-4-5","usage":{"input_tokens":100,"output_tokens":20}}}).to_string();
    fs::write(&claude, row).unwrap();
    write(
        home.path(),
        ".paseo/config.json",
        json!({"agents":{"providers":{"claude":{"env":{"CLAUDE_CONFIG_DIR":home.path().join("custom-claude")}}}}}),
    );
    let mut config = Config {
        home_dir: home.path().into(),
        ..Default::default()
    };
    config.extra_scan_paths.insert(
        "claude".into(),
        vec![home.path().join("custom-claude/projects")],
    );
    let mut cache = DiagnosticCache::default();
    let mut db = Database::open(data.path()).unwrap();
    let batch = collect_once(&config, &mut cache).await.unwrap();
    assert_eq!(batch.records.len(), 2);
    assert_eq!(
        batch
            .result
            .sources
            .iter()
            .find(|s| s.client == "micode")
            .unwrap()
            .files,
        1
    );
    persist(&mut db, batch).unwrap();
    assert_eq!(
        report(&mut db, &Filter::default()).unwrap().summary.tokens,
        270
    );
    source
        .execute(
            "UPDATE message SET data=json_set(data,'$.tokens.input',200)",
            [],
        )
        .unwrap();
    persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    assert_eq!(
        report(&mut db, &Filter::default()).unwrap().summary.tokens,
        370
    );
    assert_eq!(
        persist(&mut db, collect_once(&config, &mut cache).await.unwrap())
            .unwrap()
            .changed,
        0
    );
}

#[tokio::test]
async fn trae_and_warp_cumulative_cache_updates_do_not_add_a_second_snapshot() {
    let home = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    let config = Config {
        home_dir: home.path().into(),
        ..Default::default()
    };
    let mut db = Database::open(data.path()).unwrap();
    let mut cache = DiagnosticCache::default();
    for (time, input, cents) in [(1793926800_i64, 100, 20), (1794013200, 200, 30)] {
        write(
            home.path(),
            ".config/tokens/trae-cache/sessions/usage.json",
            json!([{"session_id":"trae-session","model_name":"GPT-5.4","usage_time":time,"dollar_float":0.1,"extra_info":{"input_token":input,"output_token":20}}]),
        );
        write(
            home.path(),
            ".config/tokens/warp-cache/usage.json",
            json!({"syncedAt":if input == 100 {"2026-11-06T01:00:00Z"} else {"2026-11-07T01:00:00Z"},"usage":{"requestsUsed":5,"spendCents":cents}}),
        );
        let batch = collect_once(&config, &mut cache).await.unwrap();
        assert_eq!(batch.records.len(), 2, "{:?}", batch.result.sources);
        persist(&mut db, batch).unwrap();
        let r = report(&mut db, &Filter::default()).unwrap();
        assert_eq!(r.summary.record_count, 2);
        assert_eq!(r.summary.tokens, input + 20);
        assert!(
            (r.details
                .iter()
                .filter_map(|d| d.record.source_cost_usd)
                .sum::<f64>()
                - (0.1 + cents as f64 / 100.0))
                .abs()
                < 1e-9
        );
    }
}
