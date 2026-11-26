// [INPUT]: Antigravity transcript.jsonl files under ~/.gemini/*/brain/<parent>/.system_generated/logs/ and effective_usage records.
// [OUTPUT]: Tool-scoped Antigravity subagent reports and local child identities for aggregate device export.
// [POS]: Read-only Antigravity subagent analytics reusing the shared subagent Report schema.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
use crate::{
    codex_subagents::{Agent, Conversation, Cost, ModelUsage, Report},
    config::Config,
    queries::{antigravity_titles, Filter, SESSION_SQL, WHERE_SQL},
};
use anyhow::Result;
use chrono::{DateTime, TimeZone};
use rusqlite::{params_from_iter, Connection};
use serde::Serialize;
use serde_json::Value;
use std::{
    collections::{BTreeMap, HashMap, HashSet, VecDeque},
    fs::{self, File},
    io::{BufRead, BufReader},
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
    time::SystemTime,
};

const ANTIGRAVITY_BRAIN_DIRS: [(&str, &str); 4] = [
    ("antigravity", "antigravity"),
    ("antigravity-ide", "antigravity"),
    ("antigravity-insiders", "antigravity"),
    ("antigravity-cli", "antigravity-cli"),
];
const CLIENTS: [&str; 2] = ["antigravity", "antigravity-cli"];

const CREATED_MARKER: &str = "Created the following subagent:";

#[derive(Clone, Debug)]
struct SpawnRecord {
    parent_id: String,
    child_id: String,
    name: Option<String>,
    started_ms: Option<i64>,
}

#[derive(Clone, Debug)]
struct CachedTranscript {
    mtime: Option<SystemTime>,
    len: u64,
    spawns: Vec<SpawnRecord>,
}

static TRANSCRIPT_CACHE: OnceLock<Mutex<HashMap<PathBuf, CachedTranscript>>> = OnceLock::new();

#[derive(Default)]
struct Usage {
    tokens: i64,
    cost: Cost,
}

fn cache() -> &'static Mutex<HashMap<PathBuf, CachedTranscript>> {
    TRANSCRIPT_CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn in_range(date: &str, filter: &Filter) -> bool {
    filter.from.as_deref().is_none_or(|from| date >= from)
        && filter.to.as_deref().is_none_or(|to| date <= to)
}

fn has_activity(starts: i64, tokens: i64, cost: &Cost) -> bool {
    starts > 0 || tokens > 0 || cost.known_estimated_cost_usd.unwrap_or_default() > 0.0
}

fn extract_name_from_args(args: &Value) -> Option<String> {
    let owned;
    let obj = match args {
        Value::Object(map) => map,
        Value::String(text) => {
            owned = serde_json::from_str::<Value>(text).ok()?;
            owned.as_object()?
        }
        _ => return None,
    };
    for key in ["Role", "role", "TypeName", "typeName", "type_name"] {
        if let Some(value) = obj.get(key).and_then(Value::as_str) {
            let trimmed = value.trim().trim_matches('"').trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
    }
    None
}

fn collect_invoke_subagent_names(value: &Value, out: &mut Vec<String>) {
    match value {
        Value::Object(map) => {
            let tool_name = map
                .get("name")
                .or_else(|| map.get("tool_name"))
                .or_else(|| map.get("toolName"))
                .or_else(|| map.get("function"))
                .and_then(|v| {
                    v.as_str()
                        .or_else(|| v.as_object()?.get("name")?.as_str())
                });
            if tool_name == Some("invoke_subagent") {
                let args = map
                    .get("arguments")
                    .or_else(|| map.get("args"))
                    .or_else(|| map.get("input"))
                    .or_else(|| map.get("parameters"))
                    .or_else(|| map.get("function").and_then(|f| f.get("arguments")));
                if let Some(name) = args.and_then(extract_name_from_args) {
                    out.push(name);
                    return;
                }
            }
            for child in map.values() {
                collect_invoke_subagent_names(child, out);
            }
        }
        Value::Array(items) => {
            for item in items {
                collect_invoke_subagent_names(item, out);
            }
        }
        _ => {}
    }
}

fn extract_created_conversation_id(content: &str) -> Option<String> {
    let marker_pos = content.find(CREATED_MARKER)?;
    let tail = &content[marker_pos + CREATED_MARKER.len()..];
    let brace_pos = tail.find('{')?;
    let json_slice = &tail[brace_pos..];
    let mut stream = serde_json::Deserializer::from_str(json_slice).into_iter::<Value>();
    let value = stream.next()?.ok()?;
    let id = value
        .get("conversationId")
        .or_else(|| value.get("conversation_id"))
        .and_then(Value::as_str)?
        .trim();
    (!id.is_empty()).then(|| id.to_string())
}

fn parse_transcript_file(path: &Path, parent_id: &str) -> Vec<SpawnRecord> {
    let Ok(file) = File::open(path) else {
        return Vec::new();
    };
    let mut spawns = Vec::new();
    let mut pending_names = VecDeque::<String>::new();
    let mut last_name: Option<String> = None;

    for line in BufReader::new(file).lines().map_while(std::result::Result::ok) {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let Ok(value) = serde_json::from_str::<Value>(trimmed) else {
            continue;
        };
        let entry_type = value.get("type").and_then(Value::as_str).unwrap_or("");
        if entry_type == "PLANNER_RESPONSE" {
            let mut found = Vec::new();
            collect_invoke_subagent_names(&value, &mut found);
            if !found.is_empty() {
                last_name = found.last().cloned();
                pending_names.extend(found);
            }
            continue;
        }
        if entry_type == "GENERIC" {
            let Some(content) = value.get("content").and_then(Value::as_str) else {
                continue;
            };
            let Some(child_id) = extract_created_conversation_id(content) else {
                continue;
            };
            let started_ms = value
                .get("created_at")
                .or_else(|| value.get("createdAt"))
                .and_then(Value::as_str)
                .and_then(|ts| DateTime::parse_from_rfc3339(ts).ok())
                .map(|dt| dt.timestamp_millis());
            let name = pending_names.pop_front().or_else(|| last_name.clone());
            spawns.push(SpawnRecord {
                parent_id: parent_id.to_string(),
                child_id,
                name,
                started_ms,
            });
            continue;
        }
        // Also inspect non-GENERIC entries that might carry synchronous invoke_subagent calls.
        let mut found = Vec::new();
        collect_invoke_subagent_names(&value, &mut found);
        if !found.is_empty() {
            last_name = found.last().cloned();
            pending_names.extend(found);
        }
    }
    spawns
}

fn load_spawns(home: &Path, client_filter: Option<&str>) -> Vec<SpawnRecord> {
    let mut all = Vec::new();
    let gemini_root = home.join(".gemini");
    for (dir_name, client) in ANTIGRAVITY_BRAIN_DIRS {
        if let Some(wanted) = client_filter {
            if wanted != client {
                continue;
            }
        }
        let brain_dir = gemini_root.join(dir_name).join("brain");
        let Ok(entries) = fs::read_dir(&brain_dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let parent_id = entry.file_name().to_string_lossy().into_owned();
            if parent_id.is_empty() || parent_id.starts_with('.') {
                continue;
            }
            let transcript = entry
                .path()
                .join(".system_generated")
                .join("logs")
                .join("transcript.jsonl");
            let Ok(meta) = fs::metadata(&transcript) else {
                continue;
            };
            let mtime = meta.modified().ok();
            let len = meta.len();
            let cached = {
                let guard = cache().lock().unwrap_or_else(|e| e.into_inner());
                guard
                    .get(&transcript)
                    .filter(|c| c.mtime == mtime && c.len == len)
                    .map(|c| c.spawns.clone())
            };
            let spawns = match cached {
                Some(spawns) => spawns,
                None => {
                    let parsed = parse_transcript_file(&transcript, &parent_id);
                    let mut guard = cache().lock().unwrap_or_else(|e| e.into_inner());
                    guard.insert(
                        transcript,
                        CachedTranscript {
                            mtime,
                            len,
                            spawns: parsed.clone(),
                        },
                    );
                    parsed
                }
            };
            all.extend(spawns);
        }
    }
    all
}

pub fn query(db: &Connection, f: &Filter, home: &Path) -> Result<Option<Report>> {
    Ok(reports(db, f, home)?.family)
}

#[derive(Default)]
pub(crate) struct ScopedReports {
    pub family: Option<Report>,
    pub by_client: BTreeMap<String, Report>,
}

pub(crate) fn reports(db: &Connection, f: &Filter, home: &Path) -> Result<ScopedReports> {
    let mut reports = ScopedReports::default();
    let zone = Config::system_timezone();
    for client in CLIENTS {
        if f.client.as_deref().is_some_and(|filter| filter != client) {
            continue;
        }
        let mut scoped = f.clone();
        scoped.client = Some(client.into());
        let Some(mut report) = query_with_timezone(db, &scoped, home, zone)? else {
            continue;
        };
        let family = reports.family.get_or_insert_with(empty_report);
        family.starts += report.starts;
        family.tokens += report.tokens;
        family.cost.merge(&report.cost);
        family.conversations.append(&mut report.conversations);
        // Rankings only need summary values. Keep local conversation details in the family report.
        reports.by_client.insert(client.into(), report);
    }
    if let Some(family) = &mut reports.family {
        family.conversations.sort_by(|left, right| {
            right
                .tokens
                .cmp(&left.tokens)
                .then(right.starts.cmp(&left.starts))
                .then(left.id.cmp(&right.id))
        });
        add_titles(family, home);
    }
    Ok(reports)
}

fn empty_report() -> Report {
    Report {
        starts: 0,
        tokens: 0,
        cost: Cost::default(),
        conversations: Vec::new(),
    }
}

// These identities stay in the worker and are used only to join effective ledger rows.
#[derive(Serialize)]
pub(crate) struct SnapshotChild {
    client: &'static str,
    id: String,
    started_ms: Option<i64>,
}

pub(crate) fn snapshot_children(home: &Path) -> Vec<SnapshotChild> {
    CLIENTS
        .into_iter()
        .flat_map(|client| {
            unique_children(load_spawns(home, Some(client)))
                .into_values()
                .map(move |record| SnapshotChild {
                    client,
                    id: record.child_id,
                    started_ms: record.started_ms,
                })
        })
        .collect()
}

fn unique_children(raw_spawns: Vec<SpawnRecord>) -> HashMap<String, SpawnRecord> {
    // App variants can repeat the same spawn. Retain the first available name and earliest start.
    let mut children = HashMap::<String, SpawnRecord>::new();
    for record in raw_spawns {
        children
            .entry(record.child_id.clone())
            .and_modify(|existing| {
                if existing.name.is_none() && record.name.is_some() {
                    existing.name = record.name.clone();
                }
                if let Some(started_ms) = record.started_ms {
                    existing.started_ms = Some(
                        existing
                            .started_ms
                            .map_or(started_ms, |current| current.min(started_ms)),
                    );
                }
            })
            .or_insert(record);
    }
    children
}

fn query_with_timezone(
    db: &Connection,
    f: &Filter,
    home: &Path,
    zone: chrono_tz::Tz,
) -> Result<Option<Report>> {
    if f.client
        .as_deref()
        .is_some_and(|c| c != "antigravity" && c != "antigravity-cli")
        || f.source.as_deref().is_some_and(|s| s != "local")
        || f.conversation.is_some()
        || f.timestamp_from_ms.is_some()
    {
        return Ok(None);
    }

    let children = unique_children(load_spawns(home, f.client.as_deref()));
    if children.is_empty() {
        return Ok(None);
    }

    let mut relevant_sessions = HashSet::<String>::new();
    for record in children.values() {
        relevant_sessions.insert(record.child_id.clone());
        relevant_sessions.insert(record.parent_id.clone());
    }

    let mut scoped = f.clone();
    scoped.source = Some("local".into());
    let mut usage = HashMap::<String, BTreeMap<String, Usage>>::new();
    let mut statement = db.prepare_cached(&format!(
        "SELECT {SESSION_SQL},model,sum(tokens),sum(estimated_cost),
                sum(CASE WHEN estimated_cost IS NULL THEN tokens ELSE 0 END)
         FROM effective_usage{WHERE_SQL}
         AND client IN ('antigravity', 'antigravity-cli')
         AND {SESSION_SQL} IS NOT NULL
         GROUP BY {SESSION_SQL},model"
    ))?;
    let mut rows = statement.query(params_from_iter(scoped.sql_parameters()))?;
    while let Some(row) = rows.next()? {
        let session: String = row.get(0)?;
        if relevant_sessions.contains(&session) {
            let entry = usage
                .entry(session)
                .or_default()
                .entry(row.get(1)?)
                .or_default();
            entry.tokens += row.get::<_, i64>(2)?;
            entry.cost.accumulate(row.get(3)?, row.get(4)?);
        }
    }

    let mut report = empty_report();
    let mut conversations = HashMap::<String, Conversation>::new();

    for record in children.values() {
        let models = usage.get(&record.child_id);
        let mut totals = Usage::default();
        for model in models.into_iter().flat_map(BTreeMap::values) {
            totals.tokens += model.tokens;
            totals.cost.merge(&model.cost);
        }
        let date_in_range = record
            .started_ms
            .and_then(|ms| zone.timestamp_millis_opt(ms).single())
            .map(|dt| dt.format("%Y-%m-%d").to_string())
            .is_some_and(|date| in_range(&date, f));
        let starts = i64::from(
            date_in_range
                && (f.model.is_none() || models.is_some())
                && (f.provider.is_none() || models.is_some()),
        );
        if !has_activity(starts, totals.tokens, &totals.cost) {
            continue;
        }
        report.starts += starts;
        report.tokens += totals.tokens;
        report.cost.merge(&totals.cost);

        let parent_id = &record.parent_id;
        let conversation = conversations
            .entry(parent_id.clone())
            .or_insert_with(|| Conversation {
                id: parent_id.clone(),
                title: None,
                starts: 0,
                tokens: 0,
                cost: Cost::default(),
                main_turns: None,
                main_tokens: usage
                    .get(parent_id)
                    .map(|m| m.values().map(|u| u.tokens).sum()),
                agents: Vec::new(),
            });
        conversation.starts += starts;
        conversation.tokens += totals.tokens;
        conversation.cost.merge(&totals.cost);
        conversation.agents.push(Agent {
            id: record.child_id.clone(),
            name: record.name.clone(),
            starts,
            models: models
                .into_iter()
                .flatten()
                .map(|(model, u)| ModelUsage {
                    model: model.clone(),
                    tokens: u.tokens,
                    cost: u.cost.clone(),
                })
                .collect(),
        });
    }

    if !has_activity(report.starts, report.tokens, &report.cost) {
        return Ok(None);
    }

    report.conversations = conversations.into_values().collect();
    for conversation in &mut report.conversations {
        conversation
            .agents
            .sort_by(|left, right| left.id.cmp(&right.id));
    }
    Ok(Some(report))
}

pub(crate) fn add_titles(report: &mut Report, home: &Path) {
    if report.conversations.is_empty() {
        return;
    }
    let mut titles = antigravity_titles(home, "antigravity");
    for (id, title) in antigravity_titles(home, "antigravity-cli") {
        titles.entry(id).or_insert(title);
    }
    for conversation in &mut report.conversations {
        if let Some(title) = titles.get(&conversation.id) {
            conversation.title = Some(title.clone());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        db::{put_record, Database},
        usage::{Tokens, UsageRecord},
    };
    use tempfile::TempDir;

    fn write_transcript(home: &Path, dir: &str, parent_id: &str, lines: &[&str]) {
        let log_dir = home
            .join(".gemini")
            .join(dir)
            .join("brain")
            .join(parent_id)
            .join(".system_generated")
            .join("logs");
        fs::create_dir_all(&log_dir).unwrap();
        fs::write(log_dir.join("transcript.jsonl"), lines.join("\n") + "\n").unwrap();
    }

    fn write_spawns(home: &Path, dir: &str, parent: &str, children: &[(&str, &str)]) {
        let lines: Vec<String> = children
            .iter()
            .map(|(id, date)| {
                let child = serde_json::json!({ "conversationId": id });
                serde_json::json!({
                    "type": "GENERIC", "created_at": date,
                    "content": format!("{CREATED_MARKER} {child}"),
                })
                .to_string()
            })
            .collect();
        write_transcript(
            home,
            dir,
            parent,
            &lines.iter().map(String::as_str).collect::<Vec<_>>(),
        );
    }

    fn record(
        key: &str,
        client: &str,
        session_id: &str,
        date: &str,
        model: &str,
        tokens: i64,
        cost: Option<f64>,
    ) -> UsageRecord {
        UsageRecord {
            key: key.into(),
            client: client.into(),
            provider: "google".into(),
            model: model.into(),
            date: date.into(),
            timezone: Some("UTC".into()),
            session_id: Some(session_id.into()),
            timestamp_ms: None,
            tokens: Tokens {
                input: tokens,
                output: 0,
                cache_read: 0,
                cache_write: 0,
                reasoning: 0,
            },
            requests: Some(1),
            source_cost_usd: None,
            estimated_cost_usd: cost,
            cost_basis: cost.map(|_| "estimated".into()),
            price_snapshot_id: None,
            metadata: Value::Null,
        }
    }

    #[test]
    fn overview_keeps_app_subagents_out_of_an_ordinary_cli_row() {
        let fixture = TempDir::new().unwrap();
        let home = fixture.path();
        let mut db = Database::open(&home.join("db")).unwrap();
        write_spawns(
            home,
            "antigravity",
            "app-parent",
            &[("app-child", "2026-05-10T08:00:00Z")],
        );
        for row in [
            record(
                "app",
                "antigravity",
                "app-child",
                "2026-05-10",
                "app-model",
                60,
                Some(0.1),
            ),
            record(
                "cli",
                "antigravity-cli",
                "cli-ordinary",
                "2026-05-10",
                "cli-model",
                20,
                None,
            ),
        ] {
            add_local_record(&db, &row);
        }

        let payload = serde_json::to_value(
            crate::queries::overview(&mut db, &Filter::default(), home).unwrap(),
        )
        .unwrap();
        assert_eq!(payload["clients"].as_array().unwrap().len(), 2);
        assert_eq!(payload["antigravitySubagents"]["tokens"], 60);
        assert_eq!(
            payload["antigravitySubagentsByClient"]["antigravity"]["tokens"],
            60
        );
        assert!(payload["antigravitySubagentsByClient"]["antigravity-cli"].is_null());
    }

    #[test]
    fn device_snapshot_exports_scoped_antigravity_activity_without_conversation_ids() {
        let fixture = TempDir::new().unwrap();
        let home = fixture.path();
        let mut db = Database::open(&home.join("db")).unwrap();
        let app_spawn = ("private-app-child", "2026-05-10T17:00:00Z");
        write_spawns(
            home,
            "antigravity",
            "private-parent",
            &[app_spawn, ("private-unused-child", "2026-05-10T19:00:00Z")],
        );
        write_spawns(home, "antigravity-insiders", "private-copy", &[app_spawn]);
        write_spawns(
            home,
            "antigravity-cli",
            "private-cli-parent",
            &[("private-cli-child", "2026-05-10T18:00:00Z")],
        );

        let mut app = record(
            "app",
            "antigravity",
            "private-app-child",
            "2026-05-10",
            "app-model",
            60,
            Some(0.1),
        );
        app.timestamp_ms = Some(
            chrono::DateTime::parse_from_rfc3339("2026-05-10T17:01:00Z")
                .unwrap()
                .timestamp_millis(),
        );
        for row in [
            app,
            record(
                "cli",
                "antigravity-cli",
                "private-cli-child",
                "2026-05-12",
                "cli-model",
                20,
                None,
            ),
            record(
                "same-id",
                "antigravity-cli",
                "private-app-child",
                "2026-05-12",
                "cli-model",
                5,
                None,
            ),
        ] {
            add_local_record(&db, &row);
        }

        let payload = serde_json::to_value(
            crate::device_snapshot::export_with_home(&mut db, "UTC", home).unwrap(),
        )
        .unwrap();
        assert_eq!(payload["schemaVersion"], 1);
        let buckets = payload["buckets"].as_array().unwrap();
        let subagent_buckets: Vec<_> = buckets
            .iter()
            .filter(|b| b["isAntigravitySubagent"] == true)
            .collect();
        assert_eq!(subagent_buckets.len(), 2);
        assert_eq!(subagent_buckets[0]["client"], "antigravity");
        assert_eq!(subagent_buckets[0]["date"], "2026-05-11");
        assert_eq!(subagent_buckets[0]["summary"]["tokens"], 60);
        assert_eq!(subagent_buckets[0]["summary"]["knownEstimatedCostUsd"], 0.1);
        assert_eq!(subagent_buckets[1]["summary"]["tokens"], 20);
        assert_eq!(subagent_buckets[1]["summary"]["unpricedTokens"], 20);
        assert!(buckets.iter().all(|b| b["isSubagent"] == false));
        let starts = payload["antigravitySubagentStarts"].as_array().unwrap();
        let find = |client: &str, model: Option<&str>| {
            starts
                .iter()
                .find(|b| {
                    b["client"] == client && b["provider"].is_null() && b["model"].as_str() == model
                })
                .unwrap()
        };
        let app = find("antigravity", None);
        assert_eq!(app["date"], "2026-05-11");
        assert_eq!(app["count"], 2);
        let scoped_cli = find("antigravity-cli", Some("cli-model"));
        assert_eq!(scoped_cli["date"], "2026-05-11");
        assert!(scoped_cli["nearestBefore"].is_null());
        assert_eq!(scoped_cli["nearestAfter"], "2026-05-12");
        assert_eq!(scoped_cli["count"], 1);
        assert!(!serde_json::to_string(&payload)
            .unwrap()
            .contains("private-"));
    }

    fn add_local_record(db: &Database, row: &UsageRecord) {
        put_record(&db.connection, "local", "", row).unwrap();
        db.connection.execute(
            "INSERT OR IGNORE INTO coverage_choices (date, client, source, batch_id) VALUES (?1, ?2, 'local', '')",
            rusqlite::params![row.date, row.client],
        ).unwrap();
    }

    #[test]
    fn parses_transcript_aggregates_usage_and_filters_by_date() {
        let tmp = TempDir::new().unwrap();
        let home = tmp.path();
        let db = Database::open(&home.join("db")).unwrap();

        let planner_line = r#"{"type":"PLANNER_RESPONSE","created_at":"2026-05-10T08:00:00Z","tool_calls":[{"name":"invoke_subagent","arguments":{"Role":"Codebase Researcher","TypeName":"research"}}]}"#;
        let generic_line_1 = r#"{"type":"GENERIC","created_at":"2026-05-10T08:00:02Z","content":"Created the following subagent:\n{\"conversationId\":\"child-1\",\"status\":\"started\"}"}"#;
        let generic_line_2 = r#"{"type":"GENERIC","created_at":"2026-05-12T09:00:00Z","content":"Created the following subagent: {\"conversationId\":\"child-2\"}"}"#;

        write_transcript(
            home,
            "antigravity",
            "parent-1",
            &[planner_line, generic_line_1, generic_line_2],
        );

        let records = vec![
            record("k1", "antigravity", "parent-1", "2026-05-10", "gemini-2.5-pro", 5000, Some(0.5)),
            record("k2", "antigravity", "child-1", "2026-05-10", "gemini-2.5-flash", 2000, Some(0.1)),
            record("k3", "antigravity", "child-2", "2026-05-12", "gemini-2.5-pro", 3000, Some(0.3)),
        ];
        for r in &records {
            put_record(&db.connection, "local", "", r).unwrap();
            db.connection
                .execute(
                    "INSERT OR IGNORE INTO coverage_choices (date, client, source, batch_id) VALUES (?1, ?2, 'local', '')",
                    rusqlite::params![r.date, r.client],
                )
                .unwrap();
        }

        // Full range
        let report = query_with_timezone(&db.connection, &Filter::default(), home, chrono_tz::UTC)
            .unwrap()
            .expect("expected antigravity subagents report");
        assert_eq!(report.starts, 2);
        assert_eq!(report.tokens, 5000);
        assert!((report.cost.known_estimated_cost_usd.unwrap() - 0.4).abs() < 1e-9);
        assert_eq!(report.conversations.len(), 1);
        let conv = &report.conversations[0];
        assert_eq!(conv.id, "parent-1");
        assert_eq!(conv.main_tokens, Some(5000));
        assert_eq!(conv.agents.len(), 2);
        assert_eq!(conv.agents[0].id, "child-1");
        assert_eq!(conv.agents[0].name.as_deref(), Some("Codebase Researcher"));
        assert_eq!(conv.agents[0].starts, 1);

        // Date filtered to 2026-05-10 only
        let filtered = query_with_timezone(
            &db.connection,
            &Filter {
                from: Some("2026-05-10".into()),
                to: Some("2026-05-10".into()),
                ..Default::default()
            },
            home,
            chrono_tz::UTC,
        )
        .unwrap()
        .expect("expected filtered report");
        assert_eq!(filtered.starts, 1);
        assert_eq!(filtered.tokens, 2000);
        assert_eq!(filtered.conversations[0].agents.len(), 1);
        assert_eq!(filtered.conversations[0].agents[0].id, "child-1");

        // Non-antigravity client returns None
        let codex_only = query_with_timezone(
            &db.connection,
            &Filter {
                client: Some("codex".into()),
                ..Default::default()
            },
            home,
            chrono_tz::UTC,
        )
        .unwrap();
        assert!(codex_only.is_none());

        // Out-of-range date returns None
        let empty = query_with_timezone(
            &db.connection,
            &Filter {
                from: Some("2026-06-01".into()),
                to: Some("2026-06-02".into()),
                ..Default::default()
            },
            home,
            chrono_tz::UTC,
        )
        .unwrap();
        assert!(empty.is_none());
    }
}
