// [INPUT]: Shared usage filters and the Records conversation selection.
// [OUTPUT]: Dimension controls and a title-aware conversation picker with a bounded result list.
// [POS]: Filter toolbar; the conversation lookup runs only while its popover is open.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
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
                if showsSource { recordFilters }
                Spacer(minLength: 0)
            }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) { primaryFilters; Spacer(minLength: 0) }
                if showsSource { recordFilters }
            }
        }
        .controlSize(.regular)
    }

    private var recordFilters: some View {
        HStack(spacing: 10) {
            sourcePicker
            ConversationPicker()
        }
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

private struct ConversationPicker: View {
    @Environment(UsageStore.self) private var store
    @State private var showing = false
    @State private var search = ""
    @State private var completedLookup: ConversationLookup?
    @State private var options: [UsageConversation] = []
    @State private var failed = false
    @FocusState private var searchFocused: Bool

    private var lookup: ConversationLookup {
        var filter = store.filter
        filter.offset = 0
        return ConversationLookup(filter: filter, search: search.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        let selected = store.recordConversation
        let title = selected.map(conversationName) ?? L("record.conversations_all")
        Button {
            search = ""
            completedLookup = nil
            showing = true
        } label: {
            HStack(spacing: 8) {
                if let selected { BrandIcon(name: selected.id.client, kind: .tool) }
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }.frame(width: 174)
        }
        .accessibilityLabel(L("record.conversation"))
        .accessibilityValue(title)
        .help(selected.map(conversationHelp) ?? title)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            let request = lookup
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L("record.conversation_search"), text: $search)
                        .textFieldStyle(.plain).focused($searchFocused)
                        .onSubmit {
                            if completedLookup == request, let first = options.first { select(first) }
                        }
                }.padding(14)
                Divider()
                option(nil)
                Divider()
                if completedLookup != request {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(16)
                        .accessibilityLabel(L("usage.loading"))
                } else if failed {
                    HStack {
                        Text(L("record.conversations_failed")).foregroundStyle(.secondary)
                        Button(L("action.retry")) { Task { await load(request) } }
                    }.padding(16)
                } else if options.isEmpty {
                    Text(L("record.conversations_empty")).foregroundStyle(.secondary).padding(16)
                } else if options.count <= 4 {
                    conversationRows
                } else {
                    ScrollView { conversationRows }
                        .frame(height: 300)
                }
            }
            .frame(width: 385)
            .onAppear { searchFocused = true }
            .task(id: request) { await load(request) }
        }
    }

    private var conversationRows: some View {
        LazyVStack(spacing: 2) {
            ForEach(options) { option($0) }
        }.padding(6)
    }

    private func option(_ conversation: UsageConversation?) -> some View {
        let selected = store.recordConversation?.id == conversation?.id
        return Button { select(conversation) } label: {
            HStack(spacing: 8) {
                if let conversation {
                    BrandIcon(name: conversation.id.client, kind: .tool)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(conversationName(conversation)).lineLimit(2).multilineTextAlignment(.leading)
                        Text(conversationContext(conversation))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    Text(L("record.conversations_all"))
                }
                Spacer(minLength: 4)
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(WorkspaceHoverStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(conversation.map(conversationHelp) ?? L("record.conversations_all"))
    }

    private func select(_ conversation: UsageConversation?) {
        store.selectConversation(conversation)
        showing = false
    }

    private func conversationName(_ conversation: UsageConversation) -> String {
        conversation.title ?? "\(clientName(conversation.id.client)) · \(lastActivity(conversation))"
    }

    private func conversationContext(_ conversation: UsageConversation) -> String {
        let context: [String?]
        if conversation.title != nil {
            context = [clientName(conversation.id.client), conversation.model, lastActivity(conversation)]
        } else {
            let id = conversation.id.sessionId
            let shortID = id.count > 8 ? "…\(id.suffix(8))" : id
            context = [conversation.model, shortID]
        }
        return context.compactMap { $0 }.joined(separator: " · ")
    }

    private func conversationHelp(_ conversation: UsageConversation) -> String {
        "\(conversationName(conversation))\n\(conversation.id.sessionId)"
    }

    private func lastActivity(_ conversation: UsageConversation) -> String {
        if let timestamp = conversation.lastTimestampMs {
            return TurnFormat.timestamp(Date(timeIntervalSince1970: Double(timestamp) / 1000))
        }
        return Localization.day(conversation.lastDate)
    }

    private func load(_ request: ConversationLookup) async {
        guard !Task.isCancelled, showing, lookup == request else { return }
        completedLookup = nil
        do {
            if !request.search.isEmpty { try await Task.sleep(for: .milliseconds(180)) }
            let matches = try await store.findConversations(request)
            guard !Task.isCancelled, showing, lookup == request else { return }
            options = matches
            failed = false
        } catch {
            guard !Task.isCancelled, showing, lookup == request else { return }
            options = []
            failed = true
        }
        completedLookup = request
    }
}
