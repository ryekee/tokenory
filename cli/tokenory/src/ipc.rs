use crate::{
    collector::{self, DiagnosticCache, ScanBatch},
    config::Config,
    db::{revision, Database},
    import, pricing,
    queries::{self, Filter},
};
use anyhow::{anyhow, bail, ensure, Result};
use serde::{de::DeserializeOwned, Deserialize};
use serde_json::{json, Value};
use std::{
    io::{self, Write},
    path::PathBuf,
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, BufReader},
    task::JoinHandle,
    time::Instant,
};
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    version: u32,
    id: String,
    operation: String,
    #[serde(default = "empty")]
    payload: Value,
}
fn empty() -> Value {
    json!({})
}
fn send(v: Value) -> Result<()> {
    let mut out = io::stdout().lock();
    serde_json::to_writer(&mut out, &v)?;
    writeln!(out)?;
    out.flush()?;
    Ok(())
}
fn reply(id: &str, r: Result<Value>) -> Result<()> {
    send(match r {
        Ok(v) => json!({"version":1,"id":id,"result":v}),
        Err(e) => {
            json!({"version":1,"id":id,"error":{"code":"invalidRequest","message":format!("{e:#}")}})
        }
    })
}
fn payload<T: DeserializeOwned>(v: Value) -> Result<T> {
    Ok(serde_json::from_value(v)?)
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ImportFile {
    source: String,
    path: PathBuf,
    timezone: Option<String>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ImportApply {
    id: String,
    #[serde(default)]
    options: import::ApplyOptions,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Id {
    id: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct FilePath {
    path: PathBuf,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Reprice {
    #[serde(default)]
    filter: Filter,
    snapshot_id: String,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Breakdown {
    group_by: String,
    #[serde(flatten)]
    filter: Filter,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Export {
    path: PathBuf,
    format: String,
    #[serde(default)]
    filter: Filter,
}
pub fn sources(db: &Database) -> Result<Value> {
    let mut stmt=db.connection.prepare("SELECT r.source,r.batch_id,r.client,count(*),sum(r.tokens),min(r.date),max(r.date),sum(CASE WHEN c.source=r.source AND c.batch_id=r.batch_id THEN r.tokens ELSE 0 END) FROM usage_records r LEFT JOIN coverage_choices c ON r.date=c.date AND r.client=c.client GROUP BY r.source,r.batch_id,r.client")?;
    let coverage=stmt.query_map([],|r|Ok(json!({"source":r.get::<_,String>(0)?,"batchId":r.get::<_,String>(1)?,"client":r.get::<_,String>(2)?,"records":r.get::<_,i64>(3)?,"tokens":r.get::<_,i64>(4)?,"from":r.get::<_,String>(5)?,"to":r.get::<_,String>(6)?,"selectedTokens":r.get::<_,i64>(7)?})))?.collect::<rusqlite::Result<Vec<_>>>()?;
    let mut stmt = db
        .connection
        .prepare("SELECT id,active,created_at,body FROM import_batches ORDER BY id DESC")?;
    let batches = stmt
        .query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, bool>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
            ))
        })?
        .map(|r| {
            let (id, active, created, body) = r?;
            let v: Value = serde_json::from_str(&body)?;
            Ok(json!({"id":id.to_string(),"active":active,"createdAt":created,"preview":v["view"]}))
        })
        .collect::<Result<Vec<_>>>()?;
    Ok(json!({"coverage":coverage,"batches":batches,"clients":crate::clients::catalog()}))
}
pub fn prices(db: &Database) -> Result<Value> {
    let mut stmt=db.connection.prepare("SELECT provider,model,sum(tokens) FROM effective_usage WHERE estimated_cost IS NULL GROUP BY provider,model ORDER BY sum(tokens) DESC")?;
    let missing=stmt.query_map([],|r|Ok(json!({"provider":r.get::<_,String>(0)?,"model":r.get::<_,String>(1)?,"tokens":r.get::<_,i64>(2)?})))?.collect::<rusqlite::Result<Vec<_>>>()?;
    let current = pricing::active_snapshot(&db.connection)?
        .map(|(id, snapshot)| json!({"id":id,"snapshot":snapshot}));
    let mut stmt = db
        .connection
        .prepare("SELECT id,created_at FROM price_snapshots ORDER BY created_at DESC")?;
    let history = stmt
        .query_map([], |r| {
            Ok(json!({"id":r.get::<_,String>(0)?,"createdAt":r.get::<_,String>(1)?}))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(json!({"current":current,"missing":missing,"history":history}))
}
pub fn export(
    db: &mut Database,
    path: &std::path::Path,
    format: &str,
    filter: &Filter,
) -> Result<()> {
    ensure!(
        matches!(format, "json" | "csv"),
        "export format must be json or csv"
    );
    let mut f = filter.clone();
    f.limit = Some(500);
    f.offset = 0;
    let mut rows = Vec::new();
    loop {
        let report = queries::report(db, &f)?;
        let count = report.details.len();
        rows.extend(report.details);
        if count < 500 {
            break;
        }
        f.offset += 500;
    }
    let mut output = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)?;
    if format == "json" {
        serde_json::to_writer_pretty(&mut output, &rows)?;
    } else {
        writeln!(output,"date,client,provider,model,source,tokens,input,output,cache_read,cache_write,reasoning,estimated_cost_usd,source_cost_usd,cost_basis")?;
        let quoted = |s: &str| format!("\"{}\"", s.replace('"', "\"\""));
        for d in rows {
            let r = d.record;
            writeln!(
                output,
                "{},{},{},{},{},{},{},{},{},{},{},{},{},{}",
                quoted(&r.date),
                quoted(&r.client),
                quoted(&r.provider),
                quoted(&r.model),
                quoted(&d.source),
                r.tokens.checked_total()?,
                r.tokens.input,
                r.tokens.output,
                r.tokens.cache_read,
                r.tokens.cache_write,
                r.tokens.reasoning,
                r.estimated_cost_usd
                    .map(|n| n.to_string())
                    .unwrap_or_default(),
                r.source_cost_usd.map(|n| n.to_string()).unwrap_or_default(),
                quoted(r.cost_basis.as_deref().unwrap_or(""))
            )?;
        }
    }
    output.flush()?;
    Ok(())
}
fn execute(db: &mut Database, config: &mut Config, op: &str, v: Value) -> Result<Value> {
    match op {
        "overview" => Ok(serde_json::to_value(queries::report(db, &payload(v)?)?)?),
        "daily" => Ok(serde_json::to_value(
            queries::report(db, &payload(v)?)?.daily,
        )?),
        "details" => Ok(serde_json::to_value(
            queries::report(db, &payload(v)?)?.details,
        )?),
        "breakdown" => {
            let b: Breakdown = payload(v)?;
            let r = queries::report(db, &b.filter)?;
            Ok(serde_json::to_value(match b.group_by.as_str() {
                "client" => r.clients,
                "provider" => r.providers,
                "model" => r.models,
                _ => bail!("groupBy must be client, provider or model"),
            })?)
        }
        "sources" => sources(db),
        "prices" => prices(db),
        "settings" => Ok(serde_json::to_value(&config)?),
        "priceSnapshot" => {
            let p: Id = payload(v)?;
            Ok(serde_json::to_value(pricing::load_snapshot(
                &db.connection,
                &p.id,
            )?)?)
        }
        "importPreview" => {
            let p: ImportFile = payload(v)?;
            Ok(serde_json::to_value(import::preview_import(
                db,
                &p.source,
                &std::fs::read(p.path)?,
                p.timezone,
            )?)?)
        }
        "importApply" => {
            let p: ImportApply = payload(v)?;
            Ok(serde_json::to_value(import::apply_import(
                db, &p.id, &p.options,
            )?)?)
        }
        "importUndo" => {
            let p: Id = payload(v)?;
            import::undo_import(db, &p.id)?;
            Ok(json!({"undone":p.id}))
        }
        "repricePreview" => {
            let p: Reprice = payload(v)?;
            Ok(serde_json::to_value(pricing::preview_reprice(
                db,
                &p.filter,
                &p.snapshot_id,
            )?)?)
        }
        "repriceApply" => {
            let p: Id = payload(v)?;
            Ok(serde_json::to_value(pricing::apply_reprice(db, &p.id)?)?)
        }
        "backup" => {
            let p: FilePath = payload(v)?;
            db.backup(&p.path)?;
            Ok(json!({"path":p.path}))
        }
        "export" => {
            let p: Export = payload(v)?;
            export(db, &p.path, &p.format, &p.filter)?;
            Ok(json!({"path":p.path}))
        }
        "updateSettings" => {
            let value: Config = payload(v)?;
            value.validate()?;
            ensure!(
                value.timezone == config.timezone
                    || db.connection.query_row(
                        "SELECT count(*) FROM usage_records WHERE source='local'",
                        [],
                        |r| r.get::<_, i64>(0)
                    )? == 0,
                "event timezone is locked once usage exists; historical dates are preserved"
            );
            value.save(&db.directory)?;
            *config = value;
            Ok(serde_json::to_value(&config)?)
        }
        _ => bail!("unknown operation: {op}"),
    }
}
fn start_scan(
    config: Config,
    mut cache: DiagnosticCache,
) -> JoinHandle<(DiagnosticCache, Result<ScanBatch>)> {
    tokio::task::spawn_blocking(move || {
        let r = tokio::runtime::Handle::current()
            .block_on(collector::collect_once(&config, &mut cache));
        (cache, r)
    })
}
pub async fn run(db: &mut Database, mut config: Config) -> Result<()> {
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    let mut cache = None;
    let mut scan = Some(start_scan(config.clone(), DiagnosticCache::persistent()));
    let mut next_scan = Instant::now() + Duration::from_secs(config.interval_seconds);
    let mut price_task: Option<
        JoinHandle<(String, Result<tokens_core::pricing::PricingService, String>)>,
    > = None;
    let mut next_price_refresh = Instant::now();
    let mut last_scan: Option<Value> = {
        use rusqlite::OptionalExtension;
        db.connection
            .query_row(
                "SELECT body FROM scan_runs ORDER BY id DESC LIMIT 1",
                [],
                |r| r.get::<_, String>(0),
            )
            .optional()?
            .map(|s| serde_json::from_str(&s))
            .transpose()?
    };
    send(json!({"version":1,"event":"ready","revision":revision(&db.connection)?}))?;
    send(json!({"version":1,"event":"scanStarted"}))?;
    loop {
        tokio::select! {
         line=lines.next_line()=>{
          let Some(line)=line?else{break;};
          let parsed=(||->Result<Request>{ensure!(line.len()<=1_048_576,"request exceeds 1 MiB");let r:Request=serde_json::from_str(&line)?;ensure!(r.version==1,"unsupported protocol version");ensure!(!r.id.is_empty(),"request id is required");Ok(r)})();
          let r=match parsed {Ok(r)=>r,Err(e)=>{let id=serde_json::from_str::<Value>(&line).ok().and_then(|v|v["id"].as_str().map(str::to_owned)).unwrap_or_default();reply(&id,Err(e))?;continue;}};
          let before=revision(&db.connection)?;
          match r.operation.as_str() {
           "shutdown"=>{reply(&r.id,Ok(json!({"stopped":true})))?;break;},
           "scan"=>{let started=scan.is_none();if started {scan=Some(start_scan(config.clone(),cache.take().unwrap_or_else(DiagnosticCache::persistent)));send(json!({"version":1,"event":"scanStarted"}))?;}reply(&r.id,Ok(json!({"started":started})))?;},
           "status"=>reply(&r.id,Ok(json!({"scanning":scan.is_some(),"lastScan":last_scan,"dataDirectory":db.directory,"revision":before,"refreshingPrices":price_task.is_some()})))?,
           "refreshPrices"=>{
            if price_task.is_some(){reply(&r.id,Err(anyhow!("price refresh already running")))?;}else{price_task=Some(tokio::spawn(async move{(r.id,tokens_core::pricing::PricingService::fetch_snapshot().await)}));}
           },
           _=>{let result=execute(db,&mut config,&r.operation,r.payload);reply(&r.id,result)?;},
          }
          let after=revision(&db.connection)?;if before!=after{send(json!({"version":1,"event":"usageChanged","revision":after}))?;}
         },
         result=async {match &mut scan {Some(task)=>task.await,None=>std::future::pending().await}},if scan.is_some()=>{
          scan=None;next_scan=Instant::now()+Duration::from_secs(config.interval_seconds);
          let result=match result {Ok((c,b))=>{cache=Some(c);b.and_then(|b|collector::persist(db,b))},Err(e)=>Err(e.into())};
          match result {Ok(r)=>{last_scan=Some(serde_json::to_value(&r)?);send(json!({"version":1,"event":"scanFinished","payload":r}))?;if r.changed>0 {send(json!({"version":1,"event":"usageChanged","revision":r.revision}))?;}},Err(e)=>send(json!({"version":1,"event":"scanFailed","message":format!("{e:#}")}))?}
         },
         _=tokio::time::sleep_until(next_scan),if scan.is_none()=>{scan=Some(start_scan(config.clone(),cache.take().unwrap_or_else(DiagnosticCache::persistent)));send(json!({"version":1,"event":"scanStarted"}))?;},
         _=tokio::time::sleep_until(next_price_refresh),if scan.is_none() && price_task.is_none()=>{
          next_price_refresh=Instant::now()+Duration::from_secs(86400);
          price_task=Some(tokio::spawn(async {(String::new(),tokens_core::pricing::PricingService::fetch_snapshot().await)}));
         },
         result=async {match &mut price_task {Some(task)=>task.await,None=>std::future::pending().await}},if price_task.is_some()=>{
          price_task=None;let(id,result)=result?;let result=result.map_err(|e|anyhow!(e)).and_then(|service|{ensure!(service.has_pricing_data(),"no upstream price dataset available; saved prices retained");let snapshot=pricing::snapshot_from_service(db,&service)?;Ok(json!({"id":pricing::save_snapshot(db,snapshot)?}))});
          if id.is_empty() { match result { Ok(value)=>send(json!({"version":1,"event":"pricesUpdated","payload":value}))?, Err(error)=>send(json!({"version":1,"event":"priceRefreshFailed","message":format!("{error:#}")}))? } } else { reply(&id,result)?; }

         }
        }
    }
    Ok(())
}
