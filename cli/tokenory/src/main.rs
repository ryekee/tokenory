use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
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
#[derive(Subcommand)]
enum Command {
    Scan,
    Report {
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
    if !matches!(args.command,Command::Report {..}|Command::Backup {..}) {tokenory::pricing::initialize(&mut db)?;}
    let value = match args.command {
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
        } => serde_json::to_value(report(
            &mut db,
            &Filter {
                from,
                to,
                client,
                model,
                provider,
                ..Default::default()
            },
        )?)?,
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
                replace_conflicts,
            } => serde_json::to_value(apply_import(
                &mut db,
                &id,
                &ApplyOptions {
                    accept_original_dates,
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
