use serde_json::json;
use tokenory::{
    db::Database,
    import::{apply_import, preview_import, ApplyOptions},
    queries::{report, Filter},
};
fn snapshot() -> serde_json::Value {
    json!({"updatedAt":"2026-11-05T03:00:00Z","stats":{"totalTokens":100,"inputTokens":40,"outputTokens":10,"cacheReadTokens":45,"cacheWriteTokens":0,"reasoningTokens":5,"activeDays":1},"modelUsage":[{"model":"test-model","tokens":100}],"contributions":[{"date":"2026-01-01","totals":{"tokens":100,"cost":1.0},"tokenBreakdown":{"input":40,"output":10,"cacheRead":45,"cacheWrite":0,"reasoning":5},"clients":[{"client":"copilot","tokens":{"input":40,"output":10,"cacheRead":45,"cacheWrite":0,"reasoning":5},"models":{"test-model":{"tokens":100,"input":40,"output":10,"cacheRead":45,"cacheWrite":0,"reasoning":5,"cost":1.0,"messages":3}}}]}]})
}
#[test]
fn profile_uses_cells_once_and_rejects_disagreeing_totals() {
    let temp = tempfile::tempdir().unwrap();
    let mut db = Database::open(temp.path()).unwrap();
    let data = serde_json::to_vec(&snapshot()).unwrap();
    let p = preview_import(&mut db, "tokens-ci", &data, None).unwrap();
    apply_import(
        &mut db,
        &p.id,
        &ApplyOptions {
            accept_original_dates: true,
            ..Default::default()
        },
    )
    .unwrap();
    let p = preview_import(&mut db, "tokens-ci", &data, None).unwrap();
    assert!(
        apply_import(&mut db, &p.id, &ApplyOptions::default())
            .unwrap()
            .already_imported
    );
    assert_eq!(
        report(&mut db, &Filter::default()).unwrap().summary.tokens,
        100
    );
    for (field, value) in [
        ("stats", json!({"totalTokens":101})),
        ("modelUsage", json!([{"model":"test-model","tokens":101}])),
    ] {
        let mut data = snapshot();
        data[field] = value;
        assert!(preview_import(
            &mut db,
            "tokens-ci",
            &serde_json::to_vec(&data).unwrap(),
            None
        )
        .is_err());
    }
    let mut data = snapshot();
    data["contributions"][0]["clients"][0]["models"]["test-model"]["cacheRead"] = 46.into();
    assert!(preview_import(
        &mut db,
        "tokens-ci",
        &serde_json::to_vec(&data).unwrap(),
        None
    )
    .is_err());
}
#[test]
fn snapshot_day_is_marked_partial_and_requires_explicit_acceptance() {
    let temp = tempfile::tempdir().unwrap();
    let mut db = Database::open(temp.path()).unwrap();
    let mut data = snapshot();
    data["contributions"][0]["date"] = "2026-11-05".into();
    let p = preview_import(
        &mut db,
        "tokens-ci",
        &serde_json::to_vec(&data).unwrap(),
        None,
    )
    .unwrap();
    assert!(p.partial_dates.contains(&"2026-11-05".into()));
    assert!(apply_import(
        &mut db,
        &p.id,
        &ApplyOptions {
            accept_original_dates: true,
            ..Default::default()
        }
    )
    .is_err());
}
#[test]
fn zero_usage_cells_may_be_omitted_from_profile_model_summary() {
    let root = tempfile::tempdir().unwrap();
    let mut db = Database::open(root.path()).unwrap();
    let mut data = snapshot();
    data["contributions"][0]["clients"][0]["models"]["<synthetic>"] = json!({"tokens":0,"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"reasoning":0,"cost":0,"messages":0});
    assert_eq!(
        preview_import(
            &mut db,
            "tokens-ci",
            &serde_json::to_vec(&data).unwrap(),
            None
        )
        .unwrap()
        .tokens,
        100
    );
}
#[test]
fn accepted_incomplete_snapshot_remains_visible_in_the_report() {
    let root = tempfile::tempdir().unwrap();
    let mut db = Database::open(root.path()).unwrap();
    let mut data = snapshot();
    data["contributions"][0]["date"] = "2026-11-05".into();
    let p = preview_import(
        &mut db,
        "tokens-ci",
        &serde_json::to_vec(&data).unwrap(),
        None,
    )
    .unwrap();
    apply_import(
        &mut db,
        &p.id,
        &ApplyOptions {
            accept_original_dates: true,
            accept_partial_dates: true,
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(
        report(&mut db, &Filter::default())
            .unwrap()
            .summary
            .partial_days,
        1
    );
}
