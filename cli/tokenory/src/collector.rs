// [INPUT]: 读取各客户端日志和当前价格快照。
// [OUTPUT]: 全量或变更 Codex/Antigravity 文件增量采集，生成规范化用量、完成回合、Codex 代理活动与诊断。
// [POS]: 采集与账本边界；按请求迁移 Antigravity / Devin 旧行，保留历史计价依据。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
use crate::{
    clients::{source_paths, CLIENTS},
    config::Config,
    db::{advance_revision, put_record, Database},
    usage::{Tokens, UsageRecord},
};
use anyhow::{anyhow, Context, Result};
use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{
    collections::{HashMap, HashSet},
    fs::File,
    io::{BufRead, BufReader},
    path::{Path, PathBuf},
    time::{Instant, SystemTime},
};
#[derive(Default)]
pub struct DiagnosticCache {
    files: HashMap<PathBuf, (u64, SystemTime, Vec<String>)>,
    persistent: bool,
    turns: crate::codex_turns::Cache,
    codex_activity: crate::codex_subagents::Cache,
    other_turns: crate::turn_analytics::Cache,
}
impl DiagnosticCache {
    pub fn recent_files(&self) -> Vec<PathBuf> {
        self.files
            .iter()
            .filter(|(_, (_, modified, _))| modified.elapsed().unwrap_or_default().as_secs() < 120)
            .map(|(path, _)| path.clone())
            .collect()
    }
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
    pub removed: usize,
    #[serde(default)]
    pub rejected: Option<usize>,
    pub revision: i64,
    pub sources: Vec<SourceStatus>,
}
pub struct ScanBatch {
    pub records: Vec<UsageRecord>,
    prior_keys: HashMap<String, String>,
    pub codex_turns: Vec<crate::codex_turns::CodexTurn>,
    codex_activity: Vec<crate::codex_subagents::ThreadActivity>,
    pub invalidated_turn_ids: Vec<String>,
    pub timezone: String,
    pub result: ScanResult,
}
fn diagnose(
    config: &Config,
    client: tokens_core::ClientId,
    paths: &[PathBuf],
    cache: &mut DiagnosticCache,
) -> SourceStatus {
    let mut status = SourceStatus {
        client: client.as_str().into(),
        status: if paths.is_empty() {
            "unavailable"
        } else {
            "ok"
        }
        .into(),
        files: paths.len(),
        records: 0,
        errors: vec![],
    };
    if let Some(extra) = config.extra_scan_paths.get(client.as_str()) {
        for root in extra {
            if let Err(e) = std::fs::read_dir(root) {
                status
                    .errors
                    .push(format!("configured directory {}: {e}", root.display()));
            }
        }
    }
    for path in paths {
        match diagnose_file(path, cache) {
            Ok(errors) => status.errors.extend(errors),
            Err(e) => status.errors.push(format!("{}: {e}", path.display())),
        }
    }
    if !status.errors.is_empty() {
        status.status = "partial".into();
    }
    status
}

fn diagnose_file(path: &Path, cache: &mut DiagnosticCache) -> Result<Vec<String>> {
    let extension = path.extension().and_then(|e| e.to_str()).unwrap_or("");
    if matches!(extension, "db" | "sqlite" | "sqlite3") {
        // WAL content can change while the main file's mtime stays fixed.
        let db = rusqlite::Connection::open_with_flags(
            path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
        )?;
        db.query_row("PRAGMA schema_version", [], |row| row.get::<_, i64>(0))?;
        if let Ok(m) = std::fs::metadata(path) {
            let mut size = m.len();
            let mut modified = m.modified().unwrap_or(SystemTime::UNIX_EPOCH);
            if let Ok(wal) = std::fs::metadata(format!("{}-wal", path.display())) {
                size = size.saturating_add(wal.len());
                if let Ok(wal_mod) = wal.modified() {
                    if wal_mod > modified {
                        modified = wal_mod;
                    }
                }
            }
            cache.files.insert(path.into(), (size, modified, vec![]));
        }
        return Ok(vec![]);
    }
    let m = std::fs::metadata(path)?;
    let modified = m.modified()?;
    if let Some((size, time, errors)) = cache.files.get(path) {
        if *size == m.len() && *time == modified {
            return Ok(errors.clone());
        }
    }
    let file = File::open(path)?;
    let mut errors = Vec::new();
    if matches!(extension, "jsonl" | "ndjson") {
        for (i, line) in BufReader::new(file).lines().enumerate() {
            let line = line?;
            if !line.trim().is_empty() && serde_json::from_str::<serde_json::Value>(&line).is_err()
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
    } else if extension == "json"
        && serde_json::from_reader::<_, serde_json::Value>(BufReader::new(file)).is_err()
    {
        errors.push(format!("{}: invalid or incomplete JSON", path.display()));
    }
    cache
        .files
        .insert(path.into(), (m.len(), modified, errors.clone()));
    Ok(errors)
}
pub async fn collect_once(config: &Config, cache: &mut DiagnosticCache) -> Result<ScanBatch> {
    collect(config, cache, CLIENTS, None).await
}

pub const LIVE_CLIENTS: &[tokens_core::ClientId] = &[
    tokens_core::ClientId::Codex,
    tokens_core::ClientId::Antigravity,
    tokens_core::ClientId::AntigravityCli,
];

pub async fn collect_codex_changes(
    config: &Config,
    cache: &mut DiagnosticCache,
    paths: Option<Vec<PathBuf>>,
) -> Result<ScanBatch> {
    match paths {
        None => collect(config, cache, &[tokens_core::ClientId::Codex], None).await,
        Some(paths) => collect_live_changes(config, cache, Some(paths)).await,
    }
}

pub async fn collect_live_changes(
    config: &Config,
    cache: &mut DiagnosticCache,
    paths: Option<Vec<PathBuf>>,
) -> Result<ScanBatch> {
    let Some(paths) = paths else {
        return collect(config, cache, LIVE_CLIENTS, None).await;
    };
    // Exec captures are superseded by matching rollouts in other files. Keep that
    // cross-file lookup when a capture changes, or it could be charged twice.
    let headless = tokens_core::scanner::headless_roots_with_env_strategy(
        &config.home_dir.to_string_lossy(),
        false,
    );
    let capture_changed = paths.iter().any(|path| {
        let path = path.canonicalize().unwrap_or_else(|_| path.clone());
        headless
            .iter()
            .any(|root| path.starts_with(root.canonicalize().unwrap_or_else(|_| root.clone())))
    });
    if capture_changed {
        return collect(config, cache, LIVE_CLIENTS, None).await;
    }
    let watch = crate::codex_watch::WatchRoots::from_config(config);
    let mut scan = tokens_core::scanner::ScanResult::default();
    let mut selected = Vec::new();
    let mut add_client = |client: tokens_core::ClientId| {
        if !selected.contains(&client) {
            selected.push(client);
        }
    };
    for path in paths {
        match watch.classify_file(&path) {
            Some((tokens_core::ClientId::Codex, target)) => {
                add_client(tokens_core::ClientId::Codex);
                scan.get_mut(tokens_core::ClientId::Codex).push(target);
            }
            Some((tokens_core::ClientId::Antigravity, target)) => {
                add_client(tokens_core::ClientId::Antigravity);
                if target.extension().and_then(|s| s.to_str()) == Some("db") {
                    scan.antigravity_dbs.push(target);
                } else {
                    scan.get_mut(tokens_core::ClientId::Antigravity)
                        .push(target);
                }
            }
            Some((tokens_core::ClientId::AntigravityCli, target)) => {
                add_client(tokens_core::ClientId::AntigravityCli);
                scan.get_mut(tokens_core::ClientId::AntigravityCli)
                    .push(target);
            }
            _ => {
                // Allow direct Codex paths passed by tests outside default watch roots.
                if path.extension().and_then(|s| s.to_str()) == Some("jsonl") {
                    add_client(tokens_core::ClientId::Codex);
                    scan.get_mut(tokens_core::ClientId::Codex).push(path);
                }
            }
        }
    }
    if selected.is_empty() {
        return collect(config, cache, LIVE_CLIENTS, None).await;
    }
    // A legacy notification supplies only the JSONL path. Reconcile the complete
    // selected sources so SQLite keeps its precedence for sessions and response IDs.
    if !scan.get(tokens_core::ClientId::Antigravity).is_empty() {
        return collect(config, cache, &selected, None).await;
    }
    let db_clients: Vec<_> = selected
        .iter()
        .filter(|c| {
            matches!(
                c,
                tokens_core::ClientId::Antigravity | tokens_core::ClientId::AntigravityCli
            )
        })
        .map(|c| c.as_str().to_owned())
        .collect();
    if !db_clients.is_empty() {
        // App, IDE and configured roots may hold fragments of the same session.
        // Discover filenames, then decode only the changed sessions' databases.
        let peers = tokens_core::scanner::scan_all_clients_with_scanner_settings(
            &config.home_dir.to_string_lossy(),
            &db_clients,
            false,
            &tokens_core::scanner::ScannerSettings {
                extra_scan_paths: config.extra_scan_paths.clone(),
                ..Default::default()
            },
        );
        add_session_peers(&mut scan.antigravity_dbs, &peers.antigravity_dbs);
        add_session_peers(
            scan.get_mut(tokens_core::ClientId::AntigravityCli),
            peers.get(tokens_core::ClientId::AntigravityCli),
        );
    }
    scan.antigravity_dbs.sort();
    scan.antigravity_dbs.dedup();
    for &client in &selected {
        let bucket = scan.get_mut(client);
        bucket.sort();
        bucket.dedup();
    }
    collect(config, cache, &selected, Some(scan)).await
}

fn add_session_peers(changed: &mut Vec<PathBuf>, discovered: &[PathBuf]) {
    let sessions: HashSet<_> = changed
        .iter()
        .filter_map(|p| p.file_stem().map(|s| s.to_owned()))
        .collect();
    changed.extend(
        discovered
            .iter()
            .filter(|p| p.file_stem().is_some_and(|s| sessions.contains(s)))
            .cloned(),
    );
}

async fn collect(
    config: &Config,
    cache: &mut DiagnosticCache,
    selected: &[tokens_core::ClientId],
    live_scan: Option<tokens_core::scanner::ScanResult>,
) -> Result<ScanBatch> {
    config.validate()?;
    let start = Instant::now();
    let started_at = chrono::Utc::now().to_rfc3339();
    let clients: Vec<_> = selected.iter().map(|c| c.as_str().to_string()).collect();
    let options = tokens_core::LocalParseOptions {
        home_dir: Some(config.home_dir.to_string_lossy().into_owned()),
        use_env_roots: false,
        clients: Some(clients.clone()),
        scanner_settings: tokens_core::scanner::ScannerSettings {
            extra_scan_paths: config.extra_scan_paths.clone(),
            bucket_timezone: Some(config.timezone.clone()),
            ..Default::default()
        },
        ..Default::default()
    };
    let discover = || {
        if let Some(scan) = &live_scan {
            return scan.clone();
        }
        tokens_core::scanner::scan_all_clients_with_scanner_settings(
            &config.home_dir.to_string_lossy(),
            &clients,
            false,
            &options.scanner_settings,
        )
    };
    let scan = discover();
    let mut sources: Vec<_> = selected
        .iter()
        .map(|c| diagnose(config, *c, &source_paths(&scan, *c), cache))
        .collect();
    let mut codex_turns = Vec::new();
    let mut codex_activity = Vec::new();
    let mut invalidated_turn_ids = Vec::new();
    let mut analytics_errors = Vec::new();
    for path in source_paths(&scan, tokens_core::ClientId::Codex) {
        match cache.codex_activity.read(&path) {
            Ok(Some(activity)) => codex_activity.push(activity),
            Ok(None) => {}
            Err(e) => analytics_errors.push((
                "codex",
                format!("{}: subagent activity: {e}", path.display()),
            )),
        }
        match cache.turns.read(&path) {
            Ok(turns) => codex_turns.extend(turns),
            Err(e) => {
                analytics_errors.push(("codex", format!("{}: turn analytics: {e}", path.display())))
            }
        }
    }
    let mut open_code_sqlite_ids = HashSet::new();
    for &client in crate::turn_analytics::COLLECTED_CLIENTS {
        if !selected.contains(&client) {
            continue;
        }
        for path in source_paths(&scan, client) {
            if client == tokens_core::ClientId::OpenCode
                && !matches!(
                    path.extension().and_then(|s| s.to_str()),
                    Some("db" | "sqlite" | "sqlite3")
                )
            {
                continue;
            }
            match cache.other_turns.read(client.as_str(), &path) {
                Ok(outcome) => {
                    if client == tokens_core::ClientId::OpenCode {
                        open_code_sqlite_ids.extend(outcome.covered_ids);
                    }
                    codex_turns.extend(outcome.turns);
                    invalidated_turn_ids.extend(outcome.invalidated_ids);
                }
                Err(e) => analytics_errors.push((
                    client.as_str(),
                    format!("{}: turn analytics: {e}", path.display()),
                )),
            }
        }
    }
    let open_code_legacy = scan.get(tokens_core::ClientId::OpenCode);
    if !open_code_legacy.is_empty() {
        match crate::turn_analytics::parse_opencode_legacy(open_code_legacy) {
            Ok(outcome) => {
                codex_turns.extend(
                    outcome
                        .turns
                        .into_iter()
                        .filter(|t| !open_code_sqlite_ids.contains(&t.id)),
                );
                invalidated_turn_ids.extend(
                    outcome
                        .invalidated_ids
                        .into_iter()
                        .filter(|id| !open_code_sqlite_ids.contains(id)),
                );
            }
            Err(e) => analytics_errors.push(("opencode", format!("legacy turn analytics: {e}"))),
        }
    }
    let mut records = Vec::new();
    let mut prior_keys = HashMap::new();
    {
        let parsed = tokens_core::parse_scanned_files(
            options.clone(),
            scan,
            clients.clone(),
            cache.persistent,
        )
        .map_err(|e| anyhow!(e))?;
        for (client, error) in parsed.source_errors {
            if let Some(source) = sources.iter_mut().find(|s| s.client == client.as_str()) {
                source.status = "partial".into();
                source.errors.push(error);
            }
        }
        let mut messages = parsed.messages;
        let tz = config.timezone.parse::<chrono_tz::Tz>()?;
        // New adapters also emit session totals or messages without an event ID.
        // Sort their rows to give a repeat scan stable snapshot positions. Their
        // current session is reconciled atomically by persist(), not added again.
        messages.sort_by(|a, b| {
            (
                &a.client,
                &a.session_id,
                a.timestamp,
                &a.model_id,
                &a.provider_id,
                &a.dedup_key,
            )
                .cmp(&(
                    &b.client,
                    &b.session_id,
                    b.timestamp,
                    &b.model_id,
                    &b.provider_id,
                    &b.dedup_key,
                ))
        });
        let mut positions: HashMap<(String, String), usize> = HashMap::new();
        for m in messages {
            let snapshot = !matches!(m.client.as_str(), "claude" | "codex");
            let devin_keys = (m.client == "devin-cli")
                .then(|| tokens_core::sessions::devin::devin_cli_request_keys(&m))
                .flatten();
            let position = positions
                .entry((m.client.clone(), m.session_id.clone()))
                .or_default();
            let index = *position;
            *position += 1;
            let converted = (|| -> Result<UsageRecord> {
                let key = if snapshot {
                    anyhow::ensure!(
                        !m.session_id.is_empty(),
                        "missing session identity for {}",
                        m.client
                    );
                    // Length-delimited JSON avoids collisions between arbitrary
                    // client/session IDs. No tokens or costs enter the identity.
                    let event_key = devin_keys
                        .as_ref()
                        .map(|(key, _)| key.as_str())
                        .or(m.dedup_key.as_deref());
                    let event = event_key.filter(|key| !key.is_empty());
                    match (m.client.as_str(), event) {
                        // RPC and SQLite may name the same request's session differently.
                        ("antigravity", Some(response)) => antigravity_response_key(response),
                        _ => {
                            let identity = match event {
                                Some(key) => json!(["event", key]),
                                None => json!(["position", index]),
                            };
                            format!(
                                "snapshot:{}",
                                serde_json::to_string(&(&m.client, &m.session_id, identity))?
                            )
                        }
                    }
                } else {
                    let identity = m
                        .dedup_key
                        .as_deref()
                        .filter(|s| !s.is_empty())
                        .context("missing stable usage identity")?;
                    format!("{}:{identity}", m.client)
                };
                anyhow::ensure!(m.timestamp > 0, "missing event timestamp for {}", m.client);
                let date = chrono::DateTime::from_timestamp_millis(m.timestamp)
                    .context("invalid event timestamp")?
                    .with_timezone(&tz)
                    .format("%Y-%m-%d")
                    .to_string();
                use tokens_core::sessions::antigravity_cli::SqliteTime;
                let is_event = match m.antigravity_sqlite_time {
                    Some(SqliteTime::Request) => true,
                    Some(SqliteTime::SessionFallback) => false,
                    // RPC usage rows require their own positive request timestamp.
                    None => !snapshot || m.client == "antigravity",
                };
                let r = UsageRecord {
                    key,
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
                    source_cost_usd: (matches!(m.cost_source, tokens_core::sessions::CostSource::ProviderReported)
                        // These upstream parsers supply USD but predate CostSource.
                        // Amp's credits, in particular, must never be treated as USD.
                        || (m.cost > 0.0 && matches!(m.client.as_str(), "trae" | "warp" | "crush" | "mux" | "roocode" | "kilocode" | "cline")))
                        .then_some(m.cost),
                    estimated_cost_usd: None,
                    cost_basis: None,
                    price_snapshot_id: None,
                    metadata: json!({"granularity":if is_event { "event" } else { "sourceRecord" },"parserVersion":"c2f3857c","cacheWrite1h":m.cache_write_1h,"inferenceSpeed":m.inference_speed,"modelAttributionConflicted":m.model_attribution_conflicted}),
                };
                let mut r = r;
                if snapshot {
                    r.metadata["collectionMode"] = "sessionSnapshot".into();
                }
                if m.client == "antigravity" && m.antigravity_sqlite_time.is_some() {
                    r.metadata["antigravitySqlite"] = true.into();
                }
                r.validate()?;
                if let Some((_, row_key)) = &devin_keys {
                    let legacy_key = serde_json::to_string(&(
                        &m.client,
                        &m.session_id,
                        ["event", row_key.as_str()],
                    ))?;
                    prior_keys.insert(r.key.clone(), format!("snapshot:{legacy_key}"));
                }
                Ok(r)
            })();
            if let Some(s) = sources.iter_mut().find(|s| s.client == m.client) {
                match converted {
                    Ok(r) => {
                        if s.status == "unavailable" {
                            s.status = "ok".into();
                        }
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
        let after_scan = discover();
        for (source, client) in sources.iter_mut().zip(selected) {
            let after = diagnose(config, *client, &source_paths(&after_scan, *client), cache);
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
    // Analytics has a narrower schema contract than usage collection. Report
    // its errors after deciding which usage snapshots are safe to reconcile.
    for (client, error) in analytics_errors {
        if let Some(source) = sources.iter_mut().find(|s| s.client == client) {
            source.errors.push(error);
            source.status = "partial".into();
        }
    }
    for source in &mut sources {
        if source.status == "ok" && source.records == 0 {
            source.status = "empty".into();
        }
        source.errors.sort();
        source.errors.dedup();
    }
    Ok(ScanBatch {
        records,
        prior_keys,
        codex_turns,
        codex_activity,
        invalidated_turn_ids,
        timezone: config.timezone.clone(),
        result: ScanResult {
            started_at,
            duration_ms: start.elapsed().as_millis() as u64,
            changed: 0,
            added: 0,
            updated: 0,
            unchanged: 0,
            removed: 0,
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
fn antigravity_response_key(response: &str) -> String {
    format!("antigravity:response:{response}")
}

// v0.1.11 identified every RPC row by client, session and event/position.
// Only named responses can be matched safely across different session IDs.
fn migrated_antigravity_key(key: &str, session: Option<&str>) -> Option<String> {
    let parts = key.strip_prefix("snapshot:")?;
    let (client, saved_session, (kind, response)): (String, String, (String, String)) =
        serde_json::from_str(parts).ok()?;
    (client == "antigravity"
        && Some(saved_session.as_str()) == session
        && kind == "event"
        && !response.is_empty())
    .then(|| antigravity_response_key(&response))
}

pub fn persist(db: &mut Database, mut batch: ScanBatch) -> Result<ScanResult> {
    let snapshot = crate::pricing::active_snapshot(&db.connection)?;
    let tx = db.connection.transaction()?;
    let sessions: HashSet<_> = batch
        .records
        .iter()
        .filter(|r| r.metadata["collectionMode"] == "sessionSnapshot")
        .map(|r| (r.client.clone(), r.session_id.clone()))
        .collect();
    let sqlite_sessions: HashSet<_> = batch
        .records
        .iter()
        .filter(|r| r.metadata["antigravitySqlite"] == true)
        .filter_map(|r| r.session_id.as_deref())
        .collect();
    let has_antigravity = sessions.iter().any(|(client, _)| client == "antigravity");
    let incoming: HashSet<_> = batch.records.iter().map(|r| r.key.as_str()).collect();
    // Only replace sessions successfully read in this scan. Missing files and
    // failed sources keep their saved history, as do every imported batch.
    let obsolete = {
        let mut stmt = tx.prepare("SELECT item_key,client,json_extract(body,'$.sessionId'),coalesce(json_extract(body,'$.metadata.antigravitySqlite'),0) FROM usage_records WHERE source='local' AND batch_id='' AND json_extract(body,'$.metadata.collectionMode')='sessionSnapshot' ORDER BY rowid")?;
        let mut saved = stmt.query([])?;
        let mut obsolete = Vec::new();
        while let Some(row) = saved.next()? {
            let key: String = row.get(0)?;
            if incoming.contains(key.as_str()) {
                continue;
            }
            let client: String = row.get(1)?;
            let session: Option<String> = row.get(2)?;
            if client == "antigravity" {
                if has_antigravity {
                    if let Some(new_key) = migrated_antigravity_key(&key, session.as_deref())
                        .filter(|key| incoming.contains(key.as_str()))
                    {
                        // Read the former row before deletion to inherit its price and timezone.
                        batch
                            .prior_keys
                            .entry(new_key)
                            .or_insert_with(|| key.clone());
                        obsolete.push(key);
                        continue;
                    }
                }
                if row.get::<_, bool>(3)?
                    && !session
                        .as_deref()
                        .is_some_and(|id| sqlite_sessions.contains(id))
                {
                    // A missing or unreadable DB leaves history intact when only RPC is available.
                    continue;
                }
            }
            if sessions.contains(&(client, session)) {
                obsolete.push(key);
            }
        }
        obsolete
    };
    let mut read_prior = tx.prepare_cached(
        "SELECT body FROM usage_records WHERE source='local' AND batch_id='' AND item_key=?1",
    )?;
    for mut record in batch.records {
        let mut prior: Option<String> = read_prior
            .query_row([&record.key], |row| row.get(0))
            .optional()?;
        let is_new = prior.is_none();
        if is_new {
            if let Some(key) = batch.prior_keys.get(&record.key) {
                prior = read_prior.query_row([key], |row| row.get(0)).optional()?;
            }
        }
        if let Some((id, p)) = &snapshot {
            crate::pricing::assign("local", &mut record, id, p);
        }
        if let Some(prior) = prior {
            let mut old: UsageRecord = serde_json::from_str(&prior)?;
            if old.metadata["antigravitySqlite"] == true
                && record.metadata["antigravitySqlite"] != true
            {
                // The primary file disappeared since the last successful scan.
                batch.result.unchanged += 1;
                continue;
            }
            if matches!(record.client.as_str(), "antigravity" | "antigravity-cli") {
                // Refining hourly coverage or identifying the source is not a user-requested
                // historical reprice. Retain the former price if all billing inputs agree.
                old.metadata["granularity"] = record.metadata["granularity"].clone();
                if let Some(source) = record.metadata.get("antigravitySqlite") {
                    old.metadata["antigravitySqlite"] = source.clone();
                }
            }
            if old.tokens == record.tokens
                && old.model == record.model
                && old.provider == record.provider
                && old.metadata == record.metadata
            {
                // 已有金额保持不可变；此前缺价格的记录采用当前首次估算。
                if old.estimated_cost_usd.is_some() || record.estimated_cost_usd.is_none() {
                    record.estimated_cost_usd = old.estimated_cost_usd;
                    record.cost_basis = old.cost_basis;
                    record.price_snapshot_id = old.price_snapshot_id;
                }
            }
            // A display/timezone preference must not silently move persisted events.
            if record.metadata["collectionMode"] == "sessionSnapshot" {
                if let (Some(timestamp), Some(zone)) =
                    (record.timestamp_ms, old.timezone.as_deref())
                {
                    record.date = chrono::DateTime::from_timestamp_millis(timestamp)
                        .context("invalid persisted timestamp")?
                        .with_timezone(&zone.parse::<chrono_tz::Tz>()?)
                        .format("%Y-%m-%d")
                        .to_string();
                }
            } else {
                record.date = old.date;
            }
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
    drop(read_prior);
    // Keep legacy rows available until their replacement has inherited pricing.
    for key in obsolete {
        batch.result.removed += tx.execute(
            "DELETE FROM usage_records WHERE source='local' AND batch_id='' AND item_key=?1",
            [key],
        )?;
    }
    batch.result.changed += batch.result.removed;
    let invalidated: HashSet<_> = batch.invalidated_turn_ids.iter().collect();
    batch
        .codex_turns
        .retain(|turn| !invalidated.contains(&turn.id));
    for id in invalidated {
        batch.result.changed += tx.execute("DELETE FROM codex_turns WHERE id=?1", [id])?;
    }
    batch.result.changed += crate::codex_turns::persist(&tx, &batch.codex_turns, &batch.timezone)?;
    let activity_changed = crate::codex_subagents::persist(&tx, &batch.codex_activity, &batch.timezone)?;
    batch.result.revision = if batch.result.changed > 0 || activity_changed {
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
