// [INPUT]: Plot-local device segments, cost curve, dots and committed date range.
// [OUTPUT]: Core Animation marks with bounded bar growth and a horizontal line reveal.
// [POS]: AppKit drawing surface under the dashboard chart's hover controls.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import AppKit
import QuartzCore
import SwiftUI

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
        private let lineContainer = CALayer()
        private let line = CAShapeLayer()
        private var barLayers: [CALayer] = []
        private var dotLayers: [CALayer] = []
        private var rendered: DashboardChartMarks?
        private var revealID = 0

        init() {
            super.init(frame: .zero)
            // Use a layer-hosting view so the renderer owns the layer coordinate system.
            let root = CALayer()
            layer = root
            wantsLayer = true
            barContainer.masksToBounds = true
            root.addSublayer(barContainer)
            root.addSublayer(lineContainer)
            line.fillColor = nil
            line.lineWidth = 2
            line.lineJoin = .round
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
                lineContainer.frame = frame
                line.frame = frame
                if let mask = lineContainer.mask {
                    mask.bounds.size = CGSize(width: frame.width + 16, height: frame.height + 16)
                }
            }
            updateBars(marks, previous: previous, heightChanged: heightChanged, animate: animate)
            if previous?.series != marks.series || heightChanged {
                line.path = Self.linePath(marks.series, plotHeight: marks.frameSize.height)
            }
            if previous?.dots != marks.dots || heightChanged {
                updateDots(marks.dots, plotHeight: marks.frameSize.height)
            }
            updateColors(marks)

            if animate && (line.path?.isEmpty == false || !marks.dots.isEmpty) {
                revealLine(in: marks.frameSize)
            } else if !marks.animateRangeChanges || animate {
                lineContainer.mask = nil
            }

            rendered = marks
            CATransaction.commit()
        }

        private func updateBars(
            _ marks: DashboardChartMarks, previous: DashboardChartMarks?, heightChanged: Bool, animate: Bool
        ) {
            let count = marks.bars.count
            while barLayers.count > count { barLayers.removeLast().removeFromSuperlayer() }
            let previousCount = barLayers.count
            while barLayers.count < count {
                let bar = CALayer()
                bar.anchorPoint = .zero
                barContainer.addSublayer(bar)
                barLayers.append(bar)
            }
            for (index, bar) in marks.bars.enumerated() {
                let layer = barLayers[index]
                if !marks.animateRangeChanges { layer.removeAnimation(forKey: "range") }

                let isNew = index >= previousCount
                guard isNew || heightChanged || previous?.bars[index].frame != bar.frame else { continue }
                let target = CGRect(
                    x: bar.frame.minX, y: marks.frameSize.height - bar.frame.maxY,
                    width: bar.frame.width, height: bar.frame.height
                )
                // The new scale owns x, width, and the baseline as soon as it is
                // visible. Only height interpolates, so bars never sweep sideways.
                let previousHeight = isNew ? 0 : (layer.presentation() ?? layer).bounds.height
                layer.removeAnimation(forKey: "range")
                layer.bounds = CGRect(origin: .zero, size: target.size)
                layer.position = target.origin
                layer.cornerRadius = min(2, target.width / 2, target.height / 2)
                if animate && previousHeight != target.height {
                    let growth = Self.animation("bounds.size.height", from: previousHeight, to: target.height)
                    growth.duration = 0.34
                    growth.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    layer.add(growth, forKey: "range")
                }
            }
        }

        private func updateDots(_ dots: [Dot], plotHeight: CGFloat) {
            while dotLayers.count > dots.count { dotLayers.removeLast().removeFromSuperlayer() }
            while dotLayers.count < dots.count {
                let dot = CALayer()
                lineContainer.addSublayer(dot)
                dotLayers.append(dot)
            }
            for (dot, layer) in zip(dots, dotLayers) {
                let radius = dot.diameter / 2
                layer.frame = CGRect(
                    x: dot.center.x - radius, y: plotHeight - dot.center.y - radius,
                    width: dot.diameter, height: dot.diameter
                )
                layer.cornerRadius = radius
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
            sweep.duration = 0.44
            sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            mask.add(sweep, forKey: "range")
        }

        private static func animation(_ key: String, from: Any, to: Any) -> CABasicAnimation {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = from
            animation.toValue = to
            return animation
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
