use crate::usage::UsageRecord;
use anyhow::{ensure, Context, Result};
use rusqlite::{params, Connection};
use std::{
    path::{Path, PathBuf},
    time::Duration,
};

pub struct Database {
    pub connection: Connection,
    pub directory: PathBuf,
}
impl Database {
    pub fn open(directory: &Path) -> Result<Self> {
        std::fs::create_dir_all(directory)?;
        let connection = Connection::open(directory.join("tokenory.sqlite3"))?;
        connection.busy_timeout(Duration::from_secs(5))?;
        connection.execute_batch("PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL;")?;
        let version: i64 = connection.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        ensure!(
            version <= 3,
            "database was created by a newer Tokenory version"
        );
        if version == 0 {
            connection.execute_batch(include_str!("../migrations/001_initial.sql"))?;
        }
        if version < 2 {
            connection.execute_batch(include_str!("../migrations/002_pricing.sql"))?;
        }
        let mut db = Self {
            connection,
            directory: directory.to_owned(),
        };
        if version < 3 {
            if version > 0 {
                db.backup_before("schema-3")?;
            }
            db.migrate_local_keys()?;
        }
        Ok(db)
    }
    fn migrate_local_keys(&mut self) -> Result<()> {
        let tx = self.connection.transaction()?;
        let rows = {
            let mut stmt = tx.prepare("SELECT body FROM usage_records WHERE source='local' AND batch_id='' ORDER BY rowid")?;
            let rows = stmt
                .query_map([], |r| r.get::<_, String>(0))?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            rows
        };
        let mut merged = std::collections::BTreeMap::<String, UsageRecord>::new();
        for body in rows {
            let mut record: UsageRecord = serde_json::from_str(&body)?;
            let prefix = format!("{}:{}:", record.client, record.provider);
            let Some(identity) = record.key.strip_prefix(&prefix) else {
                continue;
            };
            let key = format!("{}:{identity}", record.client);
            tx.execute(
                "DELETE FROM usage_records WHERE source='local' AND batch_id='' AND item_key=?1",
                [&record.key],
            )?;
            record.key = key.clone();
            // Later rows contain the corrected provider; preserve the first
            // observation's date, just as a normal streaming update does.
            if let Some(first) = merged.get(&key) {
                record.date = first.date.clone();
                record.timezone = first.timezone.clone();
            }
            merged.insert(key, record);
        }
        for record in merged.values() {
            put_record(&tx, "local", "", record)?;
        }
        if !merged.is_empty() {
            advance_revision(&tx)?;
        }
        tx.execute_batch("PRAGMA user_version=3;")?;
        tx.commit()?;
        Ok(())
    }
    pub fn backup(&self, destination: &Path) -> Result<()> {
        ensure!(!destination.exists(), "backup destination already exists");
        if let Some(parent) = destination.parent() {
            std::fs::create_dir_all(parent)?;
        }
        self.connection
            .backup(rusqlite::DatabaseName::Main, destination, None)
            .context("create consistent SQLite backup")?;
        Ok(())
    }
    pub fn restore(&mut self, source_path: &Path) -> Result<()> {
        let source =
            Connection::open_with_flags(source_path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
                .context("open backup")?;
        source.execute_batch("BEGIN;")?;
        let integrity: String = source.query_row("PRAGMA integrity_check", [], |r| r.get(0))?;
        ensure!(integrity == "ok", "backup integrity check failed");
        let version: i64 = source.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        ensure!(
            (1..=3).contains(&version),
            "unsupported backup schema version"
        );
        {
            let mut statement = source.prepare("SELECT body,tokens FROM usage_records")?;
            for row in
                statement.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))?
            {
                let (body, total) = row?;
                let record: UsageRecord = serde_json::from_str(&body)?;
                record.validate()?;
                ensure!(
                    record.tokens.checked_total()? == total,
                    "backup token totals do not match record bodies"
                );
            }
            source.query_row("SELECT count(*) FROM effective_usage", [], |r| {
                r.get::<_, i64>(0)
            })?;
            source.query_row("SELECT value FROM meta WHERE key='revision'", [], |r| {
                r.get::<_, i64>(0)
            })?;
        }
        self.backup_before("restore")?;
        // Keep the validated source read transaction open while copying it.
        // SQLite applies the replacement as one destination transaction.
        {
            let backup = rusqlite::backup::Backup::new(&source, &mut self.connection)?;
            backup.run_to_completion(100, Duration::from_millis(5), None)?;
        }
        source.execute_batch("COMMIT;")?;
        if version == 1 {
            self.connection
                .execute_batch(include_str!("../migrations/002_pricing.sql"))?;
        }
        if version < 3 {
            self.migrate_local_keys()?;
        }
        advance_revision(&self.connection)?;
        Ok(())
    }
    pub fn backup_before(&self, action: &str) -> Result<PathBuf> {
        let target = self.directory.join("backups").join(format!(
            "{}-{action}.sqlite3",
            chrono::Utc::now().format("%Y%m%dT%H%M%S%.9f")
        ));
        self.backup(&target)?;
        Ok(target)
    }
}

pub fn revision(connection: &Connection) -> Result<i64> {
    Ok(
        connection.query_row("SELECT value FROM meta WHERE key='revision'", [], |r| {
            r.get(0)
        })?,
    )
}
pub fn advance_revision(connection: &Connection) -> Result<i64> {
    connection.execute("UPDATE meta SET value=value+1 WHERE key='revision'", [])?;
    revision(connection)
}
pub fn put_record(
    connection: &Connection,
    source: &str,
    batch: &str,
    r: &UsageRecord,
) -> Result<bool> {
    let body = serde_json::to_string(r)?;
    let changed = connection.execute(
        "INSERT INTO usage_records(source,batch_id,item_key,date,client,provider,model,input,output,cache_read,cache_write,reasoning,tokens,estimated_cost,source_cost,requests,body)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17)
         ON CONFLICT(source,batch_id,item_key) DO UPDATE SET date=excluded.date,client=excluded.client,provider=excluded.provider,model=excluded.model,input=excluded.input,output=excluded.output,cache_read=excluded.cache_read,cache_write=excluded.cache_write,reasoning=excluded.reasoning,tokens=excluded.tokens,estimated_cost=excluded.estimated_cost,source_cost=excluded.source_cost,requests=excluded.requests,body=excluded.body
         WHERE usage_records.body != excluded.body",
        params![source,batch,r.key,r.date,r.client,r.provider,r.model,r.tokens.input,r.tokens.output,r.tokens.cache_read,r.tokens.cache_write,r.tokens.reasoning,r.tokens.checked_total()?,r.estimated_cost_usd,r.source_cost_usd,r.requests,body])?;
    Ok(changed != 0)
}
