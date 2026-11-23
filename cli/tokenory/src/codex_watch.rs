// [INPUT]: Codex live/archived rollouts, Antigravity roots including Insiders, and filesystem notifications.
// [OUTPUT]: Changed log/SQLite paths or a rescan request; no usage estimates.
// [POS]: Live ingestion trigger; periodic scans remain the recovery path.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
use crate::config::Config;
use anyhow::Result;
use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use std::{
    collections::HashMap,
    path::{Path, PathBuf},
    time::SystemTime,
};
use tokio::sync::mpsc::{self, UnboundedReceiver};
use tokens_core::sessions::codex::is_rollout_archive;
use tokens_core::ClientId;

pub enum Change {
    Paths(Vec<PathBuf>),
    Rescan,
}

#[derive(Clone)]
pub(crate) struct WatchRoots {
    codex: Vec<PathBuf>,
    antigravity: Vec<PathBuf>,
    antigravity_cli: Vec<PathBuf>,
}

fn normalized(path: &Path) -> PathBuf {
    if let Ok(path) = path.canonicalize() {
        return path;
    }
    match (path.parent(), path.file_name()) {
        (Some(parent), Some(name)) => normalized(parent).join(name),
        _ => path.into(),
    }
}

/// Map SQLite WAL/SHM/journal sidecar paths back to their main `.db` path.
pub(crate) fn normalize_sqlite_sidecar(path: &Path) -> PathBuf {
    if let Some(name) = path.file_name().and_then(|s| s.to_str()) {
        for suffix in ["-wal", "-shm", "-journal"] {
            if let Some(base) = name.strip_suffix(suffix) {
                if base.ends_with(".db") {
                    return path.with_file_name(base);
                }
            }
        }
    }
    path.to_path_buf()
}

fn is_db_path(path: &Path) -> bool {
    path.extension().and_then(|s| s.to_str()) == Some("db")
}

fn is_jsonl_path(path: &Path) -> bool {
    path.extension().and_then(|s| s.to_str()) == Some("jsonl")
}

impl WatchRoots {
    pub(crate) fn from_config(config: &Config) -> Self {
        let mut codex = vec![
            config.home_dir.join(".codex/sessions"),
            config.home_dir.join(".codex/archived_sessions"),
        ];
        codex.extend(
            config
                .extra_scan_paths
                .get("codex")
                .into_iter()
                .flatten()
                .cloned(),
        );
        codex.extend(
            tokens_core::scanner::headless_roots_with_env_strategy(
                &config.home_dir.to_string_lossy(),
                false,
            )
            .into_iter()
            .map(|root| root.join("codex")),
        );

        let home = config.home_dir.to_string_lossy();
        let mut antigravity = tokens_core::scanner::antigravity_conversation_roots(&home, false);
        antigravity.push(PathBuf::from(
            ClientId::Antigravity
                .data()
                .resolve_path_with_env_strategy(&home, false),
        ));
        antigravity.extend(
            config
                .extra_scan_paths
                .get("antigravity")
                .into_iter()
                .flatten()
                .cloned(),
        );

        let mut antigravity_cli = vec![config.home_dir.join(".gemini/antigravity-cli/conversations")];
        antigravity_cli.extend(
            config
                .extra_scan_paths
                .get("antigravity-cli")
                .into_iter()
                .flatten()
                .cloned(),
        );

        Self {
            codex: codex.iter().map(|root| normalized(root)).collect(),
            antigravity: antigravity.iter().map(|root| normalized(root)).collect(),
            antigravity_cli: antigravity_cli.iter().map(|root| normalized(root)).collect(),
        }
    }

    fn all_roots(&self) -> impl Iterator<Item = &PathBuf> {
        self.codex
            .iter()
            .chain(self.antigravity.iter())
            .chain(self.antigravity_cli.iter())
    }

    pub(crate) fn classify_file(&self, path: &Path) -> Option<(ClientId, PathBuf)> {
        let candidate = normalize_sqlite_sidecar(path);
        let norm = normalized(&candidate);
        if (is_jsonl_path(&norm) || is_rollout_archive(&norm))
            && self.codex.iter().any(|root| norm.starts_with(root))
        {
            return Some((ClientId::Codex, candidate));
        }
        if (is_db_path(&norm) || is_jsonl_path(&norm))
            && self.antigravity.iter().any(|root| norm.starts_with(root))
        {
            return Some((ClientId::Antigravity, candidate));
        }
        if is_db_path(&norm)
            && self
                .antigravity_cli
                .iter()
                .any(|root| norm.starts_with(root))
        {
            return Some((ClientId::AntigravityCli, candidate));
        }
        None
    }

    fn matches_any_root(&self, path: &Path) -> bool {
        let norm = normalized(path);
        self.all_roots()
            .any(|root| norm.starts_with(root) || root.starts_with(&norm))
    }
}

pub fn start(config: &Config) -> Result<(RecommendedWatcher, UnboundedReceiver<Change>)> {
    let watch = WatchRoots::from_config(config);
    let home = normalized(&config.home_dir);
    // Watch the nearest existing ancestor so creating a new sessions/conversations
    // root is noticed too. Avoid recursive watches on home_dir itself when an
    // optional client directory does not exist yet.
    let mut recursive_roots: Vec<PathBuf> = Vec::new();
    let mut watch_home_non_recursive = false;
    for root in watch.all_roots() {
        let mut parent = root.as_path();
        while !parent.is_dir() {
            parent = parent
                .parent()
                .ok_or_else(|| anyhow::anyhow!("no existing parent for {}", root.display()))?;
        }
        let parent_norm = normalized(parent);
        if parent_norm == home {
            watch_home_non_recursive = true;
            continue;
        }
        if !recursive_roots
            .iter()
            .any(|existing| parent_norm.starts_with(existing))
        {
            recursive_roots.retain(|existing| !existing.starts_with(&parent_norm));
            recursive_roots.push(parent_norm);
        }
    }

    let (tx, rx) = mpsc::unbounded_channel();
    let mut watcher =
        notify::recommended_watcher(move |result: notify::Result<notify::Event>| match result {
            Ok(event)
                if matches!(
                    event.kind,
                    EventKind::Create(_)
                        | EventKind::Modify(_)
                        | EventKind::Remove(_)
                        | EventKind::Other
                ) =>
            {
                if event.need_rescan() {
                    let _ = tx.send(Change::Rescan);
                    return;
                }
                let mut paths = Vec::new();
                for path in event.paths {
                    if let Some((_, target)) = watch.classify_file(&path) {
                        if target.is_file() {
                            paths.push(target);
                        } else if !target.exists() {
                            let _ = tx.send(Change::Rescan);
                        }
                    } else if watch.matches_any_root(&path) && (path.is_dir() || !path.exists()) {
                        let _ = tx.send(Change::Rescan);
                    }
                }
                if !paths.is_empty() {
                    let _ = tx.send(Change::Paths(paths));
                }
            }
            Err(error) => {
                eprintln!("Live watcher requested recovery scan: {error}");
                let _ = tx.send(Change::Rescan);
            }
            _ => {}
        })?;
    for root in recursive_roots {
        watcher.watch(&root, RecursiveMode::Recursive)?;
    }
    if watch_home_non_recursive && home.is_dir() {
        watcher.watch(&home, RecursiveMode::NonRecursive)?;
    }
    Ok((watcher, rx))
}

type FileStamp = (u64, SystemTime, Option<(u64, SystemTime)>);

fn file_stamp(path: &Path) -> std::io::Result<FileStamp> {
    let meta = path.metadata()?;
    let modified = meta.modified()?;
    let wal = if is_db_path(path) {
        let wal_path = PathBuf::from(format!("{}-wal", path.display()));
        match wal_path.metadata() {
            Ok(w) => w.modified().ok().map(|t| (w.len(), t)),
            Err(_) => None,
        }
    } else {
        None
    };
    Ok((meta.len(), modified, wal))
}

/// FSEvents may coalesce repeated writes until a writer closes its file (or
/// appends to a SQLite `-wal`). Check only logs/DBs active in this worker
/// session, not the entire historical directory tree.
pub struct ActiveFiles {
    roots: WatchRoots,
    files: HashMap<PathBuf, FileStamp>,
}

impl ActiveFiles {
    pub fn new(config: &Config) -> Self {
        Self {
            roots: WatchRoots::from_config(config),
            files: Default::default(),
        }
    }

    pub fn track(&mut self, paths: impl IntoIterator<Item = PathBuf>) {
        for path in paths {
            let Some((_, target)) = self.roots.classify_file(&path) else {
                continue;
            };
            let target = normalized(&target);
            if let Ok(stamp) = file_stamp(&target) {
                self.files.entry(target).or_insert(stamp);
            }
        }
    }

    pub fn changed(&mut self) -> Vec<PathBuf> {
        let mut changed = Vec::new();
        self.files.retain(|path, previous| match file_stamp(path) {
            Ok(current) => {
                if current != *previous {
                    changed.push(path.clone());
                    *previous = current;
                }
                true
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
            Err(error) => {
                eprintln!("Active live file metadata {}: {error}", path.display());
                false
            }
        });
        changed
    }
}
