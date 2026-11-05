# 估算口径

费用统一使用各家的官方美元费率，不通过汇率换算，也不要求用户填写价格。Tokenory 保存源成本和独立的 API 估算；缺少计价证据时估算为 null，不显示为免费。

## 官方费率

2026-11-05 核实并内置 DeepSeek、当前使用的 OpenAI 和 Anthropic 官方费率。新安装和版本升级离线也可使用。首次扫描后及每 24 小时刷新现有上游参考数据，补充内置表未覆盖的旧模型；内置官方表优先。刷新操作不代表重新核实了内置表的发布日期，内置表随应用维护更新。每条估算保留不可变价格快照 ID、来源和计价假设。

- [DeepSeek 官方美元价格](https://api-docs.deepseek.com/quick_start/pricing/)
- [OpenAI 官方价格](https://developers.openai.com/api/docs/pricing)；其 Markdown 版本含标准、长上下文和速度档位完整表。
- [Anthropic 官方价格](https://platform.claude.com/docs/en/about-claude/pricing)
- [GPT-5.2-Codex](https://developers.openai.com/api/docs/models/gpt-5.2-codex) 和 [GPT-5.1-Codex Mini](https://developers.openai.com/api/docs/models/gpt-5.1-codex-mini) 的旧模型价格来自各自官方页面。

## DeepSeek 时段

每百万 tokens 的官方美元费率：

| 模型 | 缓存未命中：高峰 / 低峰 | 缓存命中：高峰 / 低峰 | 输出：高峰 / 低峰 |
| --- | --- | --- | --- |
| deepseek-flash | 0.30 / 0.15 | 0.006 / 0.003 | 1.20 / 0.60 |
| deepseek-v4-pro | 1.32 / 0.66 | 0.044 / 0.022 | 3.96 / 1.98 |

高峰为北京时间周一至周五 09:00 至 12:00、14:00 至 18:00，结束时刻不含在高峰内。周末、中国法定节假日和其他时段全部按低峰价。调休上班的周末仍按周末处理，遵循 DeepSeek 对周末的明文规则。

2026 年节假日依据[国务院办公厅通知的政府网站转载](https://www.wuhan.gov.cn/zwgk/tzgg/202511/t20251105_2672471.shtml)。节假日日历版本保存在价格快照的 schedule 中。其他年份的潜在高峰时段在日历未核实前保留待计价。

deepseek-v4-flash 和 deepseek-v4-flash-vision-exp 按官方当前别名关系使用 Flash 费率。此规则仅应用于确认的 deepseek 提供方，不套用到转售渠道。

有请求时间的事件按实际时段计算。仅有日期的汇总，只有确认是北京时间且全天低峰时才计价；工作日缺少峰谷拆分时保留待计价。此前保存的固定价快照仍按原记录读取，不被新规则暗中改写。

## 其他规则

- 官方 OpenAI 长上下文模型以整条请求的输入（含缓存读取）判断 272,000 tokens 门槛，超过时整条请求使用长上下文费率。
- Anthropic 按缓存读取、5 分钟写入、已观察到的 1 小时写入分别计算。
- 已核实的 OpenAI Fast/Ultrafast 与 Anthropic Opus Fast 档位自动计算；未核实的速度档位保持待计价。
- 日汇总和新增客户端的 `sourceRecord` 不作为一条长请求，也不以缓存同步时刻推断峰谷折扣。来源原成本、订阅支出和 API 费率估算互相独立。
- 当前官方价格不能证明历史账单当时的费率。界面始终称为估算；没有发起付费 API 请求。

刷新只改变后续记录使用的快照。重估已有记录须预览，提交前自动备份；源成本和旧价格快照保留。重估不改变 token 数量、日期或来源覆盖选择。
