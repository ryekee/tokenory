# Tokenory 界面第二轮改造

日期：2026-11-06。范围：总览图表、日期范围、导航、明细与分页、设置与费率表。菜单栏 Liquid Glass 面板保持原实现。

## 设计决策与参考

| 组件 | 参考 | 实现 |
| --- | --- | --- |
| 日期范围 | [Watermelon Date Picker](https://ui.watermelon.sh/components/date-picker)，实际查看 DatePicker2 | 双月日历、连续范围高亮、快捷范围、自定义范围 Apply/Cancel |
| 明细表 | [Data Table](https://ui.watermelon.sh/components/data-table)，实际查看 DataTable10 并翻页；[Table](https://ui.watermelon.sh/components/table) | 对齐列、轻表头与分隔线、整行打开详情、数值右对齐 |
| 导航 | [Tabs](https://ui.watermelon.sh/components/tabs)、[Continuous Tabs](https://ui.watermelon.sh/animated-components/continuous-tabs)，实际切换预览选项 | SwiftUI 原生按钮、选中底色滑动、上下方向键 |
| 分页 | [Pagination](https://ui.watermelon.sh/components/pagination) | 编号、首末页编号、前后页、范围、每页 50/100/200 条 |
| 动效 | Continuous Tabs 的连续选中指示；原生 DisclosureGroup | 200 ms 导航和展开反馈、180 ms 分页反馈；遵循 Reduce Motion |

借鉴布局、层次和交互，不引入 React 组件或 WebView。

### Tokens 与费用合并

合并合理：两者共用时间维度，联合提示可以直接比较同一时段的用量与费用。采用蓝色 Tokens 柱形、橙色费用折线；左右轴分别标注 Tokens 和 USD，均从零开始。两个轴独立缩放，柱线相交不表示数值相等。费用在后续细节调整中改为 monotone 平滑曲线，经过原始数据点，并保持区间单调性。

- Today 及任意单日范围使用北京时间 24 小时分桶。
- 后端从全部有效记录聚合，遵守来源覆盖及筛选，不受明细分页影响。
- 只有真实时间戳能进入小时桶；日汇总及日期不匹配记录计入未分配量，页面明确显示。
- 已过去且没有记录的小时显示零；未来小时留空。
- 未计价费用保持未知并断线；全部未知时不画费用线。部分已知费用仍标注为已知估算。
- 悬停、点击和左右方向键读取同一时段的两项实际数值。辅助功能内容同样使用实际值。

### 设置和费率

- 取消重复的窗口内标题，只保留内容区标题，消除跨栏文字。
- 语言、货币和开关按右边缘对齐。
- DisclosureGroup 标题整行可点击，包含文字及空白区。
- 费率按 provider 分组，再按完整 rates、schedule、allowFast、explicitFree 分组，避免把长上下文或其他规则不同的模型误合并。
- 同组模型逐行排列，价格只显示一次；支持模型和提供方搜索。
- 内部的 unknown、_session 提供方在界面中分别显示为「未知提供方」「未标注提供方」，保留原分组和估算规则。

## impeccable 原生界面复查

依据 `impeccable` 的 craft-floor、polish、animate 和原生检查流程进行源码与运行界面复查。目标是 SwiftUI macOS，因此不运行只识别 Web 标记的 detector。未把构建成功当成视觉验收。

| 检查项 | 观察及处理 |
| --- | --- |
| 标题与对齐 | 中文深色、英文浅色的通用设置均检查；没有跨栏标题，右侧控件边缘一致 |
| 点击区域 | 实际点击折叠标题中部空白区，能展开/收起；实际点击明细行中部，能打开详情 |
| 日期 | 实际选择 10 月 30 日至 11 月 2 日并应用；单日 11 月 5 日显示 24 小时分布；Today 显示小时粒度 |
| 图表 | 首轮运行发现柱形变为短横条，已改为明确从零绘制的矩形柱；折线绘于柱形上方；检查深浅两种外观 |
| 费用状态 | 实际筛选 codex-auto-review，显示待计价且没有虚假的零费用折线 |
| 联合提示 | 实际点击图表并按右方向键，提示从 10 月 27 日切到 10 月 28 日，展示两项真实值 |
| 辅助功能 | 运行时 AX 检查发现归一化比例被读出，已用真实时间、Tokens、费用和未计价量替代；费率按组提供带列名的内容 |
| 分页 | 实际从第 1–50 条切换至第 51–66 条；末页禁用下一页；每页改为 100 条后回到第一页 |
| 费率可读性 | 中英文运行检查；DeepSeek 搜索结果将三个 Flash 型号合为一组，价格只出现一次 |
| 设置其他页面 | 中文采集、数据页面运行检查，字段与按钮未遮挡 |
| 动效 | 导航、展开和分页只反馈操作，不动画后台采集数值；Reduce Motion 分支完成源码检查 |

边界：未完成全程 VoiceOver 朗读验收；未通过工具成功调整到精确 800 pt 窗宽，因此不把最小窗口尺寸算作运行验收。源码保留 800×560 最小约束、表格横向滚动和窄布局分页换行。未操作真实导入、恢复或重新计价。

## 验证

- `cargo test --manifest-path cli/Cargo.toml -p tokenory`：33 项通过。
- `cargo clippy --manifest-path cli/Cargo.toml -p tokenory --all-targets -- -D warnings`：通过。
- Xcode Debug 测试：9 项通过，含小时空桶、未来时段、未知费用断线、完整费率分组验证。
- `TOKENORY_CONFIGURATION=Release ./script/build.sh`：构建通过；应用通过 `codesign --verify --deep --strict`。
- 临时浅色检查覆盖已移除；安装版跟随系统外观，语言偏好未被测试改写。
- 日志保留在 `.build/ui-validation/2026-11-06/`，不纳入源代码。
