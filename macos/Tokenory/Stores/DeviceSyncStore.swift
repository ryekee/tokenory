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
    let localRevision: Int64
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
    private(set) var pausing = false
    private(set) var lastContact: Date?
    private(set) var managementError: String?
    private var transferError: String?
    private var revoked = false
    private var incompatibleDevices = false
    var message: String? {
        managementError ?? (revoked ? DeviceCloudError.revoked.localizedDescription : nil) ?? transferError
    }
    var compatibilityNotice: String? { incompatibleDevices ? L("cloud.incompatibleDevices") : nil }
    private(set) var hasUnconfirmedDeviceDeletion = false
    private(set) var hasUnconfirmedAllDeletion = false
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
    var hasLocalSnapshot: Bool { snapshots[service.deviceID] != nil }
    func instantLocalOverview(for filter: UsageFilter) -> UsageReport? {
        guard filter.conversation == nil, filter.source == nil,
              let localSnapshot = snapshots[service.deviceID] else { return nil }
        return DeviceUsageSnapshot.overview(devices: [service.deviceID: localSnapshot], filter: filter)
    }
    func name(_ id: String) -> String { sources.first { $0.id == id }?.name ?? id }
    func overview(for filter: UsageFilter?) -> UsageReport? { projection?.filter == filter ? projection?.overview : nil }
    func remote(for filter: UsageFilter?) -> [String: UsageReport] { projection?.filter == filter ? projection?.remote ?? [:] : [:] }
    func local(for filter: UsageFilter?) -> UsageReport? { projection?.filter == filter ? projection?.local : nil }
    func matchingSubagentDetails(in report: UsageReport, for filter: UsageFilter) -> CodexSubagentReport? {
        guard let projection, projection.filter == filter, projection.localRevision == report.revision else { return nil }
        return report.codexSubagents
    }
    var localCalendar: UsageActivity? { projection?.annual.localCalendar }
    var activity: ActivityReport? { projection?.annual.activity }
    var remoteActivity: [String: ActivityReport] { projection?.annual.remoteActivity ?? [:] }
    var calendar: UsageActivity? { projection?.annual.calendar }
    var remoteCalendars: [String: UsageActivity] { projection?.annual.remoteCalendars ?? [:] }

    convenience init(engine: EngineClient, usesDefaultLedger: Bool) {
        self.init(service: DeviceCloudSync(),
                  availableForLedger: usesDefaultLedger && ProcessInfo.processInfo.environment["TOKENORY_TESTING"] != "1") {
            try await engine.deviceUsageSnapshot()
        }
    }

    init(service: DeviceCloudSync, availableForLedger: Bool = true,
         loadSnapshot: @escaping @Sendable () async throws -> DeviceUsageSnapshot) {
        self.loadSnapshot = loadSnapshot
        self.service = service
        self.availableForLedger = availableForLedger
        enabled = availableForLedger && service.isEnabled
        revoked = availableForLedger && service.wasRevoked
        updatePendingDeletes()
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
                revoked = false
                lastContact = nil
                refresh(localChanged: true)
            }
        }
        #if CLOUD_DEVELOPMENT
        if ProcessInfo.processInfo.arguments.contains("--enable-icloud-sync"), !enabled { Task { await enable() } }
        #endif
    }

    @ObservationIgnored private var projectionCache: [UsageFilter: DeviceProjection] = [:]
    @ObservationIgnored private var projectionCacheVersion = -1

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
            if projectionCacheVersion != version {
                projectionCache.removeAll(keepingCapacity: true)
                projectionCacheVersion = version
            }
            let old = projection
            let reusable = old?.snapshotVersion == version && old?.annual.filter == annualFilter
            let next: DeviceProjection?
            if reusable, old?.filter == filter {
                next = old
            } else if let cached = projectionCache[filter], cached.snapshotVersion == version, cached.annual.filter == annualFilter {
                next = cached
            } else if let localSnapshot = snapshots[service.deviceID], snapshots.count > 1 {
                let all = snapshots, id = service.deviceID
                let cachedAnnual = reusable ? old?.annual : nil
                next = await Task.detached(priority: .userInitiated) { [annualFilter] in
                    let local = [id: localSnapshot]
                    let others = all.filter { $0.key != id }
                    let annual = cachedAnnual ?? Self.buildAnnual(all: all, local: local, others: others,
                                                                  filter: annualFilter, from: from, to: to)
                    return DeviceProjection(filter: filter, overview: DeviceUsageSnapshot.overview(devices: all, filter: filter),
                                            local: DeviceUsageSnapshot.overview(devices: local, filter: filter), localRevision: localSnapshot.revision,
                                            remote: others.reduce(into: [:]) { rows, item in
                                                rows[item.key] = DeviceUsageSnapshot.overview(devices: [item.key: item.value], filter: filter)
                                            }, snapshotVersion: version, annual: annual)
                }.value
            } else {
                next = nil
            }
            guard whileCurrent() else { return }
            guard version == snapshotVersion else { continue }
            if let next {
                if projectionCache.count >= 16 { projectionCache.removeAll(keepingCapacity: true) }
                projectionCache[filter] = next
            }
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
            var localError: Error?
            do { try await refreshLocal(ticket: ticket) }
            catch { localError = error }
            guard ticket == generation else { return }
            if let localError { noteFailure(localError) }
            do {
                let id = service.deviceID
                let others = try await service.snapshots(excludingLocal: true)
                guard generation == ticket else { return }
                if service.wasRevoked { markRevoked() }
                enabled = service.isEnabled
                let dates = Dictionary(uniqueKeysWithValues: others.map { ($0.deviceID, $0.updatedAt) })
                if dates != remoteDates {
                    let (decoded, rows, catalog, incompatible) = try await Task.detached(priority: .utility) {
                        var values: [String: DeviceUsageSnapshot] = [:]
                        var rows: [DeviceSourceSummary] = []
                        var incompatible = false
                        for item in others {
                            do {
                                let snapshot = try JSONDecoder().decode(DeviceUsageSnapshot.self, from: item.data)
                                guard snapshot.timezone == DeviceUsageSnapshot.reportingTimezone else {
                                    incompatible = true
                                    continue
                                }
                                values[item.deviceID] = snapshot
                                let full = DeviceUsageSnapshot.overview(devices: [item.deviceID: snapshot], filter: .init())
                                rows.append(DeviceSourceSummary(id: item.deviceID, name: item.deviceName, updatedAt: item.updatedAt, clients: full.clients))
                            } catch DeviceUsageSnapshot.DecodingIssue.unsupportedVersion {
                                incompatible = true
                            }
                        }
                        return (values, rows.sorted { ($0.name, $0.id) < ($1.name, $1.id) },
                                DeviceUsageSnapshot.overview(devices: values, filter: .init()), incompatible)
                    }.value
                    guard ticket == generation else { return }
                    snapshots = decoded.merging(snapshots.filter { $0.key == id }) { _, local in local }
                    sources = rows
                    remoteCatalog = catalog
                    remoteDates = dates
                    incompatibleDevices = incompatible
                    snapshotsChanged()
                }
                lastContact = Date()
                if localError == nil { transferError = nil }
                #if CLOUD_DEVELOPMENT
                if ProcessInfo.processInfo.arguments.contains("--cloud-sync-receipt") {
                    let totals = snapshots.mapValues { $0.buckets.reduce(Int64(0)) { $0 + $1.summary.tokens } }
                    let items = totals.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                    FileHandle.standardError.write(Data("TOKENORY_SYNC local=\(id) devices=\(snapshots.count) enabled=\(enabled) \(items)\n".utf8))
                }
                #endif
            } catch {
                guard ticket == generation else { return }
                noteFailure(error)
                #if CLOUD_DEVELOPMENT
                if ProcessInfo.processInfo.arguments.contains("--cloud-sync-receipt") {
                    FileHandle.standardError.write(Data("TOKENORY_SYNC_ERROR \(error.localizedDescription)\n".utf8))
                }
                #endif
            }
        }
    }

    private func refreshLocal(ticket: Int) async throws {
        let id = service.deviceID
        let needsLocal = localDirty || snapshots[id] == nil
        let publication = enabled && (needsLocal || uploadPending) ? try await service.beginPublication() : nil
        guard ticket == generation else { return }
        if needsLocal {
            localDirty = false
            defer { if ticket != generation { localDirty = true } }
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
            guard ticket == generation else { return }
            try await service.publish(data, revision: snapshot.revision, publication: publication)
            if ticket == generation { uploadPending = false }
        }
    }

    private func markRevoked() {
        revoked = true
        uploadPending = false
    }

    private func noteFailure(_ error: Error) {
        if let cloudError = error as? DeviceCloudError {
            switch cloudError {
            case .revoked:
                resetSnapshots(keepingLocal: true)
                markRevoked()
            case .accountChanged, .noAccount: resetSnapshots()
            default: break
            }
        }
        enabled = service.isEnabled
        transferError = error.localizedDescription
    }

    func enable() async { await manage { try await self.service.enable(); self.revoked = false } }
    func stop() async {
        await manage {
            self.pausing = true
            await self.service.stop()
            self.pausing = false
        }
    }
    func delete(all: Bool) async {
        await manage(operation: all ? "cloud.deleteAll" : "cloud.deleteDevice") {
            if all { try await self.service.deleteAll() } else { try await self.service.deleteDevice() }
            if all { self.resetSnapshots(keepingLocal: true) }
        }
    }

    func confirmPreviousDeletion(all: Bool) async {
        await manage { try await self.service.confirmPreviousDeletion(all: all) }
    }

    private func updatePendingDeletes() {
        hasUnconfirmedDeviceDeletion = service.hasDeletionToConfirm(all: false)
        hasUnconfirmedAllDeletion = service.hasDeletionToConfirm(all: true)
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
        updatePendingDeletes()
        managing = false
        if managementError == nil { refresh(localChanged: true) }
    }

    private func resetSnapshots(keepingLocal: Bool = false) {
        snapshots = keepingLocal ? snapshots.filter { $0.key == service.deviceID } : [:]
        remoteDates = [:]
        remoteCatalog = nil
        sources = []
        incompatibleDevices = false
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
