# cli/tokenory/src/
> L2 | Parent: ../../../AGENTS.md

clients.rs: 声明客户端来源和扫描路径，包括 Copilot SDK 日志与独立的 TRAE CLI。
codex_watch.rs: 监听 Codex 默认/额外/headless 根目录中的 `.jsonl` 和 `.jsonl.zst`，以及 Antigravity App、Insiders 和 CLI 的 SQLite 会话目录。忽略只反映 SQLite 读锁的 `-shm` 通知，规整 `-wal` 等数据变更并轮询活跃文件/WAL 元数据以覆盖 FSEvents 合并通知。
collector.rs: 只读采集源日志并更新账本及独立回合分析。支持 Codex 与 Antigravity 增量采集，Antigravity App 以 responseId 跨 RPC / SQLite 会话迁移并保留原价，增量扫描合并同名数据库副本。生成表读取不完整或 Copilot SDK 轮转日志缺失时保留已采历史。只有来自请求的时间参与小时分布。分析失败只影响诊断。Devin CLI 和 Pi 在确认是同一请求后替换旧键，沿用原价格快照。
collector/hermes.rs: 替换 Hermes 本机会话快照时，按原用量组保留历史费用和归档时区。后续同组增加的用量沿用原费率依据。
turn_analytics.rs / turn_analytics/: 泛化完成回合、来源能力与别名过滤；含 `antigravity.rs` 解析 Antigravity App/CLI 的 SQLite `steps` + `gen_metadata` 主链完成回合与合并工具等待；证据不足不估 token；有效来源重开回合返回精确撤销 ID。Claude 回合只在各回复报告的推理速度一致时返回速度。
codex_turns.rs: 从文本日志和压缩归档校验完成主回合，缓存未变化日志，保存无正文的统计并按日期和模型查询。按回合开头的同线程、同模型设置保存所选推理速度。
codex_subagents.rs / codex_subagents/logs.rs: 从文本日志和压缩归档识别明确派生的 Codex 子代理和用户发起的主代理回合，持久化线程、父关系及回合开始证据。用有效账本汇总可归属的 Tokens、已有费用估算和未计价 Tokens，独立计算启动数。
config.rs: 读取系统时区用于新记录归档并保存采集配置；读取扫描器实际默认路径，拒绝新添重复目录并保留历史配置。
db.rs: 维护 SQLite schema、记录和备份；迁移/恢复包含独立回合表；一次升级仅备份一次，自动备份保留 3 份，预览保留 24 小时内最近 3 份。
device_snapshot.rs: 从单一 SQLite 读事务导出全部有效历史、可筛选的子代理启动数和按工具、来源、供应商、模型分组的用量。云端事件按北京时间分日分小时，按日导入和近似时间保留原日期，仅聚合字段出账本。
import.rs: 预览、提交和撤销历史导入。
ipc.rs: 每次开始扫描时读取系统时区，增量采集中收到手动扫描请求时在增量批次后启动一次全量扫描。向原生应用提供 worker JSON 协议、默认采集路径、有效账本的已用模型、对话目录、按会话查标题、总览子代理卡及 codexTurns / turnAnalytics 查询。列表用的 turnAnalytics 可附按工具和会话分组的本地标题，供速度页搜索。时间戳窗口查询省略标题。`dailySourceUsage` 接受空对象，一次返回全部日期的有效用量，每行仅有 date、client、source、tokens。 `deviceUsageSnapshot` 接受 `stream: true`，按同一请求 ID 返回有序 UTF-8 分块及完成帧。旧单帧请求超过 64 MiB 时返回可恢复错误。
lib.rs: 导出账本引擎模块。
main.rs: 提供 CLI 命令和单写者锁；compact 回收空闲页。
remote_pricing.rs: 拉取并校验官方远程费率表，保留最近一次有效修订。
price_coverage.rs: 从缓存扩展模型覆盖，为未计价记录生成首次估算候选；用 OpenClaw 原生事件键核验请求时间，保留文件时间回退与按日聚合的边界。
pricing.rs: 保存价格快照，计算估算并重估历史。Antigravity 的 Opus 5.5 和 Sonnet 5.5 推理档位从有效基础费率派生，升级时补齐待估价记录。Codex 自动审批用固定参考价。小米 Token Plan 使用对应 MiMo API 美元参考价，MiMo v2 Pro 的计价依据标明是否应用长上下文费率。OpenRouter 已验证的 Step 3.5 Flash 免费路由为零。GPT-6.2 支持长上下文、Fast 和按快照日期确定的 Ultrafast 优惠。
queries.rs: 当日用量支持时间戳半开区间，按设备本地午夜查询。按有效来源、筛选和对话查询用量与 Fast tokens、已知估算费用。对话目录按工具与会话 ID 汇总，实时读取 Codex 本地标题索引以及 Antigravity App、Insiders 和 CLI 的 `conversation_summaries.db`。activity 聚合归档日期、工具、模型及按系统时区分配的小时用量。daily_source_usage 按账本日期、工具与选中来源汇总 Tokens。
usage.rs: 定义用量记录和 token 分类。


price_catalog.rs: 合并全量离线目录、价格缓存和当前规则；只供费率展示。

[PROTOCOL]: Update this header on change, then check AGENTS.md
