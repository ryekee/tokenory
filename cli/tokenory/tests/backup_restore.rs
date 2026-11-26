// [INPUT]: Temporary ledgers and SQLite backup files across schema versions.
// [OUTPUT]: Coverage for backup recovery, schema upgrades and preservation of subagent evidence.
use rusqlite::Connection;
use tokenory::{
    db::{advance_revision, revision, Database},
    import::{apply_import, preview_import, ApplyOptions},
    queries::{report, Filter},
};

fn import_usage(db: &mut Database) {
    let rows = br#"[{"date":"2026-04-08","app_type":"claude","provider_id":"test","model":"a","request_count":1,"input_tokens":100,"output_tokens":0,"cache_read_tokens":0,"cache_creation_tokens":0,"total_cost_usd":"0","input_token_semantics":0}]"#;
    let preview = preview_import(db, "cc-switch", rows, Some("Asia/Shanghai".into())).unwrap();
    apply_import(db, &preview.id, &ApplyOptions::default()).unwrap();
}

fn schema_version(connection: &Connection) -> i64 {
    connection
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .unwrap()
}

type SavedSpawn = (String, String, String, Option<String>, Option<i64>);

fn antigravity_evidence(connection: &Connection) -> Vec<SavedSpawn> {
    let mut statement = connection
        .prepare("SELECT client,child_id,parent_id,name,started_ms FROM antigravity_subagent_spawns ORDER BY client,child_id")
        .unwrap();
    statement
        .query_map([], |row| {
            Ok((
                row.get(0)?,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
            ))
        })
        .unwrap()
        .collect::<rusqlite::Result<Vec<_>>>()
        .unwrap()
}

#[test]
fn restoring_an_older_backup_advances_the_current_ledger_revision() {
    let root = tempfile::tempdir().unwrap();
    let mut db = Database::open(&root.path().join("ledger")).unwrap();
    let backup = root.path().join("backup.sqlite3");
    db.backup(&backup).unwrap();
    let before = advance_revision(&db.connection).unwrap();

    db.restore(&backup).unwrap();

    assert_eq!(revision(&db.connection).unwrap(), before + 1);
}

#[test]
fn schema_six_upgrade_keeps_a_restorable_pre_upgrade_backup() {
    let root = tempfile::tempdir().unwrap();
    let directory = root.path().join("ledger");
    let mut legacy = Database::open(&directory).unwrap();
    import_usage(&mut legacy);
    let legacy_revision = revision(&legacy.connection).unwrap();
    legacy
        .connection
        .execute_batch("DROP TABLE antigravity_subagent_spawns; PRAGMA user_version=6;")
        .unwrap();
    drop(legacy);

    let upgraded = Database::open(&directory).unwrap();
    assert_eq!(schema_version(&upgraded.connection), 7);
    assert_eq!(revision(&upgraded.connection).unwrap(), legacy_revision);
    assert!(antigravity_evidence(&upgraded.connection).is_empty());

    let backups: Vec<_> = std::fs::read_dir(directory.join("backups"))
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| path.to_string_lossy().ends_with("-schema-7.sqlite3"))
        .collect();
    assert_eq!(backups.len(), 1);
    let backup_path = &backups[0];
    let backup = Connection::open(backup_path).unwrap();
    assert_eq!(schema_version(&backup), 6);
    assert_eq!(revision(&backup).unwrap(), legacy_revision);
    assert!(backup
        .prepare("SELECT child_id FROM antigravity_subagent_spawns")
        .is_err());
    drop(backup);

    let mut restored = Database::open(&root.path().join("restored")).unwrap();
    restored.restore(backup_path).unwrap();
    assert_eq!(schema_version(&restored.connection), 7);
    assert!(antigravity_evidence(&restored.connection).is_empty());
    assert_eq!(
        report(&mut restored, &Filter::default())
            .unwrap()
            .summary
            .tokens,
        100
    );
}

#[test]
fn schema_seven_restore_recovers_antigravity_evidence_and_rejects_a_missing_table() {
    let root = tempfile::tempdir().unwrap();
    let mut source = Database::open(&root.path().join("source")).unwrap();
    import_usage(&mut source);
    source
        .connection
        .execute_batch(
            "INSERT INTO antigravity_subagent_spawns (client,child_id,parent_id,name,started_ms)
             VALUES ('antigravity','app-child','app-parent','Research',1778112000000),
                    ('antigravity-cli','cli-child','cli-parent',NULL,NULL);",
        )
        .unwrap();
    let expected = antigravity_evidence(&source.connection);
    assert_eq!(expected.len(), 2);
    let valid = root.path().join("valid.sqlite3");
    source.backup(&valid).unwrap();

    let mut restored = Database::open(&root.path().join("restored")).unwrap();
    restored.restore(&valid).unwrap();
    assert_eq!(schema_version(&restored.connection), 7);
    assert_eq!(antigravity_evidence(&restored.connection), expected);
    let restored_revision = revision(&restored.connection).unwrap();

    let malformed = root.path().join("missing-table.sqlite3");
    std::fs::copy(&valid, &malformed).unwrap();
    let backup = Connection::open(&malformed).unwrap();
    backup
        .execute_batch("DROP TABLE antigravity_subagent_spawns;")
        .unwrap();
    assert_eq!(schema_version(&backup), 7);
    drop(backup);

    assert!(restored.restore(&malformed).is_err());
    assert_eq!(revision(&restored.connection).unwrap(), restored_revision);
    assert_eq!(antigravity_evidence(&restored.connection), expected);
}

#[test]
fn valid_backup_restores_usage_and_corrupt_backup_keeps_current_database() {
    let root = tempfile::tempdir().unwrap();
    let mut db = Database::open(&root.path().join("db")).unwrap();
    import_usage(&mut db);
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
