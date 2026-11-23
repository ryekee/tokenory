use chrono::{SecondsFormat, TimeZone};
use serde_json::json;
use tokenory::{
    config::Config,
    db::{put_record, Database},
    queries::{report, Filter},
    usage::UsageRecord,
};

#[test]
fn hourly_uses_system_time_for_all_effective_rows() {
    let root = tempfile::tempdir().unwrap();
    let mut db = Database::open(root.path()).unwrap();
    let zone = Config::system_timezone();
    let time = |day, hour, minute, second| {
        zone.with_ymd_and_hms(2026, 11, day, hour, minute, second)
            .earliest().unwrap()
    };
    let add = |key: &str,
               client: &str,
               source: &str,
               timestamp: Option<chrono::DateTime<chrono_tz::Tz>>,
               tokens: i64,
               cost: Option<f64>,
               daily: bool| {
        let timestamp = timestamp.map(|instant| instant.timestamp_millis());
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
        Some(time(6, 0, 0, 0)),
        100,
        Some(0.2),
        false,
    );
    add(
        "second",
        "codex",
        "local",
        Some(time(6, 0, 59, 59)),
        200,
        None,
        false,
    );
    add(
        "later",
        "codex",
        "local",
        Some(time(6, 1, 0, 0)),
        50,
        None,
        false,
    );
    add("daily", "claude", "history", None, 400, Some(0.5), true);
    add(
        "daily-with-time",
        "claude",
        "history",
        Some(time(6, 0, 0, 0)),
        20,
        None,
        true,
    );
    add(
        "mismatched-day",
        "codex",
        "local",
        Some(time(7, 0, 0, 0)),
        10,
        None,
        false,
    );
    add(
        "inactive",
        "codex",
        "old",
        Some(time(6, 0, 0, 0)),
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
    assert_eq!(hours.buckets[0].key, time(6, 0, 0, 0).to_rfc3339_opts(SecondsFormat::Secs, false));
    assert_eq!(hours.buckets[0].summary.tokens, 300);
    assert_eq!(hours.buckets[0].summary.known_estimated_cost_usd, Some(0.2));
    assert_eq!(hours.buckets[0].summary.cost_status, "partial");
    assert_eq!(hours.buckets[1].key, time(6, 1, 0, 0).to_rfc3339_opts(SecondsFormat::Secs, false));
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

#[test]
fn local_hour_keeps_repeated_dst_hours_distinct() {
    let root = tempfile::tempdir().unwrap();
    let db = Database::open(root.path()).unwrap();
    for (utc, local) in [
        ("2026-11-01T05:30:00Z", "2026-11-01T01:00:00-04:00"),
        ("2026-11-01T06:30:00Z", "2026-11-01T01:00:00-05:00"),
    ] {
        let instant = chrono::DateTime::parse_from_rfc3339(utc).unwrap().timestamp_millis();
        let bucket: String = db.connection.query_row(
            "SELECT local_usage_hour(?1, 'America/New_York', '2026-11-01', 1)",
            [instant],
            |row| row.get(0),
        ).unwrap();
        assert_eq!(bucket, local);
    }
}

#[test]
fn device_snapshots_share_a_reporting_day_across_ledger_timezones() {
    let instant = chrono::DateTime::parse_from_rfc3339("2026-11-22T16:30:00Z")
        .unwrap()
        .timestamp_millis();
    for (timezone, archived_day) in [
        ("America/Los_Angeles", "2026-11-22"),
        ("Asia/Shanghai", "2026-11-23"),
    ] {
        let root = tempfile::tempdir().unwrap();
        let mut db = Database::open(root.path()).unwrap();
        for (key, source, day, granularity, tokens) in [
            ("request", "local", archived_day, "event", 50),
            ("import", "tokens-ci", "2026-11-22", "day", 70),
            ("approximate", "local", "2026-11-21", "sourceRecord", 30),
        ] {
            let client = if source == "local" { "codex" } else { "claude" };
            let row: UsageRecord = serde_json::from_value(json!({
                "key":key, "client":client,
                "provider":"openai", "model":"model", "date":day,
                "sessionId":"agent", "timezone":timezone, "timestampMs":instant,
                "tokens":{"input":tokens,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0},
                "metadata":{"granularity":granularity}
            })).unwrap();
            put_record(&db.connection, source, "", &row).unwrap();
            db.connection.execute(
                "INSERT INTO coverage_choices VALUES (?1, ?2, ?3, '')",
                rusqlite::params![day, client, source],
            ).unwrap();
        }
        db.connection.execute(
            "INSERT INTO codex_activity_threads(id,parent_id,depth,name,provider,started_ms,date)
             VALUES ('agent','parent',1,NULL,'openai',?1,?2)",
            rusqlite::params![instant, archived_day],
        ).unwrap();
        let original = report(&mut db, &Filter::default()).unwrap();
        let snapshot = tokenory::device_snapshot::export(&mut db, timezone).unwrap();
        assert_eq!(snapshot.timezone, "Asia/Shanghai");
        let event = snapshot.buckets.iter().find(|row| row.summary.tokens == 50).unwrap();
        assert_eq!((event.date.as_str(), event.hour), ("2026-11-23", Some(0)));
        assert!(event.is_subagent);
        let imported = snapshot.buckets.iter().find(|row| row.source == "tokens-ci").unwrap();
        assert_eq!((imported.date.as_str(), imported.hour), ("2026-11-22", None));
        let unallocated = snapshot.buckets.iter().find(|row| row.summary.tokens == 30).unwrap();
        assert_eq!((unallocated.date.as_str(), unallocated.hour), ("2026-11-21", None));
        assert!(snapshot.subagent_starts.iter().any(|row| {
            row.date == "2026-11-23" && row.model.as_deref() == Some("model")
                && row.nearest_after.as_deref() == Some("2026-11-23")
        }));
        assert_eq!(report(&mut db, &Filter::default()).unwrap().daily.iter().map(|row| &row.key).collect::<Vec<_>>(),
                   original.daily.iter().map(|row| &row.key).collect::<Vec<_>>());
    }
}
