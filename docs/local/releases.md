# macOS 发布

更新源固定为 `https://raw.githubusercontent.com/ryekee/tokenory/updates/appcast.xml`。
每个正式 Release 必须包含同一次打包生成的 ZIP、`appcast.xml`、`SHA256SUMS.txt`，再设置为 latest。发布脚本同步生成 `updates` 分支的清单；该分支只用于发布，不手工编辑。不要单独替换 ZIP，否则 Sparkle 签名会失效。

raw 清单中的安装包 URL 使用匿名 GitHub Release Asset API，App 发送 `Accept: application/octet-stream`。这避开了 GitHub 网页下载重定向的 504 路径，不需要 GitHub 登录或 token。更新包仍由 Sparkle 的 EdDSA 和 Developer ID 校验。Release 附件 `appcast.xml` 保留网页下载 URL，兼容不发送 API 请求头的 v0.1.3；raw 分支发布单独生成的 `appcast-api.xml` 内容。

1. 在 `macos/project.yml` 递增 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`。Sparkle 按 build 号比较版本，build 必须递增。
2. 通过 `script/build.sh` 和 Xcode 的 Tokenory test scheme 验证改动，提交源码。
3. 编写更新说明，运行 `./script/package_release.sh /absolute/path/release-notes.md`。
4. 脚本构建 Release，按从内到外的顺序签名 Sparkle 组件、Rust helper 和主 App，提交公证，附加票据，重新打包，再生成带 EdDSA 更新包签名的 appcast。
5. 确认源码已推送，运行 `./script/publish_release.py .build/releases/vVERSION --target FULL_COMMIT_SHA`。脚本先上传 ZIP 到草稿，核对远端 SHA256，生成指向该资产 API URL 的 raw 清单，上传兼容清单与校验值，再正式发布并更新 `updates` 分支。可重试同一版本；已发布 ZIP 不会被覆盖。
6. 回下载验证 SHA256、`codesign --verify --deep --strict`、`stapler validate` 和 Gatekeeper；确认固定 raw 清单能匿名读取，并且它与 Release 兼容清单的版本、签名和安装包长度一致。

默认签名身份为 Hiko Developer ID，公证使用钥匙串 profile `Hiko-notray`。可以通过 `TOKENORY_SIGNING_IDENTITY` 和 `TOKENORY_NOTARY_PROFILE` 指定已有配置。

Sparkle 2.10.1 通过 XcodeGen 的精确版本依赖引入。更新签名私钥保存在 macOS 钥匙串账户 `ee.ryek.tokenory`，不会写入仓库或发布包。迁移发布机器时须安全迁移该密钥，不可直接重新生成并替换公钥。

Debug 构建使用 ad-hoc 签名，不启用 hardened runtime，以加载 Sparkle。正式包启用 hardened runtime，所有嵌套组件使用同一 Developer ID 签名。

自动检查使用 Sparkle 自带调度和持久化设置；应用退出期间不检查，重新启动后根据上次检查时间安排检查。关闭自动检查仍可手动检查，改变频率会重排下一次检查。自动检查只提示新版本，不静默安装。
