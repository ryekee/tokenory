use serde_json::json;
use tokenory::{
    db::Database,
    import::{apply_import, preview_import, preview_records, undo_import, ApplyOptions},
    queries::{report, Filter},
};
#[test]
fn overlapping_sources_require_a_choice_and_are_never_added() {
    let t = tempfile::tempdir().unwrap();
    let mut db = Database::open(t.path()).unwrap();
    let data=serde_json::to_vec(&json!([{"date":"2026-04-08","app_type":"claude","provider_id":"a","model":"m","request_count":1,"input_tokens":100,"output_tokens":0,"cache_read_tokens":0,"cache_creation_tokens":0,"total_cost_usd":"0","input_token_semantics":0}])).unwrap();
    let p = preview_import(&mut db, "cc-switch", &data, Some("Asia/Shanghai".into())).unwrap();
    apply_import(&mut db, &p.id, &ApplyOptions::default()).unwrap();
    let mut row = report(&mut db, &Filter::default()).unwrap().details[0]
        .record
        .clone();
    row.tokens.input = 60;
    let p = preview_records(
        &mut db,
        "test-other",
        b"other",
        vec![row],
        Some("Asia/Shanghai".into()),
    )
    .unwrap();
    assert_eq!(p.conflicts.len(), 1);
    assert!(apply_import(&mut db, &p.id, &ApplyOptions::default()).is_err());
    let b = apply_import(
        &mut db,
        &p.id,
        &ApplyOptions {
            replace_conflicts: true,
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(
        report(&mut db, &Filter::default()).unwrap().summary.tokens,
        60
    );
    undo_import(&mut db, &b.batch_id).unwrap();
    assert_eq!(
        report(&mut db, &Filter::default()).unwrap().summary.tokens,
        100
    );
}
#[test]
fn replacement_range_includes_days_missing_from_incoming_snapshot() {
    use tokenory::usage::{Tokens, UsageRecord};
    let root = tempfile::tempdir().unwrap();
    let mut db = Database::open(root.path()).unwrap();
    let make = |day: &str, tokens| UsageRecord {
        key: day.into(),
        client: "claude".into(),
        provider: "test".into(),
        model: "test".into(),
        date: day.into(),
        timezone: Some("Asia/Shanghai".into()),
        timestamp_ms: None,
        session_id: None,
        tokens: Tokens {
            input: tokens,
            ..Default::default()
        },
        requests: None,
        source_cost_usd: None,
        estimated_cost_usd: None,
        cost_basis: None,
        price_snapshot_id: None,
        metadata: serde_json::json!({}),
    };
    let p = preview_records(
        &mut db,
        "first",
        b"first",
        vec![make("2026-01-02", 100)],
        Some("Asia/Shanghai".into()),
    )
    .unwrap();
    apply_import(&mut db, &p.id, &ApplyOptions::default()).unwrap();
    let p = preview_records(
        &mut db,
        "second",
        b"second",
        vec![make("2026-01-01", 10), make("2026-01-03", 10)],
        Some("Asia/Shanghai".into()),
    )
    .unwrap();
    assert_eq!(p.conflicts.len(), 1);
    apply_import(
        &mut db,
        &p.id,
        &ApplyOptions {
            replace_conflicts: true,
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(
        report(&mut db, &Filter::default()).unwrap().summary.tokens,
        20
    );
}
fn cell(date: &str, client: &str, tokens: i64) -> tokenory::usage::UsageRecord {
    serde_json::from_value(json!({"key":format!("{client}:{date}"),"client":client,"provider":"test","model":"m","date":date,"tokens":{"input":tokens,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0}})).unwrap()
}
#[test]
fn each_client_has_its_own_snapshot_coverage_span() {
    let root = tempfile::tempdir().unwrap();
    let mut db = Database::open(root.path()).unwrap();
    let p = preview_records(
        &mut db,
        "old",
        b"old",
        vec![cell("2026-04-08", "claude", 100)],
        None,
    )
    .unwrap();
    apply_import(
        &mut db,
        &p.id,
        &ApplyOptions {
            accept_original_dates: true,
            ..Default::default()
        },
    )
    .unwrap();
    let p = preview_records(
        &mut db,
        "new",
        b"new",
        vec![
            cell("2026-01-01", "codex", 10),
            cell("2026-09-01", "claude", 20),
        ],
        None,
    )
    .unwrap();
    assert!(p.conflicts.is_empty());
    apply_import(
        &mut db,
        &p.id,
        &ApplyOptions {
            accept_original_dates: true,
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(
        report(&mut db, &Filter::default()).unwrap().summary.tokens,
        130
    );
}
#[test]
fn newly_collected_day_inside_preview_range_requires_a_new_preview() {
    let root = tempfile::tempdir().unwrap();
    let mut db = Database::open(root.path()).unwrap();
    let p = preview_records(
        &mut db,
        "history",
        b"history",
        vec![
            cell("2026-01-01", "codex", 10),
            cell("2026-01-03", "codex", 20),
        ],
        None,
    )
    .unwrap();
    let q = preview_records(
        &mut db,
        "local",
        b"new-event",
        vec![cell("2026-01-02", "codex", 5)],
        None,
    )
    .unwrap();
    apply_import(
        &mut db,
        &q.id,
        &ApplyOptions {
            accept_original_dates: true,
            ..Default::default()
        },
    )
    .unwrap();
    assert!(apply_import(
        &mut db,
        &p.id,
        &ApplyOptions {
            accept_original_dates: true,
            ..Default::default()
        }
    )
    .is_err());
    assert_eq!(
        report(&mut db, &Filter::default()).unwrap().summary.tokens,
        5
    );
}
