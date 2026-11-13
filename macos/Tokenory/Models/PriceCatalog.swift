// [INPUT]: 解码引擎价格目录与生成的供应商品牌资源。
// [OUTPUT]: 提供完整费率目录、品牌名称和费率分组。
// [POS]: 价格协议到设置页的展示模型；不计算账本金额。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import Foundation

struct PriceCatalogResponse: Decodable {
    struct Current: Decodable {
        struct Snapshot: Decodable { let entries: [PriceCatalogEntry] }
        let snapshot: Snapshot
    }
    let current: Current?
    let catalog: [PriceCatalogEntry]?
    let usedModels: [PriceModelIdentity]?
}
struct PriceModelIdentity: Decodable, Hashable {
    let provider: String
    let model: String
}
struct PriceCatalogEntry: Decodable {
    let provider: String
    let model: String
    let rates: [String: Double?]
    let schedule: String?
    let allowFast: Bool
    let explicitFree: Bool
}
struct PriceRateGroup: Identifiable {
    let entries: [PriceCatalogEntry]
    var id: String { entries[0].model }
    var rates: [String: Double?] { entries[0].rates }
    func price(_ key: String) -> Double? { rates[key] ?? nil }
}
struct PriceProviderGroup: Identifiable {
    let id: String
    let groups: [PriceRateGroup]
    var title: String {
        switch id {
        case "openai": "OpenAI"
        case "anthropic": "Anthropic"
        case "deepseek": "DeepSeek"
        case "google": "Google"
        case "devin", "cognition": "Devin"
        case "mistralai": "Mistral AI"
        case "moonshot": "Moonshot AI"
        case "zhipu": "Zhipu AI"
        case "_session": L("provider.unspecified")
        case "unknown": L("provider.unknown")
        default: ProviderBrand.all[id]?.name ?? id
        }
    }
    static func make(_ entries: [PriceCatalogEntry]) -> [PriceProviderGroup] {
        Dictionary(grouping: entries, by: \.provider).map { provider, entries in
            var grouped: [[PriceCatalogEntry]] = []
            for entry in entries.sorted(by: { $0.model.localizedStandardCompare($1.model) == .orderedAscending }) {
                // Compare every rate and schedule, including long-context/cache
                // tiers, so equal headline prices never hide different pricing.
                if let index = grouped.firstIndex(where: {
                    let first = $0[0]
                    return first.rates == entry.rates && first.schedule == entry.schedule
                        && first.allowFast == entry.allowFast && first.explicitFree == entry.explicitFree
                }) { grouped[index].append(entry) }
                else { grouped.append([entry]) }
            }
            let groups = grouped.map { PriceRateGroup(entries: $0) }.sorted {
                let left = $0.price("input_cost_per_token") ?? .infinity
                let right = $1.price("input_cost_per_token") ?? .infinity
                return left == right ? $0.id < $1.id : left < right
            }
            return PriceProviderGroup(id: provider, groups: groups)
        }.sorted {
            if $0.id == "_session" || $1.id == "_session" { return $1.id == "_session" && $0.id != "_session" }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}

struct ProviderBrand: Decodable {
    let name: String
    let icon: String
    let subscription: Bool
    let original: Bool
    static let all: [String: ProviderBrand] = {
        let url = Bundle.main.url(forResource: "ProviderCatalog", withExtension: "json")!
        return try! JSONDecoder().decode([String: ProviderBrand].self, from: Data(contentsOf: url))
    }()
}
