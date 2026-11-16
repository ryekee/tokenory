# Codex 实时用量调研

调研日期：2026-11-16。范围：Tokenory 当前采集实现、本机近期三份 rollout 的事件元数据，以及 OpenAI Codex 官方源码 `75fc67e8f4284a669eebd90ab6bc9ef7697e876e`。未修改 Codex 配置、安装 hook 或改变采集机制。

## 结论

优先实现 Codex rollout 文件变化监听及增量入账。它能消除 Tokenory 当前默认 60 秒的扫描等待，使每次模型响应完成后的真实用量及时驱动 HUD。它不能提供单次模型响应尚未完成时的精确 token 消耗。若要求从生成开始持续增长，需要流式估算或独立的活动动效，不能把估算直接记入真实账本。

## 已确认的事实

- Tokenory `Config.interval_seconds` 默认为 60；IPC 在一轮扫描结束后开始计算下一次等待时间。采集完成并持久化后发出 `scanFinished` / `usageChanged`，Swift UsageStore 再读取当日汇总。来源：`cli/tokenory/src/config.rs`、`ipc.rs`、`macos/Tokenory/Stores/UsageStore.swift`。
- Codex 在 `ResponseEvent::Completed` 分支记录 provider usage 并请求发送 token-count；`OutputTextDelta` 分支发送文本片段。这是**每次模型响应**，不是只能等整个用户任务结束。[源码](https://github.com/openai/codex/blob/75fc67e8f4284a669eebd90ab6bc9ef7697e876e/codex-rs/core/src/session/turn.rs#L3560)
- App-server 的 `thread/tokenUsage/updated` 由同一 `TokenCount` 事件转换，改用这个通知不会自然变成逐 token 精确统计。[源码](https://github.com/openai/codex/blob/75fc67e8f4284a669eebd90ab6bc9ef7697e876e/codex-rs/app-server/src/bespoke_event_handling.rs#L1662)
- rollout 持久化 `TokenCount` 和完成项，但文本/推理 delta 属于瞬态事件。已经 materialize 的日志在添加项目后尝试 flush。仅 tail 文件无法取得每个文本流片段；首次 materialize 和 IO 延迟仍需实测。[事件策略](https://github.com/openai/codex/blob/75fc67e8f4284a669eebd90ab6bc9ef7697e876e/codex-rs/rollout/src/policy.rs#L128)、[写入循环](https://github.com/openai/codex/blob/75fc67e8f4284a669eebd90ab6bc9ef7697e876e/codex-rs/rollout/src/recorder.rs#L1969)
- 当前官方 hook 枚举包含 UserPromptSubmit、PostToolUse、Stop 等生命周期事件，没有逐 token usage hook。结束 hook 可触发补采，但不是生成中的计数来源。[schema](https://github.com/openai/codex/blob/75fc67e8f4284a669eebd90ab6bc9ef7697e876e/codex-rs/hooks/src/schema.rs#L103)

## 本机样本

仅检查事件类型、时间戳和用量字段，没有复制提示词或回答内容。当前对话的一个未完成任务在北京时间 18:28:31 开始；已检查区间内，18:28:38.200 至 18:29:56.670 有 8 次 token_count。首个更新距任务开始约 6.8 秒，后续间隔约 4.9–21.0 秒。采样时该任务尚未出现 task_complete。另一个长任务也在完成前持续产生 token_count。

这些是日志内部时间戳，证明事件在任务中途产生；不等于已经测量了磁盘可见延迟或 HUD 端到端延迟。当前安装版本与上游提交也不能视为完全相同。

## 路径比较

| 路径 | 能改善什么 | 边界与成本 |
| --- | --- | --- |
| 文件监听 + 增量采集 | 每次确认用量产生后及时入账，无需用户配置各个任务 | 保留现有解析/去重口径；需要处理新文件、未完整行、截断和重扫恢复；不是逐 token |
| Hook 触发补采 | 任务/工具阶段结束后及时刷新，可补充活动状态 | 事件覆盖有限；需维护 Codex 配置；不能补出尚未发布的准确 usage |
| 同一 app-server 的事件流 | 文本 delta 提供生成活动；usage 通知提供响应结束后的校正值 | 尚未验证 Tokenory 能只读订阅当前桌面 App 持有的会话；另起 app-server 不等于接入现有流 |
| 流式估算 | 可在文本生成期间连续增长 | 文本 delta 不等于完整账单 token，不能完整覆盖隐藏推理、输入和缓存；需显示估算状态并在真实 usage 到达后校正 |

## 建议的最小下一步（尚未实施）

1. Codex 文件变化触发去抖采集，初步目标是新增完整用量事件可见后约 0.25–1 秒进入 HUD；这是设计目标，需测量验证。
2. 优先重用现有 parser 和去重契约。先测量针对变更文件的扫描耗时，再决定是否需要字节偏移增量解析，避免在 watcher 回调中高频全目录重扫。
3. 保留低频扫描用于漏通知、新文件和恢复对账。多个会话增量共同更新当日累计，沿用 HUD 的连续目标追加。
4. 单次长推理中的持续动效另做设计：精确累计与活动状态分开，或经用户确认后加入明确的暂估模式。

## 单位与计价

HUD Tokens 使用 M，保留六位小数，例如 163,704,355 → `163.704355M`；整数 token 仍是动画和账本的输入，最小变化 0.000001M = 1 token。M 是数量单位，不意味着所有输入、输出和缓存 token 使用同一个费率；费用继续沿用各类 token 的现有计价。
