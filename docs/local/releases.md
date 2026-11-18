# macOS 发布

更新源位于 `https://raw.githubusercontent.com/ryekee/tokenory/updates/`。Tokenory 语言选为跟随系统时读取双语 `appcast.xml`，Sparkle 按系统语言显示说明，默认回退英语。Tokenory 语言选为 English 或简体中文时分别读取 `appcast.en.xml` 或 `appcast.zh-Hans.xml`。旧版 Tokenory 继续读取 `appcast.xml`。

每个正式 Release 必须包含同一次打包生成的 ZIP、`appcast.xml`、`SHA256SUMS.txt`，再设置为 latest。发布脚本在同一次提交中更新 `updates` 分支的三份清单；它们指向同一个已签名的 ZIP。该分支的远程费率目录独立更新，见 [价格说明](pricing.md)。更换 ZIP 需要重新生成 Sparkle 签名。

raw 清单与 Release 附件均使用公开的 GitHub Release 下载地址，App 下载不依赖匿名 REST API 配额。2026-11-15 的 Sparkle 日志记录了 Asset API 下载返回 403；普通 Release 地址匿名回下载通过 SHA256 校验，因此恢复使用公开下载路径。发布脚本仍通过已认证 API 核验附件；正式验收必须覆盖不带登录凭据的下载路径，不能用认证下载替代。更新包仍由 Sparkle 的 EdDSA 和 Developer ID 校验。

1. 在 `macos/project.yml` 递增 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`。Sparkle 按 build 号比较版本，build 必须递增。
2. 通过 `script/build.sh` 和 Xcode 的 Tokenory test scheme 验证改动，提交源码。
3. 按下方格式编写双语更新说明，运行 `./script/package_release.sh /absolute/path/release-notes.json`。脚本先验证说明，再开始构建。
4. 脚本构建 Release，按从内到外的顺序签名 Sparkle 组件、Rust helper 和主 App，提交公证，附加票据，重新打包，再生成带 EdDSA 更新包签名和双语说明的清单。
5. 确认源码已推送，运行 `./script/publish_release.py .build/releases/vVERSION --target FULL_COMMIT_SHA`。脚本检查说明与清单是否一致，上传 ZIP 到草稿，核对远端 SHA256，上传兼容清单与校验值，然后写入双语正文并正式发布。随后在 `updates` 分支同步发布三份清单。重试草稿时会刷新说明正文；重试已发布版本只能使用同一份 ZIP、清单和正文。
6. 回下载验证 SHA256、`codesign --verify --deep --strict`、`stapler validate` 和 Gatekeeper。匿名读取三份 raw 清单，核对版本、签名和安装包长度，并从 Tokenory 的语言设置验证更新窗口的说明。

## 双语更新说明

`release-notes.json` 是 GitHub Release 正文和 Sparkle 说明的共用输入。

```json
{
  "en": {
    "features": ["Compare usage across providers."],
    "fixes": ["Fixed a crash when opening the usage HUD."]
  },
  "zh-Hans": {
    "features": ["支持对比各供应商的用量。"],
    "fixes": ["修复打开用量 HUD 时的崩溃。"]
  }
}
```

每个条目用一行描述用户能看到的变化。中英文在各分类内逐条对齐，至少有一项新功能或修复。分类无内容时，两种语言都用空数组，该标题会省略。用 `python3 script/release_notes.py /absolute/path/release-notes.json` 预览 GitHub 正文。Sparkle 在清单中读取对应语言的 Markdown。 [Sparkle 本地化说明](https://sparkle-project.org/documentation/publishing/#localization)

若在上传草稿前调整文字，可更新产物目录里的 `release-notes.json`，再运行 `python3 script/release_notes.py .build/releases/vVERSION/release-notes.json --appcast .build/releases/vVERSION/appcast.xml`。发布时会重新计算清单的 SHA256。

## 签名和更新

默认签名身份为 Hiko Developer ID，公证使用钥匙串 profile `Hiko-notray`。可以通过 `TOKENORY_SIGNING_IDENTITY` 和 `TOKENORY_NOTARY_PROFILE` 指定已有配置。

Sparkle 2.10.1 通过 XcodeGen 的精确版本依赖引入。更新签名私钥保存在 macOS 钥匙串账户 `ee.ryek.tokenory`，不会写入仓库或发布包。迁移发布机器时须安全迁移该密钥，不可直接重新生成并替换公钥。

Debug 构建使用 ad-hoc 签名，不启用 hardened runtime，以加载 Sparkle。正式包启用 hardened runtime，所有嵌套组件使用同一 Developer ID 签名。

自动检查使用 Sparkle 自带调度和持久化设置；应用退出期间不检查，重新启动后根据上次检查时间安排检查。关闭自动检查仍可手动检查，改变频率会重排下一次检查。自动检查只提示新版本，不静默安装。
