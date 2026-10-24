import XCTest
import RealmSwift
import SwiftCloudDrive
import SwiftUIDownloads
import SwiftUIWebView
@testable import LakeOfFireContent
@testable import LakeOfFireReader

private actor DownloadedBookOpenImportGate {
    private var entered = false
    private var finished = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspendIgnoringCancellation() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilSuspendedOrFinished() async -> Bool {
        if !entered && !finished {
            await withCheckedContinuation { entryWaiters.append($0) }
        }
        return entered
    }

    func finish() {
        finished = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

final class DownloadableBookLibraryImportTests: XCTestCase {
    private struct Fixture {
        let manager: ReaderFileManager
        let downloadable: Downloadable
        let expectedReaderURL: URL
    }

    private func makeHistoryRealmConfiguration() -> Realm.Configuration {
        var configuration = Realm.Configuration(
            inMemoryIdentifier: "DownloadableBookLibraryImportTests.\(UUID().uuidString)"
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

    @MainActor
    private func withFixture<T>(
        downloadIsAlreadyInLibrary: Bool,
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

        let manager = ReaderFileManager()
        manager.localDrive = try await CloudDrive(storage: .localDirectory(rootURL: libraryRootURL))
        ReaderFileManager.shared = manager
        EbookFileManager.configure()
        ReaderContentLoader.historyRealmConfiguration = makeHistoryRealmConfiguration()

        let downloadable = Downloadable(
            url: URL(string: "https://example.com/editor-picks/regression.epub")!,
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
    func testOpenDownloadedMissingImportThrowsBeforeNavigation() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: true) { fixture in
            let readerContent = ReaderContent()
            let navigator = WebViewNavigator()
            var imports = 0
            var callbacks = 0
            do {
                try await BookLibraryViewModel.openDownloaded(
                    publication: Publication(title: fixture.downloadable.name, downloadURL: fixture.downloadable.url),
                    readerFileManager: fixture.manager,
                    readerContent: readerContent,
                    navigator: navigator,
                    readerModeViewModel: ReaderModeViewModel(),
                    onNavigateToReader: { callbacks += 1 },
                    importDownloaded: { downloadable in
                        imports += 1
                        XCTAssertEqual(downloadable.localDestination, fixture.downloadable.localDestination)
                        return nil
                    }
                )
                XCTFail("Missing import must produce an actionable error")
            } catch let error as ReaderFileImportError {
                XCTAssertEqual(error, .missingResult(fixture.downloadable.localDestination))
                XCTAssertEqual(error.localizedDescription, ReaderFileImportPresentation.missingResult(for: fixture.downloadable.localDestination))
            }
            XCTAssertEqual(imports, 1)
            XCTAssertEqual(callbacks, 0)
            XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, "nil")
            XCTAssertEqual(navigator.debugLoadSnapshot.lastHTMLBaseURL, "nil")
            XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL, "nil")
            XCTAssertNil(readerContent.content)
        }
    }

    @MainActor
    func testOpenDownloadedPreservesImportErrorBeforeNavigation() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: true) { fixture in
            let readerContent = ReaderContent()
            let navigator = WebViewNavigator()
            var imports = 0
            var callbacks = 0
            do {
                try await BookLibraryViewModel.openDownloaded(
                    publication: Publication(title: fixture.downloadable.name, downloadURL: fixture.downloadable.url),
                    readerFileManager: fixture.manager,
                    readerContent: readerContent,
                    navigator: navigator,
                    readerModeViewModel: ReaderModeViewModel(),
                    onNavigateToReader: { callbacks += 1 },
                    importDownloaded: { _ in
                        imports += 1
                        throw ReaderFileAccessError.notAvailableOffline
                    }
                )
                XCTFail("The importer failure must reach the row's error presentation")
            } catch ReaderFileAccessError.notAvailableOffline {
            }
            XCTAssertEqual(imports, 1)
            XCTAssertEqual(callbacks, 0)
            XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, "nil")
            XCTAssertEqual(navigator.debugLoadSnapshot.lastHTMLBaseURL, "nil")
            XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL, "nil")
        }
    }

    @MainActor
    func testOpenDownloadedPublicPathKeepsCurrentBookWithoutDuplicateNavigation() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: true) { fixture in
            let previousFeedConfiguration = ReaderContentLoader.feedEntryRealmConfiguration
            let previousProviders = ReaderContentLoader.additionalContentProviders
            defer {
                ReaderContentLoader.feedEntryRealmConfiguration = previousFeedConfiguration
                ReaderContentLoader.additionalContentProviders = previousProviders
            }
            ReaderContentLoader.feedEntryRealmConfiguration = ReaderContentLoader.historyRealmConfiguration
            ReaderContentLoader.additionalContentProviders = []
            await ReaderContentLoader.resetTransientCachesForTesting()
            do {
                let readerContent = ReaderContent()
                readerContent.pageURL = fixture.expectedReaderURL
                let navigator = WebViewNavigator()
                var callbacks = 0
                try await BookLibraryViewModel.openDownloaded(
                    publication: Publication(title: fixture.downloadable.name, downloadURL: fixture.downloadable.url),
                    readerFileManager: fixture.manager,
                    readerContent: readerContent,
                    navigator: navigator,
                    readerModeViewModel: ReaderModeViewModel(),
                    onNavigateToReader: { callbacks += 1 }
                )
                XCTAssertEqual(fixture.manager.files(ofTypes: [.epub, .epubZip])?.map(\.url), [fixture.expectedReaderURL])
                let realm = try await Realm.open(configuration: ReaderContentLoader.historyRealmConfiguration)
                XCTAssertEqual(realm.objects(HistoryRecord.self).count, 1, "The successful import must reach the real content loader")
                XCTAssertEqual(readerContent.pageURL, fixture.expectedReaderURL)
                XCTAssertEqual(callbacks, 0)
                XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, "nil")
                XCTAssertEqual(navigator.debugLoadSnapshot.lastHTMLBaseURL, "nil")
                XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL, "nil")
            } catch {
                await ReaderContentLoader.resetTransientCachesForTesting()
                throw error
            }
            await ReaderContentLoader.resetTransientCachesForTesting()
        }
    }

    @MainActor
    func testOpenDownloadedRetiredEntrantDoesNotImport() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: true) { fixture in
            let navigator = WebViewNavigator()
            var imports = 0
            var callbacks = 0
            try await BookLibraryViewModel.openDownloaded(
                publication: Publication(title: fixture.downloadable.name, downloadURL: fixture.downloadable.url),
                readerFileManager: fixture.manager,
                readerContent: ReaderContent(),
                navigator: navigator,
                readerModeViewModel: ReaderModeViewModel(),
                shouldOpen: { false },
                onNavigateToReader: { callbacks += 1 },
                importDownloaded: { _ in
                    imports += 1
                    return fixture.expectedReaderURL
                }
            )

            XCTAssertEqual(imports, 0)
            XCTAssertEqual(callbacks, 0)
            XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, "nil")
            XCTAssertEqual(navigator.debugLoadSnapshot.lastHTMLBaseURL, "nil")
            XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL, "nil")
        }
    }

    @MainActor
    func testOpenDownloadedCancellationPreservesCommittedImportWithoutOpening() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: true) { fixture in
            try await withIsolatedContentLoading {
                let gate = DownloadedBookOpenImportGate()
                let navigator = WebViewNavigator()
                let readerContent = ReaderContent()
                var importedURL: URL?
                var callbacks = 0
                let task = Task { @MainActor in
                    do {
                        try await BookLibraryViewModel.openDownloaded(
                            publication: Publication(title: fixture.downloadable.name, downloadURL: fixture.downloadable.url),
                            readerFileManager: fixture.manager,
                            readerContent: readerContent,
                            navigator: navigator,
                            readerModeViewModel: ReaderModeViewModel(),
                            onNavigateToReader: { callbacks += 1 },
                            importDownloaded: { downloadable in
                                importedURL = try await fixture.manager.ensureImported(downloadable: downloadable)
                                await gate.suspendIgnoringCancellation()
                                return importedURL
                            }
                        )
                        await gate.finish()
                    } catch {
                        await gate.finish()
                        throw error
                    }
                }
                guard await gate.waitUntilSuspendedOrFinished() else {
                    try await task.value
                    XCTFail("The current command must reach its importer")
                    return
                }
                XCTAssertEqual(importedURL, fixture.expectedReaderURL)

                task.cancel()
                await gate.release()
                try await task.value

                let realm = try await Realm.open(configuration: ReaderContentLoader.historyRealmConfiguration)
                XCTAssertEqual(realm.objects(ContentFile.self).count, 1)
                XCTAssertEqual(realm.objects(HistoryRecord.self).count, 0)
                XCTAssertEqual(fixture.manager.files(ofTypes: [.epub, .epubZip])?.map(\.url), [fixture.expectedReaderURL])
                XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.downloadable.localDestination.path))
                XCTAssertEqual(callbacks, 0)
                XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, "nil")
                XCTAssertEqual(navigator.debugLoadSnapshot.lastHTMLBaseURL, "nil")
                XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL, "nil")
                XCTAssertNil(readerContent.content)
            }
        }
    }

    @MainActor
    func testOpenDownloadedReplacedSelectionRejectsUncancelledLateImport() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: true) { fixture in
            try await withIsolatedContentLoading {
                let viewModel = BookLibraryViewModel()
                var original: BookLibraryViewModel.OpenSelection?
                let reservation = try XCTUnwrap(viewModel.startOpenSelection(
                    onStart: { original = $0 }
                ) { _ in })
                await reservation.value
                let selection = try XCTUnwrap(original)
                let gate = DownloadedBookOpenImportGate()
                let navigator = WebViewNavigator()
                var importedURL: URL?
                var callbacks = 0
                let task = Task { @MainActor in
                    do {
                        try await BookLibraryViewModel.openDownloaded(
                            publication: Publication(title: fixture.downloadable.name, downloadURL: fixture.downloadable.url),
                            readerFileManager: fixture.manager,
                            readerContent: ReaderContent(),
                            navigator: navigator,
                            readerModeViewModel: ReaderModeViewModel(),
                            shouldOpen: { viewModel.isCurrentOpenSelection(selection) },
                            onNavigateToReader: { callbacks += 1 },
                            importDownloaded: { downloadable in
                                importedURL = try await fixture.manager.ensureImported(downloadable: downloadable)
                                await gate.suspendIgnoringCancellation()
                                return importedURL
                            }
                        )
                        await gate.finish()
                    } catch {
                        await gate.finish()
                        throw error
                    }
                }
                guard await gate.waitUntilSuspendedOrFinished() else {
                    try await task.value
                    XCTFail("The current command must reach its importer")
                    return
                }
                XCTAssertEqual(importedURL, fixture.expectedReaderURL)

                let replacement = try XCTUnwrap(viewModel.startOpenSelection { newer in
                    XCTAssertTrue(viewModel.isCurrentOpenSelection(newer))
                })
                await replacement.value
                XCTAssertFalse(viewModel.isCurrentOpenSelection(selection))
                XCTAssertFalse(task.isCancelled, "The public command must also honor its explicit selection admission")
                await gate.release()
                try await task.value

                let realm = try await Realm.open(configuration: ReaderContentLoader.historyRealmConfiguration)
                XCTAssertEqual(realm.objects(ContentFile.self).count, 1)
                XCTAssertEqual(realm.objects(HistoryRecord.self).count, 0)
                XCTAssertEqual(fixture.manager.files(ofTypes: [.epub, .epubZip])?.map(\.url), [fixture.expectedReaderURL])
                XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.downloadable.localDestination.path))
                XCTAssertEqual(callbacks, 0)
                XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, "nil")
                XCTAssertEqual(navigator.debugLoadSnapshot.lastHTMLBaseURL, "nil")
                XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL, "nil")
            }
        }
    }

    @MainActor
    func testOpenDownloadedPublicPathNavigatesCurrentImport() async throws {
        try await withFixture(downloadIsAlreadyInLibrary: true) { fixture in
            try await withIsolatedContentLoading {
                let navigator = WebViewNavigator()
                var callbacks = 0
                try await BookLibraryViewModel.openDownloaded(
                    publication: Publication(title: fixture.downloadable.name, downloadURL: fixture.downloadable.url),
                    readerFileManager: fixture.manager,
                    readerContent: ReaderContent(),
                    navigator: navigator,
                    readerModeViewModel: ReaderModeViewModel(),
                    onNavigateToReader: { callbacks += 1 }
                )

                let realm = try await Realm.open(configuration: ReaderContentLoader.historyRealmConfiguration)
                XCTAssertEqual(realm.objects(ContentFile.self).count, 1)
                XCTAssertEqual(realm.objects(HistoryRecord.self).count, 1)
                XCTAssertEqual(callbacks, 1)
                XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, fixture.expectedReaderURL.absoluteString)
                XCTAssertEqual(navigator.debugLoadSnapshot.lastHTMLBaseURL, "nil")
                XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL, "nil")
            }
        }
    }

    @MainActor
    private func withIsolatedContentLoading<T>(
        _ operation: @MainActor () async throws -> T
    ) async throws -> T {
        let previousFeedConfiguration = ReaderContentLoader.feedEntryRealmConfiguration
        let previousProviders = ReaderContentLoader.additionalContentProviders
        defer {
            ReaderContentLoader.feedEntryRealmConfiguration = previousFeedConfiguration
            ReaderContentLoader.additionalContentProviders = previousProviders
        }
        ReaderContentLoader.feedEntryRealmConfiguration = ReaderContentLoader.historyRealmConfiguration
        ReaderContentLoader.additionalContentProviders = []
        await ReaderContentLoader.resetTransientCachesForTesting()
        do {
            let result = try await operation()
            await ReaderContentLoader.resetTransientCachesForTesting()
            return result
        } catch {
            await ReaderContentLoader.resetTransientCachesForTesting()
            throw error
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
