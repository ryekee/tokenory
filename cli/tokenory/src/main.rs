use anyhow::{Context, Result};
use clap::{Parser, Subcommand, ValueEnum};
use fs2::FileExt;
use std::{fs::File, path::PathBuf};
use tokenory::{
    db::Database,
    import::{apply_import, preview_import, undo_import, ApplyOptions},
    queries::{report, Filter},
};

#[derive(Parser)]
#[command(version, about = "Tokenory local usage ledger")]
struct Args {
    #[arg(long, global = true)]
    data_dir: Option<PathBuf>,
    #[command(subcommand)]
    command: Command,
}
#[derive(Clone, ValueEnum)]
enum GroupBy {
    Day,
    Client,
    Provider,
    Model,
}
#[derive(Subcommand)]
enum Command {
    Restore {
        source: PathBuf,
    },
    Export {
        #[arg(long)]
        format: String,
        destination: PathBuf,
    },
    Worker {
        #[arg(long)]
        stdio: bool,
    },
    Scan,
    Report {
        #[arg(long)]
        group_by: Option<GroupBy>,
        #[arg(long)]
        json: bool,
        #[arg(long)]
        from: Option<String>,
        #[arg(long)]
        to: Option<String>,
        #[arg(long)]
        client: Option<String>,
        #[arg(long)]
        model: Option<String>,
        #[arg(long)]
        provider: Option<String>,
    },
    Import {
        #[command(subcommand)]
        action: ImportAction,
    },
    Backup {
        destination: PathBuf,
    },
}
#[derive(Subcommand)]
enum ImportAction {
    Preview {
        #[arg(long)]
        source: String,
        file: PathBuf,
        #[arg(long)]
        timezone: Option<String>,
    },
    Apply {
        id: String,
        #[arg(long)]
        accept_original_dates: bool,
        #[arg(long)]
        accept_partial_dates: bool,
        #[arg(long)]
        replace_conflicts: bool,
    },
    Undo {
        id: String,
    },
}
fn main() -> Result<()> {
    let args = Args::parse();
    let directory = args.data_dir.unwrap_or_else(|| {
        dirs::home_dir()
            .expect("home directory")
            .join("Library/Application Support/Tokenory")
    });
    std::fs::create_dir_all(&directory)?;
    // Every app-owned cache lives here; never reuse tokens.ci login or submit state.
    std::env::set_var("TOKENS_CONFIG_DIR", directory.join("core"));
    let _lock = if matches!(
        args.command,
        Command::Report { .. } | Command::Backup { .. }
    ) {
        None
    } else {
        let f = File::options()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(directory.join("writer.lock"))?;
        f.try_lock_exclusive()
            .context("Tokenory writer is already running; use the app or stop it first")?;
        Some(f)
    };
    let mut db = Database::open(&directory)?;
    if !matches!(
        args.command,
        Command::Report { .. } | Command::Backup { .. }
    ) {
        tokenory::pricing::initialize(&mut db)?;
    }
    let value = match args.command {
        Command::Restore { source } => {
            db.restore(&source)?;
            serde_json::json!({"restored":source})
        }
        Command::Export {
            format,
            destination,
        } => {
            tokenory::ipc::export(&mut db, &destination, &format, &Filter::default())?;
            serde_json::json!({"path":destination})
        }
        Command::Worker { stdio } => {
            anyhow::ensure!(stdio, "worker requires --stdio");
            let config = tokenory::config::Config::load(&directory)?;
            let runtime = tokio::runtime::Runtime::new()?;
            let result = runtime.block_on(tokenory::ipc::run(&mut db, config));
            runtime.shutdown_timeout(std::time::Duration::from_millis(100));
            return result;
        }
        Command::Scan => {
            let config = tokenory::config::Config::load(&directory)?;
            let mut cache = tokenory::collector::DiagnosticCache::persistent();
            let batch = tokio::runtime::Runtime::new()?
                .block_on(tokenory::collector::collect_once(&config, &mut cache))?;
            serde_json::to_value(tokenory::collector::persist(&mut db, batch)?)?
        }
        Command::Report {
            from,
            to,
            client,
            model,
            provider,
            group_by,
            json: _,
        } => {
            let r = report(
                &mut db,
                &Filter {
                    from,
                    to,
                    client,
                    model,
                    provider,
                    ..Default::default()
                },
            )?;
            if let Some(group) = group_by {
                let groups = match group {
                    GroupBy::Day => r.daily,
                    GroupBy::Client => r.clients,
                    GroupBy::Provider => r.providers,
                    GroupBy::Model => r.models,
                };
                serde_json::json!({"revision":r.revision,"summary":r.summary,"groups":groups})
            } else {
                serde_json::to_value(r)?
            }
        }
        Command::Import { action } => match action {
            ImportAction::Preview {
                source,
                file,
                timezone,
            } => serde_json::to_value(preview_import(
                &mut db,
                &source,
                &std::fs::read(file)?,
                timezone,
            )?)?,
            ImportAction::Apply {
                id,
                accept_original_dates,
                accept_partial_dates,
                replace_conflicts,
            } => serde_json::to_value(apply_import(
                &mut db,
                &id,
                &ApplyOptions {
                    accept_original_dates,
                    accept_partial_dates,
                    replace_conflicts,
                    ..Default::default()
                },
            )?)?,
            ImportAction::Undo { id } => {
                undo_import(&mut db, &id)?;
                serde_json::json!({"undone":id})
            }
        },
        Command::Backup { destination } => {
            db.backup(&destination)?;
            serde_json::json!({"path":destination})
        }
    };
    println!("{}", serde_json::to_string(&value)?);
    Ok(())
}
