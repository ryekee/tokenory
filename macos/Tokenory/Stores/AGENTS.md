# macos/Tokenory/Stores/
> L2 | Parent: ../../../AGENTS.md

HUDPreferences.swift: 持久化 HUD 显隐、六种屏幕位置及按屏幕比例计算的四角边距、显示指标、音效开关和音量；首次默认隐藏、静音、35% 音量。

UsageStore.swift: 按北京时间移动统计日期范围且重置分页，空范围不可移动，向后最多到今日，回到匹配范围时恢复滚动预设；今日速度独立于统计页筛选，扫描/弹窗/跨日刷新，失败清空旧速度；按需加载多 agent 回合，代际保护筛选结果，扫描后刷新已访问的回合数据；总览和明细先发布所选报告，日期及分页切换复用全年活动、目录和当日数据；活动筛选或账本更新时刷新全年活动及走势缓存；来源查询独立于价格目录，扫描完成后刷新已加载的来源数据。

Codex todayUsageChanged 事件只刷新当日汇总，实时传给 HUD，完整统计沿用全扫描刷新。

总览及明细统计失败跟随发起请求的筛选条件。重试使用当前筛选，已有报告保留到下一次成功。

保留选中的对话名称供筛选按钮显示。对话筛选以工具和会话 ID 区分，仅应用于明细报表。切换对话重置分页。

速度图按已返回的查询生成同一批回合的时间分组；当日速度仅计算摘要。

UsageStore 的 todayDay / todayTimeZone / todayUsageError 供 HUD 识别跨日与不可用读数，沿用今日独立查询与代际保护。

[PROTOCOL]: Update this header on change, then check AGENTS.md
