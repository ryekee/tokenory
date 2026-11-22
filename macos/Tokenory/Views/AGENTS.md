# macos/Tokenory/Views/
> L2 | Parent: ../../../AGENTS.md

BrandIcon.swift: 统一工具、提供方、模型的品牌映射；保留彩色标志和背景细节。
DashboardView.swift: 组织统计窗口导航与重试；等待期间保留上一份报告；宽窗口同时显示记录列表与所选详情，窄窗口保留原生面板。
DashboardMotion.swift: 使用共享计数值、进位和借位静音滚动统计数字；大跨度快进后滚完最后一段，单位变化时淡入新读数；记录图表从无数据恢复时的日期切换；遵循减少动态效果设置。
DashboardChartMarks.swift: 由 Core Animation 绘制日期范围的柱形与分段曲线；固定坐标和基线，只动画柱高和折线揭示进度。
ImportView.swift: 单击选择导入格式，展示导入预览、来源冲突和自适应来源卡片。导入记录与来源覆盖在加载后显示各自的空态文案。
MenuBarView.swift: HUD 显隐使用文案后的勾选菜单项； 展示今日 Tokens、费用、加权速度及来源用量，保留未知/估算标记。
OverviewView.swift: 滚动更新所选范围的摘要、Token 构成与排行读数；有子代理活动时在工具与模型排行之后显示独立卡，指标沿用编码习惯卡的字号，并列展示启动数、Tokens、估算费用及占比，展开后按对话显示用量和费用。日期范围为空时只展示一处空态，全年有记录时继续展示活动数据。工具与模型排行共用 Tokens/费用切换和 Fast 图例，横条按所选指标区分 Fast 占比。
PriceCatalogView.swift: 展示默认收起、按供应商独立折叠的完整价格目录；支持全部和账本已用模型切换，搜索展开匹配项，标明 compactor 参考估算，在 DeepSeek 表内展示峰谷价格和时段说明。
RecordsView.swift: 展示用量明细及当前筛选下的 Tokens 和估算费用合计。窄布局显示简体中文短日期，同页重复日期只格式化一次。无记录时提供清除筛选或更改日期。
SettingsView.swift: 配置通用、HUD、价格、采集和数据维护。语言和检查频率选择器以本地化文案计算共享宽度。恢复前确认文件与影响，操作旁显示进度、结果和重试。
MechanicalHUDView.swift: 原生橙色机械计数器按原型 50% 显示（220×92 pt 窗口）；双击读数或外壳打开统计窗口；文本片段/费用图标、渐停数字轮，音效仅在面板所在空间可见时播放；复用当日汇总，跨日与唤醒刷新；每帧捕获数字位置快照，避免延迟绘制访问已清空或缩短的数组。
HUDSettingsView.swift: 六种位置的 2 × 3 选择器； HUD 显隐、指标和独立音效开关、音量；音量仅在设置页调整，HUD 喇叭按钮直接切换音效。
UsageDatePicker.swift: 通过工具栏和明细空状态打开共用日期浮层；弹出时初始化草稿和两个月的日历，选中日期时复用标签。
UsageFiltersView.swift: 单行选择工具、提供方和模型。工具和提供方按全账本 Tokens 排序，模型按名称排序。明细额外按来源及最近活动优先的对话筛选。
UsageTrendChart.swift: 绘制双轴日/小时趋势；日期切换时插值 Tokens 柱高，沿时间轴描出费用。
UsageActivityView.swift: 固定 YlGnBu 活动日历，隔离悬停状态，只更新提示卡片，点击直达当日。
UsageHabitsView.swift: 独立编码习惯面板，展示最高产星期及占比、单日最高、星期和 24 小时分布；宽窗口并排，窄窗口堆叠。
UsageHistoryChart.swift: 按工具分组的模型堆叠走势和原始总量；单击切换 30 天平均和每日数据。
UsageViews.swift: 提供用量格式、跨页 Fast 闪电标记和菜单栏三项摘要。
WorkspaceControls.swift: 提供前缘对齐、展开间距统一的工作区控件。下拉共用触发按钮、搜索框、选项行和带勾选的弹窗。说明按钮点击展开原生浮层。
WorkspaceStyle.swift: 定义统计窗口颜色、共享输出/推理色、Fast 用量色和独立工具等待/其余耗时色及布局样式。

TurnsView.swift: 多 agent 回合摘要、工具与模型筛选、能力弹窗、时间分组筛选、分页排序和详情。详情显示选中回合的本地会话名称。无回合时显示一处页级空态，请求失败提供重试。窄窗口上下排列。
TurnSpeedChart.swift: 按北京时间绘制小时、日或周速度箱体及稀疏与离群回合；悬停或用键盘查看区间和典型速度。

[PROTOCOL]: Update this header on change, then check AGENTS.md
