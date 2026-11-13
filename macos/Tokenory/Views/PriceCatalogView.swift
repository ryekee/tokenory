// [INPUT]: 接收完整目录、账本已用模型和搜索条件。
// [OUTPUT]: 展示对齐的范围筛选、搜索和可折叠费率表。
// [POS]: 设置价格页的只读目录；折叠状态不改变计价数据。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import SwiftUI

struct PriceCatalogView: View {
    let providers: [PriceProviderGroup]
    let usedModels: Set<PriceModelIdentity>
    @AppStorage("priceCatalog.usedOnly") private var usedOnly = false
    @State private var query = ""
    @State private var expandedProviders: Set<String> = []
    @Environment(\.colorScheme) private var scheme

    private var filtered: [PriceProviderGroup] {
        return providers.compactMap { provider in
            let groups = provider.groups.compactMap { group -> PriceRateGroup? in
                let entries = group.entries.filter { entry in
                    (!usedOnly || usedModels.contains(PriceModelIdentity(provider: entry.provider, model: entry.model)))
                        && (query.isEmpty || provider.title.localizedCaseInsensitiveContains(query)
                            || entry.model.localizedCaseInsensitiveContains(query))
                }
                return entries.isEmpty ? nil : PriceRateGroup(entries: entries)
            }
            return groups.isEmpty ? nil : PriceProviderGroup(id: provider.id, groups: groups)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    Picker(L("price.scope"), selection: $usedOnly) {
                        Text(L("price.scope_all")).tag(false)
                        Text(L("price.scope_used")).tag(true)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                        .accessibilityIdentifier("price-catalog-scope")
                    Spacer(minLength: 12)
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(L("filter.search_models"), text: $query).textFieldStyle(.plain)
                    }.padding(.horizontal, 8).frame(width: 200, height: 28)
                        .background(WorkspaceStyle.canvas(scheme), in: RoundedRectangle(cornerRadius: 7))
                }
                Text(L("price.rate_units")).font(.caption).foregroundStyle(.secondary)
            }
            LazyVStack(alignment: .leading, spacing: 4) {
                if filtered.isEmpty { Text(L("filter.no_models")).foregroundStyle(.secondary).padding(.vertical, 16) }
                ForEach(filtered) { provider in
                    VStack(alignment: .leading, spacing: 10) {
                        let hasSchedule = provider.groups.contains { $0.entries[0].schedule == "deepseek-cn-2026-v1" }
                        Button {
                            if !expandedProviders.contains(provider.id) {
                                expandedProviders.insert(provider.id)
                            } else {
                                expandedProviders.remove(provider.id)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: !expandedProviders.contains(provider.id) ? "chevron.right" : "chevron.down")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 12)
                                BrandLabel(name: provider.id, kind: .provider, title: provider.title, size: 18).font(.headline)
                                Spacer(minLength: 0)
                            }.frame(minHeight: 32).contentShape(Rectangle())
                        }
                        .buttonStyle(WorkspaceHoverStyle())
                        .accessibilityLabel(provider.title)
                        .accessibilityValue(L(!expandedProviders.contains(provider.id) ? "state.collapsed" : "state.expanded"))
                        .accessibilityIdentifier("price-provider-" + provider.id)
                        if expandedProviders.contains(provider.id) {
                            VStack(alignment: .leading, spacing: 10) {
                                if ProviderBrand.all[provider.id]?.subscription == true {
                                    Text(L("price.subscription_rates")).font(.caption).foregroundStyle(.secondary)
                                }
                                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 0) {
                                    GridRow {
                                        Text(L("field.model")).frame(maxWidth: .infinity, alignment: .leading)
                                        if hasSchedule { Text(L("price.period")) }
                                        Text(L("token.input")).frame(width: 72, alignment: .trailing)
                                        Text(L("token.cache_read")).frame(width: 72, alignment: .trailing)
                                        Text(L("token.output")).frame(width: 72, alignment: .trailing)
                                    }.font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                                    Divider().gridCellUnsizedAxes(.horizontal)
                                    ForEach(provider.groups) { group in
                                        GridRow(alignment: .top) {
                                            VStack(alignment: .leading, spacing: 6) {
                                                ForEach(group.entries, id: \.model) { entry in
                                                    BrandLabel(name: entry.model, kind: .model, title: modelTitle(entry)).textSelection(.enabled)
                                                        .fixedSize(horizontal: false, vertical: true)
                                                }
                                            }.frame(maxWidth: .infinity, alignment: .leading)
                                            if hasSchedule {
                                                VStack(alignment: .leading, spacing: 6) {
                                                    if group.entries[0].schedule == "deepseek-cn-2026-v1" {
                                                        Text(L("price.peak"))
                                                        Text(L("price.off_peak"))
                                                    } else { Text("—") }
                                                }.foregroundStyle(.secondary)
                                            }
                                            rate(group, "input_cost_per_token")
                                            rate(group, "cache_read_input_token_cost")
                                            rate(group, "output_cost_per_token")
                                        }.font(.callout).padding(.vertical, 12)
                                        Divider().gridCellUnsizedAxes(.horizontal)
                                    }
                                }
                                .accessibilityRepresentation {
                                    VStack {
                                        ForEach(provider.groups) { group in
                                            VStack {
                                                Text(group.entries.map { modelTitle($0) }.joined(separator: ", "))
                                                Text("\(L("token.input")): \(accessibleRate(group, "input_cost_per_token"))")
                                                Text("\(L("token.cache_read")): \(accessibleRate(group, "cache_read_input_token_cost"))")
                                                Text("\(L("token.output")): \(accessibleRate(group, "output_cost_per_token"))")
                                            }.accessibilityElement(children: .combine)
                                        }
                                    }.accessibilityElement(children: .contain).accessibilityLabel(provider.title)
                                }
                                if provider.id == "deepseek" && hasSchedule {
                                    Text(L("price.deepseek_schedule")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    Link(L("price.official_page"), destination: URL(string: "https://api-docs.deepseek.com/quick_start/pricing/")!).font(.caption)
                                }
                            }.padding(.leading, 20)
                        }
                    }
                }
            }
        }
        .onChange(of: usedOnly) { _, _ in
            if !query.isEmpty { expandedProviders.formUnion(filtered.map(\.id)) }
        }
        .onChange(of: query) { _, value in
            if !value.isEmpty { expandedProviders.formUnion(filtered.map(\.id)) }
        }
    }
    private func modelTitle(_ entry: PriceCatalogEntry) -> String {
        entry.provider == "devin" && entry.model == "compactor" ? L("price.compactor_reference") : entry.model
    }
    private func rate(_ group: PriceRateGroup, _ key: String) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(rateText(group, key))
            if group.entries[0].schedule == "deepseek-cn-2026-v1" {
                Text(rateText(group, key, factor: 0.5))
            }
        }.monospacedDigit().frame(width: 72, alignment: .trailing).textSelection(.enabled)
    }
    private func accessibleRate(_ group: PriceRateGroup, _ key: String) -> String {
        guard group.entries[0].schedule == "deepseek-cn-2026-v1" else { return rateText(group, key) }
        return "\(L("price.peak")) \(rateText(group, key)), \(L("price.off_peak")) \(rateText(group, key, factor: 0.5))"
    }
    private func rateText(_ group: PriceRateGroup, _ key: String, factor: Double = 1) -> String {
        group.price(key).map {
            ($0 * 1_000_000 * factor).formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")).precision(.fractionLength(2...4)))
        } ?? L("value.unavailable")
    }
}
