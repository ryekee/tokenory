import AppKit
import Combine
import Sparkle

@MainActor
final class UpdateChecker: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    static let shared = UpdateChecker()
    static let intervalHours = [1, 6, 12, 24, 168]

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var checkIntervalHours = 24
    @Published private(set) var startupError: String?
    let currentVersion: String
    private(set) var updater: SPUUpdater!

    init(bundle: Bundle = .main) {
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        super.init()
        let driver = SPUStandardUserDriver(hostBundle: bundle, delegate: self)
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: nil)
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
        updater.publisher(for: \.updateCheckInterval).map { Int($0 / 3600) }.assign(to: &$checkIntervalHours)
    }

    func start() {
        do { try updater.start() }
        catch { startupError = error.localizedDescription }
    }

    func check() {
        NSApp.activate(ignoringOtherApps: true)
        updater.checkForUpdates()
    }

    func setAutomaticChecks(_ enabled: Bool) {
        updater.automaticallyChecksForUpdates = enabled
    }

    func setIntervalHours(_ hours: Int) {
        updater.updateCheckInterval = TimeInterval(hours * 3600)
    }

    // Sparkle presents scheduled updates behind other apps for this menu bar app.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
