# 已接入来源

| 来源 | 数据入口 | 身份与口径 | 当前状态 |
| --- | --- | --- | --- |
| Claude Code | `~/.claude/projects/**/*.jsonl` | message/request 稳定身份；流式更新覆盖；input/cache/output 分开 | 本机真实记录与持久化测试通过 |
| Codex | `~/.codex/sessions`、`archived_sessions` | 累计 usage 转增量；上游处理 replay/fork；重扫不累加 | 本机持续产生的新记录已入库 |
| DeepSeek 官方 API | Claude Code 的 Anthropic 兼容日志 | 仍归工具 Claude Code；提供方 DeepSeek；已有 input 为 cache miss，cache read 为 hit；output 包括未单列的推理 | **用户确认只曾通过本机 Claude Code 使用**；545 条、194,207,906 tokens 已采集与对账 |
| CC Switch | 原始 Claude 日汇总 JSON | 165 行、96 天；input 已分离缓存，不再减一次 | 历史导入通过 |
| tokens.ci | profile JSON 内实际日/工具/模型单元 | 436 行；顶层/模型总表只校验；未知提供方保持 unknown | 历史导入通过，包含 Codex / Claude / MiCode / Cline / Copilot |

DeepSeek 已有记录包括 `deepseek-flash`（523 条，191,977,939 tokens）和 `deepseek-v4-pro`（22 条，2,229,967 tokens）。没有额外请求 DeepSeek API，也没有新增全流量代理或余额差分推断。重复响应只保存一个事件；不同响应即使 token 数相同也分别计数。只有同一个已验证日志入口参与实时采集，因此没有再导入第二份账户级消耗。

源日志部分写入、读取失败会在来源状态中显示；受影响工具保留上次有效记录，下一次完整扫描恢复。已经删除的日志不删除数据库历史。固定日界为 Asia/Shanghai；原始历史汇总日期保持原样。

当前首版只启用经过本机验证的 Claude/Codex 采集器。MiCode、Cline、Copilot 当前仅有历史导入；未声称其持续采集已验证。未保存 usage 的 DeepSeek 请求不能从现有日志恢复，缺少的推理细分不凭空生成。
