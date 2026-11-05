use crate::{
    config::Config,
    db::{advance_revision, put_record, Database},
    usage::{Tokens, UsageRecord},
};
use anyhow::{anyhow, Context, Result};
use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{
    collections::HashMap,
    fs::File,
    io::{BufRead, BufReader},
    path::PathBuf,
    time::{Instant, SystemTime},
};
#[derive(Default)]
pub struct DiagnosticCache {
    files: HashMap<PathBuf, (u64, SystemTime, Vec<String>)>,
    persistent: bool,
}
impl DiagnosticCache {
    pub fn persistent() -> Self {
        Self {
            persistent: true,
            ..Default::default()
        }
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceStatus {
    pub client: String,
    pub status: String,
    pub files: usize,
    pub records: usize,
    pub errors: Vec<String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScanResult {
    pub started_at: String,
    pub duration_ms: u64,
    pub changed: usize,
    #[serde(default)]
    pub added: usize,
    #[serde(default)]
    pub updated: usize,
    #[serde(default)]
    pub unchanged: usize,
    #[serde(default)]
    pub rejected: Option<usize>,
    pub revision: i64,
    pub sources: Vec<SourceStatus>,
}
pub struct ScanBatch {
    pub records: Vec<UsageRecord>,
    pub result: ScanResult,
}
fn diagnose(config: &Config, client: &str, cache: &mut DiagnosticCache) -> SourceStatus {
    let mut status = SourceStatus {
        client: client.into(),
        status: "ok".into(),
        files: 0,
        records: 0,
        errors: vec![],
    };
    let mut roots_found = 0;
    for root in config.roots(client) {
        if !root.exists() {
            if config
                .extra_scan_paths
                .get(client)
                .is_some_and(|p| p.contains(&root))
            {
                status
                    .errors
                    .push(format!("configured directory missing: {}", root.display()));
            }
            continue;
        }
        roots_found += 1;
        for entry in walkdir::WalkDir::new(&root).follow_links(false) {
            let entry = match entry {
                Ok(v) => v,
                Err(e) => {
                    status.errors.push(e.to_string());
                    continue;
                }
            };
            if !entry.file_type().is_file() || entry.path().extension().is_none_or(|e| e != "jsonl")
            {
                continue;
            }
            status.files += 1;
            let path = entry.path();
            let check = (|| -> Result<Vec<String>> {
                let m = std::fs::metadata(path)?;
                let modified = m.modified()?;
                if let Some((size, time, errors)) = cache.files.get(path) {
                    if *size == m.len() && *time == modified {
                        return Ok(errors.clone());
                    }
                }
                let mut errors = Vec::new();
                for (i, line) in BufReader::new(File::open(path)?).lines().enumerate() {
                    let line = line?;
                    if !line.trim().is_empty()
                        && serde_json::from_str::<serde_json::Value>(&line).is_err()
                    {
                        errors.push(format!(
                            "{}:{} invalid or incomplete JSON",
                            path.display(),
                            i + 1
                        ));
                        if errors.len() == 5 {
                            break;
                        }
                    }
                }
                cache
                    .files
                    .insert(path.into(), (m.len(), modified, errors.clone()));
                Ok(errors)
            })();
            match check {
                Ok(errors) => status.errors.extend(errors),
                Err(e) => status.errors.push(format!("{}: {e}", path.display())),
            }
        }
    }
    if !status.errors.is_empty() {
        status.status = "partial".into();
    } else if roots_found == 0 {
        status.status = "unavailable".into();
    }
    status
}
pub async fn collect_once(config: &Config, cache: &mut DiagnosticCache) -> Result<ScanBatch> {
    config.validate()?;
    let start = Instant::now();
    let started_at = chrono::Utc::now().to_rfc3339();
    let mut sources: Vec<_> = ["claude", "codex"]
        .into_iter()
        .map(|c| diagnose(config, c, cache))
        .collect();
    let clients: Vec<_> = sources
        .iter()
        .filter(|s| s.status == "ok")
        .map(|s| s.client.clone())
        .collect();
    let mut records = Vec::new();
    if !clients.is_empty() {
        let options = tokens_core::LocalParseOptions {
            home_dir: Some(config.home_dir.to_string_lossy().into_owned()),
            use_env_roots: false,
            clients: Some(clients),
            scanner_settings: tokens_core::scanner::ScannerSettings {
                extra_scan_paths: config.extra_scan_paths.clone(),
                bucket_timezone: Some(config.timezone.clone()),
                ..Default::default()
            },
            ..Default::default()
        };
        let messages = if cache.persistent {
            tokens_core::parse_local_unified_messages_with_pricing(options, None).await
        } else {
            tokens_core::parse_local_unified_messages_with_pricing_uncached(options, None).await
        }
        .map_err(|e| anyhow!(e))?;
        let tz = config.timezone.parse::<chrono_tz::Tz>()?;
        for m in messages {
            let converted = (|| -> Result<UsageRecord> {
                let identity = m
                    .dedup_key
                    .as_deref()
                    .filter(|s| !s.is_empty())
                    .context("missing stable usage identity")?;
                let date = chrono::DateTime::from_timestamp_millis(m.timestamp)
                    .context("invalid event timestamp")?
                    .with_timezone(&tz)
                    .format("%Y-%m-%d")
                    .to_string();
                let r = UsageRecord {
                    key: format!("{}:{}:{identity}", m.client, m.provider_id),
                    client: m.client.clone(),
                    provider: m.provider_id.clone(),
                    model: m.model_id.clone(),
                    date,
                    timezone: Some(config.timezone.clone()),
                    timestamp_ms: Some(m.timestamp),
                    session_id: Some(m.session_id.clone()),
                    tokens: Tokens {
                        input: m.tokens.input,
                        output: m.tokens.output,
                        cache_read: m.tokens.cache_read,
                        cache_write: m.tokens.cache_write,
                        reasoning: m.tokens.reasoning,
                    },
                    requests: Some(i64::from(m.message_count)),
                    source_cost_usd: matches!(
                        m.cost_source,
                        tokens_core::sessions::CostSource::ProviderReported
                    )
                    .then_some(m.cost),
                    estimated_cost_usd: None,
                    cost_basis: None,
                    price_snapshot_id: None,
                    metadata: json!({"granularity":"event","parserVersion":"c2f3857c","cacheWrite1h":m.cache_write_1h,"inferenceSpeed":m.inference_speed,"modelAttributionConflicted":m.model_attribution_conflicted}),
                };
                r.validate()?;
                Ok(r)
            })();
            if let Some(s) = sources.iter_mut().find(|s| s.client == m.client) {
                match converted {
                    Ok(r) => {
                        s.records += 1;
                        records.push(r);
                    }
                    Err(e) => {
                        s.status = "partial".into();
                        s.errors.push(e.to_string());
                    }
                }
            }
        }
        // Logs can change while the parser is working. Recheck changed files
        // before accepting a cumulative source snapshot.
        for source in &mut sources {
            let after = diagnose(config, &source.client, cache);
            if after.status == "partial" {
                source.status = after.status;
                source.errors.extend(after.errors);
            }
        }
        // A damaged cumulative log can change later deltas. Preserve that source's
        // entire previous snapshot until the log becomes parseable again.
        records.retain(|r| {
            sources
                .iter()
                .any(|s| s.client == r.client && s.status == "ok")
        });
    }
    Ok(ScanBatch {
        records,
        result: ScanResult {
            started_at,
            duration_ms: start.elapsed().as_millis() as u64,
            changed: 0,
            added: 0,
            updated: 0,
            unchanged: 0,
            rejected: if sources.iter().any(|s| s.status == "partial") {
                None
            } else {
                Some(0)
            },
            revision: 0,
            sources,
        },
    })
}
pub fn persist(db: &mut Database, mut batch: ScanBatch) -> Result<ScanResult> {
    let snapshot = crate::pricing::active_snapshot(&db.connection)?;
    let tx = db.connection.transaction()?;
    for mut record in batch.records {
        let prior:Option<String>=tx.query_row("SELECT body FROM usage_records WHERE source='local' AND batch_id='' AND item_key=?1",[&record.key],|r|r.get(0)).optional()?;
        let is_new = prior.is_none();
        if let Some((id, p)) = &snapshot {
            crate::pricing::assign(&mut record, id, p);
        }
        if let Some(prior) = prior {
            let old: UsageRecord = serde_json::from_str(&prior)?;
            if old.tokens == record.tokens
                && old.model == record.model
                && old.provider == record.provider
                && old.metadata == record.metadata
            {
                record.estimated_cost_usd = old.estimated_cost_usd;
                record.cost_basis = old.cost_basis;
                record.price_snapshot_id = old.price_snapshot_id;
            }
            // A display/timezone preference must not silently move persisted events.
            record.date = old.date;
            record.timezone = old.timezone;
        }
        if put_record(&tx, "local", "", &record)? {
            batch.result.changed += 1;
            if is_new {
                batch.result.added += 1;
            } else {
                batch.result.updated += 1;
            }
        } else {
            batch.result.unchanged += 1;
        }
        tx.execute("INSERT OR IGNORE INTO coverage_choices(date,client,source,batch_id) VALUES (?1,?2,'local','')",params![record.date,record.client])?;
    }
    batch.result.revision = if batch.result.changed > 0 {
        advance_revision(&tx)?
    } else {
        crate::db::revision(&tx)?
    };
    tx.execute(
        "INSERT INTO scan_runs(started_at,body) VALUES (?1,?2)",
        params![
            batch.result.started_at,
            serde_json::to_string(&batch.result)?
        ],
    )?;
    // Scan diagnostics are operational state, not usage history.
    tx.execute("DELETE FROM scan_runs WHERE id NOT IN (SELECT id FROM scan_runs ORDER BY id DESC LIMIT 100)",[])?;
    tx.commit()?;
    Ok(batch.result)
}
