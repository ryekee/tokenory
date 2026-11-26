use serde_json::{json, Value};
use tokenory::{
    codex_turns,
    db::Database,
    queries::Filter,
    turn_analytics::{parse_claude, parse_devin, parse_opencode, query},
};
fn claude() -> Vec<Value> {
    vec![
        json!({"type":"user","uuid":"u","sessionId":"s","timestamp":"2026-11-14T00:00:00Z","cwd":"/private/p","message":{"content":"private text"}}),
        json!({"type":"assistant","sessionId":"s","timestamp":"2026-11-14T00:00:01Z","message":{"id":"r1","model":"claude","usage":{"output_tokens":100},"content":[{"type":"tool_use","id":"tool1"}],"stop_reason":"tool_use"}}),
        json!({"type":"user","sessionId":"s","timestamp":"2026-11-14T00:00:03Z","message":{"content":[{"type":"tool_result","tool_use_id":"tool1"}]}}),
        json!({"type":"assistant","sessionId":"s","timestamp":"2026-11-14T00:00:05Z","message":{"id":"r2","model":"claude","usage":{"output_tokens":20},"stop_reason":"end_turn"}}),
    ]
}
fn parsed(v: &[Value]) -> Vec<codex_turns::CodexTurn> {
    parse_claude(std::io::Cursor::new(
        v.iter()
            .map(Value::to_string)
            .collect::<Vec<_>>()
            .join("\n"),
    ))
    .unwrap()
}

#[test]
fn claude_turn_speed_requires_consistent_reports_for_all_replies() {
    let speed = |events: &[Value]| {
        serde_json::to_value(&parsed(events)[0]).unwrap()["inferenceSpeed"].clone()
    };
    let mut e = claude();
    e[1]["message"]["usage"]["service_tier"] = json!("priority");
    assert!(speed(&e).is_null());
    e[1]["message"]["usage"]["speed"] = json!("fast");
    assert!(speed(&e).is_null());
    e[3]["message"]["usage"]["speed"] = json!("fast");
    assert_eq!(speed(&e), json!({"speed":"fast","source":"reported"}));
    e[3]["message"]["usage"]["speed"] = json!("standard");
    assert!(speed(&e).is_null());
}

#[test]
fn claude_completed_main_turns_deduplicate_blocks_and_exclude_tools_from_input() {
    let mut e = claude();
    e.insert(2, e[1].clone());
    let turns = parsed(&e);
    assert_eq!(turns.len(), 1);
    let t = &turns[0];
    assert_eq!(t.generated_tokens, 120);
    assert_eq!(t.requests, Some(2));
    assert_eq!(t.duration_ms, 5000);
    assert!(t.duration_estimated);
    assert_eq!(t.reasoning_tokens, None);
    assert_eq!(t.ttft_ms, None);
    assert_eq!(t.tool_wait_ms, None);
    assert_eq!(t.tool_calls, Some(1));
    e.last_mut().unwrap()["isSidechain"] = true.into();
    assert!(parsed(&e).is_empty());
    let mut e = claude();
    e.pop();
    assert!(parsed(&e).is_empty());
    let mut e = claude();
    e[1]["message"]["usage"]["output_tokens"] = (-1i64).into();
    assert!(parsed(&e).is_empty());
}
#[test]
fn claude_missing_reasoning_is_not_zero_and_mixed_models_are_excluded() {
    let mut e = claude();
    e[1]["message"]["usage"]["output_tokens_details"] = json!({"thinking_tokens":0});
    e[3]["message"]["usage"]["output_tokens_details"] = json!({"thinking_tokens":0});
    assert_eq!(parsed(&e)[0].reasoning_tokens, Some(0));
    e[3]["message"]["model"] = "other".into();
    assert!(parsed(&e).is_empty());
}
#[test]
fn devin_uses_authoritative_main_chain_and_explicit_completion() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("sessions.db");
    let c = rusqlite::Connection::open(&path).unwrap();
    c.execute_batch("CREATE TABLE sessions(id TEXT,working_directory TEXT,main_chain_id INTEGER);CREATE TABLE message_nodes(session_id TEXT,node_id INTEGER,parent_node_id INTEGER,chat_message TEXT);INSERT INTO sessions VALUES('s','/private/p',3);").unwrap();
    for (id, parent, d) in [
        (
            1,
            None,
            json!({"role":"user","message_id":"u","metadata":{"is_user_input":true,"created_at":"2026-11-14T00:00:00Z"}}),
        ),
        (
            2,
            Some(1),
            json!({"role":"assistant","metadata":{"request_id":"r1","generation_model":"devin","metrics":{"output_tokens":100},"finish_reason":"tool_calls","created_at":"2026-11-14T00:00:01Z"},"tool_calls":[{"id":"tool"}]}),
        ),
        (
            3,
            Some(2),
            json!({"role":"assistant","metadata":{"request_id":"r2","generation_model":"devin","metrics":{"output_tokens":20},"finish_reason":"stop","created_at":"2026-11-14T00:00:05Z"}}),
        ),
        (
            4,
            Some(1),
            json!({"role":"assistant","metadata":{"request_id":"branch","generation_model":"other","metrics":{"output_tokens":999},"finish_reason":"stop","created_at":"2026-11-14T00:00:05Z"}}),
        ),
    ] {
        c.execute(
            "INSERT INTO message_nodes VALUES('s',?1,?2,?3)",
            rusqlite::params![id, parent, d.to_string()],
        )
        .unwrap();
    }
    let t = parse_devin(&path).unwrap();
    assert_eq!(t.len(), 1);
    assert_eq!(t[0].generated_tokens, 120);
    assert_eq!(t[0].tool_calls, Some(1));
    assert_eq!(t[0].duration_ms, 5000);
    assert_eq!(t[0].client, "devin-cli");
    let continuation = json!({"role":"assistant","metadata":{"request_id":"r3","generation_model":"devin","metrics":{"output_tokens":30},"finish_reason":"tool_calls","created_at":"2026-11-14T00:00:07Z"}});
    c.execute(
        "UPDATE message_nodes SET parent_node_id=3,chat_message=?1 WHERE node_id=4",
        [continuation.to_string()],
    )
    .unwrap();
    c.execute("UPDATE sessions SET main_chain_id=4", [])
        .unwrap();
    let outcome = tokenory::turn_analytics::parse_devin_outcome(&path).unwrap();
    assert!(outcome.turns.is_empty());
    assert_eq!(outcome.invalidated_ids.len(), 1);
    c.execute("UPDATE sessions SET main_chain_id=2", [])
        .unwrap();
    assert!(parse_devin(&path).unwrap().is_empty());
}
#[test]
fn opencode_family_requires_final_stop_and_adds_separate_reasoning() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("mimocode.db");
    let c = rusqlite::Connection::open(&path).unwrap();
    c.execute_batch("CREATE TABLE session(id TEXT,directory TEXT,parent_id TEXT,revert TEXT);CREATE TABLE message(id TEXT,session_id TEXT,time_created INTEGER,data TEXT);CREATE TABLE part(id TEXT,message_id TEXT,data TEXT);INSERT INTO session VALUES('s','/private/p',NULL,NULL);").unwrap();
    let user = json!({"role":"user","time":{"created":1000}});
    let assistant = json!({"role":"assistant","parentID":"u","agent":"build","modelID":"mimo","tokens":{"output":12,"reasoning":22},"time":{"created":1100,"completed":2000},"finish":"stop"});
    for (id, d) in [("u", user), ("a", assistant)] {
        c.execute(
            "INSERT INTO message VALUES(?1,'s',?2,?3)",
            rusqlite::params![id, d["time"]["created"].as_i64(), d.to_string()],
        )
        .unwrap();
    }
    let t = parse_opencode(&path, "micode").unwrap();
    assert_eq!(t.len(), 1);
    assert_eq!(t[0].generated_tokens, 34);
    assert_eq!(t[0].reasoning_tokens, Some(22));
    assert_eq!(t[0].duration_ms, 1000);
    let continuation = json!({"role":"assistant","parentID":"u","agent":"build","modelID":"mimo","tokens":{"output":8,"reasoning":2},"time":{"created":2100,"completed":2500},"finish":"tool-calls"});
    c.execute(
        "INSERT INTO message VALUES('b','s',2100,?1)",
        [continuation.to_string()],
    )
    .unwrap();
    let outcome = tokenory::turn_analytics::parse_opencode_outcome(&path, "micode").unwrap();
    assert!(outcome.turns.is_empty());
    assert_eq!(outcome.invalidated_ids.len(), 1);
    c.execute("DELETE FROM message WHERE id='b'", []).unwrap();
    c.execute(
        "UPDATE message SET data=json_remove(data,'$.finish') WHERE id='a'",
        [],
    )
    .unwrap();
    let outcome = tokenory::turn_analytics::parse_opencode_outcome(&path, "micode").unwrap();
    assert!(outcome.turns.is_empty());
    assert_eq!(outcome.invalidated_ids.len(), 1);
}
#[test]
fn generic_filters_catalog_and_codex_compatibility() {
    let dir = tempfile::tempdir().unwrap();
    let mut db = Database::open(dir.path()).unwrap();
    let mut turns = parsed(&claude());
    let mut second = turns[0].clone();
    second.id = "other".into();
    second.client = "devin-cli".into();
    second.model = "devin".into();
    turns.push(second);
    codex_turns::persist(&db.connection, &turns, "UTC").unwrap();
    let report = serde_json::to_value(
        query(
            &mut db,
            &Filter {
                client: Some("claude".into()),
                model: Some("absent".into()),
                ..Default::default()
            },
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(report["clients"], json!(["claude", "devin-cli"]));
    assert_eq!(report["models"], json!(["claude"]));
    assert_eq!(report["turns"], json!([]));
    assert!(codex_turns::query(&mut db, &Filter::default())
        .unwrap()
        .turns
        .is_empty());
    let supported = report["capabilities"].as_array().unwrap();
    assert!(supported
        .iter()
        .any(|c| c["client"] == "claude" && c["supported"] == true));
    assert!(supported
        .iter()
        .any(|c| c["client"] == "warp" && c["supported"] == false));
}
#[test]
fn schema_four_turns_restore_with_codex_defaults() {
    let dir = tempfile::tempdir().unwrap();
    let db = Database::open(dir.path()).unwrap();
    let mut body = serde_json::to_value(parsed(&claude()).remove(0)).unwrap();
    body.as_object_mut().unwrap().remove("client");
    body.as_object_mut().unwrap().remove("durationEstimated");
    db.connection.execute_batch("DROP TABLE antigravity_subagent_spawns; DROP TABLE codex_main_turn_starts; DROP TABLE codex_activity_aliases; DROP TABLE codex_activity_threads; DROP TABLE codex_turns; CREATE TABLE codex_turns(id TEXT PRIMARY KEY,date TEXT NOT NULL,model TEXT NOT NULL,body TEXT NOT NULL); PRAGMA user_version=4;").unwrap();
    db.connection
        .execute(
            "INSERT INTO codex_turns VALUES('legacy','2026-11-14','claude',?1)",
            [body.to_string()],
        )
        .unwrap();
    let backup = dir.path().join("v4.sqlite3");
    db.backup(&backup).unwrap();
    drop(db);
    let mut db = Database::open(dir.path()).unwrap();
    let report = codex_turns::query(&mut db, &Filter::default()).unwrap();
    assert_eq!(report.turns.len(), 1);
    assert_eq!(report.turns[0].client, "codex");
    assert!(!report.turns[0].duration_estimated);
    db.restore(&backup).unwrap();
    let report = serde_json::to_value(query(&mut db, &Filter::default()).unwrap()).unwrap();
    assert_eq!(report["clients"], json!(["codex"]));
}
fn continuation() -> Vec<Value> {
    vec![
        json!({"type":"user","isMeta":true,"sessionId":"s","timestamp":"2026-11-14T00:00:06Z","message":{"content":"continue"}}),
        json!({"type":"assistant","sessionId":"s","timestamp":"2026-11-14T00:00:07Z","message":{"id":"r3","model":"claude","usage":{"output_tokens":30},"stop_reason":"tool_use","content":[{"type":"tool_use","id":"tool2"}]}}),
    ]
}
#[test]
fn reopened_claude_turn_requires_a_new_terminal_response() {
    use tokenory::turn_analytics::parse_claude_outcome;
    let mut e = claude();
    e.extend(continuation());
    let read = |events: &[Value]| {
        parse_claude_outcome(std::io::Cursor::new(
            events
                .iter()
                .map(Value::to_string)
                .collect::<Vec<_>>()
                .join("\n"),
        ))
        .unwrap()
    };
    let outcome = read(&e);
    assert!(outcome.turns.is_empty());
    assert_eq!(outcome.invalidated_ids.len(), 1);
    let mut replay = e.clone();
    replay.push(claude()[3].clone());
    assert!(
        read(&replay).turns.is_empty(),
        "replayed old terminal response cannot close a continuation"
    );
    e.push(json!({"type":"assistant","sessionId":"s","timestamp":"2026-11-14T00:00:09Z","message":{"id":"r4","model":"claude","usage":{"output_tokens":10},"stop_reason":"end_turn"}}));
    let outcome = read(&e);
    assert!(outcome.invalidated_ids.is_empty());
    assert_eq!(outcome.turns[0].duration_ms, 9000);
    assert_eq!(outcome.turns[0].generated_tokens, 160);
}
#[tokio::test]
async fn scanner_retracts_reopened_turn_atomically_and_cached_rescan_is_unchanged() {
    use tokenory::collector::{collect_once, persist, DiagnosticCache};
    let home = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    let path = home.path().join(".claude/projects/p/s.jsonl");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let write = |events: &[Value]| {
        std::fs::write(
            &path,
            events
                .iter()
                .map(Value::to_string)
                .collect::<Vec<_>>()
                .join("\n"),
        )
        .unwrap()
    };
    let config = tokenory::config::Config {
        home_dir: home.path().into(),
        ..Default::default()
    };
    let mut cache = DiagnosticCache::default();
    let mut db = Database::open(data.path()).unwrap();
    let mut e = claude();
    write(&e);
    persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    assert_eq!(
        serde_json::to_value(query(&mut db, &Filter::default()).unwrap()).unwrap()["turns"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    e.extend(continuation());
    write(&e);
    let removed = persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    assert!(removed.changed > 0);
    assert_eq!(
        serde_json::to_value(query(&mut db, &Filter::default()).unwrap()).unwrap()["turns"],
        json!([])
    );
    let again = persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    assert_eq!(again.changed, 0);
    assert_eq!(again.revision, removed.revision);
    e.push(json!({"type":"assistant","sessionId":"s","timestamp":"2026-11-14T00:00:09Z","message":{"id":"r4","model":"claude","usage":{"output_tokens":10},"stop_reason":"end_turn"}}));
    write(&e);
    persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    let r = serde_json::to_value(query(&mut db, &Filter::default()).unwrap()).unwrap();
    assert_eq!(r["turns"][0]["durationMs"], 9000);
    assert_eq!(r["turns"][0]["generatedTokens"], 160);
}
#[test]
fn damaged_claude_source_does_not_revoke_saved_history() {
    let mut e = claude();
    e.extend(continuation());
    let lines = e
        .iter()
        .map(Value::to_string)
        .collect::<Vec<_>>()
        .join("\n")
        + "\n{incomplete";
    let outcome =
        tokenory::turn_analytics::parse_claude_outcome(std::io::Cursor::new(lines)).unwrap();
    assert!(outcome.invalidated_ids.is_empty());
    assert!(outcome.turns.is_empty());
}
#[tokio::test]
async fn analytics_adapter_errors_mark_source_partial() {
    let home = tempfile::tempdir().unwrap();
    let path = home.path().join(".local/share/devin/cli/sessions.db");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    rusqlite::Connection::open(&path)
        .unwrap()
        .execute_batch("CREATE TABLE unsupported(id INTEGER);")
        .unwrap();
    let config = tokenory::config::Config {
        home_dir: home.path().into(),
        ..Default::default()
    };
    let batch = tokenory::collector::collect_once(
        &config,
        &mut tokenory::collector::DiagnosticCache::default(),
    )
    .await
    .unwrap();
    let source = batch
        .result
        .sources
        .iter()
        .find(|s| s.client == "devin-cli")
        .unwrap();
    assert_eq!(source.status, "partial");
    assert!(source.errors.iter().any(|e| e.contains("turn analytics")));
}
#[tokio::test]
async fn legacy_devin_analytics_failure_does_not_block_ledger_updates() {
    use tokenory::collector::{collect_once, persist, DiagnosticCache};
    let home = tempfile::tempdir().unwrap();
    let data = tempfile::tempdir().unwrap();
    let path = home.path().join(".local/share/devin/cli/sessions.db");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let c = rusqlite::Connection::open(&path).unwrap();
    c.execute_batch("CREATE TABLE sessions(id TEXT,working_directory TEXT,model TEXT); CREATE TABLE message_nodes(row_id INTEGER,session_id TEXT,chat_message TEXT,created_at INTEGER); INSERT INTO sessions VALUES('s','/private/p','swe-2-flash-medium');").unwrap();
    let row = |output| {
        json!({"role":"assistant","metadata":{"generation_model":"swe-2-flash-medium","metrics":{"input_tokens":100,"output_tokens":output}}}).to_string()
    };
    c.execute(
        "INSERT INTO message_nodes VALUES(1,'s',?1,1794614400)",
        [row(20)],
    )
    .unwrap();
    let config = tokenory::config::Config {
        home_dir: home.path().into(),
        ..Default::default()
    };
    let mut cache = DiagnosticCache::default();
    let mut db = Database::open(data.path()).unwrap();
    let batch = collect_once(&config, &mut cache).await.unwrap();
    let source = batch
        .result
        .sources
        .iter()
        .find(|s| s.client == "devin-cli")
        .unwrap();
    assert_eq!(source.status, "partial");
    assert!(source.errors.iter().any(|s| s.contains("turn analytics")));
    assert_eq!(
        batch.records.len(),
        1,
        "analytics-only errors must not suppress valid usage"
    );
    persist(&mut db, batch).unwrap();
    assert_eq!(
        tokenory::queries::report(&mut db, &Filter::default())
            .unwrap()
            .summary
            .tokens,
        120
    );
    c.execute("UPDATE message_nodes SET chat_message=?1", [row(30)])
        .unwrap();
    persist(&mut db, collect_once(&config, &mut cache).await.unwrap()).unwrap();
    assert_eq!(
        tokenory::queries::report(&mut db, &Filter::default())
            .unwrap()
            .summary
            .tokens,
        130
    );
    assert!(
        serde_json::to_value(query(&mut db, &Filter::default()).unwrap()).unwrap()["turns"]
            .as_array()
            .unwrap()
            .is_empty()
    );
}

fn linked_transcript() -> Vec<Value> {
    vec![
        json!({"type":"session","id":"linked","cwd":"/private/demo"}),
        json!({"type":"message","id":"u","parentId":null,"timestamp":"2026-11-14T00:00:00Z","message":{"role":"user","content":"private"}}),
        json!({"type":"message","id":"a","parentId":"u","timestamp":"2026-11-14T00:00:01Z","message":{"role":"assistant","model":"model","usage":{"output":6},"stopReason":"toolUse","content":[{"type":"toolCall","id":"call"}]}}),
        json!({"type":"message","id":"tool","parentId":"a","timestamp":"2026-11-14T00:00:02Z","message":{"role":"toolResult"}}),
        json!({"type":"message","id":"b","parentId":"tool","timestamp":"2026-11-14T00:00:03Z","message":{"role":"assistant","model":"model","usage":{"output":4,"reasoning":2,"reasoningTokens":2},"stopReason":"stop"}}),
    ]
}

fn transcript_text(events: &[Value]) -> String {
    events
        .iter()
        .map(Value::to_string)
        .collect::<Vec<_>>()
        .join("\n")
}

#[test]
fn linked_turns_require_monotone_lineage_and_terminal_response() {
    use tokenory::turn_analytics::parse_linked_transcript;
    let mut events = linked_transcript();
    events.insert(3, events[2].clone());
    let parse = |events: &[Value]| {
        parse_linked_transcript(std::io::Cursor::new(transcript_text(events)), "pi", None).unwrap()
    };
    let turns = parse(&events).turns;
    assert_eq!(turns.len(), 1);
    let t = &turns[0];
    assert_eq!(
        (
            t.client.as_str(),
            t.generated_tokens,
            t.requests,
            t.tool_calls,
            t.duration_ms
        ),
        ("pi", 10, Some(2), Some(1), 3_000)
    );
    assert_eq!(t.reasoning_tokens, None);
    events.push(json!({"type":"message","id":"c","parentId":"b","timestamp":"2026-11-14T00:00:04Z","message":{"role":"assistant","model":"model","usage":{"output":2},"stopReason":"toolUse"}}));
    let reopened = parse(&events);
    assert!(reopened.turns.is_empty());
    assert_eq!(reopened.invalidated_ids, vec![t.id.clone()]);
    events.last_mut().unwrap()["parentId"] = "u".into();
    let branched = parse(&events);
    assert!(branched.turns.is_empty() && branched.invalidated_ids.is_empty());
    events.pop();
    events[0]["parentSession"] = "parent.jsonl".into();
    assert!(parse(&events).turns.is_empty());
}

#[test]
fn openclaw_reads_sqlite_and_compressed_transcripts_with_the_same_identity() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("transcript.sqlite");
    let archive = dir.path().join("linked.jsonl.zst");
    let c = rusqlite::Connection::open(&path).unwrap();
    c.execute_batch("CREATE TABLE transcript_events(session_id TEXT,seq INTEGER,event_json TEXT);")
        .unwrap();
    let events = linked_transcript();
    for (index, event) in events.iter().enumerate() {
        c.execute(
            "INSERT INTO transcript_events VALUES('linked',?1,?2)",
            rusqlite::params![index, event.to_string()],
        )
        .unwrap();
    }
    let content = transcript_text(&events);
    std::fs::write(&archive, zstd::encode_all(content.as_bytes(), 0).unwrap()).unwrap();
    let mut cache = tokenory::turn_analytics::Cache::default();
    let db = cache.read("openclaw", &path).unwrap().turns;
    let zip = cache.read("openclaw", &archive).unwrap().turns;
    assert_eq!(db, zip);
    assert_eq!(db.len(), 1);
    assert_eq!(db[0].client, "openclaw");
    assert_eq!(db[0].generated_tokens, 10);
    let mut mirrored = events;
    mirrored.last_mut().unwrap()["message"]["idempotencyKey"] =
        "codex-app-server:thread:turn:assistant".into();
    let outcome = tokenory::turn_analytics::parse_linked_transcript(
        std::io::Cursor::new(transcript_text(&mirrored)),
        "openclaw",
        None,
    )
    .unwrap();
    assert!(outcome.turns.is_empty());
}

#[tokio::test]
async fn scans_pi_openclaw_and_open_code_family_and_filters_aliases_without_duplicate_turns() {
    let home = tempfile::tempdir().unwrap();
    let path = home.path().join(".pi/agent/sessions/project/linked.jsonl");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, transcript_text(&linked_transcript())).unwrap();
    let path = home
        .path()
        .join(".openclaw/agents/main/sessions/linked.jsonl");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, transcript_text(&linked_transcript())).unwrap();
    let path = home
        .path()
        .join(".kimi-code/sessions/work/s/agents/main/wire.jsonl");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, transcript_text(&[
        json!({"type":"turn.prompt","agentId":"main","origin":{"kind":"user"},"trigger":"normal","turnId":1,"time":1794614400000i64}),
        json!({"type":"context.append_loop_event","agentId":"main","event":{"type":"step.begin","uuid":"step","turnId":"1"}}),
        json!({"type":"usage.record","agentId":"main","usageScope":"turn","model":"kimi-k2","time":1794614401000i64,"usage":{"output":8}}),
        json!({"type":"context.append_loop_event","agentId":"main","event":{"type":"step.end","uuid":"step","turnId":"1","usage":{"output":8}}}),
        json!({"type":"turn.ended","agentId":"main","turnId":1,"time":1794614402000i64,"reason":"completed"}),
    ])).unwrap();
    let exports = home.path().join("gemini-exports");
    std::fs::create_dir_all(&exports).unwrap();
    std::fs::write(exports.join("run.jsonl"),transcript_text(&[
        json!({"type":"init","session_id":"gem","timestamp":"2026-11-14T00:00:00Z"}),
        json!({"type":"message","role":"user","timestamp":"2026-11-14T00:00:01Z"}),
        json!({"type":"result","status":"success","timestamp":"2026-11-14T00:00:04Z","stats":{"tool_calls":0,"models":{"actual":{"input_tokens":60,"output_tokens":10,"total_tokens":70}}}}),
    ])).unwrap();
    let cline = home.path().join("cline-tasks");
    let path = cline.join("task/ui_messages.json");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path,json!([
        {"type":"say","say":"task","ts":1794614400000i64},
        {"type":"say","say":"api_req_started","ts":1794614401000i64,"modelInfo":{"modelId":"claude"},"text":json!({"tokensOut":10}).to_string()},
        {"type":"ask","ask":"completion_result","ts":1794614402000i64}
    ]).to_string()).unwrap();
    let path = home.path().join(".qwen/projects/p/chats/session.jsonl");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path,transcript_text(&[
        json!({"type":"user","uuid":"u","parentUuid":null,"sessionId":"q","promptId":"p","daemonPromptId":"d"}),
        json!({"type":"assistant","uuid":"a","parentUuid":"u","sessionId":"q","model":"served","usageMetadata":{"candidatesTokenCount":10,"thoughtsTokenCount":2}}),
        json!({"type":"system","subtype":"turn_result","uuid":"end","parentUuid":"a","sessionId":"q","promptId":"p","systemPayload":{"promptId":"d","state":"completed","stopReason":"end_turn","startedAt":1794614400000i64,"endedAt":1794614402000i64}})
    ])).unwrap();
    for target in [
        ".local/share/kilo/kilo.db",
        ".local/share/mimocode/mimocode.db",
        ".local/share/opencode/opencode.db",
    ] {
        let path = home.path().join(target);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let db = rusqlite::Connection::open(path).unwrap();
        db.execute_batch("CREATE TABLE session(id TEXT,directory TEXT,parent_id TEXT,revert TEXT);CREATE TABLE message(id TEXT,session_id TEXT,time_created INTEGER,data TEXT);CREATE TABLE part(id TEXT,message_id TEXT,data TEXT);INSERT INTO session VALUES('s','/private/p',NULL,NULL);").unwrap();
        for (id, at, body) in [
            (
                "u",
                1794614400000i64,
                json!({"role":"user","time":{"created":1794614400000i64}}),
            ),
            (
                "a",
                1794614401000i64,
                json!({"role":"assistant","parentID":"u","agent":"build","modelID":"measured","tokens":{"input":1,"output":4,"reasoning":0},"time":{"created":1794614401000i64,"completed":1794614402000i64},"finish":"stop"}),
            ),
        ] {
            db.execute(
                "INSERT INTO message VALUES(?1,'s',?2,?3)",
                rusqlite::params![id, at, body.to_string()],
            )
            .unwrap();
        }
    }
    let config = tokenory::config::Config {
        home_dir: home.path().into(),
        extra_scan_paths: [
            ("gemini".into(), vec![exports]),
            ("cline".into(), vec![cline]),
        ]
        .into(),
        ..Default::default()
    };
    let db_home = tempfile::tempdir().unwrap();
    let mut db = Database::open(db_home.path()).unwrap();
    let mut cache = tokenory::collector::DiagnosticCache::default();
    let batch = tokenory::collector::collect_once(&config, &mut cache)
        .await
        .unwrap();
    for id in [
        "pi", "openclaw", "kilo", "micode", "opencode", "kimi", "gemini", "cline", "qwen",
    ] {
        assert!(
            batch.codex_turns.iter().any(|t| t.client == id),
            "{id}: {:?}",
            batch.result.sources
        );
    }
    tokenory::collector::persist(&mut db, batch).unwrap();
    let all = serde_json::to_value(query(&mut db, &Filter::default()).unwrap()).unwrap();
    let actual = all["capabilities"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v["client"].as_str().unwrap())
        .collect::<std::collections::BTreeSet<_>>();
    let catalog = serde_json::to_value(tokenory::clients::catalog()).unwrap();
    let expected = catalog
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v["id"].as_str().unwrap())
        .collect::<std::collections::BTreeSet<_>>();
    assert_eq!(actual, expected);
    assert_eq!(all["turns"].as_array().unwrap().len(), 9);
    let orca = serde_json::to_value(
        query(
            &mut db,
            &Filter {
                client: Some("orca".into()),
                model: Some("measured".into()),
                ..Default::default()
            },
        )
        .unwrap(),
    )
    .unwrap();
    assert_eq!(orca["turns"].as_array().unwrap().len(), 1);
    assert_eq!(orca["turns"][0]["client"], "micode");
    assert_eq!(orca["models"], json!(["measured"]));
    for cap in all["capabilities"].as_array().unwrap() {
        match cap["client"].as_str().unwrap() {
            "orca" => assert_eq!(cap["delegateClients"], json!(["micode"])),
            "paseo" => assert_eq!(cap["delegateClients"], json!(["claude", "codex"])),
            "trae-cli" => assert_eq!(cap["supported"], false),
            _ if cap["supported"] == false => {
                assert!(cap["reason"].is_string() && cap["remedy"].is_string())
            }
            _ => assert!(cap["reason"].is_null() && cap["delegateClients"].is_null()),
        }
    }
}

#[test]
fn opencode_v2_uses_the_current_projection_and_successful_idle() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("opencode.db");
    let db = rusqlite::Connection::open(&path).unwrap();
    db.execute_batch("CREATE TABLE session_v2(id TEXT,directory TEXT,parent_id TEXT,revert TEXT);CREATE TABLE session_message(id TEXT,session_id TEXT,type TEXT,seq INTEGER,data TEXT);INSERT INTO session_v2 VALUES('s','/private/p',NULL,NULL);").unwrap();
    for (id, kind, seq, body) in [
        ("u", "user", 1, json!({"time":{"created":1000}})),
        (
            "a",
            "assistant",
            2,
            json!({"model":{"id":"actual"},"time":{"completed":1800},"content":[{"type":"tool","id":"call"}],"tokens":{"output":2,"reasoning":3}}),
        ),
        (
            "b",
            "assistant",
            3,
            json!({"model":{"id":"actual"},"time":{"completed":2900},"content":[{"type":"text","text":"private"}],"tokens":{"output":5,"reasoning":0}}),
        ),
        (
            "end",
            "idle",
            4,
            json!({"time":{"created":3000},"outcome":"succeeded"}),
        ),
    ] {
        db.execute(
            "INSERT INTO session_message VALUES(?1,'s',?2,?3,?4)",
            rusqlite::params![id, kind, seq, body.to_string()],
        )
        .unwrap();
    }
    let result = parse_opencode(&path, "opencode").unwrap();
    assert_eq!(result.len(), 1);
    let turn = &result[0];
    assert_eq!(
        (
            turn.model.as_str(),
            turn.generated_tokens,
            turn.requests,
            turn.tool_calls,
            turn.duration_ms
        ),
        ("actual", 10, Some(2), Some(1), 2000)
    );
    db.execute(
        "UPDATE session_message SET data=json_set(data,'$.outcome','interrupted') WHERE id='end'",
        [],
    )
    .unwrap();
    assert!(parse_opencode(&path, "opencode").unwrap().is_empty());
}

#[test]
fn opencode_legacy_joins_session_and_part_storage() {
    let temp = tempfile::tempdir().unwrap();
    let write = |relative: &str, value: Value| {
        let path = temp.path().join(relative);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, value.to_string()).unwrap();
        path
    };
    write(
        "session/project/s.json",
        json!({"id":"s","directory":"/private/project"}),
    );
    let user = write(
        "message/s/msg_u.json",
        json!({"role":"user","id":"msg_u","sessionID":"s","time":{"created":1000}}),
    );
    let a = write(
        "message/s/msg_a.json",
        json!({"role":"assistant","id":"msg_a","sessionID":"s","parentID":"msg_u","modelID":"model","time":{"created":1400,"completed":1600},"finish":"tool-calls","tokens":{"output":4,"reasoning":1}}),
    );
    write("part/msg_a/tool.json", json!({"type":"tool","id":"tool"}));
    let b = write(
        "message/s/msg_b.json",
        json!({"role":"assistant","id":"msg_b","sessionID":"s","parentID":"msg_u","modelID":"model","time":{"created":2000,"completed":3200},"finish":"stop","tokens":{"output":4,"reasoning":0}}),
    );
    let paths = vec![a, b, user];
    let out = tokenory::turn_analytics::parse_opencode_legacy(&paths).unwrap();
    assert_eq!(out.turns.len(), 1);
    assert_eq!(
        (
            out.turns[0].generated_tokens,
            out.turns[0].tool_calls,
            out.turns[0].duration_ms
        ),
        (9, Some(1), 2200)
    );
    write(
        "session/project/s.json",
        json!({"id":"s","directory":"/private/project","parentID":"other"}),
    );
    assert!(tokenory::turn_analytics::parse_opencode_legacy(&paths)
        .unwrap()
        .turns
        .is_empty());
}

#[tokio::test]
async fn legacy_opencode_retracts_reopened_turn_except_when_sqlite_owns_it() {
    use tokenory::collector::{collect_once, persist, DiagnosticCache};
    let home = tempfile::tempdir().unwrap();
    let root = home.path().join(".local/share/opencode");
    let write = |relative: &str, value: &Value| {
        let path = root.join(relative);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, value.to_string()).unwrap();
    };
    let user = json!({"role":"user","id":"msg_u","sessionID":"s","time":{"created":1000}});
    let assistant = json!({"role":"assistant","id":"msg_a","sessionID":"s","parentID":"msg_u","modelID":"model","time":{"created":1400,"completed":1600},"finish":"stop","tokens":{"output":4,"reasoning":1}});
    write(
        "storage/session/project/s.json",
        &json!({"id":"s","directory":"/private/project"}),
    );
    write("storage/message/s/msg_u.json", &user);
    write("storage/message/s/msg_a.json", &assistant);
    let config = tokenory::config::Config {
        home_dir: home.path().into(),
        ..Default::default()
    };
    let data = tempfile::tempdir().unwrap();
    let mut ledger = Database::open(data.path()).unwrap();
    let mut cache = DiagnosticCache::default();
    let count = |db: &Database| -> i64 {
        db.connection
            .query_row("SELECT count(*) FROM codex_turns", [], |r| r.get(0))
            .unwrap()
    };

    persist(
        &mut ledger,
        collect_once(&config, &mut cache).await.unwrap(),
    )
    .unwrap();
    assert_eq!(count(&ledger), 1);
    let unfinished = json!({"role":"assistant","id":"msg_b","sessionID":"s","parentID":"msg_u","modelID":"model","time":{"created":1700},"tokens":{"output":2,"reasoning":0}});
    write("storage/message/s/msg_b.json", &unfinished);
    persist(
        &mut ledger,
        collect_once(&config, &mut cache).await.unwrap(),
    )
    .unwrap();
    assert_eq!(count(&ledger), 0);

    let sqlite = rusqlite::Connection::open(root.join("opencode.db")).unwrap();
    sqlite.execute_batch("CREATE TABLE session(id TEXT,directory TEXT,parent_id TEXT,revert TEXT);CREATE TABLE message(id TEXT,session_id TEXT,time_created INTEGER,data TEXT);CREATE TABLE part(id TEXT,message_id TEXT,data TEXT);INSERT INTO session VALUES('s','/private/project',NULL,NULL);").unwrap();
    for (id, time, row) in [("msg_u", 1000, user), ("msg_a", 1400, assistant)] {
        sqlite
            .execute(
                "INSERT INTO message VALUES(?1,'s',?2,?3)",
                rusqlite::params![id, time, row.to_string()],
            )
            .unwrap();
    }
    persist(
        &mut ledger,
        collect_once(&config, &mut cache).await.unwrap(),
    )
    .unwrap();
    assert_eq!(
        count(&ledger),
        1,
        "the stale JSON must not retract SQLite's completed turn"
    );
}
