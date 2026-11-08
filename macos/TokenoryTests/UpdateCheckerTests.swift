import XCTest
@testable import Tokenory

final class UpdateCheckerTests: XCTestCase {
    @MainActor
    func testUpdaterSettingsPersistAndManualChecksRemainAvailableWhenAutomaticChecksAreOff() throws {
        let domain = "ee.ryek.tokenory.tests.\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(domain).appendingPathExtension("app")
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        let info: [String: Any] = [
            "CFBundleIdentifier": domain,
            "CFBundleName": "Tokenory Test",
            "CFBundleVersion": "5",
            "CFBundleShortVersionString": "0.1.3",
            "SUDefaultsDomain": domain,
            "SUFeedURL": "https://raw.githubusercontent.com/ryekee/tokenory/updates/appcast.xml",
            "SUPublicEDKey": "RY7yf0+Hmmt5t4CaNLRZ0yxE/IyZ2cfkL9nZxt9G/0g=",
            "SUEnableAutomaticChecks": true,
            "SUScheduledCheckInterval": 86400,
            "SUAllowsAutomaticUpdates": false
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: root))
        let checker = UpdateChecker(bundle: bundle)
        XCTAssertEqual(checker.updater.httpHeaders?["Accept"], "application/octet-stream")
        XCTAssertTrue(checker.automaticallyChecksForUpdates)
        XCTAssertEqual(checker.checkIntervalHours, 24)
        checker.setAutomaticChecks(false)
        XCTAssertFalse(checker.automaticallyChecksForUpdates)
        for hours in UpdateChecker.intervalHours {
            checker.setIntervalHours(hours)
            XCTAssertEqual(checker.updater.updateCheckInterval, Double(hours * 3600))
            XCTAssertEqual(checker.checkIntervalHours, hours)
        }
        let reopened = UpdateChecker(bundle: bundle)
        XCTAssertFalse(reopened.automaticallyChecksForUpdates)
        XCTAssertEqual(reopened.checkIntervalHours, 168)
        // Starting with automatic checks disabled must still enable the manual action.
        reopened.start()
        XCTAssertNil(reopened.startupError)
        XCTAssertTrue(reopened.canCheckForUpdates)
        reopened.setAutomaticChecks(true)
        XCTAssertTrue(reopened.automaticallyChecksForUpdates)
        reopened.setAutomaticChecks(false)
    }

    func testReleaseConfigurationSupportsSignedGitHubUpdates() throws {
        let bundle = Bundle.main
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
                       "https://raw.githubusercontent.com/ryekee/tokenory/updates/appcast.xml")
        let key = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
        XCTAssertEqual(Data(base64Encoded: key)?.count, 32)
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool, true)
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "SUAllowsAutomaticUpdates") as? Bool, false)
    }
}
