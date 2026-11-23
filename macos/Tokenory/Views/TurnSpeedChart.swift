// [INPUT]: Committed range, calendar-based turn distributions, and selected turn identity.
// [OUTPUT]: Speed boxes and sparse/outlier points with hover readouts and bucket selection.
// [POS]: Keeps pointer state local and uses the reporting calendar's time axis.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import SwiftUI
import Charts

struct TurnSpeedChart: View {
    private enum Target: Equatable {
        case bucket(start: Date, center: Date)
        case turn(AgentTurn)

        var time: Date {
            switch self {
            case .bucket(_, let center): center
            case .turn(let turn): turn.start
            }
        }
    }

    let data: TurnPresentation
    let range: DashboardDateSpan
    let animateRangeChanges: Bool
    let selected: AgentTurn?
    let selectedBucketStart: Date?
    let onSelect: (AgentTurn, Date?) -> Void
    @State private var hovered: Target?
    @State private var previousPresence: DashboardPlotPresence?
    @State private var reveal = 1.0
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let presence = DashboardPlotPresence(range: range, hasData: data.speedTimeline?.buckets.isEmpty == false)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("turns.trend")).font(.headline)
                Spacer()
                Text("tokens/s").font(.caption).foregroundStyle(.secondary)
            }
            if let timeline = data.speedTimeline, let domain = timeline.domain, !timeline.buckets.isEmpty {
                plot(timeline, domain: domain)
                    .frame(height: 190)
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

    private func plot(_ timeline: TurnSpeedTimeline, domain: ClosedRange<Date>) -> some View {
        let calendar = timeline.calendar
        let hourly = timeline.granularity == .hour
        let axisFormat = Date.FormatStyle(locale: Localization.locale, calendar: calendar, timeZone: calendar.timeZone)
        let spansYears = !calendar.isDate(domain.lowerBound, equalTo: domain.upperBound - 1, toGranularity: .year)
        let labelFormat: Date.FormatStyle
        if hourly {
            labelFormat = axisFormat.hour().minute()
        } else if spansYears {
            labelFormat = axisFormat.year(.twoDigits).month(.abbreviated).day()
        } else {
            labelFormat = axisFormat.month(.twoDigits).day(.twoDigits)
        }
        let axisValues: AxisMarkValues = timeline.granularity == .day
            ? .stride(by: .day, calendar: calendar) : .automatic(desiredCount: 4)
        return Chart {
            RuleMark(y: .value("tokens/s", 0.0)).foregroundStyle(.clear).accessibilityHidden(true)
        }
        .chartXScale(domain: domain, range: .plotDimension(startPadding: 5, endPadding: 5))
        .chartYScale(domain: 0...max(10, ceil(timeline.maxSpeed / 10) * 10),
                     range: .plotDimension(startPadding: 6, endPadding: 5))
        .chartXAxis {
            AxisMarks(preset: .aligned, values: axisValues) { value in
                if let date = value.as(Date.self), hourly || date < domain.upperBound {
                    let nearEnd = domain.upperBound.timeIntervalSince(date)
                        < domain.upperBound.timeIntervalSince(domain.lowerBound) * 0.06
                    AxisValueLabel(anchor: nearEnd ? .topTrailing : nil, collisionResolution: .greedy) {
                        Text(date.formatted(labelFormat))
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
        .chartOverlay { proxy in overlay(proxy, timeline: timeline) }
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

    private func overlay(_ proxy: ChartProxy, timeline: TurnSpeedTimeline) -> some View {
        GeometryReader { geometry in
            if let plot = proxy.plotFrame {
                let frame = geometry[plot]
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in draw(context, proxy: proxy, timeline: timeline) }
                        .frame(width: frame.width, height: frame.height)
                        .mask(alignment: .leading) { Rectangle().frame(width: frame.width * reveal) }
                        .offset(x: frame.minX, y: frame.minY)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location): hovered = target(at: location, frame: frame, proxy: proxy, timeline: timeline)
                            case .ended: hovered = nil
                            }
                        }
                        .onTapGesture { location in
                            let target = target(at: location, frame: frame, proxy: proxy, timeline: timeline)
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

    private func draw(_ context: GraphicsContext, proxy: ChartProxy, timeline: TurnSpeedTimeline) {
        let accent = WorkspaceStyle.localUsage
        let surface = WorkspaceStyle.surface(scheme)
        let highlightedBucket: Date?
        if case .bucket(let start, _) = hovered { highlightedBucket = start } else { highlightedBucket = selectedBucketStart }
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
        for bucket in timeline.buckets {
            if let stats = bucket.distribution,
               let start = proxy.position(forX: bucket.start), let end = proxy.position(forX: bucket.end),
               let center = proxy.position(forX: bucket.center),
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
                context.fill(box, with: .color(accent.opacity(bucket.start == highlightedBucket ? 0.68 : 0.38)))
                line(rect.minX + inset, median, rect.maxX - inset, median, color: .primary.opacity(0.85), width: 1.5)
            }
            for turn in bucket.visiblePoints { dot(turn, radius: 2.5, hollow: bucket.distribution != nil) }
        }
        if let selected { dot(selected, radius: 5, hollow: true); dot(selected, radius: 2, hollow: false) }
        if case .turn(let turn) = hovered, turn.id != selected?.id {
            dot(turn, radius: 5, hollow: true)
            dot(turn, radius: 2, hollow: false)
        }
    }

    private func target(at location: CGPoint, frame: CGRect, proxy: ChartProxy, timeline: TurnSpeedTimeline) -> Target? {
        guard frame.contains(location) else { return nil }
        let point = CGPoint(x: location.x - frame.minX, y: location.y - frame.minY)
        guard let date: Date = proxy.value(atX: point.x) else { return nil }
        let radius: CGFloat = 8
        let first: Date = proxy.value(atX: max(0, point.x - radius)) ?? date
        let last: Date = proxy.value(atX: min(frame.width, point.x + radius)) ?? date
        var closest: AgentTurn?
        var distance = radius
        for turn in timeline.points(in: first..<last) {
            guard let x = proxy.position(forX: turn.start), let y = proxy.position(forY: turn.speed) else { continue }
            let next = hypot(x - point.x, y - point.y)
            if next < distance {
                closest = turn
                distance = next
            }
        }
        if let closest { return .turn(closest) }
        guard let bucket = timeline.bucket(at: date), bucket.distribution != nil else { return nil }
        return .bucket(start: bucket.start, center: bucket.center)
    }

    private var targets: [Target] {
        (data.speedTimeline?.buckets ?? []).flatMap { bucket in
            let points = bucket.visiblePoints.map(Target.turn)
            let targets = bucket.distribution == nil ? points : [.bucket(start: bucket.start, center: bucket.center)] + points
            return targets.sorted { $0.time < $1.time }
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
        case .bucket(let start, _):
            if let representative = data.speedTimeline?.bucket(at: start)?.distribution?.representative {
                onSelect(representative, start)
            }
        case .turn(let turn): onSelect(turn, nil)
        }
    }

    private func readout(_ target: Target) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            switch target {
            case .bucket(let start, _):
                if let timeline = data.speedTimeline, let bucket = timeline.bucket(at: start), let stats = bucket.distribution {
                    let prefix = bucket.containsEstimates ? "≈ " : ""
                    Text(TurnFormat.speedBucket(bucket, granularity: timeline.granularity)).fontWeight(.semibold)
                    Text(LF("turns.count", bucket.turns.count)).foregroundStyle(.secondary)
                    Text(LF("turns.chart_middle", prefix + TurnFormat.number(stats.middle.lowerBound),
                            TurnFormat.number(stats.middle.upperBound)))
                    Text(LF("turns.chart_typical", prefix + TurnFormat.number(stats.median)))
                }
            case .turn(let turn):
                HStack(spacing: 6) {
                    Text(clientName(turn.client) + " · " + turn.project).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                    if let mode = turn.inferenceSpeed, mode.isFast {
                        FastModeMark(title: L("fast.title"), helpText: mode.fastHelp)
                    }
                }
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
