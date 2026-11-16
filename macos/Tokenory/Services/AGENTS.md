# macos/Tokenory/Services/
> L2 | Parent: ../../../AGENTS.md

EngineClient.swift: Rust worker 生命周期、IPC 请求和事件。
LoginItemService.swift: 系统登录启动状态与操作。
UpdateChecker.swift: Sparkle 更新检查与计划。
HUDController.swift: 每 250 ms 跟随鼠标所在屏幕； 不抢焦点的浮动面板、字体注册、六种贴边位置，按 visibleFrame 避让菜单栏和 Dock；隐藏时释放视图。
HUDAnimator.swift: 首次/跨日/指标变化静默落位；动画期间新读数直接延长当前滚动，保留位置、速度与时钟，实际数字齿位驱动音效。
HUDSound.swift: 本地 PCM 机械点击声、音量和静音；停止后释放音频执行。

[PROTOCOL]: Update this header on change, then check AGENTS.md
