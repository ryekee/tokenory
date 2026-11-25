// [INPUT]: Validated filters, the effective ledger view, and local Codex/Antigravity title indexes including Insiders.
// [OUTPUT]: Effective usage reports with tool/model breakdowns, Fast and Codex subagent subsets, archived day totals, searchable conversations, and system-local hourly activity.
// [POS]: Read-only aggregation boundary; never aggregate paginated details.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
use crate::{
    config::Config,
    db::{revision, Database},
    usage::{validate_date, Tokens, UsageRecord},
};
use anyhow::{ensure, Result};
use chrono::{DateTime, SecondsFormat, TimeZone, Timelike};
use rusqlite::functions::FunctionFlags;
use rusqlite::{params_from_iter, types::Null, Connection, Row, ToSql};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashMap},
    fs::File,
    io::{BufRead, BufReader},
    path::Path,
};
use tokens_core::sessions::codex::thread_id_from_rollout_path;

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase", deny_unknown_fields)]
pub struct Filter {
    pub from: Option<String>,
    pub to: Option<String>,
    pub client: Option<String>,
    pub provider: Option<String>,
    pub model: Option<String>,
    pub source: Option<String>,
    pub timestamp_from_ms: Option<i64>,
    pub timestamp_to_ms: Option<i64>,
    pub conversation: Option<ConversationId>,
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
        match (self.timestamp_from_ms, self.timestamp_to_ms) {
            (Some(from), Some(to)) => ensure!(from < to && self.from.is_some() && self.to.is_some(), "timestamp range needs ordered bounds and fallback dates"),
            (None, None) => {},
            _ => anyhow::bail!("both timestamp bounds are required"),
        }
        if let Some(n) = self.limit {
            ensure!((1..=500).contains(&n), "detail limit must be 1–500");
        }
        if let Some(conversation) = &self.conversation {
            ensure!(!conversation.client.is_empty() && !conversation.session_id.is_empty(), "conversation requires a client and session ID");
        }
        Ok(())
    }

    pub(crate) fn sql_parameters(&self) -> [&dyn ToSql; 10] {
        let (client, session): (&dyn ToSql, &dyn ToSql) = match &self.conversation {
            Some(id) => (&id.client, &id.session_id),
            None => (&Null, &Null),
        };
        [
            &self.from, &self.to, &self.client, &self.provider, &self.model, &self.source,
            &self.timestamp_from_ms, &self.timestamp_to_ms, client, session,
        ]
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ConversationId {
    pub client: String,
    pub session_id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ConversationQuery {
    pub filter: Filter,
    pub search: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConversationOption {
    pub id: ConversationId,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    pub last_date: String,
    pub model: Option<String>,
    pub last_timestamp_ms: Option<i64>,
}

#[derive(Deserialize)]
struct IndexedCodexTitle {
    id: String,
    thread_name: String,
}

pub(crate) fn codex_titles(home: &Path) -> HashMap<String, String> {
    let Ok(index) = File::open(home.join(".codex/session_index.jsonl")) else {
        return HashMap::new();
    };
    // Codex appends new entries on rename. Keep the last readable title per thread.
    BufReader::new(index)
        .split(b'\n')
        .map_while(std::result::Result::ok)
        .filter_map(|line| serde_json::from_slice::<IndexedCodexTitle>(&line).ok())
        .filter_map(|entry| {
            let title = entry.thread_name.split_whitespace().collect::<Vec<_>>().join(" ");
            (!title.is_empty() && !entry.id.is_empty()).then_some((entry.id, title))
        })
        .collect()
}

pub(crate) fn codex_title<'a>(titles: &'a HashMap<String, String>, session_id: &str) -> Option<&'a String> {
    titles.get(session_id).or_else(|| {
        let thread = thread_id_from_rollout_path(Path::new(session_id))?;
        titles.get(&thread)
    })
}

pub(crate) fn antigravity_titles(home: &Path, client: &str) -> HashMap<String, String> {
    let candidates: &[&str] = match client {
        "antigravity" => &tokens_core::scanner::ANTIGRAVITY_APP_DIRECTORIES,
        "antigravity-cli" => &["antigravity-cli"],
        _ => return HashMap::new(),
    };
    let mut titles = HashMap::new();
    for app in candidates {
        let path = home
            .join(".gemini")
            .join(app)
            .join("conversation_summaries.db");
        let Ok(conn) =
            Connection::open_with_flags(&path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
        else {
            continue;
        };
        let Ok(mut stmt) = conn.prepare(
            "SELECT conversation_id, title FROM conversation_summaries WHERE title != ''",
        ) else {
            continue;
        };
        let Ok(rows) = stmt.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        }) else {
            continue;
        };
        for row in rows.flatten() {
            let title = row.1.split_whitespace().collect::<Vec<_>>().join(" ");
            if !row.0.is_empty() && !title.is_empty() {
                titles.entry(row.0).or_insert(title);
            }
        }
    }
    titles
}

pub(crate) fn conversation_title(home: &Path, id: &ConversationId) -> Option<String> {
    match id.client.as_str() {
        "codex" => codex_title(&codex_titles(home), &id.session_id).cloned(),
        "antigravity" | "antigravity-cli" => {
            antigravity_titles(home, &id.client).remove(&id.session_id)
        }
        _ => None,
    }
}

pub fn conversations(
    db: &Database,
    home: &Path,
    mut query: ConversationQuery,
) -> Result<Vec<ConversationOption>> {
    // Show alternatives to the selected conversation across all result pages.
    query.filter.conversation = None;
    query.filter.validate()?;
    let search = query.search.trim();
    let title_search = search.to_lowercase();
    let filter_client = query.filter.client.as_deref();
    let codex_map = if matches!(filter_client, None | Some("codex")) {
        codex_titles(home)
    } else {
        HashMap::new()
    };
    let agy_map = if matches!(filter_client, None | Some("antigravity")) {
        antigravity_titles(home, "antigravity")
    } else {
        HashMap::new()
    };
    let agy_cli_map = if matches!(filter_client, None | Some("antigravity-cli")) {
        antigravity_titles(home, "antigravity-cli")
    } else {
        HashMap::new()
    };
    let sql = format!(
        "SELECT client, {SESSION_SQL} AS session, max(date),
            CASE WHEN min(model) = max(model) THEN min(model) END,
            max(json_extract(body, '$.timestampMs')) AS last_timestamp,
            ?11 = '' OR instr(lower({SESSION_SQL}), lower(?11)) > 0
                OR instr(lower(client), lower(?11)) > 0
                OR max(instr(lower(model), lower(?11))) > 0 AS matches_search
        FROM effective_usage{WHERE_SQL}
        AND {SESSION_SQL} != ''
        GROUP BY client, session
        ORDER BY max(date) DESC, last_timestamp DESC, client, session"
    );
    let mut stmt = db.connection.prepare(&sql)?;
    let params = query.filter.sql_parameters().into_iter().chain([&search as &dyn ToSql]);
    let mut rows = stmt.query(params_from_iter(params))?;
    let mut options = Vec::new();
    while let Some(row) = rows.next()? {
        let id = ConversationId {
            client: row.get(0)?,
            session_id: row.get(1)?,
        };
        let title = match id.client.as_str() {
            "codex" => codex_title(&codex_map, &id.session_id),
            "antigravity" => agy_map.get(&id.session_id),
            "antigravity-cli" => agy_cli_map.get(&id.session_id),
            _ => None,
        };
        if !row.get::<_, bool>(5)?
            && !title.is_some_and(|value| value.to_lowercase().contains(&title_search))
        {
            continue;
        }
        options.push(ConversationOption {
            id,
            title: title.cloned(),
            last_date: row.get(2)?,
            model: row.get(3)?,
            last_timestamp_ms: row.get(4)?,
        });
        if options.len() == 100 {
            break;
        }
    }
    Ok(options)
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Summary {
    pub tokens: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fast_tokens: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fast_estimated_cost_usd: Option<f64>,
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

#[derive(Serialize)]
pub struct DailySourceUsage {
    pub date: String,
    pub client: String,
    pub source: String,
    pub tokens: i64,
}

pub fn daily_source_usage(db: &Database) -> Result<Vec<DailySourceUsage>> {
    let mut stmt = db.connection.prepare(
        "SELECT date, client, source, SUM(tokens) FROM effective_usage
         GROUP BY date, client, source ORDER BY date, client, source",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok(DailySourceUsage {
            date: row.get(0)?,
            client: row.get(1)?,
            source: row.get(2)?,
            tokens: row.get(3)?,
        })
    })?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub client_models: Option<BTreeMap<String, Vec<Group>>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codex_subagents: Option<crate::codex_subagents::Report>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub antigravity_subagents: Option<crate::codex_subagents::Report>,
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
        .query_map(params_from_iter(f.sql_parameters()), |r| {
            Ok(ModelDay { date: r.get(0)?, client: r.get(1)?, model: r.get(2)?, summary: read_summary(r, 3)? })
        })?.collect::<rusqlite::Result<Vec<_>>>()?;
    let hourly = hourly_aggregate(&tx, f, false)?;
    let result = ActivityReport { revision: revision(&tx)?, from: from.into(), to: to.into(), daily, model_days, hourly };
    tx.commit()?;
    Ok(result)
}
pub(crate) const SESSION_SQL: &str = "json_extract(body, '$.sessionId')";
pub(crate) const WHERE_SQL:&str=" WHERE (CASE WHEN ?7 IS NOT NULL AND json_extract(body,'$.timestampMs') IS NOT NULL AND coalesce(json_extract(body,'$.metadata.granularity')!='day',1) THEN json_extract(body,'$.timestampMs')>=?7 AND json_extract(body,'$.timestampMs')<?8 ELSE (?1 IS NULL OR date>=?1) AND (?2 IS NULL OR date<=?2) END) AND (?3 IS NULL OR client=?3) AND (?4 IS NULL OR provider=?4) AND (?5 IS NULL OR model=?5) AND (?6 IS NULL OR source=?6) AND (?9 IS NULL OR client=?9 AND json_extract(body, '$.sessionId')=?10)";
pub(crate) const SUMMARY_SQL:&str="coalesce(sum(tokens),0),coalesce(sum(input),0),coalesce(sum(output),0),coalesce(sum(cache_read),0),coalesce(sum(cache_write),0),coalesce(sum(reasoning),0),sum(estimated_cost),coalesce(sum(CASE WHEN estimated_cost IS NULL THEN tokens ELSE 0 END),0),count(*),count(DISTINCT CASE WHEN tokens>0 THEN date END),sum(requests),count(DISTINCT CASE WHEN json_extract(body, '$.metadata.partialDay')=1 THEN date END),
    sum(CASE WHEN json_extract(body, '$.metadata.inferenceSpeed.speed')='fast'
        AND json_extract(body, '$.metadata.inferenceSpeed.source') IN ('selected', 'reported')
        THEN tokens END),
    sum(CASE WHEN json_extract(body, '$.metadata.inferenceSpeed.speed')='fast'
        AND json_extract(body, '$.metadata.inferenceSpeed.source') IN ('selected', 'reported')
        THEN estimated_cost END)";
pub(crate) fn read_summary(row: &Row<'_>, start: usize) -> rusqlite::Result<Summary> {
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
        fast_tokens: row.get(start + 12)?,
        fast_estimated_cost_usd: row.get(start + 13)?,
    })
}
fn grouped(c: &Connection, f: &Filter, column: &str) -> Result<Vec<Group>> {
    // Column is a private, fixed call-site choice, never interpolated user input.
    let sql=format!("SELECT {column},{SUMMARY_SQL} FROM effective_usage{WHERE_SQL} GROUP BY {column} ORDER BY {}",if column=="date" {"date ASC"}else{"sum(tokens) DESC"});
    Ok(c.prepare(&sql)?
        .query_map(
            params_from_iter(f.sql_parameters()),
            |r| {
                Ok(Group {
                    key: r.get(0)?,
                    summary: read_summary(r, 1)?,
                })
            },
        )?
        .collect::<rusqlite::Result<_>>()?)
}

fn models_by_client(c: &Connection, f: &Filter) -> Result<BTreeMap<String, Vec<Group>>> {
    let sql = format!(
        "SELECT client,model,{SUMMARY_SQL} FROM effective_usage{WHERE_SQL}
         GROUP BY client,model ORDER BY client,sum(tokens) DESC,model"
    );
    let mut statement = c.prepare(&sql)?;
    let rows = statement.query_map(params_from_iter(f.sql_parameters()), |row| {
        Ok((
            row.get::<_, String>(0)?,
            Group {
                key: row.get(1)?,
                summary: read_summary(row, 2)?,
            },
        ))
    })?;
    let mut groups = BTreeMap::<String, Vec<Group>>::new();
    for row in rows {
        let (client, model) = row?;
        groups.entry(client).or_default().push(model);
    }
    Ok(groups)
}

fn hourly(c: &Connection, f: &Filter) -> Result<Option<HourlyReport>> {
    if f.timestamp_from_ms.is_some() || f.from.is_none() || f.from != f.to {
        return Ok(None);
    }
    Ok(Some(hourly_aggregate(c, f, true)?))
}
pub(crate) fn reporting_hour_sql(format: &str) -> (String, String) {
    // Imported daily totals cannot be reconstructed as hourly activity. Only
    // timestamps that belong to the selected Beijing reporting day qualify.
    let timestamp = "json_extract(body, '$.timestampMs') / 1000.0";
    let timed = format!("coalesce(json_extract(body, '$.metadata.granularity') NOT IN ('day', 'sourceRecord'), 1) AND coalesce(strftime('%Y-%m-%d', {timestamp}, 'unixepoch', '+8 hours') = date, 0)");
    (timed, format!("strftime('{format}', {timestamp}, 'unixepoch', '+8 hours')"))
}
pub(crate) fn register_local_hour(c: &Connection) -> Result<()> {
    c.create_scalar_function(
        "local_usage_hour",
        4,
        FunctionFlags::SQLITE_DETERMINISTIC,
        |ctx| {
            let Some(instant) = ctx
                .get::<Option<i64>>(0)?
                .and_then(DateTime::from_timestamp_millis)
            else {
                return Ok(None);
            };
            let zone = ctx.get_or_create_aux(1, |value| {
                value.as_str()?.parse::<chrono_tz::Tz>().map_err(anyhow::Error::msg)
            })?;
            let local = instant.with_timezone(&*zone);
            let day = local.date_naive();
            if day.format("%Y-%m-%d").to_string() != ctx.get::<String>(2)? {
                return Ok(None);
            }
            if !ctx.get::<bool>(3)? {
                return Ok(Some(format!("{:02}", local.hour())));
            }
            // Anchor the chart's hours at local midnight, including short or long DST days.
            let midnight = day.and_time(chrono::NaiveTime::MIN);
            let start = zone
                .from_local_datetime(&midnight)
                .earliest()
                .or_else(|| chrono_tz::GapInfo::new(&midnight, &zone)?.end);
            Ok(start.and_then(|start| {
                let elapsed_hours = (instant.timestamp() - start.timestamp()) / 3600;
                let bucket = start.checked_add_signed(chrono::TimeDelta::hours(elapsed_hours))?;
                Some(bucket.to_rfc3339_opts(SecondsFormat::Secs, false))
            }))
        },
    )?;
    Ok(())
}

fn hourly_aggregate(c: &Connection, f: &Filter, include_day: bool) -> Result<HourlyReport> {
    let zone = Config::system_timezone().name();
    let params = f.sql_parameters().into_iter().chain([&zone as &dyn ToSql, &include_day]);
    let key = "CASE WHEN coalesce(json_extract(body,'$.metadata.granularity') NOT IN ('day','sourceRecord'),1)
               THEN local_usage_hour(json_extract(body,'$.timestampMs'),?11,date,?12) END";
    let order = if include_day { "julianday(hour)" } else { "hour" };
    let mut stmt = c.prepare(&format!(
        "SELECT {key} AS hour, {SUMMARY_SQL} FROM effective_usage{WHERE_SQL} GROUP BY hour ORDER BY {order}"
    ))?;
    let mut rows = stmt.query(params_from_iter(params))?;
    let mut buckets = Vec::new();
    let mut unallocated = Summary { cost_status: "empty".into(), ..Default::default() };
    while let Some(row) = rows.next()? {
        let summary = read_summary(row, 1)?;
        if let Some(key) = row.get(0)? {
            buckets.push(Group { key, summary });
        } else {
            unallocated = summary;
        }
    }
    Ok(HourlyReport { buckets, unallocated })
}
pub fn report(db: &mut Database, f: &Filter) -> Result<Report> {
    usage_report(db, f, None)
}

pub fn overview(db: &mut Database, f: &Filter, home: &Path) -> Result<Report> {
    let mut report = usage_report(db, f, Some(home))?;
    if let Some(subagents) = &mut report.codex_subagents {
        crate::codex_subagents::add_titles(subagents, home);
    }
    Ok(report)
}

fn usage_report(db: &mut Database, f: &Filter, overview_home: Option<&Path>) -> Result<Report> {
    let include_overview_fields = overview_home.is_some();
    f.validate()?;
    let tx = db.connection.transaction()?;
    let summary = tx.query_row(
        &format!("SELECT {SUMMARY_SQL} FROM effective_usage{WHERE_SQL}"),
        params_from_iter(f.sql_parameters()),
        |r| read_summary(r, 0),
    )?;
    let rows = {
        let mut stmt=tx.prepare(&format!("SELECT source,batch_id,body FROM effective_usage{WHERE_SQL} ORDER BY date DESC,client,source,batch_id,item_key LIMIT ?11 OFFSET ?12"))?;
        let limit = f.limit.unwrap_or(200);
        let params = f.sql_parameters().into_iter().chain([&limit as &dyn ToSql, &f.offset]);
        let rows = stmt
            .query_map(
                params_from_iter(params),
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
        client_models: if include_overview_fields {
            Some(models_by_client(&tx, f)?)
        } else {
            None
        },
        codex_subagents: if include_overview_fields {
            crate::codex_subagents::query(&tx, f)?
        } else {
            None
        },
        antigravity_subagents: if let Some(home) = overview_home {
            crate::antigravity_subagents::query(&tx, f, home)?
        } else {
            None
        },
    };
    tx.commit()?;
    Ok(result)
}
