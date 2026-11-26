// [INPUT]: Lazy multi-agent turn report, shared date range and local client/model selection.
// [OUTPUT]: Turn analytics with search-preserving chart selection, delayed agent labels and retryable errors.
// [POS]: Native speed analysis. The chart and list share turn selection across filters and pages.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import SwiftUI

struct TurnsView: View {
    let isActive: Bool
    let openDatePicker: () -> Void
    @Environment(UsageStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedID: String?
    @State private var order: TurnSort = .newest
    @State private var page = 0
    private enum ContentPhase: Equatable {
        case content, loading, error, empty
    }
    private var query: TurnQuery {
        TurnQuery(from: store.filter.from, to: store.filter.to, model: store.turnModel, client: store.turnClient)
    }
    var body: some View {
        let requestedQuery = isActive ? query : nil
        let waiting = isActive && (store.turnsLoading || (store.turnsQuery != requestedQuery && store.turnsError == nil))
        let hasContent = store.turnAnalytics.map { !$0.points.isEmpty } == true
            && store.turnsQuery != nil
            && (requestedQuery == nil || store.turnsQuery == requestedQuery || waiting)
        let phase: ContentPhase = hasContent ? .content : waiting ? .loading : store.turnsError != nil ? .error : .empty
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                WorkspaceDropdown(
                    label: L("field.tool"),
                    selection: Binding(
                        get: { store.turnClient ?? "" },
                        set: { store.turnClient = $0.isEmpty ? nil : $0; store.turnModel = nil }
                    ),
                    options: [""] + (store.turnAnalytics?.capabilities.filter(\.supported).map(\.client) ?? ["codex"]),
                    width: 124,
                    title: { $0.isEmpty ? L("filter.tools") : clientName($0) },
                    brand: { $0.isEmpty ? nil : ($0, .tool) }
                )
                WorkspaceModelDropdown(
                    selection: Binding(
                        get: { store.turnModel ?? "" },
                        set: { store.turnModel = $0.isEmpty ? nil : $0 }
                    ),
                    models: Array(Set((store.turnAnalytics?.models ?? []) + [store.turnModel].compactMap { $0 }))
                )
                Spacer(minLength: 0)
                if let capabilities = store.turnAnalytics?.capabilities, !capabilities.isEmpty {
                    WorkspaceInfoPopover(title: L("turns.support")) {
                        AgentCoveragePopover(capabilities: capabilities)
                    }
                }
                ZStack {
                    if waiting && store.turnAnalytics != nil { ProgressView().controlSize(.small) }
                }.frame(width: 16, height: 16)
            }.padding(.horizontal, 22).padding(.vertical, 14)
            VStack(spacing: 0) {
                if let data = store.turnAnalytics, let displayed = store.turnsQuery,
                   requestedQuery == nil || displayed == requestedQuery || waiting {
                    if let error = store.turnsError {
                        errorCard(error).padding(.bottom, 12)
                            .transition(.opacity)
                    }
                    TurnsContent(data: data, range: DashboardDateSpan(from: displayed.from, to: displayed.to),
                                 isActive: isActive, selectedID: $selectedID, order: $order, page: $page)
                        .transition(.opacity)
                } else if waiting {
                    ProgressView(L("usage.loading_stats")).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                } else if let error = store.turnsError {
                    ScrollView {
                        errorCard(error).padding(.bottom, 22)
                    }
                    .transition(.opacity)
                } else {
                    ContentUnavailableView {
                        Label(L("turns.empty"), systemImage: "stopwatch")
                    } actions: {
                        if query.client != nil || query.model != nil {
                            Button(L("record.clear_filters")) {
                                store.turnClient = nil
                                store.turnModel = nil
                            }
                        } else {
                            Button(L("record.change_dates"), action: openDatePicker)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                }
            }
            .animation(DashboardMotion.animation(DashboardMotion.load, reduceMotion: reduceMotion), value: phase)
            .animation(DashboardMotion.animation(DashboardMotion.panel, reduceMotion: reduceMotion), value: store.turnsError != nil)
        }
        .task(id: requestedQuery) {
            if let requestedQuery, !Task.isCancelled { await store.loadAgentTurns(requestedQuery) }
        }
    }

    private func errorCard(_ detail: String) -> some View {
        WorkspacePanel(surface: WorkspaceStyle.warningSurface) {
            WorkspaceErrorMessage(title: L("turns.load_failed"), detail: detail) {
                Button(L("turns.retry")) { Task { await store.loadAgentTurns(query, force: true) } }
            }
        }
        .padding(.horizontal, 22)
    }
}

private struct AgentCoveragePopover: View {
    let capabilities: [TurnCapability]
    @State private var hover = HoverDwell<String>()
    @State private var sample: (client: String, pointer: CGPoint, icon: CGRect)?
    @State private var measuredSizes: [String: CGSize] = [:]

    private func tooltipSize(for client: String) -> CGSize {
        if let measured = measuredSizes[client] { return measured }
        return CGSize(width: ceil(CursorTooltipLayout.textWidth(clientName(client))) + 20, height: 26)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach([true, false], id: \.self) { supported in
                let group = capabilities.filter { $0.supported == supported }
                if !group.isEmpty {
                    capabilityGroup(group, supported: supported)
                }
            }
        }
        .padding(18).frame(width: 340, alignment: .leading)
        .coordinateSpace(name: "agentCoverage")
        .overlay(alignment: .topLeading) {
            GeometryReader { geometry in
                if let hovered = sample, hovered.client == hover.readoutTarget {
                    let size = tooltipSize(for: hovered.client)
                    let above = min(hovered.pointer.y - 10, hovered.icon.minY - 4) - size.height
                    let below = max(hovered.pointer.y + 12, hovered.icon.maxY + 4)
                    let y = above >= 8 ? above : below
                    Text(clientName(hovered.client))
                        .font(.caption).foregroundStyle(.primary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.12)) }
                        .shadow(color: .black.opacity(0.14), radius: 5, y: 2)
                        .fixedSize()
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { measuredSizes[hovered.client] = $0 }
                        .offset(x: max(8, min(hovered.pointer.x + 10, geometry.size.width - size.width - 8)), y: max(8, y))
                        .accessibilityHidden(true)
                }
            }.allowsHitTesting(false)
        }
        .onDisappear { hover.update(nil) }
    }

    private func capabilityGroup(_ group: [TurnCapability], supported: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L(supported ? "turns.coverage.supported" : "turns.coverage.unsupported"))
                .font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32)), count: 7), alignment: .leading, spacing: 12) {
                ForEach(group, id: \.client) { capability in
                    GeometryReader { icon in
                        BrandIcon(name: capability.client, kind: .tool, size: 24)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    let frame = icon.frame(in: .named("agentCoverage"))
                                    sample = (capability.client, CGPoint(x: frame.minX + location.x, y: frame.minY + location.y), frame)
                                    hover.update(capability.client)
                                case .ended:
                                    if sample?.client == capability.client {
                                        sample = nil
                                        hover.update(nil)
                                    }
                                }
                            }
                    }
                    .frame(width: 32, height: 32)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(clientName(capability.client))
                }
            }
        }
    }
}

private struct TurnsContent: View {
    let data: TurnPresentation
    let range: DashboardDateSpan
    let isActive: Bool
    @Binding var selectedID: String?
    @Binding var order: TurnSort
    @Binding var page: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedBucketStart: Date?
    @State private var chartTurnID: String?
    @State private var search = ""
    private let pageSize = 6
    private let rowHeight: CGFloat = 52

    private var sortedTurns: [AgentTurn] {
        data.sorted(by: order, in: selectedBucket, search: search)
    }

    private var selectedBucket: TurnSpeedBucket? {
        selectedBucketStart.flatMap { data.speedTimeline?.bucket(at: $0) }
    }

    var body: some View {
        let sorted = sortedTurns
        let pageCount = max(1, (sorted.count + pageSize - 1) / pageSize)
        let currentPage = min(page, pageCount - 1)
        let visible = sorted.dropFirst(currentPage * pageSize).prefix(pageSize)
        let selected = chartTurnID.flatMap { id in data.points.first { $0.id == id } }
            ?? visible.first { $0.id == selectedID }
            ?? visible.first
        return GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    WorkspacePanel { summary }
                    WorkspacePanel {
                        if data.speedTimeline?.buckets.isEmpty == false {
                            TurnSpeedChart(data: data, range: range, animateRangeChanges: isActive,
                                           selected: selected, selectedBucketStart: selectedBucket?.start,
                                           hasChartSelection: chartTurnID != nil || selectedBucket != nil,
                                           onSelect: select, onClearSelection: clearChartSelection)
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text(L("turns.trend")).font(.headline).foregroundStyle(WorkspaceStyle.text)
                                        .accessibilityAddTraits(.isHeader)
                                    Spacer()
                                    Text("tokens/s").font(.caption).foregroundStyle(WorkspaceStyle.subtext)
                                }
                                Color.clear.frame(height: 210)
                            }
                        }
                    }
                    let wide = geometry.size.width - 44 >= 720
                    let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 18)) : AnyLayout(VStackLayout(spacing: 18))
                    layout {
                        turnList(count: sorted.count, visible: visible, selected: selected,
                                 page: currentPage, pageCount: pageCount, wide: wide) { next in
                            page = next
                            chartTurnID = nil
                            selectedID = sorted[next * pageSize].id
                        }
                        if let selected {
                            WorkspacePanel {
                                TurnDetail(turn: selected, title: data.title(for: selected))
                                    .frame(maxWidth: .infinity, maxHeight: wide ? .infinity : nil, alignment: .topLeading)
                            }
                        } else if wide {
                            Color.clear.frame(maxWidth: .infinity).accessibilityHidden(true)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }.padding(.horizontal, 22).padding(.bottom, 22)
            }
        }
        .onChange(of: order) { _, _ in
            showPage(containing: selectedID, in: sorted)
        }
        .onChange(of: range) { _, _ in
            selectedBucketStart = nil
            chartTurnID = nil
            showPage(containing: selectedID, in: data.sorted(by: order, search: search))
        }
        .onChange(of: sorted.map(\.id), initial: true) { _, _ in
            if selectedBucket == nil { selectedBucketStart = nil }
            if let index = sorted.firstIndex(where: { $0.id == selectedID }) {
                page = index / pageSize
            } else {
                selectedID = nil
                page = min(page, max(0, (sorted.count - 1) / pageSize))
            }
        }
        .cursorTooltipSurface()
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 18) {
            let speedText = data.averageSpeed.map { (data.containsEstimates ? "≈ " : "") + TurnFormat.number($0) } ?? "—"
            metric("turns.average_speed", speedText,
                   amount: data.averageSpeed, unit: data.averageSpeed == nil ? "" : "tokens/s")
            Divider().frame(height: 58)
            metric("turns.average_ttft",
                   data.averageTTFTSeconds.map(TurnFormat.number) ?? "—",
                   amount: data.averageTTFTSeconds,
                   unit: data.averageTTFTSeconds == nil ? "" : L("turns.seconds_unit"))
            Divider().frame(height: 58)
            metric("turns.average_reasoning",
                   data.averageReasoning.map { $0.formatted(.number.precision(.fractionLength(0)).locale(Localization.locale)) } ?? "—",
                   amount: data.averageReasoning,
                   unit: data.averageReasoning == nil ? "" : L("turns.tokens_per_turn"))
        }
    }
    private func metric(_ key: String, _ value: String, amount: Double?, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L(key)).font(.subheadline).foregroundStyle(WorkspaceStyle.subtext).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                DashboardRollingValue(text: value, value: amount, range: isActive ? range : nil, style: .displayNumber(32), themed: true)
                if !unit.isEmpty {
                    Text(unit).font(.caption).foregroundStyle(WorkspaceStyle.subtext)
                }
            }
            .lineLimit(1).minimumScaleFactor(0.75).textSelection(.enabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(unit.isEmpty ? value : "\(value) \(unit)")
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }

    private func turnList(count: Int, visible: ArraySlice<AgentTurn>, selected: AgentTurn?,
                          page: Int, pageCount: Int, wide: Bool, changePage: @escaping (Int) -> Void) -> some View {
        WorkspacePanel {
            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        listTitle(count: count).frame(maxWidth: .infinity, alignment: .leading)
                        sortPicker.fixedSize()
                    }
                    rowColumns {
                        Text(L("turns.project")); Text(L("turns.duration")); Text(L("token.reasoning")); Text("tokens/s")
                    }.font(.caption2).foregroundStyle(WorkspaceStyle.subtext).padding(.horizontal, 5)
                    Divider()
                }
                VStack(spacing: 0) {
                    if visible.isEmpty, !search.isEmpty {
                        HStack {
                            Text(L("turns.search_empty")).font(.callout).foregroundStyle(WorkspaceStyle.subtext)
                            Spacer(minLength: 8)
                            Button(L("turns.clear_search")) { updateSearch("") }.controlSize(.small)
                        }.padding(.vertical, 18)
                    }
                    ForEach(visible) { turn in
                        Button {
                            chartTurnID = nil
                            selectedID = turn.id
                        } label: {
                            rowColumns {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 5) {
                                        BrandIcon(name: turn.client, kind: .tool)
                                        Text(turn.project).fontWeight(.medium).foregroundStyle(WorkspaceStyle.text).lineLimit(1).truncationMode(.middle)
                                        if let mode = turn.inferenceSpeed, mode.isFast {
                                            FastModeMark(helpText: mode.fastHelp)
                                        }
                                    }
                                    let subtitle = data.matchingSubtitle(for: turn, search: search.trimmingCharacters(in: .whitespacesAndNewlines))
                                        ?? TurnFormat.timestamp(turn.start)
                                    Text(subtitle).font(.caption2).foregroundStyle(WorkspaceStyle.subtext)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Text((turn.durationEstimated ? "≈ " : "") + TurnFormat.clockDuration(turn.durationMs)).foregroundStyle(WorkspaceStyle.text)
                                Text(turn.reasoningTokens.map { compactTokens($0) } ?? "—").foregroundStyle(WorkspaceStyle.text)
                                Text((turn.durationEstimated ? "≈ " : "") + TurnFormat.number(turn.speed)).foregroundStyle(WorkspaceStyle.text)
                            }
                            .font(.callout).monospacedDigit().padding(.horizontal, 5)
                            .frame(height: rowHeight)
                            .contentShape(Rectangle())
                            .background(selected?.id == turn.id ? WorkspaceStyle.selection.opacity(0.1) : .clear)
                        }
                        .buttonStyle(WorkspaceHoverStyle())
                        .overlay(alignment: .bottom) { Divider().opacity(0.5).allowsHitTesting(false) }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(selected?.id == turn.id ? [.isSelected] : [])
                    }
                }
                .frame(height: CGFloat(pageSize) * rowHeight, alignment: .top)
                Spacer(minLength: 12)
                if pageCount > 1 {
                    HStack {
                        Button { changePage(page - 1) } label: { Image(systemName: "chevron.left") }
                            .disabled(page == 0).accessibilityLabel(L("action.previous"))
                        Spacer()
                        Text(LF("turns.page", page + 1, pageCount)).font(.caption).monospacedDigit()
                            .contentTransition(reduceMotion ? .identity : .numericText())
                            .animation(DashboardMotion.animation(DashboardMotion.pagination, reduceMotion: reduceMotion), value: page)
                        Spacer()
                        Button { changePage(page + 1) } label: { Image(systemName: "chevron.right") }
                            .disabled(page + 1 >= pageCount).accessibilityLabel(L("action.next"))
                    }
                }
            }
            .frame(maxHeight: wide ? .infinity : nil, alignment: .top)
        }
    }
    @ViewBuilder
    private func listTitle(count: Int) -> some View {
        if let selectedBucket, let granularity = data.speedTimeline?.granularity {
            HStack(spacing: 8) {
                Text("\(TurnFormat.speedBucket(selectedBucket, granularity: granularity)) · \(LF("turns.count", count))").font(.headline)
                Button(L("turns.show_all"), action: clearBucket).controlSize(.small)
            }
        } else {
            DashboardRollingValue(text: LF("turns.count", count), value: Double(count),
                                  range: isActive ? range : nil, style: .headline)
        }
    }
    private var sortPicker: some View {
        TurnListPicker(order: $order, search: Binding(get: { search }, set: updateSearch))
    }
    private func updateSearch(_ value: String) {
        search = value
        page = 0
        selectedID = nil
        chartTurnID = nil
    }
    private func rowColumns<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Group(subviews: content()) { cells in
                cells[0].frame(maxWidth: .infinity, alignment: .leading)
                cells[1].frame(width: 60, alignment: .trailing)
                cells[2].frame(width: 58, alignment: .trailing)
                cells[3].frame(width: 48, alignment: .trailing)
            }
        }.lineLimit(1).minimumScaleFactor(0.85)
    }
    private func showPage(containing id: String?, in turns: [AgentTurn]) {
        page = turns.firstIndex(where: { $0.id == id }).map { $0 / pageSize } ?? 0
    }

    private func clearBucket() {
        selectedBucketStart = nil
        chartTurnID = nil
        showPage(containing: selectedID, in: sortedTurns)
    }

    private func clearChartSelection() {
        if chartTurnID == nil {
            clearBucket()
        } else {
            chartTurnID = nil
        }
    }

    private func select(_ turn: AgentTurn, bucketStart: Date?) {
        if let bucketStart {
            if selectedBucket?.start == bucketStart {
                clearBucket()
                return
            }
            selectedBucketStart = bucketStart
            chartTurnID = nil
            let matches = sortedTurns
            selectedID = matches.first { $0.id == turn.id }?.id
                ?? matches.min { abs($0.speed - turn.speed) < abs($1.speed - turn.speed) }?.id
            showPage(containing: selectedID, in: matches)
        } else {
            chartTurnID = chartTurnID == turn.id ? nil : turn.id
        }
    }
}

private struct TurnListPicker: View {
    @Binding var order: TurnSort
    @Binding var search: String
    @State private var showing = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        let title = L("turns.search_sort")
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        WorkspaceDropdownTrigger(label: title, value: query.isEmpty ? title : query,
                                 width: max(105, WorkspaceDropdownTrigger.fittingWidth(for: [title]))) {
            showing.toggle()
        }
        .controlSize(.small)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                WorkspaceDropdownSearchField(prompt: L("turns.search_prompt"), text: $search, focus: $searchFocused) {
                    showing = false
                }
                VStack(spacing: 1) {
                    ForEach(TurnSort.allCases, id: \.self) { option in
                        WorkspaceDropdownRow(selected: option == order) {
                            order = option
                            showing = false
                        } content: { Text(option.title) }
                    }
                }.padding(.horizontal, 6).padding(.bottom, 6)
            }
            .frame(width: 280)
            .onAppear { searchFocused = true }
        }
    }
}

private struct TurnDetail: View {
    let turn: AgentTurn
    let title: String?

    private var basis: String {
        turn.durationEstimated ? L("turns.basis_summary") + " " + L("turns.basis_estimate") : L("turns.basis_summary")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(TurnFormat.timestamp(turn.start)).font(.caption).foregroundStyle(WorkspaceStyle.subtext)
                    Spacer()
                    WorkspaceInfoPopover(title: L("turns.basis")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(basis)
                            LabeledContent(L("turns.session"), value: turn.sessionId)
                            LabeledContent(L("turns.turn"), value: turn.turnId)
                        }.font(.caption).textSelection(.enabled).padding(14).frame(width: 320)
                    }.accessibilityHint(basis)
                }
                Text(turn.project).font(.title3.weight(.semibold)).foregroundStyle(WorkspaceStyle.text).textSelection(.enabled)
                if let title {
                    Text(title)
                        .font(.callout).foregroundStyle(WorkspaceStyle.subtext).lineLimit(2)
                        .textSelection(.enabled)
                        .accessibilityLabel(L("record.conversation"))
                        .accessibilityValue(title)
                }
                HStack(spacing: 12) {
                    BrandLabel(name: turn.client, kind: .tool, title: clientName(turn.client))
                        .fixedSize()
                    BrandLabel(name: turn.model, kind: .model)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    if let mode = turn.inferenceSpeed, mode.isFast {
                        FastModeMark(title: L("fast.title"), helpText: mode.fastHelp)
                    }
                    if let effort = turn.effort {
                        Text(effort).foregroundStyle(WorkspaceStyle.subtext).fixedSize()
                    }
                }.font(.caption)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(L("turns.duration")).font(.caption).foregroundStyle(WorkspaceStyle.subtext)
                Text((turn.durationEstimated ? "≈ " : "") + TurnFormat.duration(turn.durationMs))
                    .font(DisplayNumberFont.font(size: 32)).foregroundStyle(WorkspaceStyle.text)
            }
            if let wait = turn.toolWaitMs {
                VStack(spacing: 8) {
                    GeometryReader { geometry in
                        HStack(spacing: 0) {
                            Rectangle().fill(WorkspaceStyle.toolWait.opacity(0.8)).frame(width: geometry.size.width * Double(wait) / Double(turn.durationMs))
                            Rectangle().fill(WorkspaceStyle.otherTurnTime.opacity(0.8))
                        }.clipShape(Capsule())
                    }.frame(height: 7).accessibilityHidden(true)
                    ViewThatFits(in: .horizontal) {
                        HStack { waitLabel(wait); Spacer(); remainingLabel(wait) }
                        VStack(alignment: .leading, spacing: 4) { waitLabel(wait); remainingLabel(wait) }
                    }.font(.caption2).foregroundStyle(WorkspaceStyle.subtext)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                detailMetric("turns.speed", value: (turn.durationEstimated ? "≈ " : "") + TurnFormat.number(turn.speed), unit: "tokens/s")
                detailMetric("token.reasoning", value: turn.reasoningTokens.map { $0.formatted(.number.locale(Localization.locale)) } ?? "—")
                detailMetric("turns.ttft", value: TurnFormat.number(turn.ttftMs.map { Double($0) / 1000 }), unit: L("turns.seconds_unit"))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(LF("turns.responses_tools", turn.requests.map { $0.formatted(.number.locale(Localization.locale)) } ?? "—", turn.toolCalls.map { $0.formatted(.number.locale(Localization.locale)) } ?? "—")).font(.caption).foregroundStyle(WorkspaceStyle.subtext)
                HStack { Text(L("turns.generated")).foregroundStyle(WorkspaceStyle.subtext); Spacer(); Text(turn.generatedTokens.formatted(.number.locale(Localization.locale))).foregroundStyle(WorkspaceStyle.text).monospacedDigit() }.font(.caption)
                if let reasoning = turn.reasoningTokens {
                    GeometryReader { geometry in
                        HStack(spacing: 0) {
                            Rectangle().fill(WorkspaceStyle.reasoningTokens.opacity(0.8))
                                .frame(width: geometry.size.width * (turn.reasoningShare ?? 0))
                            Rectangle().fill(WorkspaceStyle.outputTokens.opacity(0.8))
                        }.clipShape(Capsule())
                    }.frame(height: 5).accessibilityHidden(true)
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        mixLabel("token.reasoning", value: reasoning, color: WorkspaceStyle.reasoningTokens)
                        Spacer(minLength: 0)
                        mixLabel("turns.other_output", value: turn.generatedTokens - reasoning, color: WorkspaceStyle.outputTokens)
                    }
                }
            }
            .padding(.top, 6)
        }
    }
    private func detailMetric(_ key: String, value: String, unit: String = "") -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L(key)).font(.caption).foregroundStyle(WorkspaceStyle.subtext).fixedSize(horizontal: false, vertical: true)
            TurnMetricValue(value: value, unit: unit, size: 24)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
    private func mixLabel(_ key: String, value: Int64, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5).accessibilityHidden(true)
            Text(L(key)).foregroundStyle(WorkspaceStyle.subtext)
            Text(value.formatted(.number.locale(Localization.locale))).foregroundStyle(WorkspaceStyle.text).monospacedDigit()
        }.font(.caption2).accessibilityElement(children: .combine)
    }
    private func waitLabel(_ ms: Int64) -> some View {
        HStack(spacing: 4) {
            Circle().fill(WorkspaceStyle.toolWait).frame(width: 5, height: 5).accessibilityHidden(true)
            Text(LF("turns.wait_value", TurnFormat.duration(ms)))
        }
    }
    private func remainingLabel(_ ms: Int64) -> some View {
        HStack(spacing: 4) {
            Circle().fill(WorkspaceStyle.otherTurnTime).frame(width: 5, height: 5).accessibilityHidden(true)
            Text(LF("turns.remaining_value", TurnFormat.duration(turn.durationMs - ms)))
        }
    }
}

private struct TurnMetricValue: View {
    let value: String
    let unit: String
    let size: CGFloat
    var body: some View {
        Text("\(Text(value).font(DisplayNumberFont.font(size: size)).foregroundStyle(WorkspaceStyle.text))\(Text(unit.isEmpty ? "" : " " + unit).font(.caption).foregroundStyle(WorkspaceStyle.subtext))")
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75).textSelection(.enabled)
    }
}
