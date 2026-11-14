// [INPUT]: Chronologically sorted real turn observations and selected turn identity.
// [OUTPUT]: Monotone temporal curve, immediate pointer/keyboard readout and detail selection.
// [POS]: Isolates chart hover state from the page; never fills gaps with synthetic data.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import SwiftUI
import Charts

struct TurnSpeedChart: View {
    let data: TurnPresentation
    let selectedID: String?
    let onSelect: (AgentTurn) -> Void
    @State private var hovered: AgentTurn?
    @Environment(\.colorScheme) private var scheme
    private var dateFormat: Date.FormatStyle {
        Date.FormatStyle(locale: Localization.locale, calendar: Localization.reportingCalendar,
                         timeZone: Localization.reportingCalendar.timeZone).month(.twoDigits).day(.twoDigits).hour().minute()
    }
    private var domain: ClosedRange<Date> {
        let start = data.points.first?.start ?? Date()
        let end = data.points.last?.start ?? start
        return start == end ? start.addingTimeInterval(-60)...end.addingTimeInterval(60) : start...end
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("turns.trend")).font(.headline)
                Spacer()
                Text("tokens/s").font(.caption).foregroundStyle(.secondary)
            }.help(L("turns.chart_help"))
            if data.points.isEmpty {
                ContentUnavailableView(L("turns.empty"), systemImage: "chart.xyaxis.line").frame(height: 190)
            } else {
                plot.frame(height: 190)
            }
        }
        .onChange(of: data.points) { _, _ in hovered = nil }
    }

    private var marks: some View {
        Chart {
            ForEach(data.points) { turn in
                LineMark(x: .value("Time", turn.start), y: .value("tokens/s", turn.speed))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
                    .accessibilityHidden(true)
                if data.points.count <= 100 || hovered?.id == turn.id || selectedID == turn.id {
                    PointMark(x: .value("Time", turn.start), y: .value("tokens/s", turn.speed))
                        .foregroundStyle(Color.accentColor)
                        .symbolSize(selectedID == turn.id || hovered?.id == turn.id ? 30 : 12)
                        .accessibilityHidden(true)
                }
            }
            if let hovered {
                RuleMark(x: .value("Time", hovered.start))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .accessibilityHidden(true)
            }
        }
    }

    private var plot: some View {
        marks
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...max(10, ceil((data.points.map(\.speed).max() ?? 0) / 10) * 10))
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .automatic(desiredCount: 4)) { value in
                AxisValueLabel(collisionResolution: .greedy) {
                    if let date = value.as(Date.self) { Text(date.formatted(dateFormat)).font(.system(size: 10)).monospacedDigit() }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4])).foregroundStyle(.secondary.opacity(0.2))
                AxisValueLabel {
                    if let speed = value.as(Double.self) { Text(speed.formatted(.number.precision(.fractionLength(0)).locale(Localization.locale))).font(.system(size: 10)).monospacedDigit() }
                }
            }
        }
        .chartOverlay { proxy in overlay(proxy) }
        .focusable()
        .onKeyPress(.leftArrow) { move(-1); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
        .onKeyPress(.return) { if let hovered { onSelect(hovered) }; return .handled }
        .onKeyPress(.space) { if let hovered { onSelect(hovered) }; return .handled }
        .onKeyPress(.escape) { hovered = nil; return .handled }
        .accessibilityLabel(L("turns.trend"))
        .accessibilityHint(L("turns.chart_keyboard"))
        .accessibilityRepresentation {
            VStack {
                ForEach(data.points) { turn in
                    Button { onSelect(turn) } label: { readout(turn) }
                        .accessibilityElement(children: .combine)
                }
            }.accessibilityElement(children: .contain)
        }
    }

    private func overlay(_ proxy: ChartProxy) -> some View {
            GeometryReader { geometry in
                if let plot = proxy.plotFrame {
                    let frame = geometry[plot]
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location): updateHover(at: location, frame: frame, proxy: proxy)
                                case .ended: hovered = nil
                                }
                            }
                            .onTapGesture { location in
                                updateHover(at: location, frame: frame, proxy: proxy)
                                if let hovered { onSelect(hovered) }
                            }
                        if let hovered, let x = proxy.position(forX: hovered.start) {
                            readout(hovered)
                                .padding(12).frame(width: 246)
                                .background(WorkspaceStyle.surface(scheme), in: RoundedRectangle(cornerRadius: 8))
                                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) }
                                .offset(x: min(max(frame.minX + x - 123, 0), max(0, geometry.size.width - 246)), y: 2)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
    }

    private func updateHover(at location: CGPoint, frame: CGRect, proxy: ChartProxy) {
        guard frame.contains(location), let date: Date = proxy.value(atX: location.x - frame.minX) else { hovered = nil; return }
        let next = data.nearest(to: date)
        if next?.id != hovered?.id { hovered = next }
    }
    private func move(_ delta: Int) {
        guard !data.points.isEmpty else { return }
        let current = data.points.firstIndex { $0.id == hovered?.id } ?? (delta > 0 ? -1 : data.points.count)
        hovered = data.points[min(max(current + delta, 0), data.points.count - 1)]
    }
    private func readout(_ turn: AgentTurn) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(clientName(turn.client) + " · " + turn.project).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
            Text(TurnFormat.timestamp(turn.start)).foregroundStyle(.secondary)
            HStack { Text(L("turns.speed")); Spacer(); Text(LF("turns.speed_value", (turn.durationEstimated ? "≈ " : "") + TurnFormat.number(turn.speed))).monospacedDigit() }
            HStack { Text(L("turns.ttft")); Spacer(); Text(turn.ttftMs.map { LF("turns.seconds_value", TurnFormat.number(Double($0) / 1000)) } ?? "—").monospacedDigit() }
            HStack { Text(L("token.reasoning")); Spacer(); Text(turn.reasoningTokens.map { $0.formatted(.number.locale(Localization.locale)) } ?? "—").monospacedDigit() }
        }.font(.caption)
    }
}
