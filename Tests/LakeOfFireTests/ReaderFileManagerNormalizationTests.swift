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
    var scanResults = [ThreadSafeReference<ContentFile>]()

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
        return scanResults
    }
}

private final class ProcessorCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.withLock { value += 1 }
    }

    var count: Int {
        lock.withLock { value }
    }
}

final class ReaderFileManagerNormalizationTests: XCTestCase {
    private enum MetadataScanError: Swift.Error {
        case failed
    }

    @MainActor
    func testRefreshWithoutAnyDriveReportsUnavailableStorage() async throws {
        let manager = CountingReaderFileManager()
        manager.historyRealmConfigurationOverride = makeHistoryRealmConfiguration()

        do {
            try await manager.refreshAllFilesMetadata(force: true)
            XCTFail("Expected missing storage to reject the inventory.")
        } catch ReaderFileManagerError.driveMissing {
            XCTAssertNil(manager.files)
            XCTAssertEqual(manager.metadataScanCount, 0)
        }
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
            ReaderFilePostprocessingWorkItem.self,
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

    @RealmBackgroundActor
    private static func contentFileReference(
        primaryKey: String,
        in configuration: Realm.Configuration
    ) async throws -> ThreadSafeReference<ContentFile> {
        let realm = try await Realm(
            configuration: configuration,
            actor: RealmBackgroundActor.shared
        )
        let contentFile: ContentFile = try XCTUnwrap(
            realm.object(ofType: ContentFile.self, forPrimaryKey: primaryKey)
        )
        return ThreadSafeReference(to: contentFile)
    }

    @RealmBackgroundActor
    private static func removeContentFileFixture(
        primaryKey: String,
        in configuration: Realm.Configuration
    ) async throws {
        let realm = try await Realm(
            configuration: configuration,
            actor: RealmBackgroundActor.shared
        )
        try await realm.asyncWrite {
            if let contentFile = realm.object(ofType: ContentFile.self, forPrimaryKey: primaryKey) {
                realm.delete(contentFile)
            }
        }
    }

    @RealmBackgroundActor
    private static func addPostprocessingWorkItem(
        for primaryKey: String,
        in configuration: Realm.Configuration
    ) async throws -> String {
        let realm = try await Realm(
            configuration: configuration,
            actor: RealmBackgroundActor.shared
        )
        let workItem = ReaderFilePostprocessingWorkItem()
        workItem.processorIdentifier = "inventory-publication-test"
        workItem.processorVersion = 1
        workItem.contentFilePrimaryKey = primaryKey
        workItem.workItemIdentifier = ReaderFilePostprocessingWorkItem.makePortableWorkItemIdentifier(
            processorIdentifier: workItem.processorIdentifier,
            contentFilePrimaryKey: primaryKey
        )
        try await realm.asyncWrite { realm.add(workItem) }
        return workItem.workItemIdentifier
    }

    @RealmBackgroundActor
    private static func postprocessingWorkItemExists(
        _ identifier: String,
        in configuration: Realm.Configuration
    ) async throws -> Bool {
        let realm = try await Realm(
            configuration: configuration,
            actor: RealmBackgroundActor.shared
        )
        return realm.object(
            ofType: ReaderFilePostprocessingWorkItem.self,
            forPrimaryKey: identifier
        ) != nil
    }

    @RealmBackgroundActor
    private static func inventoryCounts(
        in configuration: Realm.Configuration
    ) async throws -> (activeFiles: Int, workItems: Int) {
        let realm = try await Realm(
            configuration: configuration,
            actor: RealmBackgroundActor.shared
        )
        try await realm.asyncRefresh()
        return (
            realm.objects(ContentFile.self).where { !$0.isDeleted }.count,
            realm.objects(ReaderFilePostprocessingWorkItem.self).count
        )
    }

    @MainActor
    func testTwoDriveDiscoveryFailureDoesNotAdmitFirstDriveUntilRetry() async throws {
        let localRootURL = try temporaryDirectory()
        let cloudRootURL = try temporaryDirectory()
        _ = try writeFixture(relativePath: "Books/new-local.epub", under: localRootURL)
        _ = try writeFixture(relativePath: "Books/new-cloud.epub", under: cloudRootURL)
        let configuration = makeHistoryRealmConfiguration()
        let oldPrimaryKey = try await Self.addContentFile(
            at: XCTUnwrap(URL(string: "reader-file://file/load/local/Books/old.epub")),
            to: configuration
        )
        let oldWorkItem = try await Self.addPostprocessingWorkItem(
            for: oldPrimaryKey,
            in: configuration
        )
        let manager = ReaderFileManager()
        let processorCalls = ProcessorCallCounter()
        let previousVisibleFile = ContentFile()
        previousVisibleFile.url = try XCTUnwrap(
            URL(string: "reader-file://file/load/local/Books/old.epub")
        )
        manager.files = [previousVisibleFile]
        manager.registerFileProcessorBundle(
            identifier: "two-drive-atomic-inventory-\(UUID().uuidString)",
            fileProcessorVersion: 1,
            destinationProcessor: { _ in nil },
            readerFileURLProcessor: { _, _ in nil },
            contextualFileProcessor: { context in
                for contentFile in context.contentFiles {
                    processorCalls.increment()
                    context.deferPostprocessing(for: contentFile)
                }
            }
        )
        manager.historyRealmConfigurationOverride = configuration
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: localRootURL))
        manager.cloudDrive = try await CloudDrive(storage: .localDirectory(rootURL: cloudRootURL))
        manager.refreshInventoryDriveWillScanForTesting = { location in
            if location == "icloud" { throw MetadataScanError.failed }
        }

        do {
            try await manager.refreshAllFilesMetadata(force: true)
            XCTFail("Expected the second drive discovery to fail.")
        } catch MetadataScanError.failed {
            XCTAssertEqual(manager.files?.map(\.url), [previousVisibleFile.url])
            let counts = try await Self.inventoryCounts(in: configuration)
            XCTAssertEqual(counts.activeFiles, 1)
            XCTAssertEqual(counts.workItems, 1)
            let oldFileDeleted = try await Self.contentFileIsDeleted(
                primaryKey: oldPrimaryKey,
                in: configuration
            )
            let oldWorkItemExists = try await Self.postprocessingWorkItemExists(
                oldWorkItem,
                in: configuration
            )
            XCTAssertFalse(oldFileDeleted)
            XCTAssertTrue(oldWorkItemExists)
            XCTAssertEqual(processorCalls.count, 0)
        }

        manager.refreshInventoryDriveWillScanForTesting = nil
        try await manager.refreshAllFilesMetadata(force: true)
        let counts = try await Self.inventoryCounts(in: configuration)
        XCTAssertEqual(counts.activeFiles, 2)
        XCTAssertEqual(counts.workItems, 2)
        let oldFileDeleted = try await Self.contentFileIsDeleted(
            primaryKey: oldPrimaryKey,
            in: configuration
        )
        let oldWorkItemExists = try await Self.postprocessingWorkItemExists(
            oldWorkItem,
            in: configuration
        )
        XCTAssertTrue(oldFileDeleted)
        XCTAssertFalse(oldWorkItemExists)
        XCTAssertEqual(manager.files?.count, 2)
        XCTAssertEqual(processorCalls.count, 2)
    }

    @MainActor
    func testDriveReplacementDuringFinalRefreshDoesNotPublishOldInventory() async throws {
        try await assertReplacementDuringFinalRefresh(replacesConfiguration: false)
    }

    @MainActor
    func testConfigurationReplacementDuringFinalRefreshDoesNotPublishOldInventory() async throws {
        try await assertReplacementDuringFinalRefresh(replacesConfiguration: true)
    }

    @MainActor
    private func assertReplacementDuringFinalRefresh(replacesConfiguration: Bool) async throws {
        let firstRootURL = try temporaryDirectory()
        let secondRootURL = try temporaryDirectory()
        _ = try writeFixture(relativePath: "Books/first.epub", under: firstRootURL)
        _ = try writeFixture(relativePath: "Books/second.epub", under: secondRootURL)
        let firstConfiguration = makeHistoryRealmConfiguration()
        let secondConfiguration = replacesConfiguration ? makeHistoryRealmConfiguration() : firstConfiguration
        let manager = ReaderFileManager()
        manager.historyRealmConfigurationOverride = firstConfiguration
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: firstRootURL))
        try await manager.refreshAllFilesMetadata(force: true)
        let previousURLs = try XCTUnwrap(manager.files).map(\.url)
        XCTAssertEqual(previousURLs.count, 1)

        let finalRefreshGate = ScanGate()
        let finalRefreshStarted = expectation(description: "final inventory Realm refresh reached")
        manager.refreshFinalInventoryWillRefreshForTesting = {
            finalRefreshStarted.fulfill()
            await finalRefreshGate.wait()
        }
        let refresh = Task { @MainActor in
            try await manager.refreshAllFilesMetadata(force: true)
        }
        await fulfillment(of: [finalRefreshStarted], timeout: 5)
        if replacesConfiguration {
            manager.historyRealmConfigurationOverride = secondConfiguration
        } else {
            manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: secondRootURL))
        }
        await finalRefreshGate.release()

        do {
            try await refresh.value
            XCTFail("Expected replacement during final refresh to reject the obsolete inventory.")
        } catch ReaderFileManagerError.refreshSuperseded {
            XCTAssertEqual(manager.files?.map(\.url), previousURLs)
        }

        manager.refreshFinalInventoryWillRefreshForTesting = nil
        try await manager.refreshAllFilesMetadata(force: true)
        let currentURLs = try XCTUnwrap(manager.files).map(\.url)
        XCTAssertEqual(currentURLs.count, 1)
        XCTAssertEqual(currentURLs.first?.lastPathComponent, replacesConfiguration ? "first.epub" : "second.epub")
        if replacesConfiguration {
            XCTAssertEqual(currentURLs, previousURLs)
        } else {
            XCTAssertNotEqual(currentURLs, previousURLs)
        }
        let counts = try await Self.inventoryCounts(in: secondConfiguration)
        XCTAssertEqual(counts.activeFiles, 1)
        if replacesConfiguration {
            let oldCounts = try await Self.inventoryCounts(in: firstConfiguration)
            XCTAssertEqual(oldCounts.activeFiles, 1)
        }
    }

    @MainActor
    func testFailedOrphanCleanupDoesNotPublishIncompleteInventory() async throws {
        let rootURL = try temporaryDirectory()
        let configuration = makeHistoryRealmConfiguration()
        let orphanPrimaryKey = try await Self.addContentFile(
            at: XCTUnwrap(URL(string: "reader-file://file/load/local/Books/missing-reader-content.epub")),
            to: configuration
        )
        let workItemIdentifier = try await Self.addPostprocessingWorkItem(
            for: orphanPrimaryKey,
            in: configuration
        )
        let manager = CountingReaderFileManager()
        manager.scanDelayNanoseconds = 0
        manager.historyRealmConfigurationOverride = configuration
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: rootURL))
        manager.refreshOrphanCleanupWillBeginForTesting = {
            throw MetadataScanError.failed
        }

        do {
            try await manager.refreshAllFilesMetadata()
            XCTFail("Expected orphan cleanup to fail before inventory publication.")
        } catch MetadataScanError.failed {
            XCTAssertNil(manager.files)
            let orphanWasDeleted = try await Self.contentFileIsDeleted(
                primaryKey: orphanPrimaryKey,
                in: configuration
            )
            XCTAssertFalse(orphanWasDeleted)
            let workItemStillExists = try await Self.postprocessingWorkItemExists(
                workItemIdentifier,
                in: configuration
            )
            XCTAssertTrue(workItemStillExists)
        }

        manager.refreshOrphanCleanupWillBeginForTesting = nil
        try await manager.refreshAllFilesMetadata(force: true)
        XCTAssertEqual(manager.files?.count, 0)
        let orphanWasDeleted = try await Self.contentFileIsDeleted(
            primaryKey: orphanPrimaryKey,
            in: configuration
        )
        XCTAssertTrue(orphanWasDeleted)
        let workItemStillExists = try await Self.postprocessingWorkItemExists(
            workItemIdentifier,
            in: configuration
        )
        XCTAssertFalse(workItemStillExists)
    }

    @MainActor
    func testConfigurationReplacementBeforeOrphanWriteRetainsInventoryAndWorkItem() async throws {
        let rootURL = try temporaryDirectory()
        let firstConfiguration = makeHistoryRealmConfiguration()
        let secondConfiguration = makeHistoryRealmConfiguration()
        let orphanPrimaryKey = try await Self.addContentFile(
            at: XCTUnwrap(URL(string: "reader-file://file/load/local/Books/orphaned.epub")),
            to: firstConfiguration
        )
        let workItemIdentifier = try await Self.addPostprocessingWorkItem(
            for: orphanPrimaryKey,
            in: firstConfiguration
        )
        let manager = CountingReaderFileManager()
        manager.scanDelayNanoseconds = 0
        manager.historyRealmConfigurationOverride = firstConfiguration
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: rootURL))
        manager.refreshOrphanCleanupWillBeginForTesting = {
            manager.historyRealmConfigurationOverride = secondConfiguration
        }

        do {
            try await manager.refreshAllFilesMetadata()
            XCTFail("Expected the replaced inventory to be rejected.")
        } catch ReaderFileManagerError.refreshSuperseded {
            XCTAssertNil(manager.files)
            let orphanWasDeleted = try await Self.contentFileIsDeleted(
                primaryKey: orphanPrimaryKey,
                in: firstConfiguration
            )
            XCTAssertFalse(orphanWasDeleted)
            let workItemStillExists = try await Self.postprocessingWorkItemExists(
                workItemIdentifier,
                in: firstConfiguration
            )
            XCTAssertTrue(workItemStillExists)
        }
    }

    @MainActor
    func testSameRootDriveReplacementBeforeOrphanWriteRetainsInventoryAndWorkItem() async throws {
        let rootURL = try temporaryDirectory()
        let configuration = makeHistoryRealmConfiguration()
        let orphanPrimaryKey = try await Self.addContentFile(
            at: XCTUnwrap(URL(string: "reader-file://file/load/local/Books/orphaned.epub")),
            to: configuration
        )
        let workItemIdentifier = try await Self.addPostprocessingWorkItem(
            for: orphanPrimaryKey,
            in: configuration
        )
        let manager = CountingReaderFileManager()
        manager.scanDelayNanoseconds = 0
        manager.historyRealmConfigurationOverride = configuration
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: rootURL))
        manager.refreshOrphanCleanupWillBeginForTesting = {
            manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: rootURL))
        }

        do {
            try await manager.refreshAllFilesMetadata()
            XCTFail("Expected the replaced drive inventory to be rejected.")
        } catch ReaderFileManagerError.refreshSuperseded {
            XCTAssertNil(manager.files)
            let orphanWasDeleted = try await Self.contentFileIsDeleted(
                primaryKey: orphanPrimaryKey,
                in: configuration
            )
            XCTAssertFalse(orphanWasDeleted)
            let workItemStillExists = try await Self.postprocessingWorkItemExists(
                workItemIdentifier,
                in: configuration
            )
            XCTAssertTrue(workItemStillExists)
        }
    }

    @MainActor
    func testDisappearingResolvedRowDoesNotPublishPartialInventory() async throws {
        let rootURL = try temporaryDirectory()
        let realmRootURL = try temporaryDirectory()
        let configuration = makeHistoryRealmConfiguration(
            fileURL: realmRootURL.appendingPathComponent("inventory.realm")
        )
        let primaryKey = try await Self.addContentFile(
            at: rootURL.appendingPathComponent("transient.epub"),
            to: configuration
        )
        let reference = try await Self.contentFileReference(
            primaryKey: primaryKey,
            in: configuration
        )
        let manager = CountingReaderFileManager()
        manager.scanDelayNanoseconds = 0
        manager.scanResults = [reference]
        manager.historyRealmConfigurationOverride = configuration
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: rootURL))
        let scanGate = ScanGate()
        let scanStarted = expectation(description: "candidate inventory scan started")
        manager.scanDidStart = { scanStarted.fulfill() }
        manager.scanBlocker = { _ in await scanGate.wait() }

        let refresh = Task { @MainActor in
            try await manager.refreshAllFilesMetadata()
        }
        await fulfillment(of: [scanStarted], timeout: 1)
        try await Self.removeContentFileFixture(
            primaryKey: primaryKey,
            in: configuration
        )
        await scanGate.release()

        do {
            try await refresh.value
            XCTFail("Expected a missing resolved row to reject the inventory.")
        } catch ReaderFileManagerError.incompleteFileInventory {
            XCTAssertNil(manager.files)
        }
    }

    @MainActor
    func testConfigurationReplacementBetweenDrivesStopsObsoleteSecondScan() async throws {
        let localRootURL = try temporaryDirectory()
        let cloudRootURL = try temporaryDirectory()
        let manager = CountingReaderFileManager()
        manager.scanDelayNanoseconds = 0
        manager.historyRealmConfigurationOverride = makeHistoryRealmConfiguration()
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: localRootURL))
        manager.cloudDrive = try await CloudDrive(storage: .localDirectory(rootURL: cloudRootURL))
        let firstScanGate = ScanGate()
        let firstScanStarted = expectation(description: "first drive scan started")
        manager.scanDidStart = { firstScanStarted.fulfill() }
        manager.scanBlocker = { scanNumber in
            if scanNumber == 1 { await firstScanGate.wait() }
        }

        let refresh = Task { @MainActor in
            try await manager.refreshAllFilesMetadata()
        }
        await fulfillment(of: [firstScanStarted], timeout: 1)
        manager.historyRealmConfigurationOverride = makeHistoryRealmConfiguration()
        await firstScanGate.release()

        do {
            try await refresh.value
            XCTFail("Expected the old configuration to stop before scanning drive two.")
        } catch ReaderFileManagerError.refreshSuperseded {
            XCTAssertEqual(manager.metadataScanCount, 1)
            XCTAssertNil(manager.files)
        }
    }

    @RealmBackgroundActor
    private static func importedMetadata(in configuration: Realm.Configuration) async throws -> [(String, URL?)] {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
        try await realm.asyncRefresh()
        return realm.objects(ContentFile.self).where { !$0.isDeleted }.map { ($0.title, $0.sourceDownloadURL) }
    }

    func testImportManifestClassificationUsesFilesystemType() throws {
        let root = try temporaryDirectory()
        let directory = root.appendingPathComponent("unregistered-package.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let regularFile = try writeFixture(relativePath: "archive.epub", under: root)
        XCTAssertTrue(try directory.readerImportRequiresManifest())
        XCTAssertFalse(try regularFile.readerImportRequiresManifest())
    }

    func testImportManifestClassificationRejectsRootSymlinkAndMissingSource() throws {
        let root = try temporaryDirectory()
        let directory = root.appendingPathComponent("package")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("linked-package")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        XCTAssertThrowsError(try link.readerImportRequiresManifest()) { error in
            guard let manifestError = error as? ReaderImportPackageManifestError,
                  case .unsupportedEntry = manifestError else {
                return XCTFail("Expected unsupported root symlink, got \(error)")
            }
        }
        XCTAssertThrowsError(try root.appendingPathComponent("missing").readerImportRequiresManifest())
    }

    func testPackageManifestDigestIsDeterministicAndDoesNotFollowEscapingSymlink() throws {
        let first = try temporaryDirectory()
        let second = try temporaryDirectory()
        let outsideRoot = try temporaryDirectory()
        let outside = try writeFixture(relativePath: "outside.txt", under: outsideRoot)
        for root in [first, second] {
            _ = try writeFixture(relativePath: "b.txt", under: root)
            _ = try writeFixture(relativePath: "a.txt", under: root)
        }
        try FileManager.default.createSymbolicLink(
            at: first.appendingPathComponent("outside-link.txt"),
            withDestinationURL: outside
        )
        let digest = try first.packageManifestDigest()
        XCTAssertEqual(digest, try first.packageManifestDigest())
        XCTAssertNotEqual(digest, try second.packageManifestDigest())
        try Data("changed outside bytes".utf8).write(to: outside)
        XCTAssertEqual(digest, try first.packageManifestDigest())
    }

    func testPackageManifestIncludesRelativePathsAndEmptyDirectories() throws {
        let first = try temporaryDirectory()
        let second = try temporaryDirectory()
        _ = try writeFixture(relativePath: "first.txt", under: first)
        _ = try writeFixture(relativePath: "renamed.txt", under: second)
        XCTAssertNotEqual(try first.packageManifestDigest(), try second.packageManifestDigest())
        let original = try first.packageManifestDigest()
        try FileManager.default.createDirectory(
            at: first.appendingPathComponent("empty"),
            withIntermediateDirectories: true
        )
        XCTAssertNotEqual(original, try first.packageManifestDigest())
    }

    func testPackageManifestRejectsEntryByteAndDepthBudgetOverflow() throws {
        let root = try temporaryDirectory()
        _ = try writeFixture(relativePath: "Nested/book.txt", under: root)
        for limits in [
            ReaderImportPackageManifestLimits(maximumEntries: 1, maximumBytes: 1024, maximumDepth: 10),
            ReaderImportPackageManifestLimits(maximumEntries: 10, maximumBytes: 1, maximumDepth: 10),
            ReaderImportPackageManifestLimits(maximumEntries: 10, maximumBytes: 1024, maximumDepth: 0)
        ] {
            XCTAssertThrowsError(try root.packageManifestDigest(limits: limits)) { error in
                guard let manifestError = error as? ReaderImportPackageManifestError,
                      case .budgetExceeded = manifestError else {
                    return XCTFail("Expected a typed package manifest budget rejection.")
                }
            }
        }
    }

    func testPackageManifestDoesNotConflateFileBoundaries() throws {
        let first = try temporaryDirectory()
        let second = try temporaryDirectory()
        for (root, firstBytes, secondBytes) in [(first, "ab", "c"), (second, "a", "bc")] {
            try Data(firstBytes.utf8).write(to: root.appendingPathComponent("a.txt"))
            try Data(secondBytes.utf8).write(to: root.appendingPathComponent("b.txt"))
        }
        XCTAssertNotEqual(try first.packageManifestDigest(), try second.packageManifestDigest())
    }

    @MainActor
    private func collisionImportManager(libraryRootURL: URL) async throws -> ReaderFileManager {
        let manager = ReaderFileManager()
        manager.historyRealmConfigurationOverride = makeHistoryRealmConfiguration()
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: libraryRootURL))
        manager.registerFileProcessorBundle(
            identifier: "collision-import",
            destinationProcessor: { _ in RootRelativePath(path: "Books") },
            readerFileURLProcessor: { _, _ in nil },
            contextualFileProcessor: { _ in }
        )
        return manager
    }

    @MainActor
    func testFreeDestinationImportInstallsAndIndexesSourceBytes() async throws {
        let sourceRootURL = try temporaryDirectory()
        let libraryRootURL = try temporaryDirectory()
        let sourceURL = try writeFixture(relativePath: "book.txt", under: sourceRootURL)
        let expectedBytes = Data("verified new import".utf8)
        try expectedBytes.write(to: sourceURL)
        let manager = try await collisionImportManager(libraryRootURL: libraryRootURL)
        let result = try await manager.importFile(fileURL: sourceURL, fromDownloadURL: nil)
        XCTAssertEqual(result?.lastPathComponent, "book.txt")
        let installedURL = libraryRootURL.appendingPathComponent("Books/book.txt")
        XCTAssertEqual(try Data(contentsOf: installedURL), expectedBytes)
        XCTAssertEqual(manager.files?.count, 1)
    }

    @MainActor
    func testSameURLImportValidatesAndReusesInstalledBytes() async throws {
        let libraryRootURL = try temporaryDirectory()
        let sourceURL = try writeFixture(relativePath: "Books/book.txt", under: libraryRootURL)
        let expectedBytes = try Data(contentsOf: sourceURL)
        let manager = try await collisionImportManager(libraryRootURL: libraryRootURL)
        let result = try await manager.importFile(fileURL: sourceURL, fromDownloadURL: nil)
        XCTAssertEqual(result?.lastPathComponent, "book.txt")
        XCTAssertEqual(try Data(contentsOf: sourceURL), expectedBytes)
        XCTAssertEqual(manager.files?.count, 1)
    }

    @MainActor
    func testIdenticalImportAtDifferentURLReusesExistingDestination() async throws {
        let sourceRootURL = try temporaryDirectory()
        let libraryRootURL = try temporaryDirectory()
        let sourceURL = try writeFixture(relativePath: "book.txt", under: sourceRootURL)
        let destination = try writeFixture(relativePath: "Books/book.txt", under: libraryRootURL)
        let manager = try await collisionImportManager(libraryRootURL: libraryRootURL)
        let importResult = try await manager.importFile(fileURL: sourceURL, fromDownloadURL: nil)
        let readerURL = try XCTUnwrap(importResult)
        XCTAssertEqual(readerURL.lastPathComponent, "book.txt")
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: sourceURL))
        XCTAssertEqual(manager.files?.count, 1)
    }

    @MainActor
    func testRepeatedCollisionImportReusesPreviouslyRenamedFile() async throws {
        let sourceRootURL = try temporaryDirectory()
        let libraryRootURL = try temporaryDirectory()
        let sourceURL = try writeFixture(relativePath: "book.txt", under: sourceRootURL)
        let original = try writeFixture(relativePath: "Books/book.txt", under: libraryRootURL)
        try Data("original user file".utf8).write(to: original)
        let manager = try await collisionImportManager(libraryRootURL: libraryRootURL)
        let first = try await manager.importFile(fileURL: sourceURL, fromDownloadURL: nil)
        let second = try await manager.importFile(fileURL: sourceURL, fromDownloadURL: nil)
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first?.lastPathComponent, "book.txt")
        XCTAssertEqual(try Data(contentsOf: original), Data("original user file".utf8))
        XCTAssertEqual(manager.files?.count, 2)
    }

    @MainActor
    func testOccupiedImportCollisionNameIsPreservedAndNextCandidateSelected() async throws {
        let sourceRootURL = try temporaryDirectory()
        let libraryRootURL = try temporaryDirectory()
        let sourceURL = try writeFixture(relativePath: "book.txt", under: sourceRootURL)
        let original = try writeFixture(relativePath: "Books/book.txt", under: libraryRootURL)
        try Data("original".utf8).write(to: original)
        let manager = try await collisionImportManager(libraryRootURL: libraryRootURL)
        let firstResult = try await manager.importFile(fileURL: sourceURL, fromDownloadURL: nil)
        let first = try XCTUnwrap(firstResult)
        let occupiedURL = libraryRootURL.appendingPathComponent("Books").appendingPathComponent(first.lastPathComponent)
        try Data("edited renamed file".utf8).write(to: occupiedURL)
        let nextResult = try await manager.importFile(fileURL: sourceURL, fromDownloadURL: nil)
        let next = try XCTUnwrap(nextResult)
        XCTAssertNotEqual(first, next)
        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: occupiedURL), Data("edited renamed file".utf8))
        let nextURL = libraryRootURL.appendingPathComponent("Books").appendingPathComponent(next.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: nextURL), try Data(contentsOf: sourceURL))
        XCTAssertEqual(manager.files?.count, 3)
    }

    @MainActor
    func testMissingImportSourceDoesNotReplaceExistingFile() async throws {
        let sourceRootURL = try temporaryDirectory()
        let libraryRootURL = try temporaryDirectory()
        let original = try writeFixture(relativePath: "Books/missing.txt", under: libraryRootURL)
        let originalBytes = try Data(contentsOf: original)
        let manager = try await collisionImportManager(libraryRootURL: libraryRootURL)
        do {
            _ = try await manager.importFile(
                fileURL: sourceRootURL.appendingPathComponent("missing.txt"),
                fromDownloadURL: nil
            )
            XCTFail("Expected missing source to propagate its I/O failure.")
        } catch {
            XCTAssertEqual(try Data(contentsOf: original), originalBytes)
            XCTAssertNil(manager.files)
        }
    }

    func testHistoryConfigurationAuthorityRejectsRestoredOldGeneration() throws {
        let firstConfiguration = makeHistoryRealmConfiguration()
        let secondConfiguration = makeHistoryRealmConfiguration()
        let authority = ReaderHistoryRealmConfigurationAuthority(configuration: firstConfiguration)
        let oldReceipt = authority.receipt()
        authority.configuration = secondConfiguration
        authority.configuration = firstConfiguration
        var didMutate = false
        let didApply = try authority.applyIfCurrent(oldReceipt) {
            didMutate = true
            return true
        }
        XCTAssertFalse(didApply)
        XCTAssertFalse(didMutate)
        XCTAssertEqual(authority.configuration.inMemoryIdentifier, firstConfiguration.inMemoryIdentifier)
        let currentReceipt = authority.receipt()
        XCTAssertTrue(try authority.applyIfCurrent(currentReceipt) {
            // Processor mutations may read configuration synchronously.
            authority.configuration.inMemoryIdentifier == firstConfiguration.inMemoryIdentifier
        })
    }

    func testHistoryConfigurationAuthorityRejectsReentrantReplacement() throws {
        let authority = ReaderHistoryRealmConfigurationAuthority(configuration: makeHistoryRealmConfiguration())
        let receipt = authority.receipt()
        XCTAssertThrowsError(try authority.applyIfCurrent(receipt) {
            authority.configuration = self.makeHistoryRealmConfiguration()
            return true
        }) { error in
            guard let managerError = error as? ReaderFileManagerError,
                  case .refreshSuperseded = managerError else {
                return XCTFail("Expected replacement inside a mutation to reject commit admission.")
            }
        }
    }

    @MainActor
    func testDefaultRealmReplacementRejectsInventoryProcessorWriteAndRetainsWork() async throws {
        let previousDefault = ReaderContentLoader.historyRealmConfiguration
        defer { ReaderContentLoader.historyRealmConfiguration = previousDefault }
        let firstConfiguration = makeHistoryRealmConfiguration()
        let secondConfiguration = makeHistoryRealmConfiguration()
        ReaderContentLoader.historyRealmConfiguration = firstConfiguration
        let libraryRootURL = try temporaryDirectory()
        _ = try writeFixture(relativePath: "Books/default.epub", under: libraryRootURL)
        let manager = ReaderFileManager()
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: libraryRootURL))
        let processorGate = ScanGate()
        let processorStarted = expectation(description: "default-Realm inventory processor suspended")
        let appliedWrites = ProcessorCallCounter()
        manager.registerFileProcessorBundle(
            identifier: "default-realm-replacement",
            fileProcessorVersion: 1,
            destinationProcessor: { _ in nil },
            readerFileURLProcessor: { _, _ in nil },
            contextualFileProcessor: { context in
                processorStarted.fulfill()
                await processorGate.wait()
                let didApply = try await context.performCurrentWrite { _, contentFile in
                    contentFile.title = "Obsolete default processor"
                    contentFile.refreshChangeMetadata(explicitlyModified: true)
                }
                if didApply { appliedWrites.increment() }
            }
        )
        let refresh = Task { @MainActor in try await manager.refreshAllFilesMetadata(force: true) }
        await fulfillment(of: [processorStarted], timeout: 5)
        ReaderContentLoader.historyRealmConfiguration = secondConfiguration
        await processorGate.release()
        do {
            try await refresh.value
            XCTFail("Expected default-Realm replacement to reject the old inventory.")
        } catch ReaderFileManagerError.refreshSuperseded {}
        XCTAssertEqual(appliedWrites.count, 0)
        XCTAssertNil(manager.files)
        let oldMetadata = try await Self.importedMetadata(in: firstConfiguration)
        XCTAssertEqual(oldMetadata.map { $0.0 }, ["default"])
        let oldCounts = try await Self.inventoryCounts(in: firstConfiguration)
        XCTAssertEqual(oldCounts.workItems, 1)
        let newCounts = try await Self.inventoryCounts(in: secondConfiguration)
        XCTAssertEqual(newCounts.activeFiles, 0)
        manager.registerFileProcessorBundle(
            identifier: "default-realm-replacement",
            fileProcessorVersion: 1,
            destinationProcessor: { _ in nil },
            readerFileURLProcessor: { _, _ in nil },
            contextualFileProcessor: { context in
                try await context.performCurrentWrite { _, contentFile in
                    contentFile.title = "Current default processor"
                    contentFile.refreshChangeMetadata(explicitlyModified: true)
                }
            }
        )
        try await manager.refreshAllFilesMetadata(force: true)
        let currentMetadata = try await Self.importedMetadata(in: secondConfiguration)
        XCTAssertEqual(currentMetadata.map { $0.0 }, ["Current default processor"])
        let retainedCounts = try await Self.inventoryCounts(in: firstConfiguration)
        XCTAssertEqual(retainedCounts.workItems, 1)
        let currentCounts = try await Self.inventoryCounts(in: secondConfiguration)
        XCTAssertEqual(currentCounts.workItems, 0)
    }

    @MainActor
    func testStandaloneTargetedDiscoveryRejectsSameRootDriveReplacementBeforeAdmission() async throws {
        try await assertStandaloneTargetedDiscoveryReplacement(replacesConfiguration: false)
    }

    @MainActor
    func testStandaloneTargetedDiscoveryRejectsConfigurationReplacementBeforeAdmission() async throws {
        try await assertStandaloneTargetedDiscoveryReplacement(replacesConfiguration: true)
    }

    @MainActor
    private func assertStandaloneTargetedDiscoveryReplacement(replacesConfiguration: Bool) async throws {
        let libraryRootURL = try temporaryDirectory()
        _ = try writeFixture(relativePath: "Books/Nested/targeted.epub", under: libraryRootURL)
        let firstConfiguration = makeHistoryRealmConfiguration()
        let secondConfiguration = makeHistoryRealmConfiguration()
        let manager = ReaderFileManager()
        manager.historyRealmConfigurationOverride = firstConfiguration
        let originalDrive = try await CloudDrive(storage: .localDirectory(rootURL: libraryRootURL))
        manager.localDrive = originalDrive
        let mappingGate = ScanGate()
        let mappingStarted = expectation(description: "standalone recursive targeted discovery suspended")
        let processorCalls = ProcessorCallCounter()
        let processorIdentifier = "standalone-targeted-replacement"
        manager.registerFileProcessorBundle(
            identifier: processorIdentifier,
            fileProcessorVersion: 1,
            destinationProcessor: { _ in nil },
            readerFileURLProcessor: { _, _ in
                mappingStarted.fulfill()
                await mappingGate.wait()
                return nil
            },
            contextualFileProcessor: { _ in processorCalls.increment() }
        )
        let scan = Task { @MainActor in
            try await manager.refreshFilesMetadata(
                drive: originalDrive,
                relativePath: RootRelativePath(path: "Books"),
                realmConfiguration: firstConfiguration
            )
        }
        await fulfillment(of: [mappingStarted], timeout: 5)
        if replacesConfiguration {
            manager.historyRealmConfigurationOverride = secondConfiguration
        } else {
            manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: libraryRootURL))
        }
        await mappingGate.release()
        do {
            _ = try await scan.value
            XCTFail("Expected obsolete recursive discovery to reject admission.")
        } catch ReaderFileManagerError.refreshSuperseded {}
        XCTAssertEqual(processorCalls.count, 0)
        XCTAssertNil(manager.files)
        for configuration in [firstConfiguration, secondConfiguration] {
            let counts = try await Self.inventoryCounts(in: configuration)
            XCTAssertEqual(counts.activeFiles, 0)
            XCTAssertEqual(counts.workItems, 0)
        }
        manager.registerFileProcessorBundle(
            identifier: processorIdentifier,
            fileProcessorVersion: 1,
            destinationProcessor: { _ in nil },
            readerFileURLProcessor: { _, _ in nil },
            contextualFileProcessor: { context in
                processorCalls.increment()
                for contentFile in context.contentFiles { context.deferPostprocessing(for: contentFile) }
            }
        )
        let currentConfiguration = replacesConfiguration ? secondConfiguration : firstConfiguration
        let references = try await manager.refreshFilesMetadata(
            drive: XCTUnwrap(manager.localDrive),
            relativePath: RootRelativePath(path: "Books"),
            realmConfiguration: currentConfiguration
        )
        XCTAssertEqual(references?.count, 1)
        let counts = try await Self.inventoryCounts(in: currentConfiguration)
        XCTAssertEqual(counts.activeFiles, 1)
        XCTAssertEqual(counts.workItems, 1)
        XCTAssertEqual(processorCalls.count, 1)
    }

    @MainActor
    func testFullInventoryDriveReplacementRejectsProcessorWriteAndRetainsWork() async throws {
        try await assertFullInventoryProcessorReplacement(replacesConfiguration: false)
    }

    @MainActor
    func testFullInventoryConfigurationReplacementRejectsProcessorWriteAndRetainsWork() async throws {
        try await assertFullInventoryProcessorReplacement(replacesConfiguration: true)
    }

    @MainActor
    private func assertFullInventoryProcessorReplacement(replacesConfiguration: Bool) async throws {
        let libraryRootURL = try temporaryDirectory()
        _ = try writeFixture(relativePath: "Books/inventory.epub", under: libraryRootURL)
        let firstConfiguration = makeHistoryRealmConfiguration()
        let secondConfiguration = makeHistoryRealmConfiguration()
        let manager = ReaderFileManager()
        manager.historyRealmConfigurationOverride = firstConfiguration
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: libraryRootURL))
        let processorGate = ScanGate()
        let processorStarted = expectation(description: "full inventory processor suspended")
        let appliedWrites = ProcessorCallCounter()
        manager.registerFileProcessorBundle(
            identifier: "full-inventory-replacement",
            fileProcessorVersion: 1,
            destinationProcessor: { _ in nil },
            readerFileURLProcessor: { _, _ in nil },
            contextualFileProcessor: { context in
                processorStarted.fulfill()
                await processorGate.wait()
                let didApply = try await context.performCurrentWrite { _, contentFile in
                    contentFile.title = "Obsolete inventory processor"
                    contentFile.refreshChangeMetadata(explicitlyModified: true)
                }
                if didApply { appliedWrites.increment() }
            }
        )
        let refresh = Task { @MainActor in
            try await manager.refreshAllFilesMetadata(force: true)
        }
        await fulfillment(of: [processorStarted], timeout: 5)
        if replacesConfiguration {
            manager.historyRealmConfigurationOverride = secondConfiguration
        } else {
            manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: libraryRootURL))
        }
        await processorGate.release()
        do {
            try await refresh.value
            XCTFail("Expected the obsolete inventory processor to reject publication.")
        } catch ReaderFileManagerError.refreshSuperseded {}
        XCTAssertEqual(appliedWrites.count, 0)
        XCTAssertNil(manager.files)
        let oldMetadata = try await Self.importedMetadata(in: firstConfiguration)
        XCTAssertEqual(oldMetadata.map { $0.0 }, ["inventory"])
        let oldCounts = try await Self.inventoryCounts(in: firstConfiguration)
        XCTAssertEqual(oldCounts.activeFiles, 1)
        XCTAssertEqual(oldCounts.workItems, 1)
        let replacementCounts = try await Self.inventoryCounts(in: secondConfiguration)
        XCTAssertEqual(replacementCounts.activeFiles, 0)

        manager.registerFileProcessorBundle(
            identifier: "full-inventory-replacement",
            fileProcessorVersion: 1,
            destinationProcessor: { _ in nil },
            readerFileURLProcessor: { _, _ in nil },
            contextualFileProcessor: { context in
                try await context.performCurrentWrite { _, contentFile in
                    contentFile.title = "Current inventory processor"
                    contentFile.refreshChangeMetadata(explicitlyModified: true)
                }
            }
        )
        try await manager.refreshAllFilesMetadata(force: true)
        let currentConfiguration = replacesConfiguration ? secondConfiguration : firstConfiguration
        let currentMetadata = try await Self.importedMetadata(in: currentConfiguration)
        XCTAssertEqual(currentMetadata.map { $0.0 }, ["Current inventory processor"])
        XCTAssertEqual(manager.files?.count, 1)
        let currentCounts = try await Self.inventoryCounts(in: currentConfiguration)
        XCTAssertEqual(currentCounts.activeFiles, 1)
        XCTAssertEqual(currentCounts.workItems, 0)
        if replacesConfiguration {
            let retainedCounts = try await Self.inventoryCounts(in: firstConfiguration)
            XCTAssertEqual(retainedCounts.workItems, 1)
        }
    }

    @MainActor
    func testImportProcessorMutationFailureRollsBackAndRetainsWorkItem() async throws {
        let libraryRootURL = try temporaryDirectory()
        let sourceRootURL = try temporaryDirectory()
        let sourceURL = try writeFixture(relativePath: "rollback.epub", under: sourceRootURL)
        let configuration = makeHistoryRealmConfiguration()
        let manager = ReaderFileManager()
        manager.historyRealmConfigurationOverride = configuration
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: libraryRootURL))
        manager.registerFileProcessorBundle(
            identifier: "throwing-import-mutation",
            fileProcessorVersion: 1,
            destinationProcessor: { _ in RootRelativePath(path: "Books") },
            readerFileURLProcessor: { _, _ in nil },
            contextualFileProcessor: { context in
                try await context.performCurrentWrite { _, contentFile in
                    contentFile.title = "Uncommitted mutation"
                    throw ReaderFileManagerError.refreshSuperseded
                }
            }
        )
        do {
            _ = try await manager.importFile(fileURL: sourceURL, fromDownloadURL: nil)
            XCTFail("Expected a processor mutation error to reject import completion.")
        } catch ReaderFileManagerError.refreshSuperseded {}
        let metadata = try await Self.importedMetadata(in: configuration)
        XCTAssertEqual(metadata.map { $0.0 }, ["rollback"])
        let counts = try await Self.inventoryCounts(in: configuration)
        XCTAssertEqual(counts.activeFiles, 1)
        XCTAssertEqual(counts.workItems, 1)
        XCTAssertNil(manager.files)
    }

    @MainActor
    func testReplacedImportProcessorCannotWriteOrRetireWorkItem() async throws {
        let libraryRootURL = try temporaryDirectory()
        let sourceRootURL = try temporaryDirectory()
        let sourceURL = try writeFixture(relativePath: "callback.epub", under: sourceRootURL)
        let configuration = makeHistoryRealmConfiguration()
        let manager = ReaderFileManager()
        manager.historyRealmConfigurationOverride = configuration
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: libraryRootURL))
        let processorGate = ScanGate()
        let processorStarted = expectation(description: "import processor suspended")
        let appliedWrites = ProcessorCallCounter()
        manager.registerFileProcessorBundle(
            identifier: "callback-replacement",
            fileProcessorVersion: 1,
            destinationProcessor: { _ in RootRelativePath(path: "Books") },
            readerFileURLProcessor: { _, _ in nil },
            contextualFileProcessor: { context in
                processorStarted.fulfill()
                await processorGate.wait()
                let didApply = try await context.performCurrentWrite { _, contentFile in
                    contentFile.title = "Obsolete callback"
                    contentFile.refreshChangeMetadata(explicitlyModified: true)
                }
                if didApply { appliedWrites.increment() }
            }
        )
        let importTask = Task { @MainActor in
            try await manager.importFile(fileURL: sourceURL, fromDownloadURL: nil)
        }
        await fulfillment(of: [processorStarted], timeout: 5)
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: libraryRootURL))
        await processorGate.release()
        do {
            _ = try await importTask.value
            XCTFail("Expected an obsolete callback to reject import completion.")
        } catch ReaderFileManagerError.refreshSuperseded {}
        XCTAssertEqual(appliedWrites.count, 0)
        let metadata = try await Self.importedMetadata(in: configuration)
        XCTAssertEqual(metadata.map { $0.0 }, ["callback"])
        let counts = try await Self.inventoryCounts(in: configuration)
        XCTAssertEqual(counts.activeFiles, 1)
        XCTAssertEqual(counts.workItems, 1)
        XCTAssertNil(manager.files)

        manager.registerFileProcessorBundle(
            identifier: "callback-replacement",
            fileProcessorVersion: 1,
            destinationProcessor: { _ in RootRelativePath(path: "Books") },
            readerFileURLProcessor: { _, _ in nil },
            contextualFileProcessor: { context in
                try await context.performCurrentWrite { _, contentFile in
                    contentFile.title = "Current callback"
                    contentFile.refreshChangeMetadata(explicitlyModified: true)
                }
            }
        )
        let retryResult = try await manager.importFile(fileURL: sourceURL, fromDownloadURL: nil)
        XCTAssertNotNil(retryResult)
        let retriedMetadata = try await Self.importedMetadata(in: configuration)
        XCTAssertEqual(retriedMetadata.map { $0.0 }, ["Current callback"])
        let retriedCounts = try await Self.inventoryCounts(in: configuration)
        XCTAssertEqual(retriedCounts.workItems, 0)
    }

    @MainActor
    func testConfigurationReplacementBeforeImportProvenanceWriteRetainsOldMetadata() async throws {
        let libraryRootURL = try temporaryDirectory()
        let sourceRootURL = try temporaryDirectory()
        let sourceURL = try writeFixture(relativePath: "provenance.epub", under: sourceRootURL)
        let downloadURL = try XCTUnwrap(URL(string: "https://example.com/provenance.epub"))
        let firstConfiguration = makeHistoryRealmConfiguration()
        let secondConfiguration = makeHistoryRealmConfiguration()
        let manager = ReaderFileManager()
        manager.historyRealmConfigurationOverride = firstConfiguration
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: libraryRootURL))
        let provenanceGate = ScanGate()
        let provenanceStarted = expectation(description: "import provenance write suspended")
        manager.importProvenanceWillWriteForTesting = {
            provenanceStarted.fulfill()
            await provenanceGate.wait()
        }
        let importTask = Task { @MainActor in
            try await manager.importFile(fileURL: sourceURL, fromDownloadURL: downloadURL)
        }
        await fulfillment(of: [provenanceStarted], timeout: 5)
        manager.historyRealmConfigurationOverride = secondConfiguration
        await provenanceGate.release()
        do {
            _ = try await importTask.value
            XCTFail("Expected obsolete provenance admission to reject import completion.")
        } catch ReaderFileManagerError.refreshSuperseded {}
        let oldMetadata = try await Self.importedMetadata(in: firstConfiguration)
        XCTAssertEqual(oldMetadata.count, 1)
        XCTAssertNil(oldMetadata.first?.1)
        let newCounts = try await Self.inventoryCounts(in: secondConfiguration)
        XCTAssertEqual(newCounts.activeFiles, 0)

        manager.importProvenanceWillWriteForTesting = nil
        let retryResult = try await manager.importFile(fileURL: sourceURL, fromDownloadURL: downloadURL)
        XCTAssertNotNil(retryResult)
        let currentMetadata = try await Self.importedMetadata(in: secondConfiguration)
        XCTAssertEqual(currentMetadata.count, 1)
        XCTAssertEqual(currentMetadata.first?.1, downloadURL)
        let unchangedMetadata = try await Self.importedMetadata(in: firstConfiguration)
        XCTAssertNil(unchangedMetadata.first?.1)
    }

    @MainActor
    func testDriveReplacementDuringTargetedImportDiscoveryDoesNotAdmitMetadata() async throws {
        try await assertReplacementDuringTargetedImportDiscovery(replacesConfiguration: false)
    }

    @MainActor
    func testConfigurationReplacementDuringTargetedImportDiscoveryDoesNotAdmitMetadata() async throws {
        try await assertReplacementDuringTargetedImportDiscovery(replacesConfiguration: true)
    }

    @MainActor
    private func assertReplacementDuringTargetedImportDiscovery(replacesConfiguration: Bool) async throws {
        let libraryRootURL = try temporaryDirectory()
        let sourceRootURL = try temporaryDirectory()
        let sourceURL = try writeFixture(relativePath: "retained.epub", under: sourceRootURL)
        let firstConfiguration = makeHistoryRealmConfiguration()
        let secondConfiguration = makeHistoryRealmConfiguration()
        let manager = ReaderFileManager()
        manager.historyRealmConfigurationOverride = firstConfiguration
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: libraryRootURL))
        let discoveryGate = ScanGate()
        let discoveryStarted = expectation(description: "targeted import URL mapping suspended")
        let processorCalls = ProcessorCallCounter()
        let processorIdentifier = "targeted-import-authority-\(UUID().uuidString)"
        manager.registerFileProcessorBundle(
            identifier: processorIdentifier,
            fileProcessorVersion: 1,
            destinationProcessor: { _ in RootRelativePath(path: "Books") },
            readerFileURLProcessor: { _, _ in
                discoveryStarted.fulfill()
                await discoveryGate.wait()
                return nil
            },
            contextualFileProcessor: { context in
                processorCalls.increment()
                for contentFile in context.contentFiles {
                    context.deferPostprocessing(for: contentFile)
                }
            }
        )
        let importTask = Task { @MainActor in
            try await manager.importFile(fileURL: sourceURL, fromDownloadURL: nil)
        }
        await fulfillment(of: [discoveryStarted], timeout: 5)
        if replacesConfiguration {
            manager.historyRealmConfigurationOverride = secondConfiguration
        } else {
            manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: libraryRootURL))
        }
        await discoveryGate.release()
        do {
            _ = try await importTask.value
            XCTFail("Expected obsolete targeted discovery to reject metadata admission.")
        } catch ReaderFileManagerError.refreshSuperseded {
            XCTAssertNil(manager.files)
        }
        let retainedURL = libraryRootURL.appendingPathComponent("Books/retained.epub")
        XCTAssertEqual(try Data(contentsOf: retainedURL), try Data(contentsOf: sourceURL))
        XCTAssertEqual(processorCalls.count, 0)
        for configuration in [firstConfiguration, secondConfiguration] {
            let counts = try await Self.inventoryCounts(in: configuration)
            XCTAssertEqual(counts.activeFiles, 0)
            XCTAssertEqual(counts.workItems, 0)
        }

        manager.registerFileProcessorBundle(
            identifier: processorIdentifier,
            fileProcessorVersion: 1,
            destinationProcessor: { _ in RootRelativePath(path: "Books") },
            readerFileURLProcessor: { _, _ in nil },
            contextualFileProcessor: { context in
                processorCalls.increment()
                for contentFile in context.contentFiles {
                    context.deferPostprocessing(for: contentFile)
                }
            }
        )
        let retryResult = try await manager.importFile(fileURL: sourceURL, fromDownloadURL: nil)
        let retryURL = try XCTUnwrap(retryResult)
        XCTAssertEqual(manager.files?.map(\.url), [retryURL])
        let currentConfiguration = replacesConfiguration ? secondConfiguration : firstConfiguration
        let counts = try await Self.inventoryCounts(in: currentConfiguration)
        XCTAssertEqual(counts.activeFiles, 1)
        XCTAssertEqual(counts.workItems, 1)
        XCTAssertGreaterThan(processorCalls.count, 0)
    }

    private enum ImportInterruption: Equatable {
        case driveReplacement
        case configurationReplacement
        case cancellation
    }

    @MainActor
    func testSameRootDriveReplacementDuringImportClassificationDoesNotCopyOrIndex() async throws {
        try await assertInterruptedImportClassification(.driveReplacement)
    }

    @MainActor
    func testConfigurationReplacementDuringImportClassificationDoesNotCopyOrIndex() async throws {
        try await assertInterruptedImportClassification(.configurationReplacement)
    }

    @MainActor
    func testCancellationDuringImportClassificationDoesNotCopyOrIndex() async throws {
        try await assertInterruptedImportClassification(.cancellation)
    }

    @MainActor
    private func assertInterruptedImportClassification(_ interruption: ImportInterruption) async throws {
        let libraryRootURL = try temporaryDirectory()
        let sourceRootURL = try temporaryDirectory()
        let sourceURL = try writeFixture(relativePath: "interrupted.epub", under: sourceRootURL)
        let firstConfiguration = makeHistoryRealmConfiguration()
        let secondConfiguration = makeHistoryRealmConfiguration()
        let manager = ReaderFileManager()
        manager.historyRealmConfigurationOverride = firstConfiguration
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: libraryRootURL))
        let classificationGate = ScanGate()
        let classificationStarted = expectation(description: "public import classification suspended")
        let processorCalls = ProcessorCallCounter()
        manager.registerFileProcessorBundle(
            identifier: "interrupted-import-\(UUID().uuidString)",
            fileProcessorVersion: 1,
            destinationProcessor: { _ in
                classificationStarted.fulfill()
                await classificationGate.wait()
                return RootRelativePath(path: "Books")
            },
            readerFileURLProcessor: { _, _ in nil },
            contextualFileProcessor: { _ in processorCalls.increment() }
        )
        let importTask = Task { @MainActor in
            try await manager.importFile(fileURL: sourceURL, fromDownloadURL: nil)
        }
        await fulfillment(of: [classificationStarted], timeout: 5)
        switch interruption {
        case .driveReplacement:
            manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: libraryRootURL))
        case .configurationReplacement:
            manager.historyRealmConfigurationOverride = secondConfiguration
        case .cancellation:
            importTask.cancel()
        }
        await classificationGate.release()
        do {
            _ = try await importTask.value
            XCTFail("Expected an interrupted import to stop before copying or indexing.")
        } catch is CancellationError {
            XCTAssertEqual(interruption, .cancellation)
        } catch ReaderFileManagerError.refreshSuperseded {
            XCTAssertNotEqual(interruption, .cancellation)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: libraryRootURL.appendingPathComponent("Books").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertNil(manager.files)
        XCTAssertEqual(processorCalls.count, 0)
        for configuration in [firstConfiguration, secondConfiguration] {
            let counts = try await Self.inventoryCounts(in: configuration)
            XCTAssertEqual(counts.activeFiles, 0)
            XCTAssertEqual(counts.workItems, 0)
        }
    }

    @MainActor
    func testConcurrentImportWaitsForFollowUpInsteadOfFailingOlderInventory() async throws {
        let libraryRootURL = try temporaryDirectory()
        let sourceRootURL = try temporaryDirectory()
        _ = try writeFixture(relativePath: "Books/existing.epub", under: libraryRootURL)
        let sourceURL = try writeFixture(relativePath: "imported.epub", under: sourceRootURL)
        let configuration = makeHistoryRealmConfiguration()
        let manager = ReaderFileManager()
        manager.historyRealmConfigurationOverride = configuration
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: libraryRootURL))
        manager.registerFileProcessorBundle(
            identifier: "concurrent-import-inventory-\(UUID().uuidString)",
            fileProcessorVersion: 1,
            destinationProcessor: { _ in RootRelativePath(path: "Books") },
            readerFileURLProcessor: { _, _ in nil },
            contextualFileProcessor: { context in
                for contentFile in context.contentFiles {
                    context.deferPostprocessing(for: contentFile)
                }
            }
        )
        try await manager.refreshAllFilesMetadata(force: true)
        let previousURLs = try XCTUnwrap(manager.files).map(\.url)
        XCTAssertEqual(previousURLs.count, 1)

        let finalRefreshGate = ScanGate()
        let finalRefreshStarted = expectation(description: "old scan reached final publication")
        let importRequestedFollowUp = expectation(description: "public import requested follow-up scan")
        manager.refreshFinalInventoryWillRefreshForTesting = {
            manager.refreshFinalInventoryWillRefreshForTesting = nil
            finalRefreshStarted.fulfill()
            await finalRefreshGate.wait()
        }
        manager.refreshTaskWaiterDidAdmitForTesting = { role in
            if case .forcedJoiner = role {
                importRequestedFollowUp.fulfill()
            }
        }
        let refresh = Task { @MainActor in
            try await manager.refreshAllFilesMetadata(force: true)
        }
        await fulfillment(of: [finalRefreshStarted], timeout: 5)
        let importTask = Task { @MainActor in
            try await manager.importFile(fileURL: sourceURL, fromDownloadURL: nil)
        }
        await fulfillment(of: [importRequestedFollowUp], timeout: 5)
        XCTAssertEqual(manager.files?.map(\.url), previousURLs)
        let admittedCounts = try await Self.inventoryCounts(in: configuration)
        XCTAssertEqual(admittedCounts.activeFiles, 2)
        XCTAssertEqual(admittedCounts.workItems, 2)
        await finalRefreshGate.release()

        try await refresh.value
        let importResult = try await importTask.value
        let importedURL = try XCTUnwrap(importResult)
        let visibleURLs = try XCTUnwrap(manager.files).map(\.url)
        XCTAssertEqual(visibleURLs.count, 2)
        XCTAssertTrue(visibleURLs.contains(importedURL))
        XCTAssertTrue(visibleURLs.contains(previousURLs[0]))
        XCTAssertEqual(importedURL.lastPathComponent, "imported.epub")
        let importedBytes = try Data(contentsOf: libraryRootURL.appendingPathComponent("Books/imported.epub"))
        XCTAssertEqual(importedBytes, try Data(contentsOf: sourceURL))
        let finalCounts = try await Self.inventoryCounts(in: configuration)
        XCTAssertEqual(finalCounts.activeFiles, 2)
        XCTAssertEqual(finalCounts.workItems, 2)
    }

    @MainActor
    func testConcurrentNewFileRowIsNotTombstonedByOlderInventory() async throws {
        let rootURL = try temporaryDirectory()
        let configuration = makeHistoryRealmConfiguration()
        let manager = CountingReaderFileManager()
        manager.scanDelayNanoseconds = 0
        manager.historyRealmConfigurationOverride = configuration
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: rootURL))
        let scanGate = ScanGate()
        let scanStarted = expectation(description: "inventory scan started before import")
        manager.scanDidStart = { scanStarted.fulfill() }
        manager.scanBlocker = { _ in await scanGate.wait() }

        let refresh = Task { @MainActor in
            try await manager.refreshAllFilesMetadata()
        }
        await fulfillment(of: [scanStarted], timeout: 1)
        let readerURL = try XCTUnwrap(URL(string: "reader-file://file/load/local/Books/new.epub"))
        let primaryKey = try await Self.addContentFile(at: readerURL, to: configuration)
        let workItemIdentifier = try await Self.addPostprocessingWorkItem(
            for: primaryKey,
            in: configuration
        )
        await scanGate.release()

        do {
            try await refresh.value
            XCTFail("Expected the unobserved new row to reject complete publication.")
        } catch ReaderFileManagerError.incompleteFileInventory {
            XCTAssertNil(manager.files)
            let isDeleted = try await Self.contentFileIsDeleted(
                primaryKey: primaryKey,
                in: configuration
            )
            XCTAssertFalse(isDeleted)
            let workItemExists = try await Self.postprocessingWorkItemExists(
                workItemIdentifier,
                in: configuration
            )
            XCTAssertTrue(workItemExists)
        }
    }

    @MainActor
    func testUnavailableCloudRootCannotTombstoneItsExistingRow() async throws {
        let rootURL = try temporaryDirectory()
        let configuration = makeHistoryRealmConfiguration()
        let readerURL = try XCTUnwrap(URL(string: "reader-file://file/load/icloud/Books/cloud.epub"))
        let primaryKey = try await Self.addContentFile(at: readerURL, to: configuration)
        let workItemIdentifier = try await Self.addPostprocessingWorkItem(
            for: primaryKey,
            in: configuration
        )
        let manager = CountingReaderFileManager()
        manager.scanDelayNanoseconds = 0
        manager.historyRealmConfigurationOverride = configuration
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: rootURL))

        do {
            try await manager.refreshAllFilesMetadata()
            XCTFail("Expected an unavailable cloud root to prevent complete publication.")
        } catch ReaderFileManagerError.cloudInventoryUnavailable {
            XCTAssertNil(manager.files)
            let isDeleted = try await Self.contentFileIsDeleted(
                primaryKey: primaryKey,
                in: configuration
            )
            XCTAssertFalse(isDeleted)
            let workItemExists = try await Self.postprocessingWorkItemExists(
                workItemIdentifier,
                in: configuration
            )
            XCTAssertTrue(workItemExists)
        }
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
    func testResumeRetriesAfterJoiningCancelledSuspendedOwner() async throws {
        let rootURL = try temporaryDirectory()
        let manager = CountingReaderFileManager()
        manager.scanDelayNanoseconds = 0
        manager.historyRealmConfigurationOverride = makeHistoryRealmConfiguration()
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: rootURL))
        let firstScanGate = ScanGate()
        let secondScanGate = ScanGate()
        let firstScanStarted = expectation(description: "pre-suspension inventory scan started")
        let secondScanStarted = expectation(description: "resume replacement inventory scan started")
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

        let originalOwner = Task { @MainActor () -> Result<Void, any Swift.Error> in
            do {
                try await manager.refreshAllFilesMetadata()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        await fulfillment(of: [firstScanStarted], timeout: 1)
        manager.appSuspendedDidChange(isSuspended: true)
        manager.appSuspendedDidChange(isSuspended: false)
        await firstScanGate.release()

        switch await originalOwner.value {
        case .failure(is CancellationError):
            break
        case .failure(let error):
            XCTFail("Unexpected suspended-owner error: \(error)")
        case .success:
            XCTFail("Expected suspension to cancel the original inventory owner.")
        }
        await fulfillment(of: [secondScanStarted], timeout: 1)
        await secondScanGate.release()

        for _ in 0..<100 where manager.refreshTaskCountForTesting != 0 {
            await Task.yield()
        }
        XCTAssertEqual(manager.metadataScanCount, 2)
        XCTAssertEqual(manager.refreshTaskCountForTesting, 0)
    }

    @MainActor
    func testDebounceSkipsOrdinaryRefreshAndForceBypassesIt() async throws {
        let rootURL = try temporaryDirectory()
        let manager = CountingReaderFileManager()
        manager.scanDelayNanoseconds = 0
        manager.historyRealmConfigurationOverride = makeHistoryRealmConfiguration()
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: rootURL))

        try await manager.refreshAllFilesMetadata()
        XCTAssertEqual(manager.metadataScanCount, 1)

        try await manager.refreshAllFilesMetadata()
        XCTAssertEqual(manager.metadataScanCount, 1)

        try await manager.refreshAllFilesMetadata(force: true)
        XCTAssertEqual(manager.metadataScanCount, 2)
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
