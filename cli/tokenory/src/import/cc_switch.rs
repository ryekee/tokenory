use crate::usage::{Tokens, UsageRecord};
use anyhow::{ensure, Context, Result};
use serde::Deserialize;

#[derive(Deserialize)]
struct Rollup {
    date: String,
    app_type: String,
    provider_id: String,
    model: String,
    #[serde(default)]
    request_model: String,
    #[serde(default)]
    pricing_model: String,
    request_count: i64,
    input_tokens: i64,
    output_tokens: i64,
    cache_read_tokens: i64,
    cache_creation_tokens: i64,
    total_cost_usd: serde_json::Value,
    input_token_semantics: i64,
}
pub fn parse(bytes: &[u8], timezone: Option<String>) -> Result<Vec<UsageRecord>> {
    let rows: Vec<Rollup> =
        serde_json::from_slice(bytes).context("invalid CC Switch rollup JSON")?;
    let mut seen = std::collections::HashSet::new();
    rows.into_iter().enumerate().map(|(i,r)| {
        ensure!(r.app_type == "claude", "row {}: this importer accepts verified Claude rollups only", i+1);
        ensure!(matches!(r.input_token_semantics,0|2), "row {}: unknown input token semantics",i+1);
        let cost = match &r.total_cost_usd {
            serde_json::Value::String(s) => s.parse::<f64>().context("invalid source cost")?,
            n => n.as_f64().ok_or_else(|| anyhow::anyhow!("invalid source cost"))?,
        };
        let key = serde_json::to_string(&(&r.date,&r.app_type,&r.provider_id,&r.model,&r.request_model,&r.pricing_model))?;
        ensure!(seen.insert(key.clone()), "row {}: duplicate source key", i+1);
        let record = UsageRecord {
            key, client:r.app_type, provider:r.provider_id, model:r.model, date:r.date,
            timezone:timezone.clone(), timestamp_ms:None, session_id:None,
            tokens:Tokens {input:r.input_tokens,output:r.output_tokens,cache_read:r.cache_read_tokens,cache_write:r.cache_creation_tokens,reasoning:0},
            requests:Some(r.request_count), source_cost_usd:Some(cost), estimated_cost_usd:None,
            cost_basis:None,price_snapshot_id:None,
            metadata:serde_json::json!({"requestModel":r.request_model,"pricingModel":r.pricing_model,"inputTokenSemantics":r.input_token_semantics,"granularity":"day"}),
        };
        record.validate().with_context(||format!("CC Switch row {}",i+1))?;
        Ok(record)
    }).collect()
}
