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
        schedule: None,
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
fn direct_openai_event_uses_full_request_context_tier_but_daily_uses_base_rates() {
    let mut r = record();
    r.provider = "openai".into();
    r.model = "gpt-6-astra".into();
    r.tokens = Tokens {
        input: 300_000,
        output: 10_000,
        ..Default::default()
    };
    let mut p = snapshot(10., 50.);
    let e = &mut p.entries[0];
    e.provider = r.provider.clone();
    e.model = r.model.clone();
    e.matched_key = r.model.clone();
    e.source = "LiteLLM".into();
    e.rates.input_cost_per_token_above_272k_tokens = Some(20e-6);
    e.rates.output_cost_per_token_above_272k_tokens = Some(75e-6);
    let service = tokens_core::pricing::PricingService::new(
        [(e.matched_key.clone(), e.rates.clone())]
            .into_iter()
            .collect(),
        Default::default(),
    );
    let upstream = service.calculate_cost_with_provider(
        &r.model,
        Some(&r.provider),
        &tokens_core::TokenBreakdown {
            input: 300_000,
            output: 10_000,
            ..Default::default()
        },
    );
    assert_eq!(estimate(&r, &p).cost.unwrap(), upstream);
    assert!((estimate(&r, &p).cost.unwrap() - 6.75).abs() < 1e-12);
    r.tokens.input = 272_000;
    assert!((estimate(&r, &p).cost.unwrap() - 3.22).abs() < 1e-12);
    r.tokens.input = 300_000;
    r.metadata["granularity"] = "day".into();
    assert!((estimate(&r, &p).cost.unwrap() - 3.5).abs() < 1e-12);
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
fn deepseek_official_peak_prices_hit_miss_output_separately() {
    let mut r = record();
    r.timestamp_ms = Some(
        chrono::DateTime::parse_from_rfc3339("2026-11-04T10:00:00+08:00")
            .unwrap()
            .timestamp_millis(),
    );
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

#[test]
fn deepseek_schedule_boundaries_weekends_holidays_and_aliases() {
    let p = PriceSnapshot::deepseek_reference();
    let mut r = record();
    r.provider = "deepseek".into();
    r.model = "deepseek-v4-flash".into();
    r.tokens = Tokens {
        input: 1_000_000,
        cache_read: 1_000_000,
        output: 1_000_000,
        ..Default::default()
    };
    for (time, factor) in [
        ("2026-11-05T08:59:59+08:00", 0.5),
        ("2026-11-05T09:00:00+08:00", 1.),
        ("2026-11-05T11:59:59+08:00", 1.),
        ("2026-11-05T12:00:00+08:00", 0.5),
        ("2026-11-05T14:00:00+08:00", 1.),
        ("2026-11-05T17:59:59+08:00", 1.),
        ("2026-11-05T18:00:00+08:00", 0.5),
        ("2026-09-20T10:00:00+08:00", 0.5),
        ("2026-10-01T10:00:00+08:00", 0.5),
        ("2026-11-07T10:00:00+08:00", 0.5),
        ("2026-11-05T01:00:00Z", 1.),
    ] {
        r.timestamp_ms = Some(
            chrono::DateTime::parse_from_rfc3339(time)
                .unwrap()
                .timestamp_millis(),
        );
        assert!(
            (estimate(&r, &p).cost.unwrap() - 1.506 * factor).abs() < 1e-10,
            "{time}"
        );
    }
    r.timestamp_ms = None;
    r.date = "2026-11-05".into();
    assert!(estimate(&r, &p).cost.is_none());
    r.date = "2026-10-01".into();
    assert_eq!(estimate(&r, &p).cost, Some(0.753));
    r.timezone = None;
    assert!(estimate(&r, &p).cost.is_none());
    r.timestamp_ms = Some(
        chrono::DateTime::parse_from_rfc3339("2027-11-05T10:00:00+08:00")
            .unwrap()
            .timestamp_millis(),
    );
    assert!(estimate(&r, &p).cost.is_none());
    r.provider = "reseller".into();
    assert!(estimate(&r, &p).cost.is_none());
}
#[test]
fn legacy_snapshots_keep_their_original_fixed_rate() {
    let mut p = PriceSnapshot::deepseek_reference();
    for e in &mut p.entries {
        e.schedule = None;
    }
    let mut r = record();
    r.provider = "deepseek".into();
    r.model = "deepseek-flash".into();
    r.timestamp_ms = None;
    r.tokens = Tokens {
        input: 1_000_000,
        ..Default::default()
    };
    assert_eq!(estimate(&r, &p).cost, Some(0.3));
}

#[test]
fn bundled_official_prices_work_offline_with_context_speed_and_cache() {
    let p = PriceSnapshot::official_reference();
    p.validate().unwrap();
    let mut r = record();
    r.provider = "openai".into();
    r.model = "gpt-6.1-sol".into();
    r.tokens = Tokens {
        input: 280_000,
        output: 10_000,
        cache_read: 20_000,
        ..Default::default()
    };
    assert!((estimate(&r, &p).cost.unwrap() - 1.274).abs() < 1e-10);
    r.metadata["inferenceSpeed"] = serde_json::json!({"speed":"fast"});
    assert!((estimate(&r, &p).cost.unwrap() - 2.548).abs() < 1e-10);
    r.metadata["granularity"] = "day".into();
    assert!((estimate(&r, &p).cost.unwrap() - 1.324).abs() < 1e-10);
    r.metadata = serde_json::json!({"granularity":"event","cacheWrite1h":100});
    r.provider = "anthropic".into();
    r.model = "claude-opus-4-8".into();
    r.tokens = Tokens {
        input: 1000,
        output: 500,
        cache_write: 100,
        ..Default::default()
    };
    assert!((estimate(&r, &p).cost.unwrap() - 0.0185).abs() < 1e-10);
    r.metadata["inferenceSpeed"] = serde_json::json!({"speed":"fast"});
    assert!((estimate(&r, &p).cost.unwrap() - 0.037).abs() < 1e-10);
}

#[test]
fn catalog_upgrade_keeps_old_snapshots_and_is_idempotent_offline() {
    let t = tempfile::tempdir().unwrap();
    let mut db = Database::open(t.path()).unwrap();
    let mut old = PriceSnapshot::deepseek_reference();
    for e in &mut old.entries {
        e.schedule = None;
    }
    let old_id = save_snapshot(&mut db, old).unwrap();
    tokenory::pricing::initialize(&mut db).unwrap();
    let (new_id, new) = tokenory::pricing::active_snapshot(&db.connection)
        .unwrap()
        .unwrap();
    assert_ne!(old_id, new_id);
    assert!(new
        .entries
        .iter()
        .any(|e| e.model == "deepseek-flash" && e.schedule.is_some()));
    assert!(tokenory::pricing::load_snapshot(&db.connection, &old_id)
        .unwrap()
        .entries[0]
        .schedule
        .is_none());
    tokenory::pricing::initialize(&mut db).unwrap();
    assert_eq!(
        new_id,
        tokenory::pricing::active_snapshot(&db.connection)
            .unwrap()
            .unwrap()
            .0
    );
}

#[test]
fn reprice_checks_original_body_without_float_reserialization_false_conflict() {
    let t = tempfile::tempdir().unwrap();
    let mut db = Database::open(t.path()).unwrap();
    let mut r = record();
    r.estimated_cost_usd = Some(0.18448799999999999);
    let p = preview_records(
        &mut db,
        "test",
        b"float-cost",
        vec![r],
        Some("Asia/Shanghai".into()),
    )
    .unwrap();
    apply_import(&mut db, &p.id, &ApplyOptions::default()).unwrap();
    let mut body: String = db
        .connection
        .query_row("SELECT body FROM usage_records LIMIT 1", [], |row| {
            row.get(0)
        })
        .unwrap();
    let start = body.find("\"estimatedCostUsd\":").unwrap() + "\"estimatedCostUsd\":".len();
    let end = start + body[start..].find(',').unwrap();
    body.replace_range(start..end, "0.18448799999999999");
    db.connection
        .execute(
            "UPDATE usage_records SET estimated_cost=?1,body=?2",
            rusqlite::params![0.18448799999999999_f64, body],
        )
        .unwrap();
    let id = save_snapshot(&mut db, snapshot(2., 8.)).unwrap();
    let preview = preview_reprice(&mut db, &Filter::default(), &id).unwrap();
    apply_reprice(&mut db, &preview.id).unwrap();
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
}
