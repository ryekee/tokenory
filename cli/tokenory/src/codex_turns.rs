// [INPUT]: Local Codex plain and compressed JSONL events, independently of priced usage records.
// [OUTPUT]: Completed main-turn metadata, selected inference speed and date/model-scoped reports.
// [POS]: External-event validation, unchanged-file cache and private-text-free storage.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
use crate::{
    db::{revision, Database},
    queries::Filter,
};
use anyhow::{ensure, Result};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::{BTreeMap, BTreeSet, HashMap},
    io::BufRead,
    path::{Path, PathBuf},
    time::SystemTime,
};
use tokens_core::speed::InferenceSpeed;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexTurn {
    pub id: String,
    #[serde(default = "codex_client")]
    pub client: String,
    #[serde(default)]
    pub duration_estimated: bool,
    pub session_id: String,
    pub turn_id: String,
    pub project: String,
    pub model: String,
    pub effort: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub inference_speed: Option<InferenceSpeed>,
    pub start_ms: i64,
    pub end_ms: i64,
    pub duration_ms: i64,
    pub ttft_ms: Option<i64>,
    pub generated_tokens: i64,
    pub reasoning_tokens: Option<i64>,
    pub requests: Option<i64>,
    pub tool_calls: Option<i64>,
    pub tool_wait_ms: Option<i64>,
}
fn codex_client() -> String {
    "codex".into()
}
impl CodexTurn {
    pub fn validate(&self) -> Result<()> {
        ensure!(
            !self.id.is_empty()
                && !self.session_id.is_empty()
                && !self.turn_id.is_empty()
                && !self.model.is_empty(),
            "missing Codex turn identity"
        );
        ensure!(
            self.start_ms >= 0
                && self.duration_ms > 0
                && self.start_ms.checked_add(self.duration_ms) == Some(self.end_ms),
            "invalid Codex turn interval"
        );
        ensure!(
            self.generated_tokens >= 0
                && self
                    .reasoning_tokens
                    .is_none_or(|n| n >= 0 && n <= self.generated_tokens),
            "invalid Codex turn usage"
        );
        ensure!(
            self.requests.is_none_or(|n| n > 0) && self.tool_calls.is_none_or(|n| n >= 0),
            "invalid Codex turn counts"
        );
        ensure!(
            [self.ttft_ms, self.tool_wait_ms]
                .into_iter()
                .all(|v| v.is_none_or(|n| n >= 0 && n <= self.duration_ms)),
            "invalid Codex turn timing"
        );
        Ok(())
    }
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    pub revision: i64,
    pub models: Vec<String>,
    pub turns: Vec<CodexTurn>,
}
#[derive(Default)]
struct Turn {
    models: BTreeSet<String>,
    efforts: BTreeSet<String>,
    inference_speed: Option<InferenceSpeed>,
    usage: HashMap<String, (i64, Option<i64>)>,
    total: Option<(i64, Option<i64>)>,
    invalid: bool,
    aborted: bool,
    complete: Option<(i64, i64, Option<i64>)>,
    calls: HashMap<String, (Option<i64>, Option<i64>)>,
}
fn usage(v: &Value) -> Option<(i64, Option<i64>)> {
    let output = v["output_tokens"].as_i64().filter(|n| *n >= 0)?;
    let reasoning = match v.get("reasoning_output_tokens") {
        None | Some(Value::Null) => None,
        Some(v) => Some(v.as_i64().filter(|n| *n >= 0 && *n <= output)?),
    };
    Some((output, reasoning))
}
fn timestamp(v: &Value) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(v.as_str()?)
        .ok()
        .map(|t| t.timestamp_millis())
}
/// Requires a started and completed turn, unique response totals, and one model.
/// token_count is intentionally ignored: it describes the same usage stream.
pub fn parse(reader: impl BufRead) -> Result<Vec<CodexTurn>> {
    parse_client(reader, false, false)
}

pub(crate) fn parse_client(
    reader: impl BufRead,
    openclaw: bool,
    owned_path: bool,
) -> Result<Vec<CodexTurn>> {
    let mut session = None;
    let mut project = String::new();
    let mut excluded_session = false;
    let mut turns = BTreeMap::<String, Turn>::new();
    let mut current = None::<String>;
    let mut call_owners = HashMap::<String, String>::new();
    let mut speed_selection = None::<(String, InferenceSpeed)>;
    for line in reader.lines() {
        let line = line?;
        let Ok(d) = serde_json::from_str::<Value>(&line) else {
            if !line.trim().is_empty() {
                if let Some(t) = current.as_ref().and_then(|id| turns.get_mut(id)) {
                    if t.complete.is_none() {
                        t.invalid = true;
                    }
                }
            }
            continue;
        };
        let p = &d["payload"];
        let kind = d["type"].as_str().unwrap_or("");
        let typ = p["type"].as_str().unwrap_or("");
        if kind == "session_meta" {
            // Fork rollouts can replay a parent session. Until a causal replay
            // boundary is available, omit them instead of duplicating history.
            excluded_session |= p.get("forked_from_id").is_some_and(|v| !v.is_null())
                || (!owned_path
                    && openclaw
                        != p["originator"]
                            .as_str()
                            .is_some_and(|s| s.eq_ignore_ascii_case("openclaw")))
                || session
                    .as_deref()
                    .is_some_and(|s| p["id"].as_str() != Some(s));
            session = p["id"]
                .as_str()
                .filter(|s| !s.is_empty())
                .map(str::to_owned);
            project = Path::new(p["cwd"].as_str().unwrap_or(""))
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("")
                .into();
            excluded_session |= ["source", "thread_source"].iter().any(|k| {
                p[*k].is_object()
                    || p[*k].as_str().is_some_and(|s| {
                        s.to_lowercase().contains("subagent") || s == "guardian_review"
                    })
            });
        }
        if kind == "event_msg" && typ == "thread_settings_applied" {
            if session
                .as_deref()
                .is_some_and(|id| p["thread_id"].as_str() == Some(id))
            {
                let settings = &p["thread_settings"];
                speed_selection = settings["model"].as_str().and_then(|model| {
                    InferenceSpeed::codex(settings["service_tier"].as_str())
                        .map(|speed| (model.to_owned(), speed))
                });
            }
            continue;
        }
        if kind == "event_msg" && typ == "task_started" {
            current = p["turn_id"]
                .as_str()
                .filter(|s| !s.is_empty())
                .map(str::to_owned);
            if let Some(id) = &current {
                turns.entry(id.clone()).or_default();
            }
        }
        let id = p["turn_id"]
            .as_str()
            .or_else(|| p["internal_chat_message_metadata_passthrough"]["turn_id"].as_str())
            .or(current.as_deref());
        let Some(id) = id.map(str::to_owned) else {
            continue;
        };
        if kind == "response_item"
            && matches!(typ, "function_call_output" | "custom_tool_call_output")
        {
            if let Some(cid) = p["call_id"].as_str() {
                if let Some(t) = call_owners.get(cid).and_then(|owner| turns.get_mut(owner)) {
                    if let Some(call) = t.calls.get_mut(cid) {
                        if call.1.is_none() {
                            call.1 = timestamp(&d["timestamp"]);
                        }
                    }
                }
            }
            continue;
        }
        let Some(t) = turns.get_mut(&id) else {
            continue;
        };
        match kind {
            "turn_context" => {
                if let Some(model) = p["model"].as_str().filter(|s| !s.is_empty()) {
                    // A settings change during a turn applies to the next turn.
                    if t.models.is_empty() {
                        t.inference_speed = speed_selection
                            .as_ref()
                            .filter(|(selected, _)| selected == model)
                            .map(|(_, speed)| *speed);
                    }
                    t.models.insert(model.into());
                }
                if let Some(e) = p["effort"]
                    .as_str()
                    .or_else(|| p["collaboration_mode"]["settings"]["reasoning_effort"].as_str())
                {
                    t.efforts.insert(e.into());
                }
            }
            "token_usage_record" => {
                if let (Some(rid), Some(u), Some(total)) = (
                    p["response_id"].as_str().filter(|s| !s.is_empty()),
                    usage(&p["usage"]),
                    usage(&p["turn_token_usage"]),
                ) {
                    if let Some(prior) = t.usage.get(rid) {
                        if *prior != u {
                            t.invalid = true;
                        }
                    } else {
                        t.usage.insert(rid.into(), u);
                        t.total = Some(total);
                    }
                } else {
                    t.invalid = true;
                }
            }
            "response_item" if matches!(typ, "function_call" | "custom_tool_call") => {
                if let Some(cid) = p["call_id"].as_str().filter(|s| !s.is_empty()) {
                    t.calls
                        .entry(cid.into())
                        .or_insert((timestamp(&d["timestamp"]), None));
                    call_owners.entry(cid.into()).or_insert(id);
                } else {
                    t.calls
                        .entry(format!("missing:{}", t.calls.len()))
                        .or_insert((None, None));
                }
            }
            "event_msg" if typ == "turn_aborted" || typ == "task_aborted" => t.aborted = true,
            "event_msg" if typ == "task_complete" => {
                if let (Some(end), Some(duration)) = (
                    timestamp(&d["timestamp"]),
                    p["duration_ms"].as_i64().filter(|n| *n > 0),
                ) {
                    if end.checked_sub(duration).is_some_and(|s| s >= 0) {
                        t.complete = Some((
                            end,
                            duration,
                            p["time_to_first_token_ms"]
                                .as_i64()
                                .filter(|n| *n >= 0 && *n <= duration),
                        ));
                    }
                }
            }
            _ => {}
        }
    }
    let Some(session) = session else {
        return Ok(vec![]);
    };
    if excluded_session {
        return Ok(vec![]);
    }
    let mut result = Vec::new();
    for (id, t) in turns {
        let Some((end, duration, ttft)) = t.complete else {
            continue;
        };
        if t.invalid || t.aborted || t.usage.is_empty() || t.models.len() != 1 {
            continue;
        }
        let Some(generated) = t.usage.values().try_fold(0i64, |a, u| a.checked_add(u.0)) else {
            continue;
        };
        let reasoning = t.usage.values().try_fold(0i64, |a, u| a.checked_add(u.1?));
        let Some(total) = t.total else { continue };
        if total.0 != generated
            || (reasoning.is_some() && total.1.is_some() && reasoning != total.1)
        {
            continue;
        }
        let start = end - duration;
        let mut intervals = Vec::new();
        let mut timing_known = true;
        for (a, b) in t.calls.values() {
            match (a, b) {
                (Some(a), Some(b)) if b >= a => {
                    let a = (*a).max(start);
                    let b = (*b).min(end);
                    if b > a {
                        intervals.push((a, b));
                    }
                }
                _ => timing_known = false,
            }
        }
        intervals.sort_unstable();
        let mut wait = 0;
        let mut right = start;
        for (a, b) in intervals {
            if b > right {
                wait += b - a.max(right);
                right = b;
            }
        }
        result.push(CodexTurn {
            id: if openclaw {
                serde_json::to_string(&("openclaw", &session, &id))?
            } else {
                serde_json::to_string(&(&session, &id))?
            },
            client: if openclaw { "openclaw" } else { "codex" }.into(),
            duration_estimated: false,
            session_id: session.clone(),
            turn_id: id,
            project: project.clone(),
            model: t.models.into_iter().next().unwrap(),
            effort: (t.efforts.len() == 1).then(|| t.efforts.into_iter().next().unwrap()),
            inference_speed: t.inference_speed,
            start_ms: start,
            end_ms: end,
            duration_ms: duration,
            ttft_ms: ttft,
            generated_tokens: generated,
            reasoning_tokens: reasoning,
            requests: Some(t.usage.len() as i64),
            tool_calls: Some(t.calls.len() as i64),
            tool_wait_ms: timing_known.then_some(wait),
        });
    }
    Ok(result)
}

#[derive(Default)]
pub struct Cache {
    files: HashMap<PathBuf, (u64, SystemTime, Vec<CodexTurn>)>,
}
impl Cache {
    pub fn read(&mut self, path: &Path) -> Result<Vec<CodexTurn>> {
        let m = std::fs::metadata(path)?;
        let modified = m.modified()?;
        if let Some((size, time, turns)) = self.files.get(path) {
            if *size == m.len() && *time == modified {
                return Ok(turns.clone());
            }
        }
        let turns = tokens_core::sessions::codex::read_rollout(path, |reader| parse(reader))?;
        // A growing log must be read again on the next scan.
        let after = std::fs::metadata(path)?;
        if after.len() == m.len() && after.modified()? == modified {
            self.files
                .insert(path.into(), (m.len(), modified, turns.clone()));
        }
        Ok(turns)
    }
}
pub fn persist(c: &Connection, turns: &[CodexTurn], timezone: &str) -> Result<usize> {
    let tz = timezone.parse::<chrono_tz::Tz>()?;
    let mut changed = 0;
    for t in turns {
        let date = chrono::DateTime::from_timestamp_millis(t.start_ms)
            .ok_or_else(|| anyhow::anyhow!("invalid turn timestamp"))?
            .with_timezone(&tz)
            .format("%Y-%m-%d")
            .to_string();
        changed+=c.execute("INSERT INTO codex_turns(id,date,model,body,client) VALUES (?1,?2,?3,?4,?5) ON CONFLICT(id) DO UPDATE SET model=excluded.model,body=excluded.body,client=excluded.client WHERE codex_turns.body!=excluded.body",params![t.id,date,t.model,serde_json::to_string(t)?,t.client])?;
    }
    Ok(changed)
}
pub fn query(db: &mut Database, f: &Filter) -> Result<Report> {
    f.validate()?;
    ensure!(
        f.client.as_deref().is_none_or(|s| s == "codex")
            && f.source.as_deref().is_none_or(|s| s == "local")
            && f.provider.is_none(),
        "Codex turns support local Codex data only"
    );
    let tx = db.connection.transaction()?;
    let models = {
        let mut s=tx.prepare("SELECT DISTINCT model FROM codex_turns WHERE client='codex' AND (?1 IS NULL OR date>=?1) AND (?2 IS NULL OR date<=?2) ORDER BY model")?;
        let rows = s
            .query_map(params![f.from, f.to], |r| r.get(0))?
            .collect::<rusqlite::Result<Vec<String>>>()?;
        rows
    };
    let turns = {
        let mut s=tx.prepare("SELECT body FROM codex_turns WHERE client='codex' AND (?1 IS NULL OR date>=?1) AND (?2 IS NULL OR date<=?2) AND (?3 IS NULL OR model=?3) ORDER BY json_extract(body,'$.startMs'),id")?;
        let bodies = s
            .query_map(params![f.from, f.to, f.model], |r| r.get::<_, String>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        bodies
            .iter()
            .map(|b| serde_json::from_str(b))
            .collect::<serde_json::Result<Vec<CodexTurn>>>()?
    };
    let report = Report {
        revision: revision(&tx)?,
        models,
        turns,
    };
    tx.commit()?;
    Ok(report)
}
