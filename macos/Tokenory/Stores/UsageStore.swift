// [INPUT]: 接收引擎报告、目录和设置协议。
// [OUTPUT]: 按系统日期刷新统计及来源，在需要操作时展示提示，确认恢复后清除相应提示。
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
    enum ErrorAction { case refresh, reconnect, acknowledge }

    private enum Recovery {
        case scan, status, statistics, activity, todayUsage, management
    }

    private struct Failure {
        let id = UUID()
        let message: String
        let recovery: Recovery?
        let action: ErrorAction?
    }

    static let shared = UsageStore()
    let engine: EngineClient
    let cloud: DeviceSyncStore
    var combinedOverview: UsageReport? { cloud.overview(for: reportFilter) }
    var cloudLocalOverview: UsageReport? { cloud.local(for: reportFilter) }
    var cloudLocalActivityCalendar: UsageActivity? { cloud.localCalendar }
    var remoteOverviewReports: [String: UsageReport] { cloud.remote(for: reportFilter) }
    var combinedActivity: ActivityReport? { cloud.activity }
    var remoteActivityReports: [String: ActivityReport] { cloud.remoteActivity }
    var combinedActivityCalendar: UsageActivity? { cloud.calendar }
    var remoteActivityCalendars: [String: UsageActivity] { cloud.remoteCalendars }
    var localDeviceName: String { cloud.localName }
    func deviceName(_ id: String) -> String { cloud.name(id) }
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
        if let reportFailure, reportFailure.selection == reportSelection { return reportFailure.message }
        return connected || loading ? nil : error
    }
    var activity: ActivityReport?
    var activityCalendar: UsageActivity?
    @ObservationIgnored private var historyCache: [HistorySelection: UsageHistory] = [:]
    @ObservationIgnored private var reportCache: [UsageFilter: UsageReport] = [:]
    @ObservationIgnored private var reportCacheRevision: Int64?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    private struct HistorySelection: Hashable {
        let revision: Int64
        let localOnly: Bool
        let projectionVersion: Int
        let metric: UsageMetric
        let average: Bool
        let client: String?
    }
    func history(metric: UsageMetric, average: Bool, client: String?, localOnly: Bool = true) -> UsageHistory? {
        guard let activity = localOnly ? activity : (combinedActivity ?? activity) else { return nil }
        let key = HistorySelection(revision: activity.revision, localOnly: localOnly, projectionVersion: localOnly ? 0 : cloud.annualVersion, metric: metric, average: average, client: client)
        if let cached = historyCache[key] { return cached }
        let data = UsageHistory(report: activity, metric: metric, average: average, client: client, calendarDays: (localOnly ? activityCalendar : (combinedActivityCalendar ?? activityCalendar))?.days)
        historyCache = historyCache.filter { $0.key.localOnly != localOnly || ($0.key.revision == activity.revision && $0.key.projectionVersion == key.projectionVersion) }
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
    var recordsAreActive = false
    private(set) var recordConversation: UsageConversation?
    var reportSelection: UsageFilter {
        var selection = filter
        selection.conversation = recordsAreActive ? recordConversation?.id : nil
        return selection
    }
    var dateRange: UsageDateRange = .week
    var status: EngineStatus?
    var scanning = false
    private(set) var scanRequested = false
    var scanInProgress: Bool { scanning || scanRequested }
    var connected = false
    var loading = false
    private var failure: Failure?
    var error: String? { errorAction == nil ? nil : failure?.message }
    var errorAction: ErrorAction? { failure?.action }
    var sources: JSONValue = .null
    private(set) var sourcesError: String?
    private var sourcesGeneration = 0
    var prices: JSONValue = .null
    var priceProviders: [PriceProviderGroup] = []
    var usedPriceModels: Set<PriceModelIdentity> = []
    var settings: EngineSettings?
    var clients: [ClientInfo] = []
    private var eventTask: Task<Void, Never>?
    private var dayTask: Task<Void, Never>?
    private(set) var systemTimeZone = TimeZone.current
    private(set) var todayTimeZone: String?
    private var refreshGeneration = 0
    private var reportGeneration = 0
    private var requestedReportFilter: UsageFilter?
    private var reportFailure: (selection: UsageFilter, message: String)?
    private var activityFilter: UsageFilter?
    private var requestedActivityFilter: UsageFilter?
    private var activityGeneration = 0

    init(engine: EngineClient? = nil, directory: URL? = nil) {
        let primaryLedger = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Tokenory")
        let directory = directory ?? ProcessInfo.processInfo.environment["TOKENORY_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? primaryLedger
        dataDirectory = directory
        self.engine = engine ?? EngineClient(helper: Bundle.main.bundleURL.appending(path: "Contents/Helpers/tokenory"), directory: directory)
        cloud = DeviceSyncStore(engine: self.engine, usesDefaultLedger: directory.standardizedFileURL.path == primaryLedger.standardizedFileURL.path)
        updateDateRange()
    }
    static func day(_ date: Date) -> String { Localization.dayKey(date) }
    func start() {
        if eventTask == nil {
            eventTask = Task { [weak self, engine] in
                for await event in engine.events { guard let self else { return }; await consume(event) }
            }
            scheduleDayRefresh()
        }
        Task {
            do {
                try await engine.start()
                connected = true
                if errorAction != .reconnect { dismissError() }
                cloud.start()
                await refresh()
            } catch {
                connected = false
                recordFailure(error.localizedDescription, action: .reconnect)
            }
        }
    }

    private func scheduleDayRefresh() {
        dayTask?.cancel()
        let midnight = LocalUsageDay(now: .now).end
        dayTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, midnight.timeIntervalSinceNow))) } catch { return }
            guard !Task.isCancelled else { return }
            self?.systemClockChanged()
        }
    }

    func systemClockChanged() {
        let zone = TimeZone.current
        let changedZone = zone != systemTimeZone
        if changedZone { systemTimeZone = zone }
        scheduleDayRefresh()
        guard connected else { return }
        Task {
            if changedZone {
                await refresh()
                if let query = requestedTurnQuery { await loadAgentTurns(query, force: true) }
            } else {
                await refreshToday()
            }
        }
    }

    func retryReport() async {
        guard connected else {
            reportFailure = nil
            dismissError()
            start()
            return
        }
        await refreshSelection(reportSelection, forceReport: true)
    }

    func selectConversation(_ conversation: UsageConversation?) {
        if recordConversation?.id != conversation?.id { filter.offset = 0 }
        recordConversation = conversation
    }

    func clearRecordFilters() {
        recordConversation = nil
        var selection = filter
        selection.client = nil
        selection.provider = nil
        selection.model = nil
        selection.source = nil
        selection.offset = 0
        filter = selection
    }

    func findConversations(_ lookup: ConversationLookup) async throws -> [UsageConversation] {
        try await engine.request("conversations", payload: .encode(lookup), as: [UsageConversation].self)
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
        let previous = failure
        updateDateRange(now: now)
        refreshGeneration += 1
        let generation = refreshGeneration
        let localDay = LocalUsageDay(now: now)
        let quickGeneration = beginTodayRefresh(window: localDay)
        await refreshReport(reportSelection, now: now, force: true)
        guard generation == refreshGeneration else { return }
        async let history: Void = refreshActivity(for: filter, now: now, force: true)
        async let quick: Void = loadToday(window: localDay, generation: quickGeneration)
        do {
            async let all = engine.request("overview", as: UsageReport.self)
            async let engineStatus = engine.request("status", as: EngineStatus.self)
            let (newCatalog, newStatus) = try await (all, engineStatus)
            if generation == refreshGeneration {
                catalog = newCatalog; status = newStatus; scanning = newStatus.scanning; connected = true
                resolveFailure(previous, for: .statistics, .status)
            }
        } catch { if generation == refreshGeneration { fail(error, recovery: .statistics) } }
        _ = await (history, quick)
        if generation == refreshGeneration {
            prefetchPresetRanges(now: now)
        }
    }
    private func cacheReport(_ selected: UsageReport, for selection: UsageFilter) {
        if reportCacheRevision != selected.revision {
            reportCache.removeAll(keepingCapacity: true)
            reportCacheRevision = selected.revision
        }
        if reportCache.count >= 24 { reportCache.removeAll(keepingCapacity: true) }
        reportCache[selection] = selected
    }
    private func prefetchPresetRanges(now: Date) {
        prefetchTask?.cancel()
        guard connected, let expectedRevision = reportCacheRevision else { return }
        let calendar = Localization.reportingCalendar
        let today = calendar.startOfDay(for: now)
        let base = filter
        let presets: [UsageDateRange] = [.today, .week, .month, .all]
        let candidates: [UsageFilter] = presets.compactMap { preset in
            var selection = base
            selection.conversation = nil
            selection.offset = 0
            selection.to = preset == .all ? nil : Self.day(now)
            selection.from = preset.dayCount
                .flatMap { calendar.date(byAdding: .day, value: 1 - $0, to: today) }
                .map(Self.day)
            return reportCache[selection] == nil ? selection : nil
        }
        guard !candidates.isEmpty else { return }
        prefetchTask = Task(priority: .utility) { [weak self] in
            for candidate in candidates {
                guard !Task.isCancelled, let self, self.connected, self.reportCacheRevision == expectedRevision else { return }
                if self.reportCache[candidate] != nil { continue }
                guard let prefetched = try? await self.engine.request("overview", payload: .encode(candidate), as: UsageReport.self) else {
                    continue
                }
                guard !Task.isCancelled, self.reportCacheRevision == expectedRevision, prefetched.revision == expectedRevision else { return }
                self.cacheReport(prefetched, for: candidate)
            }
        }
    }
    func refreshSelection(_ selection: UsageFilter, now: Date = Date(), forceReport: Bool = false) async {
        guard selection == reportSelection else { return }
        await refreshReport(selection, now: now, force: forceReport)
        guard selection == reportSelection, reportFilter == selection else { return }
        await refreshActivity(for: selection, now: now, force: false)
    }
    private func refreshReport(_ selection: UsageFilter, now: Date, force: Bool) async {
        if !force, reportFilter == selection {
            if let pending = requestedReportFilter, pending != selection {
                reportGeneration += 1
                requestedReportFilter = nil
                loading = false
            }
            return
        }
        guard force || requestedReportFilter != selection else { return }
        reportGeneration += 1
        let generation = reportGeneration
        requestedReportFilter = selection
        reportFailure = nil
        defer {
            if generation == reportGeneration { requestedReportFilter = nil; loading = false }
        }
        if !force, let cached = reportCache[selection] {
            if selection.conversation != nil {
                report = cached
                reportFilter = selection
                return
            }
            let year = Self.reportingYear(ending: now)
            await cloud.select(selection, from: year.from, to: year.to, whileCurrent: {
                self.reportGeneration == generation && self.reportSelection == selection
            }) {
                self.report = cached
                self.reportFilter = selection
            }
            return
        }
        if !force, !recordsAreActive, selection.conversation == nil, selection.source == nil,
           let instantLocal = cloud.instantLocalOverview(for: selection) {
            let year = Self.reportingYear(ending: now)
            await cloud.select(selection, from: year.from, to: year.to, whileCurrent: {
                self.reportGeneration == generation && self.reportSelection == selection
            }) {
                self.report = instantLocal
                self.reportFilter = selection
            }
            guard generation == reportGeneration, selection == reportSelection else { return }
            // Silently fetch exact local report (records, local-TZ hourly, Codex subagent details) without re-triggering range animations.
            do {
                let selected = try await engine.request("overview", payload: .encode(selection), as: UsageReport.self)
                guard generation == reportGeneration, selection == reportSelection else { return }
                cacheReport(selected, for: selection)
                report = selected
                reportFilter = selection
            } catch {
                // Keep the instant snapshot reading visible; background refinement failure stays silent.
            }
            return
        }
        loading = true
        do {
            let selected = try await engine.request("overview", payload: .encode(selection), as: UsageReport.self)
            guard generation == reportGeneration, selection == reportSelection else { return }
            cacheReport(selected, for: selection)
            if selection.conversation != nil {
                report = selected
                reportFilter = selection
            } else {
                let year = Self.reportingYear(ending: now)
                await cloud.select(selection, from: year.from, to: year.to, whileCurrent: {
                    self.reportGeneration == generation && self.reportSelection == selection
                }) {
                    self.report = selected
                    self.reportFilter = selection
                }
            }
        } catch {
            if generation == reportGeneration, selection == reportSelection {
                reportFailure = (selection, error.localizedDescription)
            }
        }
    }
    private static func reportingYear(ending now: Date) -> (from: String, to: String) {
        let calendar = Localization.reportingCalendar
        let start = calendar.date(byAdding: .year, value: -1, to: calendar.startOfDay(for: now))!
        return (day(calendar.date(byAdding: .day, value: 1, to: start)!), day(now))
    }
    private func refreshActivity(for selection: UsageFilter, now: Date, force: Bool) async {
        let (from, to) = Self.reportingYear(ending: now)
        let annual = annualFilter(for: selection, from: from, to: to)
        guard force || (requestedActivityFilter != annual && activityFilter != annual) else { return }
        activityGeneration += 1
        let generation = activityGeneration
        let previous = failure
        requestedActivityFilter = annual
        defer { if generation == activityGeneration { requestedActivityFilter = nil } }
        do {
            let newActivity = try await engine.request("activity", payload: .encode(annual), as: ActivityReport.self)
            guard generation == activityGeneration, annual == annualFilter(for: filter, from: from, to: to) else { return }
            activityFilter = annual
            activityCalendar = UsageActivity(report: newActivity)
            historyCache.removeAll(keepingCapacity: true)
            activity = newActivity
            resolveFailure(previous, for: .activity)
        } catch {
            if generation == activityGeneration, annual == annualFilter(for: filter, from: from, to: to) {
                fail(error, recovery: .activity)
            }
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
        let previous = failure
        async let usage = engine.request("overview", payload: .encode(UsageFilter(from: window.day, to: window.day, timestampFromMs: window.startMs, timestampToMs: window.endMs)))
        async let turns = engine.request("turnAnalytics", payload: .encode(TurnQuery(from: window.day, to: window.day, timestampFromMs: window.startMs, timestampToMs: window.endMs)))
        do {
            let data = try await usage.decode(UsageReport.self)
            if generation == todayGeneration {
                today = data; todayUsageError = nil
                resolveFailure(previous, for: .todayUsage)
            }
        } catch {
            if generation == todayGeneration {
                todayUsageError = error.localizedDescription
                fail(error, recovery: .todayUsage)
            }
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
        try await engine.start(); dismissError(); cloud.refresh(localChanged: true); await refresh(); await loadManagement()
    }
    func loadSources() async {
        sourcesGeneration += 1
        let generation = sourcesGeneration
        do {
            let response = try await engine.request("sources")
            let decodedClients = try response["clients"].decode([ClientInfo].self)
            guard generation == sourcesGeneration else { return }
            sources = response; clients = decodedClients
            sourcesError = nil
        } catch {
            if generation == sourcesGeneration { sourcesError = error.localizedDescription }
        }
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
            turnAnalytics = TurnPresentation(report: response, query: query)
            turnsQuery = query
        } catch {
            if generation == turnsGeneration { turnsError = error.localizedDescription }
        }
        if generation == turnsGeneration { turnsLoading = false }
    }
    func loadManagement(notifyOnFailure: Bool = true) async {
        let previous = failure
        do {
            async let s = engine.request("sources"); async let p = engine.request("prices"); async let c = engine.request("settings")
            let values = try await (s, p, c)
            let catalog = try values.1.decode(PriceCatalogResponse.self)
            clients = try values.0["clients"].decode([ClientInfo].self)
            sourcesGeneration += 1
            sourcesError = nil
            sources = values.0; prices = values.1; settings = try values.2.decode(EngineSettings.self)
            usedPriceModels = Set(catalog.usedModels ?? [])
            priceProviders = PriceProviderGroup.make(catalog.catalog ?? catalog.current?.snapshot.entries ?? [])
            resolveFailure(previous, for: .management)
        } catch {
            fail(error, recovery: .management, action: notifyOnFailure ? .acknowledge : nil)
        }
    }
    @discardableResult
    func perform(_ operation: String, payload: JSONValue = .object([:])) async throws -> JSONValue {
        return try await engine.request(operation, payload: payload)
    }
    func scan() {
        guard !scanRequested else { return }
        scanRequested = true
        Task {
            do {
                let response = try await perform("scan")
                if response["started"].bool == false, !scanning {
                    scanRequested = false
                }
            } catch {
                scanRequested = false
                fail(error, recovery: .scan, action: .refresh)
            }
        }
    }

    func dismissError() { failure = nil }
    func fail(_ error: Error) { recordFailure(error.localizedDescription, action: .acknowledge) }

    private func fail(_ error: Error, recovery: Recovery, action: ErrorAction? = nil) {
        let canRetry = (error as? EngineError)?.code == "timeout" || action == .refresh
        recordFailure(error.localizedDescription, recovery: canRetry ? recovery : nil, action: action)
    }

    private func recordFailure(_ message: String, recovery: Recovery? = nil, action: ErrorAction? = nil) {
        guard action != nil || errorAction == nil else { return }
        failure = Failure(message: message, recovery: recovery, action: action)
    }

    private func resolveFailure(_ previous: Failure?, for recovered: Recovery...) {
        guard let previous, let recovery = previous.recovery, recovered.contains(recovery),
              failure?.id == previous.id else { return }
        dismissError()
    }

    func consume(_ event: EngineEnvelope) async {
        switch event.event {
        case "ready":
            connected = true
            if errorAction == .reconnect { dismissError() }
        case "scanStarted": scanning = true
        case "scanFinished":
            let userRequested = scanRequested
            scanning = false
            let previous = failure
            do {
                status = try await engine.request("status", as: EngineStatus.self)
                resolveFailure(previous, for: .scan, .status)
            } catch {
                fail(error, recovery: .status, action: userRequested ? .refresh : nil)
            }
            if userRequested {
                scanRequested = false
                reportCache.removeAll(keepingCapacity: true)
            }
            if userRequested || previous?.recovery == .statistics || previous?.recovery == .activity ||
                reportFailure?.selection == reportSelection {
                await refresh()
            } else {
                await refreshToday()
            }
            if previous?.recovery == .management {
                await loadManagement(notifyOnFailure: previous?.action != nil)
            } else if sources != .null || sourcesError != nil {
                await loadSources()
            }
            if let query = requestedTurnQuery { await loadAgentTurns(query, force: true) }
        case "todayUsageChanged": cloud.markDirty(); await refreshToday()
        case "usageChanged": cloud.refresh(localChanged: true); await refresh()
        case "pricesUpdated": await loadManagement(notifyOnFailure: false)
        case "scanFailed":
            let action: ErrorAction? = scanRequested ? .refresh : nil
            scanRequested = false
            scanning = false
            if let message = event.message { recordFailure(message, recovery: .scan, action: action) }
        case "stopped":
            connected = false
            scanRequested = false
            scanning = false
            recordFailure(event.message ?? L("status.stopped"), action: .reconnect)
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
