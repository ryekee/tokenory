# macOS 发布

更新源固定为 `https://github.com/ryekee/tokenory/releases/latest/download/appcast.xml`。
每个正式 Release 必须包含同一次打包生成的 ZIP、`appcast.xml`、`SHA256SUMS.txt`，再设置为 latest。不要单独替换 ZIP，否则 Sparkle 签名会失效。

1. 在 `macos/project.yml` 递增 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`。Sparkle 按 build 号比较版本，build 必须递增。
2. 通过 `script/build.sh` 和 Xcode 的 Tokenory test scheme 验证改动，提交源码。
3. 编写更新说明，运行 `./script/package_release.sh /absolute/path/release-notes.md`。
4. 脚本构建 Release，按从内到外的顺序签名 Sparkle 组件、Rust helper 和主 App，提交公证，附加票据，重新打包，再生成带 EdDSA 更新包签名的 appcast。
5. 确认源码已推送，使用 `gh release create` 发布三个文件，通过 `--target` 指定构建所用的提交，`--notes-file` 指定说明，`--latest` 标记正式版。
6. 回下载验证 SHA256、`codesign --verify --deep --strict`、`stapler validate` 和 Gatekeeper；确认 latest 的 `appcast.xml` 能公开读取。

默认签名身份为 Hiko Developer ID，公证使用钥匙串 profile `Hiko-notray`。可以通过 `TOKENORY_SIGNING_IDENTITY` 和 `TOKENORY_NOTARY_PROFILE` 指定已有配置。

Sparkle 2.10.1 通过 XcodeGen 的精确版本依赖引入。更新签名私钥保存在 macOS 钥匙串账户 `ee.ryek.tokenory`，不会写入仓库或发布包。迁移发布机器时须安全迁移该密钥，不可直接重新生成并替换公钥。

Debug 构建使用 ad-hoc 签名，不启用 hardened runtime，以加载 Sparkle。正式包启用 hardened runtime，所有嵌套组件使用同一 Developer ID 签名。

自动检查使用 Sparkle 自带调度和持久化设置；应用退出期间不检查，重新启动后根据上次检查时间安排检查。关闭自动检查仍可手动检查，改变频率会重排下一次检查。自动检查只提示新版本，不静默安装。
