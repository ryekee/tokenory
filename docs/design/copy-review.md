# Bilingual copy review

Applied humanizer to English and humanizer-zh to Simplified Chinese. The final copy is in `Localizable.xcstrings`.

| Original / initial draft | Issue | Final English | Final Chinese |
| --- | --- | --- | --- |
| API 估算 | Metric did not say whether it was usage or cost. | Estimated cost | 估算费用 |
| 已更新 · 0.3 秒 | Scan duration looked like freshness. | Up to date | 已更新 |
| 指定模型费率 / 保存费率 | Asked users to maintain vendor prices. | Official rates, applied automatically | 自动使用官方费率 |
| No data found for the selected range | Stiff, generic empty-state copy. | No usage in this period | 此范围暂无记录 |
| 此文件已导入，总数未增加。 | Preserve the no-duplication fact without extra reassurance. | This file was already imported. Totals are unchanged. | 此文件已导入，总数未增加。 |

Self-audit: removed promotional language, vague reassurance and technical implementation labels from primary flows. Kept the distinction between a cost estimate and a bill. Replaced sentence fragments assembled in Swift with complete localized messages. English count strings use singular/plural forms. Technical diagnostics and immutable pricing snapshots remain original evidence inside disclosure controls.

Adding a language: add its localization to every catalog key and plural variant, register its identifier in AppLanguage/project.yml, and run catalog tests plus native layout review. Do not localize model IDs, IPC operations, stored dates, source IDs or currency codes.
