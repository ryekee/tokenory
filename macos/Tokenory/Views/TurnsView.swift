// [INPUT]: Lazy multi-agent turn report, shared date range and local client/model selection.
// [OUTPUT]: Turn analytics with six-row pages, project/title/ID search and selected-turn metrics.
// [POS]: Native speed analysis. The chart and list share turn selection across filters and pages.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import SwiftUI

struct TurnsView: View {
    let isActive: Bool
    let openDatePicker: () -> Void
    @Environment(UsageStore.self) private var store
    @State private var selectedID: String?
    @State private var order: TurnSort = .newest
    @State private var page = 0
    private var query: TurnQuery {
        TurnQuery(from: store.filter.from, to: store.filter.to, model: store.turnModel, client: store.turnClient)
    }
    var body: some View {
        let requestedQuery = isActive ? query : nil
        let waiting = isActive && (store.turnsLoading || (store.turnsQuery != requestedQuery && store.turnsError == nil))
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
                ).help(L("turns.scope"))
                WorkspaceModelDropdown(
                    selection: Binding(
                        get: { store.turnModel ?? "" },
                        set: { store.turnModel = $0.isEmpty ? nil : $0 }
                    ),
                    models: Array(Set((store.turnAnalytics?.models ?? []) + [store.turnModel].compactMap { $0 }))
                )
                Spacer(minLength: 0)
                WorkspaceInfoPopover(title: L("turns.support")) {
                    AgentCoveragePopover(capabilities: store.turnAnalytics?.capabilities ?? [])
                }
                ZStack {
                    if waiting && store.turnAnalytics != nil { ProgressView().controlSize(.small) }
                }.frame(width: 16, height: 16)
            }.padding(.horizontal, 22).padding(.vertical, 14)
            if let data = store.turnAnalytics, !data.points.isEmpty, let displayed = store.turnsQuery,
               requestedQuery == nil || displayed == requestedQuery || waiting {
                if let error = store.turnsError {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("turns.load_failed"))
                            DisclosureGroup(L("error.details")) { Text(error).textSelection(.enabled) }
                        }
                        Spacer()
                        retryButton
                    }.font(.caption).padding(.horizontal, 22).padding(.bottom, 12)
                }
                TurnsContent(data: data, range: DashboardDateSpan(from: displayed.from, to: displayed.to),
                             isActive: isActive, selectedID: $selectedID, order: $order, page: $page)
            } else if waiting {
                ProgressView(L("usage.loading_stats")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.turnsError {
                ContentUnavailableView {
                    Label(L("turns.load_failed"), systemImage: "exclamationmark.circle")
                } description: {
                    Text(error).textSelection(.enabled)
                } actions: {
                    retryButton
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            }
        }
        .task(id: requestedQuery) {
            if let requestedQuery, !Task.isCancelled { await store.loadAgentTurns(requestedQuery) }
        }
    }

    private var retryButton: some View {
        Button(L("turns.retry")) { Task { await store.loadAgentTurns(query, force: true) } }
    }
}

private struct AgentCoveragePopover: View {
    let capabilities: [TurnCapability]
    @State private var hovered: (client: String, pointer: CGPoint, icon: CGRect)?
    @State private var tooltipSize = CGSize(width: 160, height: 30)

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach([true, false], id: \.self) { supported in
                VStack(alignment: .leading, spacing: 12) {
                    Text(L(supported ? "turns.coverage.supported" : "turns.coverage.unsupported"))
                        .font(.headline)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(32)), count: 7), alignment: .leading, spacing: 12) {
                        ForEach(capabilities.filter { $0.supported == supported }, id: \.client) { capability in
                            GeometryReader { icon in
                                BrandIcon(name: capability.client, kind: .tool, size: 24)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .contentShape(Rectangle())
                                    .onContinuousHover { phase in
                                        switch phase {
                                        case .active(let location):
                                            let frame = icon.frame(in: .named("agentCoverage"))
                                            hovered = (capability.client, CGPoint(x: frame.minX + location.x, y: frame.minY + location.y), frame)
                                        case .ended:
                                            if hovered?.client == capability.client { hovered = nil }
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
        .padding(18).frame(width: 340, alignment: .leading)
        .coordinateSpace(name: "agentCoverage")
        .overlay(alignment: .topLeading) {
            GeometryReader { geometry in
                if let hovered {
                    // Place the label just outside the actual icon boundary,
                    // rather than adding a full icon height to the cursor.
                    let above = min(hovered.pointer.y - 10, hovered.icon.minY - 4) - tooltipSize.height
                    let below = max(hovered.pointer.y + 12, hovered.icon.maxY + 4)
                    let y = above >= 8 ? above : below
                    Text(clientName(hovered.client))
                        .font(.caption).foregroundStyle(.primary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.12)) }
                        .shadow(color: .black.opacity(0.14), radius: 5, y: 2)
                        .fixedSize()
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { tooltipSize = $0 }
                        .offset(x: max(8, min(hovered.pointer.x + 10, geometry.size.width - tooltipSize.width - 8)), y: max(8, y))
                        .accessibilityHidden(true)
                }
            }.allowsHitTesting(false)
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
    @State private var selectedBucketStart: Date?
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
        let selected = visible.first { $0.id == selectedID } ?? visible.first
        return GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    WorkspacePanel { summary }
                    if data.speedTimeline?.buckets.isEmpty == false {
                        WorkspacePanel {
                            TurnSpeedChart(data: data, range: range, animateRangeChanges: isActive,
                                           selected: selected, selectedBucketStart: selectedBucket?.start, onSelect: select)
                        }
                    }
                    let wide = geometry.size.width - 44 >= 720
                    let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 18)) : AnyLayout(VStackLayout(spacing: 18))
                    layout {
                        turnList(count: sorted.count, visible: visible, selected: selected,
                                 page: currentPage, pageCount: pageCount, wide: wide) { next in
                            page = next
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
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 18) {
            metric("turns.average_speed", (data.containsEstimates ? "≈ " : "") + TurnFormat.number(data.averageSpeed),
                   amount: data.averageSpeed, unit: "tokens/s", help: L("turns.average_speed_help"))
            Divider().frame(height: 58)
            metric("turns.average_ttft", TurnFormat.number(data.averageTTFTSeconds), amount: data.averageTTFTSeconds, unit: L("turns.seconds_unit"),
                   help: LF("turns.average_ttft_help", data.ttftCoverage, data.points.count))
            Divider().frame(height: 58)
            metric("turns.average_reasoning", data.averageReasoning.map { $0.formatted(.number.precision(.fractionLength(0)).locale(Localization.locale)) } ?? "—",
                   amount: data.averageReasoning, unit: L("turns.tokens_per_turn"),
                   help: LF("turns.average_reasoning_help", data.reasoningCoverage, data.points.count))
        }
    }
    private func metric(_ key: String, _ value: String, amount: Double?, unit: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L(key)).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                DashboardRollingValue(text: value, value: amount, range: isActive ? range : nil, style: .displayNumber(32))
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            .lineLimit(1).minimumScaleFactor(0.75).textSelection(.enabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(unit.isEmpty ? value : "\(value) \(unit)")
        }.frame(maxWidth: .infinity, alignment: .leading).help(help).accessibilityElement(children: .combine)
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
                    }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 5)
                    Divider()
                }
                VStack(spacing: 0) {
                    if visible.isEmpty {
                        Text(L("turns.search_empty")).font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 18)
                    }
                    ForEach(visible) { turn in
                        Button { selectedID = turn.id } label: {
                            rowColumns {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 5) {
                                        BrandIcon(name: turn.client, kind: .tool).help(clientName(turn.client))
                                        Text(turn.project).fontWeight(.medium).lineLimit(1).truncationMode(.middle).help(turn.project)
                                        if let mode = turn.inferenceSpeed, mode.isFast {
                                            FastModeMark(helpText: mode.fastHelp)
                                        }
                                    }
                                    let subtitle = data.matchingSubtitle(for: turn, search: search.trimmingCharacters(in: .whitespacesAndNewlines))
                                        ?? TurnFormat.timestamp(turn.start)
                                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle).help(subtitle)
                                }
                                Text((turn.durationEstimated ? "≈ " : "") + TurnFormat.clockDuration(turn.durationMs)).help(TurnFormat.duration(turn.durationMs))
                                Text(turn.reasoningTokens.map { compactTokens($0) } ?? "—")
                                Text((turn.durationEstimated ? "≈ " : "") + TurnFormat.number(turn.speed))
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
                HStack {
                    Button { changePage(page - 1) } label: { Image(systemName: "chevron.left") }
                        .disabled(page == 0).accessibilityLabel(L("action.previous")).help(L("action.previous"))
                    Spacer()
                    Text(LF("turns.page", page + 1, pageCount)).font(.caption).monospacedDigit()
                    Spacer()
                    Button { changePage(page + 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(page + 1 >= pageCount).accessibilityLabel(L("action.next")).help(L("action.next"))
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
                Button(L("turns.show_all")) {
                    selectedBucketStart = nil
                    showPage(containing: selectedID, in: data.sorted(by: order, search: search))
                }.controlSize(.small)
            }
        } else {
            DashboardRollingValue(text: LF("turns.count", count), value: Double(count),
                                  range: isActive ? range : nil, style: .headline)
        }
    }
    private var sortPicker: some View {
        TurnListPicker(order: $order, search: Binding(get: { search }, set: { value in
            search = value
            page = 0
            selectedID = nil
        }))
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

    private func select(_ turn: AgentTurn, bucketStart: Date?) {
        if let bucketStart {
            selectedBucketStart = bucketStart
        } else if let selectedBucket, !selectedBucket.interval.contains(turn.start) {
            selectedBucketStart = nil
        }
        if !data.matches(turn, search: search.trimmingCharacters(in: .whitespacesAndNewlines)) {
            search = ""
        }
        selectedID = turn.id
        showPage(containing: turn.id, in: sortedTurns)
    }
}

private struct TurnListPicker: View {
    @Binding var order: TurnSort
    @Binding var search: String
    @State private var showing = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        WorkspaceDropdownTrigger(label: L("turns.search_sort"), value: search.isEmpty ? order.title : search,
                                 width: max(105, WorkspaceDropdownTrigger.fittingWidth(for: TurnSort.allCases.map(\.title)))) {
            showing.toggle()
        }
        .controlSize(.small)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    WorkspaceDropdownSearchField(prompt: L("turns.search_prompt"), text: $search, focus: $searchFocused) {
                        showing = false
                    }
                    if !search.isEmpty {
                        Button {
                            search = ""
                            searchFocused = true
                        } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).padding(.trailing, 12)
                        .accessibilityLabel(L("turns.clear_search")).help(L("turns.clear_search"))
                    }
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
                    Text(TurnFormat.timestamp(turn.start)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    WorkspaceInfoPopover(title: L("turns.basis")) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(basis)
                            LabeledContent(L("turns.session"), value: turn.sessionId)
                            LabeledContent(L("turns.turn"), value: turn.turnId)
                        }.font(.caption).textSelection(.enabled).padding(14).frame(width: 320)
                    }.help(basis).accessibilityHint(basis)
                }
                Text(turn.project).font(.title3.weight(.semibold)).textSelection(.enabled)
                if let title {
                    Text(title)
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        .textSelection(.enabled).help(title)
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
                        Text(effort).foregroundStyle(.secondary).fixedSize()
                    }
                }.font(.caption)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(L("turns.duration")).font(.caption).foregroundStyle(.secondary)
                Text((turn.durationEstimated ? "≈ " : "") + TurnFormat.duration(turn.durationMs)).font(DisplayNumberFont.font(size: 32))
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
                    }.font(.caption2).foregroundStyle(.secondary)
                }.help(L("turns.wait_help"))
            }
            HStack(alignment: .top, spacing: 12) {
                detailMetric("turns.speed", value: (turn.durationEstimated ? "≈ " : "") + TurnFormat.number(turn.speed), unit: "tokens/s")
                detailMetric("token.reasoning", value: turn.reasoningTokens.map { $0.formatted(.number.locale(Localization.locale)) } ?? "—")
                detailMetric("turns.ttft", value: TurnFormat.number(turn.ttftMs.map { Double($0) / 1000 }), unit: L("turns.seconds_unit"))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(LF("turns.responses_tools", turn.requests.map { $0.formatted(.number.locale(Localization.locale)) } ?? "—", turn.toolCalls.map { $0.formatted(.number.locale(Localization.locale)) } ?? "—")).font(.caption).foregroundStyle(.secondary)
                HStack { Text(L("turns.generated")); Spacer(); Text(turn.generatedTokens.formatted(.number.locale(Localization.locale))).monospacedDigit() }.font(.caption)
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
            Text(L(key)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TurnMetricValue(value: value, unit: unit, size: 24)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
    private func mixLabel(_ key: String, value: Int64, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5).accessibilityHidden(true)
            Text(L(key)).foregroundStyle(.secondary)
            Text(value.formatted(.number.locale(Localization.locale))).monospacedDigit()
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
        Text("\(Text(value).font(DisplayNumberFont.font(size: size)).foregroundStyle(.primary))\(Text(unit.isEmpty ? "" : " " + unit).font(.caption).foregroundStyle(.secondary))")
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75).textSelection(.enabled)
    }
}
