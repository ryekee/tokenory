# Agent Speed：42 个目录入口的格式覆盖

速度按**完成的用户回合**计算。计入该回合内完整、可归属到同一实际模型的生成用量。请求 latency、会话跨度、文件修改时间和文本长度估算都不能替代相应测量。非 Codex 原生转录使用事件时间差，标记为估算；未记录的推理 token、请求数、工具数、首 token 延迟和工具等待保持未知。实现只写入 ID、时间、工作区名称、模型和计数。

当前 14 个客户端有至少一种可用格式，另有 2 个委托入口；26 个入口待补采或继续核验。

以下文件路径相对于 `cli/tokens-core/src/sessions/`。字段描述的是已核验的输入范围；「证据不足」表示当前解析路径及样例未建立必要契约。

| 入口 | 状态 | 字段证据及下一步 |
| --- | --- | --- |
| Amp | 未接入 | `amp.rs`：线程消息 `usage` 或 `usageLedger` 有模型、请求 token 和单时间点。需要每个用户回合的结束标志，以及 ledger 到回合的稳定关联。 |
| Antigravity | 已接入部分格式 | `antigravity_cli.rs` + `turn_analytics/antigravity.rs`：直读 `~/.gemini/antigravity/conversations/*.db`（及 `antigravity-ide`），以 `steps` 表 `USER_INPUT`（`step_type=14, source=4`）为起点、同回合 UUID（`metadata.#12`）内无工具调用且带正文响应的终态 `PLANNER_RESPONSE`（`step_type=15, status=3`）为终点，关联 `gen_metadata` 实测输出/推理并合并同步工具步骤（`status=3/7`）阻塞时间；排除 `parent_references` 子代理库及报错/未完成回合。旧版 RPC JSONL 缓存缺回合边界仍只计用量。 |
| Antigravity CLI | 已接入 | `antigravity_cli.rs` + `turn_analytics/antigravity.rs`：直读 `~/.gemini/antigravity-cli/conversations/*.db`，沿用与 Antigravity App 相同的 `steps` + `gen_metadata` 回合契约、子代理排除与工具阻塞时间合并逻辑。 |
| Claude Code | 已接入 | `claudecode.rs`：主链 `sessionId`、用户 `uuid`、事件 `timestamp`、`message.id/usage.output_tokens/stop_reason`。工具结果和 agent 子链不构成用户起点；同 ID 响应块累计去重。 |
| Cline | 已接入部分格式 | 扩展 `ui_messages.json` 的 `say:task/user_feedback` 至最终 `ask:completion_result`；汇总有 `modelInfo.modelId` 和实测 `api_req_started.tokensOut` 的请求，排除取消/重试。CLI `messages[].metrics` 未核验相同终态。 |
| CodeBuddy | 未接入 | `codebuddy.rs`、`tencent_buddy.rs`：`status=completed` 是 assistant 消息状态；函数调用另记，同一请求可共享 `providerData.messageId`。需要明确用户回合结束及请求关联，不能把消息完成当回合完成。 |
| Codebuff | 未接入 | `codebuff.rs`：聊天快照中的 assistant `timestamp/createdAt`、`usage`，部分值按消息提取。需要为每个完整用户回合提供稳定起止和请求归属。 |
| Codex | 已接入 | `codex.rs`：原生 `task_started/task_complete`、`token_usage_record`、`turn_context`、工具调用及结果；过滤 fork 与子代理。 |
| Command Code | 未接入 | `commandcode.rs`：`message`、`model_change`、使用量及角色；文本可估算用量。需要最终成功状态，并区分有提供方计数和纯估算的记录。 |
| GitHub Copilot | 证据不足 | `copilot.rs`：OTel `chat` 是模型调用，`copilot_chat.agent.turn` 可能只有结束事件，`invoke_agent` 是包含嵌套 span 的父调用。须核验哪种 root span 一对一对应用户回合，且可确认成功与全部子请求。Desktop 的 `session.shutdown` 是累计量；VS Code 请求 `result.metadata` 缺结束时间。 |
| Crush | 未接入 | `crush.rs`：`sessions.cost` 可用，消息只支持分配成本所在日期。需实际请求输出计数和回合边界。 |
| Cursor | 未接入 | `cursor.rs`：Usage Events 有 session UUID、模型、单时间点和用量；聚合结构也存在。需要关联用户回合和明确开始/完成时间。 |
| Devin CLI | 已接入 | `devin.rs`：SQLite `sessions.main_chain_id`、`message_nodes.parent_node_id`、`metadata.is_user_input/created_at/request_id/generation_model/metrics.output_tokens/finish_reason`。老库缺主链字段的样本仍只做用量。 |
| Devin Desktop | 未接入 | `devin.rs`：ACP `usage_update` 和增量去重；会话标题存在关联歧义。需捕获 ACP prompt 请求、终态响应和已确认属于该请求的用量。 |
| Factory Droid | 未接入 | `droid.rs`：settings 的 `tokenUsage` 是会话累计，`providerLockTimestamp` 是路由配置时间；转录时间可帮助定日期。需要逐回合实测 token 与终态。 |
| Fx | 未接入 | `fx.rs`：`usage.json` 按模型合计，`lastSession` 是会话快照，`session.json` 提供会话时间。需要逐回合导出。 |
| Gemini CLI | 已接入部分格式 | Headless stream JSONL 的 `init`、单用户 `message`、成功 `result` 三类事件。仅接受单一实际模型、无工具调用、`total_tokens=input_tokens+output_tokens` 的导出，避免漏算推理输出。请求数未知。交互快照没有同样的完成契约。 |
| Goose | 未接入 | `goose.rs`：SQLite 会话级 `created_at`、模型和累计输入/输出；无可分配的回合用量。需导出逐回合事件。 |
| Grok Build | 证据不足 | `grok.rs`：`unified.jsonl` 支持进程、请求去重、会话、模型和子代理完成事件；子代理终态不是用户回合终态。需确认主代理开始/完成和请求归属事件。 |
| Hermes Agent | 未接入 | `hermes.rs`：`sessions` 和 `session_model_usage` 是会话/模型/提供方汇总。需逐回合导出实际计数与起止。 |
| Jcode | 未接入 | `jcode.rs`：snapshot/journal 有 assistant `id/timestamp/token_usage/tool_duration_ms`，模型只在会话层，路由切换可能错归历史；缺完成标志。需记录逐响应实际模型及回合终态。 |
| Junie | 未接入 | `junie.rs`：`UserPromptEvent` 与 `LlmResponseMetadataEvent` 可读，`usage.time` 是响应耗时；`modelUsage[].model` 提供模型。需核验用户回合最后响应或明确结束事件。 |
| Kilo | 已接入 | `kilo.rs`、`opencode_schema.rs`：共用 OpenCode schema。具备 `parentID`、`time`、`tokens` 和 `finish` 的 SQLite 行才计算；不使用用量解析器的时间回退。 |
| Kilo Code | 未接入 | `kilocode.rs`、`roocode.rs`：UI `api_req_started` 的嵌入 payload 有模型/用量。需配对用户开始与成功完成，并区分部分更新和重试。 |
| Kimi | 已接入部分格式 | Kimi Code 主 agent wire 中 `turn.prompt/turn.ended` 有明确 ID、时间和结束原因；用 step UUID 计数并与 `usageScope=turn` 的模型和实测输出核对。老 Kimi CLI 的 `TurnBegin` 和 `StatusUpdate.token_usage` 可读，但已知 fixture 无可信终态，模型来自当前配置。 |
| Kiro | 未接入 | `kiro.rs`：IDE `turn_end` 或 execution status、CLI `user_turn_metadatas[].end_timestamp`、SQLite 请求起止可见；CLI 定义 `output_token_count`，现有样例为零，尚未验证实际计数的可用性；模型只在会话状态。需核验正向实测样例并记录逐回合实际模型。 |
| MiMo Code | 已接入 | `micode.rs`、`opencode_schema.rs`：有 `session` 主链标识及 `message` 的 `parentID/finish/time/tokens`；写入 `micode`。 |
| Mux | 未接入 | `mux.rs`：会话级 per-model buckets，`lastRequest.timestamp` 是单点。需要逐回合起止与 token。 |
| OpenClaw | 已接入部分格式 | `openclaw.rs`：有 entry `id/parentId/timestamp` 和 `message.stopReason/usage.output` 的线性 JSONL（包括压缩）及 SQLite `transcript_events`；匹配 Codex rollout 的镜像不单独作为回合。无主链证据的分支及旧转录跳过。 |
| OpenCode | 已接入部分格式 | `opencode.rs`、`opencode_schema.rs`：支持原始 JSON storage、SQLite v1 的 `parentID/finish`，以及 SQLite v2 `session_message.seq`、`idle.outcome=succeeded` 和 inline tool 内容；同库 v2 优先。主链资料不足时跳过。 |
| OpenCodeReview | 未接入 | `opencodereview.rs`：`llm_response` 的 `timestamp/duration_ms/usage.completion_tokens` 只描述调用。需导出 review 用户回合及相关请求 ID。 |
| Pi | 已接入部分格式 | `pi.rs`：`session.id`、entry `id/parentId/timestamp`、`message.usage.output` 和实际模型。上游 `stopReason=stop` 且无工具调用作为转录结束估计。只接受有父链接的线性 transcript；fork 可能拷贝历史，需要可验证的分支写入边界。 |
| Qwen Code | 已接入部分格式 | 新版主转录有 `uuid/parentUuid`、用户 `promptId/daemonPromptId`、assistant 的 `model/usageMetadata`、已完成 `system:turn_result.systemPayload.startedAt/endedAt`。要求匹配 daemon prompt，跳过旧快照、分支和 retry。 |
| Reasonix | 未接入 | `reasonix.rs`：授权统计 `ts/model/completion/reasoning` 逐请求；独立转录没有实际 token。需共同的请求/回合标识及边界。 |
| Roo Code | 未接入 | `roocode.rs`：UI 的 `api_req_started` 有 `ts` 和 token，最终 `ask:completion_result` 可确定结束。旧日志的时间和会话级模型推断不足以定位请求；需稳定的逐请求实际模型、请求时间和重试身份。 |
| Trae | 未接入 | `trae.rs`：`usage_time` 和请求/用量记录没有用户回合区间。需逐回合事件关联。 |
| Warp | 未接入 | `warp.rs`：cache 提供 overall/workspace 汇总及更新时间。需逐回合事件导出。 |
| WorkBuddy | 未接入 | `workbuddy.rs`、`tencent_buddy.rs`：事件记录和扩展日志有请求 ID 与 token；旧 DB 只有聚合；需独立的用户回合完成边界及请求关联。 |
| ZCode | 未接入 | `zcode.rs`：`model_usage` 的 `started_at/completed_at/duration_ms` 是请求；旧 JSONL 角色记录可以估算文本但未证实终态。需可靠把请求与用户回合匹配。 |
| Zed | 未接入 | `zed.rs`：SQLite `threads.data` 线程快照含 token 信息、创建/更新时间，不能据此拆成完成回合。需完整逐回合事件与实测统计。 |
| Paseo | 委托 | `../paseo.rs` 发现 Claude/Codex 原生转录；界面筛选覆盖这两个客户端的全部可用会话，无法隔离 Paseo 启动的部分。汇总沿用原始客户端记录，不重复计入。 |
| Orca | 委托 | `../scanner.rs` 将 Orca sandbox 中的 MiMo DB 加入 `micode`；界面筛选覆盖全部可用 MiMo Code 会话，无法仅隔离 Orca。汇总沿用原记录。 |

上游核对：[Pi agent lifecycle](https://github.com/earendil-works/pi/blob/main/packages/agent/README.md)、[OpenClaw token use](https://github.com/openclaw/openclaw/blob/main/docs/reference/token-use.md)、[OpenCode finish/parent contract](https://github.com/anomalyco/opencode/issues/49414)。

其他上游证据：[OpenCode v2 session messages](https://github.com/anomalyco/opencode/blob/dev/packages/schema/src/session-message.ts)、[OpenCode v1 JSON storage](https://github.com/anomalyco/opencode/blob/v1.1.60/packages/opencode/src/session/index.ts)、[Kimi Code turn journal](https://github.com/MoonshotAI/kimi-code/blob/main/packages/agent-core-v2/src/agent/loop/journal.ts)、[Gemini headless CLI](https://github.com/google-gemini/gemini-cli/blob/main/packages/cli/src/nonInteractiveCli.ts)、[Gemini stream stats](https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/output/stream-json-formatter.ts)。

若 Gemini 未默认写入 headless 输出，可执行 `gemini --prompt "…" --output-format stream-json > run.jsonl`，再把导出目录添加到 Gemini CLI 的额外日志路径。

[Cline v3.72.0 请求与 UI 日志](https://github.com/cline/cline/blob/v3.72.0/src/core/task/index.ts)、[Cline 完成处理](https://github.com/cline/cline/blob/v3.72.0/src/core/task/tools/handlers/AttemptCompletionHandler.ts)、[Qwen 记录和终态](https://github.com/QwenLM/qwen-code/blob/970e1d6ea23b4855aeb60b8dcbec15ad3fb96e57/packages/core/src/services/chatRecordingService.ts)。
