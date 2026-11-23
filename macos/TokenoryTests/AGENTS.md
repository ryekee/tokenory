# macos/TokenoryTests/
> L2 | Parent: ../../AGENTS.md

BrandPresentationTests.swift: 验证品牌映射、模板资源、Gemini 图标的原生绘制面积及金额格式。
DeviceUsageSnapshotTests.swift: 验证整台设备替换、跨设备数值累加、按日期/模型去重计数、子代理筛选、小时与日粒度及协议版本。
EngineClientTests.swift: 验证引擎协议客户端和分块大目录解析。 覆盖实际进程的快照分块和错误后的请求。
DeviceCloudSyncTests.swift: 验证独立设备授权、暂停与撤回、请求乱序、账本恢复、增量缓存、离线与账号切换，以及断网时本机合计更新、联网补传和删除错误保留。日期切换保留完整的前一份双机汇总，过期计算无效，纯日期改动复用全年活动。
HUDTests.swift: 验证跨时区与 23/25 小时夏令日；验证整数与金额读数、未知/部分价格、进位和渐停、跨日/切换/减少动态效果、滚动中连续追加与密集更新、设置持久化、字体/双语资源及浮动面板的全屏空间配置。
LocalizationTests.swift: 验证本地化资源。
UsageActivityTests.swift: 验证日历、按工具区分模型、移动平均及未知费用。
PresentationDataTests.swift: 验证深浅主题的 sRGB 色值、卡片内下拉与原生控件在失焦时的底色、统计展示数据、跨设备排行四段的占比、顺序和全高 Fast 像素、唯一模型数、缺失费用、日期图表入场、统计数字进借位与单位变化。
UpdateCheckerTests.swift: 验证更新检查状态及应用语言对应的清单。
UsageStoreTests.swift: 真实 Codex 文件追加经 worker 更新当日用量并连续追加当前滚动；验证今日速度独立筛选、跨日旧响应不覆盖、完整来源能力目录；验证日期切换保留上一份报告且复用全年活动、按天数移动日期范围、今日上限及恢复滚动预设。

UsageStore 的统计回归覆盖首次请求失败、筛选失败保留旧报告和重试。来源刷新失败时保留缓存，错误在来源页展示；worker 重启后重试会清除该错误。
对话筛选回归覆盖明细隔离、分页重置和清除筛选时保留日期。

TurnAnalyticsTests.swift: 验证速度加权、估算标记、可选 Fast 证据、协议校验、小时／日／周分组、周边界、四分位、离群点和稀疏点。

CursorTooltipTests.swift: 校验读数位置、翻侧避让和固定尺寸。在带工具栏的原生分栏窗口采样浮层实际像素，核验可见性与鼠标穿透。

SourcesPresentationTests.swift: 检查本机按工具归组后能保留多来源覆盖、空采集和部分错误。

[PROTOCOL]: Update this header on change, then check AGENTS.md
