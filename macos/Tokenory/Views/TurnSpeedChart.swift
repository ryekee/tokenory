// [INPUT]: Committed range, hourly turn distributions, and selected turn identity.
// [OUTPUT]: Hourly speed boxes and sparse/outlier points with hover readouts and list selection.
// [POS]: Keeps pointer state local and uses the reporting calendar's time axis.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import SwiftUI
import Charts

struct TurnSpeedChart: View {
    private enum Target: Equatable {
        case hour(Date)
        case turn(AgentTurn)

        var time: Date {
            switch self {
            case .hour(let start): start.addingTimeInterval(1800)
            case .turn(let turn): turn.start
            }
        }
    }

    let data: TurnPresentation
    let range: DashboardDateSpan
    let animateRangeChanges: Bool
    let selected: AgentTurn?
    let selectedHour: Date?
    let onSelect: (AgentTurn, Date?) -> Void
    @State private var hovered: Target?
    @State private var previousPresence: DashboardPlotPresence?
    @State private var reveal = 1.0
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var calendar: Calendar { Localization.reportingCalendar }
    private var clockFormat: Date.FormatStyle {
        Date.FormatStyle(locale: Localization.locale, calendar: calendar, timeZone: calendar.timeZone).hour().minute()
    }

    var body: some View {
        let presence = DashboardPlotPresence(range: range, hasData: !data.points.isEmpty)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("turns.trend")).font(.headline)
                Spacer()
                Text("tokens/s").font(.caption).foregroundStyle(.secondary)
            }
            if let first = data.orderedSpeedHours.first, let last = data.orderedSpeedHours.last {
                plot(domain: first.start...last.end, singleDay: calendar.isDate(first.start, inSameDayAs: last.start))
                    .frame(height: 190)
            } else {
                ContentUnavailableView(L("turns.empty"), systemImage: "chart.xyaxis.line").frame(height: 190)
            }
        }
        .onChange(of: presence, initial: true) { _, next in
            let shouldReveal = animateRangeChanges && !reduceMotion && next.hasData
                && previousPresence.map { $0.range != next.range } == true
            previousPresence = next
            hovered = nil
            guard shouldReveal else { reveal = 1; return }
            reveal = 0
            withAnimation(DashboardMotion.grow) { reveal = 1 }
        }
        .onChange(of: data.points) { _, _ in hovered = nil }
    }

    private func plot(domain: ClosedRange<Date>, singleDay: Bool) -> some View {
        let maxSpeed = data.points.map(\.speed).max() ?? 0
        return Chart {
            RuleMark(y: .value("tokens/s", 0.0)).foregroundStyle(.clear).accessibilityHidden(true)
        }
        .chartXScale(domain: domain, range: .plotDimension(startPadding: 5, endPadding: 5))
        .chartYScale(domain: 0...max(10, ceil(maxSpeed / 10) * 10),
                     range: .plotDimension(startPadding: 6, endPadding: 5))
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .automatic(desiredCount: 4)) { value in
                if let date = value.as(Date.self) {
                    let nearEnd = domain.upperBound.timeIntervalSince(date)
                        < domain.upperBound.timeIntervalSince(domain.lowerBound) * 0.06
                    AxisValueLabel(anchor: nearEnd ? .topTrailing : nil, collisionResolution: .greedy) {
                        Text(singleDay ? date.formatted(clockFormat) : TurnFormat.timestamp(date))
                            .font(.system(size: 10)).monospacedDigit()
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(.secondary.opacity(0.2))
                AxisValueLabel {
                    if let speed = value.as(Double.self) {
                        Text(speed.formatted(.number.precision(.fractionLength(0)).locale(Localization.locale)))
                            .font(.system(size: 10)).monospacedDigit().frame(minWidth: 30, alignment: .trailing)
                    }
                }
            }
        }
        .chartOverlay { proxy in overlay(proxy) }
        .focusable()
        .onKeyPress(.leftArrow) { move(-1); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
        .onKeyPress(.return) { if let hovered { select(hovered) }; return .handled }
        .onKeyPress(.space) { if let hovered { select(hovered) }; return .handled }
        .onKeyPress(.escape) { hovered = nil; return .handled }
        .accessibilityLabel(L("turns.trend"))
        .accessibilityHint(L("turns.chart_keyboard"))
        .accessibilityRepresentation {
            VStack {
                ForEach(Array(targets.enumerated()), id: \.offset) { _, target in
                    Button { select(target) } label: { readout(target) }
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
                    Canvas { context, _ in draw(context, proxy: proxy) }
                        .frame(width: frame.width, height: frame.height)
                        .mask(alignment: .leading) { Rectangle().frame(width: frame.width * reveal) }
                        .offset(x: frame.minX, y: frame.minY)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location): hovered = target(at: location, frame: frame, proxy: proxy)
                            case .ended: hovered = nil
                            }
                        }
                        .onTapGesture { location in
                            let target = target(at: location, frame: frame, proxy: proxy)
                            hovered = target
                            if let target { select(target) }
                        }
                    if let hovered, let x = proxy.position(forX: hovered.time) {
                        let width: CGFloat = 208
                        let anchor = frame.minX + x
                        let left = anchor + width + 12 <= geometry.size.width ? anchor + 12 : anchor - width - 12
                        readout(hovered)
                            .padding(10).frame(width: width, alignment: .leading)
                            .background(WorkspaceStyle.surface(scheme), in: RoundedRectangle(cornerRadius: 8))
                            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.14), lineWidth: 0.5) }
                            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                            .offset(x: max(0, min(left, geometry.size.width - width)), y: frame.minY + 4)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private func draw(_ context: GraphicsContext, proxy: ChartProxy) {
        let accent = Color.accentColor
        let surface = WorkspaceStyle.surface(scheme)
        let highlightHour: Date?
        if case .hour(let start) = hovered { highlightHour = start } else { highlightHour = selectedHour }
        func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, color: Color, width: CGFloat) {
            var path = Path()
            path.move(to: CGPoint(x: x1, y: y1))
            path.addLine(to: CGPoint(x: x2, y: y2))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
        func dot(_ turn: AgentTurn, radius: CGFloat, hollow: Bool) {
            guard let x = proxy.position(forX: turn.start), let y = proxy.position(forY: turn.speed) else { return }
            let path = Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            context.fill(path, with: .color(hollow ? surface : accent))
            if hollow { context.stroke(path, with: .color(accent), lineWidth: 1.25) }
        }
        for hour in data.orderedSpeedHours {
            if let stats = hour.distribution,
               let start = proxy.position(forX: hour.start), let end = proxy.position(forX: hour.end),
               let center = proxy.position(forX: hour.center),
               let lower = proxy.position(forY: stats.middle.lowerBound), let upper = proxy.position(forY: stats.middle.upperBound),
               let median = proxy.position(forY: stats.median),
               let low = proxy.position(forY: stats.whiskers.lowerBound), let high = proxy.position(forY: stats.whiskers.upperBound) {
                let width = min(24, max(1, (end - start) * 0.62))
                let height = max(2, lower - upper)
                let rect = CGRect(x: center - width / 2, y: (lower + upper - height) / 2, width: width, height: height)
                let inset = width * 0.16
                line(center, low, center, lower, color: accent.opacity(0.55), width: 0.8)
                line(center, upper, center, high, color: accent.opacity(0.55), width: 0.8)
                let box = Path(roundedRect: rect, cornerRadius: min(4, width / 2))
                context.fill(box, with: .color(accent.opacity(hour.start == highlightHour ? 0.68 : 0.38)))
                line(rect.minX + inset, median, rect.maxX - inset, median, color: .primary.opacity(0.85), width: 1.5)
            }
            for turn in hour.visiblePoints { dot(turn, radius: 2.5, hollow: hour.distribution != nil) }
        }
        if let selected { dot(selected, radius: 5, hollow: true); dot(selected, radius: 2, hollow: false) }
        if case .turn(let turn) = hovered, turn.id != selected?.id {
            dot(turn, radius: 5, hollow: true)
            dot(turn, radius: 2, hollow: false)
        }
    }

    private func target(at location: CGPoint, frame: CGRect, proxy: ChartProxy) -> Target? {
        guard frame.contains(location) else { return nil }
        let point = CGPoint(x: location.x - frame.minX, y: location.y - frame.minY)
        guard let date: Date = proxy.value(atX: point.x) else { return nil }
        let start = TurnSpeedHour.start(containing: date, calendar: calendar)
        let nearby = [-3600.0, 0, 3600].flatMap { data.speedHours[start.addingTimeInterval($0)]?.visiblePoints ?? [] }
        var closest: AgentTurn?
        var distance = 8.0
        for turn in nearby {
            guard let x = proxy.position(forX: turn.start), let y = proxy.position(forY: turn.speed) else { continue }
            let next = hypot(x - point.x, y - point.y)
            if next < distance {
                closest = turn
                distance = next
            }
        }
        if let closest { return .turn(closest) }
        return data.speedHours[start]?.distribution == nil ? nil : .hour(start)
    }

    private var targets: [Target] {
        data.orderedSpeedHours.flatMap { hour in
            let points = hour.visiblePoints.map(Target.turn)
            return (hour.distribution == nil ? points : [.hour(hour.start)] + points).sorted { $0.time < $1.time }
        }
    }

    private func move(_ delta: Int) {
        let targets = targets
        guard !targets.isEmpty else { return }
        let index = hovered.flatMap { targets.firstIndex(of: $0) } ?? (delta > 0 ? -1 : targets.count)
        hovered = targets[min(max(index + delta, 0), targets.count - 1)]
    }

    private func select(_ target: Target) {
        switch target {
        case .hour(let start):
            if let representative = data.speedHours[start]?.distribution?.representative {
                onSelect(representative, start)
            }
        case .turn(let turn): onSelect(turn, nil)
        }
    }

    private func readout(_ target: Target) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            switch target {
            case .hour(let start):
                if let hour = data.speedHours[start], let stats = hour.distribution {
                    let prefix = hour.containsEstimates ? "≈ " : ""
                    Text("\(TurnFormat.timestamp(start))–\(hour.end.formatted(clockFormat))").fontWeight(.semibold)
                    Text(LF("turns.count", hour.turns.count)).foregroundStyle(.secondary)
                    Text(LF("turns.chart_middle", prefix + TurnFormat.number(stats.middle.lowerBound),
                            TurnFormat.number(stats.middle.upperBound)))
                    Text(LF("turns.chart_typical", prefix + TurnFormat.number(stats.median)))
                }
            case .turn(let turn):
                Text(clientName(turn.client) + " · " + turn.project).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                Text(TurnFormat.timestamp(turn.start)).foregroundStyle(.secondary)
                readoutRow("turns.speed", LF("turns.speed_value",
                                             (turn.durationEstimated ? "≈ " : "") + TurnFormat.number(turn.speed)))
                readoutRow("turns.ttft", turn.ttftMs.map { LF("turns.seconds_value", TurnFormat.number(Double($0) / 1000)) } ?? "—")
                readoutRow("token.reasoning", turn.reasoningTokens.map { $0.formatted(.number.locale(Localization.locale)) } ?? "—")
            }
        }.font(.caption).monospacedDigit()
    }

    private func readoutRow(_ key: String, _ value: String) -> some View {
        HStack { Text(L(key)); Spacer(); Text(value) }
    }
}
