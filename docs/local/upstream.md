# 上游与本地构建

Tokenory fork 自 https://github.com/missuo/tokens，固定基线 `c2f3857c328478e2599a3ba871151ec255e00831`。保留上游 MIT 许可证和版权。

- origin: https://github.com/ryekee/tokenory
- upstream: https://github.com/missuo/tokens
- `main` 为默认分支，维护 Tokenory macOS 应用、官网及共享解析代码。本地 `main` 跟踪 `origin/main`。
- 新功能按需从 `main` 创建短期 `codex/` 分支，合并后删除。原 `codex/macos-menubar` 已合并到 `main`。
- `updates` 是应用更新清单的发布分支，由发布脚本维护；不合并到 `main`，不删除。
- 首版 Rust 为 1.99.1；Xcode 27.2，目标 macOS 15+。当前只验本机 arm64。
- `./script/build.sh` 联合构建 Rust 与 SwiftUI；`./script/build_and_run.sh` 构建并打开 App。
- 如项目存在 `.tools/cargo`，脚本自动使用项目内工具链；否则使用 PATH 中的 cargo。
- `macos/project.yml` 为工程源文件；用 XcodeGen 生成 `.xcodeproj`，不手改生成工程。
- 开发构建使用 ad-hoc 签名，仅证明本机可运行，不代表 Developer ID、公证或其他机器验收。

## 同步上游解析器

用本地 `codex/upstream-sync` 跟踪完整的 `upstream/main`。新检出时，如果尚未配置 `upstream` remote，先添加它，再建跟踪分支。

```sh
git remote add upstream https://github.com/missuo/tokens.git
git fetch --no-tags upstream
git branch --track codex/upstream-sync upstream/main
```

确信同步分支未检出时，用普通快进抓取更新该分支。该分支供本地审阅，将经过验证的解析器增量提交到 Tokenory。

```sh
git fetch --no-tags upstream refs/heads/main:refs/heads/codex/upstream-sync
git fetch origin
git worktree add -b codex/update-agent-parsers ../tokenory-parser-update origin/main
```

在新工作树中，从上次完成整批同步的上游提交审阅到当前跟踪分支。首次以固定基线为起点。已有单独移植的修复在下文列出。

```sh
reviewed=c2f3857c328478e2599a3ba871151ec255e00831
git log --oneline "$reviewed"..codex/upstream-sync -- cli/tokens-core cli/Cargo.toml rust-toolchain.toml
git diff --binary --full-index --no-renames "$reviewed" codex/upstream-sync -- cli/tokens-core/ |
  git apply --3way --index
cargo test --manifest-path cli/Cargo.toml --workspace --locked
```

三方应用有冲突时，保留 Tokenory 已验证的格式和计价行为，逐项合并本轮需要的改动。按需补齐 Cargo 依赖和锁文件。检查客户端发现、重复扫描、快照更新和成本口径，再提交选定的解析器变更。整批审阅完成后在同步提交中记录对应的上游 SHA。

已移植 [Codex 上下文压缩修复](https://github.com/missuo/tokens/pull/116) 和 [Devin CLI 请求去重](https://github.com/missuo/tokens/pull/125) 的解析逻辑。首次扫描会重建这两类客户端的源解析缓存。

缓存生成方式见 [来源说明](sources.md)。上游 CLI、Web 和服务部署说明由 [missuo/tokens](https://github.com/missuo/tokens) 维护。

## 本地过程文件

设计原型、备选图标和设计审阅放在 `local-data/design-assets/`。开发计划、验收证据和本地工具配置副本放在 `local-data/dev-assets/`。编译与验证产物使用 `.build/` 和 Cargo `target/`。需要 Codex 的本地运行入口时，环境文件可放在已忽略的 `.codex/environments/`。
