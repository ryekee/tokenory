import SwiftUI

struct UsageFiltersView: View {
    @Environment(UsageStore.self) private var store
    let showsSource: Bool
    @State private var showingModels = false
    @State private var modelSearch = ""
    @FocusState private var searchFocused: Bool

    private var matchingModels: [UsageGroup] {
        (store.catalog?.models ?? []).filter {
            modelSearch.isEmpty || $0.key.localizedCaseInsensitiveContains(modelSearch)
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                primaryFilters
                if showsSource { sourcePicker }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) { primaryFilters; Spacer(minLength: 0) }
                if showsSource { sourcePicker }
            }
        }
        .controlSize(.regular)
    }

    private var primaryFilters: some View {
        @Bindable var store = store
        return Group {
            Picker(L("field.tool"), selection: Binding(
                get: { store.filter.client ?? "" },
                set: { store.filter.client = $0.isEmpty ? nil : $0; store.filter.offset = 0 }
            )) {
                Text(L("filter.tools")).tag("")
                ForEach(store.catalog?.clients ?? []) { group in
                    Label { Text(clientName(group.key)) } icon: { Brand.image(group.key, kind: .tool) }.tag(group.key)
                }
            }.labelsHidden().frame(width: 148)

            Picker(L("field.provider"), selection: Binding(
                get: { store.filter.provider ?? "" },
                set: { store.filter.provider = $0.isEmpty ? nil : $0; store.filter.offset = 0 }
            )) {
                Text(L("filter.providers")).tag("")
                ForEach(store.catalog?.providers ?? []) { group in
                    Label { Text(group.key) } icon: { Brand.image(group.key, kind: .provider) }.tag(group.key)
                }
            }.labelsHidden().frame(width: 145)

            Button { modelSearch = ""; showingModels = true } label: {
                HStack(spacing: 8) {
                    if let model = store.filter.model { BrandIcon(name: model, kind: .model) }
                    Text(store.filter.model ?? L("filter.models"))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }.frame(width: 180)
            }
            .help(store.filter.model ?? L("filter.models"))
            .accessibilityLabel(L("field.model"))
            .accessibilityValue(store.filter.model ?? L("filter.models"))
            .popover(isPresented: $showingModels, arrowEdge: .bottom) {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(L("filter.search_models"), text: $modelSearch)
                            .textFieldStyle(.plain).focused($searchFocused)
                            .onSubmit {
                                if let first = matchingModels.first {
                                    store.filter.model = first.key
                                    store.filter.offset = 0
                                    showingModels = false
                                }
                            }
                    }.padding(14)
                    Divider()
                    ScrollView {
                        VStack(spacing: 2) {
                            modelOption(nil)
                            ForEach(matchingModels) { modelOption($0.key) }
                            if matchingModels.isEmpty {
                                Text(L("filter.no_models")).foregroundStyle(.secondary).padding(16)
                            }
                        }.padding(6)
                    }.frame(maxHeight: 290)
                }
                .frame(width: 330)
                .onAppear { searchFocused = true }
            }
        }
    }

    private func modelOption(_ model: String?) -> some View {
        Button {
            store.filter.model = model
            store.filter.offset = 0
            showingModels = false
        } label: {
            HStack {
                if let model { BrandIcon(name: model, kind: .model) }
                Text(model ?? L("filter.models")).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                    .opacity(store.filter.model == model ? 1 : 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(store.filter.model == model ? Color.accentColor.opacity(0.1) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(model ?? L("filter.models"))
    }

    private var sourcePicker: some View {
        Picker(L("field.source"), selection: Binding(
            get: { store.filter.source ?? "" },
            set: { store.filter.source = $0.isEmpty ? nil : $0; store.filter.offset = 0 }
        )) {
            Text(L("filter.sources")).tag("")
            Text(L("source.local")).tag("local")
            Text("CC Switch").tag("cc-switch")
            Text("tokens.ci").tag("tokens-ci")
        }.labelsHidden().frame(width: 140)
    }
}
