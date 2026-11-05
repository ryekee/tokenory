use tokenory::{
    db::Database,
    import::{apply_import, preview_import, ApplyOptions},
    queries::{report, Filter},
};
#[test]
fn valid_backup_restores_usage_and_corrupt_backup_keeps_current_database() {
    let root = tempfile::tempdir().unwrap();
    let mut db = Database::open(&root.path().join("db")).unwrap();
    let rows=br#"[{"date":"2026-04-08","app_type":"claude","provider_id":"test","model":"a","request_count":1,"input_tokens":100,"output_tokens":0,"cache_read_tokens":0,"cache_creation_tokens":0,"total_cost_usd":"0","input_token_semantics":0}]"#;
    let p = preview_import(&mut db, "cc-switch", rows, Some("Asia/Shanghai".into())).unwrap();
    apply_import(&mut db, &p.id, &ApplyOptions::default()).unwrap();
    let backup = root.path().join("backup.sqlite3");
    db.backup(&backup).unwrap();
    let mut restored = Database::open(&root.path().join("restored")).unwrap();
    restored.restore(&backup).unwrap();
    assert_eq!(
        report(&mut restored, &Filter::default())
            .unwrap()
            .summary
            .tokens,
        100
    );
    let bad = root.path().join("bad.sqlite3");
    std::fs::write(&bad, b"broken SQLite").unwrap();
    assert!(restored.restore(&bad).is_err());
    assert_eq!(
        report(&mut restored, &Filter::default())
            .unwrap()
            .summary
            .tokens,
        100
    );
    let future = root.path().join("future.sqlite3");
    std::fs::copy(&backup, &future).unwrap();
    rusqlite::Connection::open(&future)
        .unwrap()
        .execute_batch("PRAGMA user_version=99;")
        .unwrap();
    assert!(restored.restore(&future).is_err());
    assert_eq!(
        report(&mut restored, &Filter::default())
            .unwrap()
            .summary
            .tokens,
        100
    );
}
