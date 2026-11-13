// [INPUT]: 组合本地账本引擎的各模块。
// [OUTPUT]: 向 CLI、测试和维护工具导出公共接口。
// [POS]: Rust 引擎的库入口。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
pub mod clients;
pub mod collector;
pub mod config;
pub mod db;
pub mod import;
pub mod queries;
pub mod usage;

pub mod pricing;

pub mod ipc;

pub mod price_coverage;

pub mod price_catalog;
