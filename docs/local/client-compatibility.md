# 多客户端接入验证

2026-11-06。接入截图中的 42 个工具，对应 40 个解析器和 Paseo / Orca 两个启动器入口。所有本次验证使用临时或项目忽略的独立数据库，没有改写正式 Tokenory 账本。

## 实现

- helper 显式启用 40 个上游扫描器，包含默认解析集合未开启的 Cursor 缓存。
- 诊断覆盖 JSON、JSONL、NDJSON 和 SQLite，数据库文件计入来源统计。
- 补齐 Roo Code / Kilo 在 macOS 原生 VS Code 中的默认目录。
- 原生来源页可展开 42 项支持列表，采集设置可为支持额外目录的工具分别保存路径。
- Claude / Codex 沿用稳定事件身份。新增适配器按会话保存最新可读快照，避免累计值更新和不稳定 ID 造成重复。
- 汇总来源不套用单请求长上下文门槛，不用缓存同步时刻推断小时用量或峰谷价格。

## 自动化结果

| 检查 | 结果 |
| --- | --- |
| Rust workspace | 2,515 passed，0 failed，4 ignored |
| Clippy | 全 workspace / all-targets，`-D warnings` 通过 |
| macOS XCTest | 13 项通过；新增的真实 helper 客户端目录断言单独复跑通过 |
| 原生构建 | Debug / Release 构建和签名检查通过 |
| 原生界面 | Release 实际显示 42 个客户端，工具选择器可切换至 Gemini CLI，额外目录编辑区域正常 |
| 文本检查 | `git diff --check` 通过 |

`cli/tokenory/tests/clients.rs` 验证：

- 42 个产品入口和启动器归属，未知客户端及不受支持的额外目录被拒绝。
- Amp / Gemini 无事件 ID 的两条等量记录各自保留，重扫不累加。
- Cline / Roo / Kilo 原生编辑器目录、Cursor JSON 缓存、Command Code 发布格式的发现与入库。
- Mux 累计值、时间和模型集合变更更新当前会话，损坏文件及完整文件删除保留已存数据。
- Orca SQLite WAL 更新能够重新采集；Paseo 自定义 Claude 目录与额外扫描目录重叠时只计一次。
- Trae / Warp 缓存更新不会增加第二份累计快照，来源 USD 成本仍保留。
- 源累计记录不伪造成小时事件。定价测试另行验证累计值不触发请求门槛。

上游解析器本身的各格式测试包含在 workspace 结果中。所有测试使用固定示例，没有为验证产生付费 API 调用。

## 本机只读采集

对本机真实日志进行一次独立账本采集，实际读取到了 Claude Code、Codex、Cline、Copilot 和 MiMo Code 记录。Kimi / WorkBuddy 有文件，但本次没有解析出有效用量。采集成功不证明所有历史都完整，也不证明所有客户端版本兼容。

Release 常驻 worker 的一次温缓存扫描为 558 ms；这是本机单次观察，不是性能上限保证。

诊断、构建和测试日志保存在忽略的 `.build/verification/client-support/`。个人日志与数据库不纳入 Git 提交。

## 边界

- Cursor、Trae、Warp、Antigravity IDE 读取已有上游缓存，App 不实现其登录或自动同步。
- 新接入的源记录暂不参与小时分配。源文件可能只提供会话总量、请求数或费用。
- 来源缺失时保留历史。仍可读取的会话采用最新快照，因此源记录修正或删除会替换该会话旧版本。
- 语法和读取错误有保护。上游解析器跳过未知结构的行为仍存在，不能把“未发现用量”当作完整性证明。
- 未逐一安装并运行全部 42 个客户端，未验证各客户端未来版本、系统登录、睡眠唤醒或跨机器安装。
