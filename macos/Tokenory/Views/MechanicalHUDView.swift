// [INPUT]: Today's real ledger summary, persisted HUD preferences, accessibility settings, and whether the panel is on the active Space.
// [OUTPUT]: Half-size orange mechanical counter with snapshot-consistent rolling and sound.
// [POS]: Floating panel content; no dashboard filters or simulated increments.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import AppKit
import SwiftUI

struct MechanicalHUDView: View {
    static let windowSize = CGSize(width: 220, height: 92)
    let canPlaySound: () -> Bool
    @Environment(UsageStore.self) private var store
    @Environment(HUDPreferences.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("appLanguage") private var language = AppLanguage.system.rawValue
    @State private var dayClock = 0
    @State private var animator = HUDAnimator()

    private var reading: HUDReading {
        HUDReading(day: (store.todayDay ?? LocalUsageDay(now: Date()).day) + ":" + (store.todayTimeZone ?? TimeZone.autoupdatingCurrent.identifier), metric: preferences.metric,
                   summary: store.todayUsageError == nil ? store.today?.summary : nil)
    }
    private var help: String {
        if let error = store.todayUsageError { return error }
        if !store.connected { return L("hud.disconnected") }
        if preferences.metric == .cost { return L(reading.partial ? "hud.partial_cost" : "cost.estimate") }
        return L("hud.today_help")
    }

    var body: some View {
        VStack(spacing: 11) {
            readout
            HStack(spacing: 12) {
                HStack(spacing: 5) {
                    Button { preferences.metric = .tokens } label: { HUDTokenSymbol().frame(width: 18, height: 18) }
                        .buttonStyle(HUDMechanicalButton(selected: preferences.metric == .tokens))
                        .help(L("usage.tokens")).accessibilityLabel(L("usage.tokens"))
                        .accessibilityAddTraits(preferences.metric == .tokens ? .isSelected : [])
                    Button { preferences.metric = .cost } label: { Image(systemName: "dollarsign.circle").font(.system(size: 17)) }
                        .buttonStyle(HUDMechanicalButton(selected: preferences.metric == .cost))
                        .help(L("hud.cost")).accessibilityLabel(L("hud.cost"))
                        .accessibilityAddTraits(preferences.metric == .cost ? .isSelected : [])
                }
                .padding(4)
                .background(LinearGradient(colors: [Color(red: 0.56, green: 0.26, blue: 0.08), Color(red: 0.77, green: 0.42, blue: 0.17)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(.black.opacity(0.15), lineWidth: 1))
                Spacer(minLength: 8)
                HStack(spacing: 3) {
                    ForEach(0..<13) { _ in Capsule().fill(Color(red: 0.62, green: 0.30, blue: 0.10).opacity(0.5)).frame(width: 2, height: 7) }
                }.shadow(color: .white.opacity(0.25), radius: 0, y: 1).accessibilityHidden(true)
                Button { preferences.soundEnabled.toggle(); HUDSound.shared.update(preferences: preferences) } label: {
                    Image(systemName: preferences.soundEnabled ? "speaker.wave.2" : "speaker.slash").font(.system(size: 13))
                }
                .buttonStyle(HUDMechanicalButton(selected: preferences.soundEnabled, round: true))
                .accessibilityLabel(L(preferences.soundEnabled ? "hud.mute" : "hud.unmute"))
                .help(L(preferences.soundEnabled ? "hud.mute" : "hud.unmute"))
                .accessibilityAddTraits(preferences.soundEnabled ? .isSelected : [])
            }.padding(.horizontal, 6)
        }
        .padding(.horizontal, 18).padding(.top, 17).padding(.bottom, 12)
        .frame(width: 420, height: 164)
        .background(LinearGradient(colors: [Color(red: 1, green: 0.71, blue: 0.35), Color(red: 0.97, green: 0.57, blue: 0.20), Color(red: 0.82, green: 0.36, blue: 0.08)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color(red: 0.66, green: 0.33, blue: 0.12), lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: 27).inset(by: 1).stroke(LinearGradient(colors: [.white.opacity(0.65), .clear, .black.opacity(0.20)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 2))
        .padding(10)
        .scaleEffect(0.5)
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .environment(\.locale, Locale(identifier: language == AppLanguage.system.rawValue ? Localization.identifier : language))
        .onChange(of: reading, initial: true) { _, next in animator.receive(next, animated: !reduceMotion) }
        .onChange(of: reduceMotion) { _, enabled in if enabled { animator.settle(); HUDSound.shared.stop() } }
        .task(id: animator.generation) {
            guard animator.isRolling else { HUDSound.shared.stop(); return }
            let generation = animator.generation
            let start = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled, animator.isRolling, animator.generation == generation {
                if animator.advance(elapsed: ProcessInfo.processInfo.systemUptime - start), canPlaySound() {
                    HUDSound.shared.tick(preferences: preferences)
                }
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
            // Let the final short click finish unless another reading has resumed the rollers.
            if !animator.isRolling {
                try? await Task.sleep(for: .milliseconds(45))
                if !Task.isCancelled, !animator.isRolling { HUDSound.shared.stop() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in dayClock += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in dayClock += 1 }
        .task(id: dayClock) {
            while !Task.isCancelled {
                let now = Date()
                await store.refreshToday(now: now)
                let midnight = LocalUsageDay(now: now).end
                do { try await Task.sleep(for: .seconds(max(0, midnight.timeIntervalSinceNow))) } catch { return }
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            animator.settle()
            Task { await store.refreshToday() }
        }
        .onDisappear { animator.settle(); HUDSound.shared.stop() }
    }

    private var readout: some View {
        // SwiftUI can evaluate an old child after the animator clears or resizes its array.
        let positions = animator.positions
        return HStack(spacing: 2) {
            if preferences.metric == .cost {
                Text(reading.partial ? "≈$" : "$").font(.custom("SairaExtraCondensed-SemiBold", size: 24))
                    .foregroundStyle(Color(red: 0.72, green: 0.79, blue: 0.86)).padding(.horizontal, 3)
            }
            if positions.isEmpty {
                Text("—").font(.custom("SairaExtraCondensed-SemiBold", size: 48))
                    .foregroundStyle(Color(red: 0.94, green: 0.94, blue: 0.87)).frame(maxWidth: .infinity)
            } else {
                ForEach(positions.indices, id: \.self) { index in
                    HUDDrum(position: positions[index], blue: index == positions.count - 1,
                            count: positions.count)
                    let remaining = positions.count - index - 1
                    if remaining > 0, (preferences.metric == .tokens && remaining.isMultiple(of: 3)) || (preferences.metric == .cost && remaining == 2) {
                        Text(preferences.metric == .cost ? "." : ",").font(.custom("SairaExtraCondensed-SemiBold", size: 25))
                            .foregroundStyle(.white.opacity(0.8)).frame(width: 5).offset(y: 15)
                    }
                }
            }
        }
        .padding(.horizontal, 5).frame(height: 76)
        .background(Color(red: 0.05, green: 0.09, blue: 0.14))
        .overlay(LinearGradient(stops: [.init(color: .black.opacity(0.75), location: 0), .init(color: .clear, location: 0.27), .init(color: .white.opacity(0.025), location: 0.48), .init(color: .clear, location: 0.72), .init(color: .black.opacity(0.8), location: 1)], startPoint: .top, endPoint: .bottom).allowsHitTesting(false))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(5)
        .background(LinearGradient(colors: [Color(red: 0.38, green: 0.18, blue: 0.07), Color(red: 0.70, green: 0.36, blue: 0.14)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.28), lineWidth: 1))
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L(preferences.metric == .tokens ? "hud.today_tokens" : "hud.today_cost"))
        .accessibilityValue((reading.partial ? "≈ " : "") + (animator.reading?.formatted ?? "—"))
        .accessibilityHint(help)
    }
}

private struct HUDDrum: View {
    let position: Double
    let blue: Bool
    let count: Int
    private let stride: CGFloat = 58
    var body: some View {
        GeometryReader { geometry in
            let integer = Int(floor(position)), fraction = position - floor(position)
            VStack(spacing: 0) {
                ForEach(-1...2, id: \.self) { delta in
                    Text(String((integer + delta + 10) % 10))
                        .font(.custom("SairaExtraCondensed-SemiBold", size: min(62, geometry.size.width * 1.4)))
                        .foregroundStyle(blue ? Color(red: 0.56, green: 0.74, blue: 1) : Color(red: 0.95, green: 0.94, blue: 0.88))
                        .shadow(color: .black.opacity(0.5), radius: 0.5, y: 1)
                        .frame(width: geometry.size.width, height: stride)
                }
            }.offset(y: (76 - stride) / 2 - stride - fraction * stride)
        }
        .frame(maxWidth: .infinity).frame(height: 76)
        .background(LinearGradient(colors: [Color(red: 0.10, green: 0.16, blue: 0.24), Color(red: 0.20, green: 0.27, blue: 0.36), Color(red: 0.12, green: 0.19, blue: 0.28)], startPoint: .leading, endPoint: .trailing))
        .clipped()
    }
}

struct HUDMechanicalButton: ButtonStyle {
    var selected: Bool
    var round = false
    func makeBody(configuration: Configuration) -> some View {
        let down = selected || configuration.isPressed
        configuration.label
            .frame(width: round ? 28 : 37, height: 27)
            .foregroundStyle(down ? Color(red: 0.97, green: 0.86, blue: 0.66) : Color(red: 0.46, green: 0.23, blue: 0.10))
            .background(LinearGradient(colors: down ? [Color(red: 0.57, green: 0.29, blue: 0.11), Color(red: 0.72, green: 0.41, blue: 0.17)] : [Color(red: 1, green: 0.83, blue: 0.55), Color(red: 0.94, green: 0.64, blue: 0.29)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: round ? 14 : 7))
            .overlay(RoundedRectangle(cornerRadius: round ? 14 : 7).stroke(down ? .black.opacity(0.3) : .white.opacity(0.45), lineWidth: 1))
            .shadow(color: .black.opacity(down ? 0 : 0.3), radius: 1, y: 2)
            .offset(y: down ? 1 : 0)
    }
}

struct HUDTokenSymbol: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for points in [[(7.0,4.0),(4,4),(4,20),(7,20)], [(17.0,4.0),(20,4),(20,20),(17,20)], [(9.0,8.0),(15,8)], [(9.0,12.0),(13,12)], [(9.0,16.0),(15,16)]] {
                path.move(to: CGPoint(x: points[0].0 / 24 * size.width, y: points[0].1 / 24 * size.height))
                for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.0 / 24 * size.width, y: point.1 / 24 * size.height)) }
            }
            context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }.accessibilityHidden(true)
    }
}
