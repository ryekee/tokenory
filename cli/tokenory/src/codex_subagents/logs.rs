// [INPUT]: Metadata and explicit user-input events from plain and compressed Codex rollouts.
// [OUTPUT]: Owned thread identity, spawn evidence and de-duplicated main turn starts.
// [POS]: Log decoding boundary. User messages are read only to recognize legacy input and are never retained.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
use anyhow::Result;
use serde_json::Value;
use std::{
    collections::{BTreeMap, HashMap},
    fs::{self, Metadata},
    io::BufRead,
    path::{Path, PathBuf},
    time::SystemTime,
};
use tokens_core::sessions::codex::{read_rollout, rollout_stem, thread_id_from_rollout_path};

#[derive(Clone)]
pub(crate) struct ThreadActivity {
    pub(crate) id: String,
    pub(crate) ledger_session_id: String,
    pub(crate) started_ms: i64,
    pub(crate) provider: Option<String>,
    pub(crate) kind: ThreadKind,
    pub(crate) main_turns: Vec<UserTurn>,
}

#[derive(Clone)]
pub(crate) enum ThreadKind {
    Main,
    Spawned {
        parent_id: String,
        depth: u32,
        name: Option<String>,
    },
}

#[derive(Clone)]
pub(crate) struct UserTurn {
    pub(crate) id: String,
    pub(crate) started_ms: i64,
    pub(crate) model: Option<String>,
    pub(crate) mixed_models: bool,
}

#[derive(Default)]
pub(crate) struct Cache {
    files: HashMap<PathBuf, CachedActivity>,
}

struct CachedActivity {
    size: u64,
    modified: SystemTime,
    activity: Option<ThreadActivity>,
}

impl Cache {
    pub(crate) fn read(&mut self, path: &Path) -> Result<Option<ThreadActivity>> {
        let before = fs::metadata(path)?;
        if let Some(entry) = self.files.get(path) {
            if entry.matches(&before)? {
                return Ok(entry.activity.clone());
            }
        }
        let activity = read_rollout(path, |reader| parse(path, reader))?;
        let entry = CachedActivity {
            size: before.len(),
            modified: before.modified()?,
            activity: activity.clone(),
        };
        if entry.matches(&fs::metadata(path)?)? {
            self.files.insert(path.to_owned(), entry);
        }
        Ok(activity)
    }
}

impl CachedActivity {
    fn matches(&self, metadata: &Metadata) -> Result<bool> {
        Ok(self.size == metadata.len() && self.modified == metadata.modified()?)
    }
}

struct PendingTurn {
    started_ms: i64,
    user_input: bool,
    model: Option<String>,
    mixed_models: bool,
}

fn nonempty(value: &Value) -> Option<&str> {
    value.as_str().filter(|text| !text.trim().is_empty())
}

fn timestamp(value: &Value) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(value.as_str()?)
        .ok()
        .map(|date| date.timestamp_millis())
        .filter(|ms| *ms > 0)
}

fn own_metadata(row: &Value, alias: &str) -> Option<ThreadActivity> {
    let meta = &row["payload"];
    let id = nonempty(&meta["id"])?;
    let origin = nonempty(&meta["originator"]);
    if origin.is_some_and(|value| value.trim().eq_ignore_ascii_case("openclaw")) {
        return None;
    }
    let source = &meta["source"];
    let thread_source = nonempty(&meta["thread_source"]);
    let kind = if let Some(spawn) = source.get("subagent").and_then(|s| s.get("thread_spawn")) {
        let parent_id = nonempty(&spawn["parent_thread_id"])?;
        let depth = u32::try_from(spawn["depth"].as_u64()?).ok()?;
        if depth == 0 || parent_id == id || !matches!(thread_source, None | Some("subagent")) {
            return None;
        }
        ThreadKind::Spawned {
            parent_id: parent_id.to_owned(),
            depth,
            name: nonempty(&spawn["agent_nickname"])
                .or_else(|| nonempty(&meta["agent_nickname"]))
                .map(|name| name.trim().chars().take(80).collect()),
        }
    } else if matches!(thread_source, None | Some("user"))
        && matches!(
            source.as_str(),
            Some("cli" | "vscode" | "desktop" | "chat" | "interactive" | "exec")
        )
    {
        ThreadKind::Main
    } else {
        return None;
    };
    Some(ThreadActivity {
        id: id.to_owned(),
        ledger_session_id: alias.to_owned(),
        started_ms: timestamp(&meta["timestamp"]).or_else(|| timestamp(&row["timestamp"]))?,
        provider: nonempty(&meta["model_provider"]).map(str::to_owned),
        kind,
        main_turns: Vec::new(),
    })
}

fn uuid_v7_timestamp_ms(id: &str) -> Option<i64> {
    if id.len() != 36 || id.as_bytes()[14] != b'7' {
        return None;
    }
    let first = i64::from_str_radix(id.get(..8)?, 16).ok()?;
    let second = i64::from_str_radix(id.get(9..13)?, 16).ok()?;
    Some(first * 65536 + second)
}

fn main_turn_belongs_to_owner(
    owner: &ThreadActivity,
    id: &str,
    started_ms: i64,
    copied_history: bool,
) -> bool {
    started_ms >= owner.started_ms
        && (!copied_history
            || uuid_v7_timestamp_ms(id)
                .zip(uuid_v7_timestamp_ms(&owner.id))
                .is_some_and(|(turn_ms, owner_ms)| turn_ms > owner_ms))
}

fn legacy_human_input(payload: &Value) -> bool {
    nonempty(&payload["message"]).is_some_and(|message| {
        // Codex has also emitted these injected blocks as legacy user events.
        ![
            "<environment_context>",
            "<system-reminder>",
            "<user_instructions>",
            "<subagent_notification>",
        ]
        .iter()
        .any(|prefix| message.trim_start().starts_with(prefix))
    })
}

fn parse(path: &Path, mut reader: impl BufRead) -> Result<Option<ThreadActivity>> {
    let Some(alias) = rollout_stem(path) else {
        return Ok(None);
    };
    let expected_id = thread_id_from_rollout_path(path);
    let mut owner = None::<ThreadActivity>;
    let mut copied_history = false;
    let mut active = None::<String>;
    let mut turns = BTreeMap::<String, PendingTurn>::new();
    let mut line = String::new();

    loop {
        line.clear();
        if reader.read_line(&mut line)? == 0 {
            break;
        }
        if line.trim().is_empty() {
            continue;
        }
        let metadata_row = line.contains(r#""session_meta""#);
        if owner.is_none() && expected_id.is_none() && !metadata_row {
            // For renamed logs only the first record can establish ownership.
            return Ok(None);
        }
        if !metadata_row {
            let turn_row = [
                r#""turn_context""#,
                r#""task_started""#,
                r#""task_complete""#,
                r#""turn_aborted""#,
                r#""task_aborted""#,
                r#""user_message""#,
            ]
            .iter()
            .any(|marker| line.contains(marker));
            let input_row = line.contains(r#""content_item_kinds""#) && line.contains(r#""user""#);
            if owner.is_none() || (!turn_row && !input_row) {
                continue;
            }
        }
        let Ok(row) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        let payload = &row["payload"];
        let kind = row["type"].as_str().unwrap_or_default();
        let event = payload["type"].as_str().unwrap_or_default();
        if kind == "session_meta" {
            let id = nonempty(&payload["id"]);
            if let Some(current_owner) = &owner {
                if id != Some(current_owner.id.as_str()) {
                    if expected_id.is_none() {
                        return Ok(None);
                    }
                    copied_history = true;
                    active = None;
                    turns.retain(|id, turn| {
                        main_turn_belongs_to_owner(current_owner, id, turn.started_ms, true)
                    });
                }
                continue;
            }
            if expected_id
                .as_deref()
                .is_some_and(|expected| Some(expected) != id)
            {
                continue;
            }
            let Some(activity) = own_metadata(&row, alias) else {
                return Ok(None);
            };
            if matches!(activity.kind, ThreadKind::Spawned { .. }) {
                // Child usage is already reconciled by the usage parser.
                return Ok(Some(activity));
            }
            copied_history = nonempty(&payload["forked_from_id"]).is_some();
            owner = Some(activity);
            continue;
        }
        let Some(current_owner) = &owner else {
            continue;
        };
        let explicit_turn = nonempty(&payload["turn_id"]);
        match (kind, event) {
            ("event_msg", "task_started") => {
                active = None;
                if let (Some(id), Some(started_ms)) = (explicit_turn, timestamp(&row["timestamp"]))
                {
                    if nonempty(&payload["turn_attribution"]["parent_turn_id"]).is_none()
                        && main_turn_belongs_to_owner(current_owner, id, started_ms, copied_history)
                    {
                        // Keep the earliest start and evidence already seen for this ID.
                        let turn = turns.entry(id.to_owned()).or_insert(PendingTurn {
                            started_ms,
                            user_input: false,
                            model: None,
                            mixed_models: false,
                        });
                        turn.started_ms = turn.started_ms.min(started_ms);
                        active = Some(id.to_owned());
                    }
                }
            }
            ("event_msg", "task_complete" | "turn_aborted" | "task_aborted") => {
                if explicit_turn.is_none() || explicit_turn == active.as_deref() {
                    active = None;
                }
            }
            ("turn_context", _) => {
                if let Some(turn) = explicit_turn
                    .or(active.as_deref())
                    .and_then(|id| turns.get_mut(id))
                {
                    if let Some(model) = nonempty(&payload["model"]) {
                        turn.mixed_models |= turn.model.as_deref().is_some_and(|old| old != model);
                        turn.model = Some(model.to_owned());
                    }
                }
            }
            ("event_msg", "user_message") if legacy_human_input(payload) => {
                if let Some(turn) = explicit_turn
                    .or(active.as_deref())
                    .and_then(|id| turns.get_mut(id))
                {
                    if timestamp(&row["timestamp"]).is_some_and(|ms| ms >= turn.started_ms) {
                        turn.user_input = true;
                    }
                }
            }
            ("response_item", "message") if payload["role"] == "user" => {
                let metadata = &payload["internal_chat_message_metadata_passthrough"];
                if metadata["content_item_kinds"]
                    .as_array()
                    .is_some_and(|kinds| {
                        kinds
                            .iter()
                            .any(|kind| matches!(kind.as_str(), Some("user.text" | "user.image")))
                    })
                {
                    if let Some(turn) =
                        nonempty(&metadata["turn_id"]).and_then(|id| turns.get_mut(id))
                    {
                        if timestamp(&row["timestamp"]).is_some_and(|ms| ms >= turn.started_ms) {
                            turn.user_input = true;
                        }
                    }
                }
            }
            _ => {}
        }
    }
    if let Some(activity) = &mut owner {
        activity.main_turns = turns
            .into_iter()
            .filter(|(_, turn)| turn.user_input)
            .map(|(id, turn)| UserTurn {
                id,
                started_ms: turn.started_ms,
                model: turn.model.filter(|_| !turn.mixed_models),
                mixed_models: turn.mixed_models,
            })
            .collect();
    }
    Ok(owner)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn from_rows(path: &str, rows: &[Value]) -> Option<ThreadActivity> {
        let jsonl = rows
            .iter()
            .map(Value::to_string)
            .collect::<Vec<_>>()
            .join("\n");
        parse(Path::new(path), jsonl.as_bytes()).unwrap()
    }

    #[test]
    fn codex_activity_uses_owned_spawn_metadata_and_ignores_copied_parent() {
        let child = "019bf4cb-5000-7000-8000-000000000001";
        let filename = format!("rollout-2026-01-20T09-00-00-{child}.jsonl");
        let activity = from_rows(&filename, &[
            json!({"type":"session_meta","timestamp":"2026-01-20T09:00:11Z",
                "payload":{"id":"copied-parent","source":"vscode","thread_source":"user"}}),
            json!({"type":"session_meta","timestamp":"2026-01-20T09:00:10Z","payload":{
                "id":child,"timestamp":"2026-01-20T09:00:00Z","thread_source":"subagent",
                "source":{"subagent":{"thread_spawn":{"parent_thread_id":"copied-parent","depth":1,"agent_nickname":"Worker"}}}
            }}),
        ]).unwrap();
        assert_eq!(activity.id, child);
        assert_eq!(
            activity.ledger_session_id,
            filename.trim_end_matches(".jsonl")
        );
        assert_eq!(activity.started_ms, 1_768_899_600_000);
        assert!(activity.main_turns.is_empty());
        assert!(
            matches!(activity.kind, ThreadKind::Spawned { parent_id, depth: 1, name: Some(name) }
            if parent_id == "copied-parent" && name == "Worker")
        );
    }

    #[test]
    fn codex_activity_counts_confirmed_user_input_once_even_on_abort() {
        let rows = [
            json!({"type":"session_meta","timestamp":"2026-01-20T09:00:00Z",
                "payload":{"id":"main","source":"vscode","thread_source":"user","model_provider":"openai"}}),
            json!({"type":"event_msg","timestamp":"2026-01-20T09:00:01Z","payload":{"type":"task_started","turn_id":"direct"}}),
            json!({"type":"turn_context","payload":{"turn_id":"direct","model":"gpt-5.6-sol"}}),
            json!({"type":"response_item","timestamp":"2026-01-20T09:00:02Z","payload":{"type":"message","role":"user",
                "internal_chat_message_metadata_passthrough":{"turn_id":"direct","content_item_kinds":["user.text","user.image"]}}}),
            json!({"type":"event_msg","timestamp":"2026-01-20T09:00:03Z","payload":{"type":"turn_aborted","turn_id":"direct"}}),
            json!({"type":"event_msg","timestamp":"2026-01-20T09:00:01Z","payload":{"type":"task_started","turn_id":"direct"}}),
            json!({"type":"event_msg","timestamp":"2026-01-20T09:03:00Z","payload":{"type":"task_started","turn_id":"injected"}}),
            json!({"type":"response_item","timestamp":"2026-01-20T09:03:01Z","payload":{"type":"message","role":"user",
                "internal_chat_message_metadata_passthrough":{"turn_id":"injected","content_item_kinds":["agents_md.instructions","environments.environment_context"]}}}),
            json!({"type":"event_msg","timestamp":"2026-01-20T09:03:02Z","payload":{"type":"user_message","message":"<environment_context>cwd=/tmp</environment_context>"}}),
            json!({"type":"event_msg","timestamp":"2026-01-20T09:06:00Z","payload":{"type":"task_started","turn_id":"legacy"}}),
            json!({"type":"event_msg","timestamp":"2026-01-20T09:06:01Z","payload":{"type":"user_message","message":"<div>style question</div>"}}),
        ];
        let activity = from_rows("legacy-owner.jsonl", &rows).unwrap();
        assert_eq!(activity.provider.as_deref(), Some("openai"));
        let [direct, legacy] = activity.main_turns.as_slice() else {
            panic!("expected only direct and legacy human turns");
        };
        assert_eq!(direct.id, "direct");
        assert_eq!(direct.model.as_deref(), Some("gpt-5.6-sol"));
        assert_eq!(legacy.id, "legacy");
    }

    #[test]
    fn codex_activity_rejects_unowned_or_ambiguous_sources() {
        for (source, thread_source, originator) in [
            (json!("other"), "user", "codex"),
            (json!("cli"), "user", "OpenClaw"),
            (
                json!({"subagent":{"other":"guardian"}}),
                "guardian_review",
                "codex",
            ),
            (
                json!({"subagent":{"thread_spawn":{"parent_thread_id":"x","depth":0}}}),
                "subagent",
                "codex",
            ),
        ] {
            let row = json!({"type":"session_meta","timestamp":"2026-01-20T09:00:00Z",
                "payload":{"id":"main","source":source,"thread_source":thread_source,"originator":originator}});
            assert!(from_rows("legacy-owner.jsonl", &[row]).is_none());
        }
    }

    #[test]
    fn codex_activity_omits_replayed_turns_in_user_forks() {
        fn uuid_v7(ms: u64) -> String {
            format!(
                "{:08x}-{:04x}-7000-8000-000000000001",
                ms >> 16,
                ms & 0xffff
            )
        }
        fn turn_events(id: &str) -> [Value; 2] {
            [
                json!({"type":"event_msg","timestamp":"2026-01-20T09:00:01Z",
                    "payload":{"type":"task_started","turn_id":id}}),
                json!({"type":"response_item","timestamp":"2026-01-20T09:00:02Z","payload":{
                    "type":"message","role":"user",
                    "internal_chat_message_metadata_passthrough":{"turn_id":id,"content_item_kinds":["user.text"]}
                }}),
            ]
        }

        let fork_ms = 1_768_899_600_000;
        let old_turn = uuid_v7(fork_ms - 1000);
        let owner = uuid_v7(fork_ms);
        let new_turn = uuid_v7(fork_ms + 1000);
        let mut rows = vec![
            json!({"type":"session_meta","timestamp":"2026-01-20T09:00:00Z",
                "payload":{"id":owner,"forked_from_id":"parent","source":"vscode","thread_source":"user"}}),
            json!({"type":"session_meta","timestamp":"2026-01-20T09:00:00Z",
                "payload":{"id":"parent","source":"vscode","thread_source":"user"}}),
        ];
        rows.extend(turn_events(&old_turn));
        rows.extend(turn_events(&new_turn));
        let activity =
            from_rows(&format!("rollout-2026-01-20T09-00-00-{owner}.jsonl"), &rows).unwrap();
        let [turn] = activity.main_turns.as_slice() else {
            panic!("expected only the fork's own turn");
        };
        assert_eq!(turn.id, new_turn);
    }
}
