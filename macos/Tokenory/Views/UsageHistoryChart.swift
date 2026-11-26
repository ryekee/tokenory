// [INPUT]: Real daily client/model aggregates for the annual range.
// [OUTPUT]: Raw and averaged model history with immediate date emphasis, delayed readouts and instant pinning.
// [POS]: Annual overview chart; known costs remain visible when another model has unpriced usage.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import SwiftUI

struct UsageHistoryChart: View {
    let report: ActivityReport
    let localOnly: Bool
    @Environment(UsageStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                        Text(L("history.title")).font(.headline).accessibilityAddTraits(.isHeader)
                        Text(L("activity.year")).font(.caption).foregroundStyle(WorkspaceStyle.subtext)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(L(metric == .tokens ? "history.total_tokens" : data.unpricedTokens > 0 ? "cost.known" : "cost.estimate"))
                            .font(.caption).foregroundStyle(WorkspaceStyle.subtext)
                        Text(metric == .tokens ? compactTokens(Int64(data.total ?? 0)) : usd(data.total))
                            .font(DisplayNumberFont.font(for: .title3))
                    }
                }.foregroundStyle(WorkspaceStyle.text)
                ViewThatFits(in: .horizontal) {
                    HStack { metricControls; Spacer(); filterControls }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 10) { metricControls; filterControls }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if data.series.isEmpty {
                    Text(L("usage.empty")).font(.callout).foregroundStyle(WorkspaceStyle.subtext)
                } else {
                    HistoryPlot(data: data, scope: HistoryPlotScope(metric: metric, average: average, client: client, localOnly: localOnly))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading, spacing: 10) {
                        ForEach(expandedLegend ? legend : Array(legend.prefix(6))) { series in
                            HStack(spacing: 6) {
                                Circle().fill(historyColor(series)).frame(width: 7, height: 7)
                                Text(series.model).lineLimit(1).truncationMode(.middle)
                            }.font(.caption).foregroundStyle(WorkspaceStyle.subtext)
                                .transition(.opacity)
                        }
                    }
                    if data.series.count > 6 {
                        Button {
                            DashboardMotion.withAnimation(DashboardMotion.disclosure, reduceMotion: reduceMotion) {
                                expandedLegend.toggle()
                            }
                        } label: {
                            Text(L(expandedLegend ? "action.show_less" : "action.show_all"))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                        }
                        .buttonStyle(WorkspaceHoverStyle()).font(.caption).foregroundStyle(WorkspaceStyle.selection)
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
            }.labelsHidden().pickerStyle(.segmented).tint(WorkspaceStyle.selection).fixedSize()
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

struct HistoryAxisScale {
    static let maxLabels = 4
    let intervals: Int
    let maximum: Double
    let labels: [String]

    init(paddedMaximum: Double, metric: UsageMetric, locale: Locale = Localization.locale) {
        let minimumStep: Double = metric == .tokens ? 1 : 0.01
        let niceMultipliers = [1.0, 2, 2.5, 5, 10]

        func niceStep(for target: Double) -> Double {
            let clamped = max(minimumStep, target)
            let magnitude = pow(10, floor(log10(clamped)))
            let multiplier = niceMultipliers.first { $0 * magnitude >= clamped } ?? 10
            return multiplier * magnitude
        }

        // Dynamically choose 2 or 3 intervals (3 or 4 labels total, including 0)
        // for the tightest nice ceiling above `paddedMaximum`.
        var bestIntervals = 3
        var bestStep = niceStep(for: paddedMaximum / 3.0)
        var bestMax = bestStep * Double(bestIntervals)
        if paddedMaximum > 0 {
            for candidateIntervals in [3, 2] {
                let step = niceStep(for: paddedMaximum / Double(candidateIntervals))
                let ceiling = step * Double(candidateIntervals)
                if ceiling < bestMax - 1e-12 {
                    bestIntervals = candidateIntervals
                    bestStep = step
                    bestMax = ceiling
                }
            }
        }
        intervals = bestIntervals
        maximum = bestMax

        // Keep one unit for the entire axis. Choose it only if each tick can
        // be shown exactly as an integer or half in that unit.
        let units = compactUsageUnits(locale: locale) + [(1, "")]
        let regularUnit = units.first { unit in
            let halves = 2 * bestStep / unit.divisor
            let rounded = halves.rounded()
            return rounded >= 1 && abs(halves - rounded) < 1e-9
        }
        let unit = regularUnit ?? (divisor: 0.01, suffix: "¢")
        let prefix = metric == .cost && regularUnit != nil ? "$" : ""
        let zero = prefix + "0" + (regularUnit == nil ? unit.suffix : "")
        let format = FloatingPointFormatStyle<Double>.number
            .precision(.fractionLength(0...1)).locale(Locale(identifier: "en_US"))
        labels = (0...intervals).reversed().map { tick in
            guard tick > 0 else { return zero }
            return prefix + (Double(tick) * bestStep / unit.divisor).formatted(format) + unit.suffix
        }
    }
}

private struct HistoryPlotScope: Hashable {
    let metric: UsageMetric
    let average: Bool
    let client: String
    let localOnly: Bool
}

private struct HistoryPlot: View {
    let data: UsageHistory
    let scope: HistoryPlotScope
    private let axis: HistoryAxisScale
    private let rowCount: Int
    private let readoutWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var inspection = ChartInspection<String>()
    @State private var tooltipPointer = TooltipPointer()
    init(data: UsageHistory, scope: HistoryPlotScope) {
        self.data = data
        self.scope = scope
        axis = HistoryAxisScale(paddedMaximum: data.maximum, metric: data.metric)
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
        VStack(alignment: .leading, spacing: 9) {
            plot.frame(height: 240)
            if let index = selectedIndex, inspection.pinned == data.days[index].key {
                PinnedChartReadout(clear: {
                    DashboardMotion.withAnimation(DashboardMotion.disclosure, reduceMotion: reduceMotion) {
                        inspection.clear()
                    }
                }) { readout(index) }
                .transition(.opacity)
            }
        }
        .onChange(of: scope) { _, _ in inspection.clear() }
    }

    private var plot: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let topInset: CGFloat = 18
            let chartHeight = max(1, geometry.size.height - 30 - topInset)
            let plotBottom = topInset + chartHeight
            ZStack(alignment: .topLeading) {
                HistoryAreas(data: data, axis: axis, topInset: topInset)
                    .frame(width: width, height: plotBottom)
                    .accessibilityHidden(true)
                HStack {
                    if let first = data.days.first { Text(Localization.day(first.key)) }
                    Spacer()
                    if let last = data.days.last { Text(Localization.day(last.key)) }
                }.font(.caption2).foregroundStyle(WorkspaceStyle.subtext).frame(width: width).offset(y: plotBottom + 10)
                let index = selectedIndex
                let plot = CGRect(x: 0, y: topInset, width: width, height: chartHeight)
                let center = index.map { data.position(of: $0, width: width) }
                let focus = center.map { x in
                    let span = max(8, width / CGFloat(max(1, data.days.count - 1)))
                    return CGRect(x: x - span / 2, y: plot.minY, width: span, height: plot.height).intersection(plot)
                }
                if let focus, let center {
                    ChartFocusShade(plot: plot, focus: focus)
                    ChartHoverRule(x: center, plot: plot, opacity: inspection.pinned == nil ? 0.7 : 0.95)
                }
                Rectangle().fill(.clear).contentShape(Rectangle()).frame(width: width, height: plotBottom)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            let next = dayKey(at: point, width: width)
                            inspection.hover.update(inspection.pinned == nil ? next : nil)
                            tooltipPointer.move(to: point, reposition: inspection.hover.readoutTarget != nil)
                        case .ended: inspection.hover.update(nil)
                        }
                    }
                    .onDisappear { inspection.hover.update(nil) }
                    .onTapGesture { point in
                        DashboardMotion.withAnimation(DashboardMotion.disclosure, reduceMotion: reduceMotion) {
                            inspection.togglePin(dayKey(at: point, width: width))
                        }
                    }
                    .selectedTooltip(avoiding: inspection.hover.readoutTarget != nil ? focus : nil, pointer: tooltipPointer) {
                        if let index { readout(index) }
                    }
            }
        }.focusable()
            .onKeyPress(.leftArrow) { move(-1); return .handled }
            .onKeyPress(.rightArrow) { move(1); return .handled }
            .onKeyPress(.escape) {
                guard inspection.selection != nil else {
                    inspection.hover.update(nil)
                    return .ignored
                }
                DashboardMotion.withAnimation(DashboardMotion.disclosure, reduceMotion: reduceMotion) {
                    inspection.clear()
                }
                return .handled
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("history.title"))
            .accessibilityValue(accessibilityReadout)
            .accessibilityAdjustableAction { direction in move(direction == .increment ? 1 : -1) }
    }
    private var selectedIndex: Int? {
        guard let key = inspection.selection else { return nil }
        return data.days.firstIndex { $0.key == key }
    }

    private var accessibilityReadout: String {
        guard let index = selectedIndex, data.days.indices.contains(index) else { return value(data.total) }
        return Localization.day(data.days[index].key) + ": " + data.series.map { $0.model + " " + value($0.values[index]) }.joined(separator: ", ")
    }
    private func value(_ amount: Double?) -> String {
        if data.metric == .cost { return usd(amount) }
        return amount.map { compactTokens(Int64($0.rounded())) } ?? "—"
    }
    private func dayKey(at point: CGPoint, width: CGFloat) -> String? {
        guard !data.days.isEmpty, point.x >= 0, point.x <= width else { return nil }
        let index = Int((point.x / width * CGFloat(data.days.count - 1)).rounded())
        return data.days[index].key
    }
    private func move(_ delta: Int) {
        guard !data.days.isEmpty else { return }
        let index = min(max(0, (selectedIndex ?? (delta > 0 ? -1 : data.days.count)) + delta), data.days.count - 1)
        DashboardMotion.withAnimation(DashboardMotion.disclosure, reduceMotion: reduceMotion) {
            inspection.pin(data.days[index].key)
        }
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

private func historyGridY(_ tick: Int, intervals: Int, topInset: CGFloat, chartHeight: CGFloat) -> CGFloat {
    topInset + chartHeight * CGFloat(tick) / CGFloat(max(1, intervals))
}

// Selection lives in a separate overlay so pointer motion does not rebuild the stacked annual paths.
private struct HistoryAreas: View {
    let data: UsageHistory
    let axis: HistoryAxisScale
    let topInset: CGFloat
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Canvas { context, size in
            let width = size.width
            let chartHeight = max(1, size.height - topInset)
            let labelColor = WorkspaceStyle.subtext.opacity(scheme == .dark ? 0.42 : 0.48)
            for tick in 0...axis.intervals {
                let y = historyGridY(tick, intervals: axis.intervals, topInset: topInset, chartHeight: chartHeight)
                var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: width, y: y))
                context.stroke(line, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
                if tick < axis.intervals, tick < axis.labels.count {
                    let label = context.resolve(
                        Text(axis.labels[tick])
                            .font(.system(size: 11, weight: .bold).monospacedDigit())
                            .foregroundStyle(labelColor)
                    )
                    context.draw(label, at: CGPoint(x: 0, y: y - 3), anchor: .bottomLeading)
                }
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
                            let point = CGPoint(x: data.position(of: i, width: width), y: topInset + chartHeight * (1 - (base[i] + (series.values[i] ?? 0)) / axis.maximum))
                            if i == start { path.move(to: point) } else { path.addLine(to: point) }
                        }
                        for i in (start..<end).reversed() { path.addLine(to: CGPoint(x: data.position(of: i, width: width), y: topInset + chartHeight * (1 - base[i] / axis.maximum))) }
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
