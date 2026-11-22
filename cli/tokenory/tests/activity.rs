use serde_json::json;
use tokenory::{db::{put_record, Database}, queries::{activity, conversations, report, ConversationId, ConversationQuery, Filter}, usage::UsageRecord};

#[test]
fn conversation_selection_is_client_scoped_and_precedes_pagination() {
    let root = tempfile::tempdir().unwrap();
    let mut db = Database::open(root.path()).unwrap();
    for (key, date, client, session, tokens) in [
        ("first", "2026-11-01", "codex", Some("session_1"), 10),
        ("latest", "2026-11-02", "codex", Some("session_1"), 20),
        ("other", "2026-11-02", "codex", Some("session-2"), 50),
        ("same_id", "2026-11-02", "claude", Some("session_1"), 100),
        ("no_id", "2026-11-02", "claude", None, 150),
    ] {
        let row: UsageRecord = serde_json::from_value(json!({
            "key": key, "date": date, "client": client, "provider": "test", "model": "model",
            "sessionId": session,
            "timestampMs": match key {
                "latest" => Some(1793606400000_i64),
                "other" => Some(1793602800000_i64),
                _ => None,
            },
            "tokens": {"input": tokens, "output": 0, "cacheRead": 0, "cacheWrite": 0, "reasoning": 0}
        })).unwrap();
        put_record(&db.connection, "local", "", &row).unwrap();
    }
    db.connection.execute_batch(
        "INSERT INTO coverage_choices VALUES
        ('2026-11-01','codex','local',''),('2026-11-02','codex','local',''),('2026-11-02','claude','local','');"
    ).unwrap();
    let filters = Filter { limit: Some(1), offset: 1, conversation: Some(ConversationId {
        client: "codex".into(), session_id: "session_1".into(),
    }), ..Default::default() };
    let scoped = report(&mut db, &filters).unwrap();
    assert_eq!(scoped.summary.record_count, 2);
    assert_eq!(scoped.summary.tokens, 30);
    assert_eq!(scoped.details[0].record.key, "first");

    let lookup = |filter, search: &str| serde_json::to_value(conversations(&db, root.path(), ConversationQuery {
        filter, search: search.into(),
    }).unwrap()).unwrap();
    let matches = lookup(filters.clone(), "SESSION_");
    assert_eq!(matches.as_array().unwrap().len(), 2);
    assert!(matches.as_array().unwrap().iter().all(|row| row["id"]["sessionId"] == "session_1"));
    let recent = lookup(filters.clone(), "");
    let recent = recent.as_array().unwrap();
    assert_eq!(recent.len(), 3);
    assert_eq!(recent[0]["id"]["sessionId"], "session_1");
    assert_eq!(recent[0]["id"]["client"], "codex");
    assert_eq!(recent[1]["id"]["sessionId"], "session-2");
    assert_eq!(recent[2]["id"]["client"], "claude");
    let date = Filter { to: Some("2026-11-01".into()), ..filters };
    assert_eq!(lookup(date, "")[0]["lastDate"], "2026-11-01");
}

#[test]
fn conversation_title_search_uses_latest_indexed_name_before_the_result_limit() {
    let root = tempfile::tempdir().unwrap();
    let db = Database::open(root.path()).unwrap();
    let codex = root.path().join(".codex");
    std::fs::create_dir(&codex).unwrap();
    let thread = "01912345-1234-7abc-8abc-abcdef123456";
    let rollout = format!("rollout-2026-11-01T09-00-00-{thread}");
    let index = [
        json!({"id": thread, "thread_name": "Previous title"}).to_string(),
        "invalid record".into(),
        json!({"id": thread, "thread_name": "  Review\n仪表盘  "}).to_string(),
        json!({"id": thread, "thread_name": " "}).to_string(),
    ];
    std::fs::write(codex.join("session_index.jsonl"), index.join("\n")).unwrap();
    let row = |key: &str, date: &str, client: &str, session: &str| {
        let record: UsageRecord = serde_json::from_value(json!({
            "key": key, "date": date, "client": client, "provider": "test", "model": "model",
            "sessionId": session,
            "tokens": {"input": 1, "output": 0, "cacheRead": 0, "cacheWrite": 0, "reasoning": 0}
        })).unwrap();
        put_record(&db.connection, "local", "", &record).unwrap();
    };
    for i in 0..100 {
        let key = format!("recent-{i}");
        row(&key, "2026-11-02", "codex", &key);
    }
    row("older", "2026-11-01", "codex", &rollout);
    row("same-id-other-client", "2026-11-01", "claude", &rollout);
    db.connection.execute_batch(
        "INSERT INTO coverage_choices VALUES
        ('2026-11-01','codex','local',''),('2026-11-02','codex','local',''),('2026-11-01','claude','local','');"
    ).unwrap();

    let lookup = |search: &str| conversations(&db, root.path(), ConversationQuery {
        filter: Filter::default(), search: search.into(),
    }).unwrap();
    let recent = lookup("");
    assert_eq!(recent.len(), 100);
    assert!(recent.iter().all(|option| option.title.is_none()));
    assert!(lookup("Previous title").is_empty());
    let matches = lookup("REVIEW 仪表盘");
    assert_eq!(matches.len(), 1);
    assert_eq!(matches[0].title.as_deref(), Some("Review 仪表盘"));
    assert_eq!(matches[0].id.session_id, rollout);
    let id_matches = lookup(thread);
    assert_eq!(id_matches.len(), 2);
    assert!(id_matches.iter().any(|option| option.id.client == "claude" && option.title.is_none()));
}

#[test]
fn fast_usage_is_a_filtered_subset_of_effective_usage_and_known_cost() {
    let root = tempfile::tempdir().unwrap();
    let mut db = Database::open(root.path()).unwrap();
    for (key, source, model, tokens, cost, speed) in [
        ("a", "local", "codex-model", 100, Some(0.125), json!({"speed":"fast","source":"selected"})),
        ("b", "local", "codex-model", 20, Some(0.625), json!({"speed":"fast","source":"reported"})),
        ("c", "local", "codex-model", 50, Some(0.25), json!({"speed":"ultrafast","source":"selected"})),
        ("d", "local", "codex-model", 10, Some(0.125), json!({"speed":"fast"})),
        ("e", "local", "legacy-model", 5, Some(0.125), json!(null)),
        ("f", "local", "unpriced-model", 4, None, json!({"speed":"fast","source":"selected"})),
        ("duplicate", "old", "codex-model", 9999, Some(99.0), json!({"speed":"fast","source":"selected"})),
    ] {
        let row: UsageRecord = serde_json::from_value(json!({
            "key": key, "date": "2026-11-01", "client": "codex", "provider": "test", "model": model,
            "tokens": {"input": tokens, "output": 0, "cacheRead": 0, "cacheWrite": 0, "reasoning": 0},
            "metadata": {"inferenceSpeed": speed}, "estimatedCostUsd": cost,
        })).unwrap();
        put_record(&db.connection, source, "", &row).unwrap();
    }
    db.connection
        .execute("INSERT INTO coverage_choices VALUES ('2026-11-01','codex','local','')", [])
        .unwrap();
    let filter = Filter { limit: Some(1), offset: 500, ..Default::default() };
    let result = report(&mut db, &filter).unwrap();
    assert!(result.details.is_empty());
    assert_eq!(result.summary.tokens, 189);
    assert_eq!(result.summary.known_estimated_cost_usd, Some(1.25));
    let report_payload = serde_json::to_value(&result).unwrap();
    assert_eq!(report_payload["summary"]["fastTokens"], 124);
    assert_eq!(report_payload["summary"]["fastEstimatedCostUsd"], 0.75);
    assert_eq!(report_payload["clients"][0]["summary"]["fastTokens"], 124);
    assert_eq!(report_payload["clients"][0]["summary"]["fastEstimatedCostUsd"], 0.75);
    assert_eq!(report_payload["models"][0]["summary"]["fastTokens"], 120);
    assert_eq!(report_payload["models"][0]["summary"]["fastEstimatedCostUsd"], 0.75);
    assert!(report_payload["models"][1]["summary"].get("fastTokens").is_none());
    assert!(report_payload["models"][1]["summary"].get("fastEstimatedCostUsd").is_none());
    assert_eq!(report_payload["models"][2]["summary"]["fastTokens"], 4);
    assert!(report_payload["models"][2]["summary"].get("fastEstimatedCostUsd").is_none());
    let filter = Filter { model: Some("legacy-model".into()), ..filter };
    let filtered_payload = serde_json::to_value(report(&mut db, &filter).unwrap()).unwrap();
    assert!(filtered_payload["summary"].get("fastTokens").is_none());
    assert!(filtered_payload["summary"].get("fastEstimatedCostUsd").is_none());
}

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
