# Tokenory

**A local macOS implementation of [missuo/tokens](https://github.com/missuo/tokens): native menu bar app, SQLite usage history, and support for 42 AI coding clients.**

Tokenory 是 `missuo/tokens` 的本地实现分支。它复用上游的日志发现和解析能力，把用量保存在本机 SQLite，通过原生 macOS 菜单栏和窗口查看。无需部署网站、数据库服务或排行榜，也无需登录 Tokenory 账号。

## 本地方案做了什么

- 菜单栏查看今日用量，窗口按日期、工具、提供方和模型查询趋势与明细。
- 自动扫描本地日志、数据库和已有用量缓存。默认每轮结束 60 秒后再次扫描。
- 已采集且源会话已删除的历史继续保留。重复扫描不重复累加，会话累计值更新为最新快照。
- 导入 CC Switch / tokens.ci 历史 JSON，先预览、处理重叠来源，再保存。支持撤销导入和数据库备份恢复。
- 区分来源成本、API 参考估算和未计价用量。新价格不会自动改写旧估算。
- 原生 SwiftUI 界面，支持简体中文和 English。关闭窗口继续采集，退出 App 停止采集。

用量账本和设置位于 `~/Library/Application Support/Tokenory`。Tokenory 不向 tokens.ci 或其他排行榜上传用量，不把提示词正文写入账本。**本地存储不等于完全离线**：参考价格刷新会访问价格源，更新检查会访问 GitHub Release。账单类客户端的缓存需要另行同步，见下文。

## 支持的客户端

覆盖下列 42 个工具。发现数据后自动采集，**仅安装客户端不保证存在可读的用量记录**。

| | | | |
| --- | --- | --- | --- |
| Amp | Antigravity | Antigravity CLI | Claude Code |
| Cline | CodeBuddy | Codebuff | Codex CLI |
| Command Code | Copilot | Crush | Cursor |
| Devin CLI | Devin Desktop | Droid | Fx |
| Gemini CLI | Goose | Grok Build | Hermes Agent |
| Jcode | Junie | Kilo | Kilo CLI |
| Kimi | Kiro | MiMo Code | Mux |
| OpenClaw | OpenCode | OpenCodeReview | Orca |
| Pi | Qwen | Reasonix | Roo Code |
| Paseo | Trae | Warp | WorkBuddy |
| ZCode | Zed Agent | | |

- **本地日志 / SQLite**：直接复用上游解析器。来源页显示发现的文件、记录和读取问题。设置中可为支持额外目录的客户端添加路径。
- **Cursor、Trae、Warp、Antigravity IDE**：读取已有的上游格式缓存。Tokenory App 不包含它们的账号登录与缓存同步界面，也不会自动请求这些账号接口。
- **Paseo**：发现其配置指定的 Claude / Codex 日志，归入底层工具。**Orca**：发现其 MiMo Code 沙箱数据库，归入 MiMo Code。两者不作为第二份用量累加。
- **统计精度**：保留源记录提供的粒度。只有会话总量、请求数或费用的来源不会被伪造成逐条 token 数据。新增适配器的源记录暂不参与小时分配。

接入范围、路径、缓存生成方式和验证边界见 [来源说明](docs/local/sources.md)。支持解析格式不代表已在 42 个真实客户端上逐一验收。

## 安装

下载版适用于运行 macOS 15 或更高版本的 Apple Silicon Mac。解压 ZIP 后，将 `Tokenory.app` 拖入「应用程序」。App 使用 Shenzhen Hiko Technology Co., Ltd. 的 Developer ID 签名，并附有 Apple 公证票据。[下载最新版本](https://github.com/ryekee/tokenory/releases/latest)

可在「Tokenory → 检查更新…」或「设置 → 通用」中检查新版，并在 App 内下载、安装和重启。自动检查默认每天一次，可关闭或改为每小时、每 6 小时、每 12 小时、每天、每周；安装由用户确认。更新源为 `ryekee/tokenory` 的 GitHub latest release，使用 Sparkle 验证更新包。v0.1.2 及更早版本需手动升级一次。

发布流程见 [macOS 发布说明](docs/local/releases.md)。

## 从源码构建与运行

需要 macOS 15+、Xcode、[XcodeGen](https://github.com/yonaskolb/XcodeGen) 和 `rust-toolchain.toml` 指定的 Rust。当前验证平台是 Apple Silicon。项目内 `.tools/cargo` / `.tools/rustup` 也受支持。

```sh
git clone https://github.com/ryekee/tokenory.git
cd tokenory
./script/build_and_run.sh
```

只构建：

```sh
./script/build.sh
# Release 构建
TOKENORY_CONFIGURATION=Release ./script/build.sh
```

Debug 产物为 `.build/xcode/Build/Products/Debug/Tokenory.app`，Release 产物在同级 `Release` 目录。本机构建使用 ad-hoc 签名。App 已包含 Rust helper，登录启动可在设置中开启。

## 本分支与上游

| | missuo/tokens | Tokenory |
| --- | --- | --- |
| 主要入口 | CLI + Web 排行榜 | 原生 macOS App |
| 用量存储 | 上游提交与服务端流程 | 本机 SQLite 账本 |
| 展示 | Web 页面与排行榜 | 菜单栏、趋势、筛选与明细 |
| 账号与部署 | 依上游服务流程 | 无 Tokenory 账号，无需自建服务 |
| 公共排名 | 上游功能 | App 不提交用量 |
| 共享能力 | 客户端发现、解析、去重、参考价格 | 复用并按需修复 |

基于固定上游版本 `c2f3857c328478e2599a3ba871151ec255e00831`。`macos/` 是 SwiftUI App，`cli/tokenory/` 是本地采集、账本和进程协议，`cli/tokens-core/` 保留上游解析核心。原 `cli/tokens-cli/`、`web/` 和 npm 包保留以便追溯和按需使用，**不是 Tokenory App 的运行依赖**。它们保留原本的联网、登录和提交命令，不能与本地 helper `tokenory` 混淆。

仓库默认分支展示本地方案，开发分支为 `codex/macos-menubar`。上游来源、构建约定和同步原则见 [上游说明](docs/local/upstream.md)。保留上游版权，遵循 [MIT License](LICENSE)。图标归属见 [品牌资源说明](assets/brand/NOTICE.md)。

## 验证与维护

```sh
cargo test --manifest-path cli/Cargo.toml
cargo clippy --manifest-path cli/Cargo.toml --all-targets -- -D warnings
./script/build.sh
xcodebuild -project macos/Tokenory.xcodeproj -scheme Tokenory \
  -derivedDataPath .build/xcode -destination 'platform=macOS' test
```

测试使用独立数据目录，不写个人用量。`macos/project.yml` 是工程源文件，`.xcodeproj` 由 XcodeGen 生成。

- [使用、备份、恢复及卸载](docs/local/operations.md)
- [客户端支持与本地格式](docs/local/sources.md)
- [本次多客户端验证](docs/local/client-compatibility.md)
- [实施状态与验收边界](docs/local/acceptance.md)
- [历史迁移对账](docs/local/migration.md)
- [估算口径](docs/local/pricing.md)
