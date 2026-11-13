# cli/tokenory/src/
> L2 | Parent: ../../../AGENTS.md

clients.rs: 声明客户端来源和扫描路径。
collector.rs: 只读采集源日志并更新账本。
config.rs: 保存采集配置。
db.rs: 维护 SQLite schema、记录和备份。
import.rs: 预览、提交和撤销历史导入。
ipc.rs: 向原生应用提供 worker JSON 协议和有效账本的已用模型集合。
lib.rs: 导出账本引擎模块。
main.rs: 提供 CLI 命令和单写者锁。
price_coverage.rs: 从缓存扩展模型覆盖，为未计价记录生成首次估算候选。
pricing.rs: 保存官方价格快照，计算估算并重估历史。
queries.rs: 按来源覆盖和筛选条件查询用量；activity 独立聚合日期/工具/模型及跨日期小时分布，小时仅采用与账本日期相符的时间戳，不受明细分页影响。
usage.rs: 定义用量记录和 token 分类。


price_catalog.rs: 合并全量离线目录、价格缓存和当前规则；只供费率展示。

[PROTOCOL]: Update this header on change, then check AGENTS.md
