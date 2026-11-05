use std::{
    collections::{BTreeMap, HashSet},
    time::Instant,
};
use tokens_core::{LocalParseOptions, ScannerSettings};

#[tokio::main]
async fn main() {
    let start = Instant::now();
    let messages = tokens_core::parse_local_unified_messages_with_pricing(
        LocalParseOptions {
            clients: Some(vec!["claude".into(), "codex".into()]),
            scanner_settings: ScannerSettings {
                bucket_timezone: Some("Asia/Shanghai".into()),
                ..Default::default()
            },
            ..Default::default()
        },
        None,
    )
    .await
    .unwrap();
    let mut groups: BTreeMap<String, (usize, i64, usize, usize)> = BTreeMap::new();
    let mut keys = HashSet::new();
    for m in messages {
        let g = groups
            .entry(format!("{} / {} / {}", m.client, m.provider_id, m.model_id))
            .or_default();
        g.0 += 1;
        g.1 += m.tokens.total();
        if let Some(k) = m.dedup_key {
            if !keys.insert((m.client, k)) {
                g.3 += 1;
            }
        } else {
            g.2 += 1;
        }
    }
    println!(
        "{}",
        serde_json::json!({"elapsedSeconds": start.elapsed().as_secs_f64(), "groups":groups})
    );
}
