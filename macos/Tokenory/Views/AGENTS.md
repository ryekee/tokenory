# macos/Tokenory/Views/
> L2 | Parent: ../../../AGENTS.md

BrandIcon.swift: 统一工具、提供方、模型的品牌映射；保留彩色标志和背景细节。
DashboardView.swift: 组织统计窗口导航；按可见页刷新日期范围，等待期间保留上一份报告，刷新图标原位显示加载状态；详情内容滚动，完成按钮保持可见。
DashboardMotion.swift: 使用共享计数值、进位和借位静音滚动统计数字；大跨度快进后滚完最后一段，单位变化时淡入新读数；记录图表从无数据恢复时的日期切换；遵循减少动态效果设置。
DashboardChartMarks.swift: 由 Core Animation 绘制日期范围的柱形与分段曲线；固定坐标和基线，只动画柱高和折线揭示进度。
ImportView.swift: 展示导入预览、来源冲突和自适应来源卡片；来源页懒加载并仅请求来源数据。
MenuBarView.swift: HUD 显隐使用文案后的勾选菜单项； 展示今日 Tokens、费用、加权速度及来源用量，保留未知/估算标记。
OverviewView.swift: 滚动更新所选范围的摘要、Token 构成与排行读数，排行条随范围生长；共用分段控件切换 Tokens/费用。
PriceCatalogView.swift: 展示默认收起、按供应商独立折叠的完整价格目录；支持全部和账本已用模型切换，搜索展开匹配项，标明 compactor 参考估算，在 DeepSeek 表内展示峰谷价格和时段说明。
RecordsView.swift: 展示筛选后的用量明细和滚动记录数；同页重复日期只格式化一次。
SettingsView.swift: 配置通用、HUD、采集、价格和数据维护。
MechanicalHUDView.swift: 原生橙色机械计数器按原型 50% 显示（220×92 pt 窗口）；文本片段/费用图标、渐停数字轮；复用当日汇总，跨日与唤醒刷新；每帧捕获数字位置快照，避免延迟绘制访问已清空或缩短的数组。
HUDSettingsView.swift: 六种位置的 2 × 3 选择器； HUD 显隐、指标和独立音效开关、音量；音量仅在设置页调整，HUD 喇叭按钮直接切换音效。
UsageDatePicker.swift: 选择统计日期范围；弹出时初始化草稿和两个月的日历展示，选中日期时复用日历标签。
UsageFiltersView.swift: 选择工具、提供方和模型。
UsageTrendChart.swift: 绘制双轴日/小时趋势；日期切换时插值 Tokens 柱高，沿时间轴描出费用。
UsageActivityView.swift: 固定 YlGnBu 活动日历，隔离悬停状态，只更新提示卡片，点击直达当日。
UsageHabitsView.swift: 独立编码习惯面板，展示最高产星期及占比、单日最高、星期和 24 小时分布；宽窗口并排，窄窗口堆叠。
UsageHistoryChart.swift: 按工具分组的模型堆叠走势、30 天平均和原始总量。
UsageViews.swift: 提供用量展示名称、格式及菜单栏三项摘要。
WorkspaceControls.swift: 提供前缘对齐、展开间距统一的原生窗口控件。
WorkspaceStyle.swift: 定义统计窗口颜色、共享输出/推理色和独立工具等待/其余耗时色及布局样式。

TurnsView.swift: 原生多 agent 回合摘要、agent/模型筛选、按支持状态分组的图标弹窗及避让图标的跟随光标名称提示、估算标记、分页排序和详情；切换范围时保留上一份报告；窄窗口上下排列。
TurnSpeedChart.swift: 真实时间轴上的单调平滑速度曲线，切换日期时描出新曲线，隔离悬停状态并支持键盘选择。

[PROTOCOL]: Update this header on change, then check AGENTS.md
