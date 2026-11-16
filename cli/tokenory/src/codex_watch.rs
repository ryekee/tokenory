// [INPUT]: Configured Codex roots and filesystem create/modify/remove notifications.
// [OUTPUT]: Changed log paths or a rescan request; no usage estimates.
// [POS]: Live ingestion trigger; periodic scans remain the recovery path.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
use crate::config::Config;
use anyhow::Result;
use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use std::path::{Path, PathBuf};
use tokio::sync::mpsc::{self, UnboundedReceiver};

pub enum Change {
    Paths(Vec<PathBuf>),
    Rescan,
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

fn roots(config: &Config) -> Vec<PathBuf> {
    let mut roots = vec![
        config.home_dir.join(".codex/sessions"),
        config.home_dir.join(".codex/archived_sessions"),
    ];
    roots.extend(
        config
            .extra_scan_paths
            .get("codex")
            .into_iter()
            .flatten()
            .cloned(),
    );
    roots.extend(
        tokens_core::scanner::headless_roots_with_env_strategy(
            &config.home_dir.to_string_lossy(),
            false,
        )
        .into_iter()
        .map(|root| root.join("codex")),
    );
    roots.iter().map(|root| normalized(root)).collect()
}

pub fn start(config: &Config) -> Result<(RecommendedWatcher, UnboundedReceiver<Change>)> {
    let roots = roots(config);
    // Watch the nearest existing ancestor so creating a new sessions root is noticed too.
    let mut watch_roots = Vec::new();
    for root in &roots {
        let mut parent = root.as_path();
        while !parent.is_dir() {
            parent = parent
                .parent()
                .ok_or_else(|| anyhow::anyhow!("no existing parent for {}", root.display()))?;
        }
        if !watch_roots
            .iter()
            .any(|existing: &PathBuf| parent.starts_with(existing))
        {
            watch_roots.retain(|existing| !existing.starts_with(parent));
            watch_roots.push(parent.to_path_buf());
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
                    if roots
                        .iter()
                        .any(|root| path.starts_with(root) || root.starts_with(&path))
                    {
                        if path.extension().is_some_and(|ext| ext == "jsonl") && path.is_file() {
                            paths.push(path);
                        } else if path.is_dir() || !path.exists() {
                            let _ = tx.send(Change::Rescan);
                        }
                    }
                }
                if !paths.is_empty() {
                    let _ = tx.send(Change::Paths(paths));
                }
            }
            Err(error) => {
                eprintln!("Codex watcher requested recovery scan: {error}");
                let _ = tx.send(Change::Rescan);
            }
            _ => {}
        })?;
    for root in watch_roots {
        watcher.watch(&root, RecursiveMode::Recursive)?;
    }
    Ok((watcher, rx))
}

/// FSEvents may coalesce repeated writes until a writer closes its file. Check only
/// logs active in this worker session, not the entire historical directory tree.
pub struct ActiveFiles {
    roots: Vec<PathBuf>,
    files: std::collections::HashMap<PathBuf, (u64, std::time::SystemTime)>,
}
impl ActiveFiles {
    pub fn new(config: &Config) -> Self {
        Self {
            roots: roots(config),
            files: Default::default(),
        }
    }
    pub fn track(&mut self, paths: impl IntoIterator<Item = PathBuf>) {
        for path in paths {
            let path = normalized(&path);
            if path.extension().is_some_and(|ext| ext == "jsonl")
                && self.roots.iter().any(|root| path.starts_with(root))
            {
                if let Ok(meta) = path.metadata() {
                    if let Ok(modified) = meta.modified() {
                        self.files.entry(path).or_insert((meta.len(), modified));
                    }
                }
            }
        }
    }
    pub fn changed(&mut self) -> Vec<PathBuf> {
        let mut changed = Vec::new();
        self.files.retain(|path, previous| {
            match path
                .metadata()
                .and_then(|meta| Ok((meta.len(), meta.modified()?)))
            {
                Ok(current) => {
                    if current != *previous {
                        changed.push(path.clone());
                        *previous = current;
                    }
                    true
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
                Err(error) => {
                    eprintln!("Codex active log metadata {}: {error}", path.display());
                    false
                }
            }
        });
        changed
    }
}
