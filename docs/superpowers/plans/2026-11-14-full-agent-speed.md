# 全 Agent 速度覆盖与菜单栏速度

## Global Constraints
- 按 clients::catalog 的全部42入口/40解析器逐一检查，而非本机日志可用性。
- 有可信用户回合边界、结束/耗时及输出计数时接入；估算明确标记；未知不可编造；不将请求或session总长冒充回合。
- 所有已有用户修改保留；不提交/发布；不安装hooks；新增解析错误不得阻断费用采集。
- 菜单栏顺序 Tokens、费用、速度，今日平均速度与速度页同口径（生成总量/耗时总量），独立于统计页筛选。
- DESIGN.md 适用，中文/英文与实际构建验证，最终运行日常账本。

### Task 1: 全目录审计与后端接入
逐一阅读40个现有tokens-core解析器及需要的schema/fixture，记录真实字段证据，接入全部有充分证据的来源。维护精确能力目录和简短缺失原因/补采方案；包括Paseo/Orca委托入口。对仍无法接入者清楚区分未记录字段和证据不足，不虚称不可能。不得用本机没有数据当作不支持理由。新增测试覆盖支持的每个格式、去重、完成边界、未知值、collector路径和能力目录完整性。
Owner: cli/tokenory/src/turn*、collector.rs及相关Rust/tests、docs/local/agent-speed-coverage.md。可必要修改tokens-core，避免无关改动。不要修改Swift。最终文档按42入口逐行列出状态、字段证据(文件)、原因和补采方案。完整Rust测试，报告到 .build/full-agent-backend-report.md。

### Task 2: 菜单栏与能力展示
Owner: root, Swift/String Catalog/设计说明。今日速度独立状态，随启动/扫描/弹窗/跨日更新，空数据—，估算≈。三项使用Tokens、费用、速度。支持信息按后端能力展示全部入口和缺失原因。

### Task 3: 审阅验收
独立代码与覆盖审阅，修复确认缺陷；Rust/原生测试构建；最新App接回日常账本，记录实际UI验收范围。

## 完成记录

三项任务均完成。最终审阅问题已修复；Rust84项、原生29项及最后helper集成测试通过。最新App运行日常账本。覆盖明细见 `docs/local/agent-speed-coverage.md`，验收证据见 `docs/local/codex-turns.md`。
