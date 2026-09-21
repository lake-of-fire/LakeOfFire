import XCTest
import RealmSwift
import SwiftCloudDrive
import SwiftUIDownloads
@testable import LakeOfFireContent
@testable import LakeOfFireReader

final class DownloadableBookLibraryImportTests: XCTestCase {
    private enum TestError: Swift.Error {
        case sourceAccessDenied
        case postprocessorFailure
    }

    private struct Fixture {
        let manager: ReaderFileManager
        let downloadable: Downloadable
        let expectedReaderURL: URL
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
            ReaderFilePostprocessorDebt.self,
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
            sourceAccess: sourceAccess
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
            let drive = try XCTUnwrap(fixture.manager.localDrive)
            let sourceURL = drive.rootDirectory.appendingPathComponent("crash.epub")
            let targetURL = drive.rootDirectory.appendingPathComponent("Books/crash.epub")
            try FileManager.default.copyItem(
                at: fixture.downloadable.localDestination,
                to: sourceURL
            )
            try FileManager.default.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: sourceURL, to: targetURL)
            try await fixture.manager.refreshAllFilesMetadata(force: true)

            let configuration = ReaderContentLoader.historyRealmConfiguration
            let realm = try await Realm.open(configuration: configuration)
            let sourceReaderURL = try XCTUnwrap(
                URL(string: "ebook://ebook/load/local/crash.epub")
            )
            let targetReaderURL = try XCTUnwrap(
                URL(string: "ebook://ebook/load/local/Books/crash.epub")
            )
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
            let sourceAttributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
            let targetAttributes = try FileManager.default.attributesOfItem(atPath: targetURL.path)
            let storageScope = [
                "memory:\(try XCTUnwrap(configuration.inMemoryIdentifier))",
                drive.rootDirectory.standardizedFileURL.absoluteString,
                "local",
            ]
                .map { "\($0.utf8.count):\($0)" }
                .joined(separator: "|")
            let receipt = ReaderFileLegacyRootRelocationReceipt()
            receipt.storageScopeIdentifier = storageScope
            receipt.sourceRelativePath = "crash.epub"
            receipt.sourceReaderBackingURLString = "reader-file://file/load/local/crash.epub"
            receipt.sourceContentFilePrimaryKey = source.compoundKey
            receipt.sourceContentFileCreatedAt = source.createdAt
            receipt.sourceModifiedAt = sourceAttributes[.modificationDate] as? Date
            receipt.sourceFileSize = (sourceAttributes[.size] as? NSNumber)?.int64Value ?? -1
            receipt.targetReaderURLString = targetReaderURL.absoluteString
            receipt.targetContentFilePrimaryKey = target.compoundKey
            receipt.targetContentFileCreatedAt = target.createdAt
            receipt.targetModifiedAt = targetAttributes[.modificationDate] as? Date
            receipt.targetFileSize = (targetAttributes[.size] as? NSNumber)?.int64Value ?? -1
            receipt.receiptIdentifier = ReaderFileLegacyRootRelocationReceipt
                .makeReceiptIdentifier(
                    storageScopeIdentifier: storageScope,
                    sourceRelativePath: receipt.sourceRelativePath,
                    sourceContentFilePrimaryKey: source.compoundKey
                )
            try realm.write {
                realm.add(receipt)
                source.isDeleted = true
                source.refreshChangeMetadata(explicitlyModified: true)
            }
            try FileManager.default.removeItem(at: sourceURL)

            try await fixture.manager.refreshAllFilesMetadata(force: true)
            XCTAssertTrue(
                realm.objects(ReaderFileLegacyRootRelocationReceipt.self).isEmpty
            )
            XCTAssertTrue(
                realm.object(ofType: ContentFile.self, forPrimaryKey: target.compoundKey)?.isDeleted == false
            )
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
        let firstDownloadable = try await firstManager.downloadable(
            url: remoteEbookURL,
            name: "First Remote"
        )
        let secondDownloadable = try await secondManager.downloadable(
            url: remoteEbookURL,
            name: "Second Remote"
        )
        XCTAssertEqual(
            firstDownloadable?.localDestination.deletingLastPathComponent().lastPathComponent,
            "Books"
        )
        XCTAssertTrue(
            secondDownloadable?.localDestination
                .deletingLastPathComponent()
                .lastPathComponent
                .hasPrefix("ReaderFileDownload.") == true
        )
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
    func testDurablePostprocessorDebtRetriesAnUnchangedFileAndClearsAfterSuccess() async throws {
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
            let debt = try XCTUnwrap(
                realm.objects(ReaderFilePostprocessorDebt.self)
                    .where { $0.processorIdentifier == "DurableRetryTest" }
                    .first
            )
            XCTAssertEqual(debt.processorVersion, 1)
            XCTAssertEqual(debt.readerFileURLString, fixture.expectedReaderURL.absoluteString)
            let firstAttemptIdentifier = debt.attemptIdentifier

            try await fixture.manager.refreshAllFilesMetadata(force: true)

            realm = try await Realm.open(configuration: configuration)
            XCTAssertEqual(probe.attempts, 2)
            XCTAssertTrue(
                realm.objects(ReaderFilePostprocessorDebt.self)
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
                realm.objects(ReaderFilePostprocessorDebt.self)
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
                realm.objects(ReaderFilePostprocessorDebt.self)
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
                realm.objects(ReaderFilePostprocessorDebt.self)
                    .where { $0.processorIdentifier == "SourceGenerationFenceTest" }
                    .isEmpty
            )
        }
    }

    @MainActor
    func testDurablePostprocessorCancellationRetainsDebt() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: false) { fixture in
            let gate = ProcessorSnapshotGate()
            fixture.manager.registerFileProcessorBundle(
                identifier: "CancellationDebtTest",
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
            let debt = try XCTUnwrap(
                realm.objects(ReaderFilePostprocessorDebt.self)
                    .where { $0.processorIdentifier == "CancellationDebtTest" }
                    .first
            )
            XCTAssertEqual(debt.processorVersion, 1)
            XCTAssertFalse(debt.attemptIdentifier.isEmpty)
        }
    }

    @MainActor
    func testDurablePostprocessorVersionUpgradeReplacesAndClearsOlderDebt() async throws {
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
                XCTFail("Expected version 1 to leave visible failure and debt")
            } catch TestError.postprocessorFailure {
                // Expected.
            }

            let configuration = ReaderContentLoader.historyRealmConfiguration
            var realm = try await Realm.open(configuration: configuration)
            let version1Debt = try XCTUnwrap(
                realm.objects(ReaderFilePostprocessorDebt.self)
                    .where { $0.processorIdentifier == "VersionUpgradeTest" }
                    .first
            )
            XCTAssertEqual(version1Debt.processorVersion, 1)
            let version1AttemptIdentifier = version1Debt.attemptIdentifier
            let probe = ProcessorEventProbe()

            fixture.manager.registerFileProcessorBundle(
                identifier: "VersionUpgradeTest",
                fileProcessorVersion: 2,
                destinationProcessor: { _ in nil },
                readerFileURLProcessor: { _, _ in nil },
                contextualFileProcessor: { context in
                    let upgradedDebt = context.realm.objects(ReaderFilePostprocessorDebt.self)
                        .where { $0.processorIdentifier == "VersionUpgradeTest" }
                        .first
                    probe.record(
                        "version=\(upgradedDebt?.processorVersion ?? -1)," +
                        "attemptChanged=\(upgradedDebt?.attemptIdentifier != version1AttemptIdentifier)"
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
                realm.objects(ReaderFilePostprocessorDebt.self)
                    .where { $0.processorIdentifier == "VersionUpgradeTest" }
                    .isEmpty
            )
        }
    }

    @MainActor
    func testDurablePostprocessorDebtSurvivesManagerReconstruction() async throws {
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
                XCTFail("Expected the first manager to leave durable debt")
            } catch TestError.postprocessorFailure {
                // Expected.
            }

            let configuration = ReaderContentLoader.historyRealmConfiguration
            var realm = try await Realm.open(configuration: configuration)
            let originalDebt = try XCTUnwrap(
                realm.objects(ReaderFilePostprocessorDebt.self)
                    .where { $0.processorIdentifier == "ManagerReconstructionTest" }
                    .first
            )
            let originalAttemptIdentifier = originalDebt.attemptIdentifier
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
                    let debt = context.realm.objects(ReaderFilePostprocessorDebt.self)
                        .where { $0.processorIdentifier == "ManagerReconstructionTest" }
                        .first
                    probe.record(
                        "attemptChanged=\(debt?.attemptIdentifier != originalAttemptIdentifier)"
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
                realm.objects(ReaderFilePostprocessorDebt.self)
                    .where { $0.processorIdentifier == "ManagerReconstructionTest" }
                    .isEmpty
            )
        }
    }

    @MainActor
    func testPortablePostprocessorDebtRebindsToCurrentStorageScope() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: false) { fixture in
            let attempts = FailingProcessorProbe()
            fixture.manager.registerFileProcessorBundle(
                identifier: "PortableDebtTest",
                fileProcessorVersion: 1,
                destinationProcessor: { _ in nil },
                readerFileURLProcessor: { _, _ in nil },
                contextualFileProcessor: { context in
                    if attempts.beginAttempt() == 1 {
                        throw TestError.postprocessorFailure
                    }
                    try await context.performCurrentWrite { _, contentFile in
                        contentFile.title = "Portable Debt Replayed"
                        contentFile.refreshChangeMetadata(explicitlyModified: true)
                    }
                }
            )

            do {
                _ = try await fixture.manager.ensureImported(
                    downloadable: fixture.downloadable
                )
                XCTFail("Expected the first attempt to retain processor debt")
            } catch TestError.postprocessorFailure {
                // Expected.
            }

            let configuration = ReaderContentLoader.historyRealmConfiguration
            var realm = try await Realm.open(configuration: configuration)
            let debt = try XCTUnwrap(
                realm.objects(ReaderFilePostprocessorDebt.self)
                    .where { $0.processorIdentifier == "PortableDebtTest" }
                    .first
            )
            let portableIdentifier = ReaderFilePostprocessorDebt
                .makePortableDebtIdentifier(
                    processorIdentifier: debt.processorIdentifier,
                    contentFilePrimaryKey: debt.contentFilePrimaryKey
                )
            try realm.write {
                let portableDebt = ReaderFilePostprocessorDebt()
                portableDebt.debtIdentifier = portableIdentifier
                portableDebt.storageScopeIdentifier = ReaderFilePostprocessorDebt
                    .portableStorageScopeIdentifier
                portableDebt.processorIdentifier = debt.processorIdentifier
                portableDebt.processorVersion = debt.processorVersion
                portableDebt.contentFilePrimaryKey = debt.contentFilePrimaryKey
                portableDebt.contentFileCreatedAt = debt.contentFileCreatedAt
                portableDebt.readerFileURLString = debt.readerFileURLString
                portableDebt.sourceModifiedAt = nil
                portableDebt.sourceFileSize = -1
                portableDebt.attemptIdentifier = ""
                portableDebt.enqueuedAt = debt.enqueuedAt
                realm.add(portableDebt)
                realm.delete(debt)
            }

            try await fixture.manager.refreshAllFilesMetadata(force: true)

            realm = try await Realm.open(configuration: configuration)
            XCTAssertEqual(attempts.attempts, 2)
            XCTAssertEqual(
                realm.objects(ContentFile.self).first?.title,
                "Portable Debt Replayed"
            )
            XCTAssertTrue(
                realm.objects(ReaderFilePostprocessorDebt.self)
                    .where { $0.processorIdentifier == "PortableDebtTest" }
                    .isEmpty
            )
        }
    }

    @MainActor
    func testPortablePostprocessorDebtIsRemovedWhenContentFileBecomesOrphan() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: false) { fixture in
            fixture.manager.registerFileProcessorBundle(
                identifier: "PortableOrphanDebtTest",
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
                XCTFail("Expected the first attempt to retain processor debt")
            } catch TestError.postprocessorFailure {
                // Expected.
            }

            let configuration = ReaderContentLoader.historyRealmConfiguration
            var realm = try await Realm.open(configuration: configuration)
            let debt = try XCTUnwrap(
                realm.objects(ReaderFilePostprocessorDebt.self)
                    .where { $0.processorIdentifier == "PortableOrphanDebtTest" }
                    .first
            )
            let contentFilePrimaryKey = debt.contentFilePrimaryKey
            let portableIdentifier = ReaderFilePostprocessorDebt
                .makePortableDebtIdentifier(
                    processorIdentifier: debt.processorIdentifier,
                    contentFilePrimaryKey: contentFilePrimaryKey
                )
            try realm.write {
                let portableDebt = ReaderFilePostprocessorDebt()
                portableDebt.debtIdentifier = portableIdentifier
                portableDebt.storageScopeIdentifier = ReaderFilePostprocessorDebt
                    .portableStorageScopeIdentifier
                portableDebt.processorIdentifier = debt.processorIdentifier
                portableDebt.processorVersion = debt.processorVersion
                portableDebt.contentFilePrimaryKey = contentFilePrimaryKey
                portableDebt.contentFileCreatedAt = debt.contentFileCreatedAt
                portableDebt.readerFileURLString = debt.readerFileURLString
                portableDebt.sourceModifiedAt = nil
                portableDebt.sourceFileSize = -1
                portableDebt.attemptIdentifier = ""
                portableDebt.enqueuedAt = debt.enqueuedAt
                realm.add(portableDebt)
                realm.delete(debt)
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
                realm.objects(ReaderFilePostprocessorDebt.self)
                    .where { $0.processorIdentifier == "PortableOrphanDebtTest" }
                    .isEmpty
            )
        }
    }

    @MainActor
    func testDurablePostprocessorDebtIsIsolatedByManagerRootAndRealm() async throws {
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
                XCTFail("Expected manager A to leave durable debt")
            } catch TestError.postprocessorFailure {
                // Expected.
            }
            do {
                try await secondManager.refreshAllFilesMetadata(force: true)
                XCTFail("Expected manager B to leave durable debt")
            } catch TestError.postprocessorFailure {
                // Expected.
            }

            var firstRealm = try await Realm.open(configuration: firstConfiguration)
            let secondRealm = try await Realm.open(configuration: secondConfiguration)
            let firstDebt = try XCTUnwrap(
                firstRealm.objects(ReaderFilePostprocessorDebt.self)
                    .where { $0.processorIdentifier == "ManagerIsolationTest" }
                    .first
            )
            let secondDebt = try XCTUnwrap(
                secondRealm.objects(ReaderFilePostprocessorDebt.self)
                    .where { $0.processorIdentifier == "ManagerIsolationTest" }
                    .first
            )
            XCTAssertEqual(firstDebt.contentFilePrimaryKey, secondDebt.contentFilePrimaryKey)
            XCTAssertNotEqual(
                firstDebt.storageScopeIdentifier,
                secondDebt.storageScopeIdentifier
            )
            XCTAssertNotEqual(firstDebt.debtIdentifier, secondDebt.debtIdentifier)

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
                firstRealm.objects(ReaderFilePostprocessorDebt.self)
                    .where { $0.processorIdentifier == "ManagerIsolationTest" }
                    .isEmpty
            )
            XCTAssertEqual(
                secondRealm.objects(ReaderFilePostprocessorDebt.self)
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
            await BookLibraryViewModel.refreshDownloadedEditorsPicks(
                publications: [Publication(
                    title: fixture.downloadable.name,
                    downloadURL: fixture.downloadable.url
                )],
                readerFileManager: fixture.manager
            )

            XCTAssertEqual(
                fixture.manager.files(ofTypes: [.epub, .epubZip])?.map(\.url),
                [fixture.expectedReaderURL]
            )
        }
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
