// [INPUT]: Plot-local device segments, cost curve, dots and committed date range.
// [OUTPUT]: Animated trend marks and the model history focus overlay.
// [POS]: AppKit drawing surface under the dashboard chart's hover controls.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import AppKit
import QuartzCore
import SwiftUI

struct ChartFocusShade: View {
    let plot: CGRect
    let focus: CGRect
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { context, _ in
            var shade = Path(plot)
            shade.addRect(focus)
            context.fill(shade, with: .color(WorkspaceStyle.surface(scheme).opacity(0.52)), style: FillStyle(eoFill: true))
            context.fill(Path(focus), with: .color(WorkspaceStyle.chartHighlight))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct DashboardChartMarks: NSViewRepresentable {
    struct Bar {
        let frame: CGRect
        let emphasized: Bool
        var otherDevice = false
    }

    struct Dot: Equatable {
        let center: CGPoint
        let diameter: CGFloat
    }

    let bars: [Bar]
    let series: [[CGPoint]]
    let dots: [Dot]
    let frameSize: CGSize
    let range: DashboardDateSpan
    let animateRangeChanges: Bool
    let takeEntrance: () -> Bool
    let barColor: NSColor
    let lineColor: NSColor
    var otherDeviceColor: NSColor? = nil

    func makeNSView(context: Context) -> PlotView { PlotView() }

    func updateNSView(_ view: PlotView, context: Context) { view.update(self) }

    final class PlotView: NSView {
        private let barContainer = CALayer()
        private let exitingBarContainer = CALayer()
        private let lineContainer = CALayer()
        private let line = CAShapeLayer()
        private var barLayers: [CALayer] = []
        private var dotLayers: [CALayer] = []
        private var rendered: DashboardChartMarks?
        private var renderedMorphPath: CGPath?
        private var revealID = 0

        init() {
            super.init(frame: .zero)
            // Use a layer-hosting view so the renderer owns the layer coordinate system.
            let root = CALayer()
            layer = root
            wantsLayer = true
            barContainer.masksToBounds = true
            exitingBarContainer.masksToBounds = true
            root.addSublayer(barContainer)
            root.addSublayer(exitingBarContainer)
            root.addSublayer(lineContainer)
            line.fillColor = nil
            line.lineWidth = 2
            line.lineJoin = .round
            line.lineCap = .round
            lineContainer.addSublayer(line)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateContentsScale()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            updateContentsScale()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            guard let rendered else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            updateColors(rendered)
            CATransaction.commit()
        }

        func update(_ marks: DashboardChartMarks) {
            guard marks.frameSize.width > 0, marks.frameSize.height > 0 else { return }
            let previous = rendered
            let growsOnMount = previous == nil && marks.takeEntrance()
            let animate = marks.animateRangeChanges
                && (previous.map { $0.range != marks.range } ?? growsOnMount)
            let heightChanged = previous?.frameSize.height != marks.frameSize.height

            CATransaction.begin()
            CATransaction.setDisableActions(true)

            if previous?.frameSize != marks.frameSize {
                let frame = CGRect(origin: .zero, size: marks.frameSize)
                barContainer.frame = frame
                exitingBarContainer.frame = frame
                lineContainer.frame = frame
                line.frame = frame
                if let mask = lineContainer.mask {
                    mask.bounds.size = CGSize(width: frame.width + 16, height: frame.height + 16)
                }
            }
            updateBars(marks, previous: previous, heightChanged: heightChanged, animate: animate)
            let previousMorphPath = renderedMorphPath
            let canMorphLine = animate && !growsOnMount && previousMorphPath != nil
                && marks.series.count == 1 && marks.series[0].count > 1
            let nextMorphPath = marks.series.count == 1 && marks.series[0].count > 1
                ? Self.resampledPath(marks.series[0], plotHeight: marks.frameSize.height)
                : nil

            if previous?.series != marks.series || heightChanged {
                let targetPath = Self.linePath(marks.series, plotHeight: marks.frameSize.height)
                if canMorphLine, let fromPath = (line.presentation()?.path ?? previousMorphPath), let toMorph = nextMorphPath {
                    lineContainer.mask = nil
                    line.removeAnimation(forKey: "range")
                    line.path = toMorph
                    let morph = Self.animation("path", from: fromPath, to: toMorph)
                    morph.duration = DashboardMotion.growDuration
                    morph.timingFunction = DashboardMotion.rangeTimingFunction
                    line.add(morph, forKey: "range")
                } else {
                    line.removeAnimation(forKey: "range")
                    line.path = targetPath
                }
            }
            renderedMorphPath = nextMorphPath

            if previous?.dots != marks.dots || heightChanged {
                updateDots(marks.dots, plotHeight: marks.frameSize.height, animate: animate)
            }
            updateColors(marks)

            if animate && !canMorphLine && (line.path?.isEmpty == false || !marks.dots.isEmpty) {
                revealLine(in: marks.frameSize)
            } else if !marks.animateRangeChanges || (animate && !canMorphLine) {
                lineContainer.mask = nil
            }

            rendered = marks
            CATransaction.commit()
        }

        private func updateBars(
            _ marks: DashboardChartMarks, previous: DashboardChartMarks?, heightChanged: Bool, animate: Bool
        ) {
            let count = marks.bars.count
            let timing = DashboardMotion.rangeTimingFunction
            if barLayers.count > count {
                let removed = Array(barLayers[count...])
                barLayers.removeSubrange(count...)
                for layer in removed {
                    layer.removeFromSuperlayer()
                    guard animate else { continue }
                    let snapshot = CALayer()
                    snapshot.anchorPoint = .zero
                    let live = layer.presentation() ?? layer
                    snapshot.bounds = live.bounds
                    snapshot.position = live.position
                    snapshot.cornerRadius = live.cornerRadius
                    snapshot.backgroundColor = live.backgroundColor
                    snapshot.opacity = 0
                    exitingBarContainer.addSublayer(snapshot)

                    let shrink = Self.animation("bounds.size.height", from: live.bounds.height, to: 0)
                    shrink.duration = DashboardMotion.growDuration * 0.65
                    shrink.timingFunction = timing
                    let fade = Self.animation("opacity", from: live.opacity, to: 0)
                    fade.duration = DashboardMotion.growDuration * 0.65
                    fade.timingFunction = timing
                    snapshot.bounds.size.height = 0
                    CATransaction.begin()
                    CATransaction.setCompletionBlock { snapshot.removeFromSuperlayer() }
                    snapshot.add(shrink, forKey: "exit.height")
                    snapshot.add(fade, forKey: "exit.opacity")
                    CATransaction.commit()
                }
            }
            let previousCount = barLayers.count
            while barLayers.count < count {
                let bar = CALayer()
                bar.anchorPoint = .zero
                barContainer.addSublayer(bar)
                barLayers.append(bar)
            }
            for (index, bar) in marks.bars.enumerated() {
                let layer = barLayers[index]
                if !marks.animateRangeChanges {
                    layer.removeAnimation(forKey: "range")
                    layer.removeAnimation(forKey: "range.position")
                    layer.removeAnimation(forKey: "range.width")
                    layer.removeAnimation(forKey: "range.opacity")
                }

                let isNew = index >= previousCount
                guard isNew || heightChanged || previous?.bars[index].frame != bar.frame else { continue }
                let target = CGRect(
                    x: bar.frame.minX, y: marks.frameSize.height - bar.frame.maxY,
                    width: bar.frame.width, height: bar.frame.height
                )
                let live = layer.presentation() ?? layer
                let previousHeight = isNew ? 0 : live.bounds.height
                let previousWidth = isNew ? target.width : live.bounds.width
                let previousPosition = isNew ? target.origin : live.position
                layer.removeAnimation(forKey: "range")
                layer.removeAnimation(forKey: "range.position")
                layer.removeAnimation(forKey: "range.width")
                layer.removeAnimation(forKey: "range.opacity")
                layer.bounds = CGRect(origin: .zero, size: target.size)
                layer.position = target.origin
                layer.cornerRadius = min(2, target.width / 2, target.height / 2)
                if animate {
                    if previousHeight != target.height {
                        let growth = Self.animation("bounds.size.height", from: previousHeight, to: target.height)
                        growth.duration = DashboardMotion.growDuration
                        growth.timingFunction = timing
                        layer.add(growth, forKey: "range")
                    }
                    if !isNew && previousPosition != target.origin {
                        let move = Self.animation("position", from: previousPosition, to: target.origin)
                        move.duration = DashboardMotion.growDuration
                        move.timingFunction = timing
                        layer.add(move, forKey: "range.position")
                    }
                    if !isNew && previousWidth != target.width {
                        let resize = Self.animation("bounds.size.width", from: previousWidth, to: target.width)
                        resize.duration = DashboardMotion.growDuration
                        resize.timingFunction = timing
                        layer.add(resize, forKey: "range.width")
                    }
                    if isNew && previous != nil {
                        let fade = Self.animation("opacity", from: 0, to: bar.emphasized ? 1 : 0.35)
                        fade.duration = DashboardMotion.growDuration * 0.7
                        fade.timingFunction = timing
                        layer.add(fade, forKey: "range.opacity")
                    }
                }
            }
        }

        private func updateDots(_ dots: [Dot], plotHeight: CGFloat, animate: Bool) {
            while dotLayers.count > dots.count { dotLayers.removeLast().removeFromSuperlayer() }
            let previousCount = dotLayers.count
            while dotLayers.count < dots.count {
                let dot = CALayer()
                lineContainer.addSublayer(dot)
                dotLayers.append(dot)
            }
            let timing = DashboardMotion.rangeTimingFunction
            for (index, (dot, layer)) in zip(dots, dotLayers).enumerated() {
                let radius = dot.diameter / 2
                let targetFrame = CGRect(
                    x: dot.center.x - radius, y: plotHeight - dot.center.y - radius,
                    width: dot.diameter, height: dot.diameter
                )
                let live = layer.presentation() ?? layer
                let isNew = index >= previousCount
                layer.removeAnimation(forKey: "range.position")
                layer.removeAnimation(forKey: "range.opacity")
                layer.frame = targetFrame
                layer.cornerRadius = radius
                if animate {
                    if !isNew {
                        let move = Self.animation("position", from: live.position, to: layer.position)
                        move.duration = DashboardMotion.growDuration
                        move.timingFunction = timing
                        layer.add(move, forKey: "range.position")
                    } else {
                        let fade = Self.animation("opacity", from: 0, to: 1)
                        fade.duration = DashboardMotion.growDuration * 0.75
                        fade.timingFunction = timing
                        layer.add(fade, forKey: "range.opacity")
                    }
                }
            }
        }

        private func updateColors(_ marks: DashboardChartMarks) {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let accent = marks.barColor.cgColor
                let other = (marks.otherDeviceColor ?? marks.barColor).cgColor
                let cost = marks.lineColor.cgColor
                for (bar, layer) in zip(marks.bars, barLayers) {
                    layer.backgroundColor = bar.otherDevice ? other : accent
                    layer.opacity = bar.emphasized ? 1 : 0.35
                }
                line.strokeColor = cost
                for dot in dotLayers { dot.backgroundColor = cost }
            }
        }

        private func updateContentsScale() {
            line.contentsScale = window?.backingScaleFactor ?? 1
        }

        private func revealLine(in size: CGSize) {
            let mask = CALayer()
            mask.backgroundColor = CGColor(gray: 1, alpha: 1)
            mask.anchorPoint = .zero
            mask.frame = CGRect(x: -8, y: -8, width: size.width + 16, height: size.height + 16)
            lineContainer.mask = mask

            revealID += 1
            let id = revealID
            CATransaction.setCompletionBlock { [weak self] in
                Task { @MainActor in
                    guard let self, self.revealID == id else { return }
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.lineContainer.mask = nil
                    CATransaction.commit()
                }
            }
            let sweep = Self.animation("transform.scale.x", from: 0, to: 1)
            sweep.duration = DashboardMotion.lineRevealDuration
            sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            mask.add(sweep, forKey: "range")
        }

        private static func animation(_ key: String, from: Any, to: Any) -> CABasicAnimation {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = from
            animation.toValue = to
            return animation
        }

        private static let morphSamples = 96

        private static func resampledPath(_ segment: [CGPoint], plotHeight: CGFloat) -> CGPath {
            let points = segment.map { CGPoint(x: $0.x, y: plotHeight - $0.y) }
            let path = CGMutablePath()
            guard points.count > 1 else { return path }
            let lastIndex = points.count - 1
            for sample in 0...Self.morphSamples {
                let position = CGFloat(sample) / CGFloat(Self.morphSamples) * CGFloat(lastIndex)
                let leftIndex = min(lastIndex, Int(floor(position)))
                let rightIndex = min(lastIndex, leftIndex + 1)
                let t = position - CGFloat(leftIndex)
                let blend = t * t * (3 - 2 * t)
                let a = points[leftIndex], b = points[rightIndex]
                let point = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * blend)
                if sample == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            return path
        }

        private static func linePath(_ series: [[CGPoint]], plotHeight: CGFloat) -> CGPath {
            let path = CGMutablePath()
            for segment in series where segment.count > 1 {
                // Use the same bottom-left layer coordinates for paths, bars, and dots.
                let points = segment.map { CGPoint(x: $0.x, y: plotHeight - $0.y) }
                let spans = zip(points, points.dropFirst()).map { $1.x - $0.x }
                let slopes = zip(zip(points, points.dropFirst()), spans).map { pair, span in
                    span > 0 ? (pair.1.y - pair.0.y) / span : 0
                }
                var tangents = [slopes[0]]
                for index in 1..<(points.count - 1) {
                    let left = slopes[index - 1]
                    let right = slopes[index]
                    // At an extremum, a horizontal tangent keeps the curve inside the data.
                    guard left != 0, right != 0, left.sign == right.sign else {
                        tangents.append(0)
                        continue
                    }
                    let leftWeight = 2 * spans[index] + spans[index - 1]
                    let rightWeight = spans[index] + 2 * spans[index - 1]
                    tangents.append((leftWeight + rightWeight) / (leftWeight / left + rightWeight / right))
                }
                tangents.append(slopes[slopes.count - 1])

                path.move(to: points[0])
                for index in spans.indices {
                    let start = points[index]
                    let end = points[index + 1]
                    let step = spans[index] / 3
                    path.addCurve(
                        to: end,
                        control1: CGPoint(x: start.x + step, y: start.y + step * tangents[index]),
                        control2: CGPoint(x: end.x - step, y: end.y - step * tangents[index + 1])
                    )
                }
            }
            return path
        }
    }
}
