# cli/tokenory/src/
> L2 | Parent: ../../../AGENTS.md

clients.rs: 声明客户端来源和扫描路径。
codex_watch.rs: 监听 Codex 默认/额外/headless 日志根目录及 Antigravity App/CLI SQLite 会话目录，规整 `-wal`/`-shm` 变更并轮询活跃文件/WAL 元数据以覆盖 FSEvents 合并通知。
collector.rs: 只读采集源日志并更新账本及独立回合分析；支持 Codex 与 Antigravity 增量变更采集，Antigravity App 以 responseId 跨 RPC / SQLite 会话迁移、保留原价，增量扫描合并同名数据库副本；只有来自请求的时间参与小时分布，生成表读取不完整时保留账本历史；分析失败只影响诊断，不阻止有效用量更新。Devin CLI 以请求键替换旧行时，沿用同一用量的原价格快照。
turn_analytics.rs / turn_analytics/: 泛化完成回合、来源能力与别名过滤；含 `antigravity.rs` 解析 Antigravity App/CLI 的 SQLite `steps` + `gen_metadata` 主链完成回合与合并工具等待；证据不足不估 token；有效来源重开回合返回精确撤销 ID。Claude 回合只在各回复报告的推理速度一致时返回速度。
codex_turns.rs: 校验完成主回合、缓存未变化日志、保存无正文的统计并按日期/模型查询。按回合开头的同线程、同模型设置保存所选推理速度。
codex_subagents.rs / codex_subagents/logs.rs: 识别明确派生的 Codex 子代理和用户发起的主代理回合，持久化线程、父关系及回合开始证据。用有效账本汇总可归属的 Tokens、已有费用估算和未计价 Tokens，独立计算启动数。
config.rs: 保存采集配置。
db.rs: 维护 SQLite schema、记录和备份；迁移/恢复包含独立回合表；一次升级仅备份一次，自动备份保留 3 份，预览保留 24 小时内最近 3 份。
import.rs: 预览、提交和撤销历史导入。
ipc.rs: 向原生应用提供 worker JSON 协议、有效账本的已用模型、对话目录、按会话查标题、总览子代理卡及 codexTurns / turnAnalytics 查询。
lib.rs: 导出账本引擎模块。
main.rs: 提供 CLI 命令和单写者锁；compact 回收空闲页。
remote_pricing.rs: 拉取并校验官方远程费率表，保留最近一次有效修订。
price_coverage.rs: 从缓存扩展模型覆盖，为未计价记录生成首次估算候选。
pricing.rs: 保存价格快照，计算估算并重估历史。Codex 自动审批用固定参考价。GPT-6.2 支持长上下文、Fast 和按快照日期确定的 Ultrafast 优惠。
queries.rs: 当日用量支持时间戳半开区间，按设备本地午夜查询。按有效来源、筛选和对话查询用量与 Fast tokens、已知估算费用。对话目录按工具与会话 ID 汇总，实时读取 Codex 本地标题索引与 Antigravity `conversation_summaries.db` 标题。activity 聚合日期、工具、模型及小时分布。
usage.rs: 定义用量记录和 token 分类。


price_catalog.rs: 合并全量离线目录、价格缓存和当前规则；只供费率展示。

[PROTOCOL]: Update this header on change, then check AGENTS.md
