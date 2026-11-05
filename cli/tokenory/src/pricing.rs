use crate::{
    db::{advance_revision, put_record, Database},
    queries::{report, Filter},
    usage::UsageRecord,
};
use anyhow::{ensure, Context, Result};
use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};
use tokens_core::pricing::{
    lookup::{compute_cost, compute_cost_for_snapshot},
    ModelPricing, PricingService,
};
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PriceEntry {
    #[serde(default)]
    pub schedule: Option<String>,
    pub provider: String,
    pub model: String,
    pub matched_key: String,
    pub source: String,
    pub assumption: String,
    pub explicit_free: bool,
    pub allow_fast: bool,
    pub rates: ModelPricing,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PriceSnapshot {
    pub created_at: String,
    pub entries: Vec<PriceEntry>,
}
impl PriceSnapshot {
    pub fn new(entries: Vec<PriceEntry>) -> Self {
        Self {
            created_at: chrono::Utc::now().to_rfc3339(),
            entries,
        }
    }
    pub fn deepseek_reference() -> Self {
        Self::new([
            ("deepseek-flash", 0.3, 1.2, 0.006),
            ("deepseek-v4-flash", 0.3, 1.2, 0.006),
            ("deepseek-v4-flash-vision-exp", 0.3, 1.2, 0.006),
            ("deepseek-v4-pro", 1.32, 3.96, 0.044),
        ].into_iter().map(|(model, input, output, cache)| PriceEntry {
            schedule: Some("deepseek-cn-2026-v1".into()),
            provider: "deepseek".into(), model: model.into(), matched_key: model.into(),
            source: "https://api-docs.deepseek.com/quick_start/pricing/".into(),
            assumption: "Official USD rates verified 2026-11-05; Beijing peak/off-peak schedule and 2026 public holidays; current-rate estimate, not historical billing".into(),
            explicit_free: false, allow_fast: false,
            rates: ModelPricing { input_cost_per_token: Some(input / 1e6), output_cost_per_token: Some(output / 1e6), cache_read_input_token_cost: Some(cache / 1e6), ..Default::default() },
        }).collect())
    }
    pub fn official_reference() -> Self {
        let mut p = Self::deepseek_reference();
        // Explicit published model IDs only. Provider matching is done before pricing.
        for (model, input, output, cache) in [
            ("claude-fable-5-1", 10., 50., 0.25),
            ("claude-mythos-5-1", 10., 50., 0.25),
            ("claude-fable-5", 10., 50., 1.),
            ("claude-mythos-5", 10., 50., 1.),
            ("claude-opus-5-5", 4., 20., 0.2),
            ("claude-sonnet-5-5", 2., 10., 0.1),
            ("claude-opus-5", 5., 25., 0.5),
            ("claude-opus-4-8", 5., 25., 0.5),
            ("claude-opus-4-7", 5., 25., 0.5),
            ("claude-opus-4-6", 5., 25., 0.5),
            ("claude-opus-4-5", 5., 25., 0.5),
            ("claude-opus-4-1", 15., 75., 1.5),
            ("claude-opus-4", 15., 75., 1.5),
            ("claude-sonnet-5", 2., 10., 0.2),
            ("claude-sonnet-4-6", 3., 15., 0.3),
            ("claude-sonnet-4-5", 3., 15., 0.3),
            ("claude-sonnet-4", 3., 15., 0.3),
            ("claude-haiku-4-5", 1., 5., 0.1),
            ("claude-haiku-4-5-20251001", 1., 5., 0.1),
            ("claude-3-5-haiku-20241022", 0.8, 4., 0.08),
        ] {
            p.entries.push(PriceEntry { schedule: None, provider: "anthropic".into(), model: model.into(), matched_key: model.into(),
                source: "https://platform.claude.com/docs/en/about-claude/pricing".into(),
                assumption: "Official standard USD API rates verified 2026-11-05; current-rate estimate, not historical billing".into(),
                explicit_free: false, allow_fast: false,
                rates: ModelPricing { input_cost_per_token: Some(input/1e6), output_cost_per_token: Some(output/1e6), cache_read_input_token_cost: Some(cache/1e6), cache_creation_input_token_cost: Some(input*1.25/1e6), ..Default::default() },
            });
        }
        for (model, input, output, cache, tiered) in [
            ("gpt-6-astra", 10., 50., 1., true),
            ("gpt-6.1-sol", 2., 10., 0.1, true),
            ("gpt-6.1-terra", 1., 5., 0.05, true),
            ("gpt-6-luna", 0.1, 0.5, 0.01, true),
            ("gpt-6-sol", 2., 10., 0.2, true),
            ("gpt-5.6-sol", 4., 20., 0.4, true),
            ("gpt-5.6-terra", 2., 12., 0.2, true),
            ("gpt-5.6-luna", 0.2, 1.2, 0.02, true),
            ("gpt-5.5", 5., 30., 0.5, true),
            ("gpt-5.4", 2.5, 15., 0.25, true),
            ("gpt-5.4-mini", 0.75, 4.5, 0.075, false),
            ("gpt-5.3-codex", 1.75, 14., 0.175, false),
            ("gpt-5.2-codex", 1.75, 14., 0.175, false),
            ("gpt-5.1-codex-mini", 0.25, 2., 0.025, false),
        ] {
            p.entries.push(PriceEntry { schedule: None, provider: "openai".into(), model: model.into(), matched_key: model.into(),
                source: "https://developers.openai.com/api/docs/pricing".into(),
                assumption: "Official standard USD API rates verified 2026-11-05; full-request long-context tiers; current-rate estimate, not historical billing".into(),
                explicit_free: false, allow_fast: false,
                rates: ModelPricing { input_cost_per_token: Some(input/1e6), output_cost_per_token: Some(output/1e6), cache_read_input_token_cost: Some(cache/1e6),
                    input_cost_per_token_above_272k_tokens: tiered.then_some(input*2./1e6),
                    output_cost_per_token_above_272k_tokens: tiered.then_some(output*1.5/1e6),
                    cache_read_input_token_cost_above_272k_tokens: tiered.then_some(cache*2./1e6),
                    ..Default::default() },
            });
        }
        p
    }
    pub fn validate(&self) -> Result<()> {
        let mut seen = std::collections::HashSet::new();
        for e in &self.entries {
            ensure!(
                e.schedule.is_none()
                    || (e.schedule.as_deref() == Some("deepseek-cn-2026-v1")
                        && e.provider == "deepseek"),
                "unsupported price schedule"
            );
            ensure!(
                !e.provider.is_empty()
                    && !e.model.is_empty()
                    && !e.source.is_empty()
                    && !e.assumption.is_empty(),
                "price requires provider, model, source and assumption"
            );
            ensure!(
                seen.insert((&e.provider, &e.model)),
                "duplicate model/provider price"
            );
            let value = serde_json::to_value(&e.rates)?;
            for n in value
                .as_object()
                .context("price rates must be an object")?
                .values()
                .filter(|n| !n.is_null())
            {
                let n = n.as_f64().context("price must be a number")?;
                ensure!(
                    n.is_finite() && n >= 0.,
                    "rates must be finite and nonnegative"
                );
                ensure!(
                    !e.explicit_free || n == 0.,
                    "free price must have zero rates"
                );
            }
        }
        Ok(())
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Estimate {
    pub cost: Option<f64>,
    pub basis: String,
    pub reason: Option<String>,
}
pub fn estimate(r: &UsageRecord, p: &PriceSnapshot) -> Estimate {
    let unknown = |reason: &str| Estimate {
        cost: None,
        basis: String::new(),
        reason: Some(reason.into()),
    };
    if r.metadata["modelAttributionConflicted"].as_bool() == Some(true) {
        return unknown("conflicting model identity");
    }
    let Some(e) = p
        .entries
        .iter()
        .find(|e| e.model == r.model && e.provider == r.provider)
    else {
        return unknown("no verified price for this provider/model");
    };
    let speed = r.metadata["inferenceSpeed"]["speed"].as_str();
    let official_openai = e.source == "https://developers.openai.com/api/docs/pricing";
    let official_anthropic = e.source == "https://platform.claude.com/docs/en/about-claude/pricing";
    let speed_factor = match speed {
        Some("fast")
            if official_openai
                && (r.model.starts_with("gpt-6")
                    || r.model.starts_with("gpt-5.6-")
                    || matches!(r.model.as_str(), "gpt-5.3-codex" | "gpt-5.4-mini")) =>
        {
            2.
        }
        Some("fast")
            if official_anthropic
                && matches!(
                    r.model.as_str(),
                    "claude-opus-4-8" | "claude-opus-5" | "claude-opus-5-5"
                ) =>
        {
            2.
        }
        Some("ultrafast")
            if official_openai && matches!(r.model.as_str(), "gpt-6-astra" | "gpt-6.1-sol") =>
        {
            6.
        }
        Some("fast" | "ultrafast") if !e.allow_fast => {
            return unknown("speed-specific rate not verified")
        }
        _ => 1.,
    };
    let t = &r.tokens;
    if !e.explicit_free {
        for (n, rate) in [
            (t.input, e.rates.input_cost_per_token),
            (t.output + t.reasoning, e.rates.output_cost_per_token),
            (t.cache_read, e.rates.cache_read_input_token_cost),
            (t.cache_write, e.rates.cache_creation_input_token_cost),
        ] {
            if n > 0 && rate.is_none() {
                return unknown("a populated token category has no rate");
            }
        }
    }
    let daily = r.timestamp_ms.is_none() || r.metadata["granularity"].as_str() == Some("day");
    // A day aggregate cannot be used as one long-context request.
    let mut rates = if daily {
        ModelPricing {
            input_cost_per_token: e.rates.input_cost_per_token,
            output_cost_per_token: e.rates.output_cost_per_token,
            cache_read_input_token_cost: e.rates.cache_read_input_token_cost,
            cache_creation_input_token_cost: e.rates.cache_creation_input_token_cost,
            ..Default::default()
        }
    } else {
        e.rates.clone()
    };
    let long_context = official_openai
        && !daily
        && t.input + t.cache_read + t.cache_write > 272_000
        && rates.input_cost_per_token_above_272k_tokens.is_some();
    if long_context {
        rates.input_cost_per_token = rates.input_cost_per_token_above_272k_tokens;
        rates.output_cost_per_token = rates.output_cost_per_token_above_272k_tokens;
        rates.cache_read_input_token_cost = rates.cache_read_input_token_cost_above_272k_tokens;
    }
    let ttl = r.metadata["cacheWrite1h"]
        .as_i64()
        .unwrap_or(0)
        .clamp(0, t.cache_write);
    let surcharge = if ttl > 0 {
        let Some(input) = rates.input_cost_per_token else {
            return unknown("1h cache write requires an input rate");
        };
        ttl as f64 * (2. * input - rates.cache_creation_input_token_cost.unwrap_or(0.)).max(0.)
    } else {
        0.
    };
    let (factor, period) = if e.schedule.is_some() {
        match deepseek_factor(r) {
            Ok(value) => value,
            Err(reason) => return unknown(reason),
        }
    } else {
        (1., "fixed rate")
    };
    let cost = (if daily || official_openai {
        compute_cost(
            &rates,
            t.input,
            t.output,
            t.cache_read,
            t.cache_write,
            t.reasoning,
        )
    } else {
        compute_cost_for_snapshot(
            &rates,
            &e.matched_key,
            if e.source == "https://developers.openai.com/api/docs/pricing" {
                "LiteLLM"
            } else {
                &e.source
            },
            Some(&r.provider),
            &tokens_core::TokenBreakdown {
                input: t.input,
                output: t.output,
                cache_read: t.cache_read,
                cache_write: t.cache_write,
                reasoning: t.reasoning,
            },
        )
    } + surcharge)
        * factor
        * speed_factor;
    if !cost.is_finite() || cost < 0. {
        return unknown("invalid calculated cost");
    }
    if cost == 0. && !e.explicit_free && t.checked_total().unwrap_or(0) > 0 {
        return unknown("zero price has no explicit free-rate confirmation");
    }
    Estimate {
        cost: Some(cost),
        basis: format!(
            "{}; {}; {}; speed factor {}; long context {}; {}",
            e.source,
            period,
            e.assumption,
            speed_factor,
            long_context,
            if daily {
                "daily aggregate at base rates; no request tier reconstruction"
            } else {
                "event usage; upstream context tiers and observed cache TTL"
            }
        ),
        reason: None,
    }
}
// Calendar version is part of each immutable snapshot. Weekend makeup workdays
// remain off-peak: the provider explicitly prices every Saturday/Sunday off-peak.
fn deepseek_factor(r: &UsageRecord) -> Result<(f64, &'static str), &'static str> {
    use chrono::{Datelike, Timelike};
    let timestamp = r
        .timestamp_ms
        .filter(|_| r.metadata["granularity"].as_str() != Some("day"));
    let (date, hour) = if let Some(ms) = timestamp {
        let dt = chrono::DateTime::from_timestamp_millis(ms)
            .ok_or("invalid request timestamp")?
            .with_timezone(&chrono_tz::Asia::Shanghai);
        (dt.date_naive(), Some(dt.hour()))
    } else {
        if r.timezone.as_deref() != Some("Asia/Shanghai") {
            return Err("DeepSeek peak/off-peak requires request time or a verified Beijing date");
        }
        (
            crate::usage::validate_date(&r.date).map_err(|_| "invalid request date")?,
            None,
        )
    };
    let weekend = date.weekday().number_from_monday() >= 6;
    let month_day = date.month() * 100 + date.day();
    let holiday = date.year() == 2026
        && matches!(month_day, 101..=103 | 215..=223 | 404..=406 | 501..=505 | 619..=621 | 925..=927 | 1001..=1007);
    if weekend || holiday || hour.is_some_and(|h| !(9..12).contains(&h) && !(14..18).contains(&h)) {
        return Ok((0.5, "off-peak (50%); Asia/Shanghai"));
    }
    if date.year() != 2026 {
        return Err("DeepSeek public holiday calendar unavailable for this year");
    }
    if hour.is_none() {
        return Err("DeepSeek daily aggregate has no peak/off-peak split");
    }
    Ok((1., "peak; Asia/Shanghai"))
}
pub fn save_snapshot(db: &mut Database, p: PriceSnapshot) -> Result<String> {
    p.validate()?;
    let body = serde_json::to_string(&p)?;
    use sha2::{Digest, Sha256};
    let id = format!("{:x}", Sha256::digest(body.as_bytes()));
    let tx = db.connection.transaction()?;
    tx.execute(
        "INSERT OR IGNORE INTO price_snapshots(id,created_at,body) VALUES (?1,?2,?3)",
        params![id, p.created_at, body],
    )?;
    tx.execute("INSERT INTO app_state(key,value) VALUES ('activePrice',?1) ON CONFLICT(key) DO UPDATE SET value=excluded.value",[&id])?;
    tx.commit()?;
    Ok(id)
}
pub fn load_snapshot(db: &rusqlite::Connection, id: &str) -> Result<PriceSnapshot> {
    let body: String = db
        .query_row("SELECT body FROM price_snapshots WHERE id=?1", [id], |r| {
            r.get(0)
        })
        .context("price snapshot not found")?;
    Ok(serde_json::from_str(&body)?)
}
pub fn active_snapshot(c: &rusqlite::Connection) -> Result<Option<(String, PriceSnapshot)>> {
    let id: Option<String> = c
        .query_row(
            "SELECT value FROM app_state WHERE key='activePrice'",
            [],
            |r| r.get(0),
        )
        .optional()?;
    id.map(|id| Ok((id.clone(), load_snapshot(c, &id)?)))
        .transpose()
}
pub fn initialize(db: &mut Database) -> Result<()> {
    const VERSION: &str = "2026-11-05-official-v2";
    let installed: Option<String> = db
        .connection
        .query_row(
            "SELECT value FROM app_state WHERE key='officialCatalog'",
            [],
            |r| r.get(0),
        )
        .optional()?;
    if installed.as_deref() != Some(VERSION) {
        let mut current = active_snapshot(&db.connection)?
            .map(|(_, p)| p)
            .unwrap_or_else(|| PriceSnapshot::new(vec![]));
        let official = PriceSnapshot::official_reference();
        for entry in official.entries {
            current
                .entries
                .retain(|e| e.provider != entry.provider || e.model != entry.model);
            current.entries.push(entry);
        }
        current.created_at = chrono::Utc::now().to_rfc3339();
        save_snapshot(db, current)?;
        db.connection.execute("INSERT INTO app_state(key,value) VALUES ('officialCatalog',?1) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [VERSION])?;
    }
    Ok(())
}
pub fn assign(r: &mut UsageRecord, id: &str, p: &PriceSnapshot) {
    let e = estimate(r, p);
    r.estimated_cost_usd = e.cost;
    r.cost_basis = Some(e.reason.unwrap_or(e.basis));
    r.price_snapshot_id = Some(id.into());
}
pub fn snapshot_from_service(db: &Database, service: &PricingService) -> Result<PriceSnapshot> {
    let mut p = PriceSnapshot::official_reference();
    let rows = {
        let mut stmt=db.connection.prepare("SELECT provider,model,sum(input),sum(output),sum(cache_read),sum(cache_write),sum(reasoning) FROM usage_records GROUP BY provider,model")?;
        let rows = stmt
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    tokens_core::TokenBreakdown {
                        input: r.get(2)?,
                        output: r.get(3)?,
                        cache_read: r.get(4)?,
                        cache_write: r.get(5)?,
                        reasoning: r.get(6)?,
                    },
                ))
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        rows
    };
    for (provider, model, usage) in rows {
        if p.entries
            .iter()
            .any(|e| e.provider == provider && e.model == model)
        {
            continue;
        }
        if !service.covers_usage_with_provider(&model, Some(&provider), &usage) {
            continue;
        }
        if let Some(found) =
            service.resolve_for_usage_with_provider(&model, Some(&provider), &usage)
        {
            p.entries.push(PriceEntry{schedule:None,provider,model,matched_key:found.matched_key,source:found.source,assumption:"current cached API reference; not historical billing; speed-specific rates unverified".into(),explicit_free:false,allow_fast:false,rates:found.pricing});
        }
    }
    p.validate()?;
    Ok(p)
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RepricePreview {
    pub id: String,
    pub snapshot_id: String,
    pub records: usize,
    pub before: Option<f64>,
    pub after: Option<f64>,
    pub unpriced_tokens: i64,
}
#[derive(Serialize, Deserialize)]
struct Change {
    source: String,
    batch: String,
    key: String,
    before: String,
    after: UsageRecord,
}
#[derive(Serialize, Deserialize)]
struct Stored {
    view: RepricePreview,
    changes: Vec<Change>,
}
pub fn preview_reprice(db: &mut Database, filter: &Filter, id: &str) -> Result<RepricePreview> {
    let snapshot = load_snapshot(&db.connection, id)?;
    let mut changes = Vec::new();
    let mut f = filter.clone();
    f.offset = 0;
    f.limit = Some(500);
    let mut before: Option<f64> = None;
    let mut after: Option<f64> = None;
    let mut unpriced = 0;
    loop {
        let rows = report(db, &f)?.details;
        let count = rows.len();
        for detail in rows {
            let mut r = detail.record;
            // Compare the exact stored body at apply time. Re-serializing a parsed
            // floating-point cost can change its last digit without a ledger edit.
            let prior: String = db.connection.query_row(
                "SELECT body FROM effective_usage WHERE source=?1 AND batch_id=?2 AND item_key=?3",
                params![detail.source, detail.batch_id, r.key],
                |row| row.get(0),
            )?;
            if let Some(c) = r.estimated_cost_usd {
                *before.get_or_insert(0.) += c;
            }
            assign(&mut r, id, &snapshot);
            if let Some(c) = r.estimated_cost_usd {
                *after.get_or_insert(0.) += c;
            } else {
                unpriced += r.tokens.checked_total()?;
            }
            changes.push(Change {
                source: detail.source,
                batch: detail.batch_id,
                key: r.key.clone(),
                before: prior,
                after: r,
            });
        }
        if count < 500 {
            break;
        }
        f.offset += 500;
    }
    let mut view = RepricePreview {
        id: String::new(),
        snapshot_id: id.into(),
        records: changes.len(),
        before,
        after,
        unpriced_tokens: unpriced,
    };
    let tx = db.connection.transaction()?;
    tx.execute("INSERT INTO reprice_previews(body) VALUES ('')", [])?;
    view.id = tx.last_insert_rowid().to_string();
    tx.execute(
        "UPDATE reprice_previews SET body=?1 WHERE id=?2",
        params![
            serde_json::to_string(&Stored {
                view: view.clone(),
                changes
            })?,
            view.id
        ],
    )?;
    tx.commit()?;
    Ok(view)
}
pub fn apply_reprice(db: &mut Database, id: &str) -> Result<RepricePreview> {
    let body: String =
        db.connection
            .query_row("SELECT body FROM reprice_previews WHERE id=?1", [id], |r| {
                r.get(0)
            })?;
    let p: Stored = serde_json::from_str(&body)?;
    db.backup_before("reprice")?;
    let tx = db.connection.transaction()?;
    for change in &p.changes {
        let current: Option<String> = tx
            .query_row(
                "SELECT body FROM effective_usage WHERE source=?1 AND batch_id=?2 AND item_key=?3",
                params![change.source, change.batch, change.key],
                |r| r.get(0),
            )
            .optional()?;
        ensure!(
            current.as_deref() == Some(&change.before),
            "usage or source coverage changed after preview; preview again"
        );
    }
    let mut changed = false;
    for c in &p.changes {
        changed |= put_record(&tx, &c.source, &c.batch, &c.after)?;
    }
    if changed {
        advance_revision(&tx)?;
    }
    tx.commit()?;
    Ok(p.view)
}
