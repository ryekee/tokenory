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
    var report: UsageReport?
    var reportFilter: UsageFilter?
    var catalog: UsageReport?
    var filter = UsageFilter()
    var dateRange: UsageDateRange = .month
    var status: EngineStatus?
    var scanning = false
    var connected = false
    var loading = false
    var error: String?
    var sources: JSONValue = .null
    var prices: JSONValue = .null
    var priceProviders: [PriceProviderGroup] = []
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
        do {
            let queryFilter = filter
            let dashboardFilter = try JSONValue.encode(queryFilter)
            let day = Self.day(now); let todayFilter = try JSONValue.encode(UsageFilter(from: day, to: day))
            async let dashboard = engine.request("overview", payload: dashboardFilter)
            async let quick = engine.request("overview", payload: todayFilter)
            async let all = engine.request("overview")
            async let engineStatus = engine.request("status")
            let results = try await (dashboard, quick, all, engineStatus)
            guard generation == refreshGeneration else { return }
            report = try results.0.decode(UsageReport.self); reportFilter = queryFilter; today = try results.1.decode(UsageReport.self); catalog = try results.2.decode(UsageReport.self)
            status = try results.3.decode(EngineStatus.self); scanning = status?.scanning ?? false; connected = true
        } catch { if generation == refreshGeneration { fail(error) } }
        if generation == refreshGeneration { loading = false }
    }
    func refreshToday(now: Date = Date()) async {
        let prior = filter
        updateDateRange(now: now)
        if prior != filter { await refresh(now: now); return }
        let day = Self.day(now)
        do { today = try await engine.request("overview", payload: .encode(UsageFilter(from: day, to: day))).decode(UsageReport.self) }
        catch { fail(error) }
    }
    func restore(from file: URL) async throws {
        do { try await engine.restore(from: file) }
        catch { start(); throw error }
        try await engine.start(); error = nil; await refresh(); await loadManagement()
    }
    func loadManagement() async {
        do {
            async let s = engine.request("sources"); async let p = engine.request("prices"); async let c = engine.request("settings")
            let values = try await (s, p, c)
            let catalog = try values.1.decode(PriceCatalogResponse.self)
            clients = try values.0["clients"].decode([ClientInfo].self)
            sources = values.0; prices = values.1; settings = try values.2.decode(EngineSettings.self)
            priceProviders = PriceProviderGroup.make(catalog.current?.snapshot.entries ?? [])
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
