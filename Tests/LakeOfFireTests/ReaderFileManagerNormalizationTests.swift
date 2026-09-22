import XCTest
import RealmSwift
import RealmSwiftGaps
import SwiftCloudDrive
@testable import LakeOfFireContent

@MainActor
private final class CountingReaderFileManager: ReaderFileManager, @unchecked Sendable {
    private(set) var metadataScanCount = 0
    var scanError: (any Swift.Error)?
    var scanDidStart: (() -> Void)?
    var scanBlocker: (@MainActor (Int) async -> Void)?
    var scanDelayNanoseconds: UInt64 = 100_000_000

    override func refreshFilesMetadata(
        drive: CloudDrive,
        relativePath: RootRelativePath? = nil,
        realmConfiguration: Realm.Configuration? = nil
    ) async throws -> [ThreadSafeReference<ContentFile>]? {
        metadataScanCount += 1
        scanDidStart?()
        await scanBlocker?(metadataScanCount)
        if let scanError {
            throw scanError
        }
        try await Task.sleep(nanoseconds: scanDelayNanoseconds)
        return []
    }
}

final class ReaderFileManagerNormalizationTests: XCTestCase {
    private enum MetadataScanError: Swift.Error {
        case failed
    }

    private actor ScanGate {
        private var didRelease = false
        private var waiter: CheckedContinuation<Void, Never>?

        func wait() async {
            guard !didRelease else { return }
            await withCheckedContinuation { waiter = $0 }
        }

        func release() {
            didRelease = true
            waiter?.resume()
            waiter = nil
        }
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

    private func makeHistoryRealmConfiguration(fileURL: URL? = nil) -> Realm.Configuration {
        var configuration: Realm.Configuration
        if let fileURL {
            configuration = Realm.Configuration(fileURL: fileURL)
        } else {
            configuration = Realm.Configuration(
                inMemoryIdentifier: "ReaderFileManagerNormalization.\(UUID().uuidString)"
            )
        }
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

    @RealmBackgroundActor
    private static func addContentFile(
        at readerURL: URL,
        to configuration: Realm.Configuration
    ) async throws -> String {
        let realm = try await Realm(
            configuration: configuration,
            actor: RealmBackgroundActor.shared
        )
        let contentFile = ContentFile()
        contentFile.url = readerURL
        contentFile.updateCompoundKey()
        try await realm.asyncWrite {
            realm.add(contentFile)
        }
        return contentFile.compoundKey
    }

    @RealmBackgroundActor
    private static func contentFileIsDeleted(
        primaryKey: String,
        in configuration: Realm.Configuration
    ) async throws -> Bool {
        let realm = try await Realm(
            configuration: configuration,
            actor: RealmBackgroundActor.shared
        )
        let contentFile: ContentFile = try XCTUnwrap(
            realm.object(ofType: ContentFile.self, forPrimaryKey: primaryKey)
        )
        return contentFile.isDeleted
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
    func testPreCancelledRefreshStopsBeforeRelocationPreflightAndScan() async {
        let rootURL: URL
        do {
            rootURL = try temporaryDirectory()
        } catch {
            XCTFail("Failed to create test directory: \(error)")
            return
        }
        let manager = CountingReaderFileManager()
        manager.historyRealmConfigurationOverride = makeHistoryRealmConfiguration()
        do {
            manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: rootURL))
        } catch {
            XCTFail("Failed to configure local drive: \(error)")
            return
        }
        manager.refreshRelocationPreflightDidCompleteForTesting = {
            XCTFail("A pre-cancelled refresh must not complete relocation preflight.")
        }
        manager.refreshTaskWaiterDidAdmitForTesting = { _ in
            XCTFail("A pre-cancelled refresh must not admit a scan waiter.")
        }

        let result = await withTaskGroup(
            of: Result<Void, any Swift.Error>.self
        ) { group in
            group.cancelAll()
            group.addTask { @MainActor in
                do {
                    try await manager.refreshAllFilesMetadata(force: true)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
            return await group.next() ?? .success(())
        }

        switch result {
        case .failure(is CancellationError):
            break
        case .failure(let error):
            XCTFail("Unexpected pre-cancelled refresh error: \(error)")
        case .success:
            XCTFail("Expected the pre-cancelled refresh to throw cancellation.")
        }
        XCTAssertEqual(manager.metadataScanCount, 0)
    }

    @MainActor
    func testCancellingRefreshCreatorDoesNotHideSharedScanFailureFromJoiner() async throws {
        let rootURL = try temporaryDirectory()
        let manager = CountingReaderFileManager()
        manager.scanDelayNanoseconds = 0
        manager.scanError = MetadataScanError.failed
        manager.historyRealmConfigurationOverride = makeHistoryRealmConfiguration()
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: rootURL))
        let scanGate = ScanGate()
        let scanStarted = expectation(description: "shared metadata scan started")
        let creatorAdmitted = expectation(description: "refresh creator waiter admitted")
        let joinerAdmitted = expectation(description: "refresh joiner waiter admitted")
        let creatorCompleted = expectation(description: "cancelled refresh creator completed")
        manager.scanDidStart = { scanStarted.fulfill() }
        manager.scanBlocker = { _ in await scanGate.wait() }
        manager.refreshTaskWaiterDidAdmitForTesting = { role in
            switch role {
            case .creator:
                creatorAdmitted.fulfill()
            case .joiner:
                joinerAdmitted.fulfill()
            case .forcedJoiner:
                XCTFail("Expected an ordinary refresh joiner.")
            }
        }

        let creator = Task { @MainActor () -> Result<Void, any Swift.Error> in
            defer { creatorCompleted.fulfill() }
            do {
                try await manager.refreshAllFilesMetadata()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        await fulfillment(of: [scanStarted, creatorAdmitted], timeout: 1)
        let joiner = Task { @MainActor in
            try await manager.refreshAllFilesMetadata()
        }
        await fulfillment(of: [joinerAdmitted], timeout: 1)
        creator.cancel()
        await fulfillment(of: [creatorCompleted], timeout: 1)

        switch await creator.value {
        case .failure(is CancellationError):
            break
        case .failure(let error):
            XCTFail("Unexpected creator error: \(error)")
        case .success:
            XCTFail("Expected the cancelled creator to stop awaiting the shared scan.")
        }
        await scanGate.release()
        do {
            try await joiner.value
            XCTFail("Expected the surviving joiner to receive the shared scan failure.")
        } catch MetadataScanError.failed {
            // Expected.
        }
        XCTAssertEqual(manager.metadataScanCount, 1)
    }

    @MainActor
    func testCancellingRefreshJoinerDoesNotCancelOwner() async throws {
        let rootURL = try temporaryDirectory()
        let manager = CountingReaderFileManager()
        manager.scanDelayNanoseconds = 0
        manager.historyRealmConfigurationOverride = makeHistoryRealmConfiguration()
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: rootURL))
        let scanGate = ScanGate()
        let scanStarted = expectation(description: "shared metadata scan started")
        let ownerAdmitted = expectation(description: "refresh owner waiter admitted")
        let joinerAdmitted = expectation(description: "refresh joiner waiter admitted")
        let joinerCompleted = expectation(description: "cancelled refresh joiner completed")
        manager.scanDidStart = { scanStarted.fulfill() }
        manager.scanBlocker = { _ in await scanGate.wait() }
        manager.refreshTaskWaiterDidAdmitForTesting = { role in
            switch role {
            case .creator:
                ownerAdmitted.fulfill()
            case .joiner:
                joinerAdmitted.fulfill()
            case .forcedJoiner:
                XCTFail("Expected an ordinary refresh joiner.")
            }
        }

        let owner = Task { @MainActor in
            try await manager.refreshAllFilesMetadata()
        }
        await fulfillment(of: [scanStarted, ownerAdmitted], timeout: 1)
        let joiner = Task { @MainActor () -> Result<Void, any Swift.Error> in
            defer { joinerCompleted.fulfill() }
            do {
                try await manager.refreshAllFilesMetadata()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        await fulfillment(of: [joinerAdmitted], timeout: 1)
        joiner.cancel()
        await fulfillment(of: [joinerCompleted], timeout: 1)

        switch await joiner.value {
        case .failure(is CancellationError):
            break
        case .failure(let error):
            XCTFail("Unexpected joiner error: \(error)")
        case .success:
            XCTFail("Expected the cancelled joiner to stop awaiting the shared scan.")
        }
        await scanGate.release()
        try await owner.value
        XCTAssertEqual(manager.metadataScanCount, 1)
    }

    @MainActor
    func testLateJoinerCanJoinSharedScanAfterEveryEarlierWaiterCancels() async throws {
        let rootURL = try temporaryDirectory()
        let manager = CountingReaderFileManager()
        manager.scanDelayNanoseconds = 0
        manager.historyRealmConfigurationOverride = makeHistoryRealmConfiguration()
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: rootURL))
        let scanGate = ScanGate()
        let scanStarted = expectation(description: "shared metadata scan started")
        let creatorAdmitted = expectation(description: "refresh creator waiter admitted")
        let firstJoinerAdmitted = expectation(description: "first refresh joiner waiter admitted")
        let lateJoinerAdmitted = expectation(description: "late refresh joiner waiter admitted")
        let creatorCompleted = expectation(description: "cancelled refresh creator completed")
        let firstJoinerCompleted = expectation(description: "cancelled first joiner completed")
        var admittedJoinerCount = 0
        manager.scanDidStart = { scanStarted.fulfill() }
        manager.scanBlocker = { _ in await scanGate.wait() }
        manager.refreshTaskWaiterDidAdmitForTesting = { role in
            switch role {
            case .creator:
                creatorAdmitted.fulfill()
            case .joiner:
                admittedJoinerCount += 1
                switch admittedJoinerCount {
                case 1:
                    firstJoinerAdmitted.fulfill()
                case 2:
                    lateJoinerAdmitted.fulfill()
                default:
                    XCTFail("Expected exactly two refresh joiners.")
                }
            case .forcedJoiner:
                XCTFail("Expected ordinary refresh joiners.")
            }
        }

        let creator = Task { @MainActor () -> Result<Void, any Swift.Error> in
            defer { creatorCompleted.fulfill() }
            do {
                try await manager.refreshAllFilesMetadata()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        await fulfillment(of: [scanStarted, creatorAdmitted], timeout: 1)
        let firstJoiner = Task { @MainActor () -> Result<Void, any Swift.Error> in
            defer { firstJoinerCompleted.fulfill() }
            do {
                try await manager.refreshAllFilesMetadata()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        await fulfillment(of: [firstJoinerAdmitted], timeout: 1)

        creator.cancel()
        firstJoiner.cancel()
        await fulfillment(of: [creatorCompleted, firstJoinerCompleted], timeout: 1)
        let lateJoiner = Task { @MainActor in
            try await manager.refreshAllFilesMetadata()
        }
        await fulfillment(of: [lateJoinerAdmitted], timeout: 1)
        XCTAssertEqual(manager.metadataScanCount, 1)

        await scanGate.release()
        try await lateJoiner.value
        for result in [await creator.value, await firstJoiner.value] {
            switch result {
            case .failure(is CancellationError):
                break
            case .failure(let error):
                XCTFail("Unexpected cancelled-waiter error: \(error)")
            case .success:
                XCTFail("Expected every cancelled waiter to finish with cancellation.")
            }
        }
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
    func testForcedRefreshRequesterCompletesAfterItsFollowUpScan() async throws {
        let rootURL = try temporaryDirectory()
        let manager = CountingReaderFileManager()
        manager.historyRealmConfigurationOverride = makeHistoryRealmConfiguration()
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: rootURL))
        let firstScanGate = ScanGate()
        let secondScanGate = ScanGate()
        let firstScanStarted = expectation(description: "first inventory scan started")
        let secondScanStarted = expectation(description: "forced follow-up inventory scan started")
        let ownerAdmitted = expectation(description: "refresh owner waiter admitted")
        let forceRequesterAdmitted = expectation(description: "forced refresh waiter admitted")
        let ownerCompleted = expectation(description: "refresh owner completed")
        let forceRequesterCompleted = expectation(description: "force requester completed")
        ownerCompleted.isInverted = true
        forceRequesterCompleted.isInverted = true
        var observedScanCount = 0
        manager.scanDidStart = {
            observedScanCount += 1
            switch observedScanCount {
            case 1:
                firstScanStarted.fulfill()
            case 2:
                secondScanStarted.fulfill()
            default:
                XCTFail("Expected exactly two metadata scans.")
            }
        }
        manager.scanBlocker = { scanNumber in
            switch scanNumber {
            case 1:
                await firstScanGate.wait()
            case 2:
                await secondScanGate.wait()
            default:
                break
            }
        }
        manager.refreshTaskWaiterDidAdmitForTesting = { role in
            switch role {
            case .creator:
                ownerAdmitted.fulfill()
            case .forcedJoiner:
                forceRequesterAdmitted.fulfill()
            case .joiner:
                XCTFail("Expected the second caller to request a forced follow-up.")
            }
        }

        let owner = Task { @MainActor in
            defer { ownerCompleted.fulfill() }
            try await manager.refreshAllFilesMetadata()
        }
        await fulfillment(of: [firstScanStarted, ownerAdmitted], timeout: 1)
        let forceRequester = Task { @MainActor in
            try await manager.refreshAllFilesMetadata(force: true)
            forceRequesterCompleted.fulfill()
        }
        await fulfillment(of: [forceRequesterAdmitted], timeout: 1)
        await firstScanGate.release()
        await fulfillment(of: [secondScanStarted], timeout: 1)
        await fulfillment(of: [ownerCompleted, forceRequesterCompleted], timeout: 0.1)
        ownerCompleted.isInverted = false
        forceRequesterCompleted.isInverted = false
        await secondScanGate.release()

        try await owner.value
        try await forceRequester.value
        XCTAssertEqual(manager.metadataScanCount, 2)
    }

    @MainActor
    func testCancellingForcedRefreshRequesterDoesNotRetractAdmittedFollowUp() async throws {
        let rootURL = try temporaryDirectory()
        let manager = CountingReaderFileManager()
        manager.scanDelayNanoseconds = 0
        manager.historyRealmConfigurationOverride = makeHistoryRealmConfiguration()
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: rootURL))
        let firstScanGate = ScanGate()
        let secondScanGate = ScanGate()
        let firstScanStarted = expectation(description: "first inventory scan started")
        let secondScanStarted = expectation(description: "admitted follow-up inventory scan started")
        let ownerAdmitted = expectation(description: "refresh owner waiter admitted")
        let forceRequesterAdmitted = expectation(description: "forced refresh waiter admitted")
        let forceRequesterCompleted = expectation(description: "cancelled force requester completed")
        let ownerCompleted = expectation(description: "refresh owner completed")
        ownerCompleted.isInverted = true
        var observedScanCount = 0
        manager.scanDidStart = {
            observedScanCount += 1
            switch observedScanCount {
            case 1:
                firstScanStarted.fulfill()
            case 2:
                secondScanStarted.fulfill()
            default:
                XCTFail("Expected exactly two metadata scans.")
            }
        }
        manager.scanBlocker = { scanNumber in
            switch scanNumber {
            case 1:
                await firstScanGate.wait()
            case 2:
                await secondScanGate.wait()
            default:
                break
            }
        }
        manager.refreshTaskWaiterDidAdmitForTesting = { role in
            switch role {
            case .creator:
                ownerAdmitted.fulfill()
            case .forcedJoiner:
                forceRequesterAdmitted.fulfill()
            case .joiner:
                XCTFail("Expected a forced refresh requester.")
            }
        }

        let owner = Task { @MainActor in
            defer { ownerCompleted.fulfill() }
            try await manager.refreshAllFilesMetadata()
        }
        await fulfillment(of: [firstScanStarted, ownerAdmitted], timeout: 1)
        let forceRequester = Task { @MainActor () -> Result<Void, any Swift.Error> in
            defer { forceRequesterCompleted.fulfill() }
            do {
                try await manager.refreshAllFilesMetadata(force: true)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        await fulfillment(of: [forceRequesterAdmitted], timeout: 1)
        forceRequester.cancel()
        await fulfillment(of: [forceRequesterCompleted], timeout: 1)
        switch await forceRequester.value {
        case .failure(is CancellationError):
            break
        case .failure(let error):
            XCTFail("Unexpected force-requester error: \(error)")
        case .success:
            XCTFail("Expected the cancelled force requester to stop awaiting the owner.")
        }

        await firstScanGate.release()
        await fulfillment(of: [secondScanStarted], timeout: 1)
        await fulfillment(of: [ownerCompleted], timeout: 0.1)
        ownerCompleted.isInverted = false
        await secondScanGate.release()

        try await owner.value
        XCTAssertEqual(manager.metadataScanCount, 2)
    }

    @MainActor
    func testForceDuringFollowUpRequiresThirdScanForEveryRequester() async throws {
        let rootURL = try temporaryDirectory()
        let manager = CountingReaderFileManager()
        manager.scanDelayNanoseconds = 0
        manager.historyRealmConfigurationOverride = makeHistoryRealmConfiguration()
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: rootURL))
        let firstScanGate = ScanGate()
        let secondScanGate = ScanGate()
        let thirdScanGate = ScanGate()
        let firstScanStarted = expectation(description: "first inventory scan started")
        let secondScanStarted = expectation(description: "first follow-up inventory scan started")
        let thirdScanStarted = expectation(description: "second follow-up inventory scan started")
        let ownerAdmitted = expectation(description: "refresh owner waiter admitted")
        let firstForceAdmitted = expectation(description: "first forced refresh waiter admitted")
        let secondForceAdmitted = expectation(description: "second forced refresh waiter admitted")
        let ownerCompleted = expectation(description: "refresh owner completed")
        let firstForceCompleted = expectation(description: "first force requester completed")
        let secondForceCompleted = expectation(description: "second force requester completed")
        ownerCompleted.isInverted = true
        firstForceCompleted.isInverted = true
        secondForceCompleted.isInverted = true
        var observedScanCount = 0
        var admittedForceCount = 0
        manager.scanDidStart = {
            observedScanCount += 1
            switch observedScanCount {
            case 1:
                firstScanStarted.fulfill()
            case 2:
                secondScanStarted.fulfill()
            case 3:
                thirdScanStarted.fulfill()
            default:
                XCTFail("Expected exactly three metadata scans.")
            }
        }
        manager.scanBlocker = { scanNumber in
            switch scanNumber {
            case 1:
                await firstScanGate.wait()
            case 2:
                await secondScanGate.wait()
            case 3:
                await thirdScanGate.wait()
            default:
                break
            }
        }
        manager.refreshTaskWaiterDidAdmitForTesting = { role in
            switch role {
            case .creator:
                ownerAdmitted.fulfill()
            case .forcedJoiner:
                admittedForceCount += 1
                switch admittedForceCount {
                case 1:
                    firstForceAdmitted.fulfill()
                case 2:
                    secondForceAdmitted.fulfill()
                default:
                    XCTFail("Expected exactly two forced refresh requesters.")
                }
            case .joiner:
                XCTFail("Expected only forced refresh requesters.")
            }
        }

        let owner = Task { @MainActor in
            defer { ownerCompleted.fulfill() }
            try await manager.refreshAllFilesMetadata()
        }
        await fulfillment(of: [firstScanStarted, ownerAdmitted], timeout: 1)
        let firstForceRequester = Task { @MainActor in
            defer { firstForceCompleted.fulfill() }
            try await manager.refreshAllFilesMetadata(force: true)
        }
        await fulfillment(of: [firstForceAdmitted], timeout: 1)
        await firstScanGate.release()
        await fulfillment(of: [secondScanStarted], timeout: 1)

        let secondForceRequester = Task { @MainActor in
            defer { secondForceCompleted.fulfill() }
            try await manager.refreshAllFilesMetadata(force: true)
        }
        await fulfillment(of: [secondForceAdmitted], timeout: 1)
        await secondScanGate.release()
        await fulfillment(of: [thirdScanStarted], timeout: 1)
        await fulfillment(
            of: [ownerCompleted, firstForceCompleted, secondForceCompleted],
            timeout: 0.1
        )
        ownerCompleted.isInverted = false
        firstForceCompleted.isInverted = false
        secondForceCompleted.isInverted = false
        await thirdScanGate.release()

        try await owner.value
        try await firstForceRequester.value
        try await secondForceRequester.value
        XCTAssertEqual(manager.metadataScanCount, 3)
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
    func testMissingFileDeletionUsesManagersCapturedRealmConfiguration() async throws {
        let rootURL = try temporaryDirectory()
        let realmRootURL = try temporaryDirectory()
        let managerConfiguration = makeHistoryRealmConfiguration(
            fileURL: realmRootURL.appendingPathComponent("manager.realm")
        )
        let globalConfiguration = makeHistoryRealmConfiguration(
            fileURL: realmRootURL.appendingPathComponent("global.realm")
        )
        let originalGlobalConfiguration = ReaderContentLoader.historyRealmConfiguration
        ReaderContentLoader.historyRealmConfiguration = globalConfiguration
        defer { ReaderContentLoader.historyRealmConfiguration = originalGlobalConfiguration }
        let manager = ReaderFileManager(defaultLocalRootURLProvider: { rootURL })
        manager.historyRealmConfigurationOverride = managerConfiguration
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: rootURL))
        let readerURL = try XCTUnwrap(
            URL(string: "reader-file://file/load/local/Books/missing.epub")
        )
        let managerPrimaryKey = try await Self.addContentFile(
            at: readerURL,
            to: managerConfiguration
        )
        let globalPrimaryKey = try await Self.addContentFile(
            at: readerURL,
            to: globalConfiguration
        )

        try await manager.delete(readerFileURL: readerURL)

        let managerContentIsDeleted = try await Self.contentFileIsDeleted(
            primaryKey: managerPrimaryKey,
            in: managerConfiguration
        )
        let globalContentIsDeleted = try await Self.contentFileIsDeleted(
            primaryKey: globalPrimaryKey,
            in: globalConfiguration
        )
        XCTAssertTrue(managerContentIsDeleted)
        XCTAssertFalse(globalContentIsDeleted)
    }

    @MainActor
    func testSuccessfulFileDeletionUsesManagersCapturedRealmConfiguration() async throws {
        let rootURL = try temporaryDirectory()
        let localURL = try writeFixture(relativePath: "Books/present.epub", under: rootURL)
        let realmRootURL = try temporaryDirectory()
        let managerConfiguration = makeHistoryRealmConfiguration(
            fileURL: realmRootURL.appendingPathComponent("manager.realm")
        )
        let globalConfiguration = makeHistoryRealmConfiguration(
            fileURL: realmRootURL.appendingPathComponent("global.realm")
        )
        let originalGlobalConfiguration = ReaderContentLoader.historyRealmConfiguration
        ReaderContentLoader.historyRealmConfiguration = globalConfiguration
        defer { ReaderContentLoader.historyRealmConfiguration = originalGlobalConfiguration }
        let manager = ReaderFileManager(defaultLocalRootURLProvider: { rootURL })
        manager.historyRealmConfigurationOverride = managerConfiguration
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: rootURL))
        let readerURL = try XCTUnwrap(
            URL(string: "reader-file://file/load/local/Books/present.epub")
        )
        let managerPrimaryKey = try await Self.addContentFile(
            at: readerURL,
            to: managerConfiguration
        )
        let globalPrimaryKey = try await Self.addContentFile(
            at: readerURL,
            to: globalConfiguration
        )

        try await manager.delete(readerFileURL: readerURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
        let managerContentIsDeleted = try await Self.contentFileIsDeleted(
            primaryKey: managerPrimaryKey,
            in: managerConfiguration
        )
        let globalContentIsDeleted = try await Self.contentFileIsDeleted(
            primaryKey: globalPrimaryKey,
            in: globalConfiguration
        )
        XCTAssertTrue(managerContentIsDeleted)
        XCTAssertFalse(globalContentIsDeleted)
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
