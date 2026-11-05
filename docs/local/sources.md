# 客户端与来源

更新：2026-11-06。Tokenory 启用截图中的 **42 个客户端入口，对应 40 个上游解析器**。Paseo 和 Orca 使用底层客户端数据，不再增加一份计数。支持集合由 `cli/tokenory/src/clients.rs` 定义，通过 helper 的 `sources` 协议提供给原生界面。

## 自动发现

| 类型 | 客户端 | 读取方式 |
| --- | --- | --- |
| Claude 及兼容日志 | Claude Code、Command Code、CodeBuddy、WorkBuddy、OpenCodeReview、ZCode | JSONL；WorkBuddy / ZCode 还支持数据库 |
| 其他会话日志 | Amp、Codex CLI、Gemini CLI、Droid、OpenClaw、Pi、Kimi、Qwen、Jcode、Junie、Grok Build、Reasonix、Codebuff、Fx、Mux | 上游规定的 JSON / JSONL 文件；OpenClaw 还支持 SQLite |
| 编辑器记录 | Cline、Roo Code、Kilo、Kiro、Copilot | 编辑器任务、CLI 日志或对应数据库；Roo/Kilo 已补 macOS 原生 VS Code 路径 |
| SQLite | OpenCode、Kilo CLI、MiMo Code、Goose、Hermes Agent、Crush、Zed Agent、Devin CLI、Antigravity CLI | 只读数据库；OpenCode / Hermes 也保留上游文件格式支持 |
| 桌面事件 | Devin Desktop | ACP NDJSON，沿用上游与 Devin CLI 的重叠处理 |
| 已有缓存 | Cursor、Trae、Warp、Antigravity IDE | 上游同步产生的本地 JSON / JSONL / CSV |
| 启动器 | Paseo、Orca | Paseo 配置指定的 Claude/Codex 目录；Orca 的 MiMo Code 沙箱数据库 |

默认路径及格式继承固定上游基线的 `cli/tokens-core/src/clients.rs` 和 `scanner.rs`，包含归档、编辑器及已知备用目录。App 不依赖从终端继承的环境变量。非标准位置在「设置 → 采集」中配置绝对路径，每行一个目录。已有额外目录在切换工具后仍保留。

Kilo CLI、Crush、Goose、MiMo Code 使用上游的数据库发现入口，目前没有额外目录编辑项。Paseo 从 `~/.paseo/config.json` 读取 provider 目录。Orca 从 `~/Library/Application Support/orca/mimocode-hooks/shared/data/` 读取数据库。Zed 仅统计 Zed 托管模型，外部 ACP 工具由其自身日志统计。

## 需要先生成缓存的客户端

这四种入口不能仅靠安装客户端完成采集。下列命令属于保留的上游 **`tokens` CLI**，不是本地 **`tokenory` helper**。如需要同步，可从本仓库构建上游 CLI：`cargo build --manifest-path cli/Cargo.toml -p tokens-cli`，然后使用 `cli/target/debug/tokens`。只执行需要的登录 / 同步命令即可，无需执行 `submit`。

| 客户端 | 默认缓存 | 上游缓存生成命令 |
| --- | --- | --- |
| Cursor | `~/.config/tokens/cursor-cache/usage*.json`，兼容 CSV | `tokens cursor login`，`tokens cursor sync --json` |
| Trae | `~/.config/tokens/trae-cache/sessions/*.json` | `tokens trae login`，`tokens trae sync` |
| Warp | `~/.config/tokens/warp-cache/usage*.json` | `tokens warp login`，`tokens warp sync` |
| Antigravity IDE | `~/.config/tokens/antigravity-cache/sessions/*.jsonl` | 客户端运行时执行 `tokens antigravity sync` |

Tokenory App 自动读取缓存，但不自动运行这些命令。同步频率决定缓存的新鲜度。自定义缓存路径可以在对应工具的额外目录中添加。Antigravity CLI 直接读取其本地会话数据库，不依赖 IDE 缓存。

## 持久化口径

- Claude / Codex 保留原有稳定事件键、流式更新和累计值转增量规则。已存日期不随显示设置变化。
- 新启用的解析器可能没有事件 ID，或只返回会话累计值。按客户端与会话保存最新可读快照，原子替换该会话的旧模型/记录。重复扫描不累加，旧的同会话累计值不与新值相加。
- 完整会话不再出现在源文件中时，保留已存历史。仍可读取的会话采用当前源快照，因此有效文件中的修正、记录删除和模型归属变化会反映到本地账本。
- token 字段沿用上游解析口径，部分旧格式（例如旧版 Command Code）可能由上游估算，不能视为服务商实测账单。
- 不把累计会话或账单时间当成真实请求时间。新增解析器统一标记为 `sourceRecord`，按上游时间归日，暂不分配小时。Warp / Crush 可能只有请求数或费用，没有 token 明细。
- JSON / JSONL 部分写入或读取失败、数据库无法打开时，受影响客户端保留上一轮数据。上游解析器仍可能跳过结构不支持的行；来源页的“未发现用量记录”不代表源文件全部有效。
- 未安装或没有文件的工具不显示为空卡片，完整支持列表可在来源页展开。没有可靠费率时保留未计价状态。
- 已有历史导入的来源选择继续有效。新采集的同日工具数据不会自动叠加到已选择的历史快照。

## 历史导入与 DeepSeek

CC Switch 的原始 Claude 日汇总 JSON，以及 tokens.ci profile JSON 的实际日/工具/模型单元均可导入。未知时区保留源日期，顶层总表用于校验，不作为第二份用量添加。

本机 DeepSeek 数据来自 Claude Code 的 Anthropic 兼容日志，工具仍归 Claude Code，提供方归 DeepSeek。没有新增代理或余额差分推断。未保存 usage 的请求无法从现有日志恢复，缺少的推理细分不生成模拟数据。原有迁移与真实记录对账见 [历史迁移](migration.md) 和 [历史来源审计](source-audit.md)。

多客户端接入的自动化验证见 [兼容性验证](client-compatibility.md)。本机真实 Claude/Codex 验收与其余客户端的格式测试分别记录。
