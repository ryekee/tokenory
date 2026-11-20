# macos/TokenoryTests/
> L2 | Parent: ../../AGENTS.md

BrandPresentationTests.swift: 验证品牌映射、模板资源及金额格式。
EngineClientTests.swift: 验证引擎协议客户端和分块大目录解析。
HUDTests.swift: 验证跨时区与 23/25 小时夏令日；验证整数与金额读数、未知/部分价格、进位和渐停、跨日/切换/减少动态效果、滚动中连续追加与密集更新、设置持久化、字体/双语资源及浮动面板的全屏空间配置。
LocalizationTests.swift: 验证本地化资源。
UsageActivityTests.swift: 验证日历、按工具区分模型、移动平均及未知费用。
PresentationDataTests.swift: 验证统计展示数据、日期图表入场、统计数字进借位与单位变化。
UpdateCheckerTests.swift: 验证更新检查状态及应用语言对应的清单。
UsageStoreTests.swift: 真实 Codex 文件追加经 worker 更新当日用量并连续追加当前滚动；验证今日速度独立筛选、跨日旧响应不覆盖、完整来源能力目录；验证日期切换保留上一份报告且复用全年活动、按天数移动日期范围、今日上限及恢复滚动预设。

UsageStore 的统计回归覆盖首次请求失败、筛选失败保留旧报告和重试。

TurnAnalyticsTests.swift: 验证速度加权、估算标记、协议校验、小时／日／周分组、北京时区周边界、四分位、离群点和稀疏点。

[PROTOCOL]: Update this header on change, then check AGENTS.md
