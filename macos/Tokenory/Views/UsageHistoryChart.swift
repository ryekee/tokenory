// [INPUT]: Real daily client/model aggregates for the annual range.
// [OUTPUT]: Stacked model history, raw totals and single-click daily/moving-average inspection.
// [POS]: Annual overview chart; known costs remain visible when another model has unpriced usage.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import SwiftUI

struct UsageHistoryChart: View {
    let report: ActivityReport
    let localOnly: Bool
    @Environment(UsageStore.self) private var store
    @State private var metric: UsageMetric = .tokens
    @State private var average = true
    @State private var client = ""
    @State private var expandedLegend = false
    private var clients: [String] { Array(Set(report.modelDays.map(\.client))).sorted() }
    var body: some View {
        let data = store.history(metric: metric, average: average, client: clients.contains(client) ? client : nil, localOnly: localOnly)
        if let data { historyPanel(data) }
    }
    private func historyPanel(_ data: UsageHistory) -> some View {
        let legend = data.series.sorted { ($0.total ?? -1) > ($1.total ?? -1) }
        return WorkspacePanel {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L("history.title")).font(.headline)
                        Text(L("activity.year")).font(.caption).foregroundStyle(WorkspaceStyle.subtext)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(L(metric == .tokens ? "history.total_tokens" : data.unpricedTokens > 0 ? "cost.known" : "cost.estimate"))
                            .font(.caption).foregroundStyle(WorkspaceStyle.subtext)
                        Text(metric == .tokens ? compactTokens(Int64(data.total ?? 0)) : usd(data.total))
                            .font(DisplayNumberFont.font(for: .title3))
                    }.help(data.unpricedTokens > 0 ? LF("usage.unpriced", compactTokens(data.unpricedTokens)) : L("history.total_help"))
                }.foregroundStyle(WorkspaceStyle.text)
                ViewThatFits(in: .horizontal) {
                    HStack { metricControls; Spacer(); filterControls }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 10) { metricControls; filterControls }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if data.series.isEmpty {
                    Text(L("usage.empty")).font(.callout).foregroundStyle(WorkspaceStyle.subtext)
                } else {
                    HistoryPlot(data: data).frame(height: 240)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading, spacing: 10) {
                        ForEach(expandedLegend ? legend : Array(legend.prefix(6))) { series in
                            HStack(spacing: 6) {
                                Circle().fill(historyColor(series)).frame(width: 7, height: 7)
                                Text(series.model).lineLimit(1).truncationMode(.middle)
                            }.font(.caption).foregroundStyle(WorkspaceStyle.subtext).help(clientName(series.client) + " · " + series.model)
                        }
                    }
                    if data.series.count > 6 {
                        Button(L(expandedLegend ? "action.show_less" : "action.show_all")) { expandedLegend.toggle() }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(WorkspaceStyle.selection)
                    }
                }
            }
        }
    }
    private var metricControls: some View {
        HStack(spacing: 10) {
            Picker(L("history.metric"), selection: $metric) {
                ForEach(UsageMetric.allCases, id: \.self) { Text($0.title).tag($0) }
            }.labelsHidden().pickerStyle(.segmented).tint(WorkspaceStyle.selection).fixedSize()
            Picker(L("history.display"), selection: $average) {
                Text(L("history.average")).tag(true)
                Text(L("history.daily")).tag(false)
            }.labelsHidden().pickerStyle(.segmented).tint(WorkspaceStyle.selection).fixedSize().help(L("history.average_help"))
        }
    }
    private var filterControls: some View {
        HStack(spacing: 12) {
            WorkspaceDropdown(
                label: L("field.tool"), selection: $client, options: [""] + clients, width: 124,
                title: { $0.isEmpty ? L("filter.tools") : clientName($0) },
                brand: { $0.isEmpty ? nil : ($0, .tool) }
            )
        }
    }
}

private func historyColor(_ series: HistorySeries) -> Color {
    let hue: Double
    switch series.client {
    case "codex": hue = 0.46
    case "claude": hue = 0.04
    case "devin-cli", "devin-desktop": hue = 0.60
    case "openclaw": hue = 0.76
    case "micode": hue = 0.92
    default:
        let hash = series.client.utf8.reduce(0) { ($0 * 31 + Int($1)) % 360 }
        hue = Double(hash) / 360
    }
    return Color(hue: hue, saturation: max(0.18, 0.63 - Double(series.shade % 5) * 0.1), brightness: 0.74 + Double(series.shade % 4) * 0.06)
}

private struct HistoryPlot: View {
    let data: UsageHistory
    private let rowCount: Int
    private let readoutWidth: CGFloat
    @State private var selectedIndex: Int?
    @State private var tooltipPointer = TooltipPointer()
    @State private var keyboardSelection = false
    init(data: UsageHistory) {
        self.data = data
        let limit = min(6, data.series.count)
        var count = 0
        for index in data.days.indices {
            let visible = data.series.lazy.filter { row in row.values[index].map { $0 > 0 } ?? true }
            count = max(count, visible.prefix(limit).count)
            if count == limit { break }
        }
        rowCount = count
        let name = min(155, data.series.map { CursorTooltipLayout.textWidth($0.model) }.max() ?? 0)
        let value = data.metric == .cost ? usd(data.maximum) : compactTokens(Int64(exactly: data.maximum.rounded()) ?? Int64.max)
        readoutWidth = max(130, name + CursorTooltipLayout.textWidth(value) + 24)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - 70)
            let height = max(1, geometry.size.height - 30)
            ZStack(alignment: .topLeading) {
                HistoryAreas(data: data).frame(width: width, height: height)
                    .accessibilityHidden(true)
                ForEach(0...4, id: \.self) { tick in
                    Text(value(data.maximum * Double(4 - tick) / 4))
                        .font(.system(size: 10)).foregroundStyle(WorkspaceStyle.subtext).monospacedDigit()
                        .offset(x: width + 9, y: height * Double(tick) / 4 - 5)
                }
                HStack {
                    if let first = data.days.first { Text(Localization.day(first.key)) }
                    Spacer()
                    if let last = data.days.last { Text(Localization.day(last.key)) }
                }.font(.caption2).foregroundStyle(WorkspaceStyle.subtext).frame(width: width).offset(y: height + 10)
                let index = selectedIndex.flatMap { data.days.indices.contains($0) ? $0 : nil }
                let mark = index.map { CGRect(x: data.position(of: $0, width: width), y: 0, width: 1, height: height) }
                if let mark {
                    ChartHoverRule(x: mark.minX, plot: CGRect(x: 0, y: 0, width: width, height: height), opacity: 0.7)
                }
                Rectangle().fill(.clear).contentShape(Rectangle()).frame(width: width, height: height)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): select(point, width: width)
                        case .ended: selectedIndex = nil
                        }
                    }.onTapGesture { select($0, width: width) }
                    .selectedTooltip(avoiding: mark, pointer: tooltipPointer, keyboardAnchor: keyboardSelection ? mark.map { CGPoint(x: $0.midX, y: $0.midY) } : nil) {
                        if let index { readout(index) }
                    }
            }
        }.focusable()
            .onKeyPress(.leftArrow) { move(-1); return .handled }
            .onKeyPress(.rightArrow) { move(1); return .handled }
            .onKeyPress(.escape) { selectedIndex = nil; return .handled }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("history.title"))
            .accessibilityValue(accessibilityReadout)
            .accessibilityAdjustableAction { direction in move(direction == .increment ? 1 : -1) }
    }
    private var accessibilityReadout: String {
        guard let index = selectedIndex, data.days.indices.contains(index) else { return value(data.total) }
        return Localization.day(data.days[index].key) + ": " + data.series.map { $0.model + " " + value($0.values[index]) }.joined(separator: ", ")
    }
    private func value(_ amount: Double?) -> String {
        if data.metric == .cost { return usd(amount) }
        return amount.map { compactTokens(Int64($0.rounded())) } ?? "—"
    }
    private func select(_ point: CGPoint, width: CGFloat) {
        tooltipPointer.move(to: point)
        let x = point.x
        keyboardSelection = false
        selectedIndex = min(max(0, Int((x / width * CGFloat(max(0, data.days.count - 1))).rounded())), max(0, data.days.count - 1))
    }
    private func move(_ delta: Int) {
        guard !data.days.isEmpty else { return }
        keyboardSelection = true
        selectedIndex = min(max(0, (selectedIndex ?? (delta > 0 ? -1 : data.days.count)) + delta), data.days.count - 1)
    }
    private func readout(_ index: Int) -> some View {
        let ranked = data.series.filter { $0.values[index] == nil || ($0.values[index] ?? 0) > 0 }.sorted { ($0.values[index] ?? -1) > ($1.values[index] ?? -1) }
        let rows = ranked.prefix(rowCount).map { series in
            HistoryDayReadout.Row(model: series.model, color: historyColor(series), value: value(series.values[index]))
        }
        return HistoryDayReadout(title: Localization.day(data.days[index].key), average: data.average,
                                 rows: rows, rowCount: rowCount, width: readoutWidth)
    }
}

private extension UsageHistory {
    func position(of index: Int, width: CGFloat) -> CGFloat {
        CGFloat(index) / CGFloat(max(1, days.count - 1)) * width
    }
}

// Selection lives in a separate overlay so pointer motion does not rebuild the stacked annual paths.
private struct HistoryAreas: View {
    let data: UsageHistory
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Canvas { context, size in
            let width = size.width, height = size.height
            for tick in 0...4 {
                let y = height * CGFloat(tick) / 4
                var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: width, y: y))
                context.stroke(line, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
            }
            var base = Array(repeating: 0.0, count: data.days.count)
            for series in data.series {
                let valid = series.values.map { $0 != nil }
                var start = 0
                while start < data.days.count {
                    while start < data.days.count && !valid[start] { start += 1 }
                    var end = start
                    while end < data.days.count && valid[end] { end += 1 }
                    if start < end {
                        var path = Path()
                        for i in start..<end {
                            let point = CGPoint(x: data.position(of: i, width: width), y: height * (1 - (base[i] + (series.values[i] ?? 0)) / data.maximum))
                            if i == start { path.move(to: point) } else { path.addLine(to: point) }
                        }
                        for i in (start..<end).reversed() { path.addLine(to: CGPoint(x: data.position(of: i, width: width), y: height * (1 - base[i] / data.maximum))) }
                        path.closeSubpath()
                        context.fill(path, with: .color(historyColor(series).opacity(scheme == .dark ? 0.48 : 0.38)))
                        context.stroke(path, with: .color(historyColor(series).opacity(0.85)), lineWidth: 0.8)
                    }
                    start = end + 1
                }
                for i in base.indices { base[i] += series.values[i] ?? 0 }
            }
        }
    }
}

struct HistoryDayReadout: View {
    struct Row { let model: String; let color: Color; let value: String }
    let title: String
    let average: Bool
    let rows: [Row]
    let rowCount: Int
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold))
            if average { Text(L("history.average")).font(.caption2).foregroundStyle(WorkspaceStyle.subtext) }
            ForEach(0..<rowCount, id: \.self) { slot in
                // Reserve identical line metrics even when a day has fewer active models.
                Text(verbatim: "0").font(.caption2).hidden().frame(maxWidth: .infinity)
                    .overlay(alignment: .leading) {
                        if slot < rows.count {
                            let row = rows[slot]
                            HStack(spacing: 7) {
                                Circle().fill(row.color).frame(width: 6, height: 6)
                                Text(row.model).truncationMode(.middle)
                                Spacer(minLength: 4)
                                Text(row.value).monospacedDigit().fixedSize()
                            }.font(.caption2)
                        }
                    }
            }
        }.lineLimit(1).frame(width: width, alignment: .leading)
    }
}
