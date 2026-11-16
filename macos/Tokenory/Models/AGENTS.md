# macos/Tokenory/Models/
> L2 | Parent: ../../../AGENTS.md

PriceCatalog.swift: 解码完整目录和已用模型身份并按费率分组，读取供应商品牌。
EngineMessages.swift: 定义 IPC 数据值、报告与采集配置；增量分行只扫描新字节。
HUDReading.swift: 将当日汇总映射为精确整数/美分，Token 恢复带分组符的整数显示，保持未知与部分计价语义，定义滚轮进位、长渐停曲线及连续位置/速度的目标追加。
UsageTrend.swift: 构造时间趋势展示数据。
UsageActivity.swift: 补齐日历日期、使用规律和保持未知费用的模型移动平均。

TurnAnalytics.swift: 解码完整能力目录及缺失原因/补采方案，校验回合协议，计算全范围平均速度、首 token 等待和思考量，提供时间排序与最近点查询。

[PROTOCOL]: Update this header on change, then check AGENTS.md
