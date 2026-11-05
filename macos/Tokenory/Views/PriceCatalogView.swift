import SwiftUI

struct PriceCatalogView: View {
    let providers: [PriceProviderGroup]
    @State private var query = ""
    @Environment(\.colorScheme) private var scheme

    private var filtered: [PriceProviderGroup] {
        guard !query.isEmpty else { return providers }
        return providers.compactMap { provider in
            if provider.title.localizedCaseInsensitiveContains(query) { return provider }
            let groups = provider.groups.compactMap { group -> PriceRateGroup? in
                let entries = group.entries.filter { $0.model.localizedCaseInsensitiveContains(query) }
                return entries.isEmpty ? nil : PriceRateGroup(entries: entries)
            }
            return groups.isEmpty ? nil : PriceProviderGroup(id: provider.id, groups: groups)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L("price.rate_units")).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L("filter.search_models"), text: $query).textFieldStyle(.plain)
                }.padding(8).frame(width: 200)
                    .background(WorkspaceStyle.canvas(scheme), in: RoundedRectangle(cornerRadius: 7))
            }
            if filtered.isEmpty { Text(L("filter.no_models")).foregroundStyle(.secondary).padding(.vertical, 16) }
            ForEach(filtered) { provider in
                VStack(alignment: .leading, spacing: 10) {
                    BrandLabel(name: provider.id, kind: .provider, title: provider.title, size: 18).font(.headline).padding(.top, 4)
                    Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 0) {
                        GridRow {
                            Text(L("field.model")).frame(maxWidth: .infinity, alignment: .leading)
                            Text(L("token.input")).frame(width: 72, alignment: .trailing)
                            Text(L("token.cache_read")).frame(width: 72, alignment: .trailing)
                            Text(L("token.output")).frame(width: 72, alignment: .trailing)
                        }.font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(provider.groups) { group in
                            GridRow(alignment: .top) {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(group.entries, id: \.model) { entry in
                                        BrandLabel(name: entry.model, kind: .model).textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
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
                                    Text(group.entries.map(\.model).joined(separator: ", "))
                                    Text("\(L("token.input")): \(rateText(group, "input_cost_per_token"))")
                                    Text("\(L("token.cache_read")): \(rateText(group, "cache_read_input_token_cost"))")
                                    Text("\(L("token.output")): \(rateText(group, "output_cost_per_token"))")
                                }.accessibilityElement(children: .combine)
                            }
                        }.accessibilityElement(children: .contain).accessibilityLabel(provider.title)
                    }
                }
            }
        }
    }
    private func rate(_ group: PriceRateGroup, _ key: String) -> some View {
        Text(rateText(group, key))
            .monospacedDigit().frame(width: 72, alignment: .trailing)
            .textSelection(.enabled)
    }
    private func rateText(_ group: PriceRateGroup, _ key: String) -> String {
        group.price(key).map { usd($0 * 1_000_000) } ?? L("value.unavailable")
    }
}
