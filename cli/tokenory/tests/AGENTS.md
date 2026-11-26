# cli/tokenory/tests/
> L2 | Parent: ../../../AGENTS.md

activity.rs: 验证有效来源、维度与对话筛选、对话搜索、分页独立、未知费用和工具/模型分组下的 Fast tokens 与已知估算费用。
antigravity.rs: 验证 Antigravity App、Insiders 和 CLI SQLite 直读、旧缓存去重、模型枚举不计入 input、小时分布、会话标题、完成回合与工具等待、子代理排除以及 WAL 实时监听推送。回归覆盖空闲 WAL 数据库不重复扫描、旧缓存通知、跨会话账本迁移、历史计价继承、回退时间不分配小时，以及多库与部分读取保护。
storage_retention.rs: 验证自动备份轮替、手工备份保留、预览过期及 ID 不重用、压缩后账本与撤销历史不变、连续升级只备份一次。
backup_restore.rs: 验证备份恢复和修订递增、v6 升级前的自动备份，以及 v7 子代理证据保留和缺表校验。
cli.rs: 验证 cli 的账本接口和行为。
clients.rs: 验证客户端目录、额外扫描路径、快照更新，以及 TRAE CLI 与 Trae 账户缓存的独立归类和归档副本去重。
copilot.rs: 验证 SDK 累计检查点的跨日增量、同会话来源去重、轮转日志缺失和重扫行为。
hermes.rs: 验证历史本机快照跨日分摊，保留费用、费率和归档时区，已导入批次保留原记录，源读取失败时保留本机历史。
turn_analytics.rs: 验证多客户端完成边界、分支排除、分列推理量、筛选目录和 Codex 兼容；续跑撤销、最终恢复、损坏源历史保留及分析失败不阻断账本；Claude 推理速度须由全部回复一致报告。
codex_turns.rs: 验证回合去重、用量对账、未知值、工具阻塞区间、扫描缓存、查询及迁移恢复；所选推理速度归属于回合开头的线程和模型。
codex_archive.rs: 验证文本和压缩副本去重、归档中的新增用量、回合和子代理统计，以及损坏归档对已有记录和其他来源的隔离。
codex_subagents.rs: 验证实际采集和入账中的启动去重、嵌套父会话、主代理开始回合、模型筛选、覆盖选择、费用缺失和既有总览口径。
collection.rs: 验证采集和入账，覆盖 Devin CLI 重扫去重及原价格依据。
coverage.rs: 验证 coverage 的账本接口和行为，包括更换和撤销选中来源后的逐日用量。快照的小时、子代理、隐私和 worker 入口回归分别位于 hourly.rs、codex_subagents.rs 与 ipc.rs。
history_import.rs: 验证 history_import 的账本接口和行为。
hourly.rs: 验证系统时区的小时汇总、夏令时重复小时、不同账本时区在北京午夜附近的设备快照、历史导入保留日期及子代理时间。
identity.rs: 验证 identity 的账本接口和行为。
ipc.rs: 在实际 worker 上验证请求、增量采集中排队手动扫描、带 UTF-8 的快照分块拼接及后续请求。
migration.rs: 验证 migration 的账本接口和行为。
pricing.rs: 验证 pricing 的账本接口和行为，覆盖 Antigravity Claude 5.5 的推理档位及升级补价、GPT-6.2 费率、长上下文、速度及优惠截止边界、远程费率覆盖、OpenClaw 时间依据、MiMo 订阅和长上下文计价依据、免费路由、旧库的首次补价和离线回退。


price_catalog.rs: 验证未使用供应商、峰谷与参考规则、订阅价格边界。

codex_live.rs: 时区切换仅影响新归档、真实 worker 文件监听、打开句柄追加、半行、重复、归档副本与全扫描对账；验证 Codex 压缩用量在变更文件扫描和全量账本中一致。

local_day.rs: 跨账本日期的本地午夜范围、包含起点/排除终点、日汇总回退与历史不变。
pi.rs: 验证重复响应 ID 的独立请求、派生会话去重、旧键迁移时保留的原费用与时区，以及来源损坏或缺失后的历史保留。

[PROTOCOL]: Update this header on change, then check AGENTS.md
