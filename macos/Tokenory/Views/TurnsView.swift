// [INPUT]: Lazy multi-agent turn report, shared date range and local client/model selection.
// [OUTPUT]: Turn analytics and details with rolling metrics, calendar-based speed boxes, and bucket drill-down.
// [POS]: Native speed-analysis page; list pagination never limits summaries or chart data.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import SwiftUI

struct TurnsView: View {
    let isActive: Bool
    @Environment(UsageStore.self) private var store
    @State private var selectedID: String?
    @State private var order: TurnSort = .duration
    @State private var page = 0
    @State private var showsCoverage = false
    private var query: TurnQuery {
        TurnQuery(from: store.filter.from, to: store.filter.to, model: store.turnModel, client: store.turnClient)
    }
    var body: some View {
        let requestedQuery = isActive ? query : nil
        let waiting = isActive && (store.turnsLoading || (store.turnsQuery != requestedQuery && store.turnsError == nil))
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker(L("field.tool"), selection: Binding(
                    get: { store.turnClient ?? "" },
                    set: { store.turnClient = $0.isEmpty ? nil : $0; store.turnModel = nil })) {
                    Text(L("filter.tools")).tag("")
                    ForEach(store.turnAnalytics?.capabilities.filter(\.supported).map(\.client) ?? ["codex"], id: \.self) { client in
                        Text(clientName(client)).tag(client)
                    }
                }.labelsHidden().fixedSize().help(L("turns.scope"))
                Picker(L("field.model"), selection: Binding(
                    get: { store.turnModel ?? "" },
                    set: { store.turnModel = $0.isEmpty ? nil : $0 })) {
                    Text(L("filter.models")).tag("")
                    ForEach(Array(Set((store.turnAnalytics?.models ?? []) + [store.turnModel].compactMap { $0 })).sorted(), id: \.self) { model in
                        Text(model).tag(model)
                    }
                }.labelsHidden().fixedSize().frame(maxWidth: 280, alignment: .leading)
                Spacer(minLength: 0)
                Button { showsCoverage = true } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.plain).help(L("turns.support"))
                    .popover(isPresented: $showsCoverage) {
                        AgentCoveragePopover(capabilities: store.turnAnalytics?.capabilities ?? [])
                    }
                ZStack {
                    if waiting && store.turnAnalytics != nil { ProgressView().controlSize(.small) }
                }.frame(width: 16, height: 16)
            }.padding(.horizontal, 22).padding(.vertical, 14)
            if let error = store.turnsError {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("turns.load_failed"))
                        DisclosureGroup(L("error.details")) { Text(error).textSelection(.enabled) }
                    }
                    Spacer()
                    Button(L("turns.retry")) { Task { await store.loadAgentTurns(query, force: true) } }
                }.font(.caption).padding(.horizontal, 22).padding(.bottom, 12)
            }
            if let data = store.turnAnalytics, let displayed = store.turnsQuery,
               requestedQuery == nil || displayed == requestedQuery || waiting {
                TurnsContent(data: data, range: DashboardDateSpan(from: displayed.from, to: displayed.to),
                             isActive: isActive, selectedID: $selectedID, order: $order, page: $page)
            } else if waiting {
                ProgressView(L("usage.loading_stats")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(L("turns.empty"), systemImage: "stopwatch")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: requestedQuery) {
            if let requestedQuery, !Task.isCancelled { await store.loadAgentTurns(requestedQuery) }
        }
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
    private let pageSize = 50

    private var selectedBucket: TurnSpeedBucket? {
        selectedBucketStart.flatMap { data.speedTimeline?.bucket(at: $0) }
    }

    var body: some View {
        let sorted = data.sorted(by: order, in: selectedBucket)
        let selected = sorted.first { $0.id == selectedID } ?? sorted.first
        return GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    WorkspacePanel { summary }
                    WorkspacePanel {
                        TurnSpeedChart(data: data, range: range, animateRangeChanges: isActive,
                                       selected: selected, selectedBucketStart: selectedBucket?.start, onSelect: select)
                    }
                    if data.points.isEmpty {
                        ContentUnavailableView(L("turns.empty"), systemImage: "stopwatch")
                            .frame(maxWidth: .infinity).padding(.vertical, 20)
                    } else {
                        let wide = geometry.size.width - 44 >= 720
                        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 18)) : AnyLayout(VStackLayout(spacing: 18))
                        layout {
                            turnList(sorted: sorted, selected: selected).frame(maxWidth: .infinity)
                            if let selected { WorkspacePanel { TurnDetail(turn: selected) }.frame(maxWidth: .infinity) }
                        }
                    }
                }.padding(.horizontal, 22).padding(.bottom, 22)
            }
        }
        .onChange(of: order) { _, _ in
            showPage(containing: selectedID, in: sorted)
        }
        .onChange(of: range) { _, _ in
            selectedBucketStart = nil
            showPage(containing: selectedID, in: data.sorted(by: order))
        }
        .onChange(of: data.points, initial: true) { _, _ in
            if selectedBucket == nil { selectedBucketStart = nil }
            let sorted = data.sorted(by: order, in: selectedBucket)
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
                DashboardRollingValue(text: value, value: amount, range: isActive ? range : nil, style: .semibold(32))
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            .lineLimit(1).minimumScaleFactor(0.75).textSelection(.enabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(unit.isEmpty ? value : "\(value) \(unit)")
        }.frame(maxWidth: .infinity, alignment: .leading).help(help).accessibilityElement(children: .combine)
    }

    private func turnList(sorted: [AgentTurn], selected: AgentTurn?) -> some View {
        let pageCount = max(1, (sorted.count + pageSize - 1) / pageSize)
        let start = min(page * pageSize, sorted.count)
        let visible = Array(sorted.dropFirst(start).prefix(pageSize))
        return WorkspacePanel {
            VStack(spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { listTitle(count: sorted.count); Spacer(); sortPicker }
                    VStack(alignment: .leading, spacing: 8) { listTitle(count: sorted.count); sortPicker }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                rowColumns {
                    Text(L("turns.project")); Text(L("turns.duration")); Text(L("token.reasoning")); Text("tokens/s")
                }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 5)
                Divider()
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(spacing: 0) {
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
                                            Text(TurnFormat.timestamp(turn.start)).font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Text((turn.durationEstimated ? "≈ " : "") + TurnFormat.clockDuration(turn.durationMs)).help(TurnFormat.duration(turn.durationMs))
                                        Text(turn.reasoningTokens.map { compactTokens($0) } ?? "—")
                                        Text((turn.durationEstimated ? "≈ " : "") + TurnFormat.number(turn.speed))
                                    }.font(.callout).monospacedDigit().padding(.vertical, 9).padding(.horizontal, 5)
                                        .contentShape(Rectangle())
                                        .background(selected?.id == turn.id ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                }.buttonStyle(WorkspaceHoverStyle()).id(turn.id)
                                    .accessibilityElement(children: .combine)
                                    .accessibilityAddTraits(selected?.id == turn.id ? [.isSelected] : [])
                                Divider().opacity(0.5)
                            }
                        }
                    }.frame(height: min(380, CGFloat(visible.count) * 57))
                        .onChange(of: page) { _, _ in if let first = visible.first { scroll.scrollTo(first.id, anchor: .top) } }
                        .onChange(of: order) { _, _ in if let first = visible.first { scroll.scrollTo(first.id, anchor: .top) } }
                        .onChange(of: selectedID) { _, id in if let id { scroll.scrollTo(id, anchor: .center) } }
                }
                if pageCount > 1 {
                    HStack {
                        Button { page -= 1 } label: { Image(systemName: "chevron.left") }.disabled(page == 0).help(L("action.previous"))
                        Spacer()
                        Text(LF("turns.page", page + 1, pageCount)).font(.caption).monospacedDigit()
                        Spacer()
                        Button { page += 1 } label: { Image(systemName: "chevron.right") }.disabled(page == pageCount - 1).help(L("action.next"))
                    }
                }
            }
        }
    }
    @ViewBuilder
    private func listTitle(count: Int) -> some View {
        if let selectedBucket, let granularity = data.speedTimeline?.granularity {
            HStack(spacing: 8) {
                Text("\(TurnFormat.speedBucket(selectedBucket, granularity: granularity)) · \(LF("turns.count", count))").font(.headline)
                Button(L("turns.show_all")) {
                    selectedBucketStart = nil
                    showPage(containing: selectedID, in: data.sorted(by: order))
                }.controlSize(.small)
            }
        } else {
            DashboardRollingValue(text: LF("turns.count", count), value: Double(count),
                                  range: isActive ? range : nil, style: .headline)
        }
    }
    private var sortPicker: some View {
        Picker(L("overview.sort"), selection: $order) {
            ForEach(TurnSort.allCases, id: \.self) { Text($0.title).tag($0) }
        }.labelsHidden().fixedSize().controlSize(.small)
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
        selectedID = turn.id
        showPage(containing: turn.id, in: data.sorted(by: order, in: selectedBucket))
    }
}

private struct TurnDetail: View {
    let turn: AgentTurn
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(TurnFormat.timestamp(turn.start)).font(.caption).foregroundStyle(.secondary)
                Text(turn.project).font(.title3.weight(.semibold)).textSelection(.enabled)
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
                Text((turn.durationEstimated ? "≈ " : "") + TurnFormat.duration(turn.durationMs)).font(.system(size: 32, weight: .semibold)).monospacedDigit()
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
            Divider()
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
            DisclosureGroup(L("turns.basis")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("turns.average_speed_help"))
                    Text(L("turns.ttft_help"))
                    Text(L("turns.wait_help"))
                    Text(L("turns.scope"))
                    if turn.durationEstimated { Text(L("turns.estimated_help")) }
                    LabeledContent(L("turns.session"), value: turn.sessionId)
                    LabeledContent(L("turns.turn"), value: turn.turnId)
                }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }.disclosureGroupStyle(WorkspaceDisclosureStyle()).font(.caption)
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
        Text("\(Text(value).font(.system(size: size, weight: .semibold)).foregroundStyle(.primary))\(Text(unit.isEmpty ? "" : " " + unit).font(.caption).foregroundStyle(.secondary))")
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75).textSelection(.enabled)
    }
}
