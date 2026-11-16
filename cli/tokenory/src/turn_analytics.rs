// [INPUT]: Native transcripts, agent databases, and the client catalog.
// [OUTPUT]: Completed turns with timestamp-estimated duration and explicit source capabilities.
// [POS]: Additional-client parsing boundary; never retain message or tool content.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
mod cline;
mod gemini;
mod kimi;
mod qwen;

use crate::{
    codex_turns::CodexTurn,
    db::{revision, Database},
    queries::Filter,
};
use anyhow::{ensure, Result};
use rusqlite::{params, Connection, OpenFlags};
use serde::Serialize;
use serde_json::Value;
use std::{
    collections::{BTreeSet, HashMap, HashSet},
    io::BufRead,
    path::{Path, PathBuf},
    time::SystemTime,
};
fn ms(v: &Value) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(v.as_str()?)
        .ok()
        .map(|t| t.timestamp_millis())
}
fn project(p: &str) -> String {
    Path::new(p)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .into()
}
#[derive(Default)]
struct Pending {
    session: String,
    id: String,
    project: String,
    start: i64,
    end: Option<i64>,
    invalid: bool,
    reopened: bool,
    responses: HashMap<String, (String, i64, Option<i64>)>,
    latest_response: Option<String>,
    tools: HashSet<String>,
}
#[derive(Clone, Default)]
pub struct ParseOutcome {
    pub turns: Vec<CodexTurn>,
    pub invalidated_ids: Vec<String>,
    pub covered_ids: HashSet<String>,
}
impl ParseOutcome {
    fn record(&mut self, pending: Pending, client: &str) {
        let id = serde_json::to_string(&(client, &pending.session, &pending.id))
            .expect("string identity");
        if client == "opencode" {
            self.covered_ids.insert(id.clone());
        }
        let should_invalidate = pending.reopened
            || (!pending.invalid && !pending.session.is_empty() && !pending.id.is_empty());
        if let Some(turn) = pending.finish(client) {
            self.invalidated_ids.retain(|old| old != &id);
            self.turns.retain(|t| t.id != id);
            self.turns.push(turn);
        } else if should_invalidate {
            self.turns.retain(|t| t.id != id);
            self.invalidated_ids.push(id);
        }
    }
}
impl Pending {
    fn reopen(&mut self) {
        self.reopened |= self.end.take().is_some();
    }
    fn response(&mut self, id: &str, model: &str, output: Option<i64>, reasoning: Option<i64>) {
        if !self.responses.contains_key(id) {
            self.reopen();
            self.latest_response = Some(id.into());
        }
        let Some(output) = output.filter(|n| *n >= 0) else {
            self.invalid = true;
            return;
        };
        if id.is_empty() || model.is_empty() || reasoning.is_some_and(|n| n < 0 || n > output) {
            self.invalid = true;
            return;
        }
        let value = (model.to_owned(), output, reasoning);
        if let Some(old) = self.responses.get(id) {
            // Repeated content blocks share a response ID and a cumulative usage.
            if old.0 != model || old.1 > output {
                self.invalid = true;
                return;
            }
        }
        if self.responses.get(id).is_some_and(|old| old != &value) {
            self.reopen();
        }
        self.responses.insert(id.into(), value);
    }
    fn finish(self, client: &str) -> Option<CodexTurn> {
        let end = self.end?;
        let duration = end.checked_sub(self.start)?;
        if self.invalid
            || self.session.is_empty()
            || self.id.is_empty()
            || self.start < 0
            || duration <= 0
            || self.responses.is_empty()
        {
            return None;
        }
        let models = self
            .responses
            .values()
            .map(|r| r.0.as_str())
            .collect::<BTreeSet<_>>();
        if models.len() != 1 {
            return None;
        }
        let generated = self
            .responses
            .values()
            .try_fold(0i64, |n, r| n.checked_add(r.1))?;
        let reasoning = self
            .responses
            .values()
            .try_fold(0i64, |n, r| n.checked_add(r.2?));
        Some(CodexTurn {
            id: serde_json::to_string(&(client, &self.session, &self.id)).ok()?,
            client: client.into(),
            duration_estimated: true,
            session_id: self.session,
            turn_id: self.id,
            project: self.project,
            model: models.into_iter().next()?.into(),
            effort: None,
            start_ms: self.start,
            end_ms: end,
            duration_ms: duration,
            ttft_ms: None,
            generated_tokens: generated,
            reasoning_tokens: reasoning,
            requests: Some(self.responses.len() as i64),
            tool_calls: Some(self.tools.len() as i64),
            tool_wait_ms: None,
        })
    }
}
pub fn parse_claude(reader: impl BufRead) -> Result<Vec<CodexTurn>> {
    Ok(parse_claude_outcome(reader)?.turns)
}
pub fn parse_claude_outcome(reader: impl BufRead) -> Result<ParseOutcome> {
    let mut current = None::<Pending>;
    let mut result = ParseOutcome::default();
    let mut damaged = false;
    for line in reader.lines() {
        let line = line?;
        let Ok(d) = serde_json::from_str::<Value>(&line) else {
            damaged |= !line.trim().is_empty();
            if let Some(t) = &mut current {
                t.invalid = true;
            }
            continue;
        };
        if d["isSidechain"] == true || d.get("agentId").is_some_and(|v| !v.is_null()) {
            continue;
        }
        let m = &d["message"];
        let kind = d["type"].as_str().unwrap_or("");
        let content = &m["content"];
        let human = kind == "user"
            && d["isMeta"] != true
            && (content.is_string()
                || content.as_array().is_some_and(|a| {
                    a.iter().any(|b| b["type"] == "text")
                        && !a.iter().any(|b| b["type"] == "tool_result")
                }));
        if human {
            if let Some(t) = current.take() {
                result.record(t, "claude");
            }
            if let (Some(start), Some(id), Some(session)) = (
                ms(&d["timestamp"]),
                d["uuid"].as_str(),
                d["sessionId"].as_str(),
            ) {
                current = Some(Pending {
                    session: session.into(),
                    id: id.into(),
                    project: project(d["cwd"].as_str().unwrap_or("")),
                    start,
                    ..Default::default()
                });
            }
            continue;
        }
        let Some(t) = &mut current else { continue };
        if kind == "user"
            && d["isMeta"] == true
            && (content.is_string()
                || content
                    .as_array()
                    .is_some_and(|a| a.iter().any(|b| b["type"] == "text")))
        {
            t.reopen();
        }
        if kind != "assistant" {
            continue;
        }
        if d["sessionId"].as_str() != Some(t.session.as_str()) {
            t.invalid = true;
            continue;
        }
        let reasoning = m["usage"]["output_tokens_details"].get("thinking_tokens");
        if reasoning.is_some_and(|v| !v.is_null() && v.as_i64().is_none()) {
            t.invalid = true;
        }
        t.response(
            m["id"].as_str().unwrap_or(""),
            m["model"].as_str().unwrap_or(""),
            m["usage"]["output_tokens"].as_i64(),
            reasoning.and_then(Value::as_i64),
        );
        if let Some(blocks) = content.as_array() {
            for b in blocks {
                if b["type"] == "tool_use" {
                    if let Some(id) = b["id"].as_str() {
                        t.tools.insert(id.into());
                    } else {
                        t.invalid = true;
                    }
                }
            }
        }
        if matches!(
            m["stop_reason"].as_str(),
            Some("end_turn" | "stop_sequence")
        ) && t.latest_response.as_deref() == m["id"].as_str()
        {
            t.end = ms(&d["timestamp"]);
        }
    }
    if let Some(t) = current {
        result.record(t, "claude");
    }
    // A partial/corrupt log is not authoritative evidence for deleting history.
    if damaged {
        result.invalidated_ids.clear();
    }
    Ok(result)
}
pub fn parse_devin(path: &Path) -> Result<Vec<CodexTurn>> {
    Ok(parse_devin_outcome(path)?.turns)
}
pub fn parse_devin_outcome(path: &Path) -> Result<ParseOutcome> {
    let c = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    c.execute_batch("BEGIN;")?;
    let sessions = {
        let mut s=c.prepare("SELECT id,working_directory,main_chain_id FROM sessions WHERE main_chain_id IS NOT NULL")?;
        let rows = s
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, i64>(2)?,
                ))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        rows
    };
    let mut result = ParseOutcome::default();
    let mut damaged = false;
    for (session, cwd, head) in sessions {
        let nodes = {
            let mut s = c.prepare(
                "SELECT node_id,parent_node_id,chat_message FROM message_nodes WHERE session_id=?1",
            )?;
            let rows = s
                .query_map([&session], |r| {
                    Ok((
                        r.get::<_, i64>(0)?,
                        (r.get::<_, Option<i64>>(1)?, r.get::<_, String>(2)?),
                    ))
                })?
                .collect::<rusqlite::Result<HashMap<_, _>>>()?;
            rows
        };
        let mut chain = Vec::new();
        let mut cursor = Some(head);
        let mut seen = HashSet::new();
        let mut valid = true;
        while let Some(id) = cursor {
            if !seen.insert(id) {
                valid = false;
                break;
            }
            let Some((parent, body)) = nodes.get(&id) else {
                valid = false;
                break;
            };
            chain.push((id, body));
            cursor = *parent;
        }
        if !valid {
            continue;
        }
        chain.reverse();
        let mut current = None::<Pending>;
        for (node, body) in chain {
            let Ok(d) = serde_json::from_str::<Value>(body) else {
                damaged = true;
                if let Some(t) = &mut current {
                    t.invalid = true
                }
                continue;
            };
            let m = &d["metadata"];
            if d["role"] == "user" && m["is_user_input"] == true {
                if let Some(t) = current.take() {
                    result.record(t, "devin-cli");
                }
                if let Some(start) = ms(&m["created_at"]) {
                    current = Some(Pending {
                        session: session.clone(),
                        id: d["message_id"]
                            .as_str()
                            .map(str::to_owned)
                            .unwrap_or_else(|| node.to_string()),
                        project: project(&cwd),
                        start,
                        ..Default::default()
                    });
                }
                continue;
            }
            let Some(t) = &mut current else { continue };
            if d["role"] != "assistant" {
                continue;
            }
            t.response(
                m["request_id"].as_str().unwrap_or(""),
                m["generation_model"]
                    .as_str()
                    .filter(|s| *s != "adaptive")
                    .unwrap_or(""),
                m["metrics"]["output_tokens"].as_i64(),
                None,
            );
            if let Some(calls) = d["tool_calls"].as_array() {
                for call in calls {
                    if let Some(id) = call["id"].as_str() {
                        t.tools.insert(id.into());
                    } else {
                        t.invalid = true
                    }
                }
            }
            if m["finish_reason"] == "stop"
                && t.latest_response.as_deref() == m["request_id"].as_str()
            {
                t.end = ms(&m["created_at"]);
            }
        }
        if let Some(t) = current {
            result.record(t, "devin-cli");
        }
    }
    if damaged {
        result.invalidated_ids.clear();
    }
    Ok(result)
}
/// OpenCode-family `parentID` links requests to their human prompt. A completed
/// request alone is insufficient: a final `finish=stop` closes the whole turn.
pub fn parse_opencode(path: &Path, client: &str) -> Result<Vec<CodexTurn>> {
    Ok(parse_opencode_outcome(path, client)?.turns)
}
pub fn parse_opencode_outcome(path: &Path, client: &str) -> Result<ParseOutcome> {
    let c = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    c.execute_batch("BEGIN;")?;
    let (mut result, owned) = parse_opencode_v2(&c, client)?;
    let has_legacy: bool = c.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='message')",
        [],
        |r| r.get(0),
    )?;
    if !has_legacy {
        return Ok(result);
    }
    let sessions = {
        let mut s = c.prepare(
            "SELECT id,directory FROM session WHERE parent_id IS NULL AND revert IS NULL",
        )?;
        let rows = s
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        rows
    };
    let mut damaged = false;
    for (session, cwd) in sessions {
        if owned.contains(&session) {
            continue;
        }
        let messages = {
            let mut s = c.prepare(
                "SELECT id,data FROM message WHERE session_id=?1 ORDER BY time_created,id",
            )?;
            let rows = s
                .query_map([&session], |r| {
                    Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            rows
        };
        let mut pending = HashMap::<String, Pending>::new();
        for (id, body) in &messages {
            let Ok(d) = serde_json::from_str::<Value>(body) else {
                damaged = true;
                continue;
            };
            if d["role"] == "user" {
                if let Some(start) = d["time"]["created"].as_i64() {
                    pending.insert(
                        id.clone(),
                        Pending {
                            session: session.clone(),
                            id: id.clone(),
                            project: project(&cwd),
                            start,
                            ..Default::default()
                        },
                    );
                }
            }
        }
        for (id, body) in messages {
            let Ok(d) = serde_json::from_str::<Value>(&body) else {
                damaged = true;
                continue;
            };
            if d["role"] != "assistant" {
                continue;
            }
            let Some(t) = d["parentID"].as_str().and_then(|id| pending.get_mut(id)) else {
                continue;
            };
            if !t.responses.contains_key(&id) {
                t.reopen();
            }
            if d.get("error").is_some_and(|v| !v.is_null()) {
                t.reopened = true;
            }
            if d.get("error").is_some_and(|v| !v.is_null())
                || d["agent"]
                    .as_str()
                    .is_some_and(|a| !matches!(a, "main" | "build" | "plan"))
            {
                t.invalid = true;
                continue;
            }
            opencode_response(t, &id, &d);
            let mut parts = c.prepare(
                "SELECT id FROM part WHERE message_id=?1 AND json_extract(data,'$.type')='tool'",
            )?;
            for part in parts.query_map([&id], |r| r.get::<_, String>(0))? {
                t.tools.insert(part?);
            }
            if d["finish"] == "stop" && t.latest_response.as_deref() == Some(id.as_str()) {
                t.end = d["time"]["completed"].as_i64();
            }
        }
        for t in pending.into_values() {
            result.record(t, client);
        }
    }
    if damaged {
        result.invalidated_ids.clear();
    }
    Ok(result)
}
/// Match the v1 JSON storage keys: session/<project>/<session>.json,
/// message/<session>/<message>.json and part/<message>/<part>.json.
pub fn parse_opencode_legacy(paths: &[PathBuf]) -> Result<ParseOutcome> {
    let mut by_root = HashMap::<&Path, Vec<&Path>>::new();
    for path in paths {
        let Some(root) = path.parent().and_then(Path::parent).and_then(Path::parent) else {
            continue;
        };
        if root.join("session").is_dir() {
            by_root.entry(root).or_default().push(path);
        }
    }
    let mut result = ParseOutcome::default();
    for (root, messages) in by_root {
        let mut sessions = HashMap::new();
        for project_dir in std::fs::read_dir(root.join("session"))? {
            let project_dir = project_dir?;
            if !project_dir.file_type()?.is_dir() {
                continue;
            }
            for path in std::fs::read_dir(project_dir.path())? {
                let path = path?.path();
                if path.extension().and_then(|s| s.to_str()) != Some("json") {
                    continue;
                }
                let Ok(info) = read_json(&path) else { continue };
                if let Some(id) = info["id"]
                    .as_str()
                    .filter(|_| info["parentID"].is_null() && info["revert"].is_null())
                {
                    sessions.insert(
                        id.to_owned(),
                        project(info["directory"].as_str().unwrap_or("")),
                    );
                }
            }
        }
        let mut by_session = HashMap::<String, Vec<Value>>::new();
        let mut damaged = false;
        for path in messages {
            let Ok(d) = read_json(path) else {
                damaged = true;
                continue;
            };
            if let Some(id) = d["sessionID"]
                .as_str()
                .filter(|id| sessions.contains_key(*id))
            {
                by_session.entry(id.into()).or_default().push(d);
            }
        }
        for (session, mut messages) in by_session {
            messages.sort_by(|a, b| {
                (a["time"]["created"].as_i64(), a["id"].as_str())
                    .cmp(&(b["time"]["created"].as_i64(), b["id"].as_str()))
            });
            let mut pending = HashMap::<String, Pending>::new();
            for d in messages.iter().filter(|d| d["role"] == "user") {
                if let (Some(id), Some(start)) = (d["id"].as_str(), d["time"]["created"].as_i64()) {
                    pending.insert(
                        id.to_owned(),
                        Pending {
                            session: session.clone(),
                            id: id.to_owned(),
                            project: sessions[&session].clone(),
                            start,
                            ..Default::default()
                        },
                    );
                }
            }
            let mut seen = HashSet::new();
            for d in messages.iter().filter(|d| d["role"] == "assistant") {
                let Some(t) = d["parentID"].as_str().and_then(|id| pending.get_mut(id)) else {
                    continue;
                };
                t.reopen();
                let Some(id) = d["id"].as_str().filter(|id| {
                    id.starts_with("msg_")
                        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
                        && seen.insert(*id)
                }) else {
                    t.invalid = true;
                    continue;
                };
                if d.get("error").is_some_and(|e| !e.is_null()) || d["summary"] == true {
                    t.invalid = true;
                    continue;
                }
                opencode_response(t, id, d);
                match std::fs::read_dir(root.join("part").join(id)) {
                    Ok(parts) => {
                        for part in parts {
                            let path = part?.path();
                            if path.extension().and_then(|s| s.to_str()) != Some("json") {
                                continue;
                            }
                            match read_json(&path) {
                                Ok(p) if p["type"] == "tool" => {
                                    if let Some(id) = p["id"].as_str() {
                                        t.tools.insert(id.into());
                                    } else {
                                        t.invalid = true;
                                    }
                                }
                                Ok(_) => {}
                                Err(_) => {
                                    t.invalid = true;
                                    damaged = true;
                                }
                            }
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                    Err(e) => return Err(e.into()),
                }
                if d["finish"] == "stop" {
                    t.end = d["time"]["completed"].as_i64();
                }
            }
            for t in pending.into_values() {
                result.record(t, "opencode");
            }
        }
        if damaged {
            result.invalidated_ids.clear();
        }
    }
    Ok(result)
}

fn read_json(path: &Path) -> Result<Value> {
    Ok(serde_json::from_reader(std::io::BufReader::new(
        std::fs::File::open(path)?,
    ))?)
}

/// V2 persists an explicit idle outcome instead of v1 assistant parent links.
fn parse_opencode_v2(c: &Connection, client: &str) -> Result<(ParseOutcome, HashSet<String>)> {
    let present: bool = c.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='session_message')",
        [],
        |r| r.get(0),
    )?;
    if !present {
        return Ok((ParseOutcome::default(), HashSet::new()));
    }
    let mut owned = c.prepare("SELECT DISTINCT session_id FROM session_message")?;
    let owned = owned
        .query_map([], |r| r.get::<_, String>(0))?
        .collect::<rusqlite::Result<HashSet<_>>>()?;
    let tracks_fork: bool = c.query_row(
        "SELECT EXISTS(SELECT 1 FROM pragma_table_info('session_v2') WHERE name='fork_session_id')",
        [],
        |r| r.get(0),
    )?;
    let mut sessions = c.prepare(if tracks_fork {
        "SELECT id,directory FROM session_v2 WHERE parent_id IS NULL AND revert IS NULL AND fork_session_id IS NULL"
    } else {
        "SELECT id,directory FROM session_v2 WHERE parent_id IS NULL AND revert IS NULL"
    })?;
    let mut messages =
        c.prepare("SELECT id,type,data FROM session_message WHERE session_id=?1 ORDER BY seq")?;
    let mut result = ParseOutcome::default();
    for session in
        sessions.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?
    {
        let (session, cwd) = session?;
        let mut pending = None::<Pending>;
        let mut damaged = false;
        let mut partial = ParseOutcome::default();
        let mut rows = messages.query([&session])?;
        while let Some(row) = rows.next()? {
            let id: String = row.get(0)?;
            let kind: String = row.get(1)?;
            if !matches!(kind.as_str(), "user" | "assistant" | "idle") {
                continue;
            }
            let Ok(d) = serde_json::from_str::<Value>(&row.get::<_, String>(2)?) else {
                damaged = true;
                if let Some(t) = &mut pending {
                    t.invalid = true;
                }
                continue;
            };
            if kind == "user" {
                if let Some(t) = pending.take() {
                    partial.record(t, client);
                }
                if let Some(start) = d["time"]["created"].as_i64() {
                    pending = Some(Pending {
                        session: session.clone(),
                        id,
                        project: project(&cwd),
                        start,
                        ..Default::default()
                    });
                }
            } else if let Some(t) = &mut pending {
                if kind == "assistant" {
                    t.reopen();
                    if d.get("error").is_some_and(|e| !e.is_null())
                        || d["time"]["completed"].as_i64().is_none()
                        || d["content"].as_array().is_none()
                    {
                        t.invalid = true;
                        continue;
                    }
                    opencode_response(t, &id, &d);
                    for part in d["content"].as_array().into_iter().flatten() {
                        if part["type"] == "tool" {
                            if let Some(id) = part["id"].as_str() {
                                t.tools.insert(id.into());
                            } else {
                                t.invalid = true;
                            }
                        }
                    }
                } else if d["outcome"] == "succeeded" {
                    t.end = d["time"]["created"].as_i64();
                } else {
                    t.reopen();
                }
            }
        }
        if let Some(t) = pending {
            partial.record(t, client);
        }
        result.turns.extend(partial.turns);
        result.covered_ids.extend(partial.covered_ids);
        if !damaged {
            result.invalidated_ids.extend(partial.invalidated_ids);
        }
    }
    Ok((result, owned))
}

fn opencode_response(t: &mut Pending, id: &str, d: &Value) {
    // OpenCode reports text output and reasoning in distinct buckets. Without
    // both values, generated tokens cannot be reconstructed.
    let output = d["tokens"]["output"].as_i64().filter(|n| *n >= 0);
    let reasoning = d["tokens"]["reasoning"].as_i64().filter(|n| *n >= 0);
    t.response(
        id,
        d["modelID"]
            .as_str()
            .or_else(|| d["model"]["id"].as_str())
            .unwrap_or(""),
        output.and_then(|o| reasoning.and_then(|r| o.checked_add(r))),
        reasoning,
    );
}

/// Pi and OpenClaw persist timestamped, linked user/assistant messages. Use the
/// entry timestamp: the inner assistant timestamp may be its creation time.
pub fn parse_linked_transcript(
    reader: impl BufRead,
    client: &str,
    stored_session: Option<&str>,
) -> Result<ParseOutcome> {
    parse_linked_entries(reader.lines(), client, stored_session)
}

fn parse_linked_entries(
    lines: impl IntoIterator<Item = std::io::Result<String>>,
    client: &str,
    stored_session: Option<&str>,
) -> Result<ParseOutcome> {
    let mut session = stored_session.unwrap_or_default().to_owned();
    let mut cwd = String::new();
    let mut result = ParseOutcome::default();
    let mut current = None::<Pending>;
    let mut seen = HashMap::<String, [u8; 32]>::new();
    let mut header = false;
    let mut tail = None::<String>;
    let mut damaged = false;
    for line in lines {
        let line = line?;
        let line = line.trim().trim_start_matches('\u{feff}');
        if line.is_empty() {
            continue;
        }
        let Ok(d) = serde_json::from_str::<Value>(line) else {
            damaged = true;
            if let Some(t) = &mut current {
                t.invalid = true;
            }
            continue;
        };
        if d["type"] == "session" {
            if header || tail.is_some() {
                return Ok(ParseOutcome::default());
            }
            header = true;
            if d["parentSession"].is_string() || d["rlmDepth"].as_u64().is_some_and(|n| n > 0) {
                // A fork can replay its parent's history with a new session ID.
                return Ok(ParseOutcome::default());
            }
            session = d["id"].as_str().unwrap_or(&session).to_owned();
            cwd = project(d["cwd"].as_str().unwrap_or(""));
            continue;
        }
        let Some(id) = d["id"].as_str().filter(|s| !s.is_empty()) else {
            if d["type"] == "message" {
                damaged = true;
                if let Some(t) = &mut current {
                    t.invalid = true;
                }
            }
            continue;
        };
        // Duplicate copies are common in archived logs. Conflicting entries
        // and branch changes have no authoritative head in this format.
        use sha2::Digest;
        let fingerprint: [u8; 32] = sha2::Sha256::digest(line).into();
        if let Some(old) = seen.get(id) {
            if old != &fingerprint {
                return Ok(ParseOutcome::default());
            }
            continue;
        }
        if d.get("parentId").is_none()
            || d["parentId"].as_str() != tail.as_deref()
            || (!d["parentId"].is_null() && !d["parentId"].is_string())
        {
            return Ok(ParseOutcome::default());
        }
        tail = Some(id.into());
        let message = &d["message"];
        if d["type"] == "message" && message["role"] == "user" {
            if let Some(t) = current.take() {
                result.record(t, client);
            }
            if let Some(start) = ms(&d["timestamp"]) {
                current = Some(Pending {
                    session: session.clone(),
                    id: id.into(),
                    project: cwd.clone(),
                    start,
                    ..Default::default()
                });
            }
        } else if let Some(t) = &mut current {
            if d["type"] == "message" && message["role"] == "assistant" {
                let source_model = message["model"].as_str().unwrap_or("");
                if message["api"] == "openclaw-transcript"
                    || matches!(source_model, "delivery-mirror" | "gateway-injected")
                {
                    seen.insert(id.into(), fingerprint);
                    continue;
                }
                if message["idempotencyKey"]
                    .as_str()
                    .is_some_and(|s| s.starts_with("codex-app-server:"))
                    || message["__openclaw"]["mirrorOrigin"] == "codex-app-server"
                {
                    t.invalid = true;
                }
                let model = message["responseModel"]
                    .as_str()
                    .filter(|s| !s.is_empty())
                    .unwrap_or(source_model);
                let usage = &message["usage"];
                let reasoning = usage.get(if client == "pi" {
                    "reasoning"
                } else {
                    "reasoningTokens"
                });
                if reasoning.is_some_and(|r| !r.is_null() && r.as_i64().is_none()) {
                    t.invalid = true;
                }
                t.response(
                    id,
                    model,
                    usage["output"].as_i64(),
                    reasoning.and_then(Value::as_i64),
                );
                let mut requests_tools = false;
                if let Some(blocks) = message["content"].as_array() {
                    for block in blocks {
                        if block["type"] == "toolCall" {
                            requests_tools = true;
                            if let Some(tool_id) = block["id"].as_str().filter(|s| !s.is_empty()) {
                                t.tools.insert(tool_id.to_owned());
                            } else {
                                t.invalid = true;
                            }
                        }
                    }
                }
                if message["stopReason"] == "stop" && !requests_tools {
                    t.end = ms(&d["timestamp"]);
                }
            } else if d["type"] == "message" && message["role"] == "toolResult" {
                t.reopen();
            }
        }
        // Comparison hashes keep transcript content out of the retained state.
        seen.insert(id.into(), fingerprint);
    }
    if let Some(t) = current {
        result.record(t, client);
    }
    if damaged {
        result.invalidated_ids.clear();
    }
    Ok(result)
}

fn parse_openclaw_turns(path: &Path) -> Result<ParseOutcome> {
    use tokens_core::sessions::openclaw::{classify_openclaw_jsonl, OpenClawJsonlKind};
    match classify_openclaw_jsonl(path) {
        OpenClawJsonlKind::CodexRollout => {
            let reader = std::io::BufReader::new(std::fs::File::open(path)?);
            return Ok(ParseOutcome {
                turns: crate::codex_turns::parse_client(reader, true, true)?,
                ..ParseOutcome::default()
            });
        }
        OpenClawJsonlKind::CodexHomeOther => return Ok(ParseOutcome::default()),
        OpenClawJsonlKind::Transcript => {}
    }
    if path
        .file_name()
        .and_then(|s| s.to_str())
        .is_some_and(|s| s.starts_with("rollout-"))
    {
        let reader = std::io::BufReader::new(std::fs::File::open(path)?);
        return Ok(ParseOutcome {
            turns: crate::codex_turns::parse_client(reader, true, false)?,
            ..ParseOutcome::default()
        });
    }

    if matches!(
        path.extension().and_then(|s| s.to_str()),
        Some("db" | "sqlite" | "sqlite3")
    ) {
        let c = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
        c.execute_batch("BEGIN;")?;
        let mut sessions = c.prepare("SELECT DISTINCT session_id FROM transcript_events")?;
        let sessions = sessions.query_map([], |row| row.get::<_, String>(0))?;
        let mut result = ParseOutcome::default();
        let mut stmt =
            c.prepare("SELECT event_json FROM transcript_events WHERE session_id=?1 ORDER BY seq")?;
        for session in sessions {
            let session = session?;
            let events = stmt.query_map([&session], |row| row.get::<_, String>(0))?;
            let out = parse_linked_entries(
                events.map(|row| row.map_err(std::io::Error::other)),
                "openclaw",
                Some(&session),
            )?;
            result.turns.extend(out.turns);
            result.invalidated_ids.extend(out.invalidated_ids);
        }
        return Ok(result);
    }
    let file = std::fs::File::open(path)?;
    if path.extension().and_then(|s| s.to_str()) == Some("zst") {
        parse_linked_transcript(
            std::io::BufReader::new(zstd::Decoder::new(file)?),
            "openclaw",
            None,
        )
    } else {
        parse_linked_transcript(std::io::BufReader::new(file), "openclaw", None)
    }
}

#[derive(Default)]
pub struct Cache {
    files: HashMap<(String, PathBuf), (Vec<(u64, SystemTime)>, ParseOutcome)>,
}
impl Cache {
    pub fn read(&mut self, client: &str, path: &Path) -> Result<ParseOutcome> {
        let signature = || -> Result<Vec<(u64, SystemTime)>> {
            let mut paths = vec![path.to_owned()];
            if matches!(
                path.extension().and_then(|s| s.to_str()),
                Some("db" | "sqlite" | "sqlite3")
            ) {
                paths.push(PathBuf::from(format!("{}-wal", path.display())));
            }
            let mut out = vec![];
            for p in paths {
                match std::fs::metadata(p) {
                    Ok(m) => out.push((m.len(), m.modified()?)),
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                    Err(e) => return Err(e.into()),
                }
            }
            Ok(out)
        };
        let before = signature()?;
        let key = (client.into(), path.into());
        if let Some((s, turns)) = self.files.get(&key) {
            if *s == before {
                return Ok(turns.clone());
            }
        }
        let turns = match client {
            "claude" => parse_claude_outcome(std::io::BufReader::new(std::fs::File::open(path)?))?,
            "devin-cli" => parse_devin_outcome(path)?,
            "kilo" | "micode" | "opencode" => parse_opencode_outcome(path, client)?,
            "pi" => parse_linked_transcript(
                std::io::BufReader::new(std::fs::File::open(path)?),
                "pi",
                None,
            )?,
            "openclaw" => parse_openclaw_turns(path)?,
            "kimi" => kimi::parse(path)?,
            "gemini" => gemini::parse(path)?,
            "cline" => cline::parse(path)?,
            "qwen" => qwen::parse(path)?,
            _ => ParseOutcome::default(),
        };
        if signature()? == before {
            self.files.insert(key, (before, turns.clone()));
        }
        Ok(turns)
    }
}
pub const COLLECTED_CLIENTS: &[tokens_core::ClientId] = &[
    tokens_core::ClientId::Claude,
    tokens_core::ClientId::Cline,
    tokens_core::ClientId::DevinCli,
    tokens_core::ClientId::Gemini,
    tokens_core::ClientId::Kilo,
    tokens_core::ClientId::Kimi,
    tokens_core::ClientId::MiMoCode,
    tokens_core::ClientId::OpenCode,
    tokens_core::ClientId::OpenClaw,
    tokens_core::ClientId::Pi,
    tokens_core::ClientId::Qwen,
];

const DELEGATES: &[(&str, &[&str])] = &[("paseo", &["claude", "codex"]), ("orca", &["micode"])];

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Capability {
    client: &'static str,
    supported: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    reason: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    remedy: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    delegate_clients: Option<&'static [&'static str]>,
}

fn capability(client: &'static str) -> Capability {
    let delegate_clients = DELEGATES
        .iter()
        .find_map(|(alias, ids)| (*alias == client).then_some(*ids));
    let supported = client == "codex"
        || delegate_clients.is_some()
        || COLLECTED_CLIENTS.iter().any(|id| id.as_str() == client);
    let (reason, remedy) = match client {
        "paseo" | "orca" => (Some("delegated"), Some("filter_delegates")),
        _ if supported => (None, None),
        "crush" | "droid" | "fx" | "goose" | "hermes" | "mux" | "warp" => {
            (Some("session_totals"), Some("export_turn_events"))
        }
        "jcode" | "roocode" => (Some("missing_attribution"), Some("record_attribution")),
        "antigravity" | "cursor" | "kimi" | "opencodereview" | "reasonix" | "trae" | "zcode" => {
            (Some("request_only"), Some("link_turn_requests"))
        }
        "antigravity-cli" | "copilot" | "grok" | "junie" | "kiro" => {
            (Some("schema_unverified"), Some("verify_schema"))
        }
        "gemini" => (Some("missing_timing"), Some("record_timing")),
        _ => (Some("missing_boundaries"), Some("record_boundaries")),
    };
    Capability {
        client,
        supported,
        reason,
        remedy,
        delegate_clients,
    }
}

#[derive(Serialize)]
pub struct Report {
    revision: i64,
    models: Vec<String>,
    clients: Vec<String>,
    turns: Vec<CodexTurn>,
    capabilities: Vec<Capability>,
}
pub fn query(db: &mut Database, f: &Filter) -> Result<Report> {
    f.validate()?;
    ensure!(
        f.source.as_deref().is_none_or(|s| s == "local") && f.provider.is_none(),
        "turn analytics supports local data only"
    );
    let client = f.client.as_deref();
    let delegates = DELEGATES
        .iter()
        .find_map(|(alias, ids)| (Some(*alias) == client).then_some(*ids));
    let first = delegates.and_then(|ids| ids.first().copied()).or(client);
    let second = delegates.and_then(|ids| ids.get(1).copied());
    let tx = db.connection.transaction()?;
    let clients = {
        let mut s=tx.prepare("SELECT DISTINCT client FROM codex_turns WHERE (CASE WHEN ?6 IS NULL THEN (?1 IS NULL OR date>=?1) AND (?2 IS NULL OR date<=?2) ELSE json_extract(body,'$.startMs')>=?6 AND json_extract(body,'$.startMs')<?7 END) ORDER BY client")?;
        let rows = s
            .query_map(params![f.from, f.to, first, f.model, second, f.timestamp_from_ms, f.timestamp_to_ms], |r| r.get(0))?
            .collect::<rusqlite::Result<Vec<String>>>()?;
        rows
    };
    let models = {
        let mut s=tx.prepare("SELECT DISTINCT model FROM codex_turns WHERE (CASE WHEN ?6 IS NULL THEN (?1 IS NULL OR date>=?1) AND (?2 IS NULL OR date<=?2) ELSE json_extract(body,'$.startMs')>=?6 AND json_extract(body,'$.startMs')<?7 END) AND (?3 IS NULL OR client IN (?3,?4)) ORDER BY model")?;
        let rows = s
            .query_map(params![f.from, f.to, first, second, second, f.timestamp_from_ms, f.timestamp_to_ms], |r| r.get(0))?
            .collect::<rusqlite::Result<Vec<String>>>()?;
        rows
    };
    let turns = {
        let mut s=tx.prepare("SELECT body FROM codex_turns WHERE (CASE WHEN ?6 IS NULL THEN (?1 IS NULL OR date>=?1) AND (?2 IS NULL OR date<=?2) ELSE json_extract(body,'$.startMs')>=?6 AND json_extract(body,'$.startMs')<?7 END) AND (?3 IS NULL OR client IN (?3,?5)) AND (?4 IS NULL OR model=?4) ORDER BY json_extract(body,'$.startMs'),id")?;
        let rows = s
            .query_map(params![f.from, f.to, first, f.model, second, f.timestamp_from_ms, f.timestamp_to_ms], |r| {
                r.get::<_, String>(0)
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        rows.iter()
            .map(|s| serde_json::from_str(s))
            .collect::<serde_json::Result<Vec<_>>>()?
    };
    let capabilities = crate::clients::CLIENTS
        .iter()
        .map(|c| capability(c.as_str()))
        .chain(DELEGATES.iter().map(|(alias, _)| capability(alias)))
        .collect();
    let report = Report {
        revision: revision(&tx)?,
        models,
        clients,
        turns,
        capabilities,
    };
    tx.commit()?;
    Ok(report)
}
