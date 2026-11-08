# 上游与本地构建

Tokenory fork 自 https://github.com/missuo/tokens，固定基线 `c2f3857c328478e2599a3ba871151ec255e00831`。保留上游 MIT 许可证和版权。

- origin: https://github.com/ryekee/tokenory
- upstream: https://github.com/missuo/tokens
- `main` 为默认分支，维护 Tokenory macOS 应用；本地 `main` 跟踪 `origin/main`。
- 新功能按需从 `main` 创建短期 `codex/` 分支，合并后删除。原 `codex/macos-menubar` 已合并到 `main`。
- `updates` 是应用更新清单的发布分支，由发布脚本维护；不合并到 `main`，不删除。
- 旧 Web/CLI 部署分支 `deploy/self-hosted` 已归档为标签 `archive/deploy-self-hosted-2026-11-08`（`f3767c9629d5361697c6393d5bcf70047bb4779b`）。如需恢复：`git switch -c deploy/self-hosted archive/deploy-self-hosted-2026-11-08`。
- 首版 Rust 为 1.99.1；Xcode 27.2，目标 macOS 15+。当前只验本机 arm64。
- `./script/build.sh` 联合构建 Rust 与 SwiftUI；`./script/build_and_run.sh` 构建并打开 App。
- 如项目存在 `.tools/cargo`，脚本自动使用项目内工具链；否则使用 PATH 中的 cargo。
- `macos/project.yml` 为工程源文件；用 XcodeGen 生成 `.xcodeproj`，不手改生成工程。
- 开发构建使用 ad-hoc 签名，仅证明本机可运行，不代表 Developer ID、公证或其他机器验收。

后续按需同步解析、去重和定价修复。新增客户端先检查本地发现、快照更新和成本口径，再加入 Tokenory 支持集合。本地持久化和原生 UI 不耦合上游公共站点。

本地方案覆盖 42 个工具入口。4 个缓存入口依赖另行同步的上游格式文件，App 不包含这些账号的登录/同步流程。完整边界见 [来源说明](sources.md)。`docs/upstream_policy.md` 为继承的上游历史文档，不是 Tokenory 的实施规则。
