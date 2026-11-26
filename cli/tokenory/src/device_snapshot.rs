// [INPUT]: A consistent read of the effective ledger and local Codex and Antigravity subagent evidence.
// [OUTPUT]: Versioned Beijing-time usage aggregates for one Mac, with no row, thread or file identifiers.
// [POS]: The worker's export boundary for Apple-device usage sync.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
use crate::{
    antigravity_subagents::snapshot_children,
    codex_subagents::UNIQUE_ALIASES_SQL,
    db::{revision, Database},
    queries::{read_summary, reporting_hour_sql, Summary, SUMMARY_SQL},
};
use anyhow::Result;
use rusqlite::{params, Connection};
use serde::Serialize;
use std::path::Path;

const REPORTING_TIMEZONE: &str = "Asia/Shanghai";

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceUsageSnapshot {
    pub schema_version: u32,
    pub revision: i64,
    pub timezone: String,
    pub buckets: Vec<Bucket>,
    pub subagent_starts: Vec<StartCount>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub antigravity_subagent_starts: Vec<AntigravityStartCount>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Bucket {
    pub date: String,
    pub hour: Option<u8>,
    pub client: String,
    pub provider: String,
    pub model: String,
    pub source: String,
    pub is_subagent: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_antigravity_subagent: Option<bool>,
    pub summary: Summary,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StartCount {
    pub date: String,
    pub provider: Option<String>,
    pub model: Option<String>,
    pub nearest_before: Option<String>,
    pub nearest_after: Option<String>,
    pub count: i64,
}

#[derive(Serialize)]
pub struct AntigravityStartCount {
    pub client: String,
    #[serde(flatten)]
    pub start: StartCount,
}

// This join has the same alias fallback as codex_subagents::query. The
// identifiers used in it are private to the database transaction.
const AGENT_JOIN: &str = "LEFT JOIN aliases a ON r.client='codex' AND r.source='local'
       AND a.ledger_id=json_extract(r.body,'$.sessionId')
    LEFT JOIN codex_activity_threads t ON r.client='codex' AND r.source='local'
       AND t.depth>0 AND t.id=coalesce(a.thread_id,json_extract(r.body,'$.sessionId'))";
const ANTIGRAVITY_CHILDREN: &str = "SELECT json_extract(value,'$.client') AS client,
        json_extract(value,'$.id') AS id, json_extract(value,'$.started_ms') AS started_ms
    FROM json_each(?2)";
const ANTIGRAVITY_JOIN: &str = "LEFT JOIN agy_children agy ON r.source='local'
        AND r.client=agy.client AND json_extract(r.body,'$.sessionId')=agy.id";

// Only individual local events can move to the common reporting day. Import
// days and approximate session timestamps describe their original buckets.
const REPORTING_DATE: &str = "CASE WHEN r.source='local'
        AND coalesce(json_extract(r.body, '$.timezone'), ?1) <> 'Asia/Shanghai'
        AND coalesce(json_extract(r.body, '$.metadata.granularity') NOT IN ('day', 'sourceRecord'), 1)
    THEN coalesce(strftime('%Y-%m-%d', json_extract(r.body, '$.timestampMs') / 1000.0, 'unixepoch', '+8 hours'), r.date)
    ELSE r.date END";
const AGENT_START_DATE: &str =
    "coalesce(strftime('%Y-%m-%d', t.started_ms / 1000.0, 'unixepoch', '+8 hours'), t.date)";

fn buckets(db: &Connection, timezone: &str, antigravity_children: &str) -> Result<Vec<Bucket>> {
    let (timed, hour) = reporting_hour_sql("%H");
    let mut stmt = db.prepare(&format!(
        "WITH aliases AS ({UNIQUE_ALIASES_SQL}), agy_children AS MATERIALIZED ({ANTIGRAVITY_CHILDREN}), selected AS (
           SELECT {REPORTING_DATE} AS date, r.body, r.client, r.provider, r.model, r.source,
                  r.tokens, r.input, r.output, r.cache_read, r.cache_write, r.reasoning,
                  r.estimated_cost, r.requests, t.id IS NOT NULL AS agent, agy.id IS NOT NULL AS agy_agent
           FROM effective_usage r {AGENT_JOIN} {ANTIGRAVITY_JOIN}
         )
         SELECT date, CASE WHEN {timed} THEN CAST({hour} AS INTEGER) END AS h,
                client, provider, model, source, agent, agy_agent, {SUMMARY_SQL}
         FROM selected GROUP BY date,h,client,provider,model,source,agent,agy_agent
         ORDER BY date,h,client,provider,model,source,agent,agy_agent"
    ))?;
    let rows = stmt.query_map(params![timezone, antigravity_children], |row| {
        Ok(Bucket {
            date: row.get(0)?,
            hour: row.get(1)?,
            client: row.get(2)?,
            provider: row.get(3)?,
            model: row.get(4)?,
            source: row.get(5)?,
            is_subagent: row.get(6)?,
            is_antigravity_subagent: row.get::<_, bool>(7)?.then_some(true),
            summary: read_summary(row, 8)?,
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

// The Overview counts an agent once on its start day. A model filter can
// qualify it through usage on any day inside the selected range. Given a
// range containing the start day, its two nearest evidence days suffice to
// answer that question exactly, even for a multi-model agent. Collapse the
// counts by filter and date before they leave the worker.
fn starts(
    db: &Connection,
    timezone: &str,
    antigravity_children: &str,
) -> Result<(Vec<StartCount>, Vec<AntigravityStartCount>)> {
    const ANTIGRAVITY_START_DATE: &str =
        "strftime('%Y-%m-%d', agy.started_ms / 1000.0, 'unixepoch', '+8 hours')";
    let mut stmt = db.prepare(&format!(
        "WITH aliases AS ({UNIQUE_ALIASES_SQL}), agy_children AS MATERIALIZED ({ANTIGRAVITY_CHILDREN}),
         codex_starts AS (
           SELECT t.id, {AGENT_START_DATE} AS date,t.provider FROM codex_activity_threads t WHERE t.depth>0
         ),
         codex_seen AS (
           SELECT DISTINCT t.id,{AGENT_START_DATE} AS start,{REPORTING_DATE} AS evidence,r.provider,r.model
           FROM effective_usage r {AGENT_JOIN}
           WHERE r.client='codex' AND r.source='local' AND t.id IS NOT NULL
         ),
         agy_starts AS (
           SELECT agy.client,agy.id,{ANTIGRAVITY_START_DATE} AS date FROM agy_children agy WHERE agy.started_ms IS NOT NULL
         ),
         agy_seen AS (
           SELECT DISTINCT agy.client,agy.id,{ANTIGRAVITY_START_DATE} AS start,{REPORTING_DATE} AS evidence,r.provider,r.model
           FROM effective_usage r {ANTIGRAVITY_JOIN}
           WHERE r.client IN ('antigravity','antigravity-cli') AND r.source='local' AND agy.started_ms IS NOT NULL
         ),
         scopes(client,id,start,evidence,provider,model) AS (
           SELECT 'codex',id,date,date,NULL,NULL FROM codex_starts
           UNION ALL SELECT 'codex',id,date,date,provider,NULL FROM codex_starts WHERE provider IS NOT NULL
           UNION ALL SELECT 'codex',id,start,evidence,provider,NULL FROM codex_seen
           UNION ALL SELECT 'codex',id,start,evidence,NULL,model FROM codex_seen
           UNION ALL SELECT 'codex',id,start,evidence,provider,model FROM codex_seen
           UNION ALL SELECT client,id,date,date,NULL,NULL FROM agy_starts WHERE date IS NOT NULL
           UNION ALL SELECT client,id,start,evidence,provider,NULL FROM agy_seen WHERE start IS NOT NULL
           UNION ALL SELECT client,id,start,evidence,NULL,model FROM agy_seen WHERE start IS NOT NULL
           UNION ALL SELECT client,id,start,evidence,provider,model FROM agy_seen WHERE start IS NOT NULL
         ),
         per_agent AS (
           SELECT client,start,provider,model,
               max(CASE WHEN evidence<=start THEN evidence END) AS earlier,
               min(CASE WHEN evidence>=start THEN evidence END) AS later
           FROM scopes GROUP BY client,id,start,provider,model
         )
         SELECT client,start,provider,model,earlier,later,count(*) FROM per_agent
         GROUP BY client,start,provider,model,earlier,later ORDER BY client,start,provider,model,earlier,later"
    ))?;
    let mut rows = stmt.query(params![timezone, antigravity_children])?;
    let mut codex = Vec::new();
    let mut antigravity = Vec::new();
    while let Some(row) = rows.next()? {
        let client: String = row.get(0)?;
        let start = StartCount {
            date: row.get(1)?,
            provider: row.get(2)?,
            model: row.get(3)?,
            nearest_before: row.get(4)?,
            nearest_after: row.get(5)?,
            count: row.get(6)?,
        };
        if client == "codex" {
            codex.push(start);
        } else {
            antigravity.push(AntigravityStartCount { client, start });
        }
    }
    Ok((codex, antigravity))
}

pub fn export(db: &mut Database, timezone: &str) -> Result<DeviceUsageSnapshot> {
    export_with_children(db, timezone, "[]")
}

pub fn export_with_home(
    db: &mut Database,
    timezone: &str,
    home: &Path,
) -> Result<DeviceUsageSnapshot> {
    let children = serde_json::to_string(&snapshot_children(home))?;
    export_with_children(db, timezone, &children)
}

fn export_with_children(
    db: &mut Database,
    timezone: &str,
    children: &str,
) -> Result<DeviceUsageSnapshot> {
    let tx = db.connection.transaction()?;
    let (subagent_starts, antigravity_subagent_starts) = starts(&tx, timezone, children)?;
    let snapshot = DeviceUsageSnapshot {
        schema_version: 1,
        revision: revision(&tx)?,
        timezone: REPORTING_TIMEZONE.to_owned(),
        buckets: buckets(&tx, timezone, children)?,
        subagent_starts,
        antigravity_subagent_starts,
    };
    tx.commit()?;
    Ok(snapshot)
}
