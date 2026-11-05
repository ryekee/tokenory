use serde::Serialize;
use std::path::PathBuf;
use tokens_core::{scanner::ScanResult, ClientId};

// The requested 42 products use 40 parsers: Paseo delegates to Claude/Codex,
// and Orca's MiMo sandbox is discovered by the MiMo Code scanner.
pub const CLIENTS: &[ClientId] = &[
    ClientId::Amp,
    ClientId::Antigravity,
    ClientId::AntigravityCli,
    ClientId::Claude,
    ClientId::Cline,
    ClientId::CodeBuddy,
    ClientId::Codebuff,
    ClientId::Codex,
    ClientId::CommandCode,
    ClientId::Copilot,
    ClientId::Crush,
    ClientId::Cursor,
    ClientId::DevinCli,
    ClientId::DevinDesktop,
    ClientId::Droid,
    ClientId::Fx,
    ClientId::Gemini,
    ClientId::Goose,
    ClientId::Grok,
    ClientId::Hermes,
    ClientId::Jcode,
    ClientId::Junie,
    ClientId::KiloCode,
    ClientId::Kilo,
    ClientId::Kimi,
    ClientId::Kiro,
    ClientId::MiMoCode,
    ClientId::Mux,
    ClientId::OpenClaw,
    ClientId::OpenCode,
    ClientId::OpenCodeReview,
    ClientId::Pi,
    ClientId::Qwen,
    ClientId::Reasonix,
    ClientId::RooCode,
    ClientId::Trae,
    ClientId::Warp,
    ClientId::WorkBuddy,
    ClientId::Zcode,
    ClientId::Zed,
];

pub fn supports_extra_paths(client: ClientId) -> bool {
    // These upstream lanes discover databases directly, outside extra_scan_paths.
    !matches!(
        client,
        ClientId::Kilo | ClientId::Crush | ClientId::Goose | ClientId::MiMoCode
    )
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClientInfo {
    id: &'static str,
    name: &'static str,
    supports_extra_paths: bool,
    collects_as: Vec<&'static str>,
}

pub fn catalog() -> Vec<ClientInfo> {
    let mut clients: Vec<_> = CLIENTS
        .iter()
        .map(|c| ClientInfo {
            id: c.as_str(),
            name: c.display_name(),
            supports_extra_paths: supports_extra_paths(*c),
            collects_as: vec![c.as_str()],
        })
        .collect();
    clients.extend([
        ClientInfo {
            id: "paseo",
            name: "Paseo",
            supports_extra_paths: false,
            collects_as: vec!["claude", "codex"],
        },
        ClientInfo {
            id: "orca",
            name: "Orca",
            supports_extra_paths: false,
            collects_as: vec!["micode"],
        },
    ]);
    clients.sort_by_key(|c| c.name.to_lowercase());
    clients
}

/// Include the database lanes, which the upstream scanner keeps separately
/// from its file buckets. Diagnostics must describe the same inputs as parsing.
pub fn source_paths(scan: &ScanResult, client: ClientId) -> Vec<PathBuf> {
    let mut paths = scan.get(client).clone();
    match client {
        ClientId::OpenCode => paths.extend(scan.opencode_dbs.iter().cloned()),
        ClientId::Copilot => {
            paths.extend(scan.copilot_desktop_db.iter().cloned());
            paths.extend(scan.copilot_vscode_sessions.iter().cloned());
        }
        ClientId::Kilo => paths.extend(scan.kilo_db.iter().cloned()),
        ClientId::Hermes => paths.extend(scan.hermes_db.iter().cloned()),
        ClientId::Goose => paths.extend(scan.goose_db.iter().cloned()),
        ClientId::Zed => paths.extend(scan.zed_db.iter().cloned()),
        ClientId::Kiro => paths.extend(scan.kiro_db.iter().cloned()),
        ClientId::Crush => paths.extend(scan.crush_dbs.iter().map(|s| s.db_path.clone())),
        ClientId::Zcode => paths.extend(scan.zcode_db.iter().cloned()),
        ClientId::OpenClaw => {
            paths.extend(scan.openclaw_dbs.iter().cloned());
            // Some OpenClaw rollouts live in the user's native Codex home.
            paths.extend(scan.get(ClientId::Codex).iter().cloned());
        }
        ClientId::MiMoCode => paths.extend(scan.micode_dbs.iter().cloned()),
        ClientId::DevinCli => paths.extend(scan.devin_dbs.iter().cloned()),
        _ => {}
    }
    paths.sort();
    paths.dedup();
    paths
}
