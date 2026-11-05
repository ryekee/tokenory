# Tokenory

本机 AI 用量账本，常驻 macOS 菜单栏。保存 Claude Code、Codex 和通过 Claude Code 使用的 DeepSeek token 数据，按参考 API 费率估算成本，支持历史导入、来源选择和数据库备份。

- 菜单栏看今日用量；原生窗口查日期、工具、提供方和模型。
- 日志被清理后，已采集的记录继续保留。
- CC Switch / tokens.ci JSON 先预览，再选择重叠来源；可撤销批次。
- 源成本、参考估算、未计价用量分开；价格刷新不改变既有估算。
- 数据保存在 `~/Library/Application Support/Tokenory`。不向排行榜提交，不保存提示词正文。

## 运行

需要 macOS 15+，本机验证目标为 Apple Silicon / macOS 27.2。构建需要 Xcode、XcodeGen 和 `rust-toolchain.toml` 指定的 Rust；也支持项目内 `.tools/cargo` / `.tools/rustup`。

```sh
./script/build_and_run.sh
```

联合构建入口是 `./script/build.sh`。产物在 `.build/xcode/Build/Products/Debug/Tokenory.app`，内部已包含 Rust helper。正常使用无需终端或另装 CLI。关闭统计窗口继续采集；退出 App 停止采集。登录启动默认关闭，在设置中主动开启。

```sh
# 仅维护与复现时使用；App 运行时，写命令由其 worker 独占。
cli/target/debug/tokenory --data-dir /absolute/test-directory report
cli/target/debug/tokenory --data-dir /absolute/test-directory import preview --source cc-switch /absolute/input.json
cli/target/debug/tokenory --data-dir /absolute/test-directory backup /absolute/backup.sqlite3
```

## 验证与说明

- [实施状态与验收边界](docs/local/acceptance.md)
- [使用、备份、恢复及卸载](docs/local/operations.md)
- [来源范围](docs/local/sources.md)
- [历史迁移对账](docs/local/migration.md)
- [估算口径](docs/local/pricing.md)
- [实施计划](docs/superpowers/plans/2026-11-05-tokenory-implementation.md)

Rust：`cargo test --manifest-path cli/Cargo.toml`；原生：构建后运行 `xcodebuild -project macos/Tokenory.xcodeproj -scheme Tokenory -destination 'platform=macOS' test`。测试使用独立目录，不写个人用量。

基于 [missuo/tokens](https://github.com/missuo/tokens) 的 Rust 核心，固定基线 `c2f3857c328478e2599a3ba871151ec255e00831`。新增 Tokenory SQLite/进程层和 SwiftUI App；原上游 Web/排行榜代码保留在 fork 中，不属于本机 App 的运行依赖。遵循仓库 [MIT License](LICENSE)。
