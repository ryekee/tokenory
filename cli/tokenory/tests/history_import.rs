use serde_json::json;
use tokenory::{
    db::Database,
    import::{apply_import, preview_import, undo_import, ApplyOptions},
    queries::{report, Filter},
};

fn row(date: &str, model: &str, input: i64) -> serde_json::Value {
    json!({"date":date,"app_type":"claude","provider_id":"test-provider","model":model,"request_model":model,"pricing_model":model,"request_count":1,"success_count":1,"input_tokens":input,"output_tokens":20,"cache_read_tokens":600,"cache_creation_tokens":0,"total_cost_usd":"0.25","input_token_semantics":2})
}
fn import(db: &mut Database, rows: serde_json::Value) -> String {
    let p = preview_import(
        db,
        "cc-switch",
        &serde_json::to_vec(&rows).unwrap(),
        Some("Asia/Shanghai".into()),
    )
    .unwrap();
    apply_import(db, &p.id, &ApplyOptions::default())
        .unwrap()
        .batch_id
}
#[test]
fn tokens_ci_review_import_counts_all_tokens_and_keeps_the_source_estimate() {
    let t = tempfile::tempdir().unwrap();
    let mut db = Database::open(t.path()).unwrap();
    tokenory::pricing::initialize(&mut db).unwrap();
    let buckets = json!({"input":100,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0});
    let cell = |cost| json!({"tokens":50,"input":50,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0,"cost":cost,"messages":1});
    let export = json!({
        "stats":{"totalTokens":100,"inputTokens":100,"outputTokens":0,"cacheReadTokens":0,"cacheWriteTokens":0,"reasoningTokens":0,"activeDays":1},
        "modelUsage":[{"model":"codex-auto-review","tokens":50},{"model":"unknown-model","tokens":50}],
        "updatedAt":"2026-11-04T12:00:00Z","contributions":[{"date":"2026-11-03","totals":{"tokens":100},
            "tokenBreakdown":buckets,"clients":[{"client":"codex","tokens":buckets,"models":{
                "codex-auto-review":cell(0.12),"unknown-model":cell(0.)
            }}]}]
    });
    let p = preview_import(
        &mut db,
        "tokens-ci",
        &serde_json::to_vec(&export).unwrap(),
        Some("Asia/Shanghai".into()),
    )
    .unwrap();
    assert_eq!((p.tokens, p.unpriced_tokens), (100, 50));
    apply_import(&mut db, &p.id, &ApplyOptions::default()).unwrap();
    let report = report(&mut db, &Filter::default()).unwrap();
    assert_eq!(
        (report.summary.tokens, report.summary.unpriced_tokens),
        (100, 50)
    );
    assert_eq!(report.summary.cost_status, "partial");
    assert_eq!(report.summary.known_estimated_cost_usd, Some(0.12));
    let review = &report
        .details
        .iter()
        .find(|d| d.record.model == "codex-auto-review")
        .unwrap()
        .record;
    assert_eq!(review.provider, "unknown");
    assert_eq!(review.source_cost_usd, Some(0.12));
    assert!(review.price_snapshot_id.is_some());
}
#[test]
fn duplicate_import_does_not_add_usage() {
    let t = tempfile::tempdir().unwrap();
    let mut db = Database::open(t.path()).unwrap();
    let rows = json!([row("2026-04-08", "model-a", 400)]);
    import(&mut db, rows.clone());
    import(&mut db, rows);
    let r = report(&mut db, &Filter::default()).unwrap();
    assert_eq!(r.summary.tokens, 1020);
    assert_eq!(r.daily[0].summary.tokens, 1020);
    assert_eq!(r.models[0].summary.tokens, 1020);
    assert_eq!(r.summary.known_estimated_cost_usd, None);
}
#[test]
fn corrected_snapshot_replaces_models_and_undo_restores_them() {
    let t = tempfile::tempdir().unwrap();
    let mut db = Database::open(t.path()).unwrap();
    import(
        &mut db,
        json!([
            row("2026-04-08", "model-a", 100),
            row("2026-04-08", "model-b", 100)
        ]),
    );
    let second = import(&mut db, json!([row("2026-04-08", "model-a", 50)]));
    assert_eq!(
        report(&mut db, &Filter::default()).unwrap().summary.tokens,
        670
    );
    undo_import(&mut db, &second).unwrap();
    assert_eq!(
        report(&mut db, &Filter::default()).unwrap().summary.tokens,
        1440
    );
}
#[test]
fn negative_or_fractional_tokens_and_bad_dates_are_rejected() {
    let t = tempfile::tempdir().unwrap();
    let mut db = Database::open(t.path()).unwrap();
    for rows in [
        json!([row("2026-02-30", "a", 1)]),
        json!([row("2026-04-08", "a", -1)]),
        json!([{"date":"2026-04-08","input_tokens":0.5}]),
    ] {
        assert!(preview_import(
            &mut db,
            "cc-switch",
            &serde_json::to_vec(&rows).unwrap(),
            None
        )
        .is_err());
    }
    assert_eq!(
        report(&mut db, &Filter::default()).unwrap().summary.tokens,
        0
    );
}
#[test]
fn historical_dates_require_explicit_acceptance_when_timezone_unknown() {
    let t = tempfile::tempdir().unwrap();
    let mut db = Database::open(t.path()).unwrap();
    let p = preview_import(
        &mut db,
        "cc-switch",
        &serde_json::to_vec(&json!([row("2026-04-08", "a", 1)])).unwrap(),
        None,
    )
    .unwrap();
    assert!(apply_import(&mut db, &p.id, &ApplyOptions::default()).is_err());
    let opts = ApplyOptions {
        accept_original_dates: true,
        ..Default::default()
    };
    assert!(apply_import(&mut db, &p.id, &opts).is_ok());
}
#[test]
fn stale_preview_and_dependent_undo_are_rejected_without_data_loss() {
    let t = tempfile::tempdir().unwrap();
    let mut db = Database::open(t.path()).unwrap();
    let first = import(&mut db, json!([row("2026-04-08", "a", 100)]));
    let p = preview_import(
        &mut db,
        "cc-switch",
        &serde_json::to_vec(&json!([row("2026-04-08", "a", 110)])).unwrap(),
        Some("Asia/Shanghai".into()),
    )
    .unwrap();
    import(&mut db, json!([row("2026-04-08", "a", 120)]));
    assert!(apply_import(&mut db, &p.id, &ApplyOptions::default()).is_err());
    assert!(undo_import(&mut db, &first).is_err());
    assert_eq!(
        report(&mut db, &Filter::default()).unwrap().summary.tokens,
        740
    );
}
