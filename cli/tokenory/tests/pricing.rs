// [INPUT]: 使用真实计价、导入和 SQLite 接口。
// [OUTPUT]: 验证价格匹配、原生请求时间、订阅等价估算、长上下文计价依据、免费路由、待计价回填与历史重估。
// [POS]: 隔离测试账本，验证计价规则的外部行为。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
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
        remote_policy: None,
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
fn gpt_62_official_rates_cover_cache_speed_context_and_promotion_boundary() {
    let mut p = PriceSnapshot::bundled_reference();
    p.created_at = "2026-11-18T00:00:00Z".into();
    for (model, standard, at_limit, above_limit) in [
        ("gpt-6.2-astra", 0.0284, 2.576, 4.952016),
        ("gpt-6.2-sol", 0.0071, 0.644, 1.238004),
    ] {
        let mut r = record();
        r.provider = "openai".into();
        r.model = model.into();
        r.tokens.cache_read = 1000;
        for (speed, factor) in [("standard", 1.), ("fast", 2.), ("ultrafast", 3.)] {
            r.metadata["inferenceSpeed"] = serde_json::json!({"speed": speed});
            assert!((estimate("local", &r, &p).cost.unwrap() - standard * factor).abs() < 1e-12);
        }
        for (date, factor) in [
            ("2027-03-01T07:59:59Z", 3.),
            ("2027-03-01T08:00:00Z", 6.),
        ] {
            p.created_at = date.into();
            assert!((estimate("local", &r, &p).cost.unwrap() - standard * factor).abs() < 1e-12);
        }
        p.created_at = "2026-11-18T00:00:00Z".into();
        r.metadata["inferenceSpeed"] = serde_json::json!({"speed": "standard"});
        r.tokens = Tokens { input: 272_000, output: 10_000, ..Default::default() };
        assert!((estimate("local", &r, &p).cost.unwrap() - at_limit).abs() < 1e-12);
        r.tokens.input += 1;
        assert!((estimate("local", &r, &p).cost.unwrap() - above_limit).abs() < 1e-12);
        r.metadata["inferenceSpeed"] = serde_json::json!({"speed": "fast"});
        assert!((estimate("local", &r, &p).cost.unwrap() - above_limit * 2.).abs() < 1e-12);
        r.provider = "reseller".into();
        assert!(estimate("local", &r, &p).cost.is_none());
    }
}
#[test]
fn codex_review_reference_matches_export_and_is_scoped_to_codex() {
    let p = PriceSnapshot::bundled_reference();
    let mut r = record();
    r.client = "codex".into();
    r.model = "codex-auto-review".into();
    r.provider = "openai".into();
    r.tokens = Tokens {
        input: 202_135,
        cache_read: 641_280,
        output: 1_813,
        reasoning: 1_565,
        cache_write: 0,
    };
    for speed in ["standard", "fast", "ultrafast"] {
        r.metadata["inferenceSpeed"] = serde_json::json!({"speed": speed, "source": "selected"});
        let local = estimate("local", &r, &p);
        assert!((local.cost.unwrap() - 0.07652815).abs() < 1e-12);
        assert!(local.basis.contains("tokens.ci"));
        assert!(local.basis.contains("no speed multiplier"));
    }
    r.tokens.cache_write = 1;
    assert!(estimate("local", &r, &p).cost.is_none());
    r.tokens.cache_write = 0;
    r.metadata = serde_json::json!({});
    r.client = "claude".into();
    assert!(estimate("local", &r, &p).cost.is_none());
    r.client = "codex".into();
    r.provider = "reseller".into();
    assert!(estimate("local", &r, &p).cost.is_none());
    r.provider = "unknown".into();
    assert!(estimate("local", &r, &p).cost.is_none());
    assert!((estimate("tokens-ci", &r, &p).cost.unwrap() - 0.07652815).abs() < 1e-12);
    r.source_cost_usd = Some(0.12);
    assert_eq!(estimate("tokens-ci", &r, &p).cost, Some(0.12));
    assert!(estimate("tokens-ci", &r, &PriceSnapshot::new(vec![]))
        .cost
        .is_none());
}

#[test]
fn catalog_upgrade_fills_pending_review_without_repricing_known_usage() {
    let root = tempfile::tempdir().unwrap();
    let mut db = Database::open(root.path()).unwrap();
    let mut previous = PriceSnapshot::bundled_reference();
    previous.entries.iter_mut().find(|e| e.model == "codex-auto-review").unwrap().allow_fast = false;
    let old_id = save_snapshot(&mut db, previous).unwrap();
    db.connection.execute(
        "INSERT INTO app_state(key,value) VALUES ('officialCatalog','2026-11-18-openai-6.2-v1')",
        [],
    ).unwrap();

    let mut pending = record();
    pending.client = "codex".into();
    pending.provider = "openai".into();
    pending.model = "codex-auto-review".into();
    pending.metadata["inferenceSpeed"] = serde_json::json!({"speed": "fast", "source": "selected"});
    let old = tokenory::pricing::load_snapshot(&db.connection, &old_id).unwrap();
    tokenory::pricing::assign("local", &mut pending, &old_id, &old);
    assert!(pending.estimated_cost_usd.is_none());
    tokenory::db::put_record(&db.connection, "local", "", &pending).unwrap();

    let mut known = pending.clone();
    known.key = "known".into();
    known.estimated_cost_usd = Some(0.25);
    tokenory::db::put_record(&db.connection, "local", "", &known).unwrap();
    db.connection.execute("INSERT INTO coverage_choices VALUES ('2026-11-04','codex','local','')", []).unwrap();

    tokenory::pricing::initialize(&mut db).unwrap();
    let report = report(&mut db, &Filter::default()).unwrap();
    assert_eq!(report.summary.unpriced_tokens, 0);
    assert_eq!(report.summary.tokens, 3_000);
    assert_eq!(report.summary.fast_tokens, Some(3_000));
    let filled = &report.details[0].record;
    assert!((filled.estimated_cost_usd.unwrap() - 0.00125).abs() < 1e-12);
    assert_eq!(filled.metadata, pending.metadata);
    let unchanged = &report.details[1].record;
    assert_eq!(unchanged.estimated_cost_usd, known.estimated_cost_usd);
    assert_eq!(unchanged.price_snapshot_id, Some(old_id));
    assert!(std::fs::read_dir(root.path().join("backups"))
        .unwrap()
        .any(|entry| entry.unwrap().file_name().to_string_lossy().ends_with("-price-coverage.sqlite3")));
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
    assert_eq!(estimate("local", &r, &p).cost.unwrap(), upstream);
    assert!((estimate("local", &r, &p).cost.unwrap() - 6.75).abs() < 1e-12);
    r.tokens.input = 272_000;
    assert!((estimate("local", &r, &p).cost.unwrap() - 3.22).abs() < 1e-12);
    r.tokens.input = 300_000;
    r.metadata["granularity"] = "day".into();
    assert!((estimate("local", &r, &p).cost.unwrap() - 3.5).abs() < 1e-12);
}
#[test]
fn unknown_is_not_free_and_required_rates_must_exist() {
    let r = record();
    assert!(estimate("local", &r, &PriceSnapshot::new(vec![]))
        .cost
        .is_none());
    let mut p = snapshot(0., 0.);
    assert!(estimate("local", &r, &p).cost.is_none());
    p.entries[0].explicit_free = true;
    assert_eq!(estimate("local", &r, &p).cost, Some(0.));
    let mut r = r;
    r.tokens.cache_read = 1;
    assert!(estimate("local", &r, &snapshot(2., 8.)).cost.is_none());
}
#[test]
fn rates_ttl_speed_and_daily_granularity_are_explicit() {
    let mut r = record();
    let mut p = snapshot(2., 8.);
    assert!((estimate("local", &r, &p).cost.unwrap() - 0.006).abs() < 1e-12);
    p.entries[0].rates.cache_creation_input_token_cost = Some(2.5e-6);
    r.tokens.cache_write = 100;
    r.metadata["cacheWrite1h"] = 100.into();
    assert!((estimate("local", &r, &p).cost.unwrap() - 0.0064).abs() < 1e-12);
    r.metadata["inferenceSpeed"] = serde_json::json!({"speed":"fast","source":"reported"});
    assert!(estimate("local", &r, &p).cost.is_none());
    r.metadata = serde_json::json!({"granularity":"day"});
    r.tokens = Tokens {
        input: 1_000_000,
        ..Default::default()
    };
    p.entries[0].rates.input_cost_per_token_above_200k_tokens = Some(4e-6);
    assert!((estimate("local", &r, &p).cost.unwrap() - 2.).abs() < 1e-12);
    r.metadata["granularity"] = "event".into();
    assert!(estimate("local", &r, &p).cost.unwrap() > 2.);
}
#[test]
fn refresh_fills_missing_prices_but_preserves_known_costs_and_rejects_stale_preview() {
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
        Some(0.006)
    );
    apply_reprice(&mut db, &p.id).unwrap();
    assert_eq!(db.connection.query_row("SELECT count(*) FROM reprice_previews WHERE id=?1", [&p.id], |r| r.get::<_, i64>(0)).unwrap(), 0);
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
    let e = estimate("local", &r, &PriceSnapshot::deepseek_reference());
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
            (estimate("local", &r, &p).cost.unwrap() - 1.506 * factor).abs() < 1e-10,
            "{time}"
        );
    }
    r.timestamp_ms = None;
    r.date = "2026-11-05".into();
    assert!(estimate("local", &r, &p).cost.is_none());
    r.date = "2026-10-01".into();
    assert_eq!(estimate("local", &r, &p).cost, Some(0.753));
    r.timezone = None;
    assert!(estimate("local", &r, &p).cost.is_none());
    r.timestamp_ms = Some(
        chrono::DateTime::parse_from_rfc3339("2027-11-05T10:00:00+08:00")
            .unwrap()
            .timestamp_millis(),
    );
    assert!(estimate("local", &r, &p).cost.is_none());
    r.provider = "reseller".into();
    assert!(estimate("local", &r, &p).cost.is_none());
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
    assert_eq!(estimate("local", &r, &p).cost, Some(0.3));
}

#[test]
fn bundled_official_prices_work_offline_with_context_speed_and_cache() {
    let p = PriceSnapshot::bundled_reference();
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
    assert!((estimate("local", &r, &p).cost.unwrap() - 1.274).abs() < 1e-10);
    r.metadata["inferenceSpeed"] = serde_json::json!({"speed":"fast"});
    assert!((estimate("local", &r, &p).cost.unwrap() - 2.548).abs() < 1e-10);
    r.metadata["granularity"] = "day".into();
    assert!((estimate("local", &r, &p).cost.unwrap() - 1.324).abs() < 1e-10);
    r.metadata = serde_json::json!({"granularity":"event","cacheWrite1h":100});
    r.provider = "anthropic".into();
    r.model = "claude-opus-4-8".into();
    r.tokens = Tokens {
        input: 1000,
        output: 500,
        cache_write: 100,
        ..Default::default()
    };
    assert!((estimate("local", &r, &p).cost.unwrap() - 0.0185).abs() < 1e-10);
    r.metadata["inferenceSpeed"] = serde_json::json!({"speed":"fast"});
    assert!((estimate("local", &r, &p).cost.unwrap() - 0.037).abs() < 1e-10);
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

#[test]
fn session_totals_do_not_trigger_request_context_tiers_or_hourly_discounts() {
    let mut r = record();
    r.provider = "openai".into();
    r.model = "gpt-6-astra".into();
    r.tokens = Tokens {
        input: 300_000,
        output: 10_000,
        ..Default::default()
    };
    r.metadata = serde_json::json!({"granularity":"sourceRecord"});
    let p = PriceSnapshot::bundled_reference();
    let aggregate = estimate("local", &r, &p).cost.unwrap();
    r.metadata["granularity"] = "day".into();
    assert_eq!(estimate("local", &r, &p).cost, Some(aggregate));
    r.metadata["granularity"] = "event".into();
    assert!(estimate("local", &r, &p).cost.unwrap() > aggregate);

    r.provider = "deepseek".into();
    r.model = "deepseek-flash".into();
    r.timestamp_ms = Some(
        chrono::DateTime::parse_from_rfc3339("2026-11-06T01:00:00+08:00")
            .unwrap()
            .timestamp_millis(),
    );
    r.date = "2026-11-06".into();
    r.metadata["granularity"] = "sourceRecord".into();
    let aggregate = estimate("local", &r, &p).cost;
    r.metadata["granularity"] = "day".into();
    assert_eq!(estimate("local", &r, &p).cost, aggregate);
}

#[test]
fn devin_flash_variants_price_all_token_categories_at_list_rates() {
    let p = PriceSnapshot::bundled_reference();
    p.validate().unwrap();
    let mut r = record();
    r.client = "devin-cli".into();
    r.provider = "devin".into();
    r.metadata = serde_json::json!({"granularity":"sourceRecord"});
    r.tokens = Tokens {
        input: 1_000_000,
        cache_read: 2_000_000,
        cache_write: 3_000_000,
        output: 4_000_000,
        reasoning: 1_000_000,
    };
    for model in [
        "swe-2-flash",
        "swe-2-flash-medium",
        "swe-2-flash-high",
        "swe-2-flash-max",
    ] {
        r.model = model.into();
        let e = estimate("local", &r, &p);
        assert!((e.cost.unwrap() - 2.995).abs() < 1e-12);
        assert!(e.basis.contains("not quota consumption or billing"));
    }
    r.provider = "reseller".into();
    assert!(estimate("local", &r, &p).cost.is_none());
    r.provider = "devin".into();
    r.model = "swe-2-medium".into();
    assert!(estimate("local", &r, &p).cost.is_none());
}

#[test]
fn every_supported_client_uses_shared_prices_and_cached_models_fill_pending_rows() {
    let dir = tempfile::tempdir().unwrap();
    let mut db = Database::open(dir.path()).unwrap();
    tokenory::pricing::initialize(&mut db).unwrap();
    for client in tokenory::clients::CLIENTS {
        let mut r = record();
        r.client = client.as_str().into();
        r.key = r.client.clone();
        r.provider = "openai".into();
        r.model = "gpt-6.1-sol".into();
        tokenory::pricing::assign("local", &mut r, "test", &PriceSnapshot::bundled_reference());
        assert_eq!(r.estimated_cost_usd, Some(0.007), "{}", r.client);
        r.provider = "test".into();
        r.model = "new-model".into();
        r.estimated_cost_usd = None;
        tokenory::db::put_record(&db.connection, "local", "", &r).unwrap();
    }
    let service = tokens_core::pricing::PricingService::new(
        [(
            "test/new-model".into(),
            ModelPricing {
                input_cost_per_token: Some(2e-6),
                output_cost_per_token: Some(8e-6),
                ..Default::default()
            },
        )]
        .into_iter()
        .collect(),
        Default::default(),
    );
    assert!(tokenory::price_coverage::extend_from_service(&mut db, &service).unwrap());
    let count: i64 = db
        .connection
        .query_row(
            "SELECT count(*) FROM usage_records WHERE estimated_cost IS NOT NULL",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(count, tokenory::clients::CLIENTS.len() as i64);
    assert!(!tokenory::price_coverage::extend_from_service(&mut db, &service).unwrap());
    assert!(std::fs::read_dir(dir.path().join("backups"))
        .unwrap()
        .any(|p| p
            .unwrap()
            .file_name()
            .to_string_lossy()
            .contains("price-coverage")));
}

#[test]
fn missing_price_fill_preserves_tokens_source_cost_known_amounts_and_unknown_models() {
    let dir = tempfile::tempdir().unwrap();
    let mut db = Database::open(dir.path()).unwrap();
    let mut pending = record();
    pending.source_cost_usd = Some(3.25);
    tokenory::db::put_record(&db.connection, "import", "batch", &pending).unwrap();
    let mut known = pending.clone();
    known.key = "known".into();
    known.estimated_cost_usd = Some(7.);
    tokenory::db::put_record(&db.connection, "import", "batch", &known).unwrap();
    let mut unknown = pending.clone();
    unknown.key = "unknown".into();
    unknown.provider = "reseller".into();
    tokenory::db::put_record(&db.connection, "import", "batch", &unknown).unwrap();
    let before = tokenory::db::revision(&db.connection).unwrap();
    let id = save_snapshot(&mut db, snapshot(2., 8.)).unwrap();
    let read = |key: &str| -> UsageRecord {
        let body: String = db
            .connection
            .query_row(
                "SELECT body FROM usage_records WHERE item_key=?1",
                [key],
                |r| r.get(0),
            )
            .unwrap();
        serde_json::from_str(&body).unwrap()
    };
    let filled = read("a");
    assert_eq!(filled.estimated_cost_usd, Some(0.006));
    assert_eq!(filled.tokens, pending.tokens);
    assert_eq!(filled.source_cost_usd, pending.source_cost_usd);
    assert_eq!(filled.price_snapshot_id, Some(id));
    assert_eq!(read("known").estimated_cost_usd, Some(7.));
    assert!(read("unknown").estimated_cost_usd.is_none());
    assert!(tokenory::db::revision(&db.connection).unwrap() > before);
}

#[test]
fn namespaced_official_models_use_bundled_rates_without_crossing_provider_boundary() {
    let dir = tempfile::tempdir().unwrap();
    let db = Database::open(dir.path()).unwrap();
    let mut r = record();
    r.provider = "openai".into();
    r.model = "openai/gpt-6.1-sol".into();
    tokenory::db::put_record(&db.connection, "local", "", &r).unwrap();
    let service = tokens_core::pricing::PricingService::new(Default::default(), Default::default());
    let p = tokenory::pricing::snapshot_from_service(&db, &service).unwrap();
    assert_eq!(estimate("local", &r, &p).cost, Some(0.007));
    r.metadata["inferenceSpeed"] = serde_json::json!({"speed":"fast"});
    assert_eq!(estimate("local", &r, &p).cost, Some(0.014));
    r.provider = "reseller".into();
    assert!(estimate("local", &r, &p).cost.is_none());
}

#[test]
fn unknown_providers_use_labeled_first_party_references_without_changing_identity() {
    let dir = tempfile::tempdir().unwrap();
    let db = Database::open(dir.path()).unwrap();
    let service = tokens_core::pricing::PricingService::new(
        [(
            "moonshot/kimi-k2.5".into(),
            ModelPricing {
                input_cost_per_token: Some(0.6e-6),
                output_cost_per_token: Some(3e-6),
                ..Default::default()
            },
        )]
        .into_iter()
        .collect(),
        [("moonshotai/kimi-k2.5".into(), ModelPricing {
            input_cost_per_token: Some(0.5e-6), output_cost_per_token: Some(2.5e-6), ..Default::default()
        })].into_iter().collect(),
    );
    for (i, (provider, model)) in [
        ("_session", "kimi-k2.5"),
        ("moonshotai", "kimi-k2.5"),
        ("unknown", "kimi-k2.5"),
        ("unknown", "gpt-6.1-sol"),
        ("reseller", "gpt-6.1-sol"),
        ("unknown", "openrouter/gpt-6.1-sol"),
        ("unknown", "compactor"),
        ("unknown", "deepseek-flash"),
    ]
    .into_iter()
    .enumerate()
    {
        let mut r = record();
        r.key = i.to_string();
        r.provider = provider.into();
        r.model = model.into();
        tokenory::db::put_record(&db.connection, "local", "", &r).unwrap();
    }
    let p = tokenory::pricing::snapshot_from_service(&db, &service).unwrap();
    p.validate().unwrap();
    for (provider, model, expected) in [
        ("_session", "kimi-k2.5", Some(0.0021)),
        ("unknown", "kimi-k2.5", Some(0.0021)),
        ("unknown", "gpt-6.1-sol", Some(0.007)),
        ("reseller", "gpt-6.1-sol", None),
        ("unknown", "openrouter/gpt-6.1-sol", None),
        ("unknown", "compactor", None),
    ] {
        let mut r = record();
        r.provider = provider.into();
        r.model = model.into();
        let e = estimate("local", &r, &p);
        match expected {
            Some(value) => {
                assert!((e.cost.unwrap() - value).abs() < 1e-12, "{model}");
                assert!(e.basis.contains("Provider unknown"));
            }
            None => assert!(e.cost.is_none(), "{provider}/{model}"),
        }
        assert_eq!(r.provider, provider);
    }
}

#[test]
fn archived_mimo_reference_uses_full_request_tier_but_not_daily_total() {
    let p = PriceSnapshot::bundled_reference();
    for provider in ["xiaomi", "xiaomi-tp"] {
        let mut r = record();
        r.client = "openclaw".into();
        r.provider = provider.into();
        r.model = "mimo-v2-pro".into();
        r.tokens = Tokens {
            input: 250_000,
            cache_read: 10_000,
            output: 1000,
            ..Default::default()
        };
        let time = r.timestamp_ms.unwrap();
        r.key = format!(r#"snapshot:["openclaw","s",["event","openclaw:e1:{time}:250000:1000"]]"#);
        r.metadata = serde_json::json!({"granularity":"sourceRecord","collectionMode":"sessionSnapshot"});
        let event = estimate("local", &r, &p);
        assert!((event.cost.unwrap() - 0.51).abs() < 1e-12, "{provider}");
        assert!(
            event.basis.contains("; long context true; event usage"),
            "{provider}: {}",
            event.basis
        );

        r.metadata = serde_json::json!({"granularity":"day"});
        let daily = estimate("local", &r, &p);
        assert!((daily.cost.unwrap() - 0.255).abs() < 1e-12, "{provider}");
        assert!(
            daily.basis.contains("; long context false; aggregate at base rates"),
            "{provider}: {}",
            daily.basis
        );
    }
}

#[test]
fn missing_category_rate_does_not_block_other_records_of_the_same_model() {
    let dir = tempfile::tempdir().unwrap();
    let db = Database::open(dir.path()).unwrap();
    let mut r = record();
    r.provider = "test".into();
    r.model = "model-a".into();
    tokenory::db::put_record(&db.connection, "local", "", &r).unwrap();
    let mut incomplete = r.clone();
    incomplete.key = "cache-write".into();
    incomplete.tokens.cache_write = 100;
    tokenory::db::put_record(&db.connection, "local", "", &incomplete).unwrap();
    let service = tokens_core::pricing::PricingService::new(
        [(
            "test/model-a".into(),
            ModelPricing {
                input_cost_per_token: Some(2e-6),
                output_cost_per_token: Some(8e-6),
                ..Default::default()
            },
        )]
        .into_iter()
        .collect(),
        Default::default(),
    );
    let p = tokenory::pricing::snapshot_from_service(&db, &service).unwrap();
    assert_eq!(estimate("local", &r, &p).cost, Some(0.006));
    assert_eq!(
        estimate("local", &incomplete, &p).reason.as_deref(),
        Some("a populated token category has no rate")
    );
}

#[test]
fn devin_compactor_reference_fills_missing_cost_without_renaming_the_model() {
    let dir = tempfile::tempdir().unwrap();
    let mut db = Database::open(dir.path()).unwrap();
    let mut r = record();
    r.client = "devin-cli".into(); r.provider = "devin".into(); r.model = "compactor".into();
    r.tokens = Tokens { input: 71_232, output: 5_038, ..Default::default() };
    tokenory::db::put_record(&db.connection, "local", "", &r).unwrap();
    tokenory::pricing::initialize(&mut db).unwrap();
    let body: String = db.connection.query_row("SELECT body FROM usage_records WHERE item_key='a'", [], |row| row.get(0)).unwrap();
    let updated: UsageRecord = serde_json::from_str(&body).unwrap();
    assert!((updated.estimated_cost_usd.unwrap() - 0.0096422).abs() < 1e-12);
    assert_eq!(updated.model, "compactor");
    assert_eq!(updated.tokens, r.tokens);
    assert!(updated.cost_basis.as_deref().unwrap().contains("User-selected reference estimate"));
    assert!(updated.cost_basis.as_deref().unwrap().contains("unconfirmed"));
    let p = PriceSnapshot::bundled_reference();
    r.client = "other-agent".into();
    assert!(estimate("local", &r, &p).cost.is_none());
    r.client = "devin-cli".into(); r.provider = "unknown".into();
    assert!(estimate("local", &r, &p).cost.is_none());
}

#[test]
fn remote_catalog_reprices_only_pending_rows_and_survives_offline_refresh() {
    use tokenory::pricing::{active_snapshot, load_snapshot};
    use tokenory::remote_pricing::{apply_refresh, Feed};
    use tokens_core::pricing::PricingService;

    let dir = tempfile::tempdir().unwrap();
    let mut db = Database::open(dir.path()).unwrap();
    tokenory::pricing::initialize(&mut db).unwrap();
    let (old_id, _) = active_snapshot(&db.connection).unwrap().unwrap();

    let mut new = record();
    new.provider = "openai".into();
    new.model = "gpt-remote-fixture".into();
    let mut existing = new.clone();
    existing.key = "b".into();
    existing.model = "gpt-6.2-sol".into();
    existing.estimated_cost_usd = Some(0.007);
    let preview = preview_records(
        &mut db, "test", b"remote-fee", vec![new.clone(), existing.clone()],
        Some("Asia/Shanghai".into()),
    ).unwrap();
    apply_import(&mut db, &preview.id, &ApplyOptions::default()).unwrap();

    let mut data: serde_json::Value =
        serde_json::from_str(include_str!("../data/remote-pricing.json")).unwrap();
    let mut new_model = data["entries"][1].clone();
    new_model["model"] = "gpt-remote-fixture".into();
    data["entries"].as_array_mut().unwrap().push(new_model);
    data["entries"][1]["standard"]["output"] = 20.into();
    data["effectiveAt"] = "2020-01-01T00:00:00Z".into();
    // Set a historical cutoff to exercise scheduled rates without a wall-clock dependency.
    data["entries"][2]["ultrafastChange"]["effectiveAt"] = "2020-02-01T00:00:00Z".into();
    let parse = |data: &serde_json::Value| Feed::parse(&serde_json::to_vec(data).unwrap());
    let upstream = PricingService::new(Default::default(), Default::default());
    let new_id = apply_refresh(&mut db, &upstream, Some(parse(&data).unwrap())).unwrap();
    let applied = load_snapshot(&db.connection, &new_id).unwrap();
    let old = load_snapshot(&db.connection, &old_id).unwrap();
    assert!((estimate("test", &existing, &old).cost.unwrap() - 0.007).abs() < 1e-12);
    assert!((estimate("test", &existing, &applied).cost.unwrap() - 0.012).abs() < 1e-12);

    let stored = |db: &Database, key: &str| -> f64 {
        db.connection.query_row(
            "SELECT estimated_cost FROM usage_records WHERE json_extract(body,'$.key') = ?1",
            [key], |row| row.get(0),
        ).unwrap()
    };
    assert!((stored(&db, "a") - 0.007).abs() < 1e-12);
    assert!((stored(&db, "b") - 0.007).abs() < 1e-12);

    new.metadata["inferenceSpeed"] = serde_json::json!({"speed": "ultrafast"});
    new.tokens = Tokens { input: 300_000, output: 10_000, ..Default::default() };
    assert!((estimate("test", &new, &applied).cost.unwrap() - 8.1).abs() < 1e-12);

    drop(db);
    let mut db = Database::open(dir.path()).unwrap();
    let offline_id = apply_refresh(&mut db, &upstream, None).unwrap();
    let offline = load_snapshot(&db.connection, &offline_id).unwrap();
    assert_eq!(estimate("test", &new, &applied).cost, estimate("test", &new, &offline).cost);

    data["entries"][1]["standard"]["output"] = 100.into();
    let repeated_id = apply_refresh(&mut db, &upstream, Some(parse(&data).unwrap())).unwrap();
    let repeated = load_snapshot(&db.connection, &repeated_id).unwrap();
    assert_eq!(estimate("test", &existing, &applied).cost, estimate("test", &existing, &repeated).cost);

    data["entries"][1]["standard"]["output"] = (-1).into();
    assert!(parse(&data).is_err());
    data["entries"][1] = data["entries"][0].clone();
    assert!(parse(&data).is_err());
}

#[test]
fn openclaw_pricing_requires_a_matching_native_event_time() {
    let mut r = record();
    r.client = "openclaw".into();
    r.provider = "deepseek".into();
    r.model = "deepseek-v4-flash".into();
    r.date = "2026-11-05".into();
    r.timezone = Some("Asia/Shanghai".into());
    r.metadata = serde_json::json!({"granularity":"sourceRecord","collectionMode":"sessionSnapshot"});
    r.tokens = Tokens { input: 1_000_000, output: 1_000_000, ..Default::default() };
    let p = PriceSnapshot::bundled_reference();
    for (utc, expected) in [("2026-11-05T01:00:00Z", 1.5), ("2026-11-05T04:00:00Z", 0.75)] {
        let time = chrono::DateTime::parse_from_rfc3339(utc).unwrap().timestamp_millis();
        r.timestamp_ms = Some(time);
        r.key = format!(r#"snapshot:["openclaw","session",["event","openclaw:e1:{time}:1000000:1000000"]]"#);
        assert_eq!(estimate("local", &r, &p).cost, Some(expected));
        assert!(estimate("tokens-ci", &r, &p).cost.is_none());
        r.key = r#"snapshot:["openclaw","session",["event","openclaw:e1:1000000:1000000"]]"#.into();
        assert!(estimate("local", &r, &p).cost.is_none());
        r.key = format!(r#"snapshot:["openclaw","session",["event","openclaw:e1:{time}:1000000:999"]]"#);
        assert!(estimate("local", &r, &p).cost.is_none());
    }
}

#[test]
fn previous_catalog_repairs_only_missing_amounts_and_keeps_active_prices() {
    let t = tempfile::tempdir().unwrap();
    let mut db = Database::open(t.path()).unwrap();
    let mut old = PriceSnapshot::deepseek_reference();
    old.entries[0].rates.output_cost_per_token = Some(9e-6);
    let old_id = save_snapshot(&mut db, old).unwrap();
    db.connection.execute("INSERT OR REPLACE INTO app_state(key,value) VALUES ('officialCatalog','2026-11-20-codex-review-reference-v1')", []).unwrap();
    let mut r = record();
    r.client = "openclaw".into();
    r.provider = "xiaomi-tp".into();
    r.source_cost_usd = Some(23.);
    r.tokens = Tokens { input: 1_000_000, output: 1_000_000, cache_read: 1_000_000, ..Default::default() };
    r.metadata = serde_json::json!({"granularity":"sourceRecord","collectionMode":"sessionSnapshot"});
    let time = r.timestamp_ms.unwrap();
    for (n, model) in ["mimo-v2-pro", "mimo-v2.5-pro", "stepfun/step-3.5-flash :free",
                       "stepfun/step-3.5-flash", "mimo-v2.5-pro"].into_iter().enumerate() {
        r.provider = if n == 2 || n == 3 { "openrouter" } else { "xiaomi-tp" }.into();
        r.model = model.into();
        r.key = format!(r#"snapshot:["openclaw","s",["event","openclaw:{n}:{time}:1000000:1000000"]]"#);
        if n == 4 { r.estimated_cost_usd = Some(123.); }
        tokenory::db::put_record(&db.connection,"local","",&r).unwrap();
    }
    tokenory::pricing::initialize(&mut db).unwrap();
    let costs: Vec<Option<f64>> = db.connection.prepare("SELECT estimated_cost FROM usage_records ORDER BY item_key")
        .unwrap().query_map([], |r| r.get(0)).unwrap().collect::<Result<_,_>>().unwrap();
    assert!((costs[0].unwrap() - 8.4).abs() < 1e-10);
    assert!((costs[1].unwrap() - 1.3086).abs() < 1e-10);
    assert_eq!(&costs[2..], &[Some(0.), None, Some(123.)]);
    let unchanged: i64 = db.connection.query_row("SELECT count(*) FROM usage_records WHERE source_cost=23", [], |r|r.get(0)).unwrap();
    assert_eq!(unchanged, 5);
    assert!(tokenory::pricing::load_snapshot(&db.connection, &old_id).is_ok());
    let active = tokenory::pricing::active_snapshot(&db.connection).unwrap().unwrap();
    assert_eq!(active.1.entries[0].rates.output_cost_per_token, Some(9e-6));
    assert!(std::fs::read_dir(t.path().join("backups")).unwrap().flatten().any(|e| e.file_name().to_string_lossy().contains("price-coverage")));
    tokenory::pricing::initialize(&mut db).unwrap();
    assert_eq!(tokenory::pricing::active_snapshot(&db.connection).unwrap().unwrap().0, active.0);
}
