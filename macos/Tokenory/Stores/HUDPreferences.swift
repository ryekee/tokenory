// [INPUT]: UserDefaults and HUD/Settings controls.
// [OUTPUT]: Shared persistent visibility, optional idle hiding, triple-click action, placement, metric and audio settings.
// [POS]: Main-actor preferences boundary for the mechanical HUD.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import Foundation
import Observation

enum HUDDismissal: String, CaseIterable {
    case disable, seconds30, minute1, minutes5, ignore

    var label: String { L("hud.dismiss." + rawValue) }
    var duration: Duration? {
        switch self {
        case .disable, .ignore: nil
        case .seconds30: .seconds(30)
        case .minute1: .seconds(60)
        case .minutes5: .seconds(300)
        }
    }
}

enum HUDPlacement: String, CaseIterable {
    case topLeft, topCenter, topRight, bottomLeft, bottomCenter, bottomRight

    var label: String { L("hud.position." + rawValue) }

    func origin(in bounds: CGRect, screenFrame: CGRect, size: CGSize) -> CGPoint {
        // Match visible case-edge margins as fractions of the full screen dimensions.
        // The bottom reference includes the Dock and the window's 5 pt transparent padding.
        let sideMargin = (bounds.minY - screenFrame.minY + 5) * screenFrame.width / screenFrame.height
        let left = max(bounds.minX, screenFrame.minX + sideMargin - 5)
        let right = min(bounds.maxX - size.width, screenFrame.maxX - sideMargin + 5 - size.width)
        let x: CGFloat
        switch self {
        case .topLeft, .bottomLeft: x = left
        case .topCenter, .bottomCenter: x = bounds.midX - size.width / 2
        case .topRight, .bottomRight: x = right
        }
        let top = self == .topLeft || self == .topCenter || self == .topRight
        return CGPoint(x: x, y: top ? bounds.maxY - size.height : bounds.minY)
    }
}

@MainActor @Observable
final class HUDPreferences {
    static let shared = HUDPreferences()
    @ObservationIgnored private let defaults: UserDefaults
    var enabled: Bool { didSet { defaults.set(enabled, forKey: "hud.enabled") } }
    var autoHideWhenIdle: Bool { didSet { defaults.set(autoHideWhenIdle, forKey: "hud.autoHideWhenIdle") } }
    var dismissal: HUDDismissal { didSet { defaults.set(dismissal.rawValue, forKey: "hud.dismissal") } }
    var placement: HUDPlacement { didSet { defaults.set(placement.rawValue, forKey: "hud.placement") } }
    var metric: HUDMetric { didSet { defaults.set(metric.rawValue, forKey: "hud.metric") } }
    var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: "hud.soundEnabled") } }
    var volume: Double { didSet { defaults.set(volume, forKey: "hud.volume") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "hud.enabled")
        autoHideWhenIdle = defaults.bool(forKey: "hud.autoHideWhenIdle")
        dismissal = HUDDismissal(rawValue: defaults.string(forKey: "hud.dismissal") ?? "") ?? .disable
        placement = HUDPlacement(rawValue: defaults.string(forKey: "hud.placement") ?? "") ?? .bottomRight
        metric = HUDMetric(rawValue: defaults.string(forKey: "hud.metric") ?? "") ?? .tokens
        soundEnabled = defaults.bool(forKey: "hud.soundEnabled")
        let stored = defaults.object(forKey: "hud.volume") as? Double ?? 0.35
        volume = stored.isFinite ? min(1, max(0, stored)) : 0.35
    }
}
