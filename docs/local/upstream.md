# 上游与本地构建

Tokenory fork 自 https://github.com/missuo/tokens，固定基线 `c2f3857c328478e2599a3ba871151ec255e00831`。保留上游 MIT 许可证和版权。

- origin: https://github.com/ryekee/tokenory
- upstream: https://github.com/missuo/tokens
- 本地实现分支：`codex/macos-menubar`
- 首版 Rust 为 1.99.1；Xcode 27.2，目标 macOS 14+。当前只验本机 arm64。
- `./script/build.sh` 联合构建 Rust 与 SwiftUI；`./script/build_and_run.sh` 构建并打开 App。
- 如项目存在 `.tools/cargo`，脚本自动使用项目内工具链；否则使用 PATH 中的 cargo。
- `macos/project.yml` 为工程源文件；用 XcodeGen 生成 `.xcodeproj`，不手改生成工程。
- 开发构建使用 ad-hoc 签名，仅证明本机可运行，不代表 Developer ID、公证或其他机器验收。

后续只按需同步解析、去重和定价修复；本地持久化和原生 UI 不耦合上游公共站点。
