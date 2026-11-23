// [INPUT]: A consistent read of the effective ledger and verified Codex activity.
// [OUTPUT]: Versioned Beijing-time usage aggregates for one Mac, with no row, thread or file identifiers.
// [POS]: The worker's export boundary for Apple-device usage sync.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
use crate::{
    codex_subagents::UNIQUE_ALIASES_SQL,
    db::{revision, Database},
    queries::{read_summary, reporting_hour_sql, Summary, SUMMARY_SQL},
};
use anyhow::Result;
use rusqlite::Connection;
use serde::Serialize;

const REPORTING_TIMEZONE: &str = "Asia/Shanghai";

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceUsageSnapshot {
    pub schema_version: u32,
    pub revision: i64,
    pub timezone: String,
    pub buckets: Vec<Bucket>,
    pub subagent_starts: Vec<StartCount>,
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

// This join has the same alias fallback as codex_subagents::query. The
// identifiers used in it are private to the database transaction.
const AGENT_JOIN: &str = "LEFT JOIN aliases a ON r.client='codex' AND r.source='local'
       AND a.ledger_id=json_extract(r.body,'$.sessionId')
    LEFT JOIN codex_activity_threads t ON r.client='codex' AND r.source='local'
       AND t.depth>0 AND t.id=coalesce(a.thread_id,json_extract(r.body,'$.sessionId'))";

// Only individual local events can move to the common reporting day. Import
// days and approximate session timestamps describe their original buckets.
const REPORTING_DATE: &str = "CASE WHEN r.source='local'
        AND coalesce(json_extract(r.body, '$.timezone'), ?1) <> 'Asia/Shanghai'
        AND coalesce(json_extract(r.body, '$.metadata.granularity') NOT IN ('day', 'sourceRecord'), 1)
    THEN coalesce(strftime('%Y-%m-%d', json_extract(r.body, '$.timestampMs') / 1000.0, 'unixepoch', '+8 hours'), r.date)
    ELSE r.date END";
const AGENT_START_DATE: &str = "coalesce(strftime('%Y-%m-%d', t.started_ms / 1000.0, 'unixepoch', '+8 hours'), t.date)";

fn buckets(db: &Connection, timezone: &str) -> Result<Vec<Bucket>> {
    let (timed, hour) = reporting_hour_sql("%H");
    let mut stmt = db.prepare(&format!(
        "WITH aliases AS ({UNIQUE_ALIASES_SQL}), selected AS (
           SELECT {REPORTING_DATE} AS date, r.body, r.client, r.provider, r.model, r.source,
                  r.tokens, r.input, r.output, r.cache_read, r.cache_write, r.reasoning,
                  r.estimated_cost, r.requests, t.id IS NOT NULL AS agent
           FROM effective_usage r {AGENT_JOIN}
         )
         SELECT date, CASE WHEN {timed} THEN CAST({hour} AS INTEGER) END AS h,
                client, provider, model, source, agent, {SUMMARY_SQL}
         FROM selected GROUP BY date,h,client,provider,model,source,agent
         ORDER BY date,h,client,provider,model,source,agent"
    ))?;
    let rows = stmt.query_map([timezone], |row| {
        Ok(Bucket {
            date: row.get(0)?, hour: row.get(1)?, client: row.get(2)?,
            provider: row.get(3)?, model: row.get(4)?, source: row.get(5)?,
            is_subagent: row.get(6)?, summary: read_summary(row, 7)?,
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

// The Overview counts an agent once on its start day. A model filter can
// qualify it through usage on any day inside the selected range. Given a
// range containing the start day, its two nearest evidence days suffice to
// answer that question exactly, even for a multi-model agent. Collapse the
// counts by filter and date before they leave the worker.
fn starts(db: &Connection, timezone: &str) -> Result<Vec<StartCount>> {
    let mut stmt = db.prepare(&format!(
        "WITH aliases AS ({UNIQUE_ALIASES_SQL}),
         starts AS (
           SELECT t.id, {AGENT_START_DATE} AS date,t.provider FROM codex_activity_threads t WHERE t.depth>0
         ),
         seen AS (
           SELECT DISTINCT t.id,{AGENT_START_DATE} AS start,{REPORTING_DATE} AS evidence,r.provider,r.model
           FROM effective_usage r {AGENT_JOIN}
           WHERE r.client='codex' AND r.source='local' AND t.id IS NOT NULL
         ),
         scopes(id,start,evidence,provider,model) AS (
           SELECT id,date,date,NULL,NULL FROM starts
           UNION ALL SELECT id,date,date,provider,NULL FROM starts WHERE provider IS NOT NULL
           UNION ALL SELECT id,start,evidence,provider,NULL FROM seen
           UNION ALL SELECT id,start,evidence,NULL,model FROM seen
           UNION ALL SELECT id,start,evidence,provider,model FROM seen
         ),
         per_agent AS (
           SELECT start,provider,model,
               max(CASE WHEN evidence<=start THEN evidence END) AS earlier,
               min(CASE WHEN evidence>=start THEN evidence END) AS later
           FROM scopes GROUP BY id,start,provider,model
         )
         SELECT start,provider,model,earlier,later,count(*) FROM per_agent
         GROUP BY start,provider,model,earlier,later ORDER BY start,provider,model,earlier,later"
    ))?;
    let rows = stmt.query_map([timezone], |row| {
        Ok(StartCount {
            date: row.get(0)?, provider: row.get(1)?, model: row.get(2)?,
            nearest_before: row.get(3)?, nearest_after: row.get(4)?, count: row.get(5)?,
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

pub fn export(db: &mut Database, timezone: &str) -> Result<DeviceUsageSnapshot> {
    let tx = db.connection.transaction()?;
    let snapshot = DeviceUsageSnapshot {
        schema_version: 1,
        revision: revision(&tx)?,
        timezone: REPORTING_TIMEZONE.to_owned(),
        buckets: buckets(&tx, timezone)?,
        subagent_starts: starts(&tx, timezone)?,
    };
    tx.commit()?;
    Ok(snapshot)
}
