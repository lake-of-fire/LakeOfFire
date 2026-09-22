import XCTest
import RealmSwift
import RealmSwiftGaps
import SwiftCloudDrive
import SwiftUIDownloads
@testable import LakeOfFireContent
@testable import LakeOfFireReader

final class DownloadableBookLibraryImportTests: XCTestCase {
    private enum TestError: Swift.Error {
        case sourceAccessDenied
        case postprocessorFailure
        case removalFailed
    }

    private struct Fixture {
        let manager: ReaderFileManager
        let downloadable: Downloadable
        let expectedReaderURL: URL
    }

    private struct RelocationReceiptFixture {
        let configuration: Realm.Configuration
        let receiptIdentifier: String
        let sourceURL: URL
        let targetURL: URL
        let targetContentFilePrimaryKey: String
    }

    private final class RemovalProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var recordedAttemptCount = 0
        private var failuresRemaining: Int

        init(failuresRemaining: Int = 0) {
            self.failuresRemaining = failuresRemaining
        }

        private func beginAttempt() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            recordedAttemptCount += 1
            let shouldFail = failuresRemaining > 0
            if shouldFail {
                failuresRemaining -= 1
            }
            return shouldFail
        }

        func remove(_ drive: CloudDrive, at path: RootRelativePath) async throws {
            if beginAttempt() {
                throw TestError.removalFailed
            }
            try await drive.removeFile(at: path)
        }

        var attemptCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return recordedAttemptCount
        }
    }

    private final class SourceAccessProbe {
        var events = [String]()
        var isActive = false

        func start(_ url: URL) -> Bool {
            XCTAssertFalse(isActive)
            isActive = true
            events.append("start:\(url.lastPathComponent)")
            return true
        }

        func stop(_ url: URL) {
            XCTAssertTrue(isActive)
            isActive = false
            events.append("stop:\(url.lastPathComponent)")
        }
    }

    private final class DestinationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var recordedCandidates = [URL]()

        func record(_ candidate: URL) {
            lock.lock()
            recordedCandidates.append(candidate)
            lock.unlock()
        }

        var candidates: [URL] {
            lock.lock()
            defer { lock.unlock() }
            return recordedCandidates
        }
    }

    private final class ProcessorEventProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var recordedEvents = [String]()

        func record(_ event: String) {
            lock.lock()
            recordedEvents.append(event)
            lock.unlock()
        }

        var events: [String] {
            lock.lock()
            defer { lock.unlock() }
            return recordedEvents
        }
    }

    private final class FailingProcessorProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var attemptCount = 0

        func beginAttempt() -> Int {
            lock.lock()
            defer { lock.unlock() }
            attemptCount += 1
            return attemptCount
        }

        var attempts: Int {
            lock.lock()
            defer { lock.unlock() }
            return attemptCount
        }
    }

    private final class PayloadAvailabilityProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var state: ReaderFilePayloadState = .notLocal
        private var requestedURLs = [URL]()

        func payloadState(at _: URL) -> ReaderFilePayloadState {
            lock.lock()
            defer { lock.unlock() }
            return state
        }

        func startDownloading(at url: URL) {
            lock.lock()
            requestedURLs.append(url)
            state = .current
            lock.unlock()
        }

        var downloadRequests: [URL] {
            lock.lock()
            defer { lock.unlock() }
            return requestedURLs
        }
    }

    private actor ProcessorSnapshotGate {
        private var hasEntered = false
        private var isReleased = false
        private var enteredWaiters = [CheckedContinuation<Void, Never>]()
        private var releaseWaiters = [CheckedContinuation<Void, Never>]()

        func enterAndWait() async {
            signalEntered()
            guard !isReleased else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func signalEntered() {
            hasEntered = true
            let waiters = enteredWaiters
            enteredWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }

        func waitUntilEntered() async {
            guard !hasEntered else { return }
            await withCheckedContinuation { continuation in
                enteredWaiters.append(continuation)
            }
        }

        func release() {
            isReleased = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    private func makeHistoryRealmConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(
            inMemoryIdentifier: "DownloadableBookLibraryImportTests.\(UUID().uuidString)"
        )
        configuration.objectTypes = [
            Bookmark.self,
            ContentFile.self,
            ContentPackageFile.self,
            ReaderFilePostprocessingWorkItem.self,
            ReaderFileLegacyRootRelocationReceipt.self,
            HistoryRecord.self,
            FeedEntry.self,
        ]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        return configuration
    }

    @MainActor
    private func withFixture<T>(
        downloadIsAlreadyInLibrary: Bool,
        downloadURL: URL = URL(string: "https://example.com/editor-picks/regression.epub")!,
        sourceAccess: ReaderFileSourceAccess = .securityScoped,
        legacyRootFileRemover: @escaping @Sendable (
            CloudDrive,
            RootRelativePath
        ) async throws -> Void = { drive, path in
            try await drive.removeFile(at: path)
        },
        _ operation: (Fixture) async throws -> T
    ) async throws -> T {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadableBookLibraryImportTests.\(UUID().uuidString)", isDirectory: true)
        let libraryRootURL = baseURL.appendingPathComponent("Library", isDirectory: true)
        let downloadCacheURL = baseURL.appendingPathComponent("DownloadCache", isDirectory: true)
        let libraryBooksURL = libraryRootURL.appendingPathComponent("Books", isDirectory: true)
        let destinationRoot = downloadIsAlreadyInLibrary ? libraryBooksURL : downloadCacheURL
        let localDestination = destinationRoot.appendingPathComponent("regression.epub")
        try FileManager.default.createDirectory(
            at: localDestination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("epub fixture".utf8).write(to: localDestination)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: baseURL)
        }

        let previousHistoryConfiguration = ReaderContentLoader.historyRealmConfiguration
        let previousSharedManager = ReaderFileManager.shared
        let previousFileDestinationProcessors = ReaderFileManager.fileDestinationProcessors
        let previousReaderFileURLProcessors = ReaderFileManager.readerFileURLProcessors
        let previousFileProcessors = ReaderFileManager.fileProcessors
        defer {
            ReaderContentLoader.historyRealmConfiguration = previousHistoryConfiguration
            ReaderFileManager.shared = previousSharedManager
            ReaderFileManager.fileDestinationProcessors = previousFileDestinationProcessors
            ReaderFileManager.readerFileURLProcessors = previousReaderFileURLProcessors
            ReaderFileManager.fileProcessors = previousFileProcessors
        }

        let manager = ReaderFileManager(
            defaultLocalRootURLProvider: { libraryRootURL },
            sourceAccess: sourceAccess,
            legacyRootFileRemover: legacyRootFileRemover
        )
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: libraryRootURL))
        ReaderFileManager.shared = manager
        EbookFileManager.configure()
        ReaderContentLoader.historyRealmConfiguration = makeHistoryRealmConfiguration()

        let downloadable = Downloadable(
            url: downloadURL,
            name: "Regression Book",
            localDestination: localDestination
        )
        return try await operation(Fixture(
            manager: manager,
            downloadable: downloadable,
            expectedReaderURL: URL(string: "ebook://ebook/load/local/Books/regression.epub")!
        ))
    }

    @MainActor
    private func admitLegacyRootRelocationReceipt(
        fixture: Fixture,
        filename: String
    ) async throws -> RelocationReceiptFixture {
        let drive = try XCTUnwrap(fixture.manager.localDrive)
        let sourceURL = drive.rootDirectory.appendingPathComponent(filename)
        let targetURL = drive.rootDirectory.appendingPathComponent("Books/\(filename)")
        try FileManager.default.copyItem(at: fixture.downloadable.localDestination, to: sourceURL)
        try FileManager.default.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: sourceURL, to: targetURL)
        try await fixture.manager.refreshAllFilesMetadata(force: true)

        let configuration = ReaderContentLoader.historyRealmConfiguration
        let sourceReaderURL = try XCTUnwrap(
            URL(string: "ebook://ebook/load/local/\(filename)")
        )
        let targetReaderURL = try XCTUnwrap(
            URL(string: "ebook://ebook/load/local/Books/\(filename)")
        )
        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let targetAttributes = try FileManager.default.attributesOfItem(atPath: targetURL.path)
        let storageScope = [
            "memory:\(try XCTUnwrap(configuration.inMemoryIdentifier))",
            drive.rootDirectory.standardizedFileURL.absoluteString,
            "local",
        ]
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")

        return try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            let source = try XCTUnwrap(
                realm.objects(ContentFile.self)
                    .filter(NSPredicate(
                        format: "url == %@",
                        sourceReaderURL.absoluteString as CVarArg
                    ))
                    .first
            )
            let target = try XCTUnwrap(
                realm.objects(ContentFile.self)
                    .filter(NSPredicate(
                        format: "url == %@",
                        targetReaderURL.absoluteString as CVarArg
                    ))
                    .first
            )
            let receiptIdentifier = ReaderFileLegacyRootRelocationReceipt
                .makeReceiptIdentifier(
                    storageScopeIdentifier: storageScope,
                    sourceRelativePath: filename,
                    sourceContentFilePrimaryKey: source.compoundKey
                )
            let sourceContentFilePrimaryKey = source.compoundKey
            let targetContentFilePrimaryKey = target.compoundKey
            try await realm.asyncWrite {
                let receipt = ReaderFileLegacyRootRelocationReceipt()
                receipt.receiptIdentifier = receiptIdentifier
                receipt.storageScopeIdentifier = storageScope
                receipt.sourceRelativePath = filename
                receipt.sourceReaderBackingURLString =
                    "reader-file://file/load/local/\(filename)"
                receipt.sourceContentFilePrimaryKey = sourceContentFilePrimaryKey
                receipt.sourceContentFileCreatedAt = source.createdAt
                receipt.sourceModifiedAt = sourceAttributes[.modificationDate] as? Date
                receipt.sourceFileSize =
                    (sourceAttributes[.size] as? NSNumber)?.int64Value ?? -1
                receipt.targetReaderURLString = targetReaderURL.absoluteString
                receipt.targetContentFilePrimaryKey = targetContentFilePrimaryKey
                receipt.targetContentFileCreatedAt = target.createdAt
                receipt.targetModifiedAt = targetAttributes[.modificationDate] as? Date
                receipt.targetFileSize =
                    (targetAttributes[.size] as? NSNumber)?.int64Value ?? -1
                realm.add(receipt)
                source.isDeleted = true
                source.refreshChangeMetadata(explicitlyModified: true)
            }
            return RelocationReceiptFixture(
                configuration: configuration,
                receiptIdentifier: receiptIdentifier,
                sourceURL: sourceURL,
                targetURL: targetURL,
                targetContentFilePrimaryKey: targetContentFilePrimaryKey
            )
        }()
    }

    @RealmBackgroundActor
    private func assertLegacyRootRelocationReceipt(
        _ receipt: RelocationReceiptFixture,
        isPresent: Bool
    ) async throws {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(
            for: receipt.configuration
        )
        XCTAssertEqual(
            realm.object(
                ofType: ReaderFileLegacyRootRelocationReceipt.self,
                forPrimaryKey: receipt.receiptIdentifier
            ) != nil,
            isPresent
        )
        XCTAssertTrue(
            realm.object(
                ofType: ContentFile.self,
                forPrimaryKey: receipt.targetContentFilePrimaryKey
            )?.isDeleted == false
        )
    }

    @MainActor
    private func assertLegacyRootRelocationReceiptAdmitted(
        configuration: Realm.Configuration
    ) async throws {
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
            let receipt = try XCTUnwrap(
                realm.objects(ReaderFileLegacyRootRelocationReceipt.self).first
            )
            XCTAssertTrue(
                realm.object(
                    ofType: ContentFile.self,
                    forPrimaryKey: receipt.sourceContentFilePrimaryKey
                )?.isDeleted == true
            )
            XCTAssertTrue(
                realm.object(
                    ofType: ContentFile.self,
                    forPrimaryKey: receipt.targetContentFilePrimaryKey
                )?.isDeleted == false
            )
        }()
    }

    @MainActor
    func testEnsureImportedCopiesCachedDownloadIntoIndexedBookLibrary() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: false) { fixture in
            let existsLocally = await fixture.downloadable.existsLocally()
            let readerURLBeforeImport = try await fixture.manager.readerFileURL(for: fixture.downloadable)
            XCTAssertTrue(existsLocally)
            XCTAssertNil(readerURLBeforeImport)

            try await assertEnsureImportedIndexesBook(fixture)
        }
    }

    @MainActor
    func testEnsureImportedRelocatesLegacyRootEPUBAfterIndexingTarget() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: false) { fixture in
            let drive = try XCTUnwrap(fixture.manager.localDrive)
            let legacyURL = drive.rootDirectory.appendingPathComponent("legacy.epub")
            try FileManager.default.copyItem(
                at: fixture.downloadable.localDestination,
                to: legacyURL
            )
            let legacyDownload = Downloadable(
                url: URL(string: "https://example.com/legacy.epub")!,
                name: "Legacy EPUB",
                localDestination: legacyURL
            )

            let relocatedURL = try await fixture.manager.ensureImported(
                downloadable: legacyDownload
            )
            XCTAssertEqual(
                relocatedURL,
                URL(string: "ebook://ebook/load/local/Books/legacy.epub")
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: drive.rootDirectory.appendingPathComponent("Books/legacy.epub").path
                )
            )

            let realm = try await Realm.open(
                configuration: ReaderContentLoader.historyRealmConfiguration
            )
            let liveFiles = realm.objects(ContentFile.self).where { !$0.isDeleted }
            XCTAssertEqual(liveFiles.count, 1)
            XCTAssertEqual(liveFiles.first?.url, relocatedURL)
            XCTAssertEqual(
                realm.objects(ReaderFileLegacyRootRelocationReceipt.self).count,
                0
            )
        }
    }

    @MainActor
    func testEnsureImportedLeavesRootFileWhenNoProcessorClassifiesIt() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: false) { fixture in
            ReaderFileManager.fileDestinationProcessors = []
            ReaderFileManager.readerFileURLProcessors = []
            let drive = try XCTUnwrap(fixture.manager.localDrive)
            let rootURL = drive.rootDirectory.appendingPathComponent("unchanged.txt")
            try Data("root file".utf8).write(to: rootURL)
            let rootDownload = Downloadable(
                url: URL(string: "https://example.com/unchanged.txt")!,
                name: "Unchanged",
                localDestination: rootURL
            )

            _ = try await fixture.manager.ensureImported(downloadable: rootDownload)
            XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.path))
            let realm = try await Realm.open(
                configuration: ReaderContentLoader.historyRealmConfiguration
            )
            XCTAssertTrue(
                realm.objects(ReaderFileLegacyRootRelocationReceipt.self).isEmpty
            )
        }
    }

    @MainActor
    func testRefreshDrainsReceiptAfterSourceWasRemovedBeforeReceiptCleanup() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: false) { fixture in
            let receipt = try await admitLegacyRootRelocationReceipt(
                fixture: fixture,
                filename: "crash.epub"
            )
            try FileManager.default.removeItem(at: receipt.sourceURL)

            try await fixture.manager.refreshAllFilesMetadata(force: true)
            try await assertLegacyRootRelocationReceipt(receipt, isPresent: false)
        }
    }

    @MainActor
    func testEnsureImportedRetriesLegacyRootRemovalAfterInitialPhysicalDeletionFailure() async throws {
        let removalProbe = RemovalProbe(failuresRemaining: 1)
        try await withFixture(
            downloadIsAlreadyInLibrary: false,
            legacyRootFileRemover: { drive, path in
                try await removalProbe.remove(drive, at: path)
            }
        ) { fixture in
            let drive = try XCTUnwrap(fixture.manager.localDrive)
            let sourceURL = drive.rootDirectory.appendingPathComponent("retry.epub")
            let targetURL = drive.rootDirectory.appendingPathComponent("Books/retry.epub")
            try FileManager.default.copyItem(at: fixture.downloadable.localDestination, to: sourceURL)
            let legacyDownload = Downloadable(
                url: URL(string: "https://example.com/retry.epub")!,
                name: "Retry EPUB",
                localDestination: sourceURL
            )

            let relocatedURL = try await fixture.manager.ensureImported(downloadable: legacyDownload)
            XCTAssertEqual(
                relocatedURL,
                URL(string: "ebook://ebook/load/local/Books/retry.epub")
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: targetURL.path))
            XCTAssertEqual(removalProbe.attemptCount, 1)
            try await assertLegacyRootRelocationReceiptAdmitted(
                configuration: ReaderContentLoader.historyRealmConfiguration
            )

            try await fixture.manager.refreshAllFilesMetadata(force: true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: targetURL.path))
            XCTAssertEqual(removalProbe.attemptCount, 2)
            try await { @RealmBackgroundActor in
                let realm = try await RealmBackgroundActor.shared.cachedRealm(
                    for: ReaderContentLoader.historyRealmConfiguration
                )
                XCTAssertTrue(realm.objects(ReaderFileLegacyRootRelocationReceipt.self).isEmpty)
                let liveFiles = realm.objects(ContentFile.self).where { !$0.isDeleted }
                XCTAssertEqual(liveFiles.count, 1)
                XCTAssertEqual(liveFiles.first?.url, relocatedURL)
            }()
        }
    }

    @MainActor
    func testRefreshRetainsReceiptWhenLegacyRootSourceGenerationChanges() async throws {
        let removalProbe = RemovalProbe()
        try await withFixture(
            downloadIsAlreadyInLibrary: false,
            legacyRootFileRemover: { drive, path in
                try await removalProbe.remove(drive, at: path)
            }
        ) { fixture in
            let receipt = try await admitLegacyRootRelocationReceipt(
                fixture: fixture,
                filename: "changed-source.epub"
            )
            try Data("changed source generation".utf8).write(to: receipt.sourceURL)

            try await fixture.manager.refreshAllFilesMetadata(force: true)

            XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.sourceURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.targetURL.path))
            XCTAssertEqual(removalProbe.attemptCount, 0)
            try await assertLegacyRootRelocationReceipt(receipt, isPresent: true)
        }
    }

    @MainActor
    func testRefreshRetainsReceiptWhenLegacyRootTargetGenerationChanges() async throws {
        let removalProbe = RemovalProbe()
        try await withFixture(
            downloadIsAlreadyInLibrary: false,
            legacyRootFileRemover: { drive, path in
                try await removalProbe.remove(drive, at: path)
            }
        ) { fixture in
            let receipt = try await admitLegacyRootRelocationReceipt(
                fixture: fixture,
                filename: "changed-target.epub"
            )
            try Data("changed target generation".utf8).write(to: receipt.targetURL)

            try await fixture.manager.refreshAllFilesMetadata(force: true)

            XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.sourceURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.targetURL.path))
            XCTAssertEqual(removalProbe.attemptCount, 0)
            try await assertLegacyRootRelocationReceipt(receipt, isPresent: true)
        }
    }

    @MainActor
    func testCloudOnlyReaderFileBecomesReadableAfterRequestedDownloadCompletes() async throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DownloadableBookLibraryImportTests.CloudAvailability.\(UUID().uuidString)",
                isDirectory: true
            )
        let localRootURL = baseURL.appendingPathComponent("Local", isDirectory: true)
        let cloudRootURL = baseURL.appendingPathComponent("Cloud", isDirectory: true)
        let cloudFileURL = cloudRootURL.appendingPathComponent("Books/cloud.epub")
        try FileManager.default.createDirectory(
            at: cloudFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("cloud epub fixture".utf8).write(to: cloudFileURL)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: baseURL)
        }

        let probe = PayloadAvailabilityProbe()
        let manager = ReaderFileManager(
            defaultLocalRootURLProvider: { localRootURL },
            availabilityAccess: ReaderFileAvailabilityAccess(
                payloadState: { probe.payloadState(at: $0) },
                startDownloading: { probe.startDownloading(at: $0) },
                canCoordinateRead: { _ in true }
            )
        )
        manager.cloudDrive = try await CloudDrive(
            storage: .localDirectory(rootURL: cloudRootURL)
        )
        let readerFileURL = try XCTUnwrap(
            URL(string: "ebook://ebook/load/icloud/Books/cloud.epub")
        )

        let initialStatus = try await manager.cloudDriveSyncStatus(
            readerFileURL: readerFileURL
        )
        guard case .cloudOnly = initialStatus else {
            return XCTFail("Expected cloud-only status, got \(initialStatus)")
        }
        do {
            _ = try await manager.resolveReadableLocalURL(
                forReaderBackingURL: readerFileURL
            )
            XCTFail("Expected the first access to request the cloud payload")
        } catch ReaderFileAccessError.downloadInProgress {
            // Expected.
        }
        XCTAssertEqual(
            probe.downloadRequests.map(\.absoluteURL.standardizedFileURL),
            [cloudFileURL.standardizedFileURL]
        )

        let resolvedURL = try await manager.resolveReadableLocalURL(
            forReaderBackingURL: readerFileURL
        )
        XCTAssertEqual(
            resolvedURL.standardizedFileURL,
            cloudFileURL.standardizedFileURL
        )
        let finalStatus = try await manager.cloudDriveSyncStatus(
            readerFileURL: readerFileURL
        )
        guard case .availableLocally = finalStatus else {
            return XCTFail("Expected locally available status, got \(finalStatus)")
        }
    }

    @MainActor
    func testEbookConfigureReplacesStableProcessorRegistrations() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: false) { _ in
            ReaderFileManager.fileDestinationProcessors = []
            ReaderFileManager.readerFileURLProcessors = []
            ReaderFileManager.fileProcessors = []

            EbookFileManager.configure()
            EbookFileManager.configure()

            XCTAssertEqual(ReaderFileManager.fileDestinationProcessors.count, 1)
            XCTAssertEqual(ReaderFileManager.readerFileURLProcessors.count, 1)
            XCTAssertEqual(ReaderFileManager.fileProcessors.count, 1)
        }
    }

    @MainActor
    func testEbookConfigurationIsOwnedByExplicitReaderFileManager() async throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DownloadableBookLibraryImportTests.\(UUID().uuidString)",
                isDirectory: true
            )
        let firstRootURL = baseURL.appendingPathComponent("First", isDirectory: true)
        let secondRootURL = baseURL.appendingPathComponent("Second", isDirectory: true)
        let firstFileURL = firstRootURL.appendingPathComponent(
            "Books/first.epub",
            isDirectory: true
        )
        let secondFileURL = secondRootURL.appendingPathComponent("Books/second.epub")
        let metadataDirectoryURL = firstFileURL.appendingPathComponent("META-INF")
        let packageDirectoryURL = firstFileURL.appendingPathComponent("OEBPS")
        try FileManager.default.createDirectory(
            at: metadataDirectoryURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: packageDirectoryURL,
            withIntermediateDirectories: true
        )
        try Data("""
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """.utf8).write(to: metadataDirectoryURL.appendingPathComponent("container.xml"))
        try Data("""
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="book-id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="book-id">first-manager</dc:identifier>
            <dc:title>First Manager Title</dc:title>
          </metadata>
          <manifest/>
        </package>
        """.utf8).write(to: packageDirectoryURL.appendingPathComponent("content.opf"))
        try FileManager.default.createDirectory(
            at: secondFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("epub fixture".utf8).write(to: secondFileURL)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: baseURL)
        }

        let firstManager = ReaderFileManager(defaultLocalRootURLProvider: { firstRootURL })
        let secondManager = ReaderFileManager(defaultLocalRootURLProvider: { secondRootURL })
        firstManager.localDrive = try await CloudDrive(
            storage: .localDirectory(rootURL: firstRootURL)
        )
        secondManager.localDrive = try await CloudDrive(
            storage: .localDirectory(rootURL: secondRootURL)
        )
        firstManager.historyRealmConfigurationOverride = makeHistoryRealmConfiguration()
        secondManager.historyRealmConfigurationOverride = makeHistoryRealmConfiguration()

        let previousSharedManager = ReaderFileManager.shared
        ReaderFileManager.shared = secondManager
        defer {
            ReaderFileManager.shared = previousSharedManager
        }

        EbookFileManager.configure(readerFileManager: firstManager)

        XCTAssertTrue(firstManager.readerContentMimeTypes.contains(.epub))
        XCTAssertFalse(secondManager.readerContentMimeTypes.contains(.epub))
        firstManager.registerFileProcessorBundle(
            identifier: "ReplaceableContentTypeTest",
            readerContentMimeTypes: [.pdf],
            destinationProcessor: { _ in nil },
            readerFileURLProcessor: { _, _ in nil },
            fileProcessor: { _ in }
        )
        XCTAssertTrue(firstManager.readerContentMimeTypes.contains(.pdf))
        firstManager.registerFileProcessorBundle(
            identifier: "ReplaceableContentTypeTest",
            readerContentMimeTypes: [],
            destinationProcessor: { _ in nil },
            readerFileURLProcessor: { _, _ in nil },
            fileProcessor: { _ in }
        )
        XCTAssertFalse(firstManager.readerContentMimeTypes.contains(.pdf))
        let remoteEbookURL = URL(string: "https://example.com/remote.epub")!
        let firstDownloadableResult = try await firstManager.downloadable(
            url: remoteEbookURL,
            name: "First Remote"
        )
        let secondDownloadableResult = try await secondManager.downloadable(
            url: remoteEbookURL,
            name: "Second Remote"
        )
        let firstDownloadable = try XCTUnwrap(firstDownloadableResult)
        let secondDownloadable = try XCTUnwrap(secondDownloadableResult)
        let firstRelativeComponents = Array(
            firstDownloadable.localDestination.pathComponents
                .dropFirst(firstRootURL.pathComponents.count)
        )
        XCTAssertEqual(firstRelativeComponents.count, 5)
        XCTAssertEqual(Array(firstRelativeComponents.prefix(3)), ["Books", "CatalogArtifacts", "v1"])
        XCTAssertEqual(firstRelativeComponents[3].count, 64)
        XCTAssertEqual(firstRelativeComponents[4], "remote.epub")
        let secondRelativeComponents = Array(
            secondDownloadable.localDestination.pathComponents
                .dropFirst(secondRootURL.pathComponents.count)
        )
        XCTAssertEqual(secondRelativeComponents.count, 5)
        XCTAssertTrue(secondRelativeComponents[0].hasPrefix("ReaderFileDownload."))
        XCTAssertEqual(Array(secondRelativeComponents[1...2]), ["CatalogArtifacts", "v1"])
        XCTAssertEqual(secondRelativeComponents[3].count, 64)
        XCTAssertEqual(secondRelativeComponents[4], "remote.epub")
        let firstReaderFileURL = try await firstManager.readerFileURL(for: firstFileURL)
        let secondReaderFileURL = try await secondManager.readerFileURL(for: secondFileURL)
        XCTAssertEqual(
            firstReaderFileURL,
            URL(string: "ebook://ebook/load/local/Books/first.epub")
        )
        XCTAssertEqual(
            secondReaderFileURL,
            URL(string: "reader-file://file/load/local/Books/second.epub")
        )

        try await firstManager.refreshAllFilesMetadata(force: true)
        try await secondManager.refreshAllFilesMetadata(force: true)
        XCTAssertEqual(firstManager.files?.map(\.url), [firstReaderFileURL].compactMap { $0 })
        XCTAssertEqual(firstManager.files?.first?.title, "First Manager Title")
        XCTAssertEqual(secondManager.files?.count, 0)
    }

    @MainActor
    func testCatalogDownloadDestinationsUseExactAcquisitionURLIdentity() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DownloadableBookLibraryImportTests.CatalogIdentity.\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let manager = ReaderFileManager(defaultLocalRootURLProvider: { rootURL })
        manager.localDrive = try await CloudDrive(
            storage: .localDirectory(rootURL: rootURL)
        )
        manager.historyRealmConfigurationOverride = makeHistoryRealmConfiguration()
        EbookFileManager.configure(readerFileManager: manager)

        let firstURL = URL(string: "https://first.example/books/shared.epub")!
        let secondURL = URL(string: "https://second.example/books/shared.epub")!
        let queryURL = URL(string: "https://first.example/books/shared.epub?revision=2")!
        let firstResult = try await manager.downloadable(url: firstURL, name: "First title")
        let replayResult = try await manager.downloadable(url: firstURL, name: "Renamed title")
        let secondResult = try await manager.downloadable(url: secondURL, name: "Second title")
        let queryResult = try await manager.downloadable(url: queryURL, name: "Query title")
        let first = try XCTUnwrap(firstResult)
        let replay = try XCTUnwrap(replayResult)
        let second = try XCTUnwrap(secondResult)
        let query = try XCTUnwrap(queryResult)
        let firstPublication = Publication(title: "First title", downloadURL: firstURL)
        let renamedPublication = Publication(title: "Renamed title", downloadURL: firstURL)
        let secondPublication = Publication(title: "Second title", downloadURL: secondURL)

        XCTAssertEqual(first.localDestination, replay.localDestination)
        XCTAssertNotEqual(first.localDestination, second.localDestination)
        XCTAssertNotEqual(first.localDestination, query.localDestination)
        XCTAssertEqual(firstPublication.id, renamedPublication.id)
        XCTAssertNotEqual(firstPublication.id, secondPublication.id)
        XCTAssertEqual(firstPublication, renamedPublication)
        XCTAssertEqual(Set([firstPublication, renamedPublication]).count, 1)
        XCTAssertEqual(first.localDestination.lastPathComponent, "shared.epub")
        XCTAssertTrue(first.localDestination.pathComponents.contains("CatalogArtifacts"))
        XCTAssertTrue(first.localDestination.pathComponents.contains("v1"))
        XCTAssertTrue(first.localDestination.standardizedFileURL.path.hasPrefix(
            rootURL.standardizedFileURL.path + "/"
        ))

        try FileManager.default.createDirectory(
            at: first.localDestination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("first artifact".utf8).write(to: first.localDestination)
        let firstExistsLocally = await first.existsLocally()
        let secondExistsLocally = await second.existsLocally()
        XCTAssertTrue(firstExistsLocally)
        XCTAssertFalse(secondExistsLocally)
        let firstReaderURL = try await manager.readerFileURL(for: first)
        let expectedFirstReaderURL = URL(string: [
            "ebook://ebook/load/local/Books/CatalogArtifacts/v1",
            first.localDestination.deletingLastPathComponent().lastPathComponent,
            "shared.epub",
        ].joined(separator: "/"))
        XCTAssertEqual(firstReaderURL, expectedFirstReaderURL)
        let importedFirstReaderURL = try await manager.ensureImported(downloadable: first)
        XCTAssertEqual(importedFirstReaderURL, expectedFirstReaderURL)
        XCTAssertEqual(manager.files?.map(\.url), [expectedFirstReaderURL].compactMap { $0 })

        let legacyURL = rootURL
            .appendingPathComponent("Books", isDirectory: true)
            .appendingPathComponent("legacy.epub")
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("legacy artifact".utf8).write(to: legacyURL)
        let legacyAcquisitionResult = try await manager.downloadable(
            url: URL(string: "https://legacy.example/legacy.epub")!,
            name: "Legacy title"
        )
        let legacyAcquisition = try XCTUnwrap(legacyAcquisitionResult)
        XCTAssertNotEqual(legacyAcquisition.localDestination, legacyURL)
        let legacyAcquisitionExistsLocally = await legacyAcquisition.existsLocally()
        XCTAssertFalse(legacyAcquisitionExistsLocally)

        let basenameFreeResult = try await manager.downloadable(
            url: URL(string: "https://example.com/")!,
            name: "No basename"
        )
        let encodedSeparatorResult = try await manager.downloadable(
            url: URL(string: "https://example.com/a%2Fb.epub")!,
            name: "Encoded separator"
        )
        let basenameFree = try XCTUnwrap(basenameFreeResult)
        let encodedSeparator = try XCTUnwrap(encodedSeparatorResult)
        XCTAssertEqual(basenameFree.localDestination.lastPathComponent, "download")
        XCTAssertNotEqual(
            basenameFree.localDestination,
            basenameFree.localDestination.deletingLastPathComponent()
        )
        XCTAssertEqual(encodedSeparator.localDestination.lastPathComponent, "a%2Fb.epub")
        let encodedSeparatorIdentityDirectory = encodedSeparator.localDestination
            .deletingLastPathComponent()
        XCTAssertEqual(encodedSeparatorIdentityDirectory.lastPathComponent.count, 64)
        XCTAssertTrue(encodedSeparatorIdentityDirectory.lastPathComponent.allSatisfy {
            $0.isHexDigit && !$0.isUppercase
        })
        XCTAssertEqual(
            encodedSeparatorIdentityDirectory.deletingLastPathComponent().lastPathComponent,
            "v1"
        )

        let symlinkRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DownloadableBookLibraryImportTests.CatalogSymlink.\(UUID().uuidString)",
                isDirectory: true
            )
        let outsideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DownloadableBookLibraryImportTests.CatalogOutside.\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: symlinkRootURL.appendingPathComponent("Books", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: symlinkRootURL.appendingPathComponent("Books/CatalogArtifacts"),
            withDestinationURL: outsideURL
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: symlinkRootURL)
            try? FileManager.default.removeItem(at: outsideURL)
        }
        let symlinkManager = ReaderFileManager(defaultLocalRootURLProvider: { symlinkRootURL })
        symlinkManager.localDrive = try await CloudDrive(
            storage: .localDirectory(rootURL: symlinkRootURL)
        )
        symlinkManager.historyRealmConfigurationOverride = makeHistoryRealmConfiguration()
        EbookFileManager.configure(readerFileManager: symlinkManager)

        do {
            _ = try await symlinkManager.downloadable(
                url: URL(string: "https://example.com/escaped.epub")!,
                name: "Escaped"
            )
            XCTFail("Expected a catalog destination symlink outside the drive to be rejected.")
        } catch ReaderFileManagerError.invalidDestinationPath {
            let outsideContents = try FileManager.default.contentsOfDirectory(atPath: outsideURL.path)
            XCTAssertEqual(outsideContents, [])
        }
    }

    @MainActor
    func testImportUsesOneProcessorBundleSnapshotAcrossMidflightReplacement() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: false) { fixture in
            ReaderFileManager.fileDestinationProcessors = []
            ReaderFileManager.readerFileURLProcessors = []
            ReaderFileManager.fileProcessors = []

            let gate = ProcessorSnapshotGate()
            let postprocessorProbe = ProcessorEventProbe()
            ReaderFileManager.registerFileProcessorBundle(
                identifier: "ProcessorSnapshotTest",
                destinationProcessor: { _ in
                    await gate.enterAndWait()
                    return RootRelativePath(path: "Old")
                },
                readerFileURLProcessor: { _, encodedPath in
                    URL(string: "ebook://ebook/load/" + encodedPath)
                },
                fileProcessor: { _ in
                    postprocessorProbe.record("old")
                }
            )

            let importTask = Task { @MainActor in
                try await fixture.manager.ensureImported(downloadable: fixture.downloadable)
            }
            await gate.waitUntilEntered()

            ReaderFileManager.registerFileProcessorBundle(
                identifier: "ProcessorSnapshotTest",
                destinationProcessor: { _ in RootRelativePath(path: "New") },
                readerFileURLProcessor: { _, encodedPath in
                    URL(string: "mokuro://mokuro/load/" + encodedPath)
                },
                fileProcessor: { _ in
                    postprocessorProbe.record("new")
                }
            )
            await gate.release()

            let importedURL = try await importTask.value
            let expectedReaderURL = URL(
                string: "ebook://ebook/load/local/Old/regression.epub"
            )!
            XCTAssertEqual(importedURL, expectedReaderURL)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: try XCTUnwrap(fixture.manager.localDrive)
                        .rootDirectory
                        .appendingPathComponent("Old/regression.epub")
                        .path
                )
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: try XCTUnwrap(fixture.manager.localDrive)
                        .rootDirectory
                        .appendingPathComponent("New/regression.epub")
                        .path
                )
            )
            XCTAssertFalse(postprocessorProbe.events.isEmpty)
            XCTAssertTrue(postprocessorProbe.events.allSatisfy { $0 == "old" })

            let realm = try await Realm.open(
                configuration: ReaderContentLoader.historyRealmConfiguration
            )
            XCTAssertEqual(
                realm.objects(ContentFile.self).where { !$0.isDeleted }.first?.url,
                expectedReaderURL
            )
        }
    }

    @MainActor
    func testPostprocessorFailureDoesNotSuppressLaterProcessors() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: false) { fixture in
            let probe = ProcessorEventProbe()
            ReaderFileManager.fileProcessors = [
                { _ in throw TestError.postprocessorFailure },
                { contentFiles in
                    probe.record("later:\(contentFiles.count)")
                },
            ]

            do {
                _ = try await fixture.manager.ensureImported(downloadable: fixture.downloadable)
                XCTFail("Expected the first processor failure to remain visible")
            } catch TestError.postprocessorFailure {
                // Expected.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }

            XCTAssertEqual(probe.events, ["later:1"])
        }
    }

    @MainActor
    func testDurablePostprocessingWorkItemRetriesAnUnchangedFileAndClearsAfterSuccess() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: false) { fixture in
            let probe = FailingProcessorProbe()
            fixture.manager.registerFileProcessorBundle(
                identifier: "DurableRetryTest",
                fileProcessorVersion: 1,
                destinationProcessor: { _ in nil },
                readerFileURLProcessor: { _, _ in nil },
                contextualFileProcessor: { context in
                    XCTAssertEqual(context.contentFiles.count, 1)
                    if probe.beginAttempt() == 1 {
                        throw TestError.postprocessorFailure
                    }
                }
            )

            do {
                _ = try await fixture.manager.ensureImported(
                    downloadable: fixture.downloadable
                )
                XCTFail("Expected the first durable processor attempt to fail")
            } catch TestError.postprocessorFailure {
                // Expected.
            }

            let configuration = ReaderContentLoader.historyRealmConfiguration
            var realm = try await Realm.open(configuration: configuration)
            let workItem = try XCTUnwrap(
                realm.objects(ReaderFilePostprocessingWorkItem.self)
                    .where { $0.processorIdentifier == "DurableRetryTest" }
                    .first
            )
            XCTAssertEqual(workItem.processorVersion, 1)
            XCTAssertEqual(workItem.readerFileURLString, fixture.expectedReaderURL.absoluteString)
            let firstAttemptIdentifier = workItem.attemptIdentifier

            try await fixture.manager.refreshAllFilesMetadata(force: true)

            realm = try await Realm.open(configuration: configuration)
            XCTAssertEqual(probe.attempts, 2)
            XCTAssertTrue(
                realm.objects(ReaderFilePostprocessingWorkItem.self)
                    .where { $0.processorIdentifier == "DurableRetryTest" }
                    .isEmpty
            )
            XCTAssertFalse(firstAttemptIdentifier.isEmpty)
        }
    }

    @MainActor
    func testDurablePostprocessorRejectsEffectsAfterSameVersionReplacement() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: false) { fixture in
            let gate = ProcessorSnapshotGate()
            let probe = ProcessorEventProbe()
            fixture.manager.registerFileProcessorBundle(
                identifier: "ReplacementFenceTest",
                fileProcessorVersion: 1,
                destinationProcessor: { _ in nil },
                readerFileURLProcessor: { _, _ in nil },
                contextualFileProcessor: { context in
                    await gate.enterAndWait()
                    let didApply = try await context.performCurrentWrite { _, contentFile in
                        contentFile.title = "Stale Registration"
                        contentFile.refreshChangeMetadata(explicitlyModified: true)
                    }
                    probe.record("old:\(didApply)")
                }
            )

            let importTask = Task { @MainActor in
                try await fixture.manager.ensureImported(downloadable: fixture.downloadable)
            }
            await gate.waitUntilEntered()
            fixture.manager.registerFileProcessorBundle(
                identifier: "ReplacementFenceTest",
                fileProcessorVersion: 1,
                destinationProcessor: { _ in nil },
                readerFileURLProcessor: { _, _ in nil },
                contextualFileProcessor: { context in
                    let didApply = try await context.performCurrentWrite { _, contentFile in
                        contentFile.title = "Current Registration"
                        contentFile.refreshChangeMetadata(explicitlyModified: true)
                    }
                    probe.record("new:\(didApply)")
                }
            )
            await gate.release()
            _ = try await importTask.value

            let configuration = ReaderContentLoader.historyRealmConfiguration
            var realm = try await Realm.open(configuration: configuration)
            XCTAssertFalse(probe.events.isEmpty)
            XCTAssertTrue(probe.events.allSatisfy { $0 == "old:false" })
            XCTAssertNotEqual(
                realm.objects(ContentFile.self).first?.title,
                "Stale Registration"
            )
            XCTAssertEqual(
                realm.objects(ReaderFilePostprocessingWorkItem.self)
                    .where { $0.processorIdentifier == "ReplacementFenceTest" }
                    .count,
                1
            )

            try await fixture.manager.refreshAllFilesMetadata(force: true)

            realm = try await Realm.open(configuration: configuration)
            XCTAssertEqual(probe.events.last, "new:true")
            XCTAssertTrue(probe.events.dropLast().allSatisfy { $0 == "old:false" })
            XCTAssertEqual(
                realm.objects(ContentFile.self).first?.title,
                "Current Registration"
            )
            XCTAssertTrue(
                realm.objects(ReaderFilePostprocessingWorkItem.self)
                    .where { $0.processorIdentifier == "ReplacementFenceTest" }
                    .isEmpty
            )
        }
    }

    @MainActor
    func testDurablePostprocessorRejectsEffectsFromSupersededSourceGeneration() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: false) { fixture in
            let gate = ProcessorSnapshotGate()
            let attempts = FailingProcessorProbe()
            let probe = ProcessorEventProbe()
            fixture.manager.registerFileProcessorBundle(
                identifier: "SourceGenerationFenceTest",
                fileProcessorVersion: 1,
                destinationProcessor: { _ in nil },
                readerFileURLProcessor: { _, _ in nil },
                contextualFileProcessor: { context in
                    let attempt = attempts.beginAttempt()
                    if attempt == 1 {
                        await gate.enterAndWait()
                    }
                    let title = attempt == 1 ? "Stale Source" : "Current Source"
                    let didApply = try await context.performCurrentWrite { _, contentFile in
                        contentFile.title = title
                        contentFile.refreshChangeMetadata(explicitlyModified: true)
                    }
                    probe.record("\(attempt):\(didApply)")
                }
            )

            let importTask = Task { @MainActor in
                try await fixture.manager.ensureImported(downloadable: fixture.downloadable)
            }
            await gate.waitUntilEntered()
            let importedFileURL = try XCTUnwrap(fixture.manager.localDrive)
                .rootDirectory
                .appendingPathComponent("Books/regression.epub")
            try Data("newer epub source generation".utf8).write(
                to: importedFileURL,
                options: .atomic
            )
            await gate.release()
            _ = try await importTask.value

            let configuration = ReaderContentLoader.historyRealmConfiguration
            let realm = try await Realm.open(configuration: configuration)
            XCTAssertEqual(probe.events, ["1:false", "2:true"])
            XCTAssertEqual(realm.objects(ContentFile.self).first?.title, "Current Source")
            XCTAssertTrue(
                realm.objects(ReaderFilePostprocessingWorkItem.self)
                    .where { $0.processorIdentifier == "SourceGenerationFenceTest" }
                    .isEmpty
            )
        }
    }

    @MainActor
    func testDurablePostprocessorCancellationRetainsWorkItem() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: false) { fixture in
            let gate = ProcessorSnapshotGate()
            fixture.manager.registerFileProcessorBundle(
                identifier: "CancellationWorkItemTest",
                fileProcessorVersion: 1,
                destinationProcessor: { _ in nil },
                readerFileURLProcessor: { _, _ in nil },
                contextualFileProcessor: { _ in
                    await gate.enterAndWait()
                }
            )

            let importTask = Task { @MainActor in
                try await fixture.manager.ensureImported(downloadable: fixture.downloadable)
            }
            await gate.waitUntilEntered()
            importTask.cancel()
            await gate.release()
            do {
                _ = try await importTask.value
                XCTFail("Expected cancellation to remain visible")
            } catch is CancellationError {
                // Expected.
            }

            let realm = try await Realm.open(
                configuration: ReaderContentLoader.historyRealmConfiguration
            )
            let workItem = try XCTUnwrap(
                realm.objects(ReaderFilePostprocessingWorkItem.self)
                    .where { $0.processorIdentifier == "CancellationWorkItemTest" }
                    .first
            )
            XCTAssertEqual(workItem.processorVersion, 1)
            XCTAssertFalse(workItem.attemptIdentifier.isEmpty)
        }
    }

    @MainActor
    func testDurablePostprocessorVersionUpgradeReplacesAndClearsOlderWorkItem() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: false) { fixture in
            fixture.manager.registerFileProcessorBundle(
                identifier: "VersionUpgradeTest",
                fileProcessorVersion: 1,
                destinationProcessor: { _ in nil },
                readerFileURLProcessor: { _, _ in nil },
                contextualFileProcessor: { _ in
                    throw TestError.postprocessorFailure
                }
            )

            do {
                _ = try await fixture.manager.ensureImported(
                    downloadable: fixture.downloadable
                )
                XCTFail("Expected version 1 to leave visible failure and a work item")
            } catch TestError.postprocessorFailure {
                // Expected.
            }

            let configuration = ReaderContentLoader.historyRealmConfiguration
            var realm = try await Realm.open(configuration: configuration)
            let version1WorkItem = try XCTUnwrap(
                realm.objects(ReaderFilePostprocessingWorkItem.self)
                    .where { $0.processorIdentifier == "VersionUpgradeTest" }
                    .first
            )
            XCTAssertEqual(version1WorkItem.processorVersion, 1)
            let version1AttemptIdentifier = version1WorkItem.attemptIdentifier
            let probe = ProcessorEventProbe()

            fixture.manager.registerFileProcessorBundle(
                identifier: "VersionUpgradeTest",
                fileProcessorVersion: 2,
                destinationProcessor: { _ in nil },
                readerFileURLProcessor: { _, _ in nil },
                contextualFileProcessor: { context in
                    let upgradedWorkItem = context.realm.objects(ReaderFilePostprocessingWorkItem.self)
                        .where { $0.processorIdentifier == "VersionUpgradeTest" }
                        .first
                    probe.record(
                        "version=\(upgradedWorkItem?.processorVersion ?? -1)," +
                        "attemptChanged=\(upgradedWorkItem?.attemptIdentifier != version1AttemptIdentifier)"
                    )
                    try await context.performCurrentWrite { _, contentFile in
                        contentFile.title = "Version 2"
                        contentFile.refreshChangeMetadata(explicitlyModified: true)
                    }
                }
            )

            try await fixture.manager.refreshAllFilesMetadata(force: true)

            realm = try await Realm.open(configuration: configuration)
            XCTAssertEqual(probe.events, ["version=2,attemptChanged=true"])
            XCTAssertEqual(realm.objects(ContentFile.self).first?.title, "Version 2")
            XCTAssertTrue(
                realm.objects(ReaderFilePostprocessingWorkItem.self)
                    .where { $0.processorIdentifier == "VersionUpgradeTest" }
                    .isEmpty
            )
        }
    }

    @MainActor
    func testDurablePostprocessingWorkItemSurvivesManagerReconstruction() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: false) { fixture in
            fixture.manager.registerFileProcessorBundle(
                identifier: "ManagerReconstructionTest",
                fileProcessorVersion: 1,
                destinationProcessor: { _ in nil },
                readerFileURLProcessor: { _, _ in nil },
                contextualFileProcessor: { _ in
                    throw TestError.postprocessorFailure
                }
            )

            do {
                _ = try await fixture.manager.ensureImported(
                    downloadable: fixture.downloadable
                )
                XCTFail("Expected the first manager to leave a durable work item")
            } catch TestError.postprocessorFailure {
                // Expected.
            }

            let configuration = ReaderContentLoader.historyRealmConfiguration
            var realm = try await Realm.open(configuration: configuration)
            let originalWorkItem = try XCTUnwrap(
                realm.objects(ReaderFilePostprocessingWorkItem.self)
                    .where { $0.processorIdentifier == "ManagerReconstructionTest" }
                    .first
            )
            let originalAttemptIdentifier = originalWorkItem.attemptIdentifier
            let rootURL = try XCTUnwrap(fixture.manager.localDrive).rootDirectory
            let reconstructedManager = ReaderFileManager(
                defaultLocalRootURLProvider: { rootURL }
            )
            reconstructedManager.localDrive = try await CloudDrive(
                storage: .localDirectory(rootURL: rootURL)
            )
            reconstructedManager.historyRealmConfigurationOverride = configuration
            EbookFileManager.configure(readerFileManager: reconstructedManager)
            let probe = ProcessorEventProbe()
            reconstructedManager.registerFileProcessorBundle(
                identifier: "ManagerReconstructionTest",
                fileProcessorVersion: 1,
                destinationProcessor: { _ in nil },
                readerFileURLProcessor: { _, _ in nil },
                contextualFileProcessor: { context in
                    let workItem = context.realm.objects(ReaderFilePostprocessingWorkItem.self)
                        .where { $0.processorIdentifier == "ManagerReconstructionTest" }
                        .first
                    probe.record(
                        "attemptChanged=\(workItem?.attemptIdentifier != originalAttemptIdentifier)"
                    )
                    try await context.performCurrentWrite { _, contentFile in
                        contentFile.title = "Reconstructed Manager"
                        contentFile.refreshChangeMetadata(explicitlyModified: true)
                    }
                }
            )

            try await reconstructedManager.refreshAllFilesMetadata(force: true)

            realm = try await Realm.open(configuration: configuration)
            XCTAssertEqual(probe.events, ["attemptChanged=true"])
            XCTAssertEqual(
                realm.objects(ContentFile.self).first?.title,
                "Reconstructed Manager"
            )
            XCTAssertTrue(
                realm.objects(ReaderFilePostprocessingWorkItem.self)
                    .where { $0.processorIdentifier == "ManagerReconstructionTest" }
                    .isEmpty
            )
        }
    }

    @MainActor
    func testPortablePostprocessingWorkItemRebindsToCurrentStorageScope() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: false) { fixture in
            let attempts = FailingProcessorProbe()
            fixture.manager.registerFileProcessorBundle(
                identifier: "PortableWorkItemTest",
                fileProcessorVersion: 1,
                destinationProcessor: { _ in nil },
                readerFileURLProcessor: { _, _ in nil },
                contextualFileProcessor: { context in
                    if attempts.beginAttempt() == 1 {
                        throw TestError.postprocessorFailure
                    }
                    try await context.performCurrentWrite { _, contentFile in
                        contentFile.title = "Portable Work Item Replayed"
                        contentFile.refreshChangeMetadata(explicitlyModified: true)
                    }
                }
            )

            do {
                _ = try await fixture.manager.ensureImported(
                    downloadable: fixture.downloadable
                )
                XCTFail("Expected the first attempt to retain a processor work item")
            } catch TestError.postprocessorFailure {
                // Expected.
            }

            let configuration = ReaderContentLoader.historyRealmConfiguration
            var realm = try await Realm.open(configuration: configuration)
            let workItem = try XCTUnwrap(
                realm.objects(ReaderFilePostprocessingWorkItem.self)
                    .where { $0.processorIdentifier == "PortableWorkItemTest" }
                    .first
            )
            let portableIdentifier = ReaderFilePostprocessingWorkItem
                .makePortableWorkItemIdentifier(
                    processorIdentifier: workItem.processorIdentifier,
                    contentFilePrimaryKey: workItem.contentFilePrimaryKey
                )
            try realm.write {
                let portableWorkItem = ReaderFilePostprocessingWorkItem()
                portableWorkItem.workItemIdentifier = portableIdentifier
                portableWorkItem.storageScopeIdentifier = ReaderFilePostprocessingWorkItem
                    .portableStorageScopeIdentifier
                portableWorkItem.processorIdentifier = workItem.processorIdentifier
                portableWorkItem.processorVersion = workItem.processorVersion
                portableWorkItem.contentFilePrimaryKey = workItem.contentFilePrimaryKey
                portableWorkItem.contentFileCreatedAt = workItem.contentFileCreatedAt
                portableWorkItem.readerFileURLString = workItem.readerFileURLString
                portableWorkItem.sourceModifiedAt = nil
                portableWorkItem.sourceFileSize = -1
                portableWorkItem.attemptIdentifier = ""
                portableWorkItem.enqueuedAt = workItem.enqueuedAt
                realm.add(portableWorkItem)
                realm.delete(workItem)
            }

            try await fixture.manager.refreshAllFilesMetadata(force: true)

            realm = try await Realm.open(configuration: configuration)
            XCTAssertEqual(attempts.attempts, 2)
            XCTAssertEqual(
                realm.objects(ContentFile.self).first?.title,
                "Portable Work Item Replayed"
            )
            XCTAssertTrue(
                realm.objects(ReaderFilePostprocessingWorkItem.self)
                    .where { $0.processorIdentifier == "PortableWorkItemTest" }
                    .isEmpty
            )
        }
    }

    @MainActor
    func testPortablePostprocessingWorkItemIsRemovedWhenContentFileBecomesOrphan() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: false) { fixture in
            fixture.manager.registerFileProcessorBundle(
                identifier: "PortableOrphanWorkItemTest",
                fileProcessorVersion: 1,
                destinationProcessor: { _ in nil },
                readerFileURLProcessor: { _, _ in nil },
                contextualFileProcessor: { _ in
                    throw TestError.postprocessorFailure
                }
            )

            do {
                _ = try await fixture.manager.ensureImported(
                    downloadable: fixture.downloadable
                )
                XCTFail("Expected the first attempt to retain a processor work item")
            } catch TestError.postprocessorFailure {
                // Expected.
            }

            let configuration = ReaderContentLoader.historyRealmConfiguration
            var realm = try await Realm.open(configuration: configuration)
            let workItem = try XCTUnwrap(
                realm.objects(ReaderFilePostprocessingWorkItem.self)
                    .where { $0.processorIdentifier == "PortableOrphanWorkItemTest" }
                    .first
            )
            let contentFilePrimaryKey = workItem.contentFilePrimaryKey
            let portableIdentifier = ReaderFilePostprocessingWorkItem
                .makePortableWorkItemIdentifier(
                    processorIdentifier: workItem.processorIdentifier,
                    contentFilePrimaryKey: contentFilePrimaryKey
                )
            try realm.write {
                let portableWorkItem = ReaderFilePostprocessingWorkItem()
                portableWorkItem.workItemIdentifier = portableIdentifier
                portableWorkItem.storageScopeIdentifier = ReaderFilePostprocessingWorkItem
                    .portableStorageScopeIdentifier
                portableWorkItem.processorIdentifier = workItem.processorIdentifier
                portableWorkItem.processorVersion = workItem.processorVersion
                portableWorkItem.contentFilePrimaryKey = contentFilePrimaryKey
                portableWorkItem.contentFileCreatedAt = workItem.contentFileCreatedAt
                portableWorkItem.readerFileURLString = workItem.readerFileURLString
                portableWorkItem.sourceModifiedAt = nil
                portableWorkItem.sourceFileSize = -1
                portableWorkItem.attemptIdentifier = ""
                portableWorkItem.enqueuedAt = workItem.enqueuedAt
                realm.add(portableWorkItem)
                realm.delete(workItem)
            }

            let importedFileURL = try XCTUnwrap(fixture.manager.localDrive)
                .rootDirectory
                .appendingPathComponent("Books/regression.epub")
            try FileManager.default.removeItem(at: importedFileURL)
            try await fixture.manager.refreshAllFilesMetadata(force: true)

            realm = try await Realm.open(configuration: configuration)
            XCTAssertTrue(
                try XCTUnwrap(
                    realm.object(
                        ofType: ContentFile.self,
                        forPrimaryKey: contentFilePrimaryKey
                    )
                ).isDeleted
            )
            XCTAssertTrue(
                realm.objects(ReaderFilePostprocessingWorkItem.self)
                    .where { $0.processorIdentifier == "PortableOrphanWorkItemTest" }
                    .isEmpty
            )
        }
    }

    @MainActor
    func testDurablePostprocessingWorkItemIsIsolatedByManagerRootAndRealm() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: false) { fixture in
            let secondBaseURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "DownloadableBookLibraryImportTests.SecondManager.\(UUID().uuidString)",
                    isDirectory: true
                )
            let secondRootURL = secondBaseURL.appendingPathComponent(
                "Library",
                isDirectory: true
            )
            let secondFileURL = secondRootURL.appendingPathComponent(
                "Books/regression.epub"
            )
            try FileManager.default.createDirectory(
                at: secondFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("second manager epub fixture".utf8).write(to: secondFileURL)
            addTeardownBlock {
                try? FileManager.default.removeItem(at: secondBaseURL)
            }

            let firstConfiguration = ReaderContentLoader.historyRealmConfiguration
            let secondConfiguration = makeHistoryRealmConfiguration()
            fixture.manager.historyRealmConfigurationOverride = firstConfiguration
            let secondManager = ReaderFileManager(
                defaultLocalRootURLProvider: { secondRootURL }
            )
            secondManager.localDrive = try await CloudDrive(
                storage: .localDirectory(rootURL: secondRootURL)
            )
            secondManager.historyRealmConfigurationOverride = secondConfiguration
            EbookFileManager.configure(readerFileManager: secondManager)

            let registerFailingProcessor: (ReaderFileManager) -> Void = { manager in
                manager.registerFileProcessorBundle(
                    identifier: "ManagerIsolationTest",
                    fileProcessorVersion: 1,
                    destinationProcessor: { _ in nil },
                    readerFileURLProcessor: { _, _ in nil },
                    contextualFileProcessor: { _ in
                        throw TestError.postprocessorFailure
                    }
                )
            }
            registerFailingProcessor(fixture.manager)
            registerFailingProcessor(secondManager)

            do {
                _ = try await fixture.manager.ensureImported(
                    downloadable: fixture.downloadable
                )
                XCTFail("Expected manager A to leave a durable work item")
            } catch TestError.postprocessorFailure {
                // Expected.
            }
            do {
                try await secondManager.refreshAllFilesMetadata(force: true)
                XCTFail("Expected manager B to leave a durable work item")
            } catch TestError.postprocessorFailure {
                // Expected.
            }

            var firstRealm = try await Realm.open(configuration: firstConfiguration)
            let secondRealm = try await Realm.open(configuration: secondConfiguration)
            let firstWorkItem = try XCTUnwrap(
                firstRealm.objects(ReaderFilePostprocessingWorkItem.self)
                    .where { $0.processorIdentifier == "ManagerIsolationTest" }
                    .first
            )
            let secondWorkItem = try XCTUnwrap(
                secondRealm.objects(ReaderFilePostprocessingWorkItem.self)
                    .where { $0.processorIdentifier == "ManagerIsolationTest" }
                    .first
            )
            XCTAssertEqual(firstWorkItem.contentFilePrimaryKey, secondWorkItem.contentFilePrimaryKey)
            XCTAssertNotEqual(
                firstWorkItem.storageScopeIdentifier,
                secondWorkItem.storageScopeIdentifier
            )
            XCTAssertNotEqual(firstWorkItem.workItemIdentifier, secondWorkItem.workItemIdentifier)

            fixture.manager.registerFileProcessorBundle(
                identifier: "ManagerIsolationTest",
                fileProcessorVersion: 1,
                destinationProcessor: { _ in nil },
                readerFileURLProcessor: { _, _ in nil },
                contextualFileProcessor: { context in
                    try await context.performCurrentWrite { _, contentFile in
                        contentFile.title = "Manager A Complete"
                        contentFile.refreshChangeMetadata(explicitlyModified: true)
                    }
                }
            )
            try await fixture.manager.refreshAllFilesMetadata(force: true)

            firstRealm = try await Realm.open(configuration: firstConfiguration)
            XCTAssertTrue(
                firstRealm.objects(ReaderFilePostprocessingWorkItem.self)
                    .where { $0.processorIdentifier == "ManagerIsolationTest" }
                    .isEmpty
            )
            XCTAssertEqual(
                secondRealm.objects(ReaderFilePostprocessingWorkItem.self)
                    .where { $0.processorIdentifier == "ManagerIsolationTest" }
                    .count,
                1
            )
            XCTAssertEqual(
                firstRealm.objects(ContentFile.self).first?.title,
                "Manager A Complete"
            )
            XCTAssertNotEqual(
                secondRealm.objects(ContentFile.self).first?.title,
                "Manager A Complete"
            )
        }
    }

    @MainActor
    func testPostprocessorContextCarriesOperationManagerAndRealm() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: false) { fixture in
            let probe = ProcessorEventProbe()
            fixture.manager.registerFileProcessorBundle(
                identifier: "PostprocessorContextTest",
                destinationProcessor: { _ in nil },
                readerFileURLProcessor: { _, _ in nil },
                contextualFileProcessor: { context in
                    let contextIdentifier = context.realmConfiguration.inMemoryIdentifier
                    let realmIdentifier = context.realm.configuration.inMemoryIdentifier
                    probe.record(
                        "manager=\(context.readerFileManager === fixture.manager)," +
                        "realm=\(contextIdentifier == realmIdentifier)," +
                        "files=\(context.contentFiles.count)"
                    )
                }
            )

            _ = try await fixture.manager.ensureImported(downloadable: fixture.downloadable)

            XCTAssertEqual(probe.events, [
                "manager=true,realm=true,files=1",
                "manager=true,realm=true,files=0",
            ])
        }
    }

    @MainActor
    func testEnsureImportedClassifiesLocalCandidateWhileSourceAccessIsActive() async throws {
        let sourceAccessProbe = SourceAccessProbe()
        let sourceAccess = ReaderFileSourceAccess(
            start: sourceAccessProbe.start,
            stop: sourceAccessProbe.stop
        )
        try await withFixture(
            downloadIsAlreadyInLibrary: false,
            downloadURL: URL(string: "https://example.com/download?id=mokuro")!,
            sourceAccess: sourceAccess
        ) { fixture in
            ReaderFileManager.fileDestinationProcessors.insert({ candidateURL in
                XCTAssertTrue(sourceAccessProbe.isActive)
                XCTAssertEqual(candidateURL, fixture.downloadable.localDestination)
                XCTAssertNotEqual(candidateURL, fixture.downloadable.url)
                sourceAccessProbe.events.append("classify:\(candidateURL.lastPathComponent)")
                return RootRelativePath(path: "Books")
            }, at: 0)

            let importedURL = try await fixture.manager.ensureImported(
                downloadable: fixture.downloadable
            )

            XCTAssertEqual(importedURL, fixture.expectedReaderURL)
            XCTAssertFalse(sourceAccessProbe.isActive)
            XCTAssertEqual(sourceAccessProbe.events, [
                "start:regression.epub",
                "classify:regression.epub",
                "stop:regression.epub",
            ])
        }
    }

    @MainActor
    func testEnsureImportedRejectsEscapingProcessorDestination() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: false) { fixture in
            ReaderFileManager.fileDestinationProcessors.insert({ _ in
                RootRelativePath(path: "../Escaped")
            }, at: 0)

            do {
                _ = try await fixture.manager.ensureImported(downloadable: fixture.downloadable)
                XCTFail("Expected an escaping destination to fail")
            } catch ReaderFileManagerError.invalidDestinationPath {
                // Expected.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }

            let escapedURL = try XCTUnwrap(fixture.manager.localDrive).rootDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("Escaped/regression.epub")
            XCTAssertFalse(FileManager.default.fileExists(atPath: escapedURL.path))
        }
    }

    @MainActor
    func testEnsureImportedRejectsAmbiguousProcessorDestinationsBeforeMutation() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: false) { fixture in
            ReaderFileManager.fileDestinationProcessors = [
                { _ in RootRelativePath(path: "First") },
                { _ in RootRelativePath(path: "Second") },
            ]

            do {
                _ = try await fixture.manager.ensureImported(downloadable: fixture.downloadable)
                XCTFail("Expected conflicting destination claims to fail")
            } catch ReaderFileManagerError.ambiguousDestinationPath {
                // Expected.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }

            let driveRootURL = try XCTUnwrap(fixture.manager.localDrive).rootDirectory
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: driveRootURL.appendingPathComponent("First/regression.epub").path
                )
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: driveRootURL.appendingPathComponent("Second/regression.epub").path
                )
            )
        }
    }

    @MainActor
    func testEnsureImportedRejectsDestinationSymlinkEscapingDriveRoot() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: false) { fixture in
            let driveRootURL = try XCTUnwrap(fixture.manager.localDrive).rootDirectory
            let outsideDirectoryURL = driveRootURL
                .deletingLastPathComponent()
                .appendingPathComponent("Outside", isDirectory: true)
            let redirectURL = driveRootURL
                .appendingPathComponent("Redirected", isDirectory: true)
            try FileManager.default.createDirectory(
                at: outsideDirectoryURL,
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                at: redirectURL,
                withDestinationURL: outsideDirectoryURL
            )
            ReaderFileManager.fileDestinationProcessors = [{ _ in
                RootRelativePath(path: "Redirected")
            }]

            do {
                _ = try await fixture.manager.ensureImported(downloadable: fixture.downloadable)
                XCTFail("Expected a symlink-escaping destination to fail")
            } catch ReaderFileManagerError.invalidDestinationPath {
                // Expected.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }

            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: outsideDirectoryURL
                        .appendingPathComponent("regression.epub")
                        .path
                )
            )
        }
    }

    @MainActor
    func testEnsureImportedStopsBeforeClassificationWhenSourceAccessThrows() async throws {
        let sourceAccess = ReaderFileSourceAccess(
            start: { _ in throw TestError.sourceAccessDenied },
            stop: { _ in XCTFail("A failed source-access start must not be stopped") }
        )
        try await withFixture(
            downloadIsAlreadyInLibrary: false,
            sourceAccess: sourceAccess
        ) { fixture in
            ReaderFileManager.fileDestinationProcessors.insert({ _ in
                XCTFail("Classification must not run without source access")
                return RootRelativePath(path: "Books")
            }, at: 0)

            do {
                _ = try await fixture.manager.ensureImported(downloadable: fixture.downloadable)
                XCTFail("Expected source-access failure")
            } catch TestError.sourceAccessDenied {
                // Expected.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    @MainActor
    func testReaderFileURLRejectsNonCanonicalProcessorURL() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: true) { fixture in
            let invalidProcessorURLs = [
                URL(string: "https://example.com/not-the-library-file")!,
                URL(string: "reader-file://file/load/local/Books/other.epub")!,
                URL(string: "ebook://ebook/load/local/Books/regression.epub?subpath=chapter.xhtml")!,
                URL(string: "ebook://ebook/load/local/Books/regression.epub#chapter")!,
                URL(string: "ttsu://reader/load/local/Books/regression.epub")!,
            ]

            for invalidProcessorURL in invalidProcessorURLs {
                ReaderFileManager.readerFileURLProcessors = [{ _, _ in
                    invalidProcessorURL
                }]
                do {
                    _ = try await fixture.manager.readerFileURL(for: fixture.downloadable)
                    XCTFail("Expected \(invalidProcessorURL) to fail")
                } catch ReaderFileManagerError.invalidReaderFileURL {
                    // Expected.
                } catch {
                    XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    @MainActor
    func testReaderFileURLRejectsAmbiguousProcessorClaims() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: true) { fixture in
            ReaderFileManager.readerFileURLProcessors = [
                { _, encodedPath in
                    URL(string: "ebook://ebook/load/" + encodedPath)
                },
                { _, encodedPath in
                    URL(string: "mokuro://mokuro/load/" + encodedPath)
                },
            ]

            do {
                _ = try await fixture.manager.readerFileURL(for: fixture.downloadable)
                XCTFail("Expected conflicting reader-URL claims to fail")
            } catch ReaderFileManagerError.ambiguousReaderFileURL {
                // Expected.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    @MainActor
    func testUnclassifiedRemoteDownloadStagesThenRoutesReadableLocalCandidate() async throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DownloadableBookLibraryImportTests.\(UUID().uuidString)",
                isDirectory: true
            )
        let libraryRootURL = baseURL.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryRootURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: baseURL)
        }

        let previousHistoryConfiguration = ReaderContentLoader.historyRealmConfiguration
        let previousSharedManager = ReaderFileManager.shared
        let previousFileDestinationProcessors = ReaderFileManager.fileDestinationProcessors
        let previousReaderFileURLProcessors = ReaderFileManager.readerFileURLProcessors
        let previousFileProcessors = ReaderFileManager.fileProcessors
        defer {
            ReaderContentLoader.historyRealmConfiguration = previousHistoryConfiguration
            ReaderFileManager.shared = previousSharedManager
            ReaderFileManager.fileDestinationProcessors = previousFileDestinationProcessors
            ReaderFileManager.readerFileURLProcessors = previousReaderFileURLProcessors
            ReaderFileManager.fileProcessors = previousFileProcessors
        }

        let manager = ReaderFileManager(defaultLocalRootURLProvider: { libraryRootURL })
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: libraryRootURL))
        ReaderFileManager.shared = manager
        ReaderContentLoader.historyRealmConfiguration = makeHistoryRealmConfiguration()
        EbookFileManager.configure(readerFileManager: manager)

        let destinationProbe = DestinationProbe()
        ReaderFileManager.fileDestinationProcessors = [{ candidateURL in
            destinationProbe.record(candidateURL)
            return candidateURL.isFileURL ? RootRelativePath(path: "Manga") : nil
        }]
        ReaderFileManager.readerFileURLProcessors = []
        ReaderFileManager.fileProcessors = []

        let remoteEbookURL = URL(string: "https://example.com/releases/regression.epub")!
        let pendingEbookDownload = try await manager.downloadable(
            url: remoteEbookURL,
            name: "Regression Book"
        )
        let ebookDownload = try XCTUnwrap(pendingEbookDownload)
        XCTAssertEqual(
            ebookDownload.localDestination.standardizedFileURL.path,
            libraryRootURL.appendingPathComponent("Books/regression.epub").standardizedFileURL.path
        )

        let remoteURL = URL(string: "https://example.com/releases/regression.zip")!
        let pendingDownload = try await manager.downloadable(
            url: remoteURL,
            name: "Regression Manga"
        )
        let downloadable = try XCTUnwrap(pendingDownload)
        let stagingDirectoryName = downloadable.localDestination
            .deletingLastPathComponent()
            .lastPathComponent
        XCTAssertTrue(stagingDirectoryName.hasPrefix("ReaderFileDownload."))
        XCTAssertTrue(
            ReaderFileManager.shouldSkipDiscoveredRelativePath(
                "\(stagingDirectoryName)/\(downloadable.localDestination.lastPathComponent)"
            )
        )

        try FileManager.default.createDirectory(
            at: downloadable.localDestination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("locally readable ZIP fixture".utf8).write(to: downloadable.localDestination)

        try await manager.refreshAllFilesMetadata(force: true)
        let stagingRealm = try await Realm.open(
            configuration: ReaderContentLoader.historyRealmConfiguration
        )
        XCTAssertEqual(stagingRealm.objects(ContentFile.self).where { !$0.isDeleted }.count, 0)
        XCTAssertEqual(manager.files?.count, 0)

        let importedURL = try await manager.ensureImported(downloadable: downloadable)
        let expectedReaderURL = URL(
            string: "reader-file://file/load/local/Manga/regression.zip"
        )!
        XCTAssertEqual(importedURL, expectedReaderURL)
        XCTAssertEqual(destinationProbe.candidates, [downloadable.localDestination])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: libraryRootURL.appendingPathComponent("Manga/regression.zip").path
            )
        )
        XCTAssertEqual(manager.files?.map(\.url), [expectedReaderURL])

        let realm = try await Realm.open(
            configuration: ReaderContentLoader.historyRealmConfiguration
        )
        XCTAssertEqual(realm.objects(ContentFile.self).where { !$0.isDeleted }.count, 1)
        XCTAssertEqual(
            realm.objects(ContentFile.self).where { !$0.isDeleted }.first?.url,
            expectedReaderURL
        )
    }

    @MainActor
    func testEnsureImportedIndexesDownloadAlreadyStoredInBookLibrary() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: true) { fixture in
            let readerURLBeforeImport = try await fixture.manager.readerFileURL(for: fixture.downloadable)
            XCTAssertEqual(readerURLBeforeImport, fixture.expectedReaderURL)
            XCTAssertNil(fixture.manager.files(ofTypes: [.epub, .epubZip]))

            let importedURL = try await assertEnsureImportedIndexesRealmMetadata(fixture)
            XCTAssertEqual(importedURL, fixture.expectedReaderURL)
            XCTAssertEqual(
                fixture.manager.files(ofTypes: [.epub, .epubZip])?.map(\.url),
                [fixture.expectedReaderURL]
            )
        }
    }

    @MainActor
    func testRefreshDownloadedEditorsPicksPublishesExistingLibraryDownload() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: true) { fixture in
            let publication = Publication(
                title: fixture.downloadable.name,
                downloadURL: fixture.downloadable.url
            )
            let outcome = await BookLibraryViewModel.refreshDownloadedEditorsPicks(
                publications: [publication],
                readerFileManager: fixture.manager
            )

            XCTAssertEqual(outcome.outcomes[publication.id], .imported(fixture.expectedReaderURL))
            XCTAssertEqual(
                fixture.manager.files(ofTypes: [.epub, .epubZip])?.map(\.url),
                [fixture.expectedReaderURL]
            )
        }
    }

    @MainActor
    func testRefreshDownloadedEditorsPicksReportsMissingAcquisitionAlongsideImportedBook() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: true) { fixture in
            let importedPublication = Publication(
                title: fixture.downloadable.name,
                downloadURL: fixture.downloadable.url
            )
            let unavailablePublication = Publication(title: "Unavailable Book")

            let outcome = await BookLibraryViewModel.refreshDownloadedEditorsPicks(
                publications: [unavailablePublication, importedPublication],
                readerFileManager: fixture.manager
            )

            XCTAssertEqual(
                outcome.outcomes[unavailablePublication.id],
                .failed(.noAcquisition)
            )
            XCTAssertEqual(
                outcome.outcomes[importedPublication.id],
                .imported(fixture.expectedReaderURL)
            )
            XCTAssertEqual(
                fixture.manager.files(ofTypes: [.epub, .epubZip])?.map(\.url),
                [fixture.expectedReaderURL]
            )
        }
    }

    @MainActor
    func testCatalogBookCommandReplacementRejectsCancellationIgnoringOlderCompletion() async throws {
        let viewModel = BookLibraryViewModel()
        let publication = Publication(
            title: "Generation Book",
            downloadURL: URL(string: "https://example.com/generation.epub")!
        )
        let olderURL = URL(string: "ebook://ebook/load/local/older.epub")!
        let newerURL = URL(string: "ebook://ebook/load/local/newer.epub")!
        let gate = ProcessorSnapshotGate()
        var olderClaimWasCurrentAfterReplacement = true

        let olderTask = try XCTUnwrap(viewModel.startCatalogBookCommand(
            publication: publication,
            supersedingExisting: true,
            presentsFailures: true
        ) { claim in
            await gate.enterAndWait()
            olderClaimWasCurrentAfterReplacement = claim.isCurrent()
            return .imported(olderURL)
        })
        await gate.waitUntilEntered()

        let newerTask = try XCTUnwrap(viewModel.startCatalogBookCommand(
            publication: publication,
            supersedingExisting: true,
            presentsFailures: true
        ) { _ in
            .imported(newerURL)
        })
        await newerTask.value
        await gate.release()
        await olderTask.value

        XCTAssertFalse(olderClaimWasCurrentAfterReplacement)
        XCTAssertEqual(viewModel.catalogBookOutcomes[publication.id], .imported(newerURL))
        XCTAssertNil(viewModel.catalogBookErrorMessage(for: publication))
    }

    @MainActor
    func testCatalogBookCommandErrorsAreScopedAndCurrentSuccessClearsOnlyItsRow() async throws {
        let viewModel = BookLibraryViewModel()
        let first = Publication(
            title: "First Book",
            downloadURL: URL(string: "https://example.com/first.epub")!
        )
        let second = Publication(
            title: "Second Book",
            downloadURL: URL(string: "https://example.com/second.epub")!
        )
        let importedURL = URL(string: "ebook://ebook/load/local/first.epub")!

        let firstFailure = try XCTUnwrap(viewModel.startCatalogBookCommand(
            publication: first,
            supersedingExisting: true,
            presentsFailures: true
        ) { _ in
            .failed(.importFailed("First import failed."))
        })
        let secondFailure = try XCTUnwrap(viewModel.startCatalogBookCommand(
            publication: second,
            supersedingExisting: true,
            presentsFailures: true
        ) { _ in
            .failed(.missingImportResult)
        })
        await firstFailure.value
        await secondFailure.value

        XCTAssertEqual(viewModel.catalogBookErrorMessage(for: first), "First import failed.")
        XCTAssertEqual(
            viewModel.catalogBookErrorMessage(for: second),
            "The downloaded book could not be added to your library."
        )

        let firstRetry = try XCTUnwrap(viewModel.startCatalogBookCommand(
            publication: first,
            supersedingExisting: true,
            presentsFailures: true
        ) { _ in
            .imported(importedURL)
        })
        await firstRetry.value

        XCTAssertNil(viewModel.catalogBookErrorMessage(for: first))
        XCTAssertNotNil(viewModel.catalogBookErrorMessage(for: second))
    }

    @MainActor
    func testCatalogBookAutomaticCommandJoinsSameManagerAndReplacementManagerRevokesIt() async throws {
        let viewModel = BookLibraryViewModel()
        let publication = Publication(
            title: "Scoped Book",
            downloadURL: URL(string: "https://example.com/scoped.epub")!
        )
        let firstManager = NSObject()
        let replacementManager = NSObject()
        let firstManagerIdentity = ObjectIdentifier(firstManager)
        let replacementManagerIdentity = ObjectIdentifier(replacementManager)
        let staleURL = URL(string: "ebook://ebook/load/local/stale.epub")!
        let currentURL = URL(string: "ebook://ebook/load/local/current.epub")!
        let gate = ProcessorSnapshotGate()
        var joinedOperationCount = 0

        let firstTask = try XCTUnwrap(viewModel.startCatalogBookCommand(
            publication: publication,
            supersedingExisting: false,
            presentsFailures: false,
            managerIdentity: firstManagerIdentity
        ) { _ in
            await gate.enterAndWait()
            return .imported(staleURL)
        })
        await gate.waitUntilEntered()

        let joinedTask = try XCTUnwrap(viewModel.startCatalogBookCommand(
            publication: publication,
            supersedingExisting: false,
            presentsFailures: false,
            managerIdentity: firstManagerIdentity
        ) { _ in
            joinedOperationCount += 1
            return .failed(.unavailable)
        })
        let replacementTask = try XCTUnwrap(viewModel.startCatalogBookCommand(
            publication: publication,
            supersedingExisting: false,
            presentsFailures: false,
            managerIdentity: replacementManagerIdentity
        ) { _ in
            .imported(currentURL)
        })
        await replacementTask.value
        await gate.release()
        await firstTask.value
        await joinedTask.value

        XCTAssertEqual(joinedOperationCount, 0)
        XCTAssertEqual(viewModel.catalogBookOutcomes[publication.id], .imported(currentURL))
    }

    @MainActor
    func testCancellingCatalogBookCommandsRetiresLoadAdmissionAndSuppressesOutcome() async throws {
        let viewModel = BookLibraryViewModel()
        let publication = Publication(
            title: "Cancelled Book",
            downloadURL: URL(string: "https://example.com/cancelled.epub")!
        )
        let gate = ProcessorSnapshotGate()
        var claim: BookLibraryViewModel.CatalogBookCommandClaim?

        let task = try XCTUnwrap(viewModel.startCatalogBookCommand(
            publication: publication,
            supersedingExisting: true,
            presentsFailures: true
        ) { commandClaim in
            claim = commandClaim
            await gate.enterAndWait()
            return .failed(.loadFailed("late failure"))
        })
        await gate.waitUntilEntered()

        viewModel.cancelCatalogBookCommands()
        XCTAssertThrowsError(try XCTUnwrap(claim).admission.checkActive()) { error in
            XCTAssertTrue(error is CancellationError)
        }
        await gate.release()
        await task.value

        XCTAssertNil(viewModel.catalogBookOutcomes[publication.id])
        XCTAssertNil(viewModel.catalogBookErrorMessage(for: publication))
    }

    @MainActor
    func testManualBookImportRejectsCancellationIgnoringCompletionAfterHostReplacement() async throws {
        let modals = BookLibraryModalsModel()
        let manager = ReaderFileManager()
        let firstHost = NSObject()
        let replacementHost = NSObject()
        let selectedURL = URL(fileURLWithPath: "/tmp/selected.epub")
        let staleURL = URL(string: "ebook://ebook/load/local/stale.epub")!
        let currentURL = URL(string: "ebook://ebook/load/local/current.epub")!
        let gate = ProcessorSnapshotGate()

        modals.activateManualBookImportHost(firstHost, readerFileManager: manager)
        modals.handleManualBookFileImporterResult(
            .success(selectedURL),
            host: firstHost,
            readerFileManager: manager
        ) { _ in
            await gate.enterAndWait()
            return staleURL
        }
        await gate.waitUntilEntered()

        modals.activateManualBookImportHost(replacementHost, readerFileManager: manager)
        modals.handleManualBookFileImporterResult(
            .success(selectedURL),
            host: replacementHost,
            readerFileManager: manager
        ) { _ in
            currentURL
        }
        await Task.yield()
        await gate.release()
        await Task.yield()

        XCTAssertEqual(modals.manualBookImportOutcome, .imported(currentURL))
        XCTAssertNil(modals.manualBookImportFailure)
    }

    @MainActor
    func testManualBookImportRejectsCallbackFromReplacedHost() async {
        let modals = BookLibraryModalsModel()
        let manager = ReaderFileManager()
        let firstHost = NSObject()
        let replacementHost = NSObject()
        let selectedURL = URL(fileURLWithPath: "/tmp/selected.epub")
        var didStartImport = false

        modals.activateManualBookImportHost(firstHost, readerFileManager: manager)
        modals.activateManualBookImportHost(replacementHost, readerFileManager: manager)
        modals.handleManualBookFileImporterResult(
            .success(selectedURL),
            host: firstHost,
            readerFileManager: manager
        ) { _ in
            didStartImport = true
            return URL(string: "ebook://ebook/load/local/stale.epub")!
        }
        await Task.yield()

        XCTAssertFalse(didStartImport)
        XCTAssertNil(modals.manualBookImportOutcome)
        XCTAssertNil(modals.manualBookImportFailure)
    }

    @MainActor
    func testManualBookImportManagerReplacementRevokesOlderWork() async throws {
        let modals = BookLibraryModalsModel()
        let firstManager = ReaderFileManager()
        let replacementManager = ReaderFileManager()
        let host = NSObject()
        let selectedURL = URL(fileURLWithPath: "/tmp/selected.epub")
        let staleURL = URL(string: "ebook://ebook/load/local/stale.epub")!
        let currentURL = URL(string: "ebook://ebook/load/local/current.epub")!
        let gate = ProcessorSnapshotGate()

        modals.activateManualBookImportHost(host, readerFileManager: firstManager)
        modals.handleManualBookFileImporterResult(
            .success(selectedURL),
            host: host,
            readerFileManager: firstManager
        ) { _ in
            await gate.enterAndWait()
            return staleURL
        }
        await gate.waitUntilEntered()

        modals.activateManualBookImportHost(host, readerFileManager: replacementManager)
        modals.handleManualBookFileImporterResult(
            .success(selectedURL),
            host: host,
            readerFileManager: replacementManager
        ) { _ in
            currentURL
        }
        await Task.yield()
        await gate.release()
        await Task.yield()

        XCTAssertEqual(modals.manualBookImportOutcome, .imported(currentURL))
    }

    @MainActor
    func testManualBookImportHostDeactivationSuppressesLateFailure() async throws {
        let modals = BookLibraryModalsModel()
        let manager = ReaderFileManager()
        let host = NSObject()
        let gate = ProcessorSnapshotGate()
        let selectedURL = URL(fileURLWithPath: "/tmp/selected.epub")

        modals.activateManualBookImportHost(host, readerFileManager: manager)
        modals.handleManualBookFileImporterResult(.success(selectedURL), host: host, readerFileManager: manager) { _ in
            await gate.enterAndWait()
            throw TestError.postprocessorFailure
        }
        await gate.waitUntilEntered()
        modals.deactivateManualBookImportHost(host)
        await gate.release()
        await Task.yield()

        XCTAssertNil(modals.manualBookImportOutcome)
        XCTAssertNil(modals.manualBookImportFailure)
    }

    @MainActor
    func testManualBookImportFailureThenSuccessClearsOnlyManualImportError() async throws {
        let modals = BookLibraryModalsModel()
        let manager = ReaderFileManager()
        let host = NSObject()
        let selectedURL = URL(fileURLWithPath: "/tmp/selected.epub")
        let importedURL = URL(string: "ebook://ebook/load/local/imported.epub")!

        modals.activateManualBookImportHost(host, readerFileManager: manager)
        modals.handleManualBookFileImporterResult(.success(selectedURL), host: host, readerFileManager: manager) { _ in
            nil
        }
        await Task.yield()
        XCTAssertEqual(modals.manualBookImportFailure, .missingImportResult)

        modals.handleManualBookFileImporterResult(.success(selectedURL), host: host, readerFileManager: manager) { _ in
            importedURL
        }
        await Task.yield()
        XCTAssertEqual(modals.manualBookImportOutcome, .imported(importedURL))
        XCTAssertNil(modals.manualBookImportFailure)
    }

    @MainActor
    func testManualBookImportHostReplacementClearsPriorPresentation() async {
        let modals = BookLibraryModalsModel()
        let manager = ReaderFileManager()
        let firstHost = NSObject()
        let replacementHost = NSObject()
        let selectedURL = URL(fileURLWithPath: "/tmp/selected.epub")

        modals.activateManualBookImportHost(firstHost, readerFileManager: manager)
        modals.handleManualBookFileImporterResult(
            .success(selectedURL),
            host: firstHost,
            readerFileManager: manager
        ) { _ in nil }
        await Task.yield()
        XCTAssertEqual(modals.manualBookImportFailure, .missingImportResult)

        modals.activateManualBookImportHost(replacementHost, readerFileManager: manager)

        XCTAssertNil(modals.manualBookImportOutcome)
        XCTAssertNil(modals.manualBookImportFailure)
        XCTAssertFalse(modals.canRetryManualBookImport)
    }

    @MainActor
    private func assertEnsureImportedIndexesBook(_ fixture: Fixture) async throws {
        let importedURL = try await assertEnsureImportedIndexesRealmMetadata(fixture)
        XCTAssertEqual(importedURL, fixture.expectedReaderURL)
        XCTAssertEqual(
            fixture.manager.files(ofTypes: [.epub, .epubZip])?.map(\.url),
            [fixture.expectedReaderURL]
        )
    }

    @MainActor
    private func assertEnsureImportedIndexesRealmMetadata(_ fixture: Fixture) async throws -> URL? {
        let importedURL = try await fixture.manager.ensureImported(downloadable: fixture.downloadable)
        let realm = try await Realm.open(configuration: ReaderContentLoader.historyRealmConfiguration)
        let contentFile = try XCTUnwrap(
            realm.objects(ContentFile.self)
                .filter(
                    NSPredicate(
                        format: "isDeleted == false AND url == %@",
                        fixture.expectedReaderURL.absoluteString
                    )
                )
                .first
        )
        XCTAssertEqual(contentFile.mimeType, "application/epub+zip")
        return importedURL
    }
}
