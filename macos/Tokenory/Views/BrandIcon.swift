import SwiftUI

enum BrandKind { case tool, provider, model }

enum Brand {
    // Match the original tokens.ci ModelIcon treatment and ordered model rules.
    static func slug(_ name: String, kind: BrandKind) -> String? {
        let id = name.lowercased()
        if kind == .tool {
            let tools = ["claude": "claude", "codex": "openai", "copilot": "githubcopilot", "cline": "cline", "micode": "xiaomimimo"]
            if let slug = tools[id] { return slug }
        }
        if kind == .provider {
            let providers = ["anthropic": "claude", "google": "gemini", "moonshot": "kimi", "zhipu": "zai", "github": "githubcopilot", "xiaomi": "xiaomimimo", "meta": "meta", "amazon": "aws", "microsoft": "microsoft", "apple": "apple"]
            if let slug = providers[id] { return slug }
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
            (["qwen"], "qwen"), (["minimax"], "minimax"), (["mimo", "xiaomi"], "xiaomimimo"),
            (["llama"], "meta"), (["mistral", "magistral", "devstral"], "mistral"),
            (["nemotron", "nvidia"], "nvidia"), (["step-", "stepfun"], "stepfun"),
            (["hy3", "hunyuan"], "hunyuan"), (["longcat"], "longcat"),
            (["ling-", "inclusionai"], "antgroup"), (["arcee", "trinity"], "arcee"),
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
        if let slug = slug(name, kind: kind) { return Image("Brand-" + slug) }
        return Image(systemName: kind == .tool ? "app.dashed" : kind == .provider ? "building.2" : "cube")
    }
}

struct BrandIcon: View {
    let name: String
    let kind: BrandKind
    var size: CGFloat = 14
    var body: some View {
        Brand.image(name, kind: kind).renderingMode(.template).resizable().scaledToFit()
            .frame(width: size, height: size).accessibilityHidden(true)
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
