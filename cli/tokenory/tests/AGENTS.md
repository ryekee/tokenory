# cli/tokenory/tests/
> L2 | Parent: ../../../AGENTS.md

activity.rs: 验证真实有效来源、维度过滤、分页独立和未知费用。
storage_retention.rs: 验证自动备份轮替、手工备份保留、预览过期及 ID 不重用、压缩后账本与撤销历史不变、连续升级只备份一次。
backup_restore.rs: 验证 backup_restore 的账本接口和行为。
cli.rs: 验证 cli 的账本接口和行为。
clients.rs: 验证 clients 的账本接口和行为。
turn_analytics.rs: 验证多客户端完成边界、分支排除、分列推理量、筛选目录和 Codex 兼容；续跑撤销、最终恢复、损坏源历史保留及分析失败不阻断账本。
codex_turns.rs: 验证回合去重、用量对账、未知值、工具阻塞区间、扫描缓存、查询及迁移恢复。
collection.rs: 验证 collection 的账本接口和行为。
coverage.rs: 验证 coverage 的账本接口和行为。
history_import.rs: 验证 history_import 的账本接口和行为。
hourly.rs: 验证 hourly 的账本接口和行为。
identity.rs: 验证 identity 的账本接口和行为。
ipc.rs: 验证 ipc 的账本接口和行为。
migration.rs: 验证 migration 的账本接口和行为。
pricing.rs: 验证 pricing 的账本接口和行为，覆盖 GPT-6.2 费率、长上下文、速度及优惠截止边界。


price_catalog.rs: 验证未使用供应商、峰谷与参考规则、订阅价格边界。

codex_live.rs: 真正的 worker 文件监听、打开句柄追加、半行、重复、归档副本与全扫描对账。

local_day.rs: 跨账本日期的本地午夜范围、包含起点/排除终点、日汇总回退与历史不变。

[PROTOCOL]: Update this header on change, then check AGENTS.md
