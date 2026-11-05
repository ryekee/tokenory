use crate::usage::{Tokens, UsageRecord};
use anyhow::{ensure, Context, Result};
use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet};
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Profile {
    stats: Stats,
    model_usage: Vec<ModelTotal>,
    contributions: Vec<Day>,
    updated_at: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Stats {
    total_tokens: i64,
    input_tokens: i64,
    output_tokens: i64,
    cache_read_tokens: i64,
    cache_write_tokens: i64,
    reasoning_tokens: i64,
    active_days: usize,
}
#[derive(Deserialize)]
struct ModelTotal {
    model: String,
    tokens: i64,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Day {
    date: String,
    totals: DayTotals,
    token_breakdown: Tokens,
    clients: Vec<Client>,
}
#[derive(Deserialize)]
struct DayTotals {
    tokens: i64,
}
#[derive(Deserialize)]
struct Client {
    client: String,
    tokens: Tokens,
    models: BTreeMap<String, Cell>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Cell {
    tokens: i64,
    input: i64,
    output: i64,
    cache_read: i64,
    cache_write: i64,
    reasoning: i64,
    cost: Option<f64>,
    messages: Option<i64>,
}
fn add(a: &mut Tokens, b: &Tokens) -> Result<()> {
    a.input = a.input.checked_add(b.input).context("input overflow")?;
    a.output = a.output.checked_add(b.output).context("output overflow")?;
    a.cache_read = a
        .cache_read
        .checked_add(b.cache_read)
        .context("cache read overflow")?;
    a.cache_write = a
        .cache_write
        .checked_add(b.cache_write)
        .context("cache write overflow")?;
    a.reasoning = a
        .reasoning
        .checked_add(b.reasoning)
        .context("reasoning overflow")?;
    a.checked_total()?;
    Ok(())
}
pub fn parse(bytes: &[u8], timezone: Option<String>) -> Result<Vec<UsageRecord>> {
    let p: Profile = serde_json::from_slice(bytes).context("invalid tokens.ci profile export")?;
    let updated = chrono::DateTime::parse_from_rfc3339(&p.updated_at)
        .context("invalid profile update timestamp")?
        .with_timezone(&chrono::Utc)
        .format("%Y-%m-%d")
        .to_string();
    let mut records = Vec::new();
    let mut total = Tokens::default();
    let mut models = BTreeMap::<String, i64>::new();
    let mut dates = BTreeSet::new();
    let mut keys = BTreeSet::new();
    for day in p.contributions {
        crate::usage::validate_date(&day.date)?;
        ensure!(dates.insert(day.date.clone()), "duplicate profile date");
        let mut day_sum = Tokens::default();
        for client in day.clients {
            let mut client_sum = Tokens::default();
            ensure!(
                !client.models.is_empty(),
                "missing per-model usage in {} {}",
                day.date,
                client.client
            );
            for (model, cell) in client.models {
                let tokens = Tokens {
                    input: cell.input,
                    output: cell.output,
                    cache_read: cell.cache_read,
                    cache_write: cell.cache_write,
                    reasoning: cell.reasoning,
                };
                ensure!(
                    tokens.checked_total()? == cell.tokens,
                    "model token categories disagree: {} {} {}",
                    day.date,
                    client.client,
                    model
                );
                let key = serde_json::to_string(&(&day.date, &client.client, &model))?;
                ensure!(keys.insert(key.clone()), "duplicate profile cell");
                add(&mut client_sum, &tokens)?;
                let subtotal = models.entry(model.clone()).or_default();
                *subtotal = subtotal
                    .checked_add(cell.tokens)
                    .context("model total overflow")?;
                let r = UsageRecord {
                    key,
                    client: client.client.clone(),
                    provider: "unknown".into(),
                    model,
                    date: day.date.clone(),
                    timezone: timezone.clone(),
                    timestamp_ms: None,
                    session_id: None,
                    tokens,
                    requests: cell.messages,
                    source_cost_usd: cell.cost,
                    estimated_cost_usd: None,
                    cost_basis: None,
                    price_snapshot_id: None,
                    metadata: serde_json::json!({"granularity":"day","snapshotUpdatedAt":p.updated_at,"partialDay":day.date>=updated,"providerEvidence":"not present in export"}),
                };
                r.validate()?;
                records.push(r);
            }
            ensure!(
                client_sum == client.tokens,
                "client token categories disagree: {} {}",
                day.date,
                client.client
            );
            add(&mut day_sum, &client_sum)?;
        }
        ensure!(
            day_sum == day.token_breakdown && day_sum.checked_total()? == day.totals.tokens,
            "daily token totals disagree: {}",
            day.date
        );
        add(&mut total, &day_sum)?;
    }
    let stats = Tokens {
        input: p.stats.input_tokens,
        output: p.stats.output_tokens,
        cache_read: p.stats.cache_read_tokens,
        cache_write: p.stats.cache_write_tokens,
        reasoning: p.stats.reasoning_tokens,
    };
    ensure!(
        stats == total && total.checked_total()? == p.stats.total_tokens,
        "profile summary does not match daily cells"
    );
    ensure!(
        dates.len() == p.stats.active_days,
        "profile active day count does not match daily cells"
    );
    let mut model_totals = BTreeMap::new();
    for m in p.model_usage {
        ensure!(
            model_totals.insert(m.model, m.tokens).is_none(),
            "duplicate profile model total"
        );
    }
    model_totals.retain(|_, tokens| *tokens != 0);
    models.retain(|_, tokens| *tokens != 0);
    ensure!(
        model_totals == models,
        "profile model totals do not match daily cells"
    );
    Ok(records)
}
