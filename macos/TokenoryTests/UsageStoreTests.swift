import XCTest
@testable import Tokenory

@MainActor
final class UsageStoreTests: XCTestCase {
    func testRealEngineRestartAndInvalidFilterPreserveKnownUsage() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Tokenory-tests-\(UUID())")
        let home = root.appending(path: "home"); let data = root.appending(path: "data")
        let logs = home.appending(path: ".claude/projects/test")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let settings = EngineSettings(homeDir: home.path, intervalSeconds: 60, timezone: "Asia/Shanghai", extraScanPaths: [:])
        try JSONEncoder().encode(settings).write(to: data.appending(path: "settings.json"))
        let row = #"{"type":"assistant","timestamp":"2026-11-05T01:00:00Z","message":{"id":"msg_test","role":"assistant","model":"deepseek-flash","usage":{"input_tokens":1000,"output_tokens":0}}}"# + "\n"
        try Data(row.utf8).write(to: logs.appending(path: "session.jsonl"))
        let engine = EngineClient(helper: Bundle.main.bundleURL.appending(path: "Contents/Helpers/tokenory"), directory: data)
        let store = UsageStore(engine: engine, directory: data)
        store.filter = UsageFilter()
        do {
            try await engine.start(); try await engine.start()
            for _ in 0..<50 {
                await store.refresh()
                if store.report?.summary.tokens == 1000 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertEqual(store.report?.summary.tokens, 1000)
            await store.refreshToday(now: ISO8601DateFormatter().date(from: "2026-11-05T01:00:00Z")!)
            XCTAssertEqual(store.today?.summary.tokens, 1000)
            await store.refreshToday(now: ISO8601DateFormatter().date(from: "2026-11-05T16:00:00Z")!)
            XCTAssertEqual(store.today?.summary.tokens, 0)
            store.filter.from = "2026-02-30"; await store.refresh()
            XCTAssertNotNil(store.error)
            XCTAssertEqual(store.report?.summary.tokens, 1000)
            await engine.stop()
            do { _ = try await engine.request("status"); XCTFail("stopped engine accepted request") } catch {}
            try await engine.start()
            let report = try await engine.request("overview").decode(UsageReport.self)
            XCTAssertEqual(report.summary.tokens, 1000)
            await engine.stop()
            try FileManager.default.removeItem(at: root)
        } catch {
            await engine.stop()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}
