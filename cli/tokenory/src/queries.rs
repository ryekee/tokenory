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
    pub clients: Vec<Group>,
    pub providers: Vec<Group>,
    pub models: Vec<Group>,
    pub details: Vec<Detail>,
}
const WHERE_SQL:&str=" WHERE (?1 IS NULL OR date>=?1) AND (?2 IS NULL OR date<=?2) AND (?3 IS NULL OR client=?3) AND (?4 IS NULL OR provider=?4) AND (?5 IS NULL OR model=?5) AND (?6 IS NULL OR source=?6)";
const SUMMARY_SQL:&str="coalesce(sum(tokens),0),coalesce(sum(input),0),coalesce(sum(output),0),coalesce(sum(cache_read),0),coalesce(sum(cache_write),0),coalesce(sum(reasoning),0),sum(estimated_cost),coalesce(sum(CASE WHEN estimated_cost IS NULL THEN tokens ELSE 0 END),0),count(*),count(DISTINCT date),sum(requests)";
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
pub fn report(db: &mut Database, f: &Filter) -> Result<Report> {
    f.validate()?;
    let tx = db.connection.transaction()?;
    let summary = tx.query_row(
        &format!("SELECT {SUMMARY_SQL} FROM effective_usage{WHERE_SQL}"),
        params![f.from, f.to, f.client, f.provider, f.model, f.source],
        |r| read_summary(r, 0),
    )?;
    let rows = {
        let mut stmt=tx.prepare(&format!("SELECT source,batch_id,body FROM effective_usage{WHERE_SQL} ORDER BY date DESC,item_key LIMIT ?7 OFFSET ?8"))?;
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
        clients: grouped(&tx, f, "client")?,
        providers: grouped(&tx, f, "provider")?,
        models: grouped(&tx, f, "model")?,
        details,
    };
    tx.commit()?;
    Ok(result)
}
