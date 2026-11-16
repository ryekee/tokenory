// [INPUT]: UserDefaults and HUD/Settings controls.
// [OUTPUT]: Shared persistent visibility, metric, mute and volume.
// [POS]: Main-actor preferences boundary for the mechanical HUD.
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import Foundation
import Observation

@MainActor @Observable
final class HUDPreferences {
    static let shared = HUDPreferences()
    @ObservationIgnored private let defaults: UserDefaults
    var enabled: Bool { didSet { defaults.set(enabled, forKey: "hud.enabled") } }
    var metric: HUDMetric { didSet { defaults.set(metric.rawValue, forKey: "hud.metric") } }
    var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: "hud.soundEnabled") } }
    var volume: Double { didSet { defaults.set(volume, forKey: "hud.volume") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "hud.enabled")
        metric = HUDMetric(rawValue: defaults.string(forKey: "hud.metric") ?? "") ?? .tokens
        soundEnabled = defaults.bool(forKey: "hud.soundEnabled")
        let stored = defaults.object(forKey: "hud.volume") as? Double ?? 0.35
        volume = stored.isFinite ? min(1, max(0, stored)) : 0.35
    }
}
