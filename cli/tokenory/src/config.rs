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
