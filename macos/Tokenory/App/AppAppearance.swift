// [INPUT]: The appearance chosen in General settings.
// [OUTPUT]: App-wide AppKit appearance, inherited by windows, sheets and popovers.
import AppKit

enum AppAppearance: String, CaseIterable {
    case system, light, dark

    static let defaultsKey = "appAppearance"

    var title: String { L("appearance." + rawValue) }

    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
