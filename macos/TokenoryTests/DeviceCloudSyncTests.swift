// [INPUT]: Isolated device preferences and a CloudKit-shaped atomic storage fake.
// [OUTPUT]: Lifecycle, replay, rollback, account isolation and offline Overview recovery checks.
import Foundation
import XCTest
@testable import Tokenory

private actor FakeDeviceCloud: DeviceCloudTransport {
    var account = "account-1"
    var online = true
    var manifests: [String: DeviceCloudManifest] = [:]
    var revisions: [String: Int] = [:]
    var assets: [String: [UUID: Data]] = [:]
    var writes = 0
    var commits = 0
    var downloads = 0
    var suspendNextWrite = false
    var dropAcknowledgement = false
    var suspendedWrite: CheckedContinuation<Void, Never>?

    func setAccount(_ new: String) { account = new }
    func setOnline(_ value: Bool) { online = value }
    func gateNextWrite() { suspendNextWrite = true }
    func dropNextAcknowledgement() { dropAcknowledgement = true }
    func isWaiting() -> Bool { suspendedWrite != nil }
    func releaseWrite() { suspendedWrite?.resume(); suspendedWrite = nil }
    func accountID() throws -> String {
        guard online else { throw URLError(.notConnectedToInternet) }
        return account
    }
    func head(account: String, createZone: Bool) throws -> DeviceCloudHead {
        guard try accountID() == account else { throw DeviceCloudError.accountChanged }
        let tag = revisions[account].map(String.init)
        return .init(manifest: manifests[account] ?? .init(), version: tag.map { Data($0.utf8) }, changeTag: tag)
    }
    func commit(account: String, previous: DeviceCloudHead, next: DeviceCloudManifest,
                write: DeviceCloudWrite?, removing: UUID?) async throws {
        if write != nil, suspendNextWrite {
            suspendNextWrite = false
            await withCheckedContinuation { suspendedWrite = $0 }
        }
        let current = try head(account: account, createZone: false)
        guard previous.changeTag == current.changeTag else { throw DeviceCloudError.conflict }
        if previous.version != nil && current.manifest.epoch != next.epoch { assets[account] = [:] }
        if let write { writes += 1; assets[account, default: [:]][write.id] = write.bytes }
        if let removing { assets[account]?.removeValue(forKey: removing) }
        manifests[account] = next
        revisions[account, default: 0] += 1
        commits += 1
        if dropAcknowledgement {
            dropAcknowledgement = false
            throw URLError(.networkConnectionLost)
        }
    }
    func payloads(account: String, ids: [UUID]) throws -> [UUID: Data] {
        guard try accountID() == account else { throw DeviceCloudError.accountChanged }
        downloads += ids.count
        return assets[account, default: [:]].filter { ids.contains($0.key) }
    }
}

@MainActor
final class DeviceCloudSyncTests: XCTestCase {
    private actor LocalLedger {
        var snapshot: DeviceUsageSnapshot
        init(_ snapshot: DeviceUsageSnapshot) { self.snapshot = snapshot }
        func replace(with value: DeviceUsageSnapshot) { snapshot = value }
    }

    private func snapshot(tokens: Int64) -> DeviceUsageSnapshot {
        let summary = UsageSummary(tokens: tokens, tokenBreakdown: .init(input: tokens, output: 0, cacheRead: 0,
                                   cacheWrite: 0, reasoning: 0), knownEstimatedCostUsd: nil, unpricedTokens: tokens,
                                   costStatus: "unknown", recordCount: 1, activeDays: 1, partialDays: 0, requests: 1)
        let bucket = DeviceUsageSnapshot.Bucket(date: "2026-11-23", hour: 9, client: "codex", provider: "test",
                                                model: "test", source: "local", isSubagent: false, summary: summary)
        return DeviceUsageSnapshot(schemaVersion: 1, revision: tokens, timezone: "Asia/Shanghai",
                                   buckets: [bucket], subagentStarts: [])
    }

    private func waitForStore(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private func devices(_ cloud: FakeDeviceCloud) -> (DeviceCloudSync, DeviceCloudSync) {
        let suite = "ee.ryek.tokenory.sync-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return (.init(backend: cloud, preferences: .init(defaults: defaults, host: "A")),
                .init(backend: cloud, preferences: .init(defaults: defaults, host: "B")))
    }

    func testDefaultOffStopPreservesDataAndDeletionClearsOnlyRequestedScope() async throws {
        let cloud = FakeDeviceCloud(), (a, b) = devices(cloud)
        XCTAssertFalse(a.isEnabled)
        XCTAssertFalse(a.hasParticipated)
        XCTAssertNotEqual(a.deviceID, b.deviceID)
        try await a.enable()
        try await b.enable()
        try await a.publish(Data([1]), revision: 1)
        try await b.publish(Data([2]), revision: 2)
        let before = await cloud.commits
        try await a.publish(Data([1]), revision: 1)
        let after = await cloud.commits
        XCTAssertEqual(before, after)
        await a.stop()
        XCTAssertTrue(a.hasParticipated)
        let retained = try await b.snapshots()
        XCTAssertEqual(Set(retained.map(\.data)), Set([Data([1]), Data([2])]))
        try await a.deleteDevice()
        let afterDelete = try await b.snapshots()
        XCTAssertEqual(afterDelete.map(\.deviceID), [b.deviceID])
        try await a.enable()
        try await a.publish(Data([3]), revision: 0)
        try await a.deleteAll()
        let empty = try await b.snapshots()
        XCTAssertTrue(empty.isEmpty)
        XCTAssertFalse(b.isEnabled)
        let assets = await cloud.assets
        XCTAssertTrue(assets.values.allSatisfy(\.isEmpty))
    }

    func testStoreShowsFreshLocalUsageOfflineAndPublishesItOnOrdinaryRefresh() async throws {
        let cloud = FakeDeviceCloud(), (local, peer) = devices(cloud)
        try await local.enable()
        try await peer.enable()
        let peerData = try JSONEncoder().encode(snapshot(tokens: 40))
        try await peer.publish(peerData, revision: 40)
        let ledger = LocalLedger(snapshot(tokens: 100))
        let store = DeviceSyncStore(service: local, loadSnapshot: { await ledger.snapshot })
        let filter = UsageFilter()
        await store.select(filter, from: "2026-01-01", to: "2026-12-31")
        store.refresh()
        try await waitForStore { !store.busy && store.overview(for: filter)?.summary.tokens == 140 }
        let lastOnline = try XCTUnwrap(store.lastContact)

        await cloud.setOnline(false)
        await ledger.replace(with: snapshot(tokens: 130))
        store.refresh(localChanged: true)
        try await waitForStore { !store.busy && store.overview(for: filter)?.summary.tokens == 170 }
        XCTAssertEqual(store.local(for: filter)?.summary.tokens, 130)
        XCTAssertEqual(store.remote(for: filter)[peer.deviceID]?.summary.tokens, 40)
        XCTAssertEqual(store.lastContact, lastOnline)

        await cloud.setOnline(true)
        let beforeRetry = try await peer.snapshots()
        let old = try XCTUnwrap(beforeRetry.first { $0.deviceID == local.deviceID })
        XCTAssertEqual(try JSONDecoder().decode(DeviceUsageSnapshot.self, from: old.data).buckets.first?.summary.tokens, 100)
        store.refresh()
        try await waitForStore { !store.busy && store.lastContact != lastOnline }
        let afterRetry = try await peer.snapshots()
        let updated = try XCTUnwrap(afterRetry.first { $0.deviceID == local.deviceID })
        XCTAssertEqual(try JSONDecoder().decode(DeviceUsageSnapshot.self, from: updated.data).buckets.first?.summary.tokens, 130)
        XCTAssertEqual(store.overview(for: filter)?.summary.tokens, 170)
    }

    func testDateChangePublishesOneDeviceBreakdownAndReusesAnnualActivity() async throws {
        let cloud = FakeDeviceCloud(), (local, peer) = devices(cloud)
        try await local.enable()
        try await peer.enable()
        let realLocal = snapshot(tokens: 100)
        try await peer.publish(JSONEncoder().encode(snapshot(tokens: 40)), revision: 40)
        let store = DeviceSyncStore(service: local) { realLocal }
        let first = UsageFilter(from: "2026-11-23", to: "2026-11-23")
        let second = UsageFilter(from: "2026-11-22", to: "2026-11-22")
        let from = "2026-01-01", to = "2026-12-31"
        await store.select(first, from: from, to: to)
        store.refresh()
        try await waitForStore { !store.busy && store.overview(for: first)?.summary.tokens == 140 }
        let annualVersion = store.annualVersion

        // Supersede the request between building the next range and committing it.
        var checks = 0
        await store.select(second, from: from, to: to, whileCurrent: {
            XCTAssertEqual(store.overview(for: first)?.summary.tokens, 140)
            XCTAssertEqual(store.local(for: first)?.summary.tokens, 100)
            XCTAssertEqual(store.remote(for: first)[peer.deviceID]?.summary.tokens, 40)
            checks += 1
            return checks == 1
        }) { XCTFail("A superseded selection published") }
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(store.overview(for: first)?.summary.tokens, 140)

        var committed = false
        await store.select(second, from: from, to: to, commit: {
            XCTAssertNil(store.overview(for: first))
            XCTAssertEqual(store.overview(for: second)?.summary.tokens, 0)
            XCTAssertEqual(store.local(for: second)?.summary.tokens, 0)
            XCTAssertEqual(store.remote(for: second)[peer.deviceID]?.summary.tokens, 0)
            XCTAssertEqual(store.annualVersion, annualVersion)
            XCTAssertEqual(store.activity?.daily.first?.summary.tokens, 140)
            committed = true
        })
        XCTAssertTrue(committed)

        var model = second
        model.model = "missing"
        await store.select(model, from: from, to: to)
        XCTAssertGreaterThan(store.annualVersion, annualVersion)
        XCTAssertTrue(store.activity?.daily.isEmpty == true)
    }

    func testStoreKeepsFailedDeleteVisibleAfterSuccessfulBackgroundRead() async throws {
        let cloud = FakeDeviceCloud(), (local, peer) = devices(cloud)
        try await local.enable()
        let value = snapshot(tokens: 100)
        let store = DeviceSyncStore(service: local, loadSnapshot: { value })
        store.refresh()
        try await waitForStore { !store.busy && store.lastContact != nil }
        let lastOnline = try XCTUnwrap(store.lastContact)

        await cloud.setOnline(false)
        await store.delete(all: false)
        let deletionError = try XCTUnwrap(store.message)
        XCTAssertFalse(store.enabled)
        await cloud.setOnline(true)
        store.refresh()
        try await waitForStore { !store.busy && store.lastContact != lastOnline }
        XCTAssertEqual(store.message, deletionError)
        let retained = try await peer.snapshots()
        XCTAssertEqual(retained.map(\.deviceID), [local.deviceID])

        await store.delete(all: false)
        try await waitForStore { !store.busy }
        XCTAssertNil(store.message)
        let deleted = try await peer.snapshots()
        XCTAssertTrue(deleted.isEmpty)
    }

    func testRefreshDownloadsOnlyChangedAssetsAndDropsRevokedData() async throws {
        let cloud = FakeDeviceCloud(), (a, b) = devices(cloud)
        try await a.enable(); try await b.enable()
        try await a.publish(Data([1]), revision: 1)
        try await b.publish(Data([2]), revision: 1)
        _ = try await a.snapshots()
        _ = try await a.snapshots()
        let loaded = await cloud.downloads
        XCTAssertEqual(loaded, 2)
        try await b.publish(Data([3]), revision: 2)
        let changed = try await a.snapshots()
        XCTAssertEqual(Set(changed.map(\.data)), [Data([1]), Data([3])])
        let incremental = await cloud.downloads
        XCTAssertEqual(incremental, 3)
        try await b.deleteDevice()
        let revoked = try await a.snapshots()
        XCTAssertEqual(revoked.map(\.data), [Data([1])])
        await cloud.setAccount("another-user")
        do { _ = try await a.snapshots(); XCTFail("Another account received cached data") }
        catch DeviceCloudError.accountChanged { }
        try await a.enable()
        let newAccount = try await a.snapshots()
        XCTAssertTrue(newAccount.isEmpty)
    }

    func testLostDeleteResponseRetryPreservesSubsequentExplicitRegistration() async throws {
        let cloud = FakeDeviceCloud(), (a, b) = devices(cloud)
        try await a.enable(); try await b.enable()
        try await a.publish(Data([1]), revision: 1)
        await cloud.dropNextAcknowledgement()
        do { try await a.deleteAll(); XCTFail("Deletion was prematurely confirmed") }
        catch DeviceCloudError.unconfirmedDeletion { }
        try await b.enable()
        try await b.publish(Data([2]), revision: 1)
        try await a.deleteAll()
        let remaining = try await a.snapshots()
        XCTAssertEqual(remaining.map(\.deviceID), [b.deviceID])
    }

    func testSigningEnvironmentsKeepIndependentPreferences() async throws {
        let suite = "ee.ryek.tokenory.sync-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cloud = FakeDeviceCloud()
        let dev = DeviceCloudSync(backend: cloud, preferences: .init(defaults: defaults, host: "A", environment: "Development"))
        let release = DeviceCloudSync(backend: cloud, preferences: .init(defaults: defaults, host: "A", environment: "Production"))
        let unsigned = DeviceCloudSync(backend: cloud, preferences: .init(defaults: defaults, host: "A", environment: "local"))
        try await dev.enable()
        await unsigned.stop()
        XCTAssertTrue(dev.isEnabled)
        XCTAssertFalse(release.isEnabled)
        XCTAssertFalse(release.hasParticipated)
        XCTAssertFalse(unsigned.hasParticipated)
    }

    func testUseAcquisitionOrderAfterLedgerRestoreAndReuseUnchangedAsset() async throws {
        let cloud = FakeDeviceCloud(), (a, _) = devices(cloud)
        try await a.enable()
        let early = try await a.beginPublication()
        try await a.publish(Data([7]), revision: 200)
        try await a.publish(Data([9]), revision: 5)
        do {
            try await a.publish(Data([4]), revision: 300, publication: early)
            XCTFail("An out-of-order export reached the cloud")
        } catch DeviceCloudError.staleRevision { }
        try await a.publish(Data([9]), revision: 6)
        let latest = try await a.snapshots()
        XCTAssertEqual(latest.first?.data, Data([9]))
        XCTAssertEqual(latest.first?.revision, 6)
        let writes = await cloud.writes
        XCTAssertEqual(writes, 2)
    }

    func testInFlightWriteCannotReviveDeletedEpoch() async throws {
        let cloud = FakeDeviceCloud(), (a, b) = devices(cloud)
        try await a.enable()
        try await b.enable()
        try await a.publish(Data([1]), revision: 1)
        await cloud.gateNextWrite()
        let pending = Task { try await a.publish(Data([2]), revision: 2) }
        for _ in 0..<200 {
            if await cloud.isWaiting() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let waiting = await cloud.isWaiting()
        XCTAssertTrue(waiting)
        try await b.deleteAll()
        await cloud.releaseWrite()
        do { try await pending.value; XCTFail("Deleted data was republished") }
        catch DeviceCloudError.revoked { }
        XCTAssertFalse(a.isEnabled)
        let empty = try await b.snapshots()
        XCTAssertTrue(empty.isEmpty)
        try await a.enable()
        try await a.publish(Data([3]), revision: 1)
        let restored = try await b.snapshots()
        XCTAssertEqual(restored.map(\.data), [Data([3])])
        XCTAssertFalse(b.isEnabled)
    }

    func testOfflineDeleteCanBeRetriedAndAccountSwitchNeedsExplicitConsent() async throws {
        let cloud = FakeDeviceCloud(), (a, b) = devices(cloud)
        try await a.enable()
        try await a.publish(Data([8]), revision: 3)
        await cloud.setOnline(false)
        do { try await a.deleteDevice(); XCTFail("Offline delete reported success") }
        catch let error as URLError { XCTAssertEqual(error.code, .notConnectedToInternet) }
        XCTAssertFalse(a.isEnabled)
        await cloud.setOnline(true)
        let stillPublished = try await b.snapshots()
        XCTAssertEqual(stillPublished.count, 1)
        try await a.deleteDevice()
        let empty = try await b.snapshots()
        XCTAssertTrue(empty.isEmpty)
        try await a.enable()
        await cloud.setAccount("account-2")
        do { try await a.publish(Data([8]), revision: 3); XCTFail("Another account received this Mac’s usage") }
        catch DeviceCloudError.accountChanged { }
        XCTAssertFalse(a.isEnabled)
        try await a.enable()
        try await a.publish(Data([9]), revision: 1)
        let newAccount = try await a.snapshots()
        XCTAssertEqual(newAccount.map(\.data), [Data([9])])
    }
}
