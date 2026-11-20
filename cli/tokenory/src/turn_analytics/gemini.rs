// [INPUT]: Gemini CLI headless --output-format stream-json.
// [OUTPUT]: User-to-result duration and source-reported single-model output.
// [POS]: Does not infer requests or reasoning from partial stream messages.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
use super::{ms, ParseOutcome};
use crate::codex_turns::CodexTurn;
use anyhow::Result;
use serde_json::Value;
use std::{
    io::{BufRead, BufReader},
    path::Path,
};

pub(super) fn parse(path: &Path) -> Result<ParseOutcome> {
    if path.extension().and_then(|s| s.to_str()) != Some("jsonl") {
        return Ok(ParseOutcome::default());
    }
    parse_stream(BufReader::new(std::fs::File::open(path)?))
}

fn parse_stream(reader: impl BufRead) -> Result<ParseOutcome> {
    let mut result = ParseOutcome::default();
    let mut session = None::<String>;
    let mut start = None;
    let mut terminal = None;
    let mut failed = false;
    for line in reader.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let Ok(d) = serde_json::from_str::<Value>(&line) else {
            return Ok(ParseOutcome::default());
        };
        match d["type"].as_str() {
            Some("init") if session.is_none() && start.is_none() && terminal.is_none() => {
                session = d["session_id"]
                    .as_str()
                    .filter(|id| !id.is_empty())
                    .map(str::to_owned);
            }
            Some("message")
                if d["role"] == "user"
                    && session.is_some()
                    && start.is_none()
                    && terminal.is_none() =>
            {
                start = ms(&d["timestamp"]);
                failed |= start.is_none();
            }
            Some("result") if terminal.is_none() && d["status"] == "success" => {
                terminal = Some(d);
            }
            Some("error" | "result" | "init") => {
                failed = true;
            }
            Some("message") if d["role"] == "user" || terminal.is_some() => {
                failed = true;
            }
            _ => {}
        }
    }
    let Some((session, start, terminal)) = session
        .zip(start)
        .zip(terminal)
        .map(|((session, start), terminal)| (session, start, terminal))
    else {
        return Ok(result);
    };
    let turn_id = start.to_string();
    let id = serde_json::to_string(&("gemini", &session, &turn_id))?;
    if failed {
        result.invalidated_ids.push(id);
        return Ok(result);
    }
    let stats = &terminal["stats"];
    let Some(models) = stats["models"].as_object().filter(|map| map.len() == 1) else {
        return Ok(result);
    };
    let Some((model, usage)) = models
        .iter()
        .next()
        .filter(|(model, _)| !model.trim().is_empty())
    else {
        return Ok(result);
    };
    let Some(output) = usage["output_tokens"].as_i64().filter(|n| *n > 0) else {
        return Ok(result);
    };
    let Some(end) = ms(&terminal["timestamp"]) else {
        return Ok(result);
    };
    let Some(tools) = stats["tool_calls"].as_i64().filter(|n| *n >= 0) else {
        return Ok(result);
    };
    let Some(input) = usage["input_tokens"].as_i64().filter(|n| *n >= 0) else {
        return Ok(result);
    };
    let Some(total) = usage["total_tokens"].as_i64().filter(|n| *n > 0) else {
        return Ok(result);
    };
    if tools != 0 || input.checked_add(output) != Some(total) {
        return Ok(result);
    }
    let Some(duration) = end.checked_sub(start).filter(|d| *d > 0) else {
        return Ok(result);
    };
    result.turns.push(CodexTurn {
        id,
        client: "gemini".into(),
        duration_estimated: true,
        session_id: session,
        turn_id,
        project: String::new(),
        model: model.clone(),
        effort: None,
        inference_speed: None,
        start_ms: start,
        end_ms: end,
        duration_ms: duration,
        ttft_ms: None,
        // The formatter reports candidates, without all generated reasoning.
        // Only emit this when accounting also proves no hidden output below.
        generated_tokens: output,
        reasoning_tokens: Some(0),
        requests: None,
        tool_calls: Some(tools),
        tool_wait_ms: None,
    });
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn headless_terminal_counts_only_fully_accounted_generation() {
        let input = r#"{"type":"init","session_id":"session","timestamp":"2026-11-14T00:00:00Z","model":"requested"}
{"type":"message","role":"user","timestamp":"2026-11-14T00:00:01Z"}
{"type":"result","status":"success","timestamp":"2026-11-14T00:00:04Z","stats":{"tool_calls":0,"models":{"actual":{"input_tokens":60,"output_tokens":10,"total_tokens":70}}}}"#;
        let parsed = parse_stream(input.as_bytes()).unwrap();
        let t = &parsed.turns[0];
        assert_eq!(
            (
                t.model.as_str(),
                t.generated_tokens,
                t.reasoning_tokens,
                t.duration_ms,
                t.requests
            ),
            ("actual", 10, Some(0), 3000, None)
        );
        for invalid in [
            input.replace(r#""total_tokens":70"#, r#""total_tokens":72"#),
            input.replace(r#""tool_calls":0"#, r#""tool_calls":1"#),
            input.replace("success", "error"),
        ] {
            assert!(parse_stream(invalid.as_bytes()).unwrap().turns.is_empty());
        }
    }
}
