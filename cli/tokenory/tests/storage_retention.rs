use tokenory::{
    db::{next_preview_id, prune_previews, Database},
    import::{apply_import, preview_import, ApplyOptions},
    queries::{report, Filter},
};

#[test]
fn rotates_only_recognized_automatic_backups_and_keeps_manual_files() {
    let dir = tempfile::tempdir().unwrap();
    let db = Database::open(dir.path()).unwrap();
    let backups = dir.path().join("backups");
    std::fs::create_dir_all(&backups).unwrap();
    for day in 1..=5 {
        db.backup(&backups.join(format!("202601{day:02}T000000.000000000-reprice.sqlite3")))
            .unwrap();
    }
    for name in [
        "my-backup.sqlite3",
        "20261105-before-uiux.sqlite3",
        "20260101T000000.000000000-custom.sqlite3",
        "20260199T000000.000000000-reprice.sqlite3",
    ] {
        std::fs::write(backups.join(name), b"manual").unwrap();
    }
    db.prune_automatic_backups().unwrap();
    assert!(!backups
        .join("20260101T000000.000000000-reprice.sqlite3")
        .exists());
    assert!(backups
        .join("20260103T000000.000000000-reprice.sqlite3")
        .exists());
    assert_eq!(std::fs::read_dir(&backups).unwrap().count(), 7);
    assert_eq!(
        std::fs::read(backups.join("my-backup.sqlite3")).unwrap(),
        b"manual"
    );
    db.backup_before("import").unwrap();
    assert!(!backups
        .join("20260103T000000.000000000-reprice.sqlite3")
        .exists());
    assert_eq!(std::fs::read_dir(&backups).unwrap().count(), 7);
}

#[test]
fn expires_and_caps_previews_without_reusing_deleted_ids() {
    let dir = tempfile::tempdir().unwrap();
    let db = Database::open(dir.path()).unwrap();
    for table in ["reprice_previews", "import_previews"] {
        for id in 1..=5 {
            let body =
                serde_json::json!({"created_at": chrono::Utc::now().timestamp()}).to_string();
            if table == "reprice_previews" {
                db.connection
                    .execute(
                        "INSERT INTO reprice_previews(id,body) VALUES (?1,?2)",
                        rusqlite::params![id, body],
                    )
                    .unwrap();
            } else {
                db.connection.execute("INSERT INTO import_previews(id,source,content_hash,body) VALUES (?1,'test','test',?2)", rusqlite::params![id, body]).unwrap();
            }
        }
    }
    let reserved = next_preview_id(&db.connection).unwrap();
    prune_previews(&db.connection).unwrap();
    for table in ["reprice_previews", "import_previews"] {
        assert_eq!(
            db.connection
                .query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r
                    .get::<_, i64>(0))
                .unwrap(),
            3
        );
        db.connection
            .execute(
                &format!("UPDATE {table} SET body=json_set(body,'$.created_at',unixepoch()-86401)"),
                [],
            )
            .unwrap();
    }
    prune_previews(&db.connection).unwrap();
    assert_eq!(db.connection.query_row("SELECT (SELECT count(*) FROM reprice_previews)+(SELECT count(*) FROM import_previews)", [], |r| r.get::<_, i64>(0)).unwrap(), 0);
    assert!(next_preview_id(&db.connection).unwrap() > reserved);
}

#[test]
fn consumed_import_is_removed_but_ledger_and_undo_history_survive_compaction() {
    let root = tempfile::tempdir().unwrap();
    let mut db = Database::open(root.path()).unwrap();
    let rows=br#"[{"date":"2026-04-08","app_type":"claude","provider_id":"test","model":"a","request_count":1,"input_tokens":100,"output_tokens":0,"cache_read_tokens":0,"cache_creation_tokens":0,"total_cost_usd":"0","input_token_semantics":0}]"#;
    let p = preview_import(&mut db, "cc-switch", rows, Some("Asia/Shanghai".into())).unwrap();
    apply_import(&mut db, &p.id, &ApplyOptions::default()).unwrap();
    assert_eq!(
        db.connection
            .query_row("SELECT count(*) FROM import_previews", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
        0
    );
    let next = preview_import(&mut db, "cc-switch", rows, Some("Asia/Shanghai".into())).unwrap();
    assert_ne!(p.id, next.id);
    assert!(apply_import(&mut db, &p.id, &ApplyOptions::default()).is_err());
    db.connection.execute_batch("VACUUM;").unwrap();
    assert_eq!(
        report(&mut db, &Filter::default()).unwrap().summary.tokens,
        100
    );
    assert_eq!(
        db.connection
            .query_row("SELECT count(*) FROM import_batches", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
        1
    );
}

#[test]
fn contiguous_migrations_create_one_backup() {
    let root = tempfile::tempdir().unwrap();
    let db = Database::open(root.path()).unwrap();
    db.connection
        .execute_batch("DROP TABLE codex_turns; PRAGMA user_version=3;")
        .unwrap();
    drop(db);
    let _db = Database::open(root.path()).unwrap();
    assert_eq!(
        std::fs::read_dir(root.path().join("backups"))
            .unwrap()
            .count(),
        1
    );
}
