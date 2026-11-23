use anyhow::{ensure, Context, Result};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    path::{Component, Path, PathBuf},
};

/// The same root tasks used by the scanner, with environment overrides disabled.
pub fn default_scan_paths(home: &Path) -> BTreeMap<String, Vec<PathBuf>> {
    let clients: Vec<_> = crate::clients::CLIENTS
        .iter()
        .map(|id| id.as_str().to_owned())
        .collect();
    let mut result: BTreeMap<String, Vec<PathBuf>> = BTreeMap::new();
    for (id, path) in
        tokens_core::scanner::default_scan_roots(&home.to_string_lossy(), &clients, false)
    {
        result.entry(id.as_str().to_owned()).or_default().push(path);
    }
    for id in crate::clients::CLIENTS {
        if !result.contains_key(id.as_str()) {
            result.insert(
                id.as_str().to_owned(),
                vec![PathBuf::from(id.data().resolve_path_with_env_strategy(
                    &home.to_string_lossy(),
                    false,
                ))],
            );
        }
    }
    for paths in result.values_mut() {
        paths.sort();
        paths.dedup();
    }
    result
}

fn path_identity(path: &Path) -> PathBuf {
    if let Ok(path) = std::fs::canonicalize(path) {
        return path;
    }
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            other => normalized.push(other.as_os_str()),
        }
    }
    normalized
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase", deny_unknown_fields)]
pub struct Config {
    pub home_dir: PathBuf,
    pub interval_seconds: u64,
    pub timezone: String,
    pub extra_scan_paths: BTreeMap<String, Vec<PathBuf>>,
}
impl Default for Config {
    fn default() -> Self {
        Self {
            home_dir: dirs::home_dir().unwrap_or_default(),
            interval_seconds: 60,
            timezone: "Asia/Shanghai".into(),
            extra_scan_paths: BTreeMap::new(),
        }
    }
}
impl Config {
    /// Reject newly introduced duplicates without invalidating existing configurations.
    pub fn validate_new_paths(&self, previous: &Self) -> Result<()> {
        if self.extra_scan_paths == previous.extra_scan_paths && self.home_dir == previous.home_dir
        {
            return Ok(());
        }
        let defaults = default_scan_paths(&self.home_dir);
        for (client, paths) in &self.extra_scan_paths {
            let count_paths = |items: &[PathBuf]| {
                let mut counts = BTreeMap::new();
                for path in items {
                    *counts.entry(path_identity(path)).or_insert(0usize) += 1;
                }
                counts
            };
            let old = count_paths(
                previous
                    .extra_scan_paths
                    .get(client)
                    .map(Vec::as_slice)
                    .unwrap_or(&[]),
            );
            let new = count_paths(paths);
            let built_in = defaults.get(client).map(Vec::as_slice).unwrap_or(&[]);
            for (path, count) in new {
                if count > *old.get(&path).unwrap_or(&0) {
                    ensure!(
                        count == 1 && !built_in.iter().any(|root| path_identity(root) == path),
                        "duplicate scan path for {client}: {}",
                        path.display()
                    );
                }
            }
        }
        Ok(())
    }
    pub fn validate(&self) -> Result<()> {
        ensure!(
            self.home_dir.is_absolute(),
            "home directory must be absolute"
        );
        ensure!(
            (15..=86400).contains(&self.interval_seconds),
            "scan interval must be 15–86400 seconds"
        );
        self.timezone
            .parse::<chrono_tz::Tz>()
            .context("invalid IANA timezone")?;
        for (client, paths) in &self.extra_scan_paths {
            let id = tokens_core::ClientId::from_str(client)
                .filter(|c| crate::clients::CLIENTS.contains(c))
                .with_context(|| format!("unsupported scanner: {client}"))?;
            ensure!(
                crate::clients::supports_extra_paths(id),
                "{client} uses its standard database location; extra scan paths are not supported"
            );
            for p in paths {
                ensure!(p.is_absolute(), "scan paths must be absolute");
            }
        }
        Ok(())
    }
    pub fn load(directory: &Path) -> Result<Self> {
        let path = directory.join("settings.json");
        let value = if path.exists() {
            serde_json::from_slice(&std::fs::read(path)?)?
        } else {
            Self::default()
        };
        value.validate()?;
        Ok(value)
    }
    pub fn save(&self, directory: &Path) -> Result<()> {
        self.validate()?;
        let temp = directory.join("settings.json.tmp");
        std::fs::write(&temp, serde_json::to_vec_pretty(self)?)?;
        std::fs::rename(temp, directory.join("settings.json"))?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_roots_follow_scanner_tasks() {
        let home = tempfile::tempdir().unwrap();
        let roots = default_scan_paths(home.path());
        let codex = roots.get("codex").unwrap();
        assert!(codex.contains(&home.path().join(".codex/sessions")));
        assert!(codex.contains(&home.path().join(".codex/archived_sessions")));
        let claude = roots.get("claude").unwrap();
        assert!(claude.contains(&home.path().join(".claude/projects")));
        assert!(claude.contains(&home.path().join(".claude/transcripts")));
        assert!(roots["opencode"].contains(&home.path().join(".local/share/opencode")));
        assert!(
            roots["antigravity"].contains(&home.path().join(".gemini/antigravity/conversations"))
        );
        for client in crate::clients::CLIENTS {
            if crate::clients::supports_extra_paths(*client) {
                assert!(!roots.get(client.as_str()).unwrap().is_empty(), "{}", client.as_str());
            }
        }
    }

    #[test]
    fn new_duplicates_fail_but_legacy_duplicates_remain_editable() {
        let home = tempfile::tempdir().unwrap();
        let mut old = Config {
            home_dir: home.path().into(),
            ..Config::default()
        };
        let extra = home.path().join("extra");
        old.extra_scan_paths
            .insert("codex".into(), vec![extra.clone(), extra.clone()]);
        assert!(old.validate_new_paths(&old).is_ok());
        let mut next = old.clone();
        next.extra_scan_paths
            .get_mut("codex")
            .unwrap()
            .push(extra.join("."));
        assert!(next.validate_new_paths(&old).is_err());
        let mut next = old.clone();
        next.extra_scan_paths
            .get_mut("codex")
            .unwrap()
            .push(home.path().join(".codex/sessions/"));
        assert!(next.validate_new_paths(&old).is_err());
        let mut next = old.clone();
        next.extra_scan_paths
            .get_mut("codex")
            .unwrap()
            .push(home.path().join("unique"));
        assert!(next.validate_new_paths(&old).is_ok());
    }

    #[cfg(unix)]
    #[test]
    fn symlink_aliases_are_duplicates() {
        let home = tempfile::tempdir().unwrap();
        let target = home.path().join("target");
        std::fs::create_dir(&target).unwrap();
        let link = home.path().join("link");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        let mut old = Config {
            home_dir: home.path().into(),
            ..Config::default()
        };
        old.extra_scan_paths.insert("codex".into(), vec![target]);
        let mut next = old.clone();
        next.extra_scan_paths.get_mut("codex").unwrap().push(link);
        assert!(next.validate_new_paths(&old).is_err());
    }
}
