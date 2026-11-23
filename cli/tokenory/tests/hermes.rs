// [INPUT]: Hermes DB fixtures and a pre-upgrade ledger record.
// [OUTPUT]: Assertions for cross-day allocation, historical estimate and source recovery.
// [POS]: End-to-end regression test of the local remainder and replacement rules.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
use rusqlite::{params, Connection};
use serde_json::json;
use std::fs;
use tokenory::{
    collector::{collect_once, persist, DiagnosticCache},
    config::Config,
    db::{put_record, Database},
    pricing::{assign, save_snapshot, PriceSnapshot},
    usage::{Tokens, UsageRecord},
};

fn timestamp(iso: &str) -> i64 {
    chrono::DateTime::parse_from_rfc3339(iso)
        .unwrap()
        .timestamp()
}

fn ledger(db: &Database, source: &str) -> Vec<UsageRecord> {
    let mut stmt = db
        .connection
        .prepare(
            "SELECT body FROM usage_records WHERE source = ?1 AND client = 'hermes'
         ORDER BY json_extract(body, '$.timestampMs'), item_key",
        )
        .unwrap();
    stmt.query_map([source], |row| row.get::<_, String>(0))
        .unwrap()
        .map(|body| serde_json::from_str(&body.unwrap()).unwrap())
        .collect()
}

fn assert_cost(records: &[UsageRecord], expected: f64) {
    let actual: f64 = records.iter().map(|r| r.estimated_cost_usd.unwrap()).sum();
    assert!(
        (expected - actual).abs() < 1e-12,
        "estimate {actual}, expected {expected}"
    );
}

#[tokio::test]
async fn allocated_days_replace_legacy_local_usage_and_keep_the_prior_rate_and_timezone() {
    let home = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    let source_dir = home.path().join(".hermes");
    fs::create_dir_all(&source_dir).unwrap();
    let path = source_dir.join("state.db");
    let source = Connection::open(&path).unwrap();
    source
        .execute_batch(
            "CREATE TABLE sessions (
           id TEXT PRIMARY KEY, model TEXT, started_at REAL, message_count INTEGER,
           billing_provider TEXT, input_tokens INTEGER, output_tokens INTEGER,
           cache_read_tokens INTEGER, cache_write_tokens INTEGER, reasoning_tokens INTEGER,
           estimated_cost_usd REAL, actual_cost_usd REAL
         );
         CREATE TABLE messages (session_id TEXT, role TEXT, timestamp REAL);",
        )
        .unwrap();
    let first = timestamp("2026-11-04T18:00:00Z");
    let second = timestamp("2026-11-05T18:00:00Z");
    let third = timestamp("2026-11-06T18:00:00Z");
    source.execute(
        "INSERT INTO sessions VALUES ('session', 'claude-sonnet-4', ?1, 2, 'anthropic', 1000, 100, 0, 0, 0, 0.5, NULL)",
        [first],
    ).unwrap();
    for at in [first, second, second] {
        source
            .execute(
                "INSERT INTO messages VALUES ('session', 'assistant', ?1)",
                [at],
            )
            .unwrap();
    }

    let config = Config {
        home_dir: home.path().into(),
        timezone: "America/Los_Angeles".into(),
        ..Default::default()
    };
    let mut db = Database::open(data.path()).unwrap();
    let mut cache = DiagnosticCache::default();
    let batch = collect_once(&config, &mut cache).await.unwrap();
    assert_eq!(batch.records.len(), 2);
    assert_eq!(
        batch
            .records
            .iter()
            .map(|r| r.requests.unwrap())
            .sum::<i64>(),
        2
    );
    let mut legacy = batch.records[0].clone();
    legacy.key = r#"snapshot:["hermes","session",["event","session"]]"#.into();
    legacy
        .metadata
        .as_object_mut()
        .unwrap()
        .remove("hermesUsageGroup");
    legacy.date = "2026-11-05".into();
    legacy.timezone = Some("Asia/Shanghai".into());
    legacy.tokens = Tokens {
        input: 1000,
        output: 100,
        ..Default::default()
    };
    legacy.requests = Some(2);

    let mut price = PriceSnapshot::bundled_reference();
    let original = save_snapshot(&mut db, price.clone()).unwrap();
    assign("local", &mut legacy, &original, &price);
    let saved_cost = legacy.estimated_cost_usd.unwrap();
    put_record(&db.connection, "local", "", &legacy).unwrap();
    put_record(&db.connection, "tokens-ci", "imported", &legacy).unwrap();
    let new_rates = price
        .entries
        .iter_mut()
        .find(|p| p.provider == "anthropic" && p.model == "claude-sonnet-4")
        .unwrap();
    new_rates.rates.input_cost_per_token = Some(0.01);
    let active = save_snapshot(&mut db, price).unwrap();
    assert_ne!(active, original);

    let scan = persist(&mut db, batch).unwrap();
    assert_eq!((scan.added, scan.removed), (2, 1));
    let records = ledger(&db, "local");
    assert_eq!(
        records.iter().map(|r| r.date.as_str()).collect::<Vec<_>>(),
        ["2026-11-05", "2026-11-06"]
    );
    assert!(records.iter().all(|r| {
        r.tokens.input == 500
            && r.tokens.output == 50
            && r.timezone.as_deref() == Some("Asia/Shanghai")
            && r.price_snapshot_id.as_deref() == Some(original.as_str())
            && r.cost_basis == legacy.cost_basis
            && r.source_cost_usd.is_none()
    }));
    assert_cost(&records, saved_cost);
    assert_eq!(
        persist(&mut db, collect_once(&config, &mut cache).await.unwrap())
            .unwrap()
            .changed,
        0
    );

    // A later read can see more usage and more timestamps in the same session.
    source
        .execute(
            "UPDATE sessions SET input_tokens = 1500, output_tokens = 150, message_count = 3",
            [],
        )
        .unwrap();
    source
        .execute(
            "INSERT INTO messages VALUES ('session', 'assistant', ?1)",
            params![third],
        )
        .unwrap();
    persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    let grown = ledger(&db, "local");
    assert_eq!(grown.len(), 3);
    assert_eq!(
        grown
            .iter()
            .map(|r| r.tokens.checked_total().unwrap())
            .sum::<i64>(),
        1650
    );
    assert_eq!(grown[0].timezone.as_deref(), Some("Asia/Shanghai"));
    assert_eq!(grown[1].timezone.as_deref(), Some("Asia/Shanghai"));
    assert_eq!(grown[2].timezone.as_deref(), Some("America/Los_Angeles"));
    assert!(grown
        .iter()
        .all(|r| r.price_snapshot_id.as_deref() == Some(original.as_str())));
    assert_cost(&grown, saved_cost * 1.5);
    assert_eq!(
        persist(&mut db, collect_once(&config, &mut cache).await.unwrap())
            .unwrap()
            .changed,
        0
    );

    source
        .execute("UPDATE sessions SET input_tokens = 'invalid'", [])
        .unwrap();
    let failed = persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    assert_eq!(
        failed
            .sources
            .iter()
            .find(|s| s.client == "hermes")
            .unwrap()
            .status,
        "partial"
    );
    assert_eq!(failed.changed, 0);
    drop(source);
    fs::remove_file(path).unwrap();
    assert_eq!(
        persist(&mut db, collect_once(&config, &mut cache).await.unwrap())
            .unwrap()
            .changed,
        0
    );
    assert_cost(&ledger(&db, "local"), saved_cost * 1.5);
    assert_eq!(
        serde_json::to_value(&ledger(&db, "tokens-ci")[0]).unwrap(),
        json!(legacy)
    );
}
