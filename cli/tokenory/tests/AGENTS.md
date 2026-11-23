# cli/tokenory/tests/
> L2 | Parent: ../../../AGENTS.md

activity.rs: 验证有效来源、维度与对话筛选、对话搜索、分页独立、未知费用和工具/模型分组下的 Fast tokens 与已知估算费用。
antigravity.rs: 验证 Antigravity App/CLI SQLite 直读、旧缓存去重、模型枚举不计入 input、小时分布、会话标题、完成回合与工具等待、子代理排除以及 WAL 实时监听推送。回归覆盖旧缓存通知、跨会话账本迁移、历史计价继承、回退时间不分配小时，以及多库与部分读取保护。
storage_retention.rs: 验证自动备份轮替、手工备份保留、预览过期及 ID 不重用、压缩后账本与撤销历史不变、连续升级只备份一次。
backup_restore.rs: 验证 backup_restore 的账本接口和行为。
cli.rs: 验证 cli 的账本接口和行为。
clients.rs: 验证 clients 的账本接口和行为。
turn_analytics.rs: 验证多客户端完成边界、分支排除、分列推理量、筛选目录和 Codex 兼容；续跑撤销、最终恢复、损坏源历史保留及分析失败不阻断账本；Claude 推理速度须由全部回复一致报告。
codex_turns.rs: 验证回合去重、用量对账、未知值、工具阻塞区间、扫描缓存、查询及迁移恢复；所选推理速度归属于回合开头的线程和模型。
codex_subagents.rs: 验证实际采集和入账中的启动去重、嵌套父会话、主代理开始回合、模型筛选、覆盖选择、费用缺失和既有总览口径。
collection.rs: 验证采集和入账，覆盖 Devin CLI 重扫去重及原价格依据。
coverage.rs: 验证 coverage 的账本接口和行为。
history_import.rs: 验证 history_import 的账本接口和行为。
hourly.rs: 验证 hourly 的账本接口和行为。
identity.rs: 验证 identity 的账本接口和行为。
ipc.rs: 验证 worker 请求与响应。快照的小时、子代理、隐私和 worker 入口回归分别位于 hourly.rs、codex_subagents.rs 与 ipc.rs。
migration.rs: 验证 migration 的账本接口和行为。
pricing.rs: 验证 pricing 的账本接口和行为，覆盖 GPT-6.2 费率、长上下文、速度及优惠截止边界、远程费率覆盖、OpenClaw 时间依据、MiMo 订阅与免费路由、旧库的首次补价和离线回退。


price_catalog.rs: 验证未使用供应商、峰谷与参考规则、订阅价格边界。

codex_live.rs: 真正的 worker 文件监听、打开句柄追加、半行、重复、归档副本与全扫描对账；验证 Codex 压缩用量在变更文件扫描和全量账本中一致。

local_day.rs: 跨账本日期的本地午夜范围、包含起点/排除终点、日汇总回退与历史不变。

[PROTOCOL]: Update this header on change, then check AGENTS.md
