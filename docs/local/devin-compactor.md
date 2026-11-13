# Devin CLI compactor 调查

2026-11-13，Devin CLI 3000.12.43。仅查询本地元数据与账户模型目录，没有发起模型推理请求。

## 已确认的字段

本地 `sessions.db` 中该压缩记录的 `chat_message.metadata` 包含：

```json
{
  "generation_model": "compactor",
  "metrics": {"input_tokens": 71232, "output_tokens": 5038},
  "response_dimensions": [
    {"uid": "model", "kind": {"Metric": {"label": "Model", "value": "Compactor (Luna)"}}}
  ]
}
```

这比账本的 `compactor` 标识更具体：Devin 报告它属于 Luna 系列。该字段没有精确模型 ID 或代际。外层节点的 `summarized_from` 字段指向被摘要的上下文，确认这是压缩记录。会话选中模型为 `swe-2-flash-medium`，不能用它替换这条辅助调用的模型身份。

## 模型目录

通过官方 CLI 的只读命令查询：

```sh
devin models list --format json
```

目录同时提供以下标准档位，单位为美元 / 百万 tokens：

| 系列 | 输入 | 缓存读取 | 输出 |
| --- | ---: | ---: | ---: |
| GPT-6 Luna | 0.10 | 0.01 | 0.50 |
| GPT-5.6 Luna | 0.20 | 0.02 | 1.20 |

目录没有 `compactor` 条目。原记录没有费用字段；会话累计额度不能分摊成这条调用的美元费用。已查阅 [Devin CLI 模型文档](https://docs.devin.ai/cli/models) 和 [官方模型价格页](https://docs.devin.ai/desktop/models)，未找到 compactor 到精确模型的公开映射。

## 决策

2026-11-13 用户明确选择 GPT-6 Luna 标准价作为参考。仅对 `devin-cli / devin / compactor` 使用每百万输入 $0.10、缓存读取 $0.01、输出 $0.50。费用依据和价格页注明参考估算，实际底层模型代际仍未确认。

保留原模型标识 `compactor`。本次 71,232 输入和 5,038 输出合计参考估算 $0.0096422；界面按两位小数显示 $0.01。首次回填前自动备份，不改动已有金额或 token 数量。
