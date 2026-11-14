// [INPUT]: Qwen main chat recording with daemon turn_result events.
// [OUTPUT]: Completed user turns with measured model usage.
// [POS]: Rejects unbound prompts and out-of-line history.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
use super::{ParseOutcome, Pending};
use anyhow::Result;
use serde_json::Value;
use std::{
    collections::HashSet,
    io::{BufRead, BufReader},
    path::Path,
};

pub(super) fn parse(path: &Path) -> Result<ParseOutcome> {
    parse_stream(BufReader::new(std::fs::File::open(path)?))
}

fn parse_stream(reader: impl BufRead) -> Result<ParseOutcome> {
    let mut result = ParseOutcome::default();
    let mut session = String::new();
    let mut tail = None::<String>;
    let mut seen = HashSet::new();
    let mut active = None::<(Pending, String)>;
    for line in reader.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let Ok(d) = serde_json::from_str::<Value>(&line) else {
            return Ok(ParseOutcome::default());
        };
        let subtype = d["subtype"].as_str().unwrap_or("");
        if d["isSidechain"] == true {
            continue;
        }
        if matches!(subtype, "parent_session" | "conversation_rewind" | "rewind") {
            return Ok(ParseOutcome::default());
        }
        let Some((id, sid)) = d["uuid"]
            .as_str()
            .filter(|id| !id.is_empty())
            .zip(d["sessionId"].as_str().filter(|s| !s.is_empty()))
        else {
            return Ok(ParseOutcome::default());
        };
        if session.is_empty() {
            session = sid.into();
        }
        if session != sid
            || !seen.insert(id.to_owned())
            || d.get("parentUuid").is_none()
            || d["parentUuid"].as_str() != tail.as_deref()
            || (!d["parentUuid"].is_null() && !d["parentUuid"].is_string())
        {
            return Ok(ParseOutcome::default());
        }
        tail = Some(id.into());
        if d["type"] == "user" && subtype.is_empty() && d["provenance"] != "mod_prompt" {
            if let Some((t, _)) = active.take() {
                result.record(t, "qwen");
            }
            if let (Some(prompt), Some(daemon)) = (
                d["promptId"].as_str().filter(|s| !s.is_empty()),
                d["daemonPromptId"].as_str().filter(|s| !s.is_empty()),
            ) {
                active = Some((
                    Pending {
                        id: prompt.into(),
                        session: session.clone(),
                        start: -1,
                        project: super::project(d["cwd"].as_str().unwrap_or("")),
                        ..Default::default()
                    },
                    daemon.into(),
                ));
            }
            continue;
        }
        let Some((t, daemon)) = &mut active else {
            continue;
        };
        match (d["type"].as_str(), subtype) {
            (Some("assistant"), "") => {
                let usage = &d["usageMetadata"];
                let reasoning = usage["thoughtsTokenCount"].as_i64().filter(|n| *n >= 0);
                let output = usage["candidatesTokenCount"].as_i64().filter(|n| *n >= 0);
                // Google-style candidate and thought buckets are disjoint.
                // Only infer zero thoughts when the total proves it.
                let reasoning = reasoning.or_else(|| {
                    let known = usage["promptTokenCount"]
                        .as_i64()?
                        .checked_add(output?)?
                        .checked_add(usage["toolUsePromptTokenCount"].as_i64().unwrap_or(0))?;
                    (usage["totalTokenCount"].as_i64() == Some(known)
                        && usage.get("thoughtsTokenCount").is_none())
                    .then_some(0)
                });
                t.response(
                    id,
                    d["model"].as_str().unwrap_or(""),
                    output.and_then(|n| n.checked_add(reasoning?)),
                    reasoning,
                );
                if let Some(parts) = d["message"]["parts"].as_array() {
                    for part in parts.iter().filter_map(|p| p.get("functionCall")) {
                        if let Some(id) = part["id"].as_str().filter(|id| !id.is_empty()) {
                            t.tools.insert(id.into());
                        } else {
                            t.invalid = true;
                        }
                    }
                }
            }
            (Some("system"), "turn_result") => {
                let p = &d["systemPayload"];
                if p["promptId"].as_str() != Some(daemon.as_str())
                    || d.get("promptId")
                        .is_some_and(|p| p.as_str() != Some(t.id.as_str()))
                {
                    continue;
                }
                if p["state"] == "completed" && p["stopReason"] == "end_turn" {
                    t.start = p["startedAt"].as_i64().unwrap_or(-1);
                    t.end = p["endedAt"].as_i64();
                } else {
                    t.reopen();
                }
            }
            (Some("system"), "turn_attempt" | "chat_compression") => {
                t.reopen();
                t.invalid = true;
            }
            _ => {}
        }
    }
    if let Some((t, _)) = active {
        result.record(t, "qwen");
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn authoritative_daemon_result_bounds_the_turn() {
        let mut rows = vec![
            json!({"type":"user","uuid":"u","parentUuid":null,"sessionId":"session","promptId":"client","daemonPromptId":"daemon"}),
            json!({"type":"assistant","uuid":"a","parentUuid":"u","sessionId":"session","model":"qwen","usageMetadata":{"candidatesTokenCount":7,"thoughtsTokenCount":2},"message":{"parts":[{"functionCall":{"id":"tool"}}]}}),
            json!({"type":"tool_result","uuid":"t","parentUuid":"a","sessionId":"session"}),
            json!({"type":"assistant","uuid":"a2","parentUuid":"t","sessionId":"session","model":"qwen","usageMetadata":{"promptTokenCount":40,"candidatesTokenCount":3,"totalTokenCount":43}}),
            json!({"type":"system","subtype":"turn_result","uuid":"end","parentUuid":"a2","sessionId":"session","promptId":"client","systemPayload":{"promptId":"daemon","state":"completed","stopReason":"end_turn","startedAt":1000,"endedAt":2500}}),
        ];
        let parse = |rows: &[Value]| {
            parse_stream(
                rows.iter()
                    .map(Value::to_string)
                    .collect::<Vec<_>>()
                    .join("\n")
                    .as_bytes(),
            )
            .unwrap()
        };
        let r = parse(&rows);
        let t = &r.turns[0];
        assert_eq!(
            (
                t.generated_tokens,
                t.reasoning_tokens,
                t.duration_ms,
                t.requests,
                t.tool_calls
            ),
            (12, Some(2), 1500, Some(2), Some(1))
        );
        rows[4]["systemPayload"]["promptId"] = "other".into();
        assert!(parse(&rows).turns.is_empty());
        rows[4]["systemPayload"]["promptId"] = "daemon".into();
        rows[4]["systemPayload"]["state"] = "cancelled".into();
        assert!(parse(&rows).turns.is_empty());
        rows[4]["systemPayload"]["state"] = "completed".into();
        rows[4]["parentUuid"] = "u".into();
        assert!(parse(&rows).turns.is_empty());
    }
}
