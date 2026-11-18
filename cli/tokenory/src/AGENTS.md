# cli/tokenory/src/
> L2 | Parent: ../../../AGENTS.md

clients.rs: 声明客户端来源和扫描路径。
codex_watch.rs: 监听 Codex 默认/额外/headless 日志根目录，检查活跃日志元数据以覆盖 FSEvents 合并的追加通知。
collector.rs: 只读采集源日志并更新账本及独立回合分析；分析失败只影响诊断，不阻止有效用量更新。Devin CLI 以请求键替换旧行时，沿用同一用量的原价格快照。
turn_analytics.rs / turn_analytics/: 泛化完成回合、来源能力与别名过滤；按各来源原生事务、主链或用户区间聚合，证据不足不估 token；有效来源重开回合返回精确撤销 ID。
codex_turns.rs: 校验完成主回合、缓存未变化日志、保存无正文的统计并按日期/模型查询。
config.rs: 保存采集配置。
db.rs: 维护 SQLite schema、记录和备份；迁移/恢复包含独立回合表；一次升级仅备份一次，自动备份保留 3 份，预览保留 24 小时内最近 3 份。
import.rs: 预览、提交和撤销历史导入。
ipc.rs: 向原生应用提供 worker JSON 协议、有效账本的已用模型集合及 codexTurns / turnAnalytics 查询。
lib.rs: 导出账本引擎模块。
main.rs: 提供 CLI 命令和单写者锁；compact 回收空闲页。
remote_pricing.rs: 拉取并校验官方远程费率表，保留最近一次有效修订。
price_coverage.rs: 从缓存扩展模型覆盖，为未计价记录生成首次估算候选。
pricing.rs: 保存官方价格快照，计算估算并重估历史；GPT-6.2 支持长上下文、Fast 和按快照日期确定的 Ultrafast 优惠。
queries.rs: 当日用量支持时间戳半开区间，按设备本地午夜查询； 按来源覆盖和筛选条件查询用量；activity 独立聚合日期/工具/模型及跨日期小时分布，小时仅采用与账本日期相符的时间戳，不受明细分页影响。
usage.rs: 定义用量记录和 token 分类。


price_catalog.rs: 合并全量离线目录、价格缓存和当前规则；只供费率展示。

[PROTOCOL]: Update this header on change, then check AGENTS.md
