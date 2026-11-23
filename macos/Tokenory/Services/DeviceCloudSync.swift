// [INPUT]: Opaque device usage summaries, local authorization and the signed CloudKit private database.
// [OUTPUT]: Versioned device snapshots, explicit registration, pause and revocation.
// [POS]: macOS cloud transport. The caller creates the privacy-filtered summary.
import CloudKit
import CryptoKit
import Foundation
import IOKit
import Security
import SystemConfiguration

struct DeviceCloudSnapshot: Sendable {
    let deviceID: String
    let deviceName: String
    let revision: Int64
    let updatedAt: Date
    let data: Data
}

struct DeviceCloudEntry: Codable, Sendable {
    var grant: UUID
    var sequence: Int64?
    var deviceName: String
    var payload: UUID?
    var payloadGrant: UUID?
    var revision: Int64?
    var updatedAt: Date?
    var digest: String?
}

struct DeviceCloudManifest: Codable, Sendable {
    var epoch = UUID()
    var devices: [String: DeviceCloudEntry] = [:]
}

struct DeviceCloudHead: Sendable {
    let manifest: DeviceCloudManifest
    // A saved CloudKit change tag and record ID, encoded with CKRecord.encodeSystemFields.
    let version: Data?
    let changeTag: String?
}

struct DeviceCloudPublication: Sendable {
    fileprivate let grant: UUID
    fileprivate let sequence: Int64
}

struct DeviceCloudWrite: Sendable {
    let id: UUID
    let bytes: Data
}

enum DeviceCloudError: String, LocalizedError {
    case unavailable, noAccount, accountChanged, stopped, revoked, conflict, invalidData, staleRevision, unconfirmedDeletion
    var errorDescription: String? {
        let selected = Bundle.main.path(forResource: Localization.identifier, ofType: "lproj")
        let bundle = selected.flatMap(Bundle.init(path:)) ?? .main
        return bundle.localizedString(forKey: rawValue, value: nil, table: "DeviceCloudErrors")
    }
}

protocol DeviceCloudTransport: Sendable {
    func accountID() async throws -> String
    func head(account: String, createZone: Bool) async throws -> DeviceCloudHead
    func commit(account: String, previous: DeviceCloudHead, next: DeviceCloudManifest,
                write: DeviceCloudWrite?, removing: UUID?) async throws
    func payloads(account: String, ids: [UUID]) async throws -> [UUID: Data]
}

private struct DeviceCloudGrant: Codable, Sendable {
    var account: String
    var epoch: UUID
    var token: UUID
}

private struct DeviceCloudRemoval: Codable {
    var account: String
    var epoch: UUID?
    var grant: UUID?
}

final class DeviceCloudPreferences: @unchecked Sendable {
    private static let lock = NSLock()
    private let defaults: UserDefaults
    private let prefix: String
    let deviceID: String

    init(defaults: UserDefaults = .standard, host: String? = nil, environment: String? = nil) {
        self.defaults = defaults
        // A migrated preferences file must not allow a second Mac to publish as the first.
        let hostKey = host ?? Self.localMachineID()
        let scope = environment ?? CloudKitDeviceTransport.signedEnvironment() ?? "local"
        let previousPrefix = "deviceCloudSync.v1." + Self.digest(Data(hostKey.utf8)) + "."
        let scopedPrefix = previousPrefix + scope + "."
        prefix = scopedPrefix
        let key = prefix + "device"
        deviceID = Self.lock.withLock {
            if let id = defaults.string(forKey: key) { return id }
            // Only a Development-signed prototype ever used the old unscoped authorization.
            if scope == "Development", let id = defaults.string(forKey: previousPrefix + "device") {
                for suffix in ["account", "grant", "sequence"] {
                    if let value = defaults.object(forKey: previousPrefix + suffix) {
                        defaults.set(value, forKey: scopedPrefix + suffix)
                    }
                }
                defaults.set(id, forKey: key)
                return id
            }
            let id = UUID().uuidString.lowercased()
            defaults.set(id, forKey: key)
            return id
        }
    }

    private static func localMachineID() -> String {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard entry != 0 else { return ProcessInfo.processInfo.hostName }
        defer { IOObjectRelease(entry) }
        return IORegistryEntryCreateCFProperty(entry, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String ?? ProcessInfo.processInfo.hostName
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    fileprivate var grant: DeviceCloudGrant? {
        get { defaults.data(forKey: prefix + "grant").flatMap { try? JSONDecoder().decode(DeviceCloudGrant.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: prefix + "grant") }
    }
    fileprivate var account: String? {
        get { defaults.string(forKey: prefix + "account") }
        set { defaults.set(newValue, forKey: prefix + "account") }
    }
    fileprivate var sequence: Int64 { (defaults.object(forKey: prefix + "sequence") as? NSNumber)?.int64Value ?? 0 }
    fileprivate func issue(grant: UUID) -> DeviceCloudPublication {
        Self.lock.withLock {
            let next = sequence + 1
            defaults.set(NSNumber(value: next), forKey: prefix + "sequence")
            return .init(grant: grant, sequence: next)
        }
    }
    fileprivate func pendingRemoval(all: Bool) -> DeviceCloudRemoval? {
        defaults.data(forKey: prefix + (all ? "removeAll" : "removeDevice"))
            .flatMap { try? JSONDecoder().decode(DeviceCloudRemoval.self, from: $0) }
    }
    fileprivate func setRemoval(_ value: DeviceCloudRemoval?, all: Bool) {
        defaults.set(value.flatMap { try? JSONEncoder().encode($0) }, forKey: prefix + (all ? "removeAll" : "removeDevice"))
    }
}

actor DeviceCloudSync {
    private let backend: any DeviceCloudTransport
    private let preferences: DeviceCloudPreferences
    private var operation = UUID()
    private var inFlight: Set<Int64> = []
    private var cacheAccount: String?
    private var cacheEpoch: UUID?
    private var cache: [UUID: (data: Data, digest: String)] = [:]
    nonisolated let deviceID: String
    nonisolated var deviceName: String {
        SCDynamicStoreCopyComputerName(nil, nil) as String? ?? ProcessInfo.processInfo.hostName
    }
    nonisolated var isEnabled: Bool { preferences.grant != nil }
    nonisolated var hasParticipated: Bool { preferences.account != nil }

    init(backend: any DeviceCloudTransport = CloudKitDeviceTransport(), preferences: DeviceCloudPreferences = .init()) {
        self.backend = backend
        self.preferences = preferences
        deviceID = preferences.deviceID
    }

    func stop() {
        operation = UUID()
        preferences.grant = nil
    }

    private func currentAccount() async throws -> String {
        let ticket = operation
        let account = try await backend.accountID()
        if let bound = preferences.account, bound != account {
            if ticket == operation {
                stop()
                cache.removeAll()
            }
            throw DeviceCloudError.accountChanged
        }
        return account
    }

    func enable() async throws {
        stop()
        let ticket = operation
        let account = try await backend.accountID()
        if cacheAccount != account { cache.removeAll() }
        let token = UUID()
        var startingEpoch: UUID?
        var attemptedInitialCreate = false
        for _ in 0..<4 {
            let head = try await backend.head(account: account, createZone: true)
            guard ticket == operation else { throw DeviceCloudError.stopped }
            if let startingEpoch, startingEpoch != head.manifest.epoch { throw DeviceCloudError.revoked }
            if attemptedInitialCreate && head.version != nil { throw DeviceCloudError.conflict }
            if head.version != nil { startingEpoch = head.manifest.epoch }
            else { attemptedInitialCreate = true }
            var next = head.manifest
            let previous = next.devices[deviceID]
            next.devices[deviceID] = DeviceCloudEntry(grant: token, deviceName: deviceName,
                payload: previous?.payload, payloadGrant: previous?.payloadGrant, revision: previous?.revision,
                updatedAt: previous?.updatedAt, digest: previous?.digest)
            do { try await backend.commit(account: account, previous: head, next: next, write: nil, removing: nil) }
            catch DeviceCloudError.conflict { continue }
            guard ticket == operation else { throw DeviceCloudError.stopped }
            preferences.account = account
            preferences.grant = .init(account: account, epoch: next.epoch, token: token)
            preferences.setRemoval(nil, all: true)
            preferences.setRemoval(nil, all: false)
            return
        }
        throw DeviceCloudError.conflict
    }

    func beginPublication() throws -> DeviceCloudPublication {
        guard let grant = preferences.grant else { throw DeviceCloudError.stopped }
        return preferences.issue(grant: grant.token)
    }

    func publish(_ data: Data, revision: Int64) async throws {
        try await publish(data, revision: revision, publication: beginPublication())
    }

    func publish(_ data: Data, revision: Int64, publication: DeviceCloudPublication) async throws {
        guard let grant = preferences.grant, grant.token == publication.grant else { throw DeviceCloudError.stopped }
        let ticket = operation
        let account = try await currentAccount()
        let digest = DeviceCloudPreferences.digest(data)
        inFlight.insert(publication.sequence)
        defer { inFlight.remove(publication.sequence) }
        for _ in 0..<4 {
            let head = try await backend.head(account: account, createZone: false)
            guard ticket == operation, preferences.grant?.token == grant.token else { throw DeviceCloudError.stopped }
            guard publication.sequence == preferences.sequence else { throw DeviceCloudError.staleRevision }
            guard account == grant.account, head.version != nil, grant.epoch == head.manifest.epoch,
                  var entry = head.manifest.devices[deviceID], entry.grant == grant.token else {
                stop()
                throw DeviceCloudError.revoked
            }
            if entry.payloadGrant == grant.token, let saved = entry.sequence {
                guard publication.sequence >= saved else { throw DeviceCloudError.staleRevision }
                if publication.sequence == saved {
                    guard revision == entry.revision, digest == entry.digest else { throw DeviceCloudError.staleRevision }
                    return
                }
            }
            let unchanged = entry.payload != nil && entry.digest == digest
            if unchanged && entry.payloadGrant == grant.token && entry.revision == revision &&
                entry.deviceName == deviceName && !inFlight.contains(where: { $0 < publication.sequence }) { return }
            let old = unchanged ? nil : entry.payload
            let write = unchanged ? nil : DeviceCloudWrite(id: UUID(), bytes: data)
            entry.deviceName = deviceName
            if let write { entry.payload = write.id }
            entry.payloadGrant = grant.token
            entry.sequence = publication.sequence
            entry.revision = revision
            entry.updatedAt = Date()
            entry.digest = digest
            var next = head.manifest
            next.devices[deviceID] = entry
            do { try await backend.commit(account: account, previous: head, next: next, write: write, removing: old) }
            catch DeviceCloudError.conflict { continue }
            return
        }
        throw DeviceCloudError.conflict
    }

    func snapshots() async throws -> [DeviceCloudSnapshot] {
        let account = try await currentAccount()
        for _ in 0..<4 {
            let ticket = operation
            let head = try await backend.head(account: account, createZone: false)
            guard ticket == operation else { continue }
            if let grant = preferences.grant, grant.account == account,
               (grant.epoch != head.manifest.epoch || head.manifest.devices[deviceID]?.grant != grant.token) { stop() }
            guard head.version != nil else { cache.removeAll(); return [] }
            let readTicket = operation
            let ids = Set(head.manifest.devices.values.compactMap(\.payload))
            var verified = cacheAccount == account && cacheEpoch == head.manifest.epoch
                ? cache.filter { ids.contains($0.key) } : [:]
            let missing = Array(ids.subtracting(verified.keys))
            if !missing.isEmpty {
                let result: Result<[UUID: Data], Error>
                do { result = .success(try await backend.payloads(account: account, ids: missing)) }
                catch { result = .failure(error) }
                let latest = try await backend.head(account: account, createZone: false)
                guard readTicket == operation, latest.changeTag == head.changeTag else { continue }
                for (id, bytes) in try result.get() { verified[id] = (bytes, DeviceCloudPreferences.digest(bytes)) }
            }
            let snapshots: [DeviceCloudSnapshot] = try head.manifest.devices.sorted(by: { $0.key < $1.key }).compactMap { id, entry in
                guard let payload = entry.payload else { return nil }
                guard let saved = verified[payload], saved.digest == entry.digest,
                      let time = entry.updatedAt, let revision = entry.revision else { throw DeviceCloudError.invalidData }
                return .init(deviceID: id, deviceName: entry.deviceName, revision: revision, updatedAt: time, data: saved.data)
            }
            cacheAccount = account
            cacheEpoch = head.manifest.epoch
            cache = verified
            return snapshots
        }
        throw DeviceCloudError.conflict
    }

    func deleteDevice() async throws { try await remove(all: false) }
    func deleteAll() async throws { try await remove(all: true) }

    private func remove(all: Bool) async throws {
        stop()
        cache.removeAll()
        let ticket = operation
        let account = try await currentAccount()
        var pending = preferences.pendingRemoval(all: all)
        guard pending == nil || pending?.account == account else { throw DeviceCloudError.accountChanged }
        for _ in 0..<4 {
            let head = try await backend.head(account: account, createZone: all)
            guard ticket == operation else { throw DeviceCloudError.stopped }
            // A lost acknowledgement must not turn a retry into deletion of newly re-authorized data.
            if let pending, pending.epoch != (head.version == nil ? nil : head.manifest.epoch) {
                preferences.setRemoval(nil, all: all)
                return
            }
            guard head.version != nil || all else { preferences.setRemoval(nil, all: all); return }
            var next = head.manifest
            let removed: UUID?
            if all {
                next = DeviceCloudManifest()
                removed = nil
            } else {
                guard let entry = next.devices[deviceID], pending == nil || pending?.grant == entry.grant else {
                    preferences.setRemoval(nil, all: all)
                    return
                }
                next.devices.removeValue(forKey: deviceID)
                removed = entry.payload
            }
            pending = .init(account: account, epoch: head.version == nil ? nil : head.manifest.epoch,
                            grant: head.manifest.devices[deviceID]?.grant)
            preferences.setRemoval(pending, all: all)
            do { try await backend.commit(account: account, previous: head, next: next, write: nil, removing: removed) }
            catch DeviceCloudError.conflict {
                // The initial empty-zone transaction definitively lost the create race, so
                // re-read the first published state and apply the explicit delete to that epoch.
                if head.version == nil { pending = nil; preferences.setRemoval(nil, all: all) }
                continue
            }
            catch {
                let networkError = error as? CKError
                if error is URLError || networkError.map({ [.networkFailure, .networkUnavailable, .serverResponseLost].contains($0.code) }) == true {
                    throw DeviceCloudError.unconfirmedDeletion
                }
                throw error
            }
            preferences.setRemoval(nil, all: all)
            return
        }
        throw DeviceCloudError.conflict
    }
}

struct CloudKitDeviceTransport: DeviceCloudTransport {
    static let containerID = "iCloud.ee.ryek.tokenory"
    private let manifestType = "TokenorySyncManifestV1"
    private let epochType = "TokenorySyncEpochV1"
    private let payloadType = "TokenorySyncPayloadV1"

    static func signedEnvironment() -> String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let authorized = SecTaskCopyValueForEntitlement(task,
                "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String],
              authorized.contains(Self.containerID),
              let services = SecTaskCopyValueForEntitlement(task,
                "com.apple.developer.icloud-services" as CFString, nil) as? [String],
              services.contains("CloudKit"),
              let environment = SecTaskCopyValueForEntitlement(task,
                "com.apple.developer.icloud-container-environment" as CFString, nil) as? String,
              ["Development", "Production"].contains(environment) else { return nil }
        return environment
    }

    private func container() throws -> CKContainer {
        guard Self.signedEnvironment() != nil else { throw DeviceCloudError.unavailable }
        return CKContainer(identifier: Self.containerID)
    }

    func accountID() async throws -> String {
        let cloud = try container()
        guard try await cloud.accountStatus() == .available else { throw DeviceCloudError.noAccount }
        return try await cloud.userRecordID().recordName
    }

    private func database(_ account: String) async throws -> CKDatabase {
        let cloud = try container()
        guard try await cloud.userRecordID().recordName == account else { throw DeviceCloudError.accountChanged }
        return cloud.privateCloudDatabase
    }

    private func zone(_ account: String) -> CKRecordZone.ID {
        let suffix = DeviceCloudPreferences.digest(Data(account.utf8)).prefix(32)
        return .init(zoneName: "TokenoryUsageV1-" + suffix, ownerName: CKCurrentUserDefaultName)
    }

    private func id(_ name: String, _ account: String) -> CKRecord.ID {
        .init(recordName: name, zoneID: zone(account))
    }

    private func errors(_ error: Error) -> [CKError] {
        guard let error = error as? CKError else { return [] }
        if error.code == .partialFailure, let nested = error.partialErrorsByItemID {
            return nested.values.flatMap { errors($0) }
        }
        return [error]
    }

    private func absent(_ error: Error) -> Bool {
        let causes = errors(error)
        return !causes.isEmpty && causes.allSatisfy { [.unknownItem, .zoneNotFound, .userDeletedZone].contains($0.code) }
    }

    func head(account: String, createZone: Bool) async throws -> DeviceCloudHead {
        let db = try await database(account)
        let record: CKRecord
        do { record = try await db.record(for: id("manifest", account)) }
        catch where absent(error) {
            if createZone {
                do { _ = try await db.recordZone(for: zone(account)) }
                catch where absent(error) {
                    do { _ = try await db.save(CKRecordZone(zoneID: zone(account))) }
                    catch {
                        // Another Mac can create the zone while this request is in flight.
                        _ = try await db.recordZone(for: zone(account))
                    }
                }
            }
            return .init(manifest: .init(), version: nil, changeTag: nil)
        }
        guard record.recordType == manifestType, let bytes = record["metadata"] as? Data,
              let changeTag = record.recordChangeTag else { throw DeviceCloudError.invalidData }
        let manifest = try JSONDecoder().decode(DeviceCloudManifest.self, from: bytes)
        let archive = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archive)
        archive.finishEncoding()
        return .init(manifest: manifest, version: archive.encodedData, changeTag: changeTag)
    }

    func commit(account: String, previous: DeviceCloudHead, next: DeviceCloudManifest,
                write: DeviceCloudWrite?, removing: UUID?) async throws {
        let db = try await database(account)
        let manifestID = id("manifest", account)
        let root: CKRecord
        if let version = previous.version {
            let archive = try NSKeyedUnarchiver(forReadingFrom: version)
            defer { archive.finishDecoding() }
            guard let record = CKRecord(coder: archive), record.recordID == manifestID else {
                throw DeviceCloudError.invalidData
            }
            root = record
        } else {
            root = CKRecord(recordType: manifestType, recordID: manifestID)
        }
        root["metadata"] = try JSONEncoder().encode(next) as NSData
        let epochID = id("epoch-" + next.epoch.uuidString, account)
        var saves = [root]
        var deletes: [CKRecord.ID] = []
        if previous.version == nil || previous.manifest.epoch != next.epoch {
            let marker = CKRecord(recordType: epochType, recordID: epochID)
            marker["schemaVersion"] = 1 as NSNumber
            saves.append(marker)
            if previous.version != nil { deletes.append(id("epoch-" + previous.manifest.epoch.uuidString, account)) }
        }
        var temporary: URL?
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        if let write {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            temporary = file
            let compressed = try (write.bytes as NSData).compressed(using: .lzfse)
            try compressed.write(to: file, options: .atomic)
            let payload = CKRecord(recordType: payloadType, recordID: id("payload-" + write.id.uuidString, account))
            payload["asset"] = CKAsset(fileURL: file)
            payload["epoch"] = CKRecord.Reference(recordID: epochID, action: .deleteSelf)
            saves.append(payload)
        }
        if let removing { deletes.append(id("payload-" + removing.uuidString, account)) }
        do {
            let result = try await db.modifyRecords(saving: saves, deleting: deletes,
                                                     savePolicy: .ifServerRecordUnchanged, atomically: true)
            let failures = result.saveResults.values.compactMap { item -> Error? in
                if case let .failure(error) = item { return error }; return nil
            } + result.deleteResults.values.compactMap { item -> Error? in
                if case let .failure(error) = item { return error }; return nil
            }
            if failures.contains(where: { errors($0).contains(where: { $0.code == .serverRecordChanged }) }) {
                throw DeviceCloudError.conflict
            }
            if let failure = failures.first { throw failure }
            guard result.saveResults.count == saves.count, result.deleteResults.count == deletes.count else {
                throw DeviceCloudError.invalidData
            }
        } catch {
            if errors(error).contains(where: { $0.code == .serverRecordChanged }) { throw DeviceCloudError.conflict }
            throw error
        }
    }

    func payloads(account: String, ids: [UUID]) async throws -> [UUID: Data] {
        guard !ids.isEmpty else { return [:] }
        let db = try await database(account)
        var output: [UUID: Data] = [:]
        for offset in stride(from: 0, to: ids.count, by: 100) {
            let chunk = ids[offset..<min(offset + 100, ids.count)]
            let records = try await db.records(for: chunk.map { id("payload-" + $0.uuidString, account) })
            for key in chunk {
                let recordID = id("payload-" + key.uuidString, account)
                guard let result = records[recordID] else { throw DeviceCloudError.invalidData }
                let record = try result.get()
                guard record.recordType == payloadType, let asset = record["asset"] as? CKAsset,
                      let url = asset.fileURL else { throw DeviceCloudError.invalidData }
                let bytes = try Data(contentsOf: url)
                output[key] = try (bytes as NSData).decompressed(using: .lzfse) as Data
            }
        }
        return output
    }
}
