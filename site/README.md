# Tokenory 官网

英文位于 `/`，简体中文位于 `/zh-hans/`。两种语言都有首页、常见问题和更新记录。HUD 试玩在首页，切换语言时保留当前页面。

```sh
python3 site/build.py
python3 -m http.server 8772 --bind 127.0.0.1 --directory site/dist
```

构建使用 Python 标准库，默认读取本地 `releases.json`。使用 `python3 site/build.py --refresh-releases` 可通过已认证的 `gh` 刷新正式发布数据、下载链接和更新说明。同一版本有多个 Mac 安装包时，下载按钮优先指向 build 编号最高的正式附件，并保留历史版本的文件名兼容性。每个版本号链接至 GitHub Release。双语说明跟随页面语言，历史版本使用 GitHub 渲染的已发布正文。

`site_copy.py` 保存界面文案，`page.html` 保存共享页面结构。构建从品牌目录读取应用图标，从 `site/fonts/` 复制机械 HUD 数字字体及许可证。该 Saira Extra Condensed SemiBold 字体提取自最初的机械 HUD 原型。共享导航使用与 RuaKey 相同的 Phosphor 图标，许可证在 `site/icons/LICENSE.txt`。

首页 `demo.js` 每次点击生成一笔模拟输入和输出，按仓库随附的标准 API 费率估算费用。站点使用的费率出处见 [OpenAI](https://developers.openai.com/api/docs/pricing) 和 [Anthropic](https://platform.claude.com/docs/en/about-claude/pricing)。单击沿用原生 HUD 的 4.2 秒曲线。连点合入同一次滚动，从滚动开始计，最多 6 秒后停在实际累计值。滚轮按十进制进位，高速时允许略过中间齿位。满 6 秒后继续连点即时入账。停稳后，间隔超过 400 毫秒的点击会开启新的滚动。费用累加到显示时再舍入。

官网使用 RuaKey 所在 Cloudflare 账号的独立 `tokenory` Worker，绑定 `tokenory.ryek.ee`。发布已验收的改动时，先刷新 GitHub Releases 再部署静态资源。

```sh
python3 site/build.py --refresh-releases
npx --yes wrangler@4.158.0 deploy --dry-run
npx --yes wrangler@4.158.0 deploy
```

通过 Cloudflare 控制台部署时，上传 `site/dist/`，使用生产 Worker `tokenory`，HTML handling 设为 `force-trailing-slash`。首次部署通过该入口完成，生产站点位于 [tokenory.ryek.ee](https://tokenory.ryek.ee/)。

GitHub 正式发布会触发 **Tokenory website** 工作流，更新官网下载和更新记录。仓库的 Actions Secrets 需要 `CLOUDFLARE_ACCOUNT_ID` 和 `CLOUDFLARE_API_TOKEN`。在 Cloudflare 创建账号级 API Token 时，将 **Individual Workers Editor** 权限限定到 **tokenory** Worker。工作流上传并发布 Worker 版本，沿用现有域名和路由。

只改了历史发布正文时，在 main 分支手动运行 **Tokenory website**，并勾选 **deploy**。
