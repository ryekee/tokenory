// [INPUT]: Antigravity App / CLI SQLite conversation databases (`steps`, `gen_metadata`).
// [OUTPUT]: Completed user turns with measured output, reasoning, requests, tools and merged tool wait.
// [POS]: Antigravity turn-analytics boundary; excludes child subagent trajectories and unverified spans.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
use super::ParseOutcome;
use crate::codex_turns::CodexTurn;
use anyhow::Result;
use rusqlite::{Connection, OpenFlags};
use std::{
    collections::{BTreeSet, HashMap},
    path::Path,
};
use tokens_core::sessions::antigravity_cli::{
    proto_count_len_fields, proto_message_field, proto_string_field, proto_timestamp_ms_field,
    proto_varint_field, read_antigravity_db_generations, AntigravityGeneration,
};

const STEP_USER_INPUT: i64 = 14;
const STEP_PLANNER_RESPONSE: i64 = 15;
const STEP_ERROR_MESSAGE: i64 = 17;
const STEP_SYSTEM_MESSAGE: i64 = 101;
const SOURCE_MODEL: u64 = 2;
const SOURCE_USER_EXPLICIT: u64 = 4;
const STATUS_DONE: i64 = 3;
const STATUS_ERROR: i64 = 7;

struct ActiveTurn {
    session: String,
    turn_id: String,
    has_turn_uuid: bool,
    project: String,
    start_ms: i64,
    end_ms: Option<i64>,
    reopened: bool,
    invalid: bool,
    aborted: bool,
    responses: HashMap<String, (String, i64, i64)>,
    tool_calls: i64,
    tool_intervals: Vec<(i64, i64)>,
}

impl ActiveTurn {
    fn reopen(&mut self) {
        self.reopened |= self.end_ms.take().is_some();
    }

    fn finish(self, client: &str) -> Option<CodexTurn> {
        let end_ms = self.end_ms?;
        let duration_ms = end_ms.checked_sub(self.start_ms)?;
        if self.invalid
            || self.aborted
            || self.session.is_empty()
            || self.turn_id.is_empty()
            || self.start_ms < 0
            || duration_ms <= 0
            || self.responses.is_empty()
        {
            return None;
        }
        let models: BTreeSet<&str> = self
            .responses
            .values()
            .map(|(model, _, _)| model.as_str())
            .collect();
        if models.len() != 1 {
            return None;
        }
        let model = (*models.iter().next()?).to_string();
        if model.is_empty() || model == "unknown" {
            return None;
        }
        let generated_tokens = self
            .responses
            .values()
            .try_fold(0i64, |acc, (_, out, _)| acc.checked_add(*out))?;
        let reasoning_tokens = self
            .responses
            .values()
            .try_fold(0i64, |acc, (_, _, r)| acc.checked_add(*r))?;
        if reasoning_tokens < 0 || reasoning_tokens > generated_tokens {
            return None;
        }
        let tool_wait_ms = if self.tool_calls == 0 {
            Some(0)
        } else if self.tool_intervals.is_empty() {
            None
        } else {
            Some(merged_interval_ms(&self.tool_intervals, self.start_ms, end_ms).min(duration_ms))
        };
        let turn = CodexTurn {
            id: serde_json::to_string(&(client, &self.session, &self.turn_id)).ok()?,
            client: client.into(),
            duration_estimated: true,
            session_id: self.session,
            turn_id: self.turn_id,
            project: self.project,
            model,
            effort: None,
            inference_speed: None,
            start_ms: self.start_ms,
            end_ms,
            duration_ms,
            ttft_ms: None,
            generated_tokens,
            reasoning_tokens: Some(reasoning_tokens),
            requests: Some(self.responses.len() as i64),
            tool_calls: Some(self.tool_calls),
            tool_wait_ms,
        };
        turn.validate().ok()?;
        Some(turn)
    }
}

fn merged_interval_ms(intervals: &[(i64, i64)], start_ms: i64, end_ms: i64) -> i64 {
    let mut clipped: Vec<(i64, i64)> = intervals
        .iter()
        .filter_map(|&(a, b)| {
            let a = a.max(start_ms);
            let b = b.min(end_ms);
            (b > a).then_some((a, b))
        })
        .collect();
    clipped.sort_unstable();
    let mut total = 0i64;
    let mut current: Option<(i64, i64)> = None;
    for (a, b) in clipped {
        match current {
            Some((ca, cb)) if a <= cb => current = Some((ca, cb.max(b))),
            Some((ca, cb)) => {
                total = total.saturating_add(cb - ca);
                current = Some((a, b));
            }
            None => current = Some((a, b)),
        }
    }
    if let Some((ca, cb)) = current {
        total = total.saturating_add(cb - ca);
    }
    total
}

fn record_turn(result: &mut ParseOutcome, turn: ActiveTurn, client: &str) {
    let id = serde_json::to_string(&(client, &turn.session, &turn.turn_id)).expect("turn id");
    let should_invalidate =
        turn.reopened || (!turn.invalid && !turn.session.is_empty() && !turn.turn_id.is_empty());
    if let Some(finished) = turn.finish(client) {
        result.invalidated_ids.retain(|old| old != &id);
        result.turns.retain(|existing| existing.id != id);
        result.turns.push(finished);
    } else if should_invalidate {
        result.turns.retain(|existing| existing.id != id);
        result.invalidated_ids.push(id);
    }
}

fn table_exists(conn: &Connection, name: &str) -> Result<bool> {
    Ok(conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1)",
        [name],
        |row| row.get(0),
    )?)
}

fn is_subagent_conversation(conn: &Connection) -> Result<bool> {
    if !table_exists(conn, "parent_references")? {
        return Ok(false);
    }
    Ok(conn.query_row("SELECT EXISTS(SELECT 1 FROM parent_references)", [], |row| {
        row.get(0)
    })?)
}

pub(super) fn parse(path: &Path, client: &str) -> Result<ParseOutcome> {
    if path.extension().and_then(|s| s.to_str()) != Some("db") {
        return Ok(ParseOutcome::default());
    }
    let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    conn.execute_batch("BEGIN;")?;
    if !table_exists(&conn, "steps")?
        || !table_exists(&conn, "gen_metadata")?
        || is_subagent_conversation(&conn)?
    {
        return Ok(ParseOutcome::default());
    }

    let db_gens = read_antigravity_db_generations(&conn, path)?;
    if db_gens.generations.is_empty() {
        return Ok(ParseOutcome::default());
    }

    let mut by_response_id: HashMap<&str, &AntigravityGeneration> = HashMap::new();
    let mut by_gen_idx: HashMap<i64, &AntigravityGeneration> = HashMap::new();
    for gen in &db_gens.generations {
        if let Some(rid) = gen.response_id.as_deref() {
            by_response_id.insert(rid, gen);
        }
        if let Some(idx) = gen.gen_idx {
            by_gen_idx.insert(idx, gen);
        }
    }

    let project = db_gens.workspace_label.unwrap_or_default();
    let mut stmt = conn.prepare(
        "SELECT idx, step_type, status, metadata, step_payload FROM steps ORDER BY idx",
    )?;
    let mut rows = stmt.query([])?;
    let mut result = ParseOutcome::default();
    let mut active: Option<ActiveTurn> = None;

    while let Some(row) = rows.next()? {
        let idx: i64 = row.get(0)?;
        let step_type: i64 = row.get(1)?;
        let status: i64 = row.get(2)?;
        let metadata: Option<Vec<u8>> = row.get(3)?;
        let payload: Option<Vec<u8>> = row.get(4)?;
        let meta = metadata.as_deref().unwrap_or(&[]);

        let source = proto_varint_field(meta, 3);
        let created_ms = proto_timestamp_ms_field(meta, 1);
        let step_turn_uuid = proto_string_field(meta, 12).filter(|s| !s.trim().is_empty());

        if step_type == STEP_USER_INPUT && source == Some(SOURCE_USER_EXPLICIT) {
            if let Some(prev) = active.take() {
                record_turn(&mut result, prev, client);
            }
            if let Some(start_ms) = created_ms.filter(|&ms| ms >= 0) {
                let (turn_id, has_turn_uuid) = match step_turn_uuid {
                    Some(uuid) => (uuid.to_string(), true),
                    None => (format!("step-{idx}"), false),
                };
                active = Some(ActiveTurn {
                    session: db_gens.session_id.clone(),
                    turn_id,
                    has_turn_uuid,
                    project: project.clone(),
                    start_ms,
                    end_ms: None,
                    reopened: false,
                    invalid: false,
                    aborted: false,
                    responses: HashMap::new(),
                    tool_calls: 0,
                    tool_intervals: Vec::new(),
                });
            }
            continue;
        }

        let Some(turn) = active.as_mut() else {
            continue;
        };
        if turn.has_turn_uuid && step_turn_uuid.is_some_and(|uuid| uuid != turn.turn_id) {
            continue;
        }

        match step_type {
            STEP_PLANNER_RESPONSE => {
                if status != STATUS_DONE {
                    turn.reopen();
                    turn.aborted = true;
                    continue;
                }
                let resp_id = proto_message_field(meta, 9)
                    .and_then(|m| proto_string_field(m, 11))
                    .map(str::trim)
                    .filter(|s| !s.is_empty());
                let gen_idx = proto_message_field(meta, 20)
                    .and_then(|m| proto_varint_field(m, 3))
                    .and_then(|v| i64::try_from(v).ok());

                let Some(gen) = resp_id
                    .and_then(|id| by_response_id.get(id).copied())
                    .or_else(|| gen_idx.and_then(|g| by_gen_idx.get(&g).copied()))
                else {
                    turn.invalid = true;
                    continue;
                };

                let response_key = resp_id
                    .map(str::to_owned)
                    .or_else(|| gen_idx.map(|g| format!("gen-{g}")))
                    .unwrap_or_else(|| format!("step-{idx}"));
                let value = (gen.model_id.clone(), gen.output_tokens, gen.reasoning_tokens);
                if let Some(old) = turn.responses.get(&response_key) {
                    if old != &value {
                        turn.invalid = true;
                        continue;
                    }
                } else {
                    turn.reopen();
                    turn.responses.insert(response_key, value);
                }

                let p20 = payload
                    .as_deref()
                    .and_then(|buf| proto_message_field(buf, 20));
                let tool_count = p20.map(|buf| proto_count_len_fields(buf, 7)).unwrap_or(0);
                let has_response_text = p20.is_some_and(|buf| {
                    proto_message_field(buf, 1).is_some_and(|text| !text.is_empty())
                        || proto_message_field(buf, 8).is_some_and(|text| !text.is_empty())
                });
                turn.tool_calls = turn.tool_calls.saturating_add(tool_count as i64);

                if tool_count == 0 && has_response_text {
                    turn.end_ms = proto_timestamp_ms_field(meta, 8)
                        .or_else(|| proto_timestamp_ms_field(meta, 7))
                        .or(created_ms);
                } else {
                    turn.reopen();
                }
            }
            STEP_ERROR_MESSAGE => {
                turn.reopen();
                turn.aborted = true;
            }
            STEP_SYSTEM_MESSAGE => {}
            _ if source == Some(SOURCE_MODEL) => {
                // Synchronous completed/errored tool steps record exact execution
                // spans in metadata.#7..#8. Background tasks (status=6) run
                // concurrently with subsequent model generations and are excluded.
                if matches!(status, STATUS_DONE | STATUS_ERROR) {
                    let t_start = proto_timestamp_ms_field(meta, 7).or(created_ms);
                    let t_end = proto_timestamp_ms_field(meta, 8);
                    if let (Some(a), Some(b)) = (t_start, t_end) {
                        if b > a {
                            turn.tool_intervals.push((a, b));
                        }
                    }
                }
            }
            _ => {}
        }
    }

    if let Some(last) = active {
        record_turn(&mut result, last, client);
    }
    Ok(result)
}
