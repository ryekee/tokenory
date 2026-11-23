use serde_json::{json, Value};
use tokenory::{
    collector::{collect_once, persist, DiagnosticCache},
    config::Config,
    db::{put_record, Database},
    queries::{overview, report, Filter},
    usage::UsageRecord,
};

#[tokio::test]
async fn codex_starts_and_effective_usage_are_independent_of_the_main_total() {
    let home = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    let sessions = home.path().join(".codex/sessions");
    std::fs::create_dir_all(&sessions).unwrap();
    let parent = "01912345-1234-7abc-8abc-abcdef123450";
    let child = "01912345-1234-7abc-8abc-abcdef123451";
    let grandchild = "01912345-1234-7abc-8abc-abcdef123452";
    let guard = "01912345-1234-7abc-8abc-abcdef123453";
    let write_rollout =
        |id: &str, day: &str, source: Value, thread_source: &str, tail: &[Value]| {
            let stem = format!("rollout-{day}T09-00-00-{id}");
            let timestamp = format!("{day}T09:00:00.000Z");
            let meta = json!({"type":"session_meta","timestamp":timestamp,"payload":{
                "id":id,"timestamp":timestamp,"source":source,"thread_source":thread_source,
                "model_provider":"openai","agent_nickname":"Analyst"
            }});
            let rows = std::iter::once(&meta)
                .chain(tail)
                .map(Value::to_string)
                .collect::<Vec<_>>();
            std::fs::write(sessions.join(format!("{stem}.jsonl")), rows.join("\n")).unwrap();
            stem
        };
    let main = write_rollout(
        parent,
        "2026-11-19",
        json!("cli"),
        "user",
        &[
            json!({"type":"event_msg","timestamp":"2026-11-21T09:00:00Z","payload":{"type":"task_started","turn_id":"turn-1"}}),
            json!({"type":"turn_context","timestamp":"2026-11-21T09:00:00Z","payload":{"turn_id":"turn-1","model":"child-model"}}),
            json!({"type":"event_msg","timestamp":"2026-11-21T09:00:01Z","payload":{"type":"user_message","message":"Review the results"}}),
        ],
    );
    let child = write_rollout(
        child,
        "2026-11-20",
        json!({"subagent":{"thread_spawn":{
            "parent_thread_id":parent,"depth":1,"agent_nickname":"Worker"
        }}}),
        "subagent",
        &[],
    );
    write_rollout(
        grandchild,
        "2026-11-21",
        json!({"subagent":{"thread_spawn":{
            "parent_thread_id":"01912345-1234-7abc-8abc-abcdef123451","depth":2
        }}}),
        "subagent",
        &[],
    );
    let guard = write_rollout(
        guard,
        "2026-11-21",
        json!({"subagent":{"other":"guardian"}}),
        "guardian_review",
        &[],
    );
    let config = Config {
        home_dir: home.path().into(),
        ..Default::default()
    };
    let mut cache = DiagnosticCache::default();
    let mut db = Database::open(data.path()).unwrap();
    for _ in 0..2 {
        let batch = collect_once(&config, &mut cache).await.unwrap();
        persist(&mut db, batch).unwrap();
    }
    for (key, session, model, tokens, estimate) in [
        ("main", main.as_str(), "main-model", 40, Some(0.5)),
        ("first", child.as_str(), "child-model", 25, Some(0.25)),
        ("second", child.as_str(), "other-model", 10, None),
        ("guard", guard.as_str(), "child-model", 100, Some(1.25)),
        ("unknown", "unknown", "child-model", 200, Some(2.0)),
    ] {
        let record: UsageRecord = serde_json::from_value(json!({
            "key": key, "client": "codex", "provider": "openai", "model": model,
            "date": "2026-11-21", "sessionId": session,
            "estimatedCostUsd": estimate,
            "tokens": {"input": tokens, "output": 0, "cacheRead": 0, "cacheWrite": 0, "reasoning": 0}
        })).unwrap();
        put_record(&db.connection, "local", "", &record).unwrap();
    }
    db.connection
        .execute(
            "INSERT OR IGNORE INTO coverage_choices VALUES ('2026-11-21','codex','local','')",
            [],
        )
        .unwrap();
    let today = Filter {
        from: Some("2026-11-21".into()),
        to: Some("2026-11-21".into()),
        limit: Some(1),
        ..Default::default()
    };
    assert!(report(&mut db, &today).unwrap().codex_subagents.is_none());
    std::fs::write(
        home.path().join(".codex/session_index.jsonl"),
        json!({"id":parent,"thread_name":"Check the ledger"}).to_string(),
    )
    .unwrap();
    let raw = serde_json::to_value(overview(&mut db, &today, home.path()).unwrap()).unwrap();
    let snapshot = tokenory::device_snapshot::export(&mut db, &config.timezone).unwrap();
    let child_buckets = snapshot.buckets.iter().filter(|r| r.is_subagent).collect::<Vec<_>>();
    assert_eq!(child_buckets.iter().map(|r| r.summary.tokens).sum::<i64>(), 35);
    assert_eq!(child_buckets.iter().filter_map(|r| r.summary.known_estimated_cost_usd).sum::<f64>(), 0.25);
    assert_eq!(child_buckets.iter().map(|r| r.summary.unpriced_tokens).sum::<i64>(), 10);
    let starts_today = snapshot.subagent_starts.iter().filter(|s| s.date == "2026-11-21"
        && s.provider.is_none() && s.model.is_none()).map(|s| s.count).sum::<i64>();
    assert_eq!(starts_today, 1);
    assert!(snapshot.subagent_starts.iter().any(|s| s.date == "2026-11-20"
        && s.model.as_deref() == Some("child-model") && s.nearest_after.as_deref() == Some("2026-11-21")));
    let published = serde_json::to_string(&snapshot).unwrap();
    for private_text in [parent, "rollout-", "Check the ledger", "agent_nickname", "sessionId", "item_key"] {
        assert!(!published.contains(private_text));
    }
    assert_eq!(raw["summary"]["tokens"], 375);
    assert_eq!(raw["clients"][0]["summary"]["knownEstimatedCostUsd"], 4.0);
    assert_eq!(raw["codexSubagents"]["starts"], 1);
    assert_eq!(raw["codexSubagents"]["tokens"], 35);
    let cost = json!({"knownEstimatedCostUsd": 0.25, "unpricedTokens": 10});
    assert_eq!(raw["codexSubagents"]["cost"], cost);
    let conversation = &raw["codexSubagents"]["conversations"][0];
    assert_eq!(conversation["id"], parent);
    assert_eq!(conversation["title"], "Check the ledger");
    assert_eq!(conversation["mainTurns"], 1);
    assert_eq!(conversation["mainTokens"], 40);
    assert_eq!(conversation["cost"], cost);
    let models = conversation["agents"]
        .as_array()
        .unwrap()
        .iter()
        .find(|agent| agent["starts"] == 0)
        .unwrap()["models"]
        .as_array()
        .unwrap();
    assert_eq!(
        models[0]["cost"],
        json!({"knownEstimatedCostUsd": 0.25, "unpricedTokens": 0})
    );
    assert_eq!(
        models[1]["cost"],
        json!({"knownEstimatedCostUsd": null, "unpricedTokens": 10})
    );
    assert_eq!(conversation["agents"].as_array().unwrap().len(), 2);
    assert!(conversation["agents"]
        .as_array()
        .unwrap()
        .iter()
        .any(|agent| agent["starts"] == 0 && agent["models"].as_array().unwrap().len() == 2));

    let model_filter = Filter {
        model: Some("child-model".into()),
        ..today.clone()
    };
    let raw = serde_json::to_value(overview(&mut db, &model_filter, home.path()).unwrap()).unwrap();
    assert_eq!(raw["codexSubagents"]["tokens"], 25);
    assert_eq!(
        raw["codexSubagents"]["cost"],
        json!({"knownEstimatedCostUsd": 0.25, "unpricedTokens": 0})
    );
    assert_eq!(raw["codexSubagents"]["starts"], 0);
    assert_eq!(raw["codexSubagents"]["conversations"][0]["mainTurns"], 1);

    use std::io::Write;
    let mut rollout = std::fs::OpenOptions::new()
        .append(true)
        .open(sessions.join(format!("{main}.jsonl")))
        .unwrap();
    writeln!(
        rollout,
        "\n{}\n{}",
        json!({"type":"turn_context","timestamp":"2026-11-21T09:00:02Z","payload":{"turn_id":"turn-1","model":"other-model"}}),
        json!({"type":"event_msg","timestamp":"2026-11-21T09:00:03Z","payload":{"type":"turn_aborted","turn_id":"turn-1"}}),
    ).unwrap();
    let batch = collect_once(&config, &mut cache).await.unwrap();
    persist(&mut db, batch).unwrap();
    let raw = serde_json::to_value(overview(&mut db, &model_filter, home.path()).unwrap()).unwrap();
    assert!(raw["codexSubagents"]["conversations"][0]["mainTurns"].is_null());
    let raw = serde_json::to_value(overview(&mut db, &today, home.path()).unwrap()).unwrap();
    assert_eq!(raw["codexSubagents"]["conversations"][0]["mainTurns"], 1);

    let main_only = Filter {
        model: Some("main-model".into()),
        ..today.clone()
    };
    let main_only = overview(&mut db, &main_only, home.path()).unwrap();
    assert_eq!(main_only.summary.tokens, 40);
    assert!(main_only.codex_subagents.is_none());

    let zero_usage: UsageRecord = serde_json::from_value(json!({
        "key": "empty-usage", "client": "codex", "provider": "openai", "model": "child-model",
        "date": "2026-11-22", "sessionId": child, "estimatedCostUsd": 0.0,
        "tokens": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "reasoning": 0}
    }))
    .unwrap();
    put_record(&db.connection, "local", "", &zero_usage).unwrap();
    db.connection
        .execute(
            "INSERT INTO coverage_choices VALUES ('2026-11-22','codex','local','')",
            [],
        )
        .unwrap();
    let no_activity = Filter {
        from: Some("2026-11-22".into()),
        to: Some("2026-11-22".into()),
        ..today.clone()
    };
    assert!(overview(&mut db, &no_activity, home.path())
        .unwrap()
        .codex_subagents
        .is_none());

    let backup = data.path().join("subagent-history.sqlite3");
    db.backup(&backup).unwrap();
    db.connection.execute("UPDATE coverage_choices SET source='import', batch_id='chosen' WHERE date='2026-11-21' AND client='codex'", []).unwrap();
    let raw = serde_json::to_value(overview(&mut db, &today, home.path()).unwrap()).unwrap();
    assert_eq!(raw["codexSubagents"]["starts"], 1);
    assert_eq!(raw["codexSubagents"]["tokens"], 0);
    assert_eq!(
        raw["codexSubagents"]["cost"],
        json!({"knownEstimatedCostUsd": null, "unpricedTokens": 0})
    );
    db.restore(&backup).unwrap();
    let restored = overview(&mut db, &today, home.path())
        .unwrap()
        .codex_subagents
        .unwrap();
    assert_eq!((restored.starts, restored.tokens), (1, 35));
    assert_eq!(restored.conversations[0].main_turns, Some(1));
}
