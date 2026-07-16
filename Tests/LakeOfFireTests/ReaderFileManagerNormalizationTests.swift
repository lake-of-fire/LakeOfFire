import XCTest
import SwiftCloudDrive
@testable import LakeOfFireContent

final class ReaderFileManagerNormalizationTests: XCTestCase {
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

    private func writeFixture(relativePath: String, under rootURL: URL) throws -> URL {
        let fileURL = rootURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("ebook fixture".utf8).write(to: fileURL)
        return fileURL
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
