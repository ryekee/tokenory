# 实施与验收状态

2026-11-06 更新：42 个客户端入口已接通，Rust workspace **2,515 通过、0 失败、4 忽略**，Clippy `-D warnings` 通过，原生 **13 项 XCTest 通过**，并单独复查了原生读取 42 项客户端目录的真实 helper 协议。此次验证使用独立数据库；在本机日志中实际发现 Claude、Codex、Cline、Copilot 和 MiMo Code 用量。其余客户端的格式支持不等于逐个真实安装验收。详细边界见 [多客户端验证](client-compatibility.md)。

## 2026-11-05 首版验收记录

更新：2026-11-05。**首版本机应用已实现、安装并迁移真实历史；长期系统行为仍待观察。** 安装位置：`~/Applications/Tokenory.app`，版本 0.1.0。本机 Apple Silicon / macOS 27.2，最低 macOS 15。

| 项目 | 验证结果 |
| --- | --- |
| Rust 核心与 CLI | 全 workspace **2,503 通过、0 失败、4 忽略**；包含上游测试 |
| 静态检查 | 全 workspace / all-targets Clippy `-D warnings` 通过；`git diff --check` 通过 |
| 原生 | **4 项 XCTest 通过**：协议/UTF-8/大整数/未知成本，以及真实 helper 启停、错误保留、今日/7 天/30 天跨日、自定义日期不变、恢复失败后重启 |
| 最终审查 | 独立审查的 3 项 Important 全部 RED→GREEN：provider 修正去重、整请求上下文计价、统计窗口相对日期；无未处理发现 |
| 原生界面 | 已观察全部日期统计、工具/提供方筛选、明细和依据、Settings、价格刷新与重估、导入批次和文件选择器；**用户确认菜单栏「查看统计」正常打开窗口** |
| 正式历史迁移 | 两份快照完整保留；重复导入 no-op；Codex 11 月 2 日采用本机 47,876,364；更早 Codex 采用快照；Claude 重叠日采用本机日志 |
| 备份恢复 | 正式备份 **18,254,658,608 tokens** 恢复到独立目录；汇总/日期/工具/提供方/模型/明细及用量、覆盖、批次、价格表一致 |
| DeepSeek | 本机 Claude Code 的 545 条、194,207,906 tokens 已对账；无新增付费请求；历史导入中的其他工具日汇总仍保留原工具 |
| 常驻采集 | 安装版持续保存新增 Codex 用量；Release 常规扫描约 **0.3–0.4 秒**，启动首轮约 1.2 秒；一次 RSS 采样 App 约 154 MiB、helper 约 40 MiB（统计窗口打开，非峰值保证） |
| 安装与签名 | Release 构建、安装目录启动、严格签名校验通过；App/helper 均 arm64；本机 ad-hoc 签名，未公证 |
| 退出 | CUA 正常 Cmd+Q 后 App/helper 均退出；安装版进程收到 SIGTERM 后 helper 通过 EOF 退出，无残留采集进程 |

## 待观察项

- 自然日持续运行、真实睡眠唤醒、开启登录项后的重新登录。登录项默认关闭，未替用户开启。
- 关闭所有窗口后的现场扫描验证、helper 异常时的界面重试、完整原生文件导入/导出/恢复操作、深色模式与窄窗口/键盘检查。底层协议、导入与恢复路径已有测试；CUA 对浮层、文件选择器焦点和无窗口应用的定位不稳定，因此不把尝试操作当作通过。

价格是 API 等价估算。备份核对时已知估算为 $14,301.488704972，562,831,009 tokens 缺可靠费率；未计价项不会显示成免费。持续采集会继续改变当前总数，冻结对账见 [历史迁移](migration.md)。

## 复现入口

```sh
cargo test --manifest-path cli/Cargo.toml
cargo clippy --manifest-path cli/Cargo.toml --all-targets -- -D warnings
./script/build.sh
xcodebuild -project macos/Tokenory.xcodeproj -scheme Tokenory -configuration Debug -derivedDataPath .build/xcode -destination 'platform=macOS' test
TOKENORY_CONFIGURATION=Release ./script/build.sh
```

详细本机验证日志保存在 `.build/verification/2026-11-05/`，个人迁移证据保存在忽略的 `local-data/final-migration-evidence/`。实施取舍见 [决策与审查](implementation-decisions.md)。
