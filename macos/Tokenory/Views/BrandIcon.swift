// [INPUT]: 接收工具、提供方或模型标识，读取品牌资源。
// [OUTPUT]: 提供 Brand、BrandIcon 和 BrandLabel。
// [POS]: 统一统计页和筛选器的品牌映射。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import SwiftUI

enum BrandKind { case tool, provider, model }

enum Brand {
    static let toolSlugs: [String: String] = [
        "amp": "amp", "antigravity": "antigravity", "antigravity-cli": "antigravity",
        "claude": "claude", "cline": "cline", "codebuddy": "codebuddy", "codebuff": "codebuff",
        "codex": "openai", "commandcode": "commandcode", "copilot": "githubcopilot",
        "crush": "crush", "cursor": "cursor", "devin-cli": "devin", "devin-desktop": "devin",
        "droid": "droid", "fx": "fx", "gemini": "geminicli", "goose": "goose", "grok": "grok",
        "hermes": "hermesagent", "jcode": "jcode", "junie": "junie", "kilocode": "kilocode",
        "kimi": "kimi", "kiro": "kiro", "micode": "xiaomimimo", "mux": "mux",
        "openclaw": "openclaw", "opencode": "opencode", "opencodereview": "alibaba",
        "pi": "pi", "qwen": "qwen", "roocode": "roocode", "trae": "trae", "warp": "warp",
        "workbuddy": "workbuddy", "zcode": "zai", "zed": "zed",
    ]
    // 尚无核实的品牌素材；字母图标不冒充其他项目的品牌。
    // nicepkg/kilo 与 Kilo-Org/kilocode 是不同项目。
    static let toolSymbols = ["kilo": "k.square", "reasonix": "r.square", "paseo": "p.square", "orca": "o.square"]
    static let originalSlugs: Set<String> = ["codebuff", "crush", "droid", "fx", "jcode", "mux", "warp", "zed"]
    static let providerOriginalSlugs = Set(ProviderBrand.all.values.filter(\.original).map(\.icon))
    // Match the original tokens.ci ModelIcon treatment and ordered model rules.
    static func slug(_ name: String, kind: BrandKind) -> String? {
        let id = name.lowercased()
        if kind == .tool {
            return toolSlugs[id]
        }
        if kind == .provider {
            let providers = ["anthropic": "claude", "google": "gemini", "moonshot": "kimi", "zhipu": "zai", "github": "githubcopilot", "xiaomi": "xiaomimimo", "meta": "meta", "amazon": "aws", "microsoft": "microsoft", "apple": "apple", "devin": "devin", "cognition": "devin"]
            if id == "xiaomi" { return "provider-xiaomi" }
            if let slug = providers[id] { return slug }
            if let brand = ProviderBrand.all[id] { return brand.icon }
        }
        if id.hasPrefix("accounts/fireworks") { return "fireworks" }
        if id.hasPrefix("@cf/") { return "cloudflare" }
        let rules: [([String], String)] = [
            (["composer", "cursor"], "cursor"),
            (["claude", "anthropic", "fable", "mythos", "sonnet", "opus", "haiku"], "claude"),
            (["gpt", "codex", "openai", "o1-", "o3-", "o4-"], "openai"),
            (["gemma"], "gemma"), (["gemini"], "gemini"), (["deepseek"], "deepseek"),
            (["kimi", "moonshot", "k2p", "k2-", "k2.", "k3"], "kimi"),
            (["glm", "chatglm", "z-ai", "zai"], "zai"), (["grok", "x-ai", "xai"], "grok"),
            (["qwen"], "qwen"), (["minimax"], "minimax"), (["mimo", "xiaomi"], "provider-xiaomi"),
            (["llama"], "meta"), (["mistral", "magistral", "devstral"], "mistral"),
            (["nemotron", "nvidia"], "nvidia"), (["step-", "stepfun"], "stepfun"),
            (["hy3", "hunyuan"], "hunyuan"), (["longcat"], "longcat"),
            (["ling-", "inclusionai"], "antgroup"), (["arcee", "trinity"], "arcee"),
            (["swe-2", "devin", "cognition"], "devin"),
            (["swe-1", "windsurf"], "windsurf"), (["doubao", "ark-"], "doubao"),
            (["ernie", "wenxin", "cobuddy"], "wenxin"), (["nous", "hermes"], "nousresearch"),
            (["perplexity", "sonar"], "perplexity"), (["openrouter"], "openrouter"),
            (["fireworks"], "fireworks"), (["cloudflare"], "cloudflare"),
            (["bedrock"], "bedrock"), (["azure"], "azure"), (["aws"], "aws"),
            (["baidu"], "baidu"), (["bytedance"], "bytedance"), (["volcengine"], "volcengine"),
            (["ollama", ":mlx"], "ollama"),
        ]
        return rules.first { needles, _ in needles.contains { id.contains($0) } }?.1
    }

    static func image(_ name: String, kind: BrandKind) -> Image {
        if let slug = slug(name, kind: kind) {
            return Image("Brand-" + slug)
                .renderingMode(originalSlugs.contains(slug) || providerOriginalSlugs.contains(slug) ? .original : .template)
        }
        if kind == .tool, let symbol = toolSymbols[name.lowercased()] { return Image(systemName: symbol) }
        return Image(systemName: kind == .tool ? "app.dashed" : kind == .provider ? "building.2" : "cube")
    }
}

struct BrandIcon: View {
    let name: String
    let kind: BrandKind
    var size: CGFloat = 14
    var body: some View {
        Brand.image(name, kind: kind).resizable().scaledToFit()
            .frame(width: size, height: size)
            .background {
                if let slug = Brand.slug(name, kind: kind), Brand.providerOriginalSlugs.contains(slug) {
                    RoundedRectangle(cornerRadius: 2).fill(.white)
                }
            }.accessibilityHidden(true)
    }
}

struct BrandLabel: View {
    let name: String
    let kind: BrandKind
    var title: String? = nil
    var size: CGFloat = 14
    var body: some View {
        HStack(spacing: 6) {
            BrandIcon(name: name, kind: kind, size: size)
            Text(title ?? name)
        }
    }
}
