// [INPUT]: 接收引擎报告、目录和设置协议。
// [OUTPUT]: 日期范围切换，发布筛选结果及请求失败、全年活动、当日用量、回合、价格和采集状态。
// [POS]: 原生界面与 worker 的状态边界。
// [PROTOCOL]: Update this header on change, then check AGENTS.md
import Foundation
import Observation

enum UsageDateRange: String, CaseIterable {
    case today, week, month, all, custom
    var title: String { L("range." + rawValue) }

    fileprivate var dayCount: Int? {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        case .all, .custom: nil
        }
    }
}

@MainActor @Observable
final class UsageStore {
    enum DateStep { case earlier, later }

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
    var reportLoadError: String? {
        if let reportFailure, reportFailure.selection == filter { return reportFailure.message }
        return connected || loading ? nil : error
    }
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
    private(set) var todayTimeZone: String?
    private var refreshGeneration = 0
    private var reportGeneration = 0
    private var requestedReportFilter: UsageFilter?
    private var reportFailure: (selection: UsageFilter, message: String)?
    private var activityFilter: UsageFilter?
    private var requestedActivityFilter: UsageFilter?
    private var activityGeneration = 0

    init(engine: EngineClient? = nil, directory: URL? = nil) {
        let directory = directory ?? ProcessInfo.processInfo.environment["TOKENORY_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Tokenory")
        dataDirectory = directory
        self.engine = engine ?? EngineClient(helper: Bundle.main.bundleURL.appending(path: "Contents/Helpers/tokenory"), directory: directory)
        updateDateRange()
    }
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
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

    func retryReport() async {
        guard connected else {
            reportFailure = nil
            error = nil
            start()
            return
        }
        await refreshSelection(filter, forceReport: true)
    }
    func selectDateRange(_ range: UsageDateRange, now: Date = .now) {
        dateRange = range
        updateDateRange(now: now, resetOffset: true)
    }

    func selectCustomDateRange(_ range: ClosedRange<Date>) {
        dateRange = .custom
        var selection = filter
        selection.from = Self.day(range.lowerBound)
        selection.to = Self.day(range.upperBound)
        selection.offset = 0
        filter = selection
    }

    func steppedDateRange(_ step: DateStep, now: Date = .now) -> ClosedRange<Date>? {
        guard let from = filter.from.flatMap(Localization.date),
              let to = filter.to.flatMap(Localization.date), from <= to else { return nil }
        let calendar = Localization.reportingCalendar
        guard let distance = calendar.dateComponents([.day], from: from, to: to).day else { return nil }
        let length = distance + 1
        let days: Int
        switch step {
        case .earlier: days = -length
        case .later:
            let today = calendar.startOfDay(for: now)
            guard let available = calendar.dateComponents([.day], from: to, to: today).day,
                  available > 0 else { return nil }
            days = min(length, available)
        }
        guard let start = calendar.date(byAdding: .day, value: days, to: from),
              let end = calendar.date(byAdding: .day, value: days, to: to) else { return nil }
        return start...end
    }

    func stepDateRange(_ step: DateStep, now: Date = .now) {
        guard let range = steppedDateRange(step, now: now) else { return }
        let calendar = Localization.reportingCalendar
        let dayCount = calendar.dateComponents([.day], from: range.lowerBound, to: range.upperBound).day.map { $0 + 1 }
        if calendar.isDate(range.upperBound, inSameDayAs: now),
           let dayCount,
           let preset = UsageDateRange.allCases.first(where: { $0.dayCount == dayCount }) {
            selectDateRange(preset, now: now)
        } else {
            selectCustomDateRange(range)
        }
    }

    func updateDateRange(now: Date = Date(), resetOffset: Bool = false) {
        guard dateRange != .custom else { return }
        let calendar = Localization.reportingCalendar
        let today = calendar.startOfDay(for: now)
        var selection = filter
        selection.to = dateRange == .all ? nil : Self.day(now)
        selection.from = dateRange.dayCount
            .flatMap { calendar.date(byAdding: .day, value: 1 - $0, to: today) }
            .map(Self.day)
        if resetOffset || selection != filter { selection.offset = 0 }
        if selection != filter { filter = selection }
    }
    func refresh(now: Date = Date()) async {
        updateDateRange(now: now)
        refreshGeneration += 1
        let generation = refreshGeneration
        let localDay = LocalUsageDay(now: now)
        let quickGeneration = beginTodayRefresh(window: localDay)
        await refreshReport(filter, force: true)
        guard generation == refreshGeneration else { return }
        async let history: Void = refreshActivity(for: filter, now: now, force: true)
        async let quick: Void = loadToday(window: localDay, generation: quickGeneration)
        do {
            async let all = engine.request("overview", as: UsageReport.self)
            async let engineStatus = engine.request("status", as: EngineStatus.self)
            let (newCatalog, newStatus) = try await (all, engineStatus)
            if generation == refreshGeneration {
                catalog = newCatalog; status = newStatus; scanning = newStatus.scanning; connected = true
            }
        } catch { if generation == refreshGeneration { fail(error) } }
        _ = await (history, quick)
    }
    func refreshSelection(_ selection: UsageFilter, now: Date = Date(), forceReport: Bool = false) async {
        guard selection == filter else { return }
        await refreshReport(selection, force: forceReport)
        guard selection == filter, reportFilter == selection else { return }
        await refreshActivity(for: selection, now: now, force: false)
    }
    private func refreshReport(_ selection: UsageFilter, force: Bool) async {
        guard force || (requestedReportFilter != selection && reportFilter != selection) else { return }
        reportGeneration += 1
        let generation = reportGeneration
        requestedReportFilter = selection
        reportFailure = nil
        loading = true
        defer {
            if generation == reportGeneration { requestedReportFilter = nil; loading = false }
        }
        do {
            let selected = try await engine.request("overview", payload: .encode(selection), as: UsageReport.self)
            guard generation == reportGeneration, selection == filter else { return }
            report = selected
            reportFilter = selection
        } catch {
            if generation == reportGeneration, selection == filter {
                reportFailure = (selection, error.localizedDescription)
            }
        }
    }
    private func refreshActivity(for selection: UsageFilter, now: Date, force: Bool) async {
        let calendar = Localization.reportingCalendar
        let start = calendar.date(byAdding: .year, value: -1, to: calendar.startOfDay(for: now))!
        let from = Self.day(calendar.date(byAdding: .day, value: 1, to: start)!)
        let to = Self.day(now)
        let annual = annualFilter(for: selection, from: from, to: to)
        guard force || (requestedActivityFilter != annual && activityFilter != annual) else { return }
        activityGeneration += 1
        let generation = activityGeneration
        requestedActivityFilter = annual
        defer { if generation == activityGeneration { requestedActivityFilter = nil } }
        do {
            let newActivity = try await engine.request("activity", payload: .encode(annual), as: ActivityReport.self)
            guard generation == activityGeneration, annual == annualFilter(for: filter, from: from, to: to) else { return }
            activityFilter = annual
            activityCalendar = UsageActivity(report: newActivity)
            historyCache.removeAll(keepingCapacity: true)
            activity = newActivity
        } catch {
            if generation == activityGeneration, annual == annualFilter(for: filter, from: from, to: to) { fail(error) }
        }
    }
    private func annualFilter(for selection: UsageFilter, from: String, to: String) -> UsageFilter {
        UsageFilter(from: from, to: to, client: selection.client, provider: selection.provider, model: selection.model,
                    source: selection.source, timestampFromMs: selection.timestampFromMs, timestampToMs: selection.timestampToMs)
    }
    func refreshToday(now: Date = Date()) async {
        let prior = filter
        updateDateRange(now: now)
        if prior != filter { await refresh(now: now); return }
        let window = LocalUsageDay(now: now)
        let generation = beginTodayRefresh(window: window)
        await loadToday(window: window, generation: generation)
    }
    private func beginTodayRefresh(window: LocalUsageDay) -> Int {
        todayGeneration += 1
        if todayDay != window.day || todayTimeZone != window.timeZone {
            today = nil; todayTurns = nil; todaySpeedError = nil; todayUsageError = nil
            todayDay = window.day; todayTimeZone = window.timeZone
        }
        return todayGeneration
    }
    private func loadToday(window: LocalUsageDay, generation: Int) async {
        async let usage = engine.request("overview", payload: .encode(UsageFilter(from: window.day, to: window.day, timestampFromMs: window.startMs, timestampToMs: window.endMs)))
        async let turns = engine.request("turnAnalytics", payload: .encode(TurnQuery(from: window.day, to: window.day, timestampFromMs: window.startMs, timestampToMs: window.endMs)))
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
            let response = try await engine.request("turnAnalytics", payload: .encode(query), as: TurnReport.self)
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
