// [INPUT]: 读取生成的全量目录、models.dev 缓存和当前计价快照。
// [OUTPUT]: 提供完整费率目录和订阅命名空间识别。
// [POS]: IPC 价格展示边界；目录扩充不改写账本或历史金额。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
use crate::pricing::{PriceEntry, PriceSnapshot};
use anyhow::Result;
use std::collections::BTreeMap;

pub fn entries(current: Option<&PriceSnapshot>) -> Result<Vec<PriceEntry>> {
    let baseline: Vec<PriceEntry> = serde_json::from_str(include_str!("../data/price-catalog.json"))?;
    let mut catalog: BTreeMap<_, _> = baseline.into_iter().map(|e| ((e.provider.to_lowercase(), e.model.to_lowercase()), e)).collect();
    if let Some(cached) = tokens_core::pricing::models_dev::load_cached_any_age() {
        for (key, rates) in cached {
            let Some((provider, model)) = key.split_once('/') else { continue };
            if let Some(entry) = catalog.get_mut(&(provider.to_owned(), model.to_owned())) {
                entry.rates = rates;
            }
        }
    }
    if let Some(snapshot) = current {
        for entry in &snapshot.entries {
            catalog.insert((entry.provider.to_lowercase(), entry.model.to_lowercase()), entry.clone());
        }
    }
    let references = catalog.clone();
    for entry in catalog.values_mut().filter(|e| subscription_provider(&e.provider)) {
        let bare = entry.model.rsplit('/').next().unwrap_or(&entry.model).to_lowercase();
        if let Some(provider) = crate::price_coverage::reference_provider(&bare) {
            if let Some(reference) = references.get(&(provider.to_owned(), bare)) {
                entry.rates = reference.rates.clone();
                entry.schedule = reference.schedule.clone();
                entry.source = reference.source.clone();
                entry.assumption = "Subscription plan; first-party API reference estimate, not subscription charges".into();
            }
        }
    }
    Ok(catalog.into_values().collect())
}

pub fn subscription_provider(provider: &str) -> bool {
    provider.contains("plan") || matches!(provider, "github-copilot" | "github_copilot" | "gitlab" | "cline-pass")
}
