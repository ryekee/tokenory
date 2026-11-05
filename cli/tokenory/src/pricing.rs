use crate::{
    db::{advance_revision, put_record, Database},
    queries::{report, Filter},
    usage::UsageRecord,
};
use anyhow::{ensure, Context, Result};
use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};
use tokens_core::pricing::{lookup::compute_cost, ModelPricing, PricingService};
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PriceEntry {
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
        Self::new([("deepseek-flash",0.3,1.2,0.006),("deepseek-v4-pro",1.32,3.96,0.044)].into_iter().map(|(m,i,o,c)|PriceEntry{provider:"deepseek".into(),model:m.into(),matched_key:m.into(),source:"https://api-docs.deepseek.com/quick_start/pricing/ (verified 2026-11-05)".into(),assumption:"2026-11-05 fixed peak API equivalent; excludes off-peak and holiday discounts; not historical billing".into(),explicit_free:false,allow_fast:false,rates:ModelPricing{input_cost_per_token:Some(i/1e6),output_cost_per_token:Some(o/1e6),cache_read_input_token_cost:Some(c/1e6),..Default::default()}}).collect())
    }
    pub fn validate(&self) -> Result<()> {
        let mut seen = std::collections::HashSet::new();
        for e in &self.entries {
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
    if matches!(speed, Some("fast" | "ultrafast")) && !e.allow_fast {
        return unknown("speed-specific rate not verified");
    }
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
    let rates = if daily {
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
    let cost = compute_cost(
        &rates,
        t.input,
        t.output,
        t.cache_read,
        t.cache_write,
        t.reasoning,
    ) + surcharge;
    if !cost.is_finite() || cost < 0. {
        return unknown("invalid calculated cost");
    }
    if cost == 0. && !e.explicit_free && t.checked_total().unwrap_or(0) > 0 {
        return unknown("zero price has no explicit free-rate confirmation");
    }
    Estimate {
        cost: Some(cost),
        basis: format!(
            "{}; {}; {}",
            e.source,
            e.assumption,
            if daily {
                "daily aggregate at base rates; no request tier reconstruction"
            } else {
                "event usage; upstream context tiers and observed cache TTL"
            }
        ),
        reason: None,
    }
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
    if active_snapshot(&db.connection)?.is_none() {
        save_snapshot(db, PriceSnapshot::deepseek_reference())?;
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
    let mut p = PriceSnapshot::deepseek_reference();
    if let Some((_, old)) = active_snapshot(&db.connection)? {
        for entry in old.entries.into_iter().filter(|e|e.source=="User") {
            p.entries.retain(|e|e.provider!=entry.provider || e.model!=entry.model);
            p.entries.push(entry);
        }
    }
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
            p.entries.push(PriceEntry{provider,model,matched_key:found.matched_key,source:found.source,assumption:"current cached API reference; not historical billing; speed-specific rates unverified".into(),explicit_free:false,allow_fast:false,rates:found.pricing});
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
            let prior = serde_json::to_string(&r)?;
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
