// [INPUT]: Pi transcripts with repeated provider response IDs and legacy ledger snapshots.
// [OUTPUT]: Assertions for recovered usage, fork deduplication, and retained ledger history.
// [POS]: End-to-end regression tests through the collector and SQLite ledger.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
use serde_json::json;
use std::{fs, path::Path};
use tokenory::{
    collector::{collect_once, persist, DiagnosticCache},
    config::Config,
    db::{put_record, Database},
    pricing::{assign, save_snapshot, PriceSnapshot},
    usage::UsageRecord,
};

const SHARED_ID: &str = "gateway:quoted-\"雪\"";

fn write_session(path: &Path, session: &str) {
    let mut lines = vec![json!({"type":"session", "id":session,
        "timestamp":"2026-11-04T18:00:00Z", "cwd":"/tmp/project"})];
    for (entry, at, input) in [
        ("a", "2026-11-04T18:00:01Z", 100),
        ("b", "2026-11-04T18:00:02Z", 200),
    ] {
        lines.push(json!({"type":"message", "id":entry, "timestamp":at,
            "message":{"role":"assistant", "provider":"anthropic", "model":"claude-sonnet-4",
            "responseId":SHARED_ID, "usage":{"input":input, "output":10, "cacheRead":0, "cacheWrite":0}}}));
    }
    fs::write(
        path,
        lines
            .iter()
            .map(|line| format!("{line}\n"))
            .collect::<String>(),
    )
    .unwrap();
}

fn rows(db: &Database) -> Vec<UsageRecord> {
    let mut stmt = db
        .connection
        .prepare(
            "SELECT body FROM usage_records WHERE source='local' AND client='pi' ORDER BY item_key",
        )
        .unwrap();
    stmt.query_map([], |row| row.get::<_, String>(0))
        .unwrap()
        .map(|body| serde_json::from_str(&body.unwrap()).unwrap())
        .collect()
}

fn legacy_key(session: &str) -> String {
    format!(
        "snapshot:{}",
        json!(["pi", session, ["event", format!("pi:response:{SHARED_ID}")]])
    )
}

#[tokio::test]
async fn pi_fork_keeps_distinct_requests_and_migrates_only_matching_history() {
    let home = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    let session_dir = home.path().join(".pi/agent/sessions/--project--");
    fs::create_dir_all(&session_dir).unwrap();
    let fork = session_dir.join("fork.jsonl");
    write_session(&fork, "fork-session");

    let config = Config {
        home_dir: home.path().into(),
        timezone: "America/Los_Angeles".into(),
        ..Default::default()
    };
    let mut cache = DiagnosticCache::default();
    let mut db = Database::open(data.path()).unwrap();
    let batch = collect_once(&config, &mut cache).await.unwrap();
    assert_eq!(batch.records.len(), 2);
    let source = batch
        .records
        .iter()
        .find(|r| r.tokens.input == 100)
        .unwrap();
    assert!(source.key.starts_with("pi:entry:a:"));

    let mut prices = PriceSnapshot::bundled_reference();
    let old_price = save_snapshot(&mut db, prices.clone()).unwrap();
    // The parent originally won deduplication and has since been removed. The
    // old parser stored only the first request and keyed it by response ID.
    let mut legacy = source.clone();
    legacy.key = legacy_key("missing-parent");
    legacy.session_id = Some("missing-parent".into());
    legacy.date = "2026-11-05".into();
    legacy.timezone = Some("Asia/Shanghai".into());
    assign("local", &mut legacy, &old_price, &prices);
    put_record(&db.connection, "local", "", &legacy).unwrap();

    // Same response ID in other old history is not enough evidence to remove it.
    let mut unmatched = legacy.clone();
    unmatched.key = legacy_key("other-missing-session");
    unmatched.session_id = Some("other-missing-session".into());
    unmatched.timestamp_ms = legacy.timestamp_ms.map(|at| at - 120_000);
    put_record(&db.connection, "local", "", &unmatched).unwrap();

    prices
        .entries
        .iter_mut()
        .find(|p| p.provider == "anthropic" && p.model == "claude-sonnet-4")
        .unwrap()
        .rates
        .input_cost_per_token = Some(0.01);
    let current_price = save_snapshot(&mut db, prices).unwrap();
    assert_ne!(old_price, current_price);

    let scan = persist(&mut db, batch).unwrap();
    assert_eq!((scan.added, scan.removed), (2, 1));
    let [first, second, older] = rows(&db)
        .try_into()
        .expect("two observed requests and one historical request");
    assert_eq!((first.tokens.input, second.tokens.input), (100, 200));
    assert_eq!(first.session_id.as_deref(), Some("fork-session"));
    assert_eq!(first.timezone, legacy.timezone);
    assert_eq!(first.date, legacy.date);
    let old_estimate = legacy.estimated_cost_usd.unwrap();
    assert!((first.estimated_cost_usd.unwrap() - old_estimate).abs() < 1e-12);
    assert_eq!(first.price_snapshot_id, legacy.price_snapshot_id);
    assert_eq!(
        second.price_snapshot_id.as_deref(),
        Some(current_price.as_str())
    );
    assert_eq!(second.date, "2026-11-04");
    assert_eq!(older.key, unmatched.key);

    // Another replay appears and then the former winner is removed. Changing
    // session attribution must not create another copy in the ledger.
    let copy = session_dir.join("later.jsonl");
    write_session(&copy, "later-session");
    persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    assert_eq!(rows(&db).len(), 3);
    fs::remove_file(fork).unwrap();
    let scan = persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    assert_eq!((scan.added, scan.removed), (0, 0));
    let saved = rows(&db);
    assert_eq!(saved.len(), 3);
    assert_eq!(saved[0].session_id.as_deref(), Some("later-session"));
    assert!((saved[0].estimated_cost_usd.unwrap() - old_estimate).abs() < 1e-12);
    assert_eq!(saved[0].timezone, legacy.timezone);

    // A partial read and a missing source both preserve the latest snapshot.
    fs::write(&copy, "{partial").unwrap();
    assert_eq!(
        persist(&mut db, collect_once(&config, &mut cache).await.unwrap())
            .unwrap()
            .changed,
        0
    );
    fs::remove_file(copy).unwrap();
    assert_eq!(
        persist(&mut db, collect_once(&config, &mut cache).await.unwrap())
            .unwrap()
            .changed,
        0
    );
    assert_eq!(rows(&db).len(), 3);
}
