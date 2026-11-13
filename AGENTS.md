# Tokenory - 本地 AI 用量和等价费用账本
Swift 6 + SwiftUI + Rust + SQLite + Sparkle 2.10.1

## 模块地图
- `macos/Tokenory/`：原生菜单栏和统计窗口。通过 IPC 调用 Rust worker。
- `macos/TokenoryTests/`：原生状态、展示和协议测试。
- `cli/tokenory/`：本地账本、采集、导入、计价和 IPC；data 保存离线全量目录。
- `cli/tokens-core/`：上游日志解析及价格数据适配。
- `cli/tokens-cli/`：上游 CLI。
- `assets/brand/`：品牌设计及供应商图标源文件；providers 为生成的全量品牌源。
- `script/`：构建、资源生成、签名和发布入口。
- `docs/local/`：计价口径、数据来源和维护说明。
- `web/`、`packages/`、`scripts/`、`deploy/`：保留的上游 Web、包及部署工具。
- `local-data/`：本地开发数据。

## 入口和约束
- `macos/project.yml`：XcodeGen 项目源。不要手改生成的 Xcode 项目。
- `cli/Cargo.toml`：Rust workspace。
- `script/build_and_run.sh`：构建并启动原生应用。
- `script/generate_brand_icons.py`：由 Web 字形和 vendor SVG 生成原生资源。
- `cargo test --manifest-path cli/Cargo.toml -p tokenory`：账本测试。
- `xcodebuild test -project macos/Tokenory.xcodeproj -scheme Tokenory -derivedDataPath .build/xcode -destination 'platform=macOS'`：原生测试。
- 价格更新自动回填待计价记录并备份；已有金额重估先预览并备份。
- 源成本、标准费率估算和订阅扣费保持独立。
- 修改模块时更新文件契约、模块地图和对应使用说明。
