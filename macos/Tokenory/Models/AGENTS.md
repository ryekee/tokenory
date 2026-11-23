# macos/Tokenory/Models/
> L2 | Parent: ../../../AGENTS.md

PriceCatalog.swift: 解码完整目录和已用模型身份并按费率分组，读取供应商品牌。
DeviceUsageSnapshot.swift: 版本化的设备汇总交换格式；按设备替换快照，生成指定设备集合的日期、维度及全年活动报告。费用未知、小时缺失和 Fast/子代理用量遵循原生账本口径。
EngineMessages.swift: 定义 IPC 数据值、对话身份与标题、Codex 子代理用量及估算费用、报告及 Fast 用量和费用、用量模式证据与采集配置。增量分行只扫描新字节。
HUDReading.swift: LocalUsageDay 按设备当前时区计算本地日与夏令时午夜边界；将当日汇总映射为精确整数和美分；定义小步进的进位缓动、大跨度限转、长渐停曲线及连续位置和速度的目标追加。
UsageTrend.swift: 构造时间趋势展示数据。
UsageActivity.swift: 补齐日历日期、使用规律和保持未知费用的模型移动平均。

TurnAnalytics.swift: 解码回合和能力目录，计算全范围指标及小时、日或周速度分布，提供四分位、离群点、代表回合和最近点查询。

[PROTOCOL]: Update this header on change, then check AGENTS.md
