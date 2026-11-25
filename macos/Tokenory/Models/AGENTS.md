# macos/Tokenory/Models/
> L2 | Parent: ../../../AGENTS.md

PriceCatalog.swift: 解码完整目录和已用模型身份并按费率分组，读取供应商品牌。
DeviceUsageSnapshot.swift: 版本化的设备汇总交换格式。兼容汇总使用北京时间，按设备替换，生成日期、维度、工具下的模型及全年活动报告。费用未知、小时缺失和 Fast/子代理用量保留来源口径。
EngineMessages.swift: 定义 IPC 数据值、请求错误、对话身份与标题、Codex 子代理用量及估算费用、报告、按工具归组的模型及 Fast 用量和费用、用量模式证据与采集配置。增量分行只扫描新字节。 设备快照按请求 ID 分块及结束。
HUDReading.swift: LocalUsageDay 按设备当前时区计算本地日与夏令时午夜边界；将当日汇总映射为精确整数和美分；定义小步进的进位缓动、大跨度限转、长渐停曲线及连续位置和速度的目标追加。
UsageTrend.swift: 按本机或设备汇总时区构造趋势，按实际日长展示小时和夏令时重复小时。
UsageActivity.swift: 补齐日历日期，计算连续活跃、洞察和使用规律，保持未知费用的模型移动平均。提供带顶部留白的堆叠峰值供走势右轴选档。

TurnAnalytics.swift: 解码回合、按工具分组的本地会话标题和能力目录。计算全范围指标及小时、日或周速度分布，提供四分位、离群点的绘图位置、代表回合、最近点及回合搜索。

[PROTOCOL]: Update this header on change, then check AGENTS.md
