# macos/Tokenory/Views/
> L2 | Parent: ../../../AGENTS.md

BrandIcon.swift: 统一工具、提供方、模型的品牌映射；保留彩色标志和背景细节。
DashboardView.swift: 组织统计窗口导航；保留总览以及首次访问后的明细、来源视图和滚动位置；详情内容滚动，完成按钮保持可见。
ImportView.swift: 展示导入预览、来源冲突和自适应来源卡片；来源页懒加载并仅请求来源数据。
MenuBarView.swift: 展示菜单栏用量面板。
OverviewView.swift: 展示紧凑摘要、Token 构成和由组顶部共用分段控件切换 Tokens/费用的工具与模型排行。
PriceCatalogView.swift: 展示默认收起、按供应商独立折叠的完整价格目录；支持全部和账本已用模型切换，搜索展开匹配项，标明 compactor 参考估算，在 DeepSeek 表内展示峰谷价格和时段说明。
RecordsView.swift: 展示筛选后的用量明细；同页重复日期只格式化一次。
SettingsView.swift: 配置采集、价格和数据维护。
UsageDatePicker.swift: 选择统计日期范围。
UsageFiltersView.swift: 选择工具、提供方和模型。
UsageTrendChart.swift: 绘制 Tokens 柱状与费用折线的双轴日/小时趋势。
UsageActivityView.swift: 固定 YlGnBu 活动日历，隔离悬停状态，只更新提示卡片，点击直达当日。
UsageHabitsView.swift: 独立编码习惯面板，展示最高产星期及占比、单日最高、星期和 24 小时分布；宽窗口并排，窄窗口堆叠。
UsageHistoryChart.swift: 按工具分组的模型堆叠走势、30 天平均和原始总量。
UsageViews.swift: 提供用量展示名称和格式。
WorkspaceControls.swift: 提供前缘对齐、展开间距统一的原生窗口控件。
WorkspaceStyle.swift: 定义统计窗口颜色和布局样式。

[PROTOCOL]: Update this header on change, then check AGENTS.md
