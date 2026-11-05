# Tokenory：数字、图标与窗口细节

本轮按用户的 7 项补充要求实施，并使用 impeccable 的原生界面检查方式复查。

## 结果

- USD 统一使用 `$`、逗号分组和两位小数，例如 `$1,740.70`。Token 缩写最多两位小数，保留中文万/亿和英文 K/M/B 单位，例如 `1,740.69万`。明细中的完整 token 整数仍有逗号分组。显示四舍五入不改变存储值、单位费率或计价精度。
- 主窗口、设置和菜单栏内容关闭视觉焦点光环。保留原生键盘操作、焦点导航和辅助功能标签。这是用户明确指定的视觉取舍。
- 工作窗口打开时切换到 regular 激活策略，显示 Dock 入口。最后一个工作窗口关闭时恢复 accessory 策略。最小化不触发关闭逻辑；Dock 重开动作恢复主窗口。
- 费用采用 Swift Charts 的 monotone 平滑插值，保留原数据点、零基线和未知费用的断线。
- 工具、提供方和模型使用 tokens.ci 原项目的单色字形方案。39 个 SVG 图标编译进原生资源，随文字颜色适配深浅外观，不使用彩色贴图或独立图标底板。未知名称使用中性系统图标。
- 图标覆盖筛选器、用量分布、模型排行、明细列表和详情、价格目录、采集设置、导入冲突及来源页、菜单栏工具摘要。

## 来源与维护

图标处理参考项目中 `web/src/components/profile/ModelIcon.tsx`、`web/src/lib/modelIcons.ts` 和 `web/src/components/SourceLogo.tsx`。生成脚本读取原有 `brandIcons.generated.ts`，额外引入同一 MIT 图标包的 Cline、GitHub Copilot 图标。原生 assets 通过 `python3 script/generate_brand_icons.py` 更新，许可证随应用打包。

默认图标尺寸为 14 pt，标题使用 18–22 pt。实际运行曾发现原生 Picker 会忽略 SwiftUI 外层尺寸、采用 SVG 的 24 pt 固有尺寸；现已把生成资源的固有尺寸改为 14 pt，保留 24×24 viewBox 和矢量缩放。

## 验证

- macOS XCTest：13 项通过，覆盖数字分组和四舍五入、未知费用、品牌映射与网关优先级、图标资源加载和固有尺寸，以及原有数据与本地化测试。
- Release 构建及 `codesign --verify --deep --strict` 通过。
- 深色中文：检查主图、金额、模型排行、明细和详情弹窗、通用/价格/采集设置，实际界面未见焦点光环、图标挤压或列错位。
- 浅色英文：检查主图、工具菜单及选中状态、模型图标和来源页，确认单色标识可见，菜单图标尺寸与正文一致。浅色检查使用临时进程外观，交付源码已移除该覆盖。
- 使用 NSWorkspace 读取实际应用状态：工作窗口打开时 `activationPolicy == regular`，通过 Close All 关闭窗口后为 `accessory`。Dock 自身的辅助功能读取超时，因此没有把 Dock 图标的屏幕截图作为证据。
- 自动检查工具中途超时；应用主线程采样处于正常事件等待，恢复连接后继续完成了明细和浅色检查。
- 未重复上一轮的 Rust 测试：本轮没有后端改动。未执行完整 VoiceOver 朗读验收或全部第三方品牌的逐项视觉验收。

本轮日志保留于 `.build/ui-validation/2026-11-06/presentation/`。
