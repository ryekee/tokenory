use serde_json::json;
use tokenory::{
    db::{put_record, Database},
    queries::{report, Filter},
    usage::UsageRecord,
};

#[test]
fn local_day_selects_timestamp_window_across_stored_dates_and_keeps_daily_imports() {
    let dir = tempfile::tempdir().unwrap();
    let mut db = Database::open(dir.path()).unwrap();
    let millis = |s: &str| {
        chrono::DateTime::parse_from_rfc3339(s)
            .unwrap()
            .timestamp_millis()
    };
    for (key, date, stamp, tokens, granularity) in [
        ("before", "2026-11-05", "2026-11-05T07:59:59Z", 1, "event"),
        ("start", "2026-11-05", "2026-11-05T08:00:00Z", 10, "event"),
        ("late", "2026-11-06", "2026-11-06T07:59:59Z", 20, "event"),
        ("end", "2026-11-06", "2026-11-06T08:00:00Z", 100, "event"),
        ("daily", "2026-11-05", "2026-11-04T16:00:00Z", 7, "day"),
    ] {
        let record: UsageRecord = serde_json::from_value(json!({
            "key":key,"date":date,"client":"codex","provider":"openai","model":"m",
            "timestampMs":millis(stamp),"tokens":{"input":tokens,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0},
            "estimatedCostUsd":tokens as f64 / 100.0,"metadata":{"granularity":granularity}
        })).unwrap();
        put_record(&db.connection, "local", "", &record).unwrap();
        db.connection
            .execute(
                "INSERT OR IGNORE INTO coverage_choices VALUES (?1,'codex','local','')",
                [date],
            )
            .unwrap();
    }
    let filter = Filter {
        from: Some("2026-11-05".into()),
        to: Some("2026-11-05".into()),
        timestamp_from_ms: Some(millis("2026-11-05T08:00:00Z")),
        timestamp_to_ms: Some(millis("2026-11-06T08:00:00Z")),
        ..Default::default()
    };
    let result = report(&mut db, &filter).unwrap();
    assert_eq!(result.summary.tokens, 37);
    assert!((result.summary.known_estimated_cost_usd.unwrap() - 0.37).abs() < 1e-9);
    assert_eq!(result.clients[0].summary.tokens, 37);
    assert_eq!(result.details.len(), 3);
    let old = report(
        &mut db,
        &Filter {
            from: filter.from.clone(),
            to: filter.to.clone(),
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(old.summary.tokens, 18); // Historical saved dates were not rewritten.
    assert!(Filter {
        timestamp_to_ms: None,
        ..filter.clone()
    }
    .validate()
    .is_err());
    assert!(Filter {
        timestamp_to_ms: filter.timestamp_from_ms,
        ..filter
    }
    .validate()
    .is_err());
}
