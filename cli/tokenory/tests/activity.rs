use serde_json::json;
use tokenory::{db::{put_record, Database}, queries::{activity, Filter}, usage::UsageRecord};

#[test]
fn activity_uses_effective_rows_and_preserves_unknown_costs() {
    let root = tempfile::tempdir().unwrap();
    let mut db = Database::open(root.path()).unwrap();
    for (key, date, client, source, model, tokens, cost) in [
        ("a", "2026-11-01", "codex", "local", "m", 100, Some(1.0)),
        ("b", "2026-11-01", "codex", "local", "m", 200, None),
        ("duplicate", "2026-11-01", "codex", "old", "m", 9999, Some(99.0)),
        ("c", "2026-11-01", "claude", "local", "m", 50, Some(0.0)),
        ("d", "2026-11-02", "codex", "local", "other", 30, None),
        ("e", "2026-11-03", "codex", "local", "m", 0, None),
    ] {
        let row: UsageRecord = serde_json::from_value(json!({
            "key":key,"date":date,"client":client,"provider":"test","model":model,
            "tokens":{"input":tokens,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0},
            "estimatedCostUsd":cost
        })).unwrap();
        put_record(&db.connection, source, "", &row).unwrap();
    }
    db.connection.execute("INSERT INTO coverage_choices VALUES ('2026-11-01','codex','local',''),('2026-11-01','claude','local',''),('2026-11-02','codex','local',''),('2026-11-03','codex','local','')", []).unwrap();
    let mut filter = Filter { from: Some("2026-11-01".into()), to: Some("2026-11-03".into()), limit: Some(1), offset: 100, ..Default::default() };
    let result = activity(&mut db, &filter).unwrap();
    assert_eq!(result.model_days.len(), 4);
    assert_eq!(result.daily.iter().map(|d| d.summary.tokens).sum::<i64>(), 380);
    let codex = result.model_days.iter().find(|d| d.date == "2026-11-01" && d.client == "codex").unwrap();
    assert_eq!(codex.summary.tokens, 300);
    assert_eq!(codex.summary.unpriced_tokens, 200);
    assert_eq!(codex.summary.known_estimated_cost_usd, Some(1.0));
    assert_eq!(codex.summary.cost_status, "partial");
    assert_eq!(result.daily[2].summary.active_days, 0);
    assert_eq!(result.model_days.iter().find(|d| d.model == "other").unwrap().summary.known_estimated_cost_usd, None);
    filter.client = Some("codex".into()); filter.model = Some("m".into());
    assert_eq!(activity(&mut db, &filter).unwrap().model_days.len(), 2);
    filter.provider = Some("no-match".into());
    assert!(activity(&mut db, &filter).unwrap().daily.is_empty());
    filter.from = None;
    assert!(activity(&mut db, &filter).is_err());
    filter.from = Some("2024-01-01".into());
    assert!(activity(&mut db, &filter).is_err());
}

#[test]
fn activity_hourly_patterns_combine_days_and_exclude_daily_imports() {
    let root = tempfile::tempdir().unwrap();
    let mut db = Database::open(root.path()).unwrap();
    for (key, date, time, tokens, granularity) in [
        ("a", "2026-11-01", "2026-11-01T01:00:00Z", 10, "event"),
        ("b", "2026-11-02", "2026-11-02T01:30:00Z", 20, "event"),
        ("c", "2026-11-02", "2026-11-02T15:59:00Z", 40, "event"),
        ("daily", "2026-11-02", "2026-11-02T01:00:00Z", 100, "day"),
        ("mismatch", "2026-11-02", "2026-11-01T01:00:00Z", 200, "event"),
    ] {
        let timestamp = chrono::DateTime::parse_from_rfc3339(time).unwrap().timestamp_millis();
        let row: UsageRecord = serde_json::from_value(json!({
            "key": key, "date": date, "client": "codex", "provider": "test", "model": "m",
            "timestampMs": timestamp, "metadata": {"granularity": granularity},
            "tokens": {"input": tokens, "output": 0, "cacheRead": 0, "cacheWrite": 0, "reasoning": 0}
        })).unwrap();
        put_record(&db.connection, "local", "", &row).unwrap();
    }
    db.connection.execute("INSERT INTO coverage_choices VALUES ('2026-11-01','codex','local',''),('2026-11-02','codex','local','')", []).unwrap();
    let filter = Filter { from: Some("2026-11-01".into()), to: Some("2026-11-02".into()), ..Default::default() };
    let report = activity(&mut db, &filter).unwrap();
    assert_eq!(report.hourly.buckets.len(), 2);
    assert_eq!(report.hourly.buckets[0].key, "09");
    assert_eq!(report.hourly.buckets[0].summary.tokens, 30);
    assert_eq!(report.hourly.buckets[1].key, "23");
    assert_eq!(report.hourly.buckets[1].summary.tokens, 40);
    assert_eq!(report.hourly.unallocated.tokens, 300);
    let filtered = activity(&mut db, &Filter { model: Some("absent".into()), ..filter }).unwrap();
    assert!(filtered.hourly.buckets.is_empty());
}
