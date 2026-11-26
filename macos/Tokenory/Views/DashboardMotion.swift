// [INPUT]: 已显示的日期范围、格式化读数及其数值。
// [OUTPUT]: 大号读数静止与滚动时共用随包分发的等宽字体；与 HUD 共享进位轨迹的读数过渡；为面板图形提供范围切换曲线。
// [POS]: 统计窗口短时、静音的日期过渡。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import AppKit
import SwiftUI

struct DashboardDateSpan: Equatable {
    let from: String?
    let to: String?
}

enum DashboardMotion {
    static let tabDuration: TimeInterval = 0.20
    static let disclosureDuration: TimeInterval = 0.20
    static let paginationDuration: TimeInterval = 0.18
    static let panelDuration: TimeInterval = 0.20
    static let hoverDuration: TimeInterval = 0.12
    static let pressDuration: TimeInterval = 0.08
    static let stateDuration: TimeInterval = 0.15
    static let loadDuration: TimeInterval = 0.18
    static let growDuration: TimeInterval = 0.40
    static let lineRevealDuration: TimeInterval = 0.44
    static let hudShowDuration: TimeInterval = 0.16
    static let hudHideDuration: TimeInterval = 0.14

    static let tab = Animation.easeOut(duration: tabDuration)
    static let disclosure = Animation.easeOut(duration: disclosureDuration)
    static let pagination = Animation.easeOut(duration: paginationDuration)
    static let panel = Animation.easeOut(duration: panelDuration)
    static let hover = Animation.easeOut(duration: hoverDuration)
    static let calendarCell = Animation.spring(response: 0.36, dampingFraction: 0.82)
    static let press = Animation.easeOut(duration: pressDuration)
    static let state = Animation.easeOut(duration: stateDuration)
    static let load = Animation.easeOut(duration: loadDuration)
    static let grow = Animation.timingCurve(0.22, 0.72, 0.22, 1, duration: growDuration)
    static let lineReveal = Animation.easeInOut(duration: lineRevealDuration)
    static var rangeTimingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.22, 0.72, 0.22, 1)
    }

    static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    @discardableResult
    static func withAnimation<Result>(
        _ animation: Animation,
        reduceMotion: Bool,
        _ body: () throws -> Result
    ) rethrows -> Result {
        try SwiftUI.withAnimation(self.animation(animation, reduceMotion: reduceMotion), body)
    }
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
        case headline, callout, calloutMedium, caption2, displayNumber(CGFloat)

        @MainActor var font: Font {
            switch self {
            case .headline: .headline
            case .callout: .callout
            case .calloutMedium: .callout.weight(.medium)
            case .caption2: .caption2
            case .displayNumber(let size): DisplayNumberFont.font(size: size)
            }
        }

        @MainActor var drumFont: NSFont {
            switch self {
            case .headline: .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            case .callout: .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            case .calloutMedium: .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            case .caption2: .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            case .displayNumber(let size): DisplayNumberFont.native(size: size)
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

    private struct Glyph: Identifiable {
        enum ID: Hashable { case digit(Int), grouping(Int), literal(Character, Int) }
        let id: ID
        let char: Character
    }

    private static func drumDigit(_ character: Character) -> Int? {
        guard let ascii = character.asciiValue, (48...57).contains(ascii) else { return nil }
        return Int(ascii - 48)
    }

    private var glyphs: [Glyph] {
        let integer = text.prefix { $0 != "." }
        var place = integer.compactMap(Self.drumDigit).count
        var seen: [Character: Int] = [:]
        var groupingSeen: Set<Int> = []
        return text.map { ch in
            if Self.drumDigit(ch) != nil {
                place -= 1
                return Glyph(id: .digit(place), char: ch)
            }
            if ch == ",", place > 0, groupingSeen.insert(place).inserted {
                return Glyph(id: .grouping(place), char: ch)
            }
            let count = seen[ch, default: 0]
            seen[ch] = count + 1
            return Glyph(id: .literal(ch, count), char: ch)
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(glyphs) { glyph in
                if let digit = Self.drumDigit(glyph.char), !reduceMotion {
                    DigitDrum(digit: digit, reading: value, range: range)
                } else {
                    Text(verbatim: String(glyph.char))
                        .contentTransition(.opacity)
                }
            }
        }
        .font(style.font)
        .monospacedDigit()
        .foregroundColor(themed ? (secondary ? WorkspaceStyle.subtext : WorkspaceStyle.text) : nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: text))
    }

    private struct DigitDrum: View {
        let digit: Int
        let reading: Double?
        let range: DashboardDateSpan?
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var position: Double

        init(digit: Int, reading: Double?, range: DashboardDateSpan?) {
            self.digit = digit
            self.reading = reading
            self.range = range
            _position = State(initialValue: Double(digit))
        }

        private struct Reading: Equatable {
            let digit: Int
            let value: Double?
            let range: DashboardDateSpan?
        }

        var body: some View {
            // The invisible glyph sets both width and baseline in the caller's font.
            Text("0").hidden()
                .overlay {
                    Color.clear.modifier(DrumFaceModifier(position: position))
                }
                .clipped()
                .onChange(of: Reading(digit: digit, value: reading, range: range)) { old, new in
                    guard !reduceMotion,
                          let newRange = new.range, let oldRange = old.range, newRange != oldRange,
                          let oldValue = old.value, let newValue = new.value, oldValue != newValue else {
                        position = Double(new.digit)
                        return
                    }
                    let end = Int(position.rounded())
                    let forward = ((new.digit - end) % 10 + 10) % 10
                    let distance = newValue >= oldValue ? forward : (forward == 0 ? 0 : forward - 10)
                    withAnimation(DashboardMotion.grow) {
                        position += Double(distance)
                    }
                }
                .onChange(of: reduceMotion) { _, enabled in
                    if enabled { position = Double(digit) }
                }
        }

        private struct DrumFaceModifier: ViewModifier, Animatable {
            nonisolated var position: Double
            nonisolated var animatableData: Double {
                get { position }
                set { position = newValue }
            }

            func body(content: Content) -> some View {
                GeometryReader { box in
                    let index = Int(floor(position))
                    let offset = CGFloat(position - Double(index))
                    VStack(spacing: 0) {
                        Text(verbatim: String((index % 10 + 10) % 10)).frame(height: box.size.height)
                        Text(verbatim: String(((index + 1) % 10 + 10) % 10)).frame(height: box.size.height)
                    }
                    .offset(y: -offset * box.size.height)
                }
            }
        }
    }
}
