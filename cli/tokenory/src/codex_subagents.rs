// [INPUT]: Verified Codex rollout metadata, user-turn starts, and effective ledger records.
// [OUTPUT]: Scoped spawn counts, Tokens and available ledger estimates, grouped under verified parent conversations.
// [POS]: Stores evidence separately from pricing and completed-turn speed data.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
mod logs;

use logs::ThreadKind;
pub(crate) use logs::{Cache, ThreadActivity};

use crate::queries::{Filter, SESSION_SQL, WHERE_SQL};
use anyhow::{ensure, Context, Result};
use rusqlite::{params, params_from_iter, Connection};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashMap},
    path::Path,
};

pub(crate) const UNIQUE_ALIASES_SQL: &str = "SELECT ledger_id,min(thread_id) AS thread_id
    FROM codex_activity_aliases GROUP BY ledger_id HAVING count(*)=1";

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    pub starts: i64,
    pub tokens: i64,
    #[serde(default)]
    pub cost: Cost,
    pub conversations: Vec<Conversation>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Conversation {
    pub id: String,
    pub title: Option<String>,
    pub starts: i64,
    pub tokens: i64,
    #[serde(default)]
    pub cost: Cost,
    pub main_turns: Option<i64>,
    pub main_tokens: Option<i64>,
    pub agents: Vec<Agent>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Agent {
    pub id: String,
    pub name: Option<String>,
    pub starts: i64,
    pub models: Vec<ModelUsage>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelUsage {
    pub model: String,
    pub tokens: i64,
    #[serde(default)]
    pub cost: Cost,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Cost {
    pub known_estimated_cost_usd: Option<f64>,
    pub unpriced_tokens: i64,
}

impl Cost {
    pub(crate) fn accumulate(&mut self, known: Option<f64>, unpriced_tokens: i64) {
        if let Some(known) = known {
            *self.known_estimated_cost_usd.get_or_insert(0.0) += known;
        }
        self.unpriced_tokens += unpriced_tokens;
    }

    pub(crate) fn merge(&mut self, other: &Self) {
        self.accumulate(other.known_estimated_cost_usd, other.unpriced_tokens);
    }
}

#[derive(Default)]
struct Usage {
    tokens: i64,
    cost: Cost,
}

pub(crate) fn persist(
    db: &Connection,
    activities: &[ThreadActivity],
    timezone: &str,
) -> Result<bool> {
    if activities.is_empty() {
        return Ok(false);
    }
    let zone = timezone.parse::<chrono_tz::Tz>()?;
    let date_for = |timestamp| -> Result<String> {
        Ok(chrono::DateTime::from_timestamp_millis(timestamp)
            .filter(|_| timestamp > 0)
            .context("invalid Codex activity timestamp")?
            .with_timezone(&zone)
            .format("%Y-%m-%d")
            .to_string())
    };
    let mut thread = db.prepare_cached(
        "INSERT INTO codex_activity_threads VALUES (?1,?2,?3,?4,?5,?6,?7)
         ON CONFLICT(id) DO UPDATE SET
             name=COALESCE(excluded.name,codex_activity_threads.name),
             provider=COALESCE(codex_activity_threads.provider,excluded.provider)
         WHERE codex_activity_threads.parent_id IS excluded.parent_id
           AND codex_activity_threads.depth=excluded.depth
           AND ((excluded.name IS NOT NULL AND codex_activity_threads.name IS NOT excluded.name)
             OR (codex_activity_threads.provider IS NULL AND excluded.provider IS NOT NULL))",
    )?;
    let mut alias = db.prepare_cached(
        "INSERT OR IGNORE INTO codex_activity_aliases
         SELECT ?1,id FROM codex_activity_threads WHERE id=?2 AND parent_id IS ?3 AND depth=?4",
    )?;
    let mut turn = db.prepare_cached(
        "INSERT INTO codex_main_turn_starts
         SELECT id,?2,?3,?4,?5,?6 FROM codex_activity_threads WHERE id=?1 AND depth=0
         ON CONFLICT(thread_id,turn_id) DO UPDATE SET
             model=CASE WHEN excluded.model_conflicted OR codex_main_turn_starts.model IS NOT NULL
                        THEN NULL ELSE excluded.model END,
             model_conflicted=excluded.model_conflicted OR codex_main_turn_starts.model IS NOT NULL
         WHERE NOT codex_main_turn_starts.model_conflicted
           AND (excluded.model_conflicted OR
                (excluded.model IS NOT NULL AND excluded.model IS NOT codex_main_turn_starts.model))",
    )?;
    let mut changed = false;
    for activity in activities {
        let (parent_id, depth, name) = match &activity.kind {
            ThreadKind::Main => (None, 0, None),
            ThreadKind::Spawned {
                parent_id,
                depth,
                name,
            } => (Some(parent_id.as_str()), *depth, name.as_deref()),
        };
        changed |= thread.execute(params![
            activity.id,
            parent_id,
            depth,
            name,
            activity.provider,
            activity.started_ms,
            date_for(activity.started_ms)?
        ])? > 0;
        changed |= alias.execute(params![
            activity.ledger_session_id,
            activity.id,
            parent_id,
            depth
        ])? > 0;
        for user_turn in &activity.main_turns {
            changed |= turn.execute(params![
                activity.id,
                user_turn.id,
                user_turn.started_ms,
                date_for(user_turn.started_ms)?,
                user_turn.model,
                user_turn.mixed_models
            ])? > 0;
        }
    }
    Ok(changed)
}

pub(crate) fn validate_backup(db: &Connection) -> Result<()> {
    for statement in [
        "SELECT id,parent_id,depth,name,provider,started_ms,date FROM codex_activity_threads LIMIT 0",
        "SELECT ledger_id,thread_id FROM codex_activity_aliases LIMIT 0",
        "SELECT thread_id,turn_id,started_ms,date,model,model_conflicted FROM codex_main_turn_starts LIMIT 0",
    ] {
        db.prepare(statement)?;
    }
    let mut check = db.prepare("PRAGMA foreign_key_check")?;
    ensure!(
        check.query([])?.next()?.is_none(),
        "backup contains invalid activity references"
    );
    Ok(())
}

struct Thread {
    parent: Option<String>,
    depth: u32,
    name: Option<String>,
    provider: Option<String>,
    date: String,
}

fn conversation_root<'a>(
    mut child: &'a Thread,
    threads: &'a HashMap<String, Thread>,
) -> Option<&'a str> {
    while let Some(parent_id) = &child.parent {
        if child.depth == 1 {
            // The start event itself identifies a root. Its log may be absent.
            return threads
                .get(parent_id)
                .is_none_or(|parent| parent.depth == 0)
                .then_some(parent_id.as_str());
        }
        let parent = threads.get(parent_id)?;
        // Require a complete, strictly decreasing chain. In particular a
        // missing intermediate log is not evidence of a different root.
        if parent.depth != child.depth.checked_sub(1)? {
            return None;
        }
        child = parent;
    }
    None
}

fn in_range(date: &str, filter: &Filter) -> bool {
    filter.from.as_deref().is_none_or(|from| date >= from)
        && filter.to.as_deref().is_none_or(|to| date <= to)
}

fn has_activity(starts: i64, tokens: i64, cost: &Cost) -> bool {
    starts > 0 || tokens > 0 || cost.known_estimated_cost_usd.unwrap_or_default() > 0.0
}

pub(crate) fn query(db: &Connection, filter: &Filter) -> Result<Option<Report>> {
    if filter
        .client
        .as_deref()
        .is_some_and(|client| client != "codex")
        || filter
            .source
            .as_deref()
            .is_some_and(|source| source != "local")
        || filter.conversation.is_some()
        || filter.timestamp_from_ms.is_some()
        || !db.query_row(
            "SELECT EXISTS(SELECT 1 FROM codex_activity_threads WHERE depth > 0)",
            [],
            |row| row.get::<_, bool>(0),
        )?
    {
        return Ok(None);
    }
    let threads = db
        .prepare_cached("SELECT id,parent_id,depth,name,provider,date FROM codex_activity_threads")?
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                Thread {
                    parent: row.get(1)?,
                    depth: row.get(2)?,
                    name: row.get(3)?,
                    provider: row.get(4)?,
                    date: row.get(5)?,
                },
            ))
        })?
        .collect::<rusqlite::Result<HashMap<_, _>>>()?;
    let roots: HashMap<_, _> = threads
        .iter()
        .filter(|(_, thread)| thread.depth > 0)
        .filter_map(|(id, thread)| Some((id.as_str(), conversation_root(thread, &threads)?)))
        .collect();
    let aliases = db.prepare_cached(UNIQUE_ALIASES_SQL)?
        .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?
        .collect::<rusqlite::Result<HashMap<_, _>>>()?;
    let mut scoped = filter.clone();
    scoped.client = Some("codex".into());
    scoped.source = Some("local".into());
    let mut usage = HashMap::<String, BTreeMap<String, Usage>>::new();
    let mut statement = db.prepare_cached(&format!(
        "SELECT {SESSION_SQL},model,sum(tokens),sum(estimated_cost),
                sum(CASE WHEN estimated_cost IS NULL THEN tokens ELSE 0 END)
         FROM effective_usage{WHERE_SQL}
         AND {SESSION_SQL} IS NOT NULL GROUP BY {SESSION_SQL},model"
    ))?;
    let mut rows = statement.query(params_from_iter(scoped.sql_parameters()))?;
    while let Some(row) = rows.next()? {
        let session: String = row.get(0)?;
        let id = aliases.get(&session).unwrap_or(&session);
        if threads.contains_key(id) {
            let entry = usage
                .entry(id.clone())
                .or_default()
                .entry(row.get(1)?)
                .or_default();
            entry.tokens += row.get::<_, i64>(2)?;
            entry.cost.accumulate(row.get(3)?, row.get(4)?);
        }
    }
    let main_turns = db
        .prepare_cached(
            "SELECT s.thread_id,count(*) FROM codex_main_turn_starts s
         JOIN codex_activity_threads t ON t.id=s.thread_id
         WHERE (?1 IS NULL OR s.date>=?1) AND (?2 IS NULL OR s.date<=?2)
         AND (?3 IS NULL OR s.model=?3) AND (?4 IS NULL OR t.provider=?4)
         GROUP BY s.thread_id",
        )?
        .query_map(
            params![filter.from, filter.to, filter.model, filter.provider],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
        )?
        .collect::<rusqlite::Result<HashMap<_, _>>>()?;

    let mut report = Report {
        starts: 0,
        tokens: 0,
        cost: Cost::default(),
        conversations: Vec::new(),
    };
    let mut conversations = HashMap::<&str, Conversation>::new();
    for (id, thread) in threads.iter().filter(|(_, thread)| thread.depth > 0) {
        let models = usage.get(id);
        let mut totals = Usage::default();
        for model in models.into_iter().flat_map(BTreeMap::values) {
            totals.tokens += model.tokens;
            totals.cost.merge(&model.cost);
        }
        let starts = i64::from(
            in_range(&thread.date, filter)
                && (filter.model.is_none() || models.is_some())
                && (filter.provider.is_none()
                    || thread.provider == filter.provider
                    || models.is_some()),
        );
        if !has_activity(starts, totals.tokens, &totals.cost) {
            continue;
        }
        report.starts += starts;
        report.tokens += totals.tokens;
        report.cost.merge(&totals.cost);
        let Some(root) = roots.get(id.as_str()).copied() else {
            continue;
        };
        let conversation = conversations.entry(root).or_insert_with(|| Conversation {
            id: root.into(),
            title: None,
            starts: 0,
            tokens: 0,
            cost: Cost::default(),
            main_turns: main_turns.get(root).copied(),
            main_tokens: usage
                .get(root)
                .map(|models| models.values().map(|model| model.tokens).sum()),
            agents: Vec::new(),
        });
        conversation.starts += starts;
        conversation.tokens += totals.tokens;
        conversation.cost.merge(&totals.cost);
        conversation.agents.push(Agent {
            id: id.clone(),
            name: thread.name.clone(),
            starts,
            models: models
                .into_iter()
                .flatten()
                .map(|(model, usage)| ModelUsage {
                    model: model.clone(),
                    tokens: usage.tokens,
                    cost: usage.cost.clone(),
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
    report.conversations.sort_by(|left, right| {
        right
            .tokens
            .cmp(&left.tokens)
            .then(right.starts.cmp(&left.starts))
            .then(left.id.cmp(&right.id))
    });
    Ok(Some(report))
}

pub(crate) fn add_titles(report: &mut Report, home: &Path) {
    if report.conversations.is_empty() {
        return;
    }
    let titles = crate::queries::codex_titles(home);
    for conversation in &mut report.conversations {
        conversation.title = titles.get(&conversation.id).cloned();
    }
}
