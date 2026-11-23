// [INPUT]: 使用真实 helper、临时源日志和 UsageStore。
// [OUTPUT]: 验证账本状态更新、筛选请求和客户端目录。
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
        let row = #"{"type":"assistant","timestamp":"2026-11-05T01:00:00Z","message":{"id":"msg_test","role":"assistant","model":"deepseek-flash","usage":{"input_tokens":1000,"output_tokens":0}}}"# + "\n"
        try Data(row.utf8).write(to: logs.appending(path: "session.jsonl"))
        let codexLogs = home.appending(path: ".codex/sessions")
        try FileManager.default.createDirectory(at: codexLogs, withIntermediateDirectories: true)
        let codex = """
        {"type":"session_meta","payload":{"id":"s","cwd":"/test/project","source":"cli"}}
        {"type":"event_msg","payload":{"type":"task_started","turn_id":"t"}}
        {"type":"turn_context","payload":{"turn_id":"t","model":"model-a","effort":"medium"}}
        {"type":"token_usage_record","payload":{"turn_id":"t","response_id":"r","usage":{"output_tokens":100,"reasoning_output_tokens":20},"turn_token_usage":{"output_tokens":100,"reasoning_output_tokens":20}}}
        {"type":"event_msg","timestamp":"2026-11-14T00:00:10Z","payload":{"type":"task_complete","turn_id":"t","duration_ms":10000,"time_to_first_token_ms":200}}
        """
        try Data(codex.utf8).write(to: codexLogs.appending(path: "rollout-turn-test.jsonl"))
        let claudeTurn = """
        {"type":"user","uuid":"u","sessionId":"claude-test","cwd":"/test/project","timestamp":"2026-11-14T00:00:00Z","message":{"role":"user","content":"test"}}
        {"type":"assistant","sessionId":"claude-test","timestamp":"2026-11-14T00:00:10Z","message":{"id":"claude-response","role":"assistant","model":"deepseek-flash","content":[],"stop_reason":"end_turn","usage":{"input_tokens":0,"output_tokens":0}}}
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
            await store.refreshToday(now: ISO8601DateFormatter().date(from: "2026-11-14T01:00:00Z")!)
            XCTAssertEqual(store.todayTurns?.averageSpeed, 5)
            XCTAssertEqual(store.todayTurns?.points.count, 2)
            XCTAssertTrue(store.todayTurns?.containsEstimates == true)
            XCTAssertNil(store.todaySpeedError)
            XCTAssertEqual(store.turnAnalytics?.points.map(\.client), ["claude"])
            await store.refreshToday(now: ISO8601DateFormatter().date(from: "2026-11-14T16:00:00Z")!)
            XCTAssertNil(store.todayTurns?.averageSpeed)
            XCTAssertTrue(store.todayTurns?.points.isEmpty == true)
            store.turnClient = nil; store.turnModel = nil
            await store.loadSources()
            XCTAssertEqual(store.clients.count, 42)
            XCTAssertEqual(Set(store.turnAnalytics?.capabilities.map(\.client) ?? []), Set(store.clients.map(\.id)))
            XCTAssertTrue(store.priceProviders.isEmpty)
            XCTAssertNil(store.settings)
            await store.loadManagement()
            XCTAssertEqual(store.clients.count, 42)
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
            await store.refreshToday(now: ISO8601DateFormatter().date(from: "2026-11-05T01:00:00Z")!)
            XCTAssertEqual(store.today?.summary.tokens, 1000)
            await store.refreshToday(now: ISO8601DateFormatter().date(from: "2026-11-05T16:00:00Z")!)
            XCTAssertEqual(store.today?.summary.tokens, 0)
            store.dateRange = .today
            await store.refresh(now: ISO8601DateFormatter().date(from: "2026-11-05T01:00:00Z")!)
            XCTAssertEqual(store.report?.summary.tokens, 1000)
            await store.refreshToday(now: ISO8601DateFormatter().date(from: "2026-11-05T16:00:00Z")!)
            XCTAssertEqual(store.filter.from, "2026-11-06")
            XCTAssertEqual(store.report?.summary.tokens, 0)
            store.dateRange = .week
            await store.refresh(now: ISO8601DateFormatter().date(from: "2026-11-05T16:00:00Z")!)
            XCTAssertEqual(store.filter.from, "2026-10-31")
            XCTAssertEqual(store.activity?.from, "2025-11-07")
            XCTAssertEqual(store.activity?.to, "2026-11-06")
            XCTAssertEqual(store.activity?.hourly?.buckets.first?.key, "09")
            XCTAssertEqual(store.activity?.hourly?.buckets.first?.summary.tokens, 1000)
            XCTAssertEqual(store.activityCalendar?.activeDays, 1)
            XCTAssertEqual(store.history(metric: .tokens, average: true, client: nil)?.total, 1000)
            XCTAssertEqual(store.activity?.modelDays.reduce(0) { $0 + $1.summary.tokens }, 1000)
            store.filter.model = "not-a-model"
            await store.refreshSelection(store.filter, now: ISO8601DateFormatter().date(from: "2026-11-05T16:00:00Z")!)
            XCTAssertTrue(store.activity?.modelDays.isEmpty == true)
            store.filter.model = nil
            await store.refreshSelection(store.filter, now: ISO8601DateFormatter().date(from: "2026-11-05T16:00:00Z")!)
            XCTAssertEqual(store.report?.summary.tokens, 1000)
            XCTAssertEqual(store.history(metric: .tokens, average: true, client: nil)?.total, 1000)
            store.dateRange = .month
            await store.refresh(now: ISO8601DateFormatter().date(from: "2026-11-05T16:00:00Z")!)
            XCTAssertEqual(store.filter.from, "2026-10-08")
            store.dateRange = .custom
            store.filter.from = "2026-11-05"; store.filter.to = "2026-11-05"
            await store.refreshToday(now: ISO8601DateFormatter().date(from: "2026-11-06T16:00:00Z")!)
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
        let old = Task { await store.refresh(now: ISO8601DateFormatter().date(from: "2026-11-14T15:59:00Z")!) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: root.appending(path: "waiting").path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "waiting").path))
        await store.refreshToday(now: ISO8601DateFormatter().date(from: "2026-11-14T16:01:00Z")!)
        XCTAssertEqual(store.today?.summary.tokens, 200)
        XCTAssertEqual(store.todayTurns?.averageSpeed, 200)
        try Data().write(to: root.appending(path: "release"))
        await old.value
        XCTAssertEqual(store.today?.summary.tokens, 200)
        XCTAssertEqual(store.todayTurns?.averageSpeed, 200)
        await engine.stop()
        XCTAssertEqual(store.todayDay, "2026-11-15")
        XCTAssertNil(store.todayUsageError)
        await store.refreshToday(now: ISO8601DateFormatter().date(from: "2026-11-14T16:02:00Z")!)
        XCTAssertNotNil(store.todayUsageError)
        XCTAssertEqual(store.todayDay, "2026-11-15")
        try FileManager.default.removeItem(at: root)
    }

}
