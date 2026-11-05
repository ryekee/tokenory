use anyhow::{ensure, Context, Result};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
};
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
            ensure!(
                matches!(client.as_str(), "claude" | "codex"),
                "unsupported scanner: {client}"
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
    pub fn roots(&self, client: &str) -> Vec<PathBuf> {
        let mut roots = match client {
            "claude" => vec![self.home_dir.join(".claude/projects")],
            "codex" => vec![
                self.home_dir.join(".codex/sessions"),
                self.home_dir.join(".codex/archived_sessions"),
            ],
            _ => vec![],
        };
        if let Some(extra) = self.extra_scan_paths.get(client) {
            roots.extend(extra.clone());
        }
        roots
    }
}
