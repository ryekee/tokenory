pub mod cc_switch;
use crate::{
    db::{advance_revision, put_record, Database},
    usage::UsageRecord,
};
use anyhow::{bail, ensure, Context, Result};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Conflict {
    pub id: String,
    pub date: String,
    pub client: String,
    pub existing_source: String,
    pub existing_tokens: i64,
    pub incoming_tokens: i64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportPreview {
    pub id: String,
    pub source: String,
    pub content_hash: String,
    pub start: String,
    pub end: String,
    pub row_count: usize,
    pub day_count: usize,
    pub tokens: i64,
    pub unpriced_tokens: i64,
    pub source_timezone: Option<String>,
    pub conflicts: Vec<Conflict>,
}
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase", deny_unknown_fields)]
pub struct ApplyOptions {
    pub accept_original_dates: bool,
    pub replace_conflicts: bool,
    pub resolutions: BTreeMap<String, String>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ImportResult {
    pub batch_id: String,
    pub already_imported: bool,
    pub tokens: i64,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
struct Choice {
    source: String,
    batch_id: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
struct Scope {
    date: String,
    client: String,
    previous: Option<Choice>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
struct StoredPreview {
    view: ImportPreview,
    records: Vec<UsageRecord>,
    scopes: Vec<Scope>,
    fingerprint: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
struct BatchHistory {
    view: ImportPreview,
    changes: Vec<Scope>,
}
fn selected(c: &Connection, date: &str, client: &str) -> Result<Option<Choice>> {
    Ok(c.query_row(
        "SELECT source,batch_id FROM coverage_choices WHERE date=?1 AND client=?2",
        params![date, client],
        |r| {
            Ok(Choice {
                source: r.get(0)?,
                batch_id: r.get(1)?,
            })
        },
    )
    .optional()?)
}
fn fingerprint(c: &Connection, scopes: &[Scope]) -> Result<String> {
    let mut hash = Sha256::new();
    let mut stmt=c.prepare("SELECT source,batch_id,item_key,body FROM effective_usage WHERE date=?1 AND client=?2 ORDER BY item_key")?;
    for scope in scopes {
        hash.update(serde_json::to_vec(&(
            &scope.date,
            &scope.client,
            selected(c, &scope.date, &scope.client)?,
        ))?);
        for row in stmt.query_map(params![scope.date, scope.client], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
            ))
        })? {
            hash.update(serde_json::to_vec(&row?)?);
        }
    }
    Ok(format!("{:x}", hash.finalize()))
}
pub fn preview_import(
    db: &mut Database,
    source: &str,
    bytes: &[u8],
    timezone: Option<String>,
) -> Result<ImportPreview> {
    let records = match source {
        "cc-switch" => cc_switch::parse(bytes, timezone.clone())?,
        _ => bail!("unsupported import source: {source}"),
    };
    preview_records(db, source, bytes, records, timezone)
}
pub fn preview_records(
    db: &mut Database,
    source: &str,
    bytes: &[u8],
    records: Vec<UsageRecord>,
    timezone: Option<String>,
) -> Result<ImportPreview> {
    ensure!(!records.is_empty(), "import has no usage rows");
    let start = records.iter().map(|r| r.date.clone()).min().unwrap();
    let end = records.iter().map(|r| r.date.clone()).max().unwrap();
    let mut keys: BTreeSet<(String, String)> = records
        .iter()
        .map(|r| (r.date.clone(), r.client.clone()))
        .collect();
    // A corrected snapshot replaces prior selected dates inside its stated span,
    // including a day/model removed from the replacement snapshot.
    let clients: BTreeSet<_> = records.iter().map(|r| r.client.clone()).collect();
    let mut stmt = db.connection.prepare(
        "SELECT date,client FROM coverage_choices WHERE source=?1 AND date>=?2 AND date<=?3",
    )?;
    for row in stmt.query_map(params![source, start, end], |r| {
        Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
    })? {
        let pair = row?;
        if clients.contains(&pair.1) {
            keys.insert(pair);
        }
    }
    drop(stmt);
    let mut scopes = Vec::new();
    let mut conflicts = Vec::new();
    for (date, client) in keys {
        let previous = selected(&db.connection, &date, &client)?;
        if let Some(choice) = &previous {
            if choice.source != source {
                let existing_tokens=db.connection.query_row("SELECT coalesce(sum(tokens),0) FROM effective_usage WHERE date=?1 AND client=?2",params![date,client],|r|r.get(0))?;
                let incoming_tokens = records
                    .iter()
                    .filter(|r| r.date == date && r.client == client)
                    .try_fold(0_i64, |a, r| {
                        a.checked_add(r.tokens.checked_total()?)
                            .ok_or_else(|| anyhow::anyhow!("token total overflow"))
                    })?;
                conflicts.push(Conflict {
                    id: format!("{date}|{client}"),
                    date: date.clone(),
                    client: client.clone(),
                    existing_source: choice.source.clone(),
                    existing_tokens,
                    incoming_tokens,
                });
            }
        }
        scopes.push(Scope {
            date,
            client,
            previous,
        });
    }
    let tokens = records.iter().try_fold(0_i64, |a, r| {
        a.checked_add(r.tokens.checked_total()?)
            .ok_or_else(|| anyhow::anyhow!("token total overflow"))
    })?;
    let mut view = ImportPreview {
        id: String::new(),
        source: source.into(),
        content_hash: format!("{:x}", Sha256::digest(bytes)),
        start,
        end,
        row_count: records.len(),
        day_count: records
            .iter()
            .map(|r| &r.date)
            .collect::<BTreeSet<_>>()
            .len(),
        tokens,
        unpriced_tokens: tokens,
        source_timezone: timezone,
        conflicts,
    };
    let state = fingerprint(&db.connection, &scopes)?;
    db.connection.execute(
        "INSERT INTO import_previews(source,content_hash,body) VALUES (?1,?2,'')",
        params![source, view.content_hash],
    )?;
    view.id = db.connection.last_insert_rowid().to_string();
    let stored = StoredPreview {
        view: view.clone(),
        records,
        scopes,
        fingerprint: state,
    };
    db.connection.execute(
        "UPDATE import_previews SET body=?1 WHERE id=?2",
        params![serde_json::to_string(&stored)?, view.id],
    )?;
    Ok(view)
}
pub fn apply_import(db: &mut Database, id: &str, options: &ApplyOptions) -> Result<ImportResult> {
    let body: String = db
        .connection
        .query_row("SELECT body FROM import_previews WHERE id=?1", [id], |r| {
            r.get(0)
        })
        .context("import preview does not exist")?;
    let p: StoredPreview = serde_json::from_str(&body)?;
    if let Some(batch) = db
        .connection
        .query_row(
            "SELECT id FROM import_batches WHERE source=?1 AND content_hash=?2 AND active=1",
            params![p.view.source, p.view.content_hash],
            |r| r.get::<_, i64>(0),
        )
        .optional()?
    {
        return Ok(ImportResult {
            batch_id: batch.to_string(),
            already_imported: true,
            tokens: p.view.tokens,
        });
    }
    ensure!(
        p.view.source_timezone.is_some() || options.accept_original_dates,
        "confirm preservation of original dates: source timezone is unknown"
    );
    for c in &p.view.conflicts {
        ensure!(
            options.replace_conflicts
                || matches!(
                    options.resolutions.get(&c.id).map(String::as_str),
                    Some("imported" | "existing")
                ),
            "choose a source for {}",
            c.id
        );
    }
    ensure!(
        fingerprint(&db.connection, &p.scopes)? == p.fingerprint,
        "coverage changed after preview; preview again"
    );
    db.backup_before("import")?;
    let tx = db.connection.transaction()?;
    ensure!(
        fingerprint(&tx, &p.scopes)? == p.fingerprint,
        "coverage changed after preview; preview again"
    );
    tx.execute(
        "INSERT INTO import_batches(source,content_hash,created_at,body) VALUES (?1,?2,?3,'')",
        params![
            p.view.source,
            p.view.content_hash,
            chrono::Utc::now().to_rfc3339()
        ],
    )?;
    let batch = tx.last_insert_rowid().to_string();
    for r in &p.records {
        put_record(&tx, &p.view.source, &batch, r)?;
    }
    let mut changes = Vec::new();
    for scope in &p.scopes {
        let key = format!("{}|{}", scope.date, scope.client);
        let conflict = scope
            .previous
            .as_ref()
            .is_some_and(|c| c.source != p.view.source);
        if conflict
            && options
                .resolutions
                .get(&key)
                .is_some_and(|s| s == "existing")
        {
            continue;
        }
        tx.execute("INSERT INTO coverage_choices(date,client,source,batch_id) VALUES (?1,?2,?3,?4) ON CONFLICT(date,client) DO UPDATE SET source=excluded.source,batch_id=excluded.batch_id",params![scope.date,scope.client,p.view.source,batch])?;
        changes.push(scope.clone());
    }
    tx.execute(
        "UPDATE import_batches SET body=?1 WHERE id=?2",
        params![
            serde_json::to_string(&BatchHistory {
                view: p.view.clone(),
                changes
            })?,
            batch
        ],
    )?;
    advance_revision(&tx)?;
    tx.commit()?;
    Ok(ImportResult {
        batch_id: batch,
        already_imported: false,
        tokens: p.view.tokens,
    })
}
pub fn undo_import(db: &mut Database, id: &str) -> Result<()> {
    let tx = db.connection.transaction()?;
    let (active, body): (bool, String) = tx
        .query_row(
            "SELECT active,body FROM import_batches WHERE id=?1",
            [id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .context("import batch does not exist")?;
    ensure!(active, "batch already undone");
    let history: BatchHistory = serde_json::from_str(&body)?;
    for scope in &history.changes {
        ensure!(
            selected(&tx, &scope.date, &scope.client)?.is_some_and(|c| c.batch_id == id),
            "later coverage depends on this batch; undo later batches first"
        );
    }
    for scope in &history.changes {
        if let Some(c) = &scope.previous {
            tx.execute(
                "UPDATE coverage_choices SET source=?1,batch_id=?2 WHERE date=?3 AND client=?4",
                params![c.source, c.batch_id, scope.date, scope.client],
            )?;
        } else {
            tx.execute(
                "DELETE FROM coverage_choices WHERE date=?1 AND client=?2",
                params![scope.date, scope.client],
            )?;
        }
    }
    tx.execute("UPDATE import_batches SET active=0 WHERE id=?1", [id])?;
    advance_revision(&tx)?;
    tx.commit()?;
    Ok(())
}
