// [INPUT]: Real daily client/model aggregates for the annual range.
// [OUTPUT]: Stacked model history, raw totals and daily/moving-average inspection.
// [POS]: Annual overview chart; known costs remain visible when another model has unpriced usage.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import SwiftUI

struct UsageHistoryChart: View {
    let report: ActivityReport
    @Environment(UsageStore.self) private var store
    @State private var metric: UsageMetric = .tokens
    @State private var average = true
    @State private var client = ""
    @State private var expandedLegend = false
    private var clients: [String] { Array(Set(report.modelDays.map(\.client))).sorted() }
    var body: some View {
        let data = store.history(metric: metric, average: average, client: clients.contains(client) ? client : nil)!
        let legend = data.series.sorted { ($0.total ?? -1) > ($1.total ?? -1) }
        WorkspacePanel {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L("history.title")).font(.headline)
                        Text(L("activity.year")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(L(metric == .tokens ? "history.total_tokens" : data.unpricedTokens > 0 ? "cost.known" : "cost.estimate"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(metric == .tokens ? compactTokens(Int64(data.total ?? 0)) : usd(data.total))
                            .font(.title3.weight(.semibold)).monospacedDigit()
                    }.help(data.unpricedTokens > 0 ? LF("usage.unpriced", compactTokens(data.unpricedTokens)) : L("history.total_help"))
                }
                ViewThatFits(in: .horizontal) {
                    HStack { metricControls; Spacer(); filterControls }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 10) { metricControls; filterControls }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if data.series.isEmpty {
                    ContentUnavailableView(L("usage.empty"), systemImage: "chart.xyaxis.line").frame(height: 220)
                } else {
                    HistoryPlot(data: data).frame(height: 240)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading, spacing: 10) {
                        ForEach(expandedLegend ? legend : Array(legend.prefix(6))) { series in
                            HStack(spacing: 6) {
                                Circle().fill(historyColor(series)).frame(width: 7, height: 7)
                                Text(series.model).lineLimit(1).truncationMode(.middle)
                            }.font(.caption).foregroundStyle(.secondary).help(clientName(series.client) + " · " + series.model)
                        }
                    }
                    if data.series.count > 6 {
                        Button(L(expandedLegend ? "action.show_less" : "action.show_all")) { expandedLegend.toggle() }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
    }
    private var metricControls: some View {
        HStack(spacing: 10) {
            Picker(L("history.metric"), selection: $metric) {
                ForEach(UsageMetric.allCases, id: \.self) { Text($0.title).tag($0) }
            }.labelsHidden().pickerStyle(.segmented).fixedSize()
            Picker(L("history.display"), selection: $average) {
                Text(L("history.average")).tag(true)
                Text(L("history.daily")).tag(false)
            }.labelsHidden().fixedSize().help(L("history.average_help"))
        }
    }
    private var filterControls: some View {
        HStack(spacing: 12) {
            Picker(L("field.tool"), selection: $client) {
                Text(L("filter.tools")).tag("")
                ForEach(clients, id: \.self) { Text(clientName($0)).tag($0) }
            }.labelsHidden().frame(maxWidth: 150)
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
    @State private var selectedIndex: Int?
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - 70)
            let height = max(1, geometry.size.height - 30)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
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
                                    let point = CGPoint(x: x(i, width), y: height * (1 - (base[i] + (series.values[i] ?? 0)) / data.maximum))
                                    if i == start { path.move(to: point) } else { path.addLine(to: point) }
                                }
                                for i in (start..<end).reversed() { path.addLine(to: CGPoint(x: x(i, width), y: height * (1 - base[i] / data.maximum))) }
                                path.closeSubpath()
                                context.fill(path, with: .color(historyColor(series).opacity(scheme == .dark ? 0.48 : 0.38)))
                                context.stroke(path, with: .color(historyColor(series).opacity(0.85)), lineWidth: 0.8)
                            }
                            start = end + 1
                        }
                        for i in base.indices { base[i] += series.values[i] ?? 0 }
                    }
                    if let index = selectedIndex, data.days.indices.contains(index) {
                        var rule = Path(); rule.move(to: CGPoint(x: x(index, width), y: 0)); rule.addLine(to: CGPoint(x: x(index, width), y: height))
                        context.stroke(rule, with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }.accessibilityHidden(true)
                ForEach(0...4, id: \.self) { tick in
                    Text(value(data.maximum * Double(4 - tick) / 4))
                        .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                        .offset(x: width + 9, y: height * Double(tick) / 4 - 5)
                }
                HStack {
                    if let first = data.days.first { Text(Localization.day(first.key)) }
                    Spacer()
                    if let last = data.days.last { Text(Localization.day(last.key)) }
                }.font(.caption2).foregroundStyle(.secondary).frame(width: width).offset(y: height + 10)
                Rectangle().fill(.clear).contentShape(Rectangle()).frame(width: width, height: height)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): select(point.x, width: width)
                        case .ended: selectedIndex = nil
                        }
                    }.onTapGesture { select($0.x, width: width) }
                if let index = selectedIndex, data.days.indices.contains(index) {
                    readout(index).padding(12).frame(width: min(290, geometry.size.width))
                        .background(WorkspaceStyle.surface(scheme), in: RoundedRectangle(cornerRadius: 8))
                        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) }
                        .offset(x: min(max(0, x(index, width) - 145), max(0, geometry.size.width - 290)), y: 3)
                        .allowsHitTesting(false)
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
    private func x(_ index: Int, _ width: CGFloat) -> CGFloat { CGFloat(index) / CGFloat(max(1, data.days.count - 1)) * width }
    private func value(_ amount: Double?) -> String {
        if data.metric == .cost { return usd(amount) }
        return amount.map { compactTokens(Int64($0.rounded())) } ?? "—"
    }
    private func select(_ x: CGFloat, width: CGFloat) {
        selectedIndex = min(max(0, Int((x / width * CGFloat(max(0, data.days.count - 1))).rounded())), max(0, data.days.count - 1))
    }
    private func move(_ delta: Int) {
        guard !data.days.isEmpty else { return }
        selectedIndex = min(max(0, (selectedIndex ?? (delta > 0 ? -1 : data.days.count)) + delta), data.days.count - 1)
    }
    private func readout(_ index: Int) -> some View {
        let ranked = data.series.filter { $0.values[index] == nil || ($0.values[index] ?? 0) > 0 }.sorted { ($0.values[index] ?? -1) > ($1.values[index] ?? -1) }
        return VStack(alignment: .leading, spacing: 7) {
            Text(Localization.day(data.days[index].key)).font(.caption.weight(.semibold))
            if data.average { Text(L("history.average")).font(.caption2).foregroundStyle(.secondary) }
            ForEach(ranked.prefix(6)) { series in
                HStack(spacing: 7) {
                    Circle().fill(historyColor(series)).frame(width: 6, height: 6)
                    Text(series.model).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(value(series.values[index])).monospacedDigit()
                }.font(.caption2)
            }
        }
    }
}
