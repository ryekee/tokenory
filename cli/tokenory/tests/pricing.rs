use tokenory::{
    db::Database,
    import::{apply_import, preview_records, ApplyOptions},
    pricing::{apply_reprice, estimate, preview_reprice, save_snapshot, PriceEntry, PriceSnapshot},
    queries::{report, Filter},
    usage::{Tokens, UsageRecord},
};
use tokens_core::pricing::ModelPricing;
fn record() -> UsageRecord {
    UsageRecord {
        key: "a".into(),
        client: "claude".into(),
        provider: "test".into(),
        model: "model-a".into(),
        date: "2026-11-04".into(),
        timezone: Some("Asia/Shanghai".into()),
        timestamp_ms: Some(1793750400000),
        session_id: None,
        tokens: Tokens {
            input: 1000,
            output: 500,
            ..Default::default()
        },
        requests: Some(1),
        source_cost_usd: Some(0.0),
        estimated_cost_usd: None,
        cost_basis: None,
        price_snapshot_id: None,
        metadata: serde_json::json!({"granularity":"event"}),
    }
}
fn snapshot(input: f64, output: f64) -> PriceSnapshot {
    PriceSnapshot::new(vec![PriceEntry {
        provider: "test".into(),
        model: "model-a".into(),
        matched_key: "model-a".into(),
        source: "test fixture".into(),
        assumption: "test fixed API rates".into(),
        explicit_free: false,
        allow_fast: false,
        rates: ModelPricing {
            input_cost_per_token: Some(input / 1e6),
            output_cost_per_token: Some(output / 1e6),
            ..Default::default()
        },
    }])
}
#[test]
fn unknown_is_not_free_and_required_rates_must_exist() {
    let r = record();
    assert!(estimate(&r, &PriceSnapshot::new(vec![])).cost.is_none());
    let mut p = snapshot(0., 0.);
    assert!(estimate(&r, &p).cost.is_none());
    p.entries[0].explicit_free = true;
    assert_eq!(estimate(&r, &p).cost, Some(0.));
    let mut r = r;
    r.tokens.cache_read = 1;
    assert!(estimate(&r, &snapshot(2., 8.)).cost.is_none());
}
#[test]
fn rates_ttl_speed_and_daily_granularity_are_explicit() {
    let mut r = record();
    let mut p = snapshot(2., 8.);
    assert!((estimate(&r, &p).cost.unwrap() - 0.006).abs() < 1e-12);
    p.entries[0].rates.cache_creation_input_token_cost = Some(2.5e-6);
    r.tokens.cache_write = 100;
    r.metadata["cacheWrite1h"] = 100.into();
    assert!((estimate(&r, &p).cost.unwrap() - 0.0064).abs() < 1e-12);
    r.metadata["inferenceSpeed"] = serde_json::json!({"speed":"fast","source":"reported"});
    assert!(estimate(&r, &p).cost.is_none());
    r.metadata = serde_json::json!({"granularity":"day"});
    r.tokens = Tokens {
        input: 1_000_000,
        ..Default::default()
    };
    p.entries[0].rates.input_cost_per_token_above_200k_tokens = Some(4e-6);
    assert!((estimate(&r, &p).cost.unwrap() - 2.).abs() < 1e-12);
    r.metadata["granularity"] = "event".into();
    assert!(estimate(&r, &p).cost.unwrap() > 2.);
}
#[test]
fn refresh_does_not_reprice_until_confirmed_and_stale_preview_is_rejected() {
    let t = tempfile::tempdir().unwrap();
    let mut db = Database::open(t.path()).unwrap();
    let p = preview_records(
        &mut db,
        "test",
        b"one",
        vec![record()],
        Some("Asia/Shanghai".into()),
    )
    .unwrap();
    apply_import(&mut db, &p.id, &ApplyOptions::default()).unwrap();
    let id = save_snapshot(&mut db, snapshot(2., 8.)).unwrap();
    let p = preview_reprice(&mut db, &Filter::default(), &id).unwrap();
    assert_eq!(
        report(&mut db, &Filter::default())
            .unwrap()
            .summary
            .known_estimated_cost_usd,
        None
    );
    apply_reprice(&mut db, &p.id).unwrap();
    let id2 = save_snapshot(&mut db, snapshot(4., 16.)).unwrap();
    assert!(
        (report(&mut db, &Filter::default())
            .unwrap()
            .summary
            .known_estimated_cost_usd
            .unwrap()
            - 0.006)
            .abs()
            < 1e-12
    );
    let preview = preview_reprice(&mut db, &Filter::default(), &id2).unwrap();
    let newer = preview_reprice(&mut db, &Filter::default(), &id).unwrap();
    apply_reprice(&mut db, &newer.id).unwrap();
    apply_reprice(&mut db, &preview.id).unwrap();
    assert!(apply_reprice(&mut db, &newer.id).is_err());
}
#[test]
fn deepseek_official_peak_assumption_prices_hit_miss_output_separately() {
    let mut r = record();
    r.provider = "deepseek".into();
    r.model = "deepseek-flash".into();
    r.tokens = Tokens {
        input: 400,
        cache_read: 600,
        output: 150,
        reasoning: 50,
        ..Default::default()
    };
    let e = estimate(&r, &PriceSnapshot::deepseek_reference());
    assert!((e.cost.unwrap() - 0.0003636).abs() < 1e-12);
    assert!(e.basis.contains("peak"));
}
