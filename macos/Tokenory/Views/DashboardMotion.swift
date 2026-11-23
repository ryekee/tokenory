// [INPUT]: 已显示的日期范围、格式化读数及其数值。
// [OUTPUT]: 与 HUD 共享进位轨迹的读数过渡；为面板图形提供范围切换曲线。
// [POS]: 统计窗口短时、静音的日期过渡。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import AppKit
import SwiftUI

struct DashboardDateSpan: Equatable {
    let from: String?
    let to: String?
}

enum DashboardMotion {
    static let grow = Animation.easeOut(duration: 0.34)
}

struct DashboardPlotPresence: Equatable {
    let range: DashboardDateSpan
    let hasData: Bool

    func growsOnMount(after previous: Self?) -> Bool {
        hasData && previous.map { !$0.hasData && $0.range != range } == true
    }
}

final class DashboardPlotTransition {
    private var previous: DashboardPlotPresence?
    private var entering: DashboardDateSpan?

    func takeEntrance(_ next: DashboardPlotPresence) -> Bool {
        commit(next)
        defer { entering = nil }
        return entering == next.range
    }

    func commit(_ next: DashboardPlotPresence) {
        guard previous != next else { return }
        entering = next.growsOnMount(after: previous) ? next.range : nil
        previous = next
    }
}

struct OdometerPosition: Equatable {
    let whole: Int64
    let fraction: Double

    init(whole: Int64, fraction: Double = 0) {
        self.whole = whole
        self.fraction = fraction
    }

    static func between(from: Int64, to: Int64, progress: Double) -> Self {
        Self(whole: from).moving(toward: to, progress: progress)
    }

    private func moving(toward target: Int64, progress: Double) -> Self {
        if progress <= 0 { return self }
        if progress >= 1 { return Self(whole: target) }
        // Keep the starting integer separate so low digits remain exact above 2^53.
        let distance = Double(target - whole) - fraction
        let offset = fraction + distance * progress
        guard let steps = Int64(exactly: offset.rounded(.down)) else { return Self(whole: target) }
        let (value, overflow) = whole.addingReportingOverflow(steps)
        guard !overflow, value >= 0 else { return Self(whole: target) }
        if (distance > 0 && value >= target) || (distance < 0 && value < target) {
            return Self(whole: target)
        }
        return Self(whole: value, fraction: offset - Double(steps))
    }

    // A higher wheel moves only in the unit interval where all lower places
    // go through their carry. Reversing the same path produces a true borrow.
    func digit(at place: Int64) -> Double {
        Double(whole / place % 10) + carry(at: place)
    }

    func wheel(at place: Int64, relativeTo start: Int64) -> Double {
        let turns = start / place
        return Double(whole / place - turns) + Double(turns % 10) + carry(at: place)
    }

    private func carry(at place: Int64) -> Double {
        whole % place == place - 1 ? fraction : 0
    }
}

struct DashboardOdometer {
    enum Column: Equatable {
        case literal(Character)
        case wheel(place: Int64)
    }

    private struct Reading {
        let prefix: Substring
        let suffix: Substring
        let whole: String
        let fraction: Substring
        let groupsThousands: Bool

        init?(_ text: String) {
            guard let first = text.firstIndex(where: Self.isDigit),
                  let last = text.lastIndex(where: Self.isDigit) else { return nil }
            let parts = text[first...last].split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count <= 2, let integer = parts.first else { return nil }
            let groups = integer.split(separator: ",", omittingEmptySubsequences: false)
            guard groups.allSatisfy({ !$0.isEmpty && $0.allSatisfy(Self.isDigit) }),
                  groups.count == 1 || (groups[0].count <= 3 && groups.dropFirst().allSatisfy { $0.count == 3 })
            else { return nil }
            let fraction = parts.count == 2 ? parts[1] : ""
            guard fraction.allSatisfy(Self.isDigit) else { return nil }
            self.prefix = text[..<first]
            self.suffix = text[text.index(after: last)...]
            self.whole = groups.joined()
            self.fraction = fraction
            self.groupsThousands = groups.count > 1
        }

        func scaled(to precision: Int) -> Int64? {
            Int64(whole + fraction + String(repeating: "0", count: precision - fraction.count))
        }

        static func isDigit(_ character: Character) -> Bool {
            // Chinese compact units such as 万 also have a Unicode numeric value.
            character.asciiValue.map { (48...57).contains($0) } == true
        }
    }

    static let maximumDirectTicks: Int64 = 10
    let start: Int64
    let rollStart: Int64
    let target: Int64
    let startText: String
    let targetText: String
    let columns: [Column]

    var ticks: Int64 { abs(target - rollStart) }

    init?(from: String, to: String) {
        guard let previous = Reading(from), let next = Reading(to),
              previous.prefix == next.prefix, previous.suffix == next.suffix,
              !previous.prefix.contains("-"), !previous.prefix.contains("−") else { return nil }
        let precision = max(previous.fraction.count, next.fraction.count)
        let wholeDigits = max(previous.whole.count, next.whole.count)
        let digitCount = wholeDigits + precision
        guard digitCount <= 19, let start = previous.scaled(to: precision),
              let target = next.scaled(to: precision), start != target else { return nil }

        // Keep long range changes short by rolling only the last eight teeth.
        let rollStart = abs(target - start) <= Self.maximumDirectTicks ? start : target + (target > start ? -8 : 8)
        let grouping = previous.groupsThousands || next.groupsThousands
        func formatted(_ value: Int64) -> String {
            let digits = String(value)
            let padded = String(repeating: "0", count: digitCount - digits.count) + digits
            var result = String(next.prefix)
            for (index, digit) in padded.enumerated() {
                let remaining = wholeDigits - index
                if index > 0 && remaining == 0 { result.append(".") }
                if index > 0 && remaining > 0 && grouping && remaining.isMultiple(of: 3) { result.append(",") }
                result.append(digit)
            }
            return result + next.suffix
        }

        let targetText = formatted(target)
        var place: Int64 = 1
        var columns: [Column] = []
        for character in targetText.dropFirst(next.prefix.count).dropLast(next.suffix.count).reversed() {
            if Reading.isDigit(character) {
                columns.append(.wheel(place: place))
                if place != 1_000_000_000_000_000_000 { place *= 10 }
            } else {
                columns.append(.literal(character))
            }
        }
        self.start = start
        self.rollStart = rollStart
        self.target = target
        self.startText = formatted(rollStart)
        self.targetText = targetText
        self.columns = next.prefix.map(Column.literal) + columns.reversed() + next.suffix.map(Column.literal)
    }

    func position(at progress: Double) -> OdometerPosition {
        .between(from: rollStart, to: target, progress: progress)
    }
}

struct DashboardRollingValue: View {
    enum Style {
        case headline, callout, caption2, semibold(CGFloat)

        var font: Font {
            switch self {
            case .headline: .headline
            case .callout: .callout
            case .caption2: .caption2
            case .semibold(let size): .system(size: size, weight: .semibold)
            }
        }

        var drumFont: NSFont {
            switch self {
            case .headline: .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            case .callout: .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            case .caption2: .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            case .semibold(let size): .monospacedDigitSystemFont(ofSize: size, weight: .semibold)
            }
        }
    }

    let text: String
    let value: Double?
    let range: DashboardDateSpan?
    let style: Style
    var secondary = false
    var themed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var roll: Roll?

    private struct Reading: Equatable {
        let text: String
        let value: Double?
        let range: DashboardDateSpan?
    }

    var body: some View {
        ZStack(alignment: .leading) {
            styledText(text).opacity(roll == nil ? 1 : 0)
            if let roll {
                styledText(roll.odometer?.targetText ?? roll.from)
                    .hidden()
                    .accessibilityHidden(true)
            }
        }
            .overlay(alignment: .leading) {
                if let roll {
                    Playback(roll: roll, font: style.drumFont, color: playbackColor) {
                        if self.roll?.id == roll.id { self.roll = nil }
                    }
                    .id(roll.id)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .accessibilityRepresentation { Text(text) }
            .onChange(of: Reading(text: text, value: value, range: range)) { old, new in
                if old.range == new.range && old.text == new.text { return }
                guard !reduceMotion, let range = new.range, let oldRange = old.range, range != oldRange,
                      old.value != nil, new.value != nil, old.text != new.text else {
                    roll = nil
                    return
                }
                roll = Roll(from: old.text, to: new.text)
            }
            .onChange(of: reduceMotion) { _, enabled in if enabled { roll = nil } }
    }

    private func styledText(_ string: String) -> some View {
        Text(string).font(style.font).monospacedDigit()
            .foregroundColor(themed ? (secondary ? WorkspaceStyle.subtext : WorkspaceStyle.text) : nil)
    }

    private var playbackColor: NSColor {
        if themed { return NSColor(secondary ? WorkspaceStyle.subtext : WorkspaceStyle.text) }
        return secondary ? .secondaryLabelColor : .labelColor
    }

    private struct Roll {
        let id = UUID()
        let from: String
        let to: String
        let odometer: DashboardOdometer?

        init(from: String, to: String) {
            self.from = from
            self.to = to
            self.odometer = DashboardOdometer(from: from, to: to)
        }
    }

    private struct Playback: NSViewRepresentable {
        let roll: Roll
        let font: NSFont
        let color: NSColor
        let finished: () -> Void
        func makeNSView(context: Context) -> DrumView {
            DrumView(roll: roll, font: font, color: color, finished: finished)
        }
        func updateNSView(_ view: DrumView, context: Context) {}
    }

    private final class DrumView: NSView {
        private final class DigitAtlas {
            let image: CGImage
            let width: CGFloat

            init(image: CGImage, width: CGFloat) {
                self.image = image
                self.width = width
            }
        }

        private static let curve = (0...96).map { HUDRoll.curve(Double($0) / 96).progress }
        private static let atlases: NSCache<NSString, DigitAtlas> = {
            let cache = NSCache<NSString, DigitAtlas>()
            cache.totalCostLimit = 4 * 1024 * 1024
            return cache
        }()
        // A wheel starts within the first ten rows and travels at most this many extra teeth.
        private static let atlasRows = 10 + Int(DashboardOdometer.maximumDirectTicks)
        private let roll: Roll
        private let font: NSFont
        private let color: NSColor
        private let finished: () -> Void
        private var started = false
        override var isFlipped: Bool { true }

        init(roll: Roll, font: NSFont, color: NSColor, finished: @escaping () -> Void) {
            self.roll = roll; self.font = font; self.color = color; self.finished = finished
            super.init(frame: .zero)
            wantsLayer = true
            layerContentsRedrawPolicy = .onSetNeedsDisplay
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func layout() {
            super.layout()
            guard !started, let layer, bounds.width > 0, bounds.height > 0 else { return }
            started = true
            effectiveAppearance.performAsCurrentDrawingAppearance {
                mountStrips(in: layer)
            }
        }

        private func mountStrips(in layer: CALayer) {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let scale = window?.backingScaleFactor ?? 2
            let height = bounds.height
            let rowHeight = font.ascender - font.descender + font.leading
            let textY = ((height - rowHeight) * 0.5 * scale).rounded() / scale

            func glyph(_ string: String, width: CGFloat) -> CATextLayer {
                let text = CATextLayer()
                text.string = NSAttributedString(string: string, attributes: attributes)
                text.contentsScale = scale
                text.frame = CGRect(x: 0, y: textY, width: width, height: rowHeight.rounded(.up))
                return text
            }

            func fittedBand(width: CGFloat) -> CALayer {
                let band = CALayer()
                band.anchorPoint = .zero
                band.frame = CGRect(x: 0, y: 0, width: width, height: height)
                band.setAffineTransform(CGAffineTransform(scaleX: min(1, bounds.width / max(1, width)), y: 1))
                layer.addSublayer(band)
                return band
            }

            let now = CACurrentMediaTime()
            func fadeLabel(_ string: String, from: Float, to: Float, delay: TimeInterval, duration: TimeInterval) {
                let width = ceil((string as NSString).size(withAttributes: attributes).width)
                let band = fittedBand(width: width)
                band.addSublayer(glyph(string, width: width))
                band.opacity = to
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = from
                fade.toValue = to
                fade.beginTime = band.convertTime(now, from: nil) + delay
                fade.duration = duration
                fade.fillMode = .backwards
                band.add(fade, forKey: "fade")
            }

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock { [weak self] in
                Task { @MainActor in self?.finished() }
            }
            defer { CATransaction.commit() }
            layer.isGeometryFlipped = true
            guard let odometer = roll.odometer,
                  let atlas = digitAtlas(height: height, scale: scale, attributes: attributes) else {
                fadeLabel(roll.from, from: 1, to: 0, delay: 0, duration: 0.18)
                fadeLabel(roll.to, from: 0, to: 1, delay: 0, duration: 0.18)
                return
            }

            let widths = odometer.columns.map { column -> CGFloat in
                switch column {
                case .literal(let character): return (String(character) as NSString).size(withAttributes: attributes).width
                case .wheel: return atlas.width
                }
            }
            let band = fittedBand(width: widths.reduce(0, +))
            let intro = roll.from == odometer.startText ? 0 : 0.14
            // The HUD curve peaks at 2.083× average speed. Cap the peak at 18 teeth/s.
            let duration = max(0.46, Double(odometer.ticks) * 2.0834 / 18)
            let outro = roll.to == odometer.targetText ? 0 : 0.12
            let total = intro + duration + outro
            if intro > 0 || outro > 0 {
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = (intro > 0 ? [0] : []) + [1, 1] + (outro > 0 ? [0] : [])
                let times = (intro > 0 ? [0.0] : []) + [intro / total, (intro + duration) / total] + (outro > 0 ? [1.0] : [])
                fade.keyTimes = times.map { NSNumber(value: $0) }
                fade.beginTime = band.convertTime(now, from: nil)
                fade.duration = total
                band.opacity = outro > 0 ? 0 : 1
                band.add(fade, forKey: "fade")
            }

            let positions = Self.curve.map { odometer.position(at: $0) }
            var x: CGFloat = 0
            for (column, width) in zip(odometer.columns, widths) {
                let cell = CALayer()
                cell.frame = CGRect(x: x, y: 0, width: width, height: height)
                cell.masksToBounds = true
                band.addSublayer(cell)
                x += width
                switch column {
                case .literal(let character):
                    cell.addSublayer(glyph(String(character), width: width))
                case .wheel(let place):
                    let first = positions[0].wheel(at: place, relativeTo: odometer.rollStart)
                    let last = positions[positions.count - 1].wheel(at: place, relativeTo: odometer.rollStart)
                    let atlasOrigin = floor(min(first, last) / 10) * 10
                    let strip = CALayer()
                    strip.anchorPoint = .zero
                    strip.frame = CGRect(x: 0, y: -(last - atlasOrigin) * height,
                                         width: width, height: CGFloat(Self.atlasRows) * height)
                    strip.contents = atlas.image
                    strip.contentsScale = scale
                    cell.addSublayer(strip)
                    guard first != last else { continue }
                    let slide = CAKeyframeAnimation(keyPath: "position.y")
                    slide.values = positions.map { -($0.wheel(at: place, relativeTo: odometer.rollStart) - atlasOrigin) * height }
                    slide.beginTime = strip.convertTime(now, from: nil) + intro
                    slide.duration = duration
                    slide.fillMode = .backwards
                    strip.add(slide, forKey: "roll")
                }
            }
            if intro > 0 { fadeLabel(roll.from, from: 1, to: 0, delay: 0, duration: intro) }
            if outro > 0 { fadeLabel(roll.to, from: 0, to: 1, delay: intro + duration, duration: outro) }
        }

        private func digitAtlas(height: CGFloat, scale: CGFloat,
                                attributes: [NSAttributedString.Key: Any]) -> DigitAtlas? {
            let key = "\(font.fontName)|\(font.pointSize)|\(height)|\(scale)|\(effectiveAppearance.name.rawValue)|\(color)" as NSString
            if let atlas = Self.atlases.object(forKey: key) { return atlas }
            let width = ("0" as NSString).size(withAttributes: attributes).width
            let stripHeight = height * CGFloat(Self.atlasRows)
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(ceil(width * scale)), pixelsHigh: Int(ceil(stripHeight * scale)),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: scale, y: scale)
            let textHeight = ("0" as NSString).size(withAttributes: attributes).height
            let inset = ((height - textHeight) * 0.5 * scale).rounded() / scale
            for row in 0..<Self.atlasRows {
                let y = CGFloat(Self.atlasRows - 1 - row) * height + inset
                (String(row % 10) as NSString).draw(at: CGPoint(x: 0, y: y), withAttributes: attributes)
            }
            NSGraphicsContext.restoreGraphicsState()
            guard let image = bitmap.cgImage else { return nil }
            let atlas = DigitAtlas(image: image, width: width)
            Self.atlases.setObject(atlas, forKey: key, cost: bitmap.bytesPerRow * bitmap.pixelsHigh)
            return atlas
        }
    }
}
