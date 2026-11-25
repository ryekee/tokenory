# Tokenory - 本地 AI 用量和等价费用账本
Swift 6 + SwiftUI + Rust + SQLite + Sparkle 2.10.1

## 模块地图
- `macos/Tokenory/`：原生菜单栏和统计窗口。通过 IPC 调用 Rust worker。超时记录在 macOS 统一日志的 `ee.ryek.tokenory / EngineIPC`。后台读取保留可用读数和内部诊断，需要重试或确认的错误卡片使用警告底色和文字按钮。总览包含洞察、原位日期检查、固定图表读数及工具下的模型聚合。历史导入由 worker 识别格式，保存与重估在原有卡片内反馈。
- `macos/TokenoryTests/`：原生状态、展示和协议测试。
- `cli/tokenory/`：本地账本、采集、导入、计价和 IPC。SQLite 实时监听跳过共享内存通知，手动扫描可在增量采集结束后执行。Codex 子代理活动与用量查询在 `src/codex_subagents`；data 保存离线全量目录。
- 多 Mac 同步：`cli/tokenory/src/device_snapshot.rs` 导出有效账本的用量汇总。原生代码位于 `macos/Tokenory/`，其中 `Models/DeviceUsageSnapshot.swift` 按设备计算总览与活动图，`Services/DeviceCloudSync.swift` 管理私有库的设备授权、快照替换和撤回，`Stores/DeviceSyncStore.swift` 对接本机 worker、云端和界面。
- `cli/tokens-core/`：上游日志解析及价格数据适配。Codex 补计上下文压缩用量，采集 `.jsonl.zst` 历史归档并与文本副本去重。Pi 按日志条目及时间区分独立请求。Devin CLI 按会话内请求去重，Antigravity App、Insiders 与 CLI 直读本地 SQLite 并与旧缓存去重。Copilot 合并 SDK 日志与既有来源，Hermes 按助手消息时间分配累计用量，TRAE CLI 直接读取独立的本机日志。
- `assets/brand/`：产品图标和原生品牌资源的生成源；providers 为生成的全量供应商品牌源。
- `script/`：构建、资源生成、签名和发布入口。
- `DESIGN.md`：UI/UX 设计规范与验收清单。
- `site/`：双语官网、交互式 HUD 演示和正式发布记录。
- `local-data/design-assets/`：本地设计原型、草图和审阅记录。
- `local-data/dev-assets/`：本地开发笔记、决策、验收记录和工具配置副本。编译结果存放在忽略的 `.build/` 和 Cargo `target/`。
- `codex/upstream-sync`：本地分支，跟踪 `upstream/main`。审阅 `cli/tokens-core/` 的增量，测试通过后合入。
- 原生 HUD：`Views/MechanicalHUDView.swift`、`Services/HUDController.swift`；处理双击、三击、闲置自动隐藏和用量唤醒。界面和交互约定见 `DESIGN.md`。

## 入口和约束
- `macos/project.yml`：XcodeGen 项目源。不要手改生成的 Xcode 项目。
- `cli/Cargo.toml`：Rust workspace。
- `script/build_and_run.sh`：构建并启动原生应用。
- `script/generate_brand_icons.py`：由 `assets/brand/` 下的字形和供应商品牌素材生成原生资源。
- `cargo test --manifest-path cli/Cargo.toml -p tokenory`：账本测试。
- `xcodebuild test -project macos/Tokenory.xcodeproj -scheme Tokenory -derivedDataPath .build/xcode -destination 'platform=macOS'`：原生测试。
- 新记录按系统时区归档，已有归档日期及导入日期保留。多 Mac 汇总沿用共同交换时区。
- 价格更新自动回填待计价记录并备份；已有金额重估先预览并备份。
- 源成本、标准费率估算和订阅扣费保持独立。
- 修改模块时更新文件契约、模块地图和对应使用说明。

## 计价维护

- **需要修改计价逻辑**：在 App 端修复对应逻辑，包括 Rust worker。模型归属、请求时间、token 类别或计费规则错误属于此类。
- **模型已正确识别，仅缺少费率**：更新 `cli/tokenory/data/remote-pricing.json`，保留仍有效的条目并递增 `revision`。用 `script/publish_pricing.py` 独立发布到 GitHub `updates` 分支的 `pricing.json`，并验证已发布版本的 App 刷新费率后能回填待计价记录。

## Git 提交

- 提交标题使用 `[标签] 简短摘要`，标签用小写，方括号后留一个空格。例如 `[docs] Clarify backup instructions`。
- 按提交的主要目的选择标签。标签类型参考 [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) 和基于 Angular 约定的 [commitlint 类型列表](https://commitlint.js.org/reference/rules.html#type-enum)。

| 标签 | 用途 |
| --- | --- |
| `[build]` | 构建配置、依赖或打包流程 |
| `[chore]` | 其他日常维护，如更新版本号 |
| `[ci]` | 持续集成和自动部署工作流 |
| `[docs]` | 文档和说明 |
| `[feat]` | 新增或扩展功能 |
| `[fix]` | 修复缺陷 |
| `[perf]` | 提升性能或降低资源占用 |
| `[refactor]` | 调整内部实现并保持现有行为 |
| `[revert]` | 撤回已有提交 |
| `[style]` | 代码格式、缩进或空白调整 |
| `[test]` | 新增或调整测试 |

## UI/UX
- 以 `DESIGN.md` 为具体设计规范，保留已确认的设计。
- 按可见边缘对齐；共享控件放在共同作用范围；二选一使用单击切换，不用下拉菜单增加步骤。说明放在相关内容附近，并提供实际信息。
- 文案参考成熟产品的中英文表达，删除防御性标签和重复说明；保留影响数据理解的依据。布局紧凑，宽窄窗口合理重排。
- 发现问题时检查并修复全局同类问题。关注加载、切页和交互性能。
- 在真实窗口检查中英文、深浅色及宽窄布局。
