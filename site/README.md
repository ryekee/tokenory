# Tokenory 官网

英文位于 `/`，简体中文位于 `/zh-hans/`。两种语言都有首页、常见问题和更新记录。HUD 试玩在首页，切换语言时保留当前页面。

```sh
python3 site/build.py
python3 -m http.server 8772 --bind 127.0.0.1 --directory site/dist
```

构建使用 Python 标准库，默认读取本地 `releases.json`。使用 `python3 site/build.py --refresh-releases` 可通过已认证的 `gh` 刷新正式发布数据、下载链接和更新说明。每个版本号链接至 GitHub Release。双语说明跟随页面语言，历史版本使用 GitHub 渲染的已发布正文。审阅稿位于 `docs/local/release-notes-review.md`。

`site_copy.py` 保存界面文案，`page.html` 保存共享页面结构。构建从品牌目录读取应用图标，从机械 HUD 原型提取数字字体。共享导航使用与 RuaKey 相同的 Phosphor 图标，许可证在 `site/icons/LICENSE.txt`。

首页 `demo.js` 每次点击生成一笔模拟输入和输出，按仓库随附的标准 API 费率估算费用。站点使用的费率出处见 [OpenAI](https://developers.openai.com/api/docs/pricing) 和 [Anthropic](https://platform.claude.com/docs/en/about-claude/pricing)。单击沿用原生 HUD 的 4.2 秒曲线。连点合入同一次滚动，从滚动开始计，最多 6 秒后停在实际累计值。滚轮按十进制进位，高速时允许略过中间齿位。满 6 秒后继续连点即时入账。停稳后，间隔超过 400 毫秒的点击会开启新的滚动。费用累加到显示时再舍入。

官网使用 RuaKey 所在 Cloudflare 账号的独立 `tokenory` Worker，绑定 `tokenory.ryek.ee`。发布已验收的改动时，先刷新 GitHub Releases 再部署静态资源。

```sh
python3 site/build.py --refresh-releases
npx --yes wrangler@4.158.0 deploy --dry-run
npx --yes wrangler@4.158.0 deploy
```

通过 Cloudflare 控制台部署时，上传 `site/dist/`，使用生产 Worker `tokenory`，HTML handling 设为 `force-trailing-slash`。首次部署通过该入口完成，生产站点位于 [tokenory.ryek.ee](https://tokenory.ryek.ee/)。

如通过 GitHub Actions 部署，在仓库配置 `CLOUDFLARE_ACCOUNT_ID` 和有 Workers 脚本及自定义域名发布权限的 `CLOUDFLARE_API_TOKEN`，然后在 main 分支运行 **Tokenory website** 并勾选 **deploy**。工作流在 GitHub 发布正式版时更新下载和更新记录。只改了历史发布正文时，手动运行同一工作流刷新官网。
