use serde_json::{json, Value};
use tokenory::{
    codex_turns::{parse, persist, query},
    db::Database,
    queries::Filter,
};
fn events() -> Vec<Value> {
    vec![
        json!({"type":"session_meta","payload":{"id":"s","cwd":"/private/project","source":"cli"}}),
        json!({"type":"event_msg","payload":{"type":"task_started","turn_id":"t"}}),
        json!({"type":"turn_context","payload":{"turn_id":"t","model":"model-a","effort":"medium"}}),
        json!({"type":"token_usage_record","payload":{"turn_id":"t","response_id":"r","usage":{"output_tokens":100,"reasoning_output_tokens":20},"turn_token_usage":{"output_tokens":100,"reasoning_output_tokens":20}}}),
        json!({"type":"event_msg","timestamp":"2026-11-14T00:00:10Z","payload":{"type":"task_complete","turn_id":"t","duration_ms":10000,"time_to_first_token_ms":200}}),
    ]
}
fn parsed(e: &[Value]) -> Vec<tokenory::codex_turns::CodexTurn> {
    let lines = e
        .iter()
        .map(Value::to_string)
        .collect::<Vec<_>>()
        .join("\n");
    parse(std::io::Cursor::new(lines)).unwrap()
}

#[test]
fn codex_speed_uses_the_turns_model_and_own_settings_at_start() {
    let settings = |thread: &str, tier: &str| {
        json!({
            "type": "event_msg",
            "payload": {
                "type": "thread_settings_applied",
                "thread_id": thread,
                "thread_settings": {"model": "model-a", "service_tier": tier}
            }
        })
    };
    let mut e = events();
    e.insert(1, settings("s", "priority"));
    e.insert(2, settings("other-thread", "default"));
    e.insert(5, settings("s", "default"));
    e.insert(6, e[4].clone()); // Repeated context must not relabel a running turn.
    let speed = |events: &[Value]| {
        serde_json::to_value(&parsed(events)[0]).unwrap()["inferenceSpeed"].clone()
    };
    assert_eq!(speed(&e), json!({"speed":"fast","source":"selected"}));

    let mut e = events();
    e.insert(1, settings("s", "fast"));
    e[3]["payload"]["model"] = json!("other-model");
    assert!(speed(&e).is_null());

    let mut e = events();
    e.insert(1, settings("s", "priority"));
    e.insert(2, settings("s", "auto")); // An explicit reset does not carry over Fast.
    assert!(speed(&e).is_null());
    assert!(speed(&events()).is_null());
}

#[test]
fn deduplicates_and_rejects_incomplete_or_invalid_usage() {
    let mut e = events();
    e.insert(4, e[3].clone());
    let t = parsed(&e);
    assert_eq!(t.len(), 1);
    assert_eq!(t[0].generated_tokens, 100);
    assert_eq!(t[0].requests, Some(1));
    e[3]["payload"]["usage"]["output_tokens"] = 101.into();
    assert!(parsed(&e).is_empty());
    let mut e = events();
    e.pop();
    assert!(parsed(&e).is_empty());
    let mut e = events();
    e.remove(3);
    assert!(parsed(&e).is_empty());
    let mut e = events();
    e[0]["payload"]["source"] = json!({"subagent":{}});
    assert!(parsed(&e).is_empty());
}
#[test]
fn missing_reasoning_and_ttft_are_unknown() {
    let mut e = events();
    e[3]["payload"]["usage"]
        .as_object_mut()
        .unwrap()
        .remove("reasoning_output_tokens");
    e[3]["payload"]["turn_token_usage"]
        .as_object_mut()
        .unwrap()
        .remove("reasoning_output_tokens");
    e[4]["payload"]
        .as_object_mut()
        .unwrap()
        .remove("time_to_first_token_ms");
    let t = parsed(&e);
    assert_eq!(t[0].reasoning_tokens, None);
    assert_eq!(t[0].ttft_ms, None);
}
#[test]
fn tool_union_uses_submission_and_return_only() {
    let mut e = events();
    for (typ, id, sec) in [
        ("function_call", "a", 2),
        ("custom_tool_call", "b", 3),
        ("function_call_output", "a", 4),
        ("custom_tool_call_output", "b", 5),
    ] {
        e.insert(e.len()-1,json!({"type":"response_item","timestamp":format!("2026-11-14T00:00:0{sec}Z"),"payload":{"type":typ,"call_id":id,"create_time":"2026-11-14T00:00:00Z"}}));
    }
    e.insert(e.len()-1,json!({"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution"},"started_at_ms":0,"completed_at_ms":9999999999999i64}}));
    let t = parsed(&e);
    assert_eq!(t[0].tool_calls, Some(2));
    assert_eq!(t[0].tool_wait_ms, Some(3000));
    let duplicate = e[4].clone();
    e.insert(e.len() - 1, duplicate);
    assert_eq!(parsed(&e)[0].tool_calls, Some(2));
}
#[test]
fn persistence_catalog_dates_and_restore() {
    let dir = tempfile::tempdir().unwrap();
    let mut db = Database::open(dir.path()).unwrap();
    let mut turns = parsed(&events());
    let mut second = turns[0].clone();
    second.id = "second".into();
    second.model = "model-b".into();
    turns.push(second);
    assert_eq!(persist(&db.connection, &turns, "Asia/Shanghai").unwrap(), 2);
    assert_eq!(persist(&db.connection, &turns, "Asia/Shanghai").unwrap(), 0);
    let f = Filter {
        from: Some("2026-11-14".into()),
        to: Some("2026-11-14".into()),
        model: Some("model-a".into()),
        ..Default::default()
    };
    let r = query(&mut db, &f).unwrap();
    assert_eq!(r.models, vec!["model-a", "model-b"]);
    assert_eq!(r.turns.len(), 1);
    assert!(r.turns[0].inference_speed.is_none());
    turns[0].inference_speed = tokens_core::speed::InferenceSpeed::codex(Some("priority"));
    assert_eq!(persist(&db.connection, &turns, "Asia/Shanghai").unwrap(), 1);
    assert_eq!(persist(&db.connection, &turns, "Asia/Shanghai").unwrap(), 0);
    let f = Filter {
        to: Some("2026-11-13".into()),
        ..Default::default()
    };
    assert!(query(&mut db, &f).unwrap().turns.is_empty());
    let backup = dir.path().join("backup.sqlite3");
    db.backup(&backup).unwrap();
    db.connection
        .execute("DELETE FROM codex_turns", [])
        .unwrap();
    db.restore(&backup).unwrap();
    let restored = query(&mut db, &Filter::default()).unwrap().turns;
    assert_eq!(restored.len(), 2);
    assert_eq!(restored[0].inference_speed, turns[0].inference_speed);
}
#[test]
fn malformed_timing_usage_and_abort_are_safe() {
    let mut e = events();
    e[4]["payload"]["duration_ms"] = (-1).into();
    assert!(parsed(&e).is_empty());
    let mut e = events();
    e[3]["payload"]["turn_token_usage"]["output_tokens"] = 101.into();
    assert!(parsed(&e).is_empty());
    let mut e = events();
    e[3]["payload"]["usage"]["reasoning_output_tokens"] = 101.into();
    assert!(parsed(&e).is_empty());
    let mut e = events();
    e.insert(
        4,
        json!({"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"t"}}),
    );
    assert!(parsed(&e).is_empty());
    let mut e = events();
    e.insert(4,json!({"type":"response_item","timestamp":"bad","payload":{"type":"function_call","call_id":"a"}}));
    let t = parsed(&e);
    assert_eq!(t[0].tool_wait_ms, None);
    let mut e = events();
    e[4]["payload"]["time_to_first_token_ms"] = 10001.into();
    assert_eq!(parsed(&e)[0].ttft_ms, None);
    let mut e = events();
    e.insert(4,json!({"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"output_tokens":10000}}}}));
    assert_eq!(parsed(&e)[0].generated_tokens, 100);
}
#[tokio::test]
async fn extra_paths_scan_and_unchanged_revision() {
    use tokenory::{
        collector::{collect_once, persist as save, DiagnosticCache},
        config::Config,
    };
    let home = tempfile::tempdir().unwrap();
    let extra = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    let file = extra.path().join("rollout-test.jsonl");
    std::fs::write(
        &file,
        events()
            .iter()
            .map(Value::to_string)
            .collect::<Vec<_>>()
            .join("\n"),
    )
    .unwrap();
    let mut config = Config {
        home_dir: home.path().into(),
        ..Default::default()
    };
    config
        .extra_scan_paths
        .insert("codex".into(), vec![extra.path().into()]);
    let mut cache = DiagnosticCache::default();
    let mut db = Database::open(data.path()).unwrap();
    let first = save(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    assert_eq!(query(&mut db, &Filter::default()).unwrap().turns.len(), 1);
    assert!(first.changed > 0);
    let second = save(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    assert_eq!(second.changed, 0);
    assert_eq!(first.revision, second.revision);
}
#[test]
fn cache_reuses_unchanged_file_and_refreshes_changed_file() {
    use tokenory::codex_turns::Cache;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("events.jsonl");
    let body = events()
        .iter()
        .map(Value::to_string)
        .collect::<Vec<_>>()
        .join("\n");
    std::fs::write(&path, &body).unwrap();
    let mut cache = Cache::default();
    assert_eq!(cache.read(&path).unwrap().len(), 1);
    let metadata = std::fs::metadata(&path).unwrap();
    std::fs::write(&path, " ".repeat(body.len())).unwrap();
    std::fs::File::options()
        .write(true)
        .open(&path)
        .unwrap()
        .set_times(std::fs::FileTimes::new().set_modified(metadata.modified().unwrap()))
        .unwrap();
    assert_eq!(
        cache.read(&path).unwrap().len(),
        1,
        "same metadata must reuse parsed turns"
    );
    std::fs::write(&path, "").unwrap();
    assert!(cache.read(&path).unwrap().is_empty());
}
#[test]
fn legacy_restore_adds_turn_schema() {
    let dir = tempfile::tempdir().unwrap();
    let db = Database::open(dir.path()).unwrap();
    db.connection
        .execute_batch("DROP TABLE codex_main_turn_starts; DROP TABLE codex_activity_aliases; DROP TABLE codex_activity_threads; DROP TABLE codex_turns; PRAGMA user_version=3;")
        .unwrap();
    let backup = dir.path().join("old.sqlite3");
    db.backup(&backup).unwrap();
    drop(db);
    let mut db = Database::open(dir.path()).unwrap();
    assert!(query(&mut db, &Filter::default()).unwrap().turns.is_empty());
    db.restore(&backup).unwrap();
    assert!(query(&mut db, &Filter::default()).unwrap().turns.is_empty());
    assert_eq!(
        db.connection
            .query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        6
    );
}
#[test]
fn fork_replay_and_external_sessions_are_not_attributed_to_codex() {
    let mut e = events();
    e[0]["payload"]["forked_from_id"] = "parent".into();
    assert!(parsed(&e).is_empty());
    let mut e = events();
    e[0]["payload"]["originator"] = "openclaw".into();
    assert!(parsed(&e).is_empty());
    let mut e = events();
    e.insert(
        1,
        json!({"type":"session_meta","payload":{"id":"parent","source":"cli"}}),
    );
    assert!(parsed(&e).is_empty());
}
