// [INPUT]: 接收引擎报告、目录和设置协议。
// [OUTPUT]: 发布统计、独立当日用量及其日期/错误、回合、价格和采集状态。
// [POS]: 原生界面与 worker 的状态边界。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import Foundation
import Observation

enum UsageDateRange: String, CaseIterable {
    case today, week, month, all, custom
    var title: String { L("range." + rawValue) }
}

@MainActor @Observable
final class UsageStore {
    static let shared = UsageStore()
    let engine: EngineClient
    let dataDirectory: URL
    var today: UsageReport?
    private(set) var todayUsageError: String?
    var todayTurns: TurnPresentation?
    var todaySpeedError: String?
    private var todayGeneration = 0
    private(set) var todayDay: String?
    var report: UsageReport?
    var reportFilter: UsageFilter?
    var activity: ActivityReport?
    var activityCalendar: UsageActivity?
    @ObservationIgnored private var historyCache: [HistorySelection: UsageHistory] = [:]
    private struct HistorySelection: Hashable {
        let metric: UsageMetric
        let average: Bool
        let client: String?
    }
    func history(metric: UsageMetric, average: Bool, client: String?) -> UsageHistory? {
        guard let activity else { return nil }
        let key = HistorySelection(metric: metric, average: average, client: client)
        if let cached = historyCache[key] { return cached }
        let data = UsageHistory(report: activity, metric: metric, average: average, client: client, calendarDays: activityCalendar?.days)
        historyCache[key] = data
        return data
    }
    var catalog: UsageReport?
    var turnAnalytics: TurnPresentation?
    var turnsQuery: TurnQuery?
    var turnModel: String?
    var turnClient: String?
    var turnsLoading = false
    var turnsError: String?
    private var requestedTurnQuery: TurnQuery?
    private var turnsGeneration = 0
    var filter = UsageFilter()
    var dateRange: UsageDateRange = .week
    var status: EngineStatus?
    var scanning = false
    var connected = false
    var loading = false
    var error: String?
    var sources: JSONValue = .null
    var prices: JSONValue = .null
    var priceProviders: [PriceProviderGroup] = []
    var usedPriceModels: Set<PriceModelIdentity> = []
    var settings: EngineSettings?
    var clients: [ClientInfo] = []
    private var eventTask: Task<Void, Never>?
    private var refreshGeneration = 0

    init(engine: EngineClient? = nil, directory: URL? = nil) {
        let directory = directory ?? ProcessInfo.processInfo.environment["TOKENORY_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Tokenory")
        dataDirectory = directory
        self.engine = engine ?? EngineClient(helper: Bundle.main.bundleURL.appending(path: "Contents/Helpers/tokenory"), directory: directory)
        updateDateRange()
    }
    static func day(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }
    func start() {
        if eventTask == nil {
            eventTask = Task { [weak self, engine] in
                for await event in engine.events { guard let self else { return }; await consume(event) }
            }
        }
        Task {
            do { try await engine.start(); connected = true; error = nil; await refresh() }
            catch { fail(error) }
        }
    }
    func updateDateRange(now: Date = Date()) {
        guard dateRange != .custom else { return }
        let prior = filter
        filter.to = dateRange == .all ? nil : Self.day(now)
        switch dateRange {
        case .today: filter.from = Self.day(now)
        case .week: filter.from = Self.day(now.addingTimeInterval(-6 * 86400))
        case .month: filter.from = Self.day(now.addingTimeInterval(-29 * 86400))
        case .all: filter.from = nil
        case .custom: break
        }
        if filter != prior { filter.offset = 0 }
    }
    func refresh(now: Date = Date()) async {
        updateDateRange(now: now)
        refreshGeneration += 1; let generation = refreshGeneration; loading = true
        let day = Self.day(now)
        let quickGeneration = beginTodayRefresh(day: day)
        async let quick: Void = loadToday(day: day, generation: quickGeneration)
        do {
            let queryFilter = filter
            let dashboardFilter = try JSONValue.encode(queryFilter)
            var historyFilter = queryFilter
            let calendar = Localization.reportingCalendar
            let start = calendar.date(byAdding: .year, value: -1, to: calendar.startOfDay(for: now))!
            historyFilter.from = Self.day(calendar.date(byAdding: .day, value: 1, to: start)!)
            historyFilter.to = day
            historyFilter.offset = 0
            async let dashboard = engine.request("overview", payload: dashboardFilter)
            async let history = engine.request("activity", payload: .encode(historyFilter))
            async let all = engine.request("overview")
            async let engineStatus = engine.request("status")
            let results = try await (dashboard, all, engineStatus, history)
            guard generation == refreshGeneration else { return }
            let newReport = try results.0.decode(UsageReport.self)
            let newCatalog = try results.1.decode(UsageReport.self)
            let newStatus = try results.2.decode(EngineStatus.self)
            let newActivity = try results.3.decode(ActivityReport.self)
            report = newReport; reportFilter = queryFilter; catalog = newCatalog
            activityCalendar = UsageActivity(report: newActivity)
            historyCache.removeAll(keepingCapacity: true)
            activity = newActivity; status = newStatus; scanning = newStatus.scanning; connected = true
        } catch { if generation == refreshGeneration { fail(error) } }
        await quick
        if generation == refreshGeneration { loading = false }
    }
    func refreshToday(now: Date = Date()) async {
        let prior = filter
        updateDateRange(now: now)
        if prior != filter { await refresh(now: now); return }
        let day = Self.day(now)
        let generation = beginTodayRefresh(day: day)
        await loadToday(day: day, generation: generation)
    }
    private func beginTodayRefresh(day: String) -> Int {
        todayGeneration += 1
        if todayDay != day {
            today = nil; todayTurns = nil; todaySpeedError = nil; todayUsageError = nil
            todayDay = day
        }
        return todayGeneration
    }
    private func loadToday(day: String, generation: Int) async {
        async let usage = engine.request("overview", payload: .encode(UsageFilter(from: day, to: day)))
        async let turns = engine.request("turnAnalytics", payload: .encode(TurnQuery(from: day, to: day)))
        do {
            let data = try await usage.decode(UsageReport.self)
            if generation == todayGeneration { today = data; todayUsageError = nil }
        } catch {
            if generation == todayGeneration { todayUsageError = error.localizedDescription; fail(error) }
        }
        do {
            let data = TurnPresentation(report: try await turns.decode(TurnReport.self))
            guard generation == todayGeneration else { return }
            todayTurns = data; todaySpeedError = nil
        } catch {
            guard generation == todayGeneration else { return }
            todayTurns = nil; todaySpeedError = error.localizedDescription
        }
    }
    func restore(from file: URL) async throws {
        do { try await engine.restore(from: file) }
        catch { start(); throw error }
        try await engine.start(); error = nil; await refresh(); await loadManagement()
    }
    func loadSources() async {
        do {
            let response = try await engine.request("sources")
            let decodedClients = try response["clients"].decode([ClientInfo].self)
            sources = response; clients = decodedClients
        } catch { fail(error) }
    }
    func loadAgentTurns(_ query: TurnQuery, force: Bool = false) async {
        if !force, requestedTurnQuery == query,
           turnsLoading || (turnsQuery == query && turnsError == nil) { return }
        requestedTurnQuery = query
        turnsGeneration += 1
        let generation = turnsGeneration
        turnsLoading = true; turnsError = nil
        do {
            let response = try await engine.request("turnAnalytics", payload: .encode(query)).decode(TurnReport.self)
            guard generation == turnsGeneration else { return }
            turnAnalytics = TurnPresentation(report: response)
            turnsQuery = query
        } catch {
            if generation == turnsGeneration { turnsError = error.localizedDescription }
        }
        if generation == turnsGeneration { turnsLoading = false }
    }
    func loadManagement() async {
        do {
            async let s = engine.request("sources"); async let p = engine.request("prices"); async let c = engine.request("settings")
            let values = try await (s, p, c)
            let catalog = try values.1.decode(PriceCatalogResponse.self)
            clients = try values.0["clients"].decode([ClientInfo].self)
            sources = values.0; prices = values.1; settings = try values.2.decode(EngineSettings.self)
            usedPriceModels = Set(catalog.usedModels ?? [])
            priceProviders = PriceProviderGroup.make(catalog.catalog ?? catalog.current?.snapshot.entries ?? [])
        } catch { fail(error) }
    }
    @discardableResult
    func perform(_ operation: String, payload: JSONValue = .object([:])) async throws -> JSONValue {
        return try await engine.request(operation, payload: payload)
    }
    func scan() { Task { do { _ = try await perform("scan") } catch { fail(error) } } }
    func fail(_ error: Error) { self.error = error.localizedDescription }
    func consume(_ event: EngineEnvelope) async {
        switch event.event {
        case "ready": connected = true
        case "scanStarted": scanning = true
        case "scanFinished":
            scanning = false
            do { status = try await engine.request("status").decode(EngineStatus.self) } catch { fail(error) }
            await refreshToday()
            if sources != .null { await loadSources() }
            if let query = requestedTurnQuery { await loadAgentTurns(query, force: true) }
        case "todayUsageChanged": await refreshToday()
        case "usageChanged": await refresh()
        case "pricesUpdated": await loadManagement()
        case "scanFailed": scanning = false; error = event.message
        case "stopped": connected = false; scanning = false; error = event.message
        default: break
        }
    }
    var statusText: String {
        if !connected { return L("status.stopped") }
        if scanning { return L("status.scanning") }
        if let scan = status?.lastScan {
            if scan.sources.contains(where: { $0.status == "partial" }) { return L("status.partial") }
            return L("status.updated")
        }
        return L("status.waiting")
    }
}
