// [INPUT]: 使用真实 helper、临时源日志和 UsageStore。
// [OUTPUT]: 验证账本状态更新、筛选请求、客户端目录和超时恢复。
// [POS]: 跨 Rust 和 Swift 的集成测试边界。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import AppKit
import XCTest
@testable import Tokenory

@MainActor
final class UsageStoreTests: XCTestCase {
    func testConversationSelectionResetsPaginationAndStaysInRecords() {
        let store = UsageStore()
        store.filter.offset = 100
        let id = UsageConversation.ID(client: "codex", sessionId: "conversation")
        let option = UsageConversation(id: id, title: "Review usage filters", lastDate: "2026-11-05",
                                       model: "gpt-5", lastTimestampMs: nil)
        store.selectConversation(option)
        XCTAssertEqual(store.filter.offset, 0)
        XCTAssertEqual(store.recordConversation?.title, "Review usage filters")
        XCTAssertNil(store.reportSelection.conversation)
        store.recordsAreActive = true
        XCTAssertEqual(store.reportSelection.conversation, id)
        store.recordsAreActive = false
        XCTAssertNil(store.reportSelection.conversation)
        store.recordsAreActive = true
        XCTAssertEqual(store.reportSelection.conversation, id)
        let dates = (store.filter.from, store.filter.to)
        store.clearRecordFilters()
        XCTAssertNil(store.reportSelection.conversation)
        XCTAssertNil(store.recordConversation)
        XCTAssertEqual(store.filter.from, dates.0)
        XCTAssertEqual(store.filter.to, dates.1)
    }

    func testDateArrowsKeepRangeLengthAndFiltersAcrossMonths() throws {
        let store = UsageStore()
        let today = try XCTUnwrap(Localization.date("2026-11-05"))
        store.updateDateRange(now: today)
        store.filter.client = "codex"
        store.filter.model = "gpt-5"
        store.filter.offset = 50
        XCTAssertNil(store.steppedDateRange(.later, now: today))

        store.stepDateRange(.earlier, now: today)
        XCTAssertEqual(store.dateRange, .custom)
        XCTAssertEqual(store.filter, UsageFilter(from: "2026-10-23", to: "2026-10-29", client: "codex", model: "gpt-5"))
        store.updateDateRange(now: today.addingTimeInterval(86_400))
        XCTAssertEqual(store.filter.to, "2026-10-29")

        store.stepDateRange(.later, now: today)
        XCTAssertEqual(store.dateRange, .week)
        XCTAssertEqual(store.filter, UsageFilter(from: "2026-10-30", to: "2026-11-05", client: "codex", model: "gpt-5"))
        XCTAssertNil(store.steppedDateRange(.later, now: today))
    }

    func testDateArrowsClampCustomRangesAndDisableForAllTime() throws {
        let store = UsageStore()
        let today = try XCTUnwrap(Localization.date("2026-11-05"))
        let from = try XCTUnwrap(Localization.date("2026-11-01"))
        let to = try XCTUnwrap(Localization.date("2026-11-03"))
        store.selectCustomDateRange(from...to)
        store.stepDateRange(.later, now: today)
        XCTAssertEqual(store.dateRange, .custom)
        XCTAssertEqual(store.filter.from, "2026-11-03")
        XCTAssertEqual(store.filter.to, "2026-11-05")

        store.selectDateRange(.today)
        store.updateDateRange(now: today)
        store.stepDateRange(.earlier, now: today)
        XCTAssertEqual(store.filter.from, "2026-11-04")
        XCTAssertEqual(store.filter.to, "2026-11-04")

        store.selectDateRange(.all)
        XCTAssertNil(store.steppedDateRange(.earlier, now: today))
        XCTAssertNil(store.steppedDateRange(.later, now: today))
    }

    func testDateArrowsReturnToRollingPresets() throws {
        let store = UsageStore()
        let today = try XCTUnwrap(Localization.date("2026-11-05"))
        let tomorrow = try XCTUnwrap(Localization.date("2026-11-06"))
        for preset in [UsageDateRange.today, .week, .month] {
            store.selectDateRange(preset, now: today)
            let expected = store.filter
            store.stepDateRange(.earlier, now: today)
            XCTAssertEqual(store.dateRange, .custom)
            store.stepDateRange(.later, now: today)
            XCTAssertEqual(store.dateRange, preset)
            XCTAssertEqual(store.filter, expected)
            store.updateDateRange(now: tomorrow)
            XCTAssertEqual(store.filter.to, "2026-11-06")
        }
    }

    func testCodexLiveAppendUpdatesTodayAndExtendsActiveHUDRoll() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Tokenory-live-\(UUID())")
        let home = root.appending(path: "home"), data = root.appending(path: "data")
        let logs = home.appending(path: ".codex/sessions")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let settings = EngineSettings(homeDir: home.path, intervalSeconds: 86400, timezone: "Asia/Shanghai", extraScanPaths: [:])
        try JSONEncoder().encode(settings).write(to: data.appending(path: "settings.json"))
        let stamp = ISO8601DateFormatter().string(from: Date())
        func usage(_ count: Int) -> String {
            "{\"timestamp\":\"\(stamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(count),\"output_tokens\":0,\"cached_input_tokens\":0,\"reasoning_output_tokens\":0,\"total_tokens\":\(count)}}}}\n"
        }
        let file = logs.appending(path: "active.jsonl")
        let header = """
        {"type":"session_meta","payload":{"id":"native-live-session","model_provider":"openai"}}
        {"type":"turn_context","payload":{"model":"gpt-5-codex"}}
        """ + "\n"
        try Data((header + usage(100)).utf8).write(to: file)
        let engine = EngineClient(helper: Bundle.main.bundleURL.appending(path: "Contents/Helpers/tokenory"), directory: data)
        let store = UsageStore(engine: engine, directory: data)
        do {
            store.start()
            func waitForTokens(_ value: Int64) async throws {
                for _ in 0..<160 {
                    if store.today?.summary.tokens == value { return }
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTFail("Live total did not reach \(value); actual \(String(describing: store.today?.summary.tokens))")
            }
            try await waitForTokens(100)
            let animator = HUDAnimator()
            func receive() {
                animator.receive(HUDReading(day: store.todayDay ?? "", metric: .tokens, summary: store.today?.summary), animated: true)
            }
            receive()
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(usage(150).utf8))
            try await waitForTokens(150)
            receive(); animator.advance(elapsed: 1)
            XCTAssertTrue(animator.isRolling)
            let positions = animator.positions, generation = animator.generation
            try handle.write(contentsOf: Data(usage(200).utf8))
            try await waitForTokens(200)
            receive()
            XCTAssertEqual(animator.generation, generation)
            XCTAssertEqual(animator.positions, positions)
            XCTAssertEqual(animator.reading?.value, 200)
            await engine.stop()
            try FileManager.default.removeItem(at: root)
        } catch {
            await engine.stop()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func testRealEngineRestartAndInvalidFilterPreserveKnownUsage() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Tokenory-tests-\(UUID())")
        let home = root.appending(path: "home"); let data = root.appending(path: "data")
        let logs = home.appending(path: ".claude/projects/test")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let settings = EngineSettings(homeDir: home.path, intervalSeconds: 60, timezone: "Asia/Shanghai", extraScanPaths: [:])
        try JSONEncoder().encode(settings).write(to: data.appending(path: "settings.json"))
        let day = Localization.date("2026-11-05")!
        let nextDay = Localization.date("2026-11-06")!
        let turnDay = Localization.date("2026-11-14")!
        let nextTurnDay = Localization.date("2026-11-15")!
        let usageTime = day.addingTimeInterval(9 * 3600)
        let iso = ISO8601DateFormatter()
        let row = #"{"type":"assistant","timestamp":"\#(iso.string(from: usageTime))","message":{"id":"msg_test","role":"assistant","model":"deepseek-flash","usage":{"input_tokens":1000,"output_tokens":0}}}"# + "\n"
        try Data(row.utf8).write(to: logs.appending(path: "session.jsonl"))
        let codexLogs = home.appending(path: ".codex/sessions")
        try FileManager.default.createDirectory(at: codexLogs, withIntermediateDirectories: true)
        let index = codexLogs.deletingLastPathComponent().appending(path: "session_index.jsonl")
        try Data(#"{"id":"s","thread_name":"Review sync"}"#.utf8).write(to: index)
        let codex = """
        {"type":"session_meta","payload":{"id":"s","cwd":"/test/project","source":"cli"}}
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"t"}}
        {"type":"turn_context","payload":{"turn_id":"t","model":"model-a","effort":"medium"}}
        {"type":"token_usage_record","payload":{"turn_id":"t","response_id":"r","usage":{"output_tokens":100,"reasoning_output_tokens":20},"turn_token_usage":{"output_tokens":100,"reasoning_output_tokens":20}}}
        {"type":"event_msg","timestamp":"\(iso.string(from: turnDay.addingTimeInterval(3600 + 10)))","payload":{"type":"task_complete","turn_id":"t","duration_ms":10000,"time_to_first_token_ms":200}}
        """
        try Data(codex.utf8).write(to: codexLogs.appending(path: "rollout-turn-test.jsonl"))
        let claudeTurn = """
        {"type":"user","uuid":"u","sessionId":"claude-test","cwd":"/test/project","timestamp":"\(iso.string(from: turnDay.addingTimeInterval(3600)))","message":{"role":"user","content":"test"}}
        {"type":"assistant","sessionId":"claude-test","timestamp":"\(iso.string(from: turnDay.addingTimeInterval(3600 + 10)))","message":{"id":"claude-response","role":"assistant","model":"deepseek-flash","content":[],"stop_reason":"end_turn","usage":{"input_tokens":0,"output_tokens":0}}}
        """
        try Data(claudeTurn.utf8).write(to: logs.appending(path: "turn-session.jsonl"))
        let engine = EngineClient(helper: Bundle.main.bundleURL.appending(path: "Contents/Helpers/tokenory"), directory: data)
        let store = UsageStore(engine: engine, directory: data)
        XCTAssertEqual(store.dateRange, .week)
        store.dateRange = .all
        store.filter = UsageFilter()
        do {
            try await engine.start(); try await engine.start()
            for _ in 0..<50 {
                await store.refresh()
                if store.report?.summary.tokens == 1000 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertEqual(store.report?.summary.tokens, 1000)
            XCTAssertNil(store.turnAnalytics)
            let turnQuery = TurnQuery(from: "2026-11-14", to: "2026-11-14", model: nil, client: "codex")
            await store.loadAgentTurns(turnQuery)
            XCTAssertNil(store.turnsError)
            XCTAssertEqual(store.turnAnalytics?.points.count, 1)
            XCTAssertEqual(store.turnAnalytics?.sorted(by: .newest, search: "review SYNC").first?.turnId, "t")
            XCTAssertEqual(store.turnAnalytics?.averageSpeed, 10)
            XCTAssertEqual(store.turnAnalytics?.averageTTFTSeconds, 0.2)
            await store.loadAgentTurns(TurnQuery(from: "2026-11-14", to: "2026-11-14", model: "missing", client: "codex"))
            XCTAssertTrue(store.turnAnalytics?.points.isEmpty == true)
            XCTAssertEqual(store.turnAnalytics?.models, ["model-a"])
            await store.loadAgentTurns(turnQuery)
            XCTAssertEqual(store.turnAnalytics?.points.count, 1)
            await store.loadAgentTurns(TurnQuery(from: "2026-11-14", to: "2026-11-14", model: nil, client: "claude"))
            XCTAssertEqual(store.turnAnalytics?.points.map(\.client), ["claude"])
            XCTAssertTrue(store.turnAnalytics?.containsEstimates == true)
            XCTAssertNil(store.turnAnalytics?.averageTTFTSeconds)
            XCTAssertNil(store.turnAnalytics?.averageReasoning)
            XCTAssertTrue(store.turnAnalytics?.capabilities.contains { $0.client == "claude" && $0.supported } == true)
            // Menu speed uses the whole reporting day, even when the page selects one agent/model.
            store.turnClient = "codex"; store.turnModel = "missing"
            await store.refreshToday(now: turnDay.addingTimeInterval(2 * 3600))
            XCTAssertEqual(store.todayTurns?.averageSpeed, 5)
            XCTAssertEqual(store.todayTurns?.points.count, 2)
            XCTAssertTrue(store.todayTurns?.containsEstimates == true)
            XCTAssertNil(store.todaySpeedError)
            XCTAssertEqual(store.turnAnalytics?.points.map(\.client), ["claude"])
            await store.refreshToday(now: nextTurnDay)
            XCTAssertNil(store.todayTurns?.averageSpeed)
            XCTAssertTrue(store.todayTurns?.points.isEmpty == true)
            store.turnClient = nil; store.turnModel = nil
            await store.loadSources()
            XCTAssertEqual(store.clients.count, 43)
            XCTAssertEqual(Set(store.turnAnalytics?.capabilities.map(\.client) ?? []), Set(store.clients.map(\.id)))
            XCTAssertTrue(store.priceProviders.isEmpty)
            XCTAssertNil(store.settings)
            await store.loadManagement()
            XCTAssertEqual(store.clients.count, 43)
            XCTAssertTrue(store.priceProviders.contains { $0.id == "google" })
            XCTAssertTrue(store.priceProviders.contains { $0.id == "xiaomi" && $0.title == "Xiaomi MiMo" })
            XCTAssertGreaterThan(store.priceProviders.count, 200)
            XCTAssertEqual(Set(store.usedPriceModels.map(\.model)), ["deepseek-flash"])
            let supported = Set(store.clients.map(\.id))
            XCTAssertEqual(supported, Set(Brand.toolSlugs.keys).union(Brand.toolSymbols.keys))
            for client in store.clients {
                if let slug = Brand.slug(client.id, kind: .tool) {
                    XCTAssertNotNil(NSImage(named: "Brand-" + slug), client.id)
                } else if let symbol = Brand.toolSymbols[client.id] {
                    XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), client.id)
                } else { XCTFail("Missing icon: " + client.id) }
            }
            XCTAssertEqual(store.clients.first { $0.id == "paseo" }?.collectsAs, ["claude", "codex"])
            XCTAssertEqual(store.clients.first { $0.id == "orca" }?.collectsAs, ["micode"])
            XCTAssertTrue(store.clients.first { $0.id == "gemini" }?.supportsExtraPaths == true)
            await store.refreshToday(now: usageTime)
            XCTAssertEqual(store.today?.summary.tokens, 1000)
            await store.refreshToday(now: nextDay)
            XCTAssertEqual(store.today?.summary.tokens, 0)
            store.dateRange = .today
            await store.refresh(now: usageTime)
            XCTAssertEqual(store.report?.summary.tokens, 1000)
            await store.refreshToday(now: nextDay)
            XCTAssertEqual(store.filter.from, "2026-11-06")
            XCTAssertEqual(store.report?.summary.tokens, 0)
            store.dateRange = .week
            await store.refresh(now: nextDay)
            XCTAssertEqual(store.filter.from, "2026-10-31")
            XCTAssertEqual(store.activity?.from, "2025-11-07")
            XCTAssertEqual(store.activity?.to, "2026-11-06")
            XCTAssertEqual(store.activity?.hourly?.buckets.first?.key, "09")
            XCTAssertEqual(store.activity?.hourly?.buckets.first?.summary.tokens, 1000)
            XCTAssertEqual(store.activityCalendar?.activeDays, 1)
            XCTAssertEqual(store.history(metric: .tokens, average: true, client: nil)?.total, 1000)
            XCTAssertEqual(store.activity?.modelDays.reduce(0) { $0 + $1.summary.tokens }, 1000)
            store.filter.model = "not-a-model"
            await store.refreshSelection(store.filter, now: nextDay)
            XCTAssertTrue(store.activity?.modelDays.isEmpty == true)
            store.filter.model = nil
            await store.refreshSelection(store.filter, now: nextDay)
            XCTAssertEqual(store.report?.summary.tokens, 1000)
            XCTAssertEqual(store.history(metric: .tokens, average: true, client: nil)?.total, 1000)
            store.dateRange = .month
            await store.refresh(now: nextDay)
            XCTAssertEqual(store.filter.from, "2026-10-08")
            store.dateRange = .custom
            store.filter.from = "2026-11-05"; store.filter.to = "2026-11-05"
            await store.refreshToday(now: Localization.date("2026-11-07")!)
            XCTAssertEqual(store.filter.to, "2026-11-05")
            let previousReportFilter = store.reportFilter
            store.filter.from = "2026-02-30"; await store.refresh()
            XCTAssertNotNil(store.reportLoadError)
            XCTAssertEqual(store.reportFilter, previousReportFilter)
            XCTAssertEqual(store.report?.summary.tokens, 1000)
            store.filter.from = "2026-11-05"
            await store.retryReport()
            XCTAssertNil(store.reportLoadError)
            XCTAssertEqual(store.reportFilter, store.filter)
            await engine.stop()
            do { _ = try await engine.request("status"); XCTFail("stopped engine accepted request") } catch {}
            let cachedSources = store.sources
            let previousGlobalError = store.error
            await store.loadSources()
            XCTAssertNotNil(store.sourcesError)
            XCTAssertEqual(store.sources, cachedSources)
            XCTAssertEqual(store.error, previousGlobalError)
            try await engine.start()
            await store.loadSources()
            XCTAssertNil(store.sourcesError)
            let report = try await engine.request("overview").decode(UsageReport.self)
            XCTAssertEqual(report.summary.tokens, 1000)
            let bad = root.appending(path: "bad.sqlite3")
            try Data("broken SQLite".utf8).write(to: bad)
            do { try await store.restore(from: bad); XCTFail("accepted corrupt backup") } catch {}
            try await engine.start()
            let retained = try await engine.request("overview").decode(UsageReport.self)
            XCTAssertEqual(retained.summary.tokens, 1000)
            await engine.stop()
            try FileManager.default.removeItem(at: root)
        } catch {
            await engine.stop()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
    func testFirstReportFailureStopsLoadingAndDoesNotCarryToAnotherFilter() async {
        let store = UsageStore()
        let first = UsageFilter(from: "2026-11-14", to: "2026-11-14")
        store.filter = first
        store.connected = true
        // The worker has not started, so the first report request fails.
        await store.refreshSelection(first)
        XCTAssertNil(store.report)
        XCTAssertFalse(store.loading)
        XCTAssertNotNil(store.reportLoadError)
        XCTAssertNil(store.error)

        store.filter = UsageFilter(from: "2026-11-15", to: "2026-11-15")
        XCTAssertNil(store.reportLoadError)
    }

    func testScanTimeoutClearsAfterScanFinishesAndStatusResponds() async throws {
        let (store, root) = try await makeScanRecoveryStore()
        store.scan()
        for _ in 0..<100 {
            if store.error != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.error, "Scan timed out")
        XCTAssertEqual(store.errorAction, .refresh)

        store.scan()
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: root.appending(path: "scan-accepted").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "scan-accepted").path))
        XCTAssertTrue(store.scanInProgress)
        XCTAssertEqual(store.error, "Scan timed out", "A scan acknowledgment does not confirm completion")

        await store.consume(Self.scanFinished)
        XCTAssertEqual(store.status?.revision, 1)
        XCTAssertNotNil(store.today)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.scanInProgress)

        store.fail(EngineError(code: "timeout", message: "Backup timed out"))
        await store.consume(Self.scanFinished)
        XCTAssertEqual(store.error, "Backup timed out", "Scan success is independent of backup")
        XCTAssertEqual(store.errorAction, .acknowledge)
    }

    func testSuccessfulScanRetriesTimedOutActivityOnUnchangedLedger() async throws {
        let (store, root) = try await makeScanRecoveryStore()
        await store.refresh()
        XCTAssertNotNil(store.report)
        XCTAssertNil(store.error, "A background activity failure should not interrupt the current report")
        XCTAssertNil(store.activity)

        await store.consume(Self.scanFinished)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "activity-retried").path))
        XCTAssertEqual(store.activity?.revision, 1)
        XCTAssertNil(store.error)
    }

    func testBackgroundScanFailureDoesNotInterruptOrReplaceAnActionError() async {
        let store = UsageStore()
        let event = EngineEnvelope(version: 1, id: nil, result: nil, error: nil,
                                   event: "scanFailed", payload: nil, message: "Background scan failed", revision: nil)
        await store.consume(event)
        XCTAssertNil(store.error)

        store.fail(EngineError(code: "export", message: "Could not export"))
        await store.consume(event)
        XCTAssertEqual(store.error, "Could not export")
    }

    func testBackgroundTodayFailureKeepsTheCurrentDayReading() async throws {
        let (store, root) = try await makeScanRecoveryStore()
        let now = try XCTUnwrap(Localization.date("2026-11-25"))
        await store.refreshToday(now: now)
        let revision = try XCTUnwrap(store.today?.revision)

        try Data().write(to: root.appending(path: "fail-today"))
        await store.refreshToday(now: now)
        XCTAssertEqual(store.today?.revision, revision)
        XCTAssertEqual(store.todayUsageError, "Today timed out")
        XCTAssertNil(store.error)
    }

    private static let scanFinished = EngineEnvelope(version: 1, id: nil, result: nil, error: nil,
                                                     event: "scanFinished", payload: nil, message: nil, revision: nil)

    private func makeScanRecoveryStore() async throws -> (UsageStore, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "Tokenory-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let helper = root.appending(path: "worker.py")
        try #"""
        #!/usr/bin/python3
        import json, pathlib, sys
        root = pathlib.Path(sys.argv[2])
        seen = set()
        for line in sys.stdin:
            request = json.loads(line)
            op, payload = request['operation'], request['payload']
            response = dict(version=1, id=request['id'])
            if op in ('scan', 'activity') and op not in seen:
                response['error'] = dict(code='timeout', message=op.capitalize() + ' timed out')
            elif op == 'scan':
                (root / 'scan-accepted').touch()
                response['result'] = dict(started=True)
            elif op == 'status':
                response['result'] = dict(scanning=False, dataDirectory=str(root), revision=1, refreshingPrices=False)
            elif op == 'activity':
                (root / 'activity-retried').touch()
                response['result'] = dict(revision=1, daily=[], modelDays=[], **{'from':payload['from'], 'to':payload['to']})
            elif op == 'overview' and 'timestampFromMs' in payload and (root / 'fail-today').exists():
                response['error'] = dict(code='timeout', message='Today timed out')
            elif op == 'overview':
                summary = dict(tokens=0, tokenBreakdown=dict(input=0, output=0, cacheRead=0, cacheWrite=0, reasoning=0),
                               unpricedTokens=0, costStatus='unknown', recordCount=0, activeDays=0)
                response['result'] = dict(revision=1, summary=summary, daily=[], clients=[], providers=[], models=[], details=[])
            elif op == 'turnAnalytics':
                response['result'] = dict(revision=1, models=[], clients=[], capabilities=[], turns=[])
            seen.add(op)
            print(json.dumps(response), flush=True)
        """#.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let engine = EngineClient(helper: helper, directory: root)
        addTeardownBlock {
            await engine.stop()
            try FileManager.default.removeItem(at: root)
        }
        try await engine.start()
        return (UsageStore(engine: engine, directory: root), root)
    }

    func testDateSelectionKeepsPreviousReportAndOnlyRequestsNewRange() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Tokenory-range-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appending(path: "worker.py")
        let script = #"""
        #!/usr/bin/python3
        import json, pathlib, sys, time
        root = pathlib.Path(sys.argv[2])
        for line in sys.stdin:
            r = json.loads(line)
            p, operation = r['payload'], r['operation']
            with (root / 'requests').open('a') as log:
                print(operation, file=log)
            if operation == 'overview':
                tokens = 100 if p['from'] == '2026-11-14' else 200
                if tokens == 200:
                    (root / 'waiting').touch()
                    while not (root / 'release').exists(): time.sleep(.01)
                summary = dict(tokens=tokens,tokenBreakdown=dict(input=tokens,output=0,cacheRead=0,cacheWrite=0,reasoning=0),unpricedTokens=0,costStatus='unknown',recordCount=1,activeDays=1)
                result = dict(revision=1,summary=summary,daily=[],clients=[],providers=[],models=[],details=[])
            else:
                result = dict(revision=1,daily=[],modelDays=[])
                result.update({k:p[k] for k in ('from','to')})
            print(json.dumps(dict(version=1,id=r['id'],result=result)),flush=True)
        """#
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let engine = EngineClient(helper: helper, directory: root)
        let store = UsageStore(engine: engine, directory: root)
        let now = try XCTUnwrap(Localization.date("2026-11-18"))
        store.dateRange = .custom
        let first = UsageFilter(from: "2026-11-14", to: "2026-11-14")
        let second = UsageFilter(from: "2026-11-15", to: "2026-11-15")
        try await engine.start()
        store.filter = first
        await store.refreshSelection(first, now: now)
        XCTAssertEqual(store.report?.summary.tokens, 100)
        XCTAssertNotNil(store.activity)
        store.filter = second
        let refresh = Task { await store.refreshSelection(second, now: now) }
        let waiting = root.appending(path: "waiting")
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: waiting.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: waiting.path))
        XCTAssertTrue(store.loading)
        XCTAssertEqual(store.reportFilter, first)
        XCTAssertEqual(store.report?.summary.tokens, 100)
        // Returning to the displayed date should end the wait immediately.
        store.filter = first
        await store.refreshSelection(first, now: now)
        XCTAssertFalse(store.loading)
        try Data().write(to: root.appending(path: "release"))
        await refresh.value
        XCTAssertEqual(store.reportFilter, first)
        XCTAssertEqual(store.report?.summary.tokens, 100)
        store.filter = second
        await store.refreshSelection(second, now: now)
        await engine.stop()
        XCTAssertFalse(store.loading)
        XCTAssertEqual(store.reportFilter, second)
        XCTAssertEqual(store.report?.summary.tokens, 200)
        let requests = try String(contentsOf: root.appending(path: "requests"), encoding: .utf8)
        XCTAssertEqual(requests.split(separator: "\n"), ["overview", "activity", "overview", "overview"])
    }

    func testOlderFullRefreshCannotReplaceNewDayMenuMetrics() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "Tokenory-today-race-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let helper = root.appending(path: "worker.py")
        // Hold yesterday's replies until today's refresh has committed, then release them.
        let script = #"""
        #!/usr/bin/python3
        import json, pathlib, sys, threading, time
        root = pathlib.Path(sys.argv[2])
        lock = threading.Lock()
        threads = []
        def reply(r):
            p = r['payload']; op = r['operation']; day = p.get('from')
            old = day == '2026-11-14' and p.get('to') == day
            if old and op in ('overview', 'turnAnalytics'):
                (root / 'waiting').touch()
                while not (root / 'release').exists(): time.sleep(.01)
            tokens = 100 if old else 200
            summary = dict(tokens=tokens, tokenBreakdown=dict(input=0,output=tokens,cacheRead=0,cacheWrite=0,reasoning=0), knownEstimatedCostUsd=0, unpricedTokens=0, costStatus='priced',recordCount=1,activeDays=1)
            if op == 'overview':
                result = dict(revision=1,summary=summary,daily=[],clients=[],providers=[],models=[],details=[])
            elif op == 'activity':
                result = dict(revision=1,from_=p.get('from'),to=p.get('to'),daily=[],modelDays=[])
                result['from'] = result.pop('from_')
            elif op == 'status':
                result = dict(scanning=False,dataDirectory=str(root),revision=1,refreshingPrices=False)
            else:
                turn = dict(client='codex',durationEstimated=False,id=day,sessionId='s',turnId=day,project='p',model='m',startMs=1,endMs=1001,durationMs=1000,generatedTokens=tokens,requests=1,toolCalls=0)
                result = dict(revision=1,models=['m'],clients=['codex'],capabilities=[],turns=[turn])
            with lock:
                print(json.dumps(dict(version=1,id=r['id'],result=result)),flush=True)
        for line in sys.stdin:
            t = threading.Thread(target=reply,args=(json.loads(line),));t.start();threads.append(t)
        for t in threads: t.join()
        """#
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let engine = EngineClient(helper: helper, directory: root)
        let store = UsageStore(engine: engine, directory: root)
        store.dateRange = .all
        try await engine.start()
        let midnight = Localization.date("2026-11-15")!
        let old = Task { await store.refresh(now: midnight.addingTimeInterval(-60)) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: root.appending(path: "waiting").path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "waiting").path))
        await store.refreshToday(now: midnight.addingTimeInterval(60))
        XCTAssertEqual(store.today?.summary.tokens, 200)
        XCTAssertEqual(store.todayTurns?.averageSpeed, 200)
        try Data().write(to: root.appending(path: "release"))
        await old.value
        XCTAssertEqual(store.today?.summary.tokens, 200)
        XCTAssertEqual(store.todayTurns?.averageSpeed, 200)
        await engine.stop()
        XCTAssertEqual(store.todayDay, "2026-11-15")
        XCTAssertNil(store.todayUsageError)
        await store.refreshToday(now: midnight.addingTimeInterval(120))
        XCTAssertNotNil(store.todayUsageError)
        XCTAssertEqual(store.todayDay, "2026-11-15")
        try FileManager.default.removeItem(at: root)
    }

}
