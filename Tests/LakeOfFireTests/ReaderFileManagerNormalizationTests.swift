import BigSyncKit
import XCTest
import RealmSwift
import SwiftCloudDrive
@testable import LakeOfFireContent
@testable import RealmSwiftGaps

@MainActor
private final class CountingReaderFileManager: ReaderFileManager, @unchecked Sendable {
    private(set) var metadataScanCount = 0
    var scanError: (any Swift.Error)?
    var scanDidStart: (() -> Void)?

    override func refreshFilesMetadata(
        drive: CloudDrive,
        relativePath: RootRelativePath? = nil,
        realmConfiguration: Realm.Configuration? = nil
    ) async throws -> [ThreadSafeReference<ContentFile>]? {
        metadataScanCount += 1
        scanDidStart?()
        if let scanError {
            throw scanError
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        return []
    }
}

@MainActor
private final class ControlledInventoryReaderFileManager: ReaderFileManager, @unchecked Sendable {
    private(set) var metadataScanCount = 0
    var scan: ((Int) async throws -> [ThreadSafeReference<ContentFile>])?

    override func refreshFilesMetadata(
        drive: CloudDrive,
        relativePath: RootRelativePath? = nil,
        realmConfiguration: Realm.Configuration? = nil
    ) async throws -> [ThreadSafeReference<ContentFile>]? {
        metadataScanCount += 1
        return try await scan?(metadataScanCount) ?? []
    }
}

@MainActor
private final class RetryingInventoryReaderFileManager: ReaderFileManager, @unchecked Sendable {
    private(set) var metadataScanCount = 0
    var nextScanError: (any Swift.Error)?
    var beforeScan: ((Int) async -> Void)?

    override func refreshFilesMetadata(
        drive: CloudDrive,
        relativePath: RootRelativePath? = nil,
        realmConfiguration: Realm.Configuration? = nil
    ) async throws -> [ThreadSafeReference<ContentFile>]? {
        metadataScanCount += 1
        if let beforeScan {
            await beforeScan(metadataScanCount)
        }
        try Task.checkCancellation()
        if let error = nextScanError {
            nextScanError = nil
            throw error
        }
        return try await super.refreshFilesMetadata(
            drive: drive,
            relativePath: relativePath,
            realmConfiguration: realmConfiguration
        )
    }
}

@MainActor
private final class InventoryResumeTaskCapture {
    var task: Task<Void, Never>?
}

@MainActor
private final class InventoryRefreshClock {
    var date = Date(timeIntervalSince1970: 1_700_000_000)
}

@MainActor
private final class InventoryPassGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class InventoryRefreshCompletionState {
    var firstReturned = false
    var forcedReturned = false
    var ordinaryReturned = false
}

final class ReaderFileManagerNormalizationTests: XCTestCase {
    private enum MetadataScanError: Swift.Error {
        case failed
    }

    private final class SequencedRootProvider: @unchecked Sendable {
        private let lock = NSLock()
        private let roots: [URL]
        private(set) var invocationCount = 0

        init(roots: [URL]) {
            self.roots = roots
        }

        func next() -> URL {
            lock.withLock {
                let root = roots[min(invocationCount, roots.count - 1)]
                invocationCount += 1
                return root
            }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderFileManagerTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func makeHistoryRealmConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(
            inMemoryIdentifier: "ReaderFileManagerNormalization.\(UUID().uuidString)"
        )
        configuration.objectTypes = [
            Bookmark.self,
            ContentFile.self,
            ContentPackageFile.self,
            HistoryRecord.self,
            FeedEntry.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        return configuration
    }

    private func writeFixture(relativePath: String, under rootURL: URL) throws -> URL {
        let fileURL = rootURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("ebook fixture".utf8).write(to: fileURL)
        return fileURL
    }

    @MainActor
    private func controlledMetadataFixture() async throws -> (ControlledInventoryReaderFileManager, Realm) {
        let root = try temporaryDirectory()
        let configuration = makeHistoryRealmConfiguration()
        let identifier = try XCTUnwrap(configuration.inMemoryIdentifier)
        let realm = try Realm(configuration: configuration)
        let manager = ControlledInventoryReaderFileManager()
        manager.historyRealmConfigurationOverride = configuration
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: root))
        addTeardownBlock {
            await Self.releaseMetadataFixtureRealms(owner: .shared, identifier: identifier)
        }
        return (manager, realm)
    }

    @MainActor
    private func withScanningMetadataFixture(
        _ body: @MainActor (RetryingInventoryReaderFileManager, Realm, URL) async throws -> Void
    ) async throws {
        let previousURLProcessors = ReaderFileManager.readerFileURLProcessors
        let previousFileProcessors = ReaderFileManager.fileProcessors
        ReaderFileManager.readerFileURLProcessors = []
        ReaderFileManager.fileProcessors = []
        defer {
            ReaderFileManager.readerFileURLProcessors = previousURLProcessors
            ReaderFileManager.fileProcessors = previousFileProcessors
        }
        let root = try temporaryDirectory()
        let configuration = makeHistoryRealmConfiguration()
        let identifier = try XCTUnwrap(configuration.inMemoryIdentifier)
        let realm = try Realm(configuration: configuration)
        let manager = RetryingInventoryReaderFileManager()
        manager.historyRealmConfigurationOverride = configuration
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: root))
        addTeardownBlock {
            await Self.releaseMetadataFixtureRealms(owner: .shared, identifier: identifier)
        }
        try await body(manager, realm, root)
    }

    private static func releaseMetadataFixtureRealms(owner: isolated RealmBackgroundActor, identifier: String) {
        let cached = owner.cachedRealms.filter { $0.value.configuration.inMemoryIdentifier == identifier }
        guard cached.values.allSatisfy({ !$0.isInWriteTransaction }) else {
            XCTFail("Join the actual refresh before releasing its actor-owned Realm")
            return
        }
        for key in cached.keys {
            owner.cachedRealms.removeValue(forKey: key)?.invalidate()
        }
    }

    @MainActor
    private func trackMetadataRefresh<Failure: Swift.Error>(
        _ task: Task<Void, Failure>,
        manager: ReaderFileManager,
        gates: [InventoryPassGate]
    ) {
        addTeardownBlock {
            await MainActor.run {
                // The manager owns an unstructured task; cancelling only a
                // waiter does not cancel it or release its controlled scan.
                manager.appSuspendedDidChange(isSuspended: true)
                gates.forEach { $0.release() }
            }
            task.cancel()
            _ = await task.result
        }
    }

    @MainActor
    private func resumeMetadataRefresh(_ manager: ReaderFileManager) throws -> Task<Void, Never> {
        let capture = InventoryResumeTaskCapture()
        ReaderFileMetadataRefreshObservation.$didScheduleResume.withValue({ capture.task = $0 }) {
            manager.appSuspendedDidChange(isSuspended: false)
        }
        return try XCTUnwrap(capture.task, "Observe and join the actual resume task")
    }

    @MainActor
    func testConcurrentMetadataRefreshesShareOneScan() async throws {
        let rootURL = try temporaryDirectory()
        let manager = CountingReaderFileManager()
        manager.historyRealmConfigurationOverride = makeHistoryRealmConfiguration()
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: rootURL))

        async let first: Void = manager.refreshAllFilesMetadata()
        async let second: Void = manager.refreshAllFilesMetadata()
        _ = try await (first, second)

        XCTAssertEqual(manager.metadataScanCount, 1)
    }

    @MainActor
    func testMetadataRefreshPropagatesScanFailure() async throws {
        let rootURL = try temporaryDirectory()
        let manager = CountingReaderFileManager()
        manager.scanError = MetadataScanError.failed
        manager.historyRealmConfigurationOverride = makeHistoryRealmConfiguration()
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: rootURL))

        do {
            try await manager.refreshAllFilesMetadata()
            XCTFail("Expected the metadata scan failure to propagate.")
        } catch MetadataScanError.failed {
            XCTAssertEqual(manager.metadataScanCount, 1)
        }
    }

    @MainActor
    func testRefreshAllFilesMetadataDoesNotJoinDifferentRealmConfigurationGenerations() async throws {
        let rootURL = try temporaryDirectory()
        let manager = CountingReaderFileManager()
        let firstConfiguration = makeHistoryRealmConfiguration()
        let secondConfiguration = makeHistoryRealmConfiguration()
        manager.historyRealmConfigurationOverride = firstConfiguration
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: rootURL))
        let firstScanStarted = expectation(description: "first configuration scan started")
        manager.scanDidStart = { firstScanStarted.fulfill() }

        let firstRefresh = Task { @MainActor in
            try await manager.refreshAllFilesMetadata()
        }
        await fulfillment(of: [firstScanStarted], timeout: 1)
        manager.scanDidStart = nil
        manager.historyRealmConfigurationOverride = secondConfiguration
        try await manager.refreshAllFilesMetadata()

        do {
            try await firstRefresh.value
            XCTFail("Expected the replaced configuration refresh to be rejected.")
        } catch ReaderFileManagerError.refreshSuperseded {
            // The second configuration owns its own scan and publication.
        }
        XCTAssertEqual(manager.metadataScanCount, 2)
    }

    @MainActor
    func testDriveChangeDuringRefreshForcesACompleteReplacementInventory() async throws {
        let rootURL = try temporaryDirectory()
        let manager = CountingReaderFileManager()
        manager.historyRealmConfigurationOverride = makeHistoryRealmConfiguration()
        let drive = try await CloudDrive(storage: .localDirectory(rootURL: rootURL))
        manager.localDrive = drive
        let firstScanStarted = expectation(description: "first inventory scan started")
        let replacementScanStarted = expectation(description: "replacement inventory scan started")
        var observedScanCount = 0
        manager.scanDidStart = {
            observedScanCount += 1
            switch observedScanCount {
            case 1:
                firstScanStarted.fulfill()
            case 2:
                replacementScanStarted.fulfill()
            default:
                break
            }
        }

        let refresh = Task { @MainActor in
            try await manager.refreshAllFilesMetadata()
        }
        await fulfillment(of: [firstScanStarted], timeout: 1)
        manager.cloudDriveDidChange(drive, rootRelativePaths: [.root])
        await fulfillment(of: [replacementScanStarted], timeout: 1)
        try await refresh.value

        XCTAssertEqual(manager.metadataScanCount, 2)
    }

    @MainActor
    func testCancelledForcedFollowUpFailsJoinedCallersAndExplicitRetryUsesFreshInventory() async throws {
        let (manager, realm) = try await controlledMetadataFixture()
        let orphan = ContentFile()
        orphan.url = URL(string: "reader-file://file/local/retired.txt")!
        orphan.title = "Retired file"
        orphan.updateCompoundKey()
        try realm.write {
            realm.add(orphan)
            orphan.refreshChangeMetadata(explicitlyModified: true, at: Date(timeIntervalSince1970: 1_700_000_000))
        }
        let orphanJournalKey = orphan.objectSchema.className + "." + orphan.compoundKey
        let seededGeneration = try XCTUnwrap(realm.object(
            ofType: BigSyncPendingMutation.self, forPrimaryKey: orphanJournalKey
        )).generation
        let firstPass = InventoryPassGate()
        let firstScanStarted = expectation(description: "original inventory captured")
        manager.scan = { scan in
            XCTAssertEqual(scan, 1)
            firstScanStarted.fulfill()
            await firstPass.wait()
            return []
        }
        let owner = Task { @MainActor in
            try await ReaderFileMetadataRefreshObservation.$didFinishPass.withValue({
                // The real orphan transaction has settled. Cancel the owned
                // refresh independently of its callers before loop admission.
                XCTAssertFalse(Task.isCancelled)
                manager.appSuspendedDidChange(isSuspended: true)
                XCTAssertTrue(Task.isCancelled)
            }) {
                try await manager.refreshAllFilesMetadata()
            }
        }
        trackMetadataRefresh(owner, manager: manager, gates: [firstPass])
        await fulfillment(of: [firstScanStarted], timeout: 2)

        let forcedJoined = expectation(description: "post-move inventory requested its follow-up")
        let forced = Task { @MainActor in
            try await ReaderFileMetadataRefreshObservation.$didJoin.withValue({ force in
                XCTAssertTrue(force)
                forcedJoined.fulfill()
            }) {
                try await manager.refreshAllFilesMetadata(force: true)
            }
        }
        trackMetadataRefresh(forced, manager: manager, gates: [firstPass])
        let ordinaryJoined = expectation(description: "ordinary caller joined the same owner")
        let ordinary = Task { @MainActor in
            try await ReaderFileMetadataRefreshObservation.$didJoin.withValue({ force in
                XCTAssertFalse(force)
                ordinaryJoined.fulfill()
            }) {
                try await manager.refreshAllFilesMetadata()
            }
        }
        trackMetadataRefresh(ordinary, manager: manager, gates: [firstPass])
        await fulfillment(of: [forcedJoined, ordinaryJoined], timeout: 2)
        firstPass.release()

        for task in [owner, forced, ordinary] {
            do {
                try await task.value
                XCTFail("A cancelled refresh cannot acknowledge its abandoned forced inventory")
            } catch is CancellationError {
            } catch {
                XCTFail("Unexpected refresh error: \(error)")
            }
            XCTAssertFalse(task.isCancelled, "The owned refresh failed; its independent waiter was not cancelled")
        }
        XCTAssertFalse(Task.isCancelled, "The manager's cancellation must not cancel this caller")
        XCTAssertEqual(manager.metadataScanCount, 1)
        await realm.asyncRefresh()
        XCTAssertTrue(orphan.isDeleted, "The already committed pass must remain durable")
        XCTAssertEqual(orphan.title, "Retired file")
        let committed = try XCTUnwrap(realm.object(
            ofType: BigSyncPendingMutation.self, forPrimaryKey: orphanJournalKey
        ))
        let committedGeneration = committed.generation
        let committedDate = committed.changedAt
        XCTAssertNotEqual(committedGeneration, seededGeneration)
        XCTAssertEqual(committedDate, orphan.modifiedAt)
        XCTAssertEqual(committedDate, orphan.explicitlyModifiedAt)
        XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, 1)

        let current = ContentFile()
        current.url = URL(string: "reader-file://file/local/current.txt")!
        current.title = "Current inventory"
        current.updateCompoundKey()
        try realm.write {
            realm.add(current)
            current.refreshChangeMetadata(explicitlyModified: true)
        }
        manager.scan = { scan in
            XCTAssertEqual(scan, 2)
            return [ThreadSafeReference(to: current)]
        }
        try await manager.refreshAllFilesMetadata(force: true)
        await realm.asyncRefresh()
        XCTAssertEqual(manager.metadataScanCount, 2)
        XCTAssertEqual(manager.files?.map(\.compoundKey), [current.compoundKey])
        XCTAssertFalse(current.isDeleted)
        XCTAssertTrue(orphan.isDeleted)
        XCTAssertEqual(committed.generation, committedGeneration, "Retry must not re-journal an existing tombstone")
        XCTAssertEqual(committed.changedAt, committedDate)
        XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, 2)
    }

    @MainActor
    func testForcedMetadataRefreshWaitsForFollowUpBeforeJoinedCallersReturn() async throws {
        let (manager, realm) = try await controlledMetadataFixture()
        let firstPass = InventoryPassGate()
        let followUpPass = InventoryPassGate()
        let firstScanStarted = expectation(description: "first pass started")
        let followUpStarted = expectation(description: "forced follow-up started")
        manager.scan = { scan in
            switch scan {
            case 1:
                firstScanStarted.fulfill()
                await firstPass.wait()
            case 2:
                followUpStarted.fulfill()
                await followUpPass.wait()
            default:
                XCTFail("Coalesced force requests need only one follow-up")
            }
            return []
        }
        let state = InventoryRefreshCompletionState()
        let owner = Task { @MainActor in
            defer { state.firstReturned = true }
            try await manager.refreshAllFilesMetadata()
        }
        trackMetadataRefresh(owner, manager: manager, gates: [firstPass, followUpPass])
        await fulfillment(of: [firstScanStarted], timeout: 2)
        let forcedJoined = expectation(description: "forced caller joined")
        let forced = Task { @MainActor in
            defer { state.forcedReturned = true }
            try await ReaderFileMetadataRefreshObservation.$didJoin.withValue({ force in
                XCTAssertTrue(force)
                forcedJoined.fulfill()
            }) {
                try await manager.refreshAllFilesMetadata(force: true)
            }
        }
        trackMetadataRefresh(forced, manager: manager, gates: [firstPass, followUpPass])
        let ordinaryJoined = expectation(description: "ordinary caller joined")
        let ordinary = Task { @MainActor in
            defer { state.ordinaryReturned = true }
            try await ReaderFileMetadataRefreshObservation.$didJoin.withValue({ force in
                XCTAssertFalse(force)
                ordinaryJoined.fulfill()
            }) {
                try await manager.refreshAllFilesMetadata()
            }
        }
        trackMetadataRefresh(ordinary, manager: manager, gates: [firstPass, followUpPass])
        await fulfillment(of: [forcedJoined, ordinaryJoined], timeout: 2)
        firstPass.release()
        await fulfillment(of: [followUpStarted], timeout: 2)
        XCTAssertEqual(manager.metadataScanCount, 2)
        XCTAssertFalse(state.firstReturned)
        XCTAssertFalse(state.forcedReturned)
        XCTAssertFalse(state.ordinaryReturned)
        followUpPass.release()
        try await owner.value
        try await forced.value
        try await ordinary.value
        XCTAssertTrue(state.firstReturned)
        XCTAssertTrue(state.forcedReturned)
        XCTAssertTrue(state.ordinaryReturned)
        XCTAssertEqual(manager.metadataScanCount, 2)
        XCTAssertEqual(manager.files?.count, 0)
        XCTAssertTrue(realm.objects(BigSyncPendingMutation.self).isEmpty)
    }

    @MainActor
    func testSuccessfulInventoryDebouncesFromCompletionRatherThanScanStart() async throws {
        let clock = InventoryRefreshClock()
        try await ReaderFileMetadataRefreshObservation.$now.withValue({ clock.date }) {
            try await withScanningMetadataFixture { manager, _, root in
                _ = try writeFixture(relativePath: "first.txt", under: root)
                let startedAt = clock.date
                try await ReaderFileMetadataRefreshObservation.$didFinishPass.withValue({
                    // The real scan and orphan transaction took ten clock
                    // seconds. Only the debounce clock is controlled here.
                    clock.date = startedAt.addingTimeInterval(10)
                }) {
                    try await manager.refreshAllFilesMetadata()
                }
                XCTAssertEqual(manager.metadataScanCount, 1)
                XCTAssertEqual(manager.files?.map(\.title), ["first"])

                try await manager.refreshAllFilesMetadata()
                XCTAssertEqual(manager.metadataScanCount, 1)
                clock.date = startedAt.addingTimeInterval(11.999)
                try await manager.refreshAllFilesMetadata()
                XCTAssertEqual(manager.metadataScanCount, 1)

                clock.date = startedAt.addingTimeInterval(12)
                try await manager.refreshAllFilesMetadata()
                XCTAssertEqual(manager.metadataScanCount, 2)
                XCTAssertEqual(manager.files?.map(\.title), ["first"])
            }
        }
    }

    @MainActor
    func testFailedForcedInventoryAllowsOrdinaryRetryAtTheSameClockTime() async throws {
        let clock = InventoryRefreshClock()
        try await ReaderFileMetadataRefreshObservation.$now.withValue({ clock.date }) {
            try await withScanningMetadataFixture { manager, realm, root in
                _ = try writeFixture(relativePath: "first.txt", under: root)
                try await manager.refreshAllFilesMetadata()
                await realm.asyncRefresh()
                let existing = try XCTUnwrap(realm.objects(ContentFile.self).first)
                let journalKey = existing.objectSchema.className + "." + existing.compoundKey
                let originalGeneration = try XCTUnwrap(realm.object(
                    ofType: BigSyncPendingMutation.self, forPrimaryKey: journalKey
                )).generation

                _ = try writeFixture(relativePath: "second.txt", under: root)
                manager.nextScanError = MetadataScanError.failed
                do {
                    try await manager.refreshAllFilesMetadata(force: true)
                    XCTFail("The forced scan failure must propagate")
                } catch MetadataScanError.failed {
                }
                XCTAssertEqual(manager.metadataScanCount, 2)
                XCTAssertEqual(manager.files?.map(\.title), ["first"])
                await realm.asyncRefresh()
                XCTAssertFalse(existing.isDeleted)
                XCTAssertEqual(realm.object(
                    ofType: BigSyncPendingMutation.self, forPrimaryKey: journalKey
                )?.generation, originalGeneration)

                // No clock time passes: an earlier successful scan must not
                // suppress recovery after this forced scan failed.
                try await manager.refreshAllFilesMetadata()
                XCTAssertEqual(manager.metadataScanCount, 3)
                XCTAssertEqual(Set(manager.files?.map(\.title) ?? []), Set(["first", "second"]))
                await realm.asyncRefresh()
                XCTAssertEqual(realm.objects(ContentFile.self).filter("isDeleted == false").count, 2)
            }
        }
    }

    @MainActor
    func testFailedReplacementInventoryRetriesWhilePreviousFilesRemainVisible() async throws {
        let clock = InventoryRefreshClock()
        try await ReaderFileMetadataRefreshObservation.$now.withValue({ clock.date }) {
            try await withScanningMetadataFixture { manager, realm, root in
                _ = try writeFixture(relativePath: "previous.txt", under: root)
                try await manager.refreshAllFilesMetadata()
                await realm.asyncRefresh()
                let previous = try XCTUnwrap(realm.objects(ContentFile.self).first)
                let replacementRoot = try temporaryDirectory()
                _ = try writeFixture(relativePath: "replacement.txt", under: replacementRoot)
                manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: replacementRoot))
                manager.nextScanError = MetadataScanError.failed
                do {
                    try await manager.refreshAllFilesMetadata()
                    XCTFail("The new drive's failed first scan must propagate")
                } catch MetadataScanError.failed {
                }
                XCTAssertEqual(manager.metadataScanCount, 2)
                XCTAssertEqual(manager.files?.map(\.title), ["previous"])
                await realm.asyncRefresh()
                XCTAssertFalse(previous.isDeleted)

                try await manager.refreshAllFilesMetadata()
                XCTAssertEqual(manager.metadataScanCount, 3)
                XCTAssertEqual(manager.files?.map(\.title), ["replacement"])
                await realm.asyncRefresh()
                XCTAssertTrue(previous.isDeleted)
                XCTAssertEqual(realm.objects(ContentFile.self).filter("isDeleted == false").count, 1)
            }
        }
    }

    @MainActor
    func testReturningToPreviousDriveCannotDebounceTheReplacementInventory() async throws {
        let clock = InventoryRefreshClock()
        try await ReaderFileMetadataRefreshObservation.$now.withValue({ clock.date }) {
            try await withScanningMetadataFixture { manager, realm, firstRoot in
                let firstDrive = try XCTUnwrap(manager.localDrive)
                _ = try writeFixture(relativePath: "first.txt", under: firstRoot)
                try await manager.refreshAllFilesMetadata()
                await realm.asyncRefresh()
                let first = try XCTUnwrap(realm.objects(ContentFile.self).first)
                XCTAssertEqual(manager.metadataScanCount, 1)
                XCTAssertEqual(manager.files?.map(\.title), ["first"])

                let secondRoot = try temporaryDirectory()
                _ = try writeFixture(relativePath: "second.txt", under: secondRoot)
                manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: secondRoot))
                try await manager.refreshAllFilesMetadata()
                await realm.asyncRefresh()
                let second = try XCTUnwrap(realm.objects(ContentFile.self).filter("isDeleted == false").first)
                XCTAssertEqual(manager.metadataScanCount, 2)
                XCTAssertEqual(manager.files?.map(\.title), ["second"])
                XCTAssertTrue(first.isDeleted)
                XCTAssertFalse(second.isDeleted)

                // The first drive has the same value identity as before, but
                // its old success no longer owns the one published snapshot.
                manager.localDrive = firstDrive
                try await manager.refreshAllFilesMetadata()
                await realm.asyncRefresh()
                XCTAssertEqual(manager.metadataScanCount, 3)
                XCTAssertEqual(manager.files?.map(\.title), ["first"])
                XCTAssertFalse(first.isDeleted)
                XCTAssertTrue(second.isDeleted)
                XCTAssertEqual(realm.objects(ContentFile.self).filter("isDeleted == false").count, 1)
            }
        }
    }

    @MainActor
    func testLateCompletionCannotGiveItsDebounceToAReplacementSnapshot() async throws {
        let clock = InventoryRefreshClock()
        try await ReaderFileMetadataRefreshObservation.$now.withValue({ clock.date }) {
            try await withScanningMetadataFixture { manager, realm, firstRoot in
                let firstDrive = try XCTUnwrap(manager.localDrive)
                _ = try writeFixture(relativePath: "first.txt", under: firstRoot)
                let heldCompletion = InventoryPassGate()
                let firstCommitted = expectation(description: "first scan committed before completion")
                let firstRefresh = Task { @MainActor in
                    try await ReaderFileMetadataRefreshObservation.$beforeCompletion.withValue({
                        firstCommitted.fulfill()
                        await heldCompletion.wait()
                    }) {
                        try await manager.refreshAllFilesMetadata()
                    }
                }
                trackMetadataRefresh(firstRefresh, manager: manager, gates: [heldCompletion])
                await fulfillment(of: [firstCommitted], timeout: 2)
                await realm.asyncRefresh()
                let first = try XCTUnwrap(realm.objects(ContentFile.self).first)
                XCTAssertEqual(manager.files?.map(\.title), ["first"])

                let secondRoot = try temporaryDirectory()
                _ = try writeFixture(relativePath: "second.txt", under: secondRoot)
                manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: secondRoot))
                try await manager.refreshAllFilesMetadata()
                await realm.asyncRefresh()
                let second = try XCTUnwrap(realm.objects(ContentFile.self).filter("isDeleted == false").first)
                XCTAssertEqual(manager.metadataScanCount, 2)
                XCTAssertEqual(manager.files?.map(\.title), ["second"])
                XCTAssertTrue(first.isDeleted)

                // Value identity alone would admit the old completion here,
                // although the second scan now owns the visible snapshot.
                manager.localDrive = firstDrive
                heldCompletion.release()
                try await firstRefresh.value
                XCTAssertEqual(manager.files?.map(\.title), ["second"])
                try await manager.refreshAllFilesMetadata()
                await realm.asyncRefresh()
                XCTAssertEqual(manager.metadataScanCount, 3)
                XCTAssertEqual(manager.files?.map(\.title), ["first"])
                XCTAssertFalse(first.isDeleted)
                XCTAssertTrue(second.isDeleted)
                XCTAssertEqual(realm.objects(ContentFile.self).filter("isDeleted == false").count, 1)

                // A later publication through the public property also retires
                // an already-recorded marker for the previous snapshot.
                manager.files = []
                try await manager.refreshAllFilesMetadata()
                XCTAssertEqual(manager.metadataScanCount, 4)
                XCTAssertEqual(manager.files?.map(\.title), ["first"])
            }
        }
    }

    @MainActor
    func testCancelledInventoryAllowsOrdinaryRetryAtTheSameClockTime() async throws {
        let clock = InventoryRefreshClock()
        try await ReaderFileMetadataRefreshObservation.$now.withValue({ clock.date }) {
            try await withScanningMetadataFixture { manager, realm, root in
                _ = try writeFixture(relativePath: "committed.txt", under: root)
                do {
                    try await ReaderFileMetadataRefreshObservation.$didFinishPass.withValue({
                        manager.appSuspendedDidChange(isSuspended: true)
                        XCTAssertTrue(Task.isCancelled)
                    }) {
                        try await manager.refreshAllFilesMetadata()
                    }
                    XCTFail("The owner cancellation must be reported after its committed pass")
                } catch is CancellationError {
                }
                XCTAssertFalse(Task.isCancelled, "The independent waiter remains active")
                XCTAssertEqual(manager.metadataScanCount, 1)
                XCTAssertEqual(manager.files?.map(\.title), ["committed"])
                await realm.asyncRefresh()
                XCTAssertFalse(try XCTUnwrap(realm.objects(ContentFile.self).first).isDeleted)

                _ = try writeFixture(relativePath: "resumed.txt", under: root)
                // This is the same ordinary entry used by app resume. Its
                // retry cannot rely on two seconds of wall time having passed.
                try await manager.refreshAllFilesMetadata()
                XCTAssertEqual(manager.metadataScanCount, 2)
                XCTAssertEqual(Set(manager.files?.map(\.title) ?? []), Set(["committed", "resumed"]))
                await realm.asyncRefresh()
                XCTAssertEqual(realm.objects(ContentFile.self).filter("isDeleted == false").count, 2)
            }
        }
    }

    @MainActor
    func testResumeWaitsForCancelledInventoryThenScansCurrentFiles() async throws {
        let clock = InventoryRefreshClock()
        try await ReaderFileMetadataRefreshObservation.$now.withValue({ clock.date }) {
            try await withScanningMetadataFixture { manager, realm, root in
                let firstURL = try writeFixture(relativePath: "first.txt", under: root)
                try FileManager.default.setAttributes(
                    [.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
                    ofItemAtPath: firstURL.path
                )
                try await manager.refreshAllFilesMetadata()
                await realm.asyncRefresh()
                let first = try XCTUnwrap(realm.objects(ContentFile.self).first)
                let journalKey = first.objectSchema.className + "." + first.compoundKey
                let generation = try XCTUnwrap(realm.object(
                    ofType: BigSyncPendingMutation.self, forPrimaryKey: journalKey
                )).generation
                _ = try writeFixture(relativePath: "resumed.txt", under: root)

                let heldScan = InventoryPassGate()
                let scanStarted = expectation(description: "replacement scan is still pending")
                manager.beforeScan = { scan in
                    if scan == 2 {
                        scanStarted.fulfill()
                        await heldScan.wait()
                    }
                }
                let owner = Task { @MainActor in
                    try await manager.refreshAllFilesMetadata(force: true)
                }
                trackMetadataRefresh(owner, manager: manager, gates: [heldScan])
                await fulfillment(of: [scanStarted], timeout: 2)
                manager.appSuspendedDidChange(isSuspended: true)

                let resumeJoined = expectation(description: "resume awaits the cancelled owner")
                let resume = try ReaderFileMetadataRefreshObservation.$didJoin.withValue({ force in
                    XCTAssertFalse(force)
                    resumeJoined.fulfill()
                }) {
                    try resumeMetadataRefresh(manager)
                }
                trackMetadataRefresh(resume, manager: manager, gates: [heldScan])
                await fulfillment(of: [resumeJoined], timeout: 2)
                XCTAssertEqual(manager.metadataScanCount, 2)
                heldScan.release()
                do {
                    try await owner.value
                    XCTFail("The independent caller must still receive its owner's cancellation")
                } catch is CancellationError {
                }
                await resume.value

                XCTAssertFalse(owner.isCancelled)
                XCTAssertEqual(manager.metadataScanCount, 3)
                XCTAssertEqual(Set(manager.files?.map(\.title) ?? []), Set(["first", "resumed"]))
                await realm.asyncRefresh()
                XCTAssertFalse(first.isDeleted)
                XCTAssertEqual(realm.object(
                    ofType: BigSyncPendingMutation.self, forPrimaryKey: journalKey
                )?.generation, generation, "Recovery must not journal an unchanged existing file")
                XCTAssertEqual(realm.objects(ContentFile.self).filter("isDeleted == false").count, 2)
                XCTAssertEqual(realm.objects(BigSyncPendingMutation.self).count, 2)
            }
        }
    }

    @MainActor
    func testSuspensionRetiresWaitingAndQueuedResumeWork() async throws {
        try await withScanningMetadataFixture { manager, realm, root in
            _ = try writeFixture(relativePath: "current.txt", under: root)
            let heldScan = InventoryPassGate()
            let scanStarted = expectation(description: "first scan is pending")
            manager.beforeScan = { scan in
                if scan == 1 {
                    scanStarted.fulfill()
                    await heldScan.wait()
                }
            }
            let owner = Task { @MainActor in
                try await manager.refreshAllFilesMetadata()
            }
            trackMetadataRefresh(owner, manager: manager, gates: [heldScan])
            await fulfillment(of: [scanStarted], timeout: 2)
            manager.appSuspendedDidChange(isSuspended: true)
            let resumeJoined = expectation(description: "resume is waiting for retirement")
            let waitingResume = try ReaderFileMetadataRefreshObservation.$didJoin.withValue({ force in
                XCTAssertFalse(force)
                resumeJoined.fulfill()
            }) {
                try resumeMetadataRefresh(manager)
            }
            trackMetadataRefresh(waitingResume, manager: manager, gates: [heldScan])
            await fulfillment(of: [resumeJoined], timeout: 2)
            manager.appSuspendedDidChange(isSuspended: true)
            heldScan.release()
            do {
                try await owner.value
                XCTFail("The suspended owner must still fail")
            } catch is CancellationError {
            }
            await waitingResume.value
            XCTAssertEqual(manager.metadataScanCount, 1)
            XCTAssertNil(manager.files)

            // Retire another activation before its MainActor task can enter.
            let queuedResume = try resumeMetadataRefresh(manager)
            trackMetadataRefresh(queuedResume, manager: manager, gates: [heldScan])
            manager.appSuspendedDidChange(isSuspended: true)
            await queuedResume.value
            XCTAssertEqual(manager.metadataScanCount, 1)

            let currentResume = try resumeMetadataRefresh(manager)
            trackMetadataRefresh(currentResume, manager: manager, gates: [heldScan])
            await currentResume.value
            XCTAssertEqual(manager.metadataScanCount, 2)
            XCTAssertEqual(manager.files?.map(\.title), ["current"])
            await realm.asyncRefresh()
            XCTAssertEqual(realm.objects(ContentFile.self).filter("isDeleted == false").count, 1)
        }
    }

    @MainActor
    func testNewerResumeOwnsRecoveryAndUsesTheCurrentRealmAfterWaiting() async throws {
        try await withScanningMetadataFixture { manager, previousRealm, root in
            _ = try writeFixture(relativePath: "current.txt", under: root)
            let currentConfiguration = makeHistoryRealmConfiguration()
            let currentIdentifier = try XCTUnwrap(currentConfiguration.inMemoryIdentifier)
            let currentRealm = try Realm(configuration: currentConfiguration)
            addTeardownBlock {
                await Self.releaseMetadataFixtureRealms(owner: .shared, identifier: currentIdentifier)
            }
            let heldScan = InventoryPassGate()
            let scanStarted = expectation(description: "original scan is pending")
            manager.beforeScan = { scan in
                if scan == 1 {
                    scanStarted.fulfill()
                    await heldScan.wait()
                }
            }
            let owner = Task { @MainActor in
                try await manager.refreshAllFilesMetadata()
            }
            trackMetadataRefresh(owner, manager: manager, gates: [heldScan])
            await fulfillment(of: [scanStarted], timeout: 2)

            let healthyJoined = expectation(description: "resume shares the still healthy owner")
            let healthyResume = try ReaderFileMetadataRefreshObservation.$didJoin.withValue({ force in
                XCTAssertFalse(force)
                healthyJoined.fulfill()
            }) {
                try resumeMetadataRefresh(manager)
            }
            trackMetadataRefresh(healthyResume, manager: manager, gates: [heldScan])
            await fulfillment(of: [healthyJoined], timeout: 2)
            XCTAssertEqual(manager.metadataScanCount, 1)
            manager.appSuspendedDidChange(isSuspended: true)

            let earlierJoined = expectation(description: "earlier resume awaits cancelled owner")
            let earlierResume = try ReaderFileMetadataRefreshObservation.$didJoin.withValue({ force in
                XCTAssertFalse(force)
                earlierJoined.fulfill()
            }) {
                try resumeMetadataRefresh(manager)
            }
            trackMetadataRefresh(earlierResume, manager: manager, gates: [heldScan])
            await fulfillment(of: [earlierJoined], timeout: 2)
            let currentJoined = expectation(description: "newer resume awaits cancelled owner")
            let currentResume = try ReaderFileMetadataRefreshObservation.$didJoin.withValue({ force in
                XCTAssertFalse(force)
                currentJoined.fulfill()
            }) {
                try resumeMetadataRefresh(manager)
            }
            trackMetadataRefresh(currentResume, manager: manager, gates: [heldScan])
            await fulfillment(of: [currentJoined], timeout: 2)
            manager.historyRealmConfigurationOverride = currentConfiguration
            heldScan.release()
            do {
                try await owner.value
                XCTFail("The original owner cannot report success after suspension")
            } catch is CancellationError {
            }
            await healthyResume.value
            await earlierResume.value
            await currentResume.value

            XCTAssertEqual(manager.metadataScanCount, 2, "Only the latest resumed activation may recover")
            XCTAssertEqual(manager.files?.map(\.title), ["current"])
            await previousRealm.asyncRefresh()
            await currentRealm.asyncRefresh()
            XCTAssertTrue(previousRealm.objects(ContentFile.self).isEmpty)
            XCTAssertTrue(previousRealm.objects(BigSyncPendingMutation.self).isEmpty)
            XCTAssertEqual(currentRealm.objects(ContentFile.self).filter("isDeleted == false").count, 1)
            XCTAssertEqual(currentRealm.objects(BigSyncPendingMutation.self).count, 1)
        }
    }

    func testCanonicalReaderBackingURLStripsQueryAndFragmentFromReaderFileURL() {
        let manager = ReaderFileManager()
        let url = URL(string: "reader-file://file/load/icloud/Books/test.cbz?subpath=cover.jpg#fragment")!

        let result = manager.canonicalReaderBackingURL(for: url)

        XCTAssertEqual(result?.absoluteString, "reader-file://file/load/icloud/Books/test.cbz")
    }

    func testCanonicalReaderBackingURLMapsEbookURLToReaderBackingURL() {
        let manager = ReaderFileManager()
        let url = URL(string: "ebook://ebook/load/icloud/Books/test.epub?subpath=OPS/chapter1.xhtml")!

        let result = manager.canonicalReaderBackingURL(for: url)

        XCTAssertEqual(result?.absoluteString, "reader-file://file/load/icloud/Books/test.epub")
    }

    func testCanonicalReaderBackingURLMapsMokuroURLToReaderBackingURL() {
        let manager = ReaderFileManager()
        let url = URL(string: "mokuro://mokuro/load/local/Manga/series.mokuro?subpath=page-1.json")!

        let result = manager.canonicalReaderBackingURL(for: url)

        XCTAssertEqual(result?.absoluteString, "reader-file://file/load/local/Manga/series.mokuro")
    }

    func testCanonicalReaderBackingURLReturnsNilForNonReaderBackedURL() {
        let manager = ReaderFileManager()

        XCTAssertNil(manager.canonicalReaderBackingURL(for: URL(string: "https://example.com/book")!))
    }

    @MainActor
    func testConfiguredLocalDriveRootOwnsEbookStatusAndResolution() async throws {
        let configuredRoot = try temporaryDirectory()
        let fallbackRoot = try temporaryDirectory()
        let expectedURL = try writeFixture(relativePath: "Books/configured.epub", under: configuredRoot)
        _ = try writeFixture(relativePath: "Books/configured.epub", under: fallbackRoot)
        let manager = ReaderFileManager(defaultLocalRootURLProvider: { fallbackRoot })
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: configuredRoot))
        let readerURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/Books/configured.epub"))

        let status = try await manager.cloudDriveSyncStatus(readerFileURL: readerURL)
        let resolvedURL = try await manager.resolveReadableLocalURL(forReaderBackingURL: readerURL)

        XCTAssertEqual(status, .localOnly)
        XCTAssertEqual(resolvedURL.standardizedFileURL, expectedURL.standardizedFileURL)
    }

    @MainActor
    func testConfiguredLocalDriveDoesNotProbeFallbackRoot() async throws {
        let configuredRoot = try temporaryDirectory()
        let fallbackRoot = try temporaryDirectory()
        _ = try writeFixture(relativePath: "Books/fallback-only.epub", under: fallbackRoot)
        let manager = ReaderFileManager(defaultLocalRootURLProvider: { fallbackRoot })
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: configuredRoot))
        let readerURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/Books/fallback-only.epub"))

        let status = try await manager.cloudDriveSyncStatus(readerFileURL: readerURL)

        XCTAssertEqual(status, .fileMissing)
    }

    @MainActor
    func testLocalResolutionUsesInjectedRootBeforeDriveInitialization() async throws {
        let fallbackRoot = try temporaryDirectory()
        let expectedURL = try writeFixture(relativePath: "Books/cold-start.epub", under: fallbackRoot)
        let manager = ReaderFileManager(defaultLocalRootURLProvider: { fallbackRoot })
        let readerURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/Books/cold-start.epub"))

        let resolvedURL = try await manager.resolveReadableLocalURL(forReaderBackingURL: readerURL)

        XCTAssertEqual(resolvedURL.standardizedFileURL, expectedURL.standardizedFileURL)
    }

    @MainActor
    func testLocalResolutionSnapshotsColdStartRootOnce() async throws {
        let firstRoot = try temporaryDirectory()
        let laterRoot = try temporaryDirectory()
        let expectedURL = try writeFixture(relativePath: "Books/snapshot.epub", under: firstRoot)
        let provider = SequencedRootProvider(roots: [firstRoot, laterRoot])
        let manager = ReaderFileManager(defaultLocalRootURLProvider: provider.next)
        let readerURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/Books/snapshot.epub"))

        let resolvedURL = try await manager.resolveReadableLocalURL(forReaderBackingURL: readerURL)

        XCTAssertEqual(resolvedURL.standardizedFileURL, expectedURL.standardizedFileURL)
        XCTAssertEqual(provider.invocationCount, 1)
    }

    @MainActor
    func testMissingLocalBackingFileReportsFileMissing() async throws {
        let fallbackRoot = try temporaryDirectory()
        let manager = ReaderFileManager(defaultLocalRootURLProvider: { fallbackRoot })
        let readerURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/Books/missing.epub"))

        let status = try await manager.cloudDriveSyncStatus(readerFileURL: readerURL)
        XCTAssertEqual(status, .fileMissing)
    }

    @MainActor
    func testLocalBackingPathCannotEscapeConfiguredRoot() async throws {
        let configuredRoot = try temporaryDirectory()
        let manager = ReaderFileManager(defaultLocalRootURLProvider: { configuredRoot })
        let traversalURLs = [
            "ebook://ebook/load/local/Books/../outside.epub",
            "ebook://ebook/load/local/Books/%2E%2E/outside.epub",
            "ebook://ebook/load/local/Books/%2Foutside.epub",
        ]

        for rawURL in traversalURLs {
            let readerURL = try XCTUnwrap(URL(string: rawURL))
            do {
                _ = try await manager.resolveReadableLocalURL(forReaderBackingURL: readerURL)
                XCTFail("Expected invalid reader backing path for \(rawURL)")
            } catch ReaderFileManagerError.invalidFileURL {
                // Expected.
            } catch {
                XCTFail("Unexpected error for \(rawURL): \(error)")
            }
        }
    }
}

final class ReaderFileOperationMessageMapperTests: XCTestCase {
    func testOpenMessageMapsDownloadInProgress() {
        XCTAssertEqual(
            ReaderFileOperationMessageMapper.openMessage(for: ReaderFileAccessError.downloadInProgress),
            "Downloading from iCloud. Try opening again when the download finishes."
        )
    }

    func testOpenMessageMapsNotAvailableOffline() {
        XCTAssertEqual(
            ReaderFileOperationMessageMapper.openMessage(for: ReaderFileAccessError.notAvailableOffline),
            "This book is in iCloud and isn't available offline yet."
        )
    }

    func testDeleteAlertMapsBlockedCloudOnly() {
        let alert = ReaderFileOperationMessageMapper.deleteAlert(for: ReaderFileDeleteError.blockedCloudOnly)

        XCTAssertEqual(alert?.title, "Delete Failed")
        XCTAssertEqual(alert?.message, "Download this iCloud file first, then delete it.")
    }

    func testDeleteAlertMapsRemoveFailedDescription() {
        let alert = ReaderFileOperationMessageMapper.deleteAlert(
            for: ReaderFileDeleteError.removeFailed(underlyingDescription: "The file couldn't be coordinated.")
        )

        XCTAssertEqual(alert?.title, "Delete Failed")
        XCTAssertEqual(alert?.message, "Couldn't delete the iCloud file. The file couldn't be coordinated.")
    }
}
