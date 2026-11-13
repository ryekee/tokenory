# Agent 图标与计价覆盖

2026-11-13。42 个入口、40 个解析器。下表是映射覆盖，不代表已安装并实测全部客户端。

所有解析器将记录交给共用计价层。Paseo 使用 Claude / Codex 记录，Orca 使用 MiMo Code 记录。费率按模型和提供方匹配；不从工具品牌推断付费渠道。

| 入口 ID | 图标 |
| --- | --- |
| `amp` | 品牌 `amp` |
| `antigravity` | 品牌 `antigravity` |
| `antigravity-cli` | 品牌 `antigravity` |
| `claude` | 品牌 `claude` |
| `cline` | 品牌 `cline` |
| `codebuddy` | 品牌 `codebuddy` |
| `codebuff` | 品牌 `codebuff` |
| `codex` | 品牌 `openai` |
| `commandcode` | 品牌 `commandcode` |
| `copilot` | 品牌 `githubcopilot` |
| `crush` | 品牌 `crush` |
| `cursor` | 品牌 `cursor` |
| `devin-cli` | 品牌 `devin` |
| `devin-desktop` | 品牌 `devin` |
| `droid` | 品牌 `droid` |
| `fx` | 品牌 `fx` |
| `gemini` | 品牌 `geminicli` |
| `goose` | 品牌 `goose` |
| `grok` | 品牌 `grok` |
| `hermes` | 品牌 `hermesagent` |
| `jcode` | 品牌 `jcode` |
| `junie` | 品牌 `junie` |
| `kilo` | K 字母图标 |
| `kilocode` | 品牌 `kilocode` |
| `kimi` | 品牌 `kimi` |
| `kiro` | 品牌 `kiro` |
| `micode` | 品牌 `xiaomimimo` |
| `mux` | 品牌 `mux` |
| `openclaw` | 品牌 `openclaw` |
| `opencode` | 品牌 `opencode` |
| `opencodereview` | 品牌 `alibaba` |
| `orca` | O 字母图标 |
| `paseo` | P 字母图标 |
| `pi` | 品牌 `pi` |
| `qwen` | 品牌 `qwen` |
| `reasonix` | R 字母图标 |
| `roocode` | 品牌 `roocode` |
| `trae` | 品牌 `trae` |
| `warp` | 品牌 `warp` |
| `workbuddy` | 品牌 `workbuddy` |
| `zcode` | 品牌 `zai` |
| `zed` | 品牌 `zed` |

Kilo（nicepkg）与 Kilo Code（Kilo-Org）是不同项目，不能共用品牌。四个字母图标明确属于展示替代，不声称是官方标识。

## 验证入口

- `BrandPresentationTests`：全部品牌资源实际加载，菜单尺寸，以及工具和模型品牌分离。
- `UsageStoreTests`：从真实 Rust helper 读取 42 个入口，与 Swift 图标映射集合逐项比较。
- `pricing.rs` 集成测试：40 个解析器 ID 使用相同模型费率；缓存首次回填、已有金额不变、来源身份不变、未知模型不误计价。
- `clients.rs`、`collection.rs` 等既有测试：验证真实适配器样例、去重和会话快照。

[计价规则](pricing.md) 定义未知提供方参考估算、归档费率及不能定价的情况。

## 本次验收结果

- 账本测试：48 项通过。计价子集 19 项通过。
- 原生 XCTest：17 项通过；包含真实 helper 的 42 项目录与图标映射比较。
- 真实账本副本：待计价 tokens 从 58,500,491 降到 76,270，增加参考估算 $13.3690667416。token 总量不变。
- 后续按用户选择，Devin CLI 的 `compactor` 已用 GPT-6 Luna 标准价做参考估算；真实代际仍未确认。见 [调查与决策](devin-compactor.md)。零 token 的 `<synthetic>` 不产生费用。
- 未逐一安装并运行 42 个工具；适配器格式仍由项目样例测试验证。
