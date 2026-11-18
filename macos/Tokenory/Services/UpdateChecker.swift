import AppKit
import Combine
import Sparkle

@MainActor
final class UpdateChecker: NSObject, ObservableObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    static let shared = UpdateChecker()
    static let intervalHours = [1, 6, 12, 24, 168]

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var checkIntervalHours = 24
    @Published private(set) var startupError: String?
    let currentVersion: String
    private let baseFeedURL: URL?
    private(set) var updater: SPUUpdater!

    init(bundle: Bundle = .main, userDriver: (any SPUUserDriver)? = nil) {
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        baseFeedURL = (bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String).flatMap { URL(string: $0) }
        super.init()
        let driver = userDriver ?? SPUStandardUserDriver(hostBundle: bundle, delegate: self)
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: self)
        // Public Release Asset API downloads require this content negotiation header.
        updater.httpHeaders = ["Accept": "application/octet-stream"]
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

    func feedURLString(for updater: SPUUpdater) -> String? {
        // Sparkle can resolve system languages in the main feed. Explicit Tokenory choices
        // use a feed with only that translation, even when macOS is set to another language.
        let language = Localization.language
        guard language != .system, let baseFeedURL, baseFeedURL.lastPathComponent == "appcast.xml" else {
            return nil
        }
        return baseFeedURL.deletingLastPathComponent()
            .appendingPathComponent("appcast.\(language.rawValue).xml").absoluteString
    }

    // Sparkle presents scheduled updates behind other apps for this menu bar app.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
