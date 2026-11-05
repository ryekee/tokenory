use std::fs;
use tokens_core::sessions::{claudecode::parse_claude_file, codex::parse_codex_file};

#[test]
fn claude_stream_identity_is_stable_across_updates() {
    let root = tempfile::tempdir().unwrap();
    let file = root.path().join("session.jsonl");
    let row = |n| serde_json::json!({"type":"assistant","timestamp":"2026-11-05T01:00:00Z","message":{"id":"msg_stable","role":"assistant","model":"claude-sonnet-4-5","usage":{"input_tokens":n,"output_tokens":20}}});
    fs::write(&file, format!("{}\n", row(100))).unwrap();
    let before = parse_claude_file(&file);
    fs::write(&file, format!("{}\n{}\n", row(100), row(120))).unwrap();
    let after = parse_claude_file(&file);
    assert_eq!(before.len(), 1);
    assert_eq!(after.len(), 1);
    assert_eq!(before[0].dedup_key, after[0].dedup_key);
    assert!(after[0].dedup_key.is_some());
    assert_eq!(after[0].tokens.input, 120);
}

#[test]
fn codex_copy_preserves_identity_and_cumulative_deltas() {
    let root = tempfile::tempdir().unwrap();
    let first = root.path().join("first.jsonl");
    let second = root.path().join("second.jsonl");
    let rows = [
        serde_json::json!({"timestamp":"2026-11-05T01:00:00Z","type":"session_meta","payload":{"id":"session-stable","model_provider":"openai"}}),
        serde_json::json!({"timestamp":"2026-11-05T01:00:00Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}),
        serde_json::json!({"timestamp":"2026-11-05T01:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":0,"cached_input_tokens":0,"reasoning_output_tokens":0,"total_tokens":100}}}}),
        serde_json::json!({"timestamp":"2026-11-05T01:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"output_tokens":0,"cached_input_tokens":0,"reasoning_output_tokens":0,"total_tokens":150}}}}),
    ];
    fs::write(
        &first,
        rows.iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>()
            .join("\n"),
    )
    .unwrap();
    fs::copy(&first, &second).unwrap();
    let a = parse_codex_file(&first);
    let b = parse_codex_file(&second);
    assert_eq!(a.len(), 2);
    assert_eq!(a.iter().map(|m| m.tokens.total()).sum::<i64>(), 150);
    assert_eq!(
        a.iter().map(|m| &m.dedup_key).collect::<Vec<_>>(),
        b.iter().map(|m| &m.dedup_key).collect::<Vec<_>>()
    );
}
