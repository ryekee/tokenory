# macos/Tokenory/Stores/
> L2 | Parent: ../../../AGENTS.md

HUDPreferences.swift: 持久化 HUD 显隐、六种屏幕位置、显示指标、音效开关和音量；首次默认隐藏、静音、35% 音量。

UsageStore.swift: 今日速度独立于统计页筛选，扫描/弹窗/跨日刷新，失败清空旧速度； 按需加载 多 agent 回合，代际保护筛选结果，扫描后刷新已访问的回合数据；发布引擎报告、最近12个月活动、目录、已用模型和配置状态；默认近 7 天，一次刷新按代际整体发布，并缓存日历和按指标/工具区分的走势展示数据；来源查询独立于价格目录，扫描完成后刷新已加载的来源数据。

UsageStore 的 todayDay / todayUsageError 供 HUD 识别跨日与不可用读数，沿用今日独立查询与代际保护。

[PROTOCOL]: Update this header on change, then check AGENTS.md
