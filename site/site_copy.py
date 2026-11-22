"""Bilingual website copy. Release notes come from published GitHub Releases."""

COPY = {
    "en": {
        "switch": "简体中文",
        "nav": "Main navigation",
        "faq": "FAQ",
        "changelog": "Changelog",
        "headline": ("Your code has vibe,", "Your usage needs a Counter"),
        "headline_emphasis": "Counter",
        "intro": "Put a price on tokens. See where the time went.",
        "download": "Download for macOS",
        "nav_download": "Download",
        "footer_nav": "Footer navigation",
        "requirements": "Apple silicon · macOS 15 or later",
        "demo": "Try the counter",
        "tokens": "Tokens",
        "cost": "Estimated cost",
        "sample": "Sample data",
        "run_counter": "Add a turn",
        "hud_done": "All turns counted",
        "hud_input": "In",
        "hud_output": "Out",
        "sound": "Roller sound",
        "features_title": "What happened while the agent worked?",
        "cost_example": "Estimated cost by model",
        "speed_example": "One completed turn",
        "speed_labels": ("First token", "Tool wait", "Total time"),
        "features": [
            (
                "Give tokens a price tag.",
                "A million tokens means something different on each model. See what your usage would cost at API rates and which models account for most of it.",
            ),
            (
                "Find out what took so long.",
                "Check how long it took for the first token to appear and, when your tool records it, how much of the turn went to waiting for tools.",
            ),
            (
                "Your usage history stays on your Mac.",
                "Tokenory reads local logs and saves the ledger on your Mac. You can back it up and bring in your history from CC Switch or tokens.ci.",
            ),
        ],
        "questions": [
            (
                "What do I need to run Tokenory?",
                "An Apple silicon Mac with macOS 15 or later. Unzip the download, move Tokenory to Applications, and open it. You'll find it in your menu bar.",
            ),
            (
                "Which coding tools are supported?",
                "Tokenory reads local logs and databases from tools like Codex, Claude Code, and OpenCode. Cursor, Trae, and Warp need a locally synced cache. Speed statistics depend on what each tool records.",
            ),
            (
                "What does the estimated cost mean?",
                "Tokenory uses standard API rates to estimate what your usage would cost. It shows costs reported by your tools separately. Usage without a matching rate stays unpriced. Your provider handles subscription billing.",
            ),
            (
                "Where is my usage data stored?",
                "Your ledger stays on your Mac. Back it up or restore it in Settings → Data. Tokenory connects to GitHub for app updates and model rates.",
            ),
            (
                "How do I show the floating counter?",
                "Choose Show HUD from the Tokenory menu bar menu or turn it on in Settings → HUD. There you can also choose its position and adjust the sound.",
            ),
            (
                "How do I update Tokenory?",
                "Choose Check for Updates from the Tokenory menu or Settings → General. You'll be asked before the update installs and the app restarts.",
            ),
        ],
        "sources": "See supported tools and data sources",
        "new_header": "New Features",
        "fix_header": "Fixes",
    },
    "zh-Hans": {
        "switch": "English",
        "nav": "主导航",
        "faq": "常见问题",
        "changelog": "更新记录",
        "headline": ("抠腚有氛围，", "用量有分寸"),
        "headline_emphasis": "分寸",
        "intro": "给 Token 算笔账，把慢回合拆开看。",
        "download": "下载 Mac 版",
        "nav_download": "下载",
        "footer_nav": "页脚导航",
        "requirements": "Apple 芯片 · macOS 15 或更高版本",
        "demo": "试试计数器",
        "tokens": "Tokens",
        "cost": "估算费用",
        "sample": "演示数据",
        "run_counter": "加一次用量",
        "hud_done": "用量已全部计入",
        "hud_input": "输入",
        "hud_output": "输出",
        "sound": "滚轮音效",
        "features_title": ("Agent 干活时，", "都干了什么"),
        "cost_example": "按模型看估算费用",
        "speed_example": "一次已完成的回合",
        "speed_labels": ("等到首个 Token", "等待工具", "回合总耗时"),
        "features": [
            (
                "用掉的 Token，折合多少钱？",
                "同样是一百万 Token，不同模型的价格不一样。按 API 费率估算，再看看费用主要花在哪些模型上。",
            ),
            (
                "这一回合，时间花在哪儿？",
                "看看从发出请求到首个 Token 等了多久。工具日志有记录时，还能看到有多少时间花在等待工具返回上。",
            ),
            (
                "用量历史留在你的 Mac。",
                "Tokenory 读取本机日志，账本也存在本机。你可以备份账本，或把 CC Switch 和 tokens.ci 的历史记录导进来。",
            ),
        ],
        "questions": [
            (
                "什么样的 Mac 可以使用 Tokenory？",
                "需要搭载 Apple 芯片、运行 macOS 15 或更高版本的 Mac。下载后解压，将 Tokenory 拖入「应用程序」并打开，就可以从菜单栏使用。",
            ),
            (
                "支持哪些编程工具？",
                "Tokenory 读取 Codex、Claude Code、OpenCode 等工具的本机日志和数据库。Cursor、Trae 和 Warp 需要先同步本机缓存。速度统计取决于工具日志记录的内容。",
            ),
            (
                "估算费用是什么意思？",
                "Tokenory 按 API 参考费率估算费用，单独列出工具报告的费用。查不到费率的用量会标为待计价。订阅金额以服务商账单为准。",
            ),
            (
                "用量数据存在哪里？",
                "账本保存在你的 Mac 上，可在「设置 → 数据」中备份或恢复。检查应用更新和刷新模型费率时，Tokenory 会连接 GitHub。",
            ),
            (
                "怎么打开悬浮计数器？",
                "从菜单栏打开 Tokenory，选择「显示 HUD」。也可以在「设置 → HUD」里打开，再选位置、调音效。",
            ),
            (
                "怎么更新 Tokenory？",
                "从 Tokenory 菜单或「设置 → 通用」选择「检查更新」。安装更新和重启应用前会请你确认。",
            ),
        ],
        "sources": "查看支持的工具和数据来源",
        "new_header": "新功能",
        "fix_header": "修复",
    },
}
