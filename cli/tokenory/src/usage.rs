use anyhow::{bail, ensure, Result};
use chrono::NaiveDate;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Tokens {
    pub input: i64,
    pub output: i64,
    pub cache_read: i64,
    pub cache_write: i64,
    pub reasoning: i64,
}
impl Tokens {
    pub fn checked_total(&self) -> Result<i64> {
        [
            self.input,
            self.output,
            self.cache_read,
            self.cache_write,
            self.reasoning,
        ]
        .into_iter()
        .try_fold(0_i64, |total, value| {
            ensure!(value >= 0, "token counts must be nonnegative integers");
            total
                .checked_add(value)
                .ok_or_else(|| anyhow::anyhow!("token total exceeds supported range"))
        })
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageRecord {
    pub key: String,
    pub client: String,
    pub provider: String,
    pub model: String,
    pub date: String,
    pub timezone: Option<String>,
    pub timestamp_ms: Option<i64>,
    pub session_id: Option<String>,
    pub tokens: Tokens,
    pub requests: Option<i64>,
    pub source_cost_usd: Option<f64>,
    pub estimated_cost_usd: Option<f64>,
    pub cost_basis: Option<String>,
    pub price_snapshot_id: Option<String>,
    #[serde(default)]
    pub metadata: serde_json::Value,
}
impl UsageRecord {
    pub fn validate(&self) -> Result<()> {
        validate_date(&self.date)?;
        ensure!(
            !self.key.is_empty() && !self.client.is_empty() && !self.model.is_empty(),
            "usage identity, client and model are required"
        );
        self.tokens.checked_total()?;
        if let Some(n) = self.requests {
            ensure!(n >= 0, "request count must not be negative");
        }
        for n in [self.source_cost_usd, self.estimated_cost_usd]
            .into_iter()
            .flatten()
        {
            ensure!(
                n.is_finite() && n >= 0.0,
                "cost must be finite and nonnegative"
            );
        }
        if let Some(tz) = &self.timezone {
            tz.parse::<chrono_tz::Tz>()
                .map_err(|_| anyhow::anyhow!("invalid source timezone: {tz}"))?;
        }
        Ok(())
    }
}

pub fn validate_date(value: &str) -> Result<NaiveDate> {
    if value.len() != 10 {
        bail!("date must be YYYY-MM-DD: {value}");
    }
    NaiveDate::parse_from_str(value, "%Y-%m-%d")
        .map_err(|_| anyhow::anyhow!("invalid calendar date: {value}"))
}
