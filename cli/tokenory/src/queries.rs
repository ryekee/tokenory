// [INPUT]: Validated filters and the effective ledger view.
// [OUTPUT]: Selected-range reports, complete daily client/model activity and timestamp-qualified hourly patterns.
// [POS]: Read-only aggregation boundary; never aggregate paginated details.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
use crate::{
    db::{revision, Database},
    usage::{validate_date, Tokens, UsageRecord},
};
use anyhow::{ensure, Result};
use rusqlite::{params, Connection, Row};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase", deny_unknown_fields)]
pub struct Filter {
    pub from: Option<String>,
    pub to: Option<String>,
    pub client: Option<String>,
    pub provider: Option<String>,
    pub model: Option<String>,
    pub source: Option<String>,
    pub offset: u32,
    pub limit: Option<u32>,
}
impl Filter {
    pub fn validate(&self) -> Result<()> {
        if let Some(s) = &self.from {
            validate_date(s)?;
        }
        if let Some(s) = &self.to {
            validate_date(s)?;
        }
        if let (Some(a), Some(b)) = (&self.from, &self.to) {
            ensure!(a <= b, "start date must not follow end date");
        }
        if let Some(n) = self.limit {
            ensure!((1..=500).contains(&n), "detail limit must be 1–500");
        }
        Ok(())
    }
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Summary {
    pub tokens: i64,
    pub token_breakdown: Tokens,
    pub known_estimated_cost_usd: Option<f64>,
    pub unpriced_tokens: i64,
    pub cost_status: String,
    pub record_count: i64,
    pub active_days: i64,
    pub partial_days: i64,
    pub requests: Option<i64>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Group {
    pub key: String,
    pub summary: Summary,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Detail {
    pub source: String,
    pub batch_id: String,
    #[serde(flatten)]
    pub record: UsageRecord,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    pub revision: i64,
    pub summary: Summary,
    pub daily: Vec<Group>,
    pub hourly: Option<HourlyReport>,
    pub clients: Vec<Group>,
    pub providers: Vec<Group>,
    pub models: Vec<Group>,
    pub details: Vec<Detail>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HourlyReport {
    pub buckets: Vec<Group>,
    pub unallocated: Summary,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelDay {
    pub date: String,
    pub client: String,
    pub model: String,
    pub summary: Summary,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActivityReport {
    pub revision: i64,
    pub from: String,
    pub to: String,
    pub daily: Vec<Group>,
    pub model_days: Vec<ModelDay>,
    pub hourly: HourlyReport,
}

pub fn activity(db: &mut Database, f: &Filter) -> Result<ActivityReport> {
    f.validate()?;
    let from = f.from.as_deref().ok_or_else(|| anyhow::anyhow!("activity requires a start date"))?;
    let to = f.to.as_deref().ok_or_else(|| anyhow::anyhow!("activity requires an end date"))?;
    let start = chrono::NaiveDate::parse_from_str(from, "%Y-%m-%d")?;
    let end = chrono::NaiveDate::parse_from_str(to, "%Y-%m-%d")?;
    ensure!((end - start).num_days() <= 366, "activity range must not exceed 367 days");
    let tx = db.connection.transaction()?;
    let daily = grouped(&tx, f, "date")?;
    let model_days = tx.prepare(&format!("SELECT date,client,model,{SUMMARY_SQL} FROM effective_usage{WHERE_SQL} GROUP BY date,client,model ORDER BY date,client,model"))?
        .query_map(params![f.from, f.to, f.client, f.provider, f.model, f.source], |r| {
            Ok(ModelDay { date: r.get(0)?, client: r.get(1)?, model: r.get(2)?, summary: read_summary(r, 3)? })
        })?.collect::<rusqlite::Result<Vec<_>>>()?;
    let hourly = hourly_aggregate(&tx, f, "%H")?;
    let result = ActivityReport { revision: revision(&tx)?, from: from.into(), to: to.into(), daily, model_days, hourly };
    tx.commit()?;
    Ok(result)
}
const WHERE_SQL:&str=" WHERE (?1 IS NULL OR date>=?1) AND (?2 IS NULL OR date<=?2) AND (?3 IS NULL OR client=?3) AND (?4 IS NULL OR provider=?4) AND (?5 IS NULL OR model=?5) AND (?6 IS NULL OR source=?6)";
const SUMMARY_SQL:&str="coalesce(sum(tokens),0),coalesce(sum(input),0),coalesce(sum(output),0),coalesce(sum(cache_read),0),coalesce(sum(cache_write),0),coalesce(sum(reasoning),0),sum(estimated_cost),coalesce(sum(CASE WHEN estimated_cost IS NULL THEN tokens ELSE 0 END),0),count(*),count(DISTINCT CASE WHEN tokens>0 THEN date END),sum(requests),count(DISTINCT CASE WHEN json_extract(body, '$.metadata.partialDay')=1 THEN date END)";
fn read_summary(row: &Row<'_>, start: usize) -> rusqlite::Result<Summary> {
    let known: Option<f64> = row.get(start + 6)?;
    let pending: i64 = row.get(start + 7)?;
    let count: i64 = row.get(start + 8)?;
    Ok(Summary {
        tokens: row.get(start)?,
        token_breakdown: Tokens {
            input: row.get(start + 1)?,
            output: row.get(start + 2)?,
            cache_read: row.get(start + 3)?,
            cache_write: row.get(start + 4)?,
            reasoning: row.get(start + 5)?,
        },
        known_estimated_cost_usd: known,
        unpriced_tokens: pending,
        cost_status: if count == 0 {
            "empty"
        } else if known.is_none() {
            "unknown"
        } else if pending > 0 {
            "partial"
        } else {
            "complete"
        }
        .into(),
        record_count: count,
        active_days: row.get(start + 9)?,
        requests: row.get(start + 10)?,
        partial_days: row.get(start + 11)?,
    })
}
fn grouped(c: &Connection, f: &Filter, column: &str) -> Result<Vec<Group>> {
    // Column is a private, fixed call-site choice, never interpolated user input.
    let sql=format!("SELECT {column},{SUMMARY_SQL} FROM effective_usage{WHERE_SQL} GROUP BY {column} ORDER BY {}",if column=="date" {"date ASC"}else{"sum(tokens) DESC"});
    Ok(c.prepare(&sql)?
        .query_map(
            params![f.from, f.to, f.client, f.provider, f.model, f.source],
            |r| {
                Ok(Group {
                    key: r.get(0)?,
                    summary: read_summary(r, 1)?,
                })
            },
        )?
        .collect::<rusqlite::Result<_>>()?)
}
fn hourly(c: &Connection, f: &Filter) -> Result<Option<HourlyReport>> {
    if f.from.is_none() || f.from != f.to {
        return Ok(None);
    }
    Ok(Some(hourly_aggregate(c, f, "%Y-%m-%dT%H:00:00+08:00")?))
}
fn hourly_aggregate(c: &Connection, f: &Filter, format: &str) -> Result<HourlyReport> {
    // Imported daily totals cannot be reconstructed as hourly activity. Only
    // timestamps that belong to the selected Beijing reporting day qualify.
    let timestamp = "json_extract(body, '$.timestampMs') / 1000.0";
    let timed = format!("coalesce(json_extract(body, '$.metadata.granularity') NOT IN ('day', 'sourceRecord'), 1) AND coalesce(strftime('%Y-%m-%d', {timestamp}, 'unixepoch', '+8 hours') = date, 0)");
    let key =
        format!("strftime('{format}', {timestamp}, 'unixepoch', '+8 hours')");
    let buckets = c.prepare(&format!("SELECT {key} AS hour, {SUMMARY_SQL} FROM effective_usage{WHERE_SQL} AND ({timed}) GROUP BY hour ORDER BY hour"))?
        .query_map(params![f.from, f.to, f.client, f.provider, f.model, f.source], |r| {
            Ok(Group { key: r.get(0)?, summary: read_summary(r, 1)? })
        })?.collect::<rusqlite::Result<Vec<_>>>()?;
    let unallocated = c.query_row(
        &format!("SELECT {SUMMARY_SQL} FROM effective_usage{WHERE_SQL} AND NOT ({timed})"),
        params![f.from, f.to, f.client, f.provider, f.model, f.source],
        |r| read_summary(r, 0),
    )?;
    Ok(HourlyReport { buckets, unallocated })
}
pub fn report(db: &mut Database, f: &Filter) -> Result<Report> {
    f.validate()?;
    let tx = db.connection.transaction()?;
    let summary = tx.query_row(
        &format!("SELECT {SUMMARY_SQL} FROM effective_usage{WHERE_SQL}"),
        params![f.from, f.to, f.client, f.provider, f.model, f.source],
        |r| read_summary(r, 0),
    )?;
    let rows = {
        let mut stmt=tx.prepare(&format!("SELECT source,batch_id,body FROM effective_usage{WHERE_SQL} ORDER BY date DESC,client,source,batch_id,item_key LIMIT ?7 OFFSET ?8"))?;
        let rows = stmt
            .query_map(
                params![
                    f.from,
                    f.to,
                    f.client,
                    f.provider,
                    f.model,
                    f.source,
                    f.limit.unwrap_or(200),
                    f.offset
                ],
                |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, String>(2)?,
                    ))
                },
            )?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        rows
    };
    let details = rows
        .into_iter()
        .map(|(source, batch_id, body)| {
            Ok(Detail {
                source,
                batch_id,
                record: serde_json::from_str(&body)?,
            })
        })
        .collect::<Result<_>>()?;
    let result = Report {
        revision: revision(&tx)?,
        summary,
        daily: grouped(&tx, f, "date")?,
        hourly: hourly(&tx, f)?,
        clients: grouped(&tx, f, "client")?,
        providers: grouped(&tx, f, "provider")?,
        models: grouped(&tx, f, "model")?,
        details,
    };
    tx.commit()?;
    Ok(result)
}
