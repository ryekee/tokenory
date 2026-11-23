// [INPUT]: A local worker, the signed private CloudKit store and the selected reporting period.
// [OUTPUT]: Sync controls, device sources and atomically selected per-device reports with reusable annual activity.
// [POS]: Keeps remote summaries outside the local ledger, HUD, records and speed queries.
import CloudKit
import Foundation
import Observation

struct DeviceSourceSummary: Identifiable, Sendable {
    let id: String
    let name: String
    let updatedAt: Date
    let clients: [UsageGroup]
}

private struct DeviceProjection: Sendable {
    let filter: UsageFilter
    let overview: UsageReport
    let local: UsageReport
    let remote: [String: UsageReport]
    let snapshotVersion: Int
    let annual: DeviceAnnualProjection
}

private struct DeviceAnnualProjection: Sendable {
    let filter: UsageFilter
    let localCalendar: UsageActivity
    let activity: ActivityReport
    let remoteActivity: [String: ActivityReport]
    let calendar: UsageActivity
    let remoteCalendars: [String: UsageActivity]
}

@MainActor @Observable
final class DeviceSyncStore {
    private let service: DeviceCloudSync
    private let loadSnapshot: @Sendable () async throws -> DeviceUsageSnapshot
    let availableForLedger: Bool
    private(set) var enabled: Bool
    private(set) var busy = false
    private(set) var managing = false
    private(set) var lastContact: Date?
    private(set) var managementError: String?
    private var transferError: String?
    var message: String? { managementError ?? transferError }
    private(set) var sources: [DeviceSourceSummary] = []
    private(set) var remoteCatalog: UsageReport?
    private var projection: DeviceProjection?
    @ObservationIgnored private var snapshots: [String: DeviceUsageSnapshot] = [:]
    @ObservationIgnored private var remoteDates: [String: Date] = [:]
    @ObservationIgnored private var localDirty = true
    @ObservationIgnored private var uploadPending = false
    @ObservationIgnored private var selection = UsageFilter()
    @ObservationIgnored private var year: (String, String)?
    @ObservationIgnored private var snapshotVersion = 0
    private(set) var annualVersion = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var accountObserver: Task<Void, Never>?
    @ObservationIgnored private var pending = false

    var localName: String { service.deviceName }
    func name(_ id: String) -> String { sources.first { $0.id == id }?.name ?? id }
    func overview(for filter: UsageFilter?) -> UsageReport? { projection?.filter == filter ? projection?.overview : nil }
    func remote(for filter: UsageFilter?) -> [String: UsageReport] { projection?.filter == filter ? projection?.remote ?? [:] : [:] }
    func local(for filter: UsageFilter?) -> UsageReport? { projection?.filter == filter ? projection?.local : nil }
    var localCalendar: UsageActivity? { projection?.annual.localCalendar }
    var activity: ActivityReport? { projection?.annual.activity }
    var remoteActivity: [String: ActivityReport] { projection?.annual.remoteActivity ?? [:] }
    var calendar: UsageActivity? { projection?.annual.calendar }
    var remoteCalendars: [String: UsageActivity] { projection?.annual.remoteCalendars ?? [:] }

    convenience init(engine: EngineClient, usesDefaultLedger: Bool) {
        self.init(service: DeviceCloudSync(),
                  availableForLedger: usesDefaultLedger && ProcessInfo.processInfo.environment["TOKENORY_TESTING"] != "1") {
            try await engine.request("deviceUsageSnapshot", as: DeviceUsageSnapshot.self)
        }
    }

    init(service: DeviceCloudSync, availableForLedger: Bool = true,
         loadSnapshot: @escaping @Sendable () async throws -> DeviceUsageSnapshot) {
        self.loadSnapshot = loadSnapshot
        self.service = service
        self.availableForLedger = availableForLedger
        enabled = availableForLedger && service.isEnabled
    }

    func start() {
        guard availableForLedger, timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        accountObserver = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .CKAccountChanged).map({ _ in true }) {
                guard let self else { return }
                generation += 1
                resetSnapshots()
                lastContact = nil
                refresh(localChanged: true)
            }
        }
        #if CLOUD_DEVELOPMENT
        if ProcessInfo.processInfo.arguments.contains("--enable-icloud-sync"), !enabled { Task { await enable() } }
        #endif
    }

    /// Publish the matching local report and device breakdown in a single main-actor turn.
    func select(_ filter: UsageFilter, from: String, to: String,
                whileCurrent: () -> Bool = { true }, commit: () -> Void = {}) async {
        var annualFilter = filter
        annualFilter.from = from
        annualFilter.to = to
        annualFilter.offset = 0
        annualFilter.limit = UsageFilter().limit
        while whileCurrent() {
            let version = snapshotVersion
            let old = projection
            let reusable = old?.snapshotVersion == version && old?.annual.filter == annualFilter
            let next: DeviceProjection?
            if reusable, old?.filter == filter {
                next = old
            } else if let localSnapshot = snapshots[service.deviceID], snapshots.count > 1 {
                let all = snapshots, id = service.deviceID
                let cachedAnnual = reusable ? old?.annual : nil
                next = await Task.detached(priority: .userInitiated) { [annualFilter] in
                    let local = [id: localSnapshot]
                    let others = all.filter { $0.key != id }
                    let annual = cachedAnnual ?? Self.buildAnnual(all: all, local: local, others: others,
                                                                  filter: annualFilter, from: from, to: to)
                    return DeviceProjection(filter: filter, overview: DeviceUsageSnapshot.overview(devices: all, filter: filter),
                                            local: DeviceUsageSnapshot.overview(devices: local, filter: filter),
                                            remote: others.reduce(into: [:]) { rows, item in
                                                rows[item.key] = DeviceUsageSnapshot.overview(devices: [item.key: item.value], filter: filter)
                                            }, snapshotVersion: version, annual: annual)
                }.value
            } else {
                next = nil
            }
            guard whileCurrent() else { return }
            guard version == snapshotVersion else { continue }
            selection = filter
            year = (from, to)
            if !reusable, next != nil || projection != nil { annualVersion += 1 }
            projection = next
            commit()
            return
        }
    }

    nonisolated private static func buildAnnual(all: [String: DeviceUsageSnapshot], local: [String: DeviceUsageSnapshot],
                                                others: [String: DeviceUsageSnapshot], filter: UsageFilter,
                                                from: String, to: String) -> DeviceAnnualProjection {
        func activity(_ devices: [String: DeviceUsageSnapshot]) -> ActivityReport {
            DeviceUsageSnapshot.activity(devices: devices, filter: filter, from: from, to: to)
        }
        let combined = activity(all)
        let remote = others.reduce(into: [String: ActivityReport]()) { results, item in
            results[item.key] = activity([item.key: item.value])
        }
        return DeviceAnnualProjection(filter: filter, localCalendar: UsageActivity(report: activity(local)),
                                      activity: combined, remoteActivity: remote, calendar: UsageActivity(report: combined),
                                      remoteCalendars: remote.mapValues(UsageActivity.init(report:)))
    }

    func markDirty() { localDirty = true }

    func refresh(localChanged: Bool = false) {
        guard availableForLedger else { return }
        if localChanged { localDirty = true }
        guard enabled || service.hasParticipated else { return }
        if busy || managing { pending = true; return }
        busy = true
        let ticket = generation
        Task {
            defer {
                busy = false
                if pending { pending = false; refresh() }
            }
            do {
                let id = service.deviceID
                let needsLocal = localDirty || snapshots[id] == nil
                let publication = enabled && (needsLocal || uploadPending) ? try await service.beginPublication() : nil
                if needsLocal {
                    localDirty = false
                    do {
                        let snapshot = try await loadSnapshot()
                        guard ticket == generation else { return }
                        snapshots[id] = snapshot
                        uploadPending = enabled
                        snapshotsChanged()
                    } catch {
                        localDirty = true
                        throw error
                    }
                }
                if let publication, uploadPending, let snapshot = snapshots[id] {
                    let data = try await Task.detached(priority: .utility) {
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.sortedKeys]
                        return try encoder.encode(snapshot)
                    }.value
                    try await service.publish(data, revision: snapshot.revision, publication: publication)
                    guard ticket == generation else { return }
                    uploadPending = false
                }
                let all = try await service.snapshots()
                guard generation == ticket else { return }
                let others = all.filter { $0.deviceID != id }
                let dates = Dictionary(uniqueKeysWithValues: others.map { ($0.deviceID, $0.updatedAt) })
                if dates != remoteDates {
                    let (decoded, rows, catalog) = try await Task.detached(priority: .utility) {
                        var values: [String: DeviceUsageSnapshot] = [:]
                        var rows: [DeviceSourceSummary] = []
                        for item in others {
                            let snapshot = try JSONDecoder().decode(DeviceUsageSnapshot.self, from: item.data)
                            values[item.deviceID] = snapshot
                            let full = DeviceUsageSnapshot.overview(devices: [item.deviceID: snapshot], filter: .init())
                            rows.append(DeviceSourceSummary(id: item.deviceID, name: item.deviceName, updatedAt: item.updatedAt, clients: full.clients))
                        }
                        return (values, rows.sorted { ($0.name, $0.id) < ($1.name, $1.id) }, DeviceUsageSnapshot.overview(devices: values, filter: .init()))
                    }.value
                    guard ticket == generation else { return }
                    snapshots = decoded.merging(snapshots.filter { $0.key == id }) { _, local in local }
                    sources = rows
                    remoteCatalog = catalog
                    remoteDates = dates
                    snapshotsChanged()
                }
                enabled = service.isEnabled
                lastContact = Date()
                transferError = nil
                #if CLOUD_DEVELOPMENT
                if ProcessInfo.processInfo.arguments.contains("--cloud-sync-receipt") {
                    let totals = snapshots.mapValues { $0.buckets.reduce(Int64(0)) { $0 + $1.summary.tokens } }
                    let items = totals.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                    FileHandle.standardError.write(Data("TOKENORY_SYNC local=\(id) devices=\(all.count) enabled=\(enabled) \(items)\n".utf8))
                }
                #endif
            } catch {
                guard ticket == generation else { return }
                enabled = service.isEnabled
                if let cloudError = error as? DeviceCloudError {
                    switch cloudError {
                    case .revoked, .accountChanged, .noAccount: resetSnapshots()
                    default: break
                    }
                }
                transferError = error.localizedDescription
                #if CLOUD_DEVELOPMENT
                if ProcessInfo.processInfo.arguments.contains("--cloud-sync-receipt") {
                    FileHandle.standardError.write(Data("TOKENORY_SYNC_ERROR \(error.localizedDescription)\n".utf8))
                }
                #endif
            }
        }
    }

    func enable() async { await manage { try await self.service.enable() } }
    func stop() async { await manage { await self.service.stop() } }
    func delete(all: Bool) async {
        await manage(operation: all ? "cloud.deleteAll" : "cloud.deleteDevice") {
            if all { try await self.service.deleteAll() } else { try await self.service.deleteDevice() }
            if all { self.resetSnapshots() }
        }
    }

    private func manage(operation: String? = nil, _ action: () async throws -> Void) async {
        guard availableForLedger, !managing else { return }
        managing = true
        generation += 1
        do { try await action(); managementError = nil; transferError = nil }
        catch {
            managementError = operation.map { L($0) + " · " + error.localizedDescription } ?? error.localizedDescription
        }
        enabled = service.isEnabled
        managing = false
        if managementError == nil { refresh(localChanged: true) }
    }

    private func resetSnapshots() {
        snapshots = [:]
        remoteDates = [:]
        remoteCatalog = nil
        sources = []
        uploadPending = false
        snapshotVersion += 1
        annualVersion += 1
        projection = nil
        localDirty = true
    }

    private func snapshotsChanged() {
        snapshotVersion += 1
        guard let year else { return }
        guard snapshots.count > 1 else {
            if projection != nil { annualVersion += 1 }
            projection = nil
            return
        }
        let filter = selection, version = snapshotVersion
        Task {
            await select(filter, from: year.0, to: year.1, whileCurrent: {
                self.snapshotVersion == version && self.selection == filter && self.year?.0 == year.0 && self.year?.1 == year.1
            })
        }
    }
}
