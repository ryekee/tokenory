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
