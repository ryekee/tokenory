# Tokenory 迁移输入清单

核对日期：2026-11-05。此清单只引用现有文件；没有复制个人用量数据或运行迁移。

原始目录：

```text
/Users/ryekee/workshop/P.A.R.A/1. Area/Codex/2026-11-02/tokens-https-tokens-ci-https-tokens/outputs/
```

| 文件 | 用途 | 本轮 SHA-256 |
| --- | --- | --- |
| `cc-switch-claude-rollups-original.json` | 165 行、96 天的首次导入输入 | `326be3b2a94d1e4668e34b56e2d8981ecc7e4a96059d326b94176c79eb07820b` |
| `tokens-ci-profile-2026-11-02.json` | 211 日的旧网站快照，仅用于迁移 | `7d839834d4d4a3adc879afc501b39990bcbfa23e43dc67a1383a797765bd6646` |
| `Tokens-Local-研究方案.md` | 前序方案，已原样归档为本目录 `2026-11-02-tokens-local.md` | `31fc071e4095425e5afe8188baf4f61fe69c3cdfa14fddb30caf78287abaebc8` |

同目录保留 `recovery-summary.json`、`claude-code-daily-usage.csv`、`Claude-Code-token恢复报告.md` 及原始核查证据。`claude-stats-cache-original.json` 因统计口径冲突，仅作核查。

实施时直接从上述文件复制到 Tokenory 的独立数据目录，先核对 hash，再进入预览。若需要调整 fixture，仅制作不含个人内容的最小样本，真实数据不进入 Git。

本轮重新计算：

- CC Switch：8,694,071,481 tokens。分类分别为 10,003,733 input、44,047,254 output、8,434,857,502 cache read、205,162,992 cache write。
- CC Switch：有用量但来源 cost 为 0 的 8 行，合计 772,725,441 tokens。
- CC Switch：以 date / app_type / provider_id / model / request_model / pricing_model 组成的来源键共有 165 个，与行数一致。
- 网站快照：顶部总数、每日总数之和、模型总数之和、日/工具/模型单元之和均为 9,249,414,032。
- 网站快照客户端为 codex、micode、claude、cline、copilot；没有把名称出现等同于当前仍在使用。
- 两份固定快照的算术参考值为 17,943,485,513。能否作为当前有效统计，要先完成来源覆盖和时区核对，不能与本地全量扫描直接再相加。

来源时区、跨来源覆盖、实际计价完整性与新程序行为尚未验证；具体处理见[实施计划](../superpowers/plans/2026-11-05-tokenory-implementation.md)。
