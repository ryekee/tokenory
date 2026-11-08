import AppKit
import Sparkle

// Compile alongside the real UpdateChecker.swift, then point only at a disposable app.
@main
struct UpdateSmoke {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 3,
              let bundle = Bundle(path: CommandLine.arguments[1]),
              bundle.bundleURL.path.contains("/.build/update-smoke/") else {
            fatalError("Usage: smoke /absolute/path/.build/update-smoke/Tokenory.app update|current")
        }
        _ = NSApplication.shared
        let driver = UpdateSmokeDriver()
        driver.expectUpdate = CommandLine.arguments[2] == "update"
        let checker = UpdateChecker(bundle: bundle, userDriver: driver)
        checker.setAutomaticChecks(false)
        checker.start()
        if let error = checker.startupError { fatalError(error) }
        checker.check()
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
            NSLog("SMOKE: timed out")
            exit(6)
        }
        withExtendedLifetime(checker) { NSApp.run() }
    }
}
