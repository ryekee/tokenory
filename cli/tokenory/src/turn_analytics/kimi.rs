// [INPUT]: Kimi Code main-agent wire.jsonl with explicit turn and loop events.
// [OUTPUT]: Successful user turns with measured output and recorded timestamps.
// [POS]: Kimi wire adapter; never retains content or uses legacy config model.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
use super::{ParseOutcome, Pending};
use anyhow::Result;
use serde_json::Value;
use std::{
    collections::{BTreeMap, HashMap},
    io::{BufRead, BufReader},
    path::Path,
};

#[derive(Default)]
struct Evidence {
    turn: Pending,
    steps: HashMap<String, Option<i64>>,
    usage: BTreeMap<i64, usize>,
    model: Option<String>,
    request_model: Option<String>,
}

impl Evidence {
    fn record(mut self, out: &mut ParseOutcome) {
        let mut counts = BTreeMap::<i64, usize>::new();
        for value in self.steps.values().copied().flatten() {
            *counts.entry(value).or_default() += 1;
        }
        // Step usage and usage.record are independent representations of
        // the same calls. Count the step UUID once; require matching records
        // before using their model attribution.
        if self.steps.values().any(Option::is_none) || counts != self.usage {
            self.turn.reopen();
        }
        if let Some(model) = self.model {
            for (id, usage) in self.steps {
                if let Some(usage) = usage {
                    // Pending.response clears a provisional end on a newly
                    // seen response. Preserve the wire's already known end.
                    let end = self.turn.end.take();
                    self.turn.response(&id, &model, Some(usage), None);
                    self.turn.end = end;
                }
            }
        }
        out.record(self.turn, "kimi");
    }
}

fn model(value: &Value) -> Option<&str> {
    let value = value.as_str()?.trim();
    let value = value.strip_prefix("kimi-code/").unwrap_or(value);
    (!value.is_empty() && !(value.starts_with("__") && value.ends_with("__"))).then_some(value)
}

pub(super) fn parse(path: &Path) -> Result<ParseOutcome> {
    let Some(agent) = path
        .parent()
        .filter(|p| p.file_name().is_some_and(|n| n == "main"))
    else {
        return Ok(ParseOutcome::default());
    };
    let Some(session) = agent
        .parent()
        .filter(|p| p.file_name().is_some_and(|n| n == "agents"))
        .and_then(Path::parent)
        .and_then(Path::file_name)
        .and_then(|n| n.to_str())
    else {
        return Ok(ParseOutcome::default());
    };
    parse_wire(BufReader::new(std::fs::File::open(path)?), session)
}

fn parse_wire(reader: impl BufRead, session: &str) -> Result<ParseOutcome> {
    let mut result = ParseOutcome::default();
    let mut active = None::<Evidence>;
    let mut cwd = String::new();
    let mut damaged = false;
    for line in reader.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let Ok(d) = serde_json::from_str::<Value>(&line) else {
            damaged = true;
            if let Some(t) = &mut active {
                t.turn.invalid = true;
            }
            continue;
        };
        if d["agentId"] != "main" {
            continue;
        }
        let kind = d["type"].as_str().unwrap_or("");
        if kind == "forked" {
            // The journal carries the inherited prefix before this marker.
            result = ParseOutcome::default();
            active = None;
            continue;
        }
        if kind == "config.update" {
            cwd = super::project(d["cwd"].as_str().unwrap_or(""));
            continue;
        }
        if kind == "turn.prompt" {
            if let Some(t) = active.take() {
                t.record(&mut result);
            }
            if d["origin"]["kind"] == "user" && d["trigger"] == "normal" {
                if let (Some(id), Some(start)) = (d["turnId"].as_u64(), d["time"].as_i64()) {
                    active = Some(Evidence {
                        turn: Pending {
                            id: id.to_string(),
                            session: session.into(),
                            project: cwd.clone(),
                            start,
                            ..Default::default()
                        },
                        ..Default::default()
                    });
                }
            }
            continue;
        }
        let Some(t) = &mut active else { continue };
        match kind {
            "llm.request" if d["kind"] == "loop" => {
                t.turn.reopen();
                t.request_model = model(&d["model"]).map(str::to_owned);
            }
            "usage.record" if d["usageScope"] == "turn" => {
                t.turn.reopen();
                let reported = model(&d["model"]).or(t.request_model.as_deref());
                if let (Some(output), Some(reported)) =
                    (d["usage"]["output"].as_i64().filter(|n| *n >= 0), reported)
                {
                    if t.model.as_deref().is_some_and(|old| old != reported)
                        || t.request_model
                            .as_deref()
                            .is_some_and(|request| request != reported)
                    {
                        t.turn.invalid = true;
                    }
                    t.model = Some(reported.into());
                    *t.usage.entry(output).or_default() += 1;
                } else {
                    t.turn.invalid = true;
                }
                t.request_model = None;
            }
            "context.append_loop_event" => {
                let event = &d["event"];
                if event["turnId"].as_str() != Some(t.turn.id.as_str()) {
                    continue;
                }
                match event["type"].as_str() {
                    Some("step.begin") => {
                        t.turn.reopen();
                        if let Some(id) = event["uuid"].as_str().filter(|s| !s.is_empty()) {
                            t.steps.entry(id.into()).or_default();
                        } else {
                            t.turn.invalid = true;
                        }
                    }
                    Some("step.end") => {
                        let output = event["usage"]["output"].as_i64().filter(|n| *n >= 0);
                        if let Some(value) =
                            event["uuid"].as_str().and_then(|id| t.steps.get_mut(id))
                        {
                            if *value != output {
                                t.turn.reopen();
                            }
                            if value.is_some() && *value != output {
                                t.turn.invalid = true;
                            }
                            *value = output;
                        } else {
                            t.turn.invalid = true;
                        }
                    }
                    Some("tool.call") => {
                        if let Some(id) = event["toolCallId"].as_str().filter(|s| !s.is_empty()) {
                            if t.turn.tools.insert(id.into()) {
                                t.turn.reopen();
                            }
                        } else {
                            t.turn.invalid = true;
                        }
                    }
                    _ => {}
                }
            }
            "turn.ended"
                if d["turnId"]
                    .as_u64()
                    .is_some_and(|id| id.to_string() == t.turn.id) =>
            {
                if d["reason"] == "completed" {
                    t.turn.end = d["time"].as_i64();
                } else {
                    t.turn.reopen();
                }
            }
            _ => {}
        }
    }
    if let Some(t) = active {
        t.record(&mut result);
    }
    if damaged {
        result.invalidated_ids.clear();
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn rows() -> Vec<Value> {
        vec![
            json!({"agentId":"main","type":"turn.prompt","turnId":2,"origin":{"kind":"user"},"trigger":"normal","time":1000}),
            json!({"agentId":"main","type":"context.append_loop_event","event":{"type":"step.begin","uuid":"step-id","turnId":"2"}}),
            json!({"agentId":"main","type":"llm.request","kind":"loop","model":"kimi-code/concrete"}),
            json!({"agentId":"main","type":"usage.record","usageScope":"turn","model":"__symbolic__","usage":{"output":8}}),
            json!({"agentId":"main","type":"context.append_loop_event","event":{"type":"tool.call","turnId":"2","toolCallId":"call"}}),
            json!({"agentId":"main","type":"context.append_loop_event","event":{"type":"step.end","uuid":"step-id","turnId":"2","usage":{"output":8}}}),
            json!({"agentId":"main","type":"turn.ended","turnId":2,"reason":"completed","time":3000}),
        ]
    }
    fn parse(rows: &[Value]) -> ParseOutcome {
        let text = rows
            .iter()
            .map(Value::to_string)
            .collect::<Vec<_>>()
            .join("\n");
        parse_wire(text.as_bytes(), "session").unwrap()
    }
    #[test]
    fn completed_measured_main_agent_turns() {
        let mut rows = rows();
        rows.insert(6, rows[5].clone());
        let result = parse(&rows);
        assert_eq!(result.turns.len(), 1);
        let turn = &result.turns[0];
        assert_eq!(
            (
                turn.generated_tokens,
                turn.requests,
                turn.tool_calls,
                turn.duration_ms
            ),
            (8, Some(1), Some(1), 2000)
        );
        assert_eq!(turn.model, "concrete");
        assert_eq!(turn.reasoning_tokens, None);
        rows.last_mut().unwrap()["reason"] = "cancelled".into();
        assert!(parse(&rows).turns.is_empty());
    }
    #[test]
    fn conflicting_or_unpaired_usage_is_not_a_measured_turn() {
        let mut rows = rows();
        rows[3]["usage"]["output"] = 9.into();
        assert!(parse(&rows).turns.is_empty());
        rows[3]["usage"]["output"] = 8.into();
        rows.insert(6, rows[3].clone());
        assert!(parse(&rows).turns.is_empty());
    }
}
