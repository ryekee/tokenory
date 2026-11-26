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

    var anchor: HUDDockAnchor {
        switch self {
        case .topLeft: HUDDockAnchor(edge: .top, along: 0)
        case .topCenter: HUDDockAnchor(edge: .top, along: 0.5)
        case .topRight: HUDDockAnchor(edge: .top, along: 1)
        case .bottomLeft: HUDDockAnchor(edge: .bottom, along: 0)
        case .bottomCenter: HUDDockAnchor(edge: .bottom, along: 0.5)
        case .bottomRight: HUDDockAnchor(edge: .bottom, along: 1)
        }
    }

    func origin(in bounds: CGRect, screenFrame: CGRect, size: CGSize) -> CGPoint {
        HUDLayoutSolver.origin(
            for: anchor,
            in: HUDDisplayMetrics(screenFrame: screenFrame, visibleFrame: bounds),
            size: size
        )
    }
}

@MainActor @Observable
final class HUDPreferences {
    static let shared = HUDPreferences()
    @ObservationIgnored private let defaults: UserDefaults
    var enabled: Bool { didSet { defaults.set(enabled, forKey: "hud.enabled") } }
    var autoHideWhenIdle: Bool { didSet { defaults.set(autoHideWhenIdle, forKey: "hud.autoHideWhenIdle") } }
    var followPointer: Bool { didSet { defaults.set(followPointer, forKey: "hud.followPointer") } }
    var dismissal: HUDDismissal { didSet { defaults.set(dismissal.rawValue, forKey: "hud.dismissal") } }
    var anchor: HUDDockAnchor {
        didSet {
            defaults.set(anchor.edge.rawValue, forKey: "hud.anchor.edge")
            defaults.set(anchor.along, forKey: "hud.anchor.along")
            if let matched = anchor.matchingPreset() {
                defaults.set(matched.rawValue, forKey: "hud.placement")
            }
        }
    }
    var pinnedDisplayID: UInt32? {
        didSet {
            if let pinnedDisplayID {
                defaults.set(Int(pinnedDisplayID), forKey: "hud.pinnedDisplayID")
            } else {
                defaults.removeObject(forKey: "hud.pinnedDisplayID")
            }
        }
    }
    var placement: HUDPlacement {
        get { anchor.matchingPreset() ?? .bottomRight }
        set { anchor = newValue.anchor }
    }
    var matchedPlacement: HUDPlacement? { anchor.matchingPreset() }
    var metric: HUDMetric { didSet { defaults.set(metric.rawValue, forKey: "hud.metric") } }
    var soundEnabled: Bool { didSet { defaults.set(soundEnabled, forKey: "hud.soundEnabled") } }
    var volume: Double { didSet { defaults.set(volume, forKey: "hud.volume") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "hud.enabled")
        autoHideWhenIdle = defaults.bool(forKey: "hud.autoHideWhenIdle")
        followPointer = defaults.object(forKey: "hud.followPointer") as? Bool ?? true
        dismissal = HUDDismissal(rawValue: defaults.string(forKey: "hud.dismissal") ?? "") ?? .disable
        if let edgeRaw = defaults.string(forKey: "hud.anchor.edge"),
           let edge = HUDEdge(rawValue: edgeRaw),
           let along = defaults.object(forKey: "hud.anchor.along") as? Double {
            anchor = HUDDockAnchor(edge: edge, along: along)
        } else {
            let legacy = HUDPlacement(rawValue: defaults.string(forKey: "hud.placement") ?? "") ?? .bottomRight
            anchor = legacy.anchor
        }
        if let storedDisplay = defaults.object(forKey: "hud.pinnedDisplayID") as? Int, storedDisplay > 0 {
            pinnedDisplayID = UInt32(storedDisplay)
        } else {
            pinnedDisplayID = nil
        }
        metric = HUDMetric(rawValue: defaults.string(forKey: "hud.metric") ?? "") ?? .tokens
        soundEnabled = defaults.bool(forKey: "hud.soundEnabled")
        let stored = defaults.object(forKey: "hud.volume") as? Double ?? 0.35
        volume = stored.isFinite ? min(1, max(0, stored)) : 0.35
    }
}
