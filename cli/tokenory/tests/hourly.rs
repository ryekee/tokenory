use serde_json::json;
use tokenory::{
    db::{put_record, Database},
    queries::{report, Filter},
    usage::UsageRecord,
};

#[test]
fn hourly_uses_beijing_time_all_rows_and_effective_sources() {
    let root = tempfile::tempdir().unwrap();
    let mut db = Database::open(root.path()).unwrap();
    let add = |key: &str,
               client: &str,
               source: &str,
               timestamp: Option<&str>,
               tokens: i64,
               cost: Option<f64>,
               daily: bool| {
        let timestamp = timestamp.map(|s| {
            chrono::DateTime::parse_from_rfc3339(s)
                .unwrap()
                .timestamp_millis()
        });
        let row: UsageRecord = serde_json::from_value(json!({
            "key": key, "client": client, "provider": "test", "model": "m", "date": "2026-11-06",
            "timestampMs": timestamp, "tokens": {"input":tokens,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0},
            "estimatedCostUsd": cost, "metadata": {"granularity": if daily {"day"} else {"request"}}
        })).unwrap();
        put_record(&db.connection, source, "", &row).unwrap();
    };
    add(
        "first",
        "codex",
        "local",
        Some("2026-11-05T16:00:00Z"),
        100,
        Some(0.2),
        false,
    );
    add(
        "second",
        "codex",
        "local",
        Some("2026-11-05T16:59:59Z"),
        200,
        None,
        false,
    );
    add(
        "later",
        "codex",
        "local",
        Some("2026-11-05T17:00:00Z"),
        50,
        None,
        false,
    );
    add("daily", "claude", "history", None, 400, Some(0.5), true);
    add(
        "daily-with-time",
        "claude",
        "history",
        Some("2026-11-05T16:00:00Z"),
        20,
        None,
        true,
    );
    add(
        "mismatched-day",
        "codex",
        "local",
        Some("2026-11-06T16:00:00Z"),
        10,
        None,
        false,
    );
    add(
        "inactive",
        "codex",
        "old",
        Some("2026-11-05T16:00:00Z"),
        9999,
        Some(9.0),
        false,
    );
    db.connection.execute("INSERT INTO coverage_choices VALUES ('2026-11-06','codex','local',''), ('2026-11-06','claude','history','')", []).unwrap();
    let mut filter = Filter {
        from: Some("2026-11-06".into()),
        to: Some("2026-11-06".into()),
        limit: Some(1),
        offset: 1,
        ..Default::default()
    };
    let result = report(&mut db, &filter).unwrap();
    assert_eq!(result.details.len(), 1);
    assert_eq!(result.summary.tokens, 780);
    let hours = result.hourly.unwrap();
    assert_eq!(hours.buckets.len(), 2);
    assert_eq!(hours.buckets[0].key, "2026-11-06T00:00:00+08:00");
    assert_eq!(hours.buckets[0].summary.tokens, 300);
    assert_eq!(hours.buckets[0].summary.known_estimated_cost_usd, Some(0.2));
    assert_eq!(hours.buckets[0].summary.cost_status, "partial");
    assert_eq!(hours.buckets[1].key, "2026-11-06T01:00:00+08:00");
    assert_eq!(hours.buckets[1].summary.known_estimated_cost_usd, None);
    assert_eq!(hours.unallocated.tokens, 430);
    assert_eq!(hours.unallocated.known_estimated_cost_usd, Some(0.5));
    filter.client = Some("codex".into());
    let filtered = report(&mut db, &filter).unwrap();
    assert_eq!(filtered.summary.tokens, 360);
    assert_eq!(filtered.hourly.unwrap().unallocated.tokens, 10);
    filter.model = Some("no-match".into());
    assert!(report(&mut db, &filter)
        .unwrap()
        .hourly
        .unwrap()
        .buckets
        .is_empty());
    filter.to = Some("2026-11-07".into());
    assert!(report(&mut db, &filter).unwrap().hourly.is_none());
}
