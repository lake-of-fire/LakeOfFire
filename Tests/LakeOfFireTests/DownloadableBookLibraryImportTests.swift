import XCTest
import RealmSwift
import SwiftCloudDrive
import SwiftUIDownloads
@testable import LakeOfFireContent
@testable import LakeOfFireReader

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
    private func assertEnsureImportedIndexesBook(_ fixture: Fixture) async throws {
        let importedURL = try await assertEnsureImportedIndexesRealmMetadata(fixture)
        XCTAssertEqual(importedURL, fixture.expectedReaderURL)
        try await fixture.manager.refreshAllFilesMetadata(force: true)
        XCTAssertEqual(
            fixture.manager.files(ofTypes: [.epub, .epubZip])?.map(\.url),
            [fixture.expectedReaderURL]
        )
    }

    @MainActor
    private func assertEnsureImportedIndexesRealmMetadata(_ fixture: Fixture) async throws -> URL? {
        let importedURL = try await fixture.manager.ensureImported(downloadable: fixture.downloadable)
        let realm = try await Realm.open(configuration: ReaderContentLoader.historyRealmConfiguration)
        let contentFile = try XCTUnwrap(realm.objects(ContentFile.self).where {
            !$0.isDeleted && $0.url == fixture.expectedReaderURL.absoluteString
        }.first)
        XCTAssertEqual(contentFile.mimeType, "application/epub+zip")
        return importedURL
    }
}
