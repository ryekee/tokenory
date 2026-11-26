# macos/Tokenory/Services/
> L2 | Parent: ../../../AGENTS.md

EngineClient.swift: Rust worker 生命周期、IPC 请求和事件。按请求 ID 拼接有序快照分块，校验结束计数，在取消、超时或 worker 结束时释放请求。超时将操作名和请求 ID 写入 macOS 统一日志的 `ee.ryek.tokenory / EngineIPC`，不记录请求数据。
DeviceCloudSync.swift: 私有 CloudKit 设备汇总、发布顺序、远端资产校验缓存。停传阻止新上传，确认前等待已提交的上传结束。明确区分新删除与核实上次删除；持久保留远端撤销状态。
DeviceCloudErrors.xcstrings: 依照应用所选中英文显示同步与账号错误。
LoginItemService.swift: 系统登录启动状态与操作。
UpdateChecker.swift: Sparkle 更新检查、计划及按应用语言选择更新清单。
HUDController.swift: 跟随鼠标所在屏幕，关闭跟随后固定当前可见屏幕。浮动面板留在桌面空间，避让菜单栏和 Dock。开启自动隐藏后，30 秒无新用量时隐藏，新用量唤醒。三击按偏好关闭、暂时隐藏或忽略。隐藏时释放视图与音效。
HUDAnimator.swift: 首次、跨日与指标变化静默落位；小步进采用进位缓动，大跨度使用限转滚动；新读数保留当前位置、速度与时钟，实际数字齿位驱动音效。
HUDSound.swift: 本地 PCM 机械点击声、音量和静音。滚动声与即时音量试听共用样本，分别停止。

[PROTOCOL]: Update this header on change, then check AGENTS.md
