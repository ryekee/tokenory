# Tokenory - 本地 AI 用量和等价费用账本
Swift 6 + SwiftUI + Rust + SQLite + Sparkle 2.10.1

## 模块地图
- `macos/Tokenory/`：原生菜单栏和统计窗口。通过 IPC 调用 Rust worker。
- `macos/TokenoryTests/`：原生状态、展示和协议测试。
- `cli/tokenory/`：本地账本、采集、导入、计价和 IPC；Codex 子代理活动与用量查询在 `src/codex_subagents`；data 保存离线全量目录。
- `cli/tokens-core/`：上游日志解析及价格数据适配。Codex 补计上下文压缩用量，Devin CLI 按会话内请求去重，Antigravity App 与 CLI 直读本地 SQLite 并与旧缓存去重。
- `cli/tokens-cli/`：上游 CLI。
- `assets/brand/`：品牌设计及供应商图标源文件；providers 为生成的全量品牌源。
- `script/`：构建、资源生成、签名和发布入口。
- `DESIGN.md`：UI/UX 设计规范与验收清单。
- `docs/design/`：文案审阅和历史设计记录。
- `docs/prototypes/mechanical-hud/`：已确认的独立网页原型，保留供未来官网使用。
- `site/`：双语官网、交互式 HUD 演示和正式发布记录。
- `docs/local/`：计价口径、数据来源和维护说明。
- `web/`、`packages/`、`scripts/`、`deploy/`：保留的上游 Web、包及部署工具。
- `local-data/`：本地开发数据。
- 原生 HUD：`Views/MechanicalHUDView.swift`、`Services/HUDController.swift`；全屏避让、数据口径与音效见 `docs/local/mechanical-hud.md`。

## 入口和约束
- `macos/project.yml`：XcodeGen 项目源。不要手改生成的 Xcode 项目。
- `cli/Cargo.toml`：Rust workspace。
- `script/build_and_run.sh`：构建并启动原生应用。
- `script/generate_brand_icons.py`：由 Web 字形和 vendor SVG 生成原生资源。
- `cargo test --manifest-path cli/Cargo.toml -p tokenory`：账本测试。
- `xcodebuild test -project macos/Tokenory.xcodeproj -scheme Tokenory -derivedDataPath .build/xcode -destination 'platform=macOS'`：原生测试。
- 价格更新自动回填待计价记录并备份；已有金额重估先预览并备份。
- 源成本、标准费率估算和订阅扣费保持独立。
- 修改模块时更新文件契约、模块地图和对应使用说明。

## UI/UX
- 以 `DESIGN.md` 为具体设计规范，保留已确认的设计。
- 按可见边缘对齐；共享控件放在共同作用范围；二选一使用单击切换，不用下拉菜单增加步骤。说明放在相关内容附近，并提供实际信息。
- 文案参考成熟产品的中英文表达，删除防御性标签和重复说明；保留影响数据理解的依据。布局紧凑，宽窄窗口合理重排。
- 发现问题时检查并修复全局同类问题。关注加载、切页和交互性能。
- 在真实窗口检查中英文、深浅色及宽窄布局。
