// [INPUT]: Cline extension ui_messages.json with explicit per-request metrics.
// [OUTPUT]: User task or feedback to final completion_result ask.
// [POS]: Excludes open, failed, cancelled, or unpriced/model-ambiguous request sequences.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
use super::{ParseOutcome, Pending};
use anyhow::Result;
use serde_json::Value;
use std::path::Path;

pub(super) fn parse(path: &Path) -> Result<ParseOutcome> {
    if path.file_name().is_none_or(|n| n != "ui_messages.json") {
        return Ok(ParseOutcome::default());
    }
    let Some(session) = path
        .parent()
        .and_then(Path::file_name)
        .and_then(|n| n.to_str())
    else {
        return Ok(ParseOutcome::default());
    };
    let rows: Vec<Value> =
        serde_json::from_reader(std::io::BufReader::new(std::fs::File::open(path)?))?;
    Ok(parse_rows(&rows, session))
}

fn parse_rows(rows: &[Value], session: &str) -> ParseOutcome {
    let mut result = ParseOutcome::default();
    let mut active = None::<Pending>;
    for d in rows {
        if d["type"] == "say"
            && (d["say"] == "task"
                || (d["say"] == "user_feedback"
                    && active.as_ref().is_some_and(|t| t.end.is_some())))
        {
            if let Some(t) = active.take() {
                result.record(t, "cline");
            }
            if let Some(start) = d["ts"].as_i64().filter(|ts| *ts > 0) {
                active = Some(Pending {
                    session: session.into(),
                    id: start.to_string(),
                    start,
                    ..Default::default()
                });
            }
            continue;
        }
        let Some(t) = &mut active else { continue };
        if d["type"] == "say" && d["say"] == "api_req_started" {
            let Some((ts, usage)) = d["ts"].as_i64().zip(
                d["text"]
                    .as_str()
                    .and_then(|s| serde_json::from_str::<Value>(s).ok()),
            ) else {
                t.reopen();
                t.invalid = true;
                continue;
            };
            if ["cancelReason", "streamingFailedMessage", "retryStatus"]
                .iter()
                .any(|k| usage.get(k).is_some_and(|v| !v.is_null()))
            {
                t.reopen();
                t.invalid = true;
                continue;
            }
            let model = d["modelInfo"]["modelId"]
                .as_str()
                .filter(|m| !matches!(*m, "auto" | "unknown" | "default"))
                .unwrap_or("");
            t.response(&ts.to_string(), model, usage["tokensOut"].as_i64(), None);
        } else if d["type"] == "ask"
            && d["ask"] == "completion_result"
            && (d.get("partial").is_none() || d["partial"] == false)
        {
            t.end = d["ts"].as_i64();
        } else if (d["type"] == "ask"
            && matches!(d["ask"].as_str(), Some("api_req_failed" | "resume_task")))
            || (d["type"] == "say" && d["say"] == "error_retry")
        {
            t.reopen();
            t.invalid = true;
        }
    }
    if let Some(t) = active {
        result.record(t, "cline");
    }
    // UI messages need not enumerate actual provider tool invocations; the
    // adapter leaves this ancillary count unknown.
    for turn in &mut result.turns {
        turn.tool_calls = None;
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn final_ask_closes_a_task_with_measured_requests() {
        let mut rows = vec![
            json!({"type":"say","say":"task","ts":1000}),
            json!({"type":"say","say":"api_req_started","ts":1100,"modelInfo":{"modelId":"claude"},"text":"{\"tokensOut\":10}"}),
            json!({"type":"say","say":"completion_result","ts":1600,"partial":false}),
            json!({"type":"ask","ask":"completion_result","ts":2000}),
        ];
        assert!(parse_rows(&rows[..3], "s").turns.is_empty());
        let r = parse_rows(&rows, "s");
        let t = &r.turns[0];
        assert_eq!(
            (t.generated_tokens, t.duration_ms, t.requests, t.tool_calls),
            (10, 1000, Some(1), None)
        );
        rows[1]["text"] = r#"{"tokensOut":10,"cancelReason":"user_cancelled"}"#.into();
        assert!(parse_rows(&rows, "s").turns.is_empty());
    }
}
