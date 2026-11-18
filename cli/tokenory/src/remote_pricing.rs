// [INPUT]: 读取 updates 分支的 pricing.json 和最近一次接受的目录。
// [OUTPUT]: 校验带版本的官方费率，生成可追溯的模型价格条目。
// [POS]: Tokenory 官方费率的网络与持久化边界。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
use crate::pricing::PriceEntry;
use anyhow::{ensure, Context, Result};
use chrono::{DateTime, FixedOffset, Utc};
use rusqlite::{Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::{collections::HashSet, time::Duration};
use tokens_core::pricing::ModelPricing;

const URL: &str = "https://raw.githubusercontent.com/ryekee/tokenory/updates/pricing.json";
const MAX_BYTES: usize = 1024 * 1024;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RemotePolicy {
    pub fast: Option<f64>,
    pub ultrafast: Option<f64>,
    pub long_cache_write: Option<f64>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Feed {
    schema_version: u32,
    pub(crate) revision: u64,
    effective_at: DateTime<FixedOffset>,
    entries: Vec<Entry>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Entry {
    provider: String,
    model: String,
    source: String,
    standard: Rates,
    long_context: Option<Rates>,
    fast: Option<f64>,
    ultrafast: Option<f64>,
    ultrafast_change: Option<SpeedChange>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Rates {
    input: f64,
    output: f64,
    cache_read: Option<f64>,
    cache_write: Option<f64>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SpeedChange {
    effective_at: DateTime<FixedOffset>,
    multiplier: f64,
}

impl Feed {
    pub fn parse(bytes: &[u8]) -> Result<Self> {
        ensure!(bytes.len() <= MAX_BYTES, "price feed exceeds size limit");
        let feed: Self = serde_json::from_slice(bytes)?;
        ensure!(
            feed.schema_version == 1 && feed.revision > 0,
            "unsupported price feed version"
        );
        ensure!(!feed.entries.is_empty(), "price feed is empty");

        let mut seen = HashSet::new();
        for e in &feed.entries {
            let valid_id = |id: &str| {
                !id.is_empty()
                    && id.bytes().all(|b| {
                        b.is_ascii_lowercase() || b.is_ascii_digit() || b"-._".contains(&b)
                    })
            };
            ensure!(
                valid_id(&e.provider)
                    && valid_id(&e.model)
                    && !matches!(e.provider.as_str(), "unknown" | "_session")
                    && e.provider != "deepseek"
                    && !crate::price_catalog::subscription_provider(&e.provider)
                    && !matches!(
                        (e.provider.as_str(), e.model.as_str()),
                        ("openai", "codex-auto-review")
                            | ("devin", "compactor")
                            | ("xiaomi", "mimo-v2-pro")
                    ),
                "invalid official provider or model"
            );
            ensure!(
                seen.insert((&e.provider, &e.model)),
                "duplicate price feed entry"
            );
            ensure!(
                reqwest::Url::parse(&e.source)
                    .is_ok_and(|url| url.scheme() == "https" && url.host_str().is_some()),
                "price feed source must be an HTTPS URL"
            );
            for rates in std::iter::once(&e.standard).chain(&e.long_context) {
                ensure!(
                    rates.input > 0. && rates.output > 0.,
                    "official input and output rates must be positive"
                );
                for rate in [
                    Some(rates.input),
                    Some(rates.output),
                    rates.cache_read,
                    rates.cache_write,
                ]
                .into_iter()
                .flatten()
                {
                    ensure!(rate.is_finite() && rate >= 0., "invalid token rate");
                }
            }
            for factor in [
                e.fast,
                e.ultrafast,
                e.ultrafast_change.as_ref().map(|c| c.multiplier),
            ]
            .into_iter()
            .flatten()
            {
                ensure!(
                    factor.is_finite() && factor > 0.,
                    "invalid speed multiplier"
                );
            }
            ensure!(
                e.ultrafast_change
                    .as_ref()
                    .is_none_or(|c| e.ultrafast.is_some() && c.effective_at > feed.effective_at),
                "invalid Ultrafast price change"
            );
        }
        Ok(feed)
    }

    pub(crate) fn is_effective(&self) -> bool {
        self.effective_at <= Utc::now()
    }

    pub(crate) fn prices(
        &self,
        at: DateTime<FixedOffset>,
    ) -> impl Iterator<Item = PriceEntry> + '_ {
        self.entries.iter().map(move |e| {
            let long = e.long_context.as_ref();
            let per_token = |rate: f64| rate / 1e6;
            let ultrafast = e.ultrafast_change.as_ref().filter(|c| c.effective_at <= at)
                .map(|c| c.multiplier).or(e.ultrafast);
            PriceEntry {
                remote_policy: Some(RemotePolicy { fast: e.fast, ultrafast, long_cache_write: long.and_then(|r| r.cache_write).map(per_token) }),
                schedule: None,
                provider: e.provider.clone(),
                model: e.model.clone(),
                matched_key: e.model.clone(),
                source: e.source.clone(),
                assumption: format!("Official API reference from Tokenory pricing feed revision {}; USD; effective {}", self.revision, self.effective_at),
                explicit_free: false,
                allow_fast: false,
                rates: ModelPricing {
                    input_cost_per_token: Some(per_token(e.standard.input)),
                    output_cost_per_token: Some(per_token(e.standard.output)),
                    cache_read_input_token_cost: e.standard.cache_read.map(per_token),
                    cache_creation_input_token_cost: e.standard.cache_write.map(per_token),
                    input_cost_per_token_above_272k_tokens: long.map(|r| per_token(r.input)),
                    output_cost_per_token_above_272k_tokens: long.map(|r| per_token(r.output)),
                    cache_read_input_token_cost_above_272k_tokens: long.and_then(|r| r.cache_read).map(per_token),
                    ..Default::default()
                },
            }
        })
    }
}

pub(crate) fn cached(db: &Connection) -> Result<Option<Feed>> {
    let raw: Option<String> = db
        .query_row(
            "SELECT value FROM app_state WHERE key='remotePricingFeed'",
            [],
            |row| row.get(0),
        )
        .optional()?;
    raw.map(|data| serde_json::from_str(&data).context("invalid saved remote price feed"))
        .transpose()
}

pub(crate) async fn fetch() -> Result<Feed> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(15))
        .build()?;
    let mut response = client.get(URL).send().await?.error_for_status()?;
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await? {
        ensure!(
            body.len() + chunk.len() <= MAX_BYTES,
            "price feed exceeds size limit"
        );
        body.extend_from_slice(&chunk);
    }
    Feed::parse(&body)
}

/// Overlay an accepted feed, or reuse its saved copy when the network feed is unavailable.
pub fn apply_refresh(
    db: &mut crate::db::Database,
    upstream: &tokens_core::pricing::PricingService,
    fetched: Option<Feed>,
) -> Result<String> {
    let saved = cached(&db.connection)?;
    let newer = fetched.filter(|feed| {
        feed.is_effective()
            && saved
                .as_ref()
                .is_none_or(|old| feed.revision > old.revision)
    });
    let snapshot =
        crate::pricing::snapshot_with_feed(db, upstream, newer.as_ref().or(saved.as_ref()))?;
    crate::pricing::save_snapshot_with_feed(db, snapshot, newer.as_ref())
}
