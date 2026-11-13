// [INPUT]: 使用内置目录和计价快照。
// [OUTPUT]: 验证未使用的供应商覆盖及人工规则优先级。
// [POS]: 防止费率展示重新依赖历史用量。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
use tokenory::{price_catalog, pricing::PriceSnapshot};
#[test]
fn full_catalog_includes_unused_providers_and_keeps_reference_rules() {
    let catalog = price_catalog::entries(Some(&PriceSnapshot::bundled_reference())).unwrap();
    for provider in ["google", "moonshotai", "xiaomi", "zai", "minimax", "mistral", "openrouter", "groq"] {
        assert!(catalog.iter().any(|e| e.provider == provider), "{provider}");
    }
    let deepseek = catalog.iter().find(|e| e.provider == "deepseek" && e.model == "deepseek-v4-flash").unwrap();
    assert_eq!(deepseek.schedule.as_deref(), Some("deepseek-cn-2026-v1"));
    assert_eq!(deepseek.rates.input_cost_per_token, Some(0.3e-6));
    let compactor = catalog.iter().find(|e| e.provider == "devin" && e.model == "compactor").unwrap();
    assert!(compactor.assumption.contains("User-selected reference estimate"));
    assert!(catalog.iter().any(|e| e.provider == "github-copilot" && e.rates.input_cost_per_token.unwrap_or(0.) > 0.));
    let unique: std::collections::HashSet<_> = catalog.iter().map(|e| (&e.provider, &e.model)).collect();
    assert_eq!(unique.len(), catalog.len());
}

#[test]
fn subscription_usage_uses_first_party_api_reference() {
    let dir = tempfile::tempdir().unwrap();
    let db = tokenory::db::Database::open(dir.path()).unwrap();
    let record: tokenory::usage::UsageRecord = serde_json::from_value(serde_json::json!({
        "key":"subscription", "client":"copilot", "provider":"github-copilot", "model":"openai/gpt-6-luna",
        "date":"2026-11-13", "timezone":"Asia/Shanghai", "tokens":{"input":1000000,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0},"requests":1,"metadata":{}
    })).unwrap();
    tokenory::db::put_record(&db.connection,"local","",&record).unwrap();
    let service = tokens_core::pricing::PricingService::new(Default::default(),Default::default());
    let snapshot = tokenory::pricing::snapshot_from_service(&db, &service).unwrap();
    let priced = tokenory::pricing::estimate("local",&record,&snapshot);
    assert_eq!(priced.cost,Some(0.1));
    let entry = snapshot.entries.iter().find(|e|e.provider=="github-copilot" && e.model=="openai/gpt-6-luna").unwrap();
    assert!(entry.assumption.contains("Subscription plan"));
}
