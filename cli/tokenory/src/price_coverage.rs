// [INPUT]: 读取价格快照、上游价格缓存和未计价记录。
// [OUTPUT]: 提供首次计价候选和新增模型的快照扩展。
// [POS]: 连接价格刷新与账本；已有金额只由显式重估修改。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
use crate::{
    db::Database,
    pricing::{self, PriceSnapshot},
    usage::UsageRecord,
};
use anyhow::Result;
use rusqlite::Connection;
use tokens_core::pricing::PricingService;

pub(crate) fn pending_assignments(
    connection: &Connection,
    id: &str,
    snapshot: &PriceSnapshot,
) -> Result<Vec<(String, String, UsageRecord)>> {
    let mut stmt = connection
        .prepare("SELECT source,batch_id,body FROM usage_records WHERE estimated_cost IS NULL")?;
    let rows = stmt.query_map([], |r| {
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
        ))
    })?;
    let mut changes = Vec::new();
    for row in rows {
        let (source, batch, body) = row?;
        let mut record: UsageRecord = serde_json::from_str(&body)?;
        pricing::assign(&source, &mut record, id, snapshot);
        if record.estimated_cost_usd.is_some() {
            changes.push((source, batch, record));
        }
    }
    Ok(changes)
}

// 新模型直接使用本次 worker 已加载的价格数据，无需等下次网络刷新。
pub fn extend_from_service(db: &mut Database, service: &PricingService) -> Result<bool> {
    let Some((_, mut current)) = pricing::active_snapshot(&db.connection)? else {
        return Ok(false);
    };
    let candidate = pricing::snapshot_from_service(db, service)?;
    let additions: Vec<_> = candidate
        .entries
        .into_iter()
        .filter(|entry| {
            !current
                .entries
                .iter()
                .any(|old| old.provider == entry.provider && old.model == entry.model)
        })
        .collect();
    if additions.is_empty() {
        return Ok(false);
    }
    current.entries.extend(additions);
    current.created_at = chrono::Utc::now().to_rfc3339();
    pricing::save_snapshot(db, current)?;
    Ok(true)
}

// 此表只选择参考价厂商，不改写账本的提供方身份。
// 路由标签和任意自定义模型不满足明确的模型家族前缀。
pub(crate) fn reference_provider(model: &str) -> Option<&'static str> {
    let model = model.to_ascii_lowercase();
    [
        ("claude-", "anthropic"),
        ("gpt-", "openai"),
        ("o1-", "openai"),
        ("o3-", "openai"),
        ("o4-", "openai"),
        ("gemini-", "google"),
        ("deepseek-", "deepseek"),
        ("kimi-", "moonshotai"),
        ("mimo-", "xiaomi"),
        ("glm-", "zai"),
        ("grok-", "xai"),
        ("minimax-", "minimax"),
        ("mistral-", "mistralai"),
        ("devstral-", "mistralai"),
        ("swe-2", "devin"),
        ("composer-", "cursor"),
    ]
    .into_iter()
    .find_map(|(prefix, provider)| model.starts_with(prefix).then_some(provider))
}
