// [INPUT]: Parsed Hermes usage allocations and previously saved local snapshots.
// [OUTPUT]: Existing estimate totals and archive timezones carried into the new slices.
// [POS]: Ledger reconciliation before the generic snapshot upsert.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
use crate::{
    pricing,
    usage::{Tokens, UsageRecord},
};
use anyhow::{Context, Result};
use rusqlite::Connection;
use std::collections::HashMap;

fn group(record: &UsageRecord) -> Option<&str> {
    record.metadata["hermesUsageGroup"].as_str()
}

pub(super) fn reconcile(connection: &Connection, records: &mut [UsageRecord]) -> Result<()> {
    let mut incoming = HashMap::<String, Vec<&mut UsageRecord>>::new();
    for record in records {
        if let Some(key) = group(record) {
            incoming.entry(key.to_owned()).or_default().push(record);
        }
    }
    if incoming.is_empty() {
        return Ok(());
    }

    let mut prior = HashMap::<String, Vec<UsageRecord>>::new();
    let mut stmt = connection.prepare(
        "SELECT body FROM usage_records WHERE source = 'local' AND batch_id = '' AND client = 'hermes'
         ORDER BY json_extract(body, '$.timestampMs'), item_key",
    )?;
    for body in stmt.query_map([], |row| row.get::<_, String>(0))? {
        let record: UsageRecord = serde_json::from_str(&body?)?;
        let key = group(&record).unwrap_or(&record.key);
        if incoming.contains_key(key) {
            prior.entry(key.to_owned()).or_default().push(record);
        }
    }
    let mut prices = HashMap::new();
    for (key, mut slices) in incoming {
        let Some(old) = prior.remove(&key) else {
            continue;
        };
        let legacy = (old.len() == 1 && group(&old[0]).is_none()).then(|| &old[0]);
        let old_by_time: HashMap<_, _> = old.iter().map(|r| (r.timestamp_ms, r)).collect();
        for slice in &mut slices {
            if let Some(previous) = legacy.or_else(|| old_by_time.get(&slice.timestamp_ms).copied())
            {
                if let (Some(timestamp), Some(zone)) =
                    (slice.timestamp_ms, previous.timezone.as_deref())
                {
                    slice.date = chrono::DateTime::from_timestamp_millis(timestamp)
                        .context("invalid Hermes allocation time")?
                        .with_timezone(&zone.parse::<chrono_tz::Tz>()?)
                        .format("%Y-%m-%d")
                        .to_string();
                    slice.timezone.clone_from(&previous.timezone);
                }
            }
        }
        if old.len() == slices.len()
            && slices.iter().all(|slice| {
                old_by_time
                    .get(&slice.timestamp_ms)
                    .is_some_and(|previous| {
                        slice.key == previous.key && slice.tokens == previous.tokens
                    })
            })
        {
            continue;
        }

        let first = &old[0];
        if slices
            .iter()
            .any(|r| r.provider != first.provider || r.model != first.model)
        {
            continue;
        }
        let Some(mut saved_cost) = old.iter().try_fold(0.0, |cost, row| {
            row.estimated_cost_usd.map(|amount| cost + amount)
        }) else {
            continue;
        };
        let snapshot_id = first.price_snapshot_id.as_ref().filter(|id| {
            old.iter()
                .all(|row| row.price_snapshot_id.as_ref() == Some(*id))
        });
        let previous_totals = totals(old.iter());
        let current_totals = totals(slices.iter().map(|r| &**r));
        let Some(additional) = difference(current_totals, previous_totals) else {
            continue;
        };
        if additional != Tokens::default() {
            let Some(id) = snapshot_id else {
                continue;
            };
            let snapshot = prices
                .entry(id.clone())
                .or_insert_with(|| pricing::load_snapshot(connection, id).ok());
            let Some(snapshot) = snapshot else {
                continue;
            };
            // Cumulative data has no request costs. Keep booked USD, and price
            // only the new tokens using the original group's rate reference.
            let mut new_usage = first.clone();
            new_usage.tokens = additional;
            let Some(new_cost) = pricing::estimate("local", &new_usage, snapshot).cost else {
                continue;
            };
            saved_cost += new_cost;
        }
        if !saved_cost.is_finite() {
            continue;
        }
        let basis = first.cost_basis.as_ref().filter(|basis| {
            snapshot_id.is_some()
                && old
                    .iter()
                    .all(|row| row.cost_basis.as_ref() == Some(*basis))
        });
        let group_tokens = current_totals.iter().sum::<i128>();
        let piece_count = slices.len();
        let mut apportioned_tokens = 0;
        let mut apportioned_usd = 0.0;
        for (index, slice) in slices.into_iter().enumerate() {
            apportioned_tokens += i128::from(slice.tokens.checked_total()?);
            let portion = if index + 1 == piece_count {
                saved_cost
            } else if group_tokens == 0 {
                saved_cost * ((index + 1) as f64 / piece_count as f64)
            } else {
                saved_cost * (apportioned_tokens as f64 / group_tokens as f64)
            };
            slice.estimated_cost_usd = Some(portion - apportioned_usd);
            slice.cost_basis = basis.cloned();
            slice.price_snapshot_id = snapshot_id.cloned();
            apportioned_usd = portion;
        }
    }
    Ok(())
}

fn totals<'a>(records: impl Iterator<Item = &'a UsageRecord>) -> [i128; 5] {
    let mut total = [0; 5];
    for record in records {
        let t = &record.tokens;
        for (sum, amount) in
            total
                .iter_mut()
                .zip([t.input, t.output, t.cache_read, t.cache_write, t.reasoning])
        {
            *sum += i128::from(amount);
        }
    }
    total
}

fn difference(current: [i128; 5], previous: [i128; 5]) -> Option<Tokens> {
    let mut delta = [0; 5];
    for ((amount, latest), old) in delta.iter_mut().zip(current).zip(previous) {
        if latest < old {
            return None;
        }
        *amount = i64::try_from(latest - old).ok()?;
    }
    let [input, output, cache_read, cache_write, reasoning] = delta;
    Some(Tokens {
        input,
        output,
        cache_read,
        cache_write,
        reasoning,
    })
}
