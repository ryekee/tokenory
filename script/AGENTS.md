# script/
> L2 | Parent: ../AGENTS.md

build.sh: 构建 Rust helper 与 Xcode 应用并验证签名。
build_and_run.sh: 停止旧进程，构建并启动应用。
generate_brand_icons.py: 从 `assets/brand/glyphs.json`、vendor 品牌素材和供应商图标生成原生资源，展开 CoreSVG 无法区分的紧凑弧线标志。
generate_icons.py: 从品牌源图生成应用和菜单栏图标。强调色由原生资源目录独立维护。
package_release.sh: 校验双语更新说明，嵌入 Developer ID 描述文件并核对 Production CloudKit 签名，再公证与生成发布产物。
cloudkit_release_profile.py: 匹配 Hiko 的签名证书、正式 App ID 与 iCloud 容器，可用 TOKENORY_DEVELOPER_ID_PROFILE 指定描述文件。
publish_pricing.py: 校验并独立发布 updates/pricing.json。
publish_release.py: 核对草稿附件和公开下载地址，发布双语版本说明及三份 Sparkle 更新清单。
release_notes.py: 校验更新说明 JSON，生成 GitHub Markdown 和 Sparkle 本地化说明。
tests/: 发布脚本测试。
update-smoke/: 更新验收记录和工具。


update_provider_catalog.py: 从 models.dev 生成全量离线目录和供应商品牌源文件。

[PROTOCOL]: Update this header on change, then check AGENTS.md
