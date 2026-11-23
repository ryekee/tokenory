# macos/Tokenory/Services/
> L2 | Parent: ../../../AGENTS.md

EngineClient.swift: Rust worker 生命周期、IPC 请求、事件和非主线程的类型化报告解码。
DeviceCloudSync.swift: 当前用户私有 CloudKit 的设备汇总、发布顺序、资产校验缓存、设备与账号级撤回。
DeviceCloudErrors.xcstrings: 依照应用所选中英文显示同步与账号错误。
LoginItemService.swift: 系统登录启动状态与操作。
UpdateChecker.swift: Sparkle 更新检查、计划及按应用语言选择更新清单。
HUDController.swift: 每 250 ms 跟随鼠标所在屏幕；不抢焦点的浮动面板留在桌面空间，按 visibleFrame 避让菜单栏和 Dock；关闭 HUD 时释放视图。
HUDAnimator.swift: 首次、跨日与指标变化静默落位；小步进采用进位缓动，大跨度使用限转滚动；新读数保留当前位置、速度与时钟，实际数字齿位驱动音效。
HUDSound.swift: 本地 PCM 机械点击声、音量和静音；停止后释放音频执行。

[PROTOCOL]: Update this header on change, then check AGENTS.md
