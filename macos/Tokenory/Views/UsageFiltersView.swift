// [INPUT]: Shared usage filters and the Records conversation selection.
// [OUTPUT]: Dimension controls and a title-aware conversation picker with a bounded result list.
// [POS]: Filter toolbar; the conversation lookup runs only while its popover is open.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import SwiftUI

struct UsageFiltersView: View {
    @Environment(UsageStore.self) private var store
    let showsSource: Bool

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
            WorkspaceDropdown(
                label: L("field.source"), selection: dimension(\.source),
                options: ["", "local", "cc-switch", "tokens-ci"], width: 116,
                title: { source in
                    switch source {
                    case "local": L("source.local")
                    case "cc-switch": "CC Switch"
                    case "tokens-ci": "tokens.ci"
                    default: L("filter.sources")
                    }
                }
            )
            ConversationPicker()
        }
    }

    private var primaryFilters: some View {
        Group {
            WorkspaceDropdown(
                label: L("field.tool"), selection: dimension(\.client),
                options: [""] + (store.catalog?.clients.map(\.key) ?? []), width: 124,
                title: { $0.isEmpty ? L("filter.tools") : clientName($0) },
                brand: { $0.isEmpty ? nil : ($0, .tool) }
            )
            WorkspaceDropdown(
                label: L("field.provider"), selection: dimension(\.provider),
                options: [""] + (store.catalog?.providers.map(\.key) ?? []), width: 121,
                title: { $0.isEmpty ? L("filter.providers") : $0 },
                brand: { $0.isEmpty ? nil : ($0, .provider) }
            )
            WorkspaceModelDropdown(selection: dimension(\.model), models: store.catalog?.models.map(\.key) ?? [])
        }
    }

    private func dimension(_ keyPath: WritableKeyPath<UsageFilter, String?>) -> Binding<String> {
        Binding(
            get: { store.filter[keyPath: keyPath] ?? "" },
            set: { value in
                store.filter[keyPath: keyPath] = value.isEmpty ? nil : value
                store.filter.offset = 0
            }
        )
    }
}

struct WorkspaceModelDropdown: View {
    @Binding var selection: String
    let models: [String]

    var body: some View {
        WorkspaceDropdown(
            label: L("field.model"), selection: $selection, options: models, width: 180, popoverWidth: 330,
            search: .init(prompt: L("filter.search_models"), noResults: L("filter.no_models"), clearValue: ""),
            title: { $0.isEmpty ? L("filter.models") : $0 },
            brand: { $0.isEmpty ? nil : ($0, .model) }
        )
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
        WorkspaceDropdownTrigger(
            label: L("record.conversation"), value: title, width: 174,
            brand: selected.map { ($0.id.client, .tool) }, help: selected.map(conversationHelp)
        ) {
            search = ""
            completedLookup = nil
            showing = true
        }
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            let request = lookup
            VStack(spacing: 0) {
                WorkspaceDropdownSearchField(prompt: L("record.conversation_search"), text: $search, focus: $searchFocused) {
                    if completedLookup == request, let first = options.first { select(first) }
                }
                Divider()
                option(nil).padding(6)
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
        return WorkspaceDropdownRow(selected: selected, action: { select(conversation) }) {
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
        }
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
