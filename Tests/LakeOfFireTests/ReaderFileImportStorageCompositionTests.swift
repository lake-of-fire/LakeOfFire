import Foundation
import XCTest
@preconcurrency import SwiftCloudDrive
@testable import LakeOfFireContent
@testable import LakeOfFireReader

/// Exercises real drive installation with the actual import-result and row-state
/// consumers. The after-install callback is the metadata-registration seam, not
/// a replacement ReaderFileManager or Realm. Returned URLs are physical fixture
/// URLs; reader-file URL mapping and database publication remain host tests.
@MainActor
final class ReaderFileImportStorageCompositionTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let root: URL
        let source: URL
        let library: URL
        let drive: CloudDrive

        init() async throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            self.root = root
            source = root.appendingPathComponent("incoming/book.epub")
            library = root.appendingPathComponent("library", isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
                drive = try await CloudDrive(storage: .localDirectory(rootURL: library))
                XCTAssertEqual(drive.rootDirectory.standardizedFileURL.path, library.standardizedFileURL.path)
            } catch {
                try? FileManager.default.removeItem(at: root)
                throw error
            }
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func put(_ url: URL, _ value: String) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(value.utf8).write(to: url)
        }

        func read(_ name: String) throws -> String {
            try String(contentsOf: library.appendingPathComponent(name), encoding: .utf8)
        }

        func installedNames() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: library.path).sorted()
        }

        func perform(
            source: URL? = nil,
            afterInstall: @MainActor (URL) async throws -> URL? = { $0 }
        ) async -> ReaderFileImportResult {
            await ReaderFileImportOperation.perform(.success(source ?? self.source)) { selected in
                let path = try await ReaderFileImportStorage.install(
                    fileURL: selected, targetDirectory: .root, drive: self.drive,
                    pathExtension: "epub", collisionTag: { _ in "ABCDEF" })
                return try await afterInstall(path.fileURL(forRoot: self.drive.rootDirectory))
            }
        }

        func putEPUBDirectory() throws {
            try put(source.appendingPathComponent("META-INF/container.xml"), """
                <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
                """)
            try put(source.appendingPathComponent("OPS/book.opf"), """
                <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>日本語の本</dc:title><dc:creator>著者</dc:creator></metadata><manifest/></package>
                """)
        }
    }

    private final class MetadataGate {
        let entered = XCTestExpectation(description: "Storage committed; metadata suspended")
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            await withCheckedContinuation {
                continuation = $0
                entered.fulfill()
            }
        }
        func finish() {
            let saved = continuation
            continuation = nil
            saved?.resume()
        }
    }

    func testFreshInstallPublishesTheReturnedInstalledURL() async throws {
        let fixture = try await Fixture()
        try fixture.put(fixture.source, "new")
        var state = BookDownloadImportState()
        var returnedURL: URL?
        let result = await fixture.perform { installed in
            returnedURL = installed
            return installed
        }
        let installed = try XCTUnwrap(returnedURL)
        let expected = fixture.library.appendingPathComponent("book.epub")
        // CloudDrive may return a relative URL with its root as the base. Check
        // filesystem location separately from exact operation-to-state transfer.
        XCTAssertEqual(installed.absoluteURL.standardizedFileURL, expected.standardizedFileURL)
        XCTAssertEqual(result, .imported(installed))
        XCTAssertTrue(state.receive(result))
        XCTAssertEqual(state.importedURL, installed)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(try fixture.read("book.epub"), "new")
    }

    func testRepeatedInstallReusesTheSameCommittedItem() async throws {
        let fixture = try await Fixture()
        try fixture.put(fixture.source, "new")
        var state = BookDownloadImportState()
        let first = await fixture.perform()
        let repeated = await fixture.perform()
        XCTAssertEqual(repeated, first)
        XCTAssertTrue(state.receive(first))
        XCTAssertTrue(state.receive(repeated))
        XCTAssertEqual(try fixture.installedNames(), ["book.epub"])
    }

    func testOccupiedSuffixPublishesTheActualResolvedDestination() async throws {
        let fixture = try await Fixture()
        try fixture.put(fixture.source, "new")
        try fixture.put(fixture.library.appendingPathComponent("book.epub"), "old")
        try fixture.put(fixture.library.appendingPathComponent("book (ABCDEF).epub"), "other")
        var state = BookDownloadImportState()
        let result = await fixture.perform()
        XCTAssertTrue(state.receive(result))
        XCTAssertEqual(state.importedURL?.lastPathComponent, "book (ABCDEF-2).epub")
        XCTAssertEqual(try fixture.read("book.epub"), "old")
        XCTAssertEqual(try fixture.read("book (ABCDEF).epub"), "other")
        XCTAssertEqual(try fixture.read("book (ABCDEF-2).epub"), "new")
    }

    func testPostCopyFailureLeavesCommittedBytesAndRetryReusesThem() async throws {
        let fixture = try await Fixture()
        try fixture.put(fixture.source, "new")
        var state = BookDownloadImportState()
        let failed = await fixture.perform { installed in
            XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))
            throw CocoaError(.fileReadNoPermission)
        }
        guard case .failed = failed else { return XCTFail("Metadata failure was accepted") }
        XCTAssertFalse(state.receive(failed))
        XCTAssertFalse(state.isImported)
        XCTAssertNotNil(state.errorMessage)
        XCTAssertEqual(try fixture.read("book.epub"), "new")
        let retry = await fixture.perform()
        XCTAssertTrue(state.receive(retry))
        XCTAssertTrue(state.isImported)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(try fixture.installedNames(), ["book.epub"])
    }

    func testMissingMetadataResultLeavesRetryableStateWithoutDuplicatingStorage() async throws {
        let fixture = try await Fixture()
        try fixture.put(fixture.source, "new")
        var state = BookDownloadImportState()
        let missing = await fixture.perform { _ in nil }
        XCTAssertEqual(missing, .failed(message: ReaderFileImportPresentation.missingResult(for: fixture.source)))
        XCTAssertFalse(state.receive(missing))
        XCTAssertEqual(try fixture.installedNames(), ["book.epub"])
        let retry = await fixture.perform()
        XCTAssertTrue(state.receive(retry))
        XCTAssertEqual(try fixture.installedNames(), ["book.epub"])
    }

    func testPreCancelledSelectionNeverStartsStorage() async throws {
        let fixture = try await Fixture()
        try fixture.put(fixture.source, "new")
        let task = Task { @MainActor in await fixture.perform() }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(try fixture.installedNames(), [])
    }

    func testLateCancellationSuppressesPublicationButRetryReusesCommittedBytes() async throws {
        let fixture = try await Fixture()
        try fixture.put(fixture.source, "new")
        var state = BookDownloadImportState()
        let task = Task { @MainActor in
            await fixture.perform { installed in
                withUnsafeCurrentTask { $0?.cancel() }
                return installed
            }
        }
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(state.receive(result))
        XCTAssertFalse(state.isImported)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(try fixture.read("book.epub"), "new")
        let retry = await fixture.perform()
        XCTAssertTrue(state.receive(retry))
        XCTAssertEqual(try fixture.installedNames(), ["book.epub"])
    }

    func testSupersededRowCannotPublishAfterItsStorageCommit() async throws {
        let fixture = try await Fixture()
        try fixture.put(fixture.source, "first")
        let replacementSource = fixture.root.appendingPathComponent("replacement/book.epub")
        try fixture.put(replacementSource, "second")
        let owner = BookDownloadOperation()
        let gate = MetadataGate()
        defer { gate.finish(); owner.cancel() }
        var state = BookDownloadImportState()
        var publications: [URL] = []
        let publish: @MainActor (ReaderFileImportResult) -> Void = { result in
            if state.receive(result), let url = state.importedURL { publications.append(url) }
        }
        let first = try XCTUnwrap(owner.start(operation: {
            await fixture.perform { installed in
                await gate.wait()
                return installed
            }
        }, publish: publish))
        let readiness = await XCTWaiter.fulfillment(of: [gate.entered], timeout: 5)
        guard readiness == .completed else { return XCTFail("First import never reached metadata") }
        XCTAssertEqual(try fixture.read("book.epub"), "first")
        let replacement = try XCTUnwrap(owner.start(operation: {
            await fixture.perform(source: replacementSource)
        }, publish: publish))
        await replacement.value
        gate.finish()
        await first.value
        XCTAssertEqual(publications.map(\.lastPathComponent), ["book (ABCDEF).epub"])
        XCTAssertEqual(state.importedURL?.lastPathComponent, "book (ABCDEF).epub")
        XCTAssertEqual(try fixture.read("book.epub"), "first")
        XCTAssertEqual(try fixture.read("book (ABCDEF).epub"), "second")
    }

    func testProviderCancellationAfterCopyIsSilentAndPreservesPriorState() async throws {
        let fixture = try await Fixture()
        try fixture.put(fixture.source, "new")
        var state = BookDownloadImportState()
        let previous = fixture.root.appendingPathComponent("previous.epubub")
        state.receive(.imported(previous))
        let result = await fixture.perform { _ in throw URLError(.cancelled) }
        XCTAssertEqual(result, .cancelled)
        XCTAssertFalse(state.receive(result))
        XCTAssertEqual(state.importedURL, previous)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(try fixture.read("book.epub"), "new")
    }

    func testRealMetadataParsesFromTheInstalledDirectory() async throws {
        let fixture = try await Fixture()
        try fixture.putEPUBDirectory()
        var state = BookDownloadImportState()
        let result = await fixture.perform { installed in
            let metadata = try XCTUnwrap(EPubParser.parseMetadataAndCover(from: installed))
            XCTAssertEqual(metadata.title, "日本語の本")
            XCTAssertEqual(metadata.author, "著者")
            return installed
        }
        XCTAssertTrue(state.receive(result))
        XCTAssertEqual(try fixture.installedNames(), ["book.epub"])
    }

    func testMetadataLimitFailurePreservesStorageForRetry() async throws {
        let fixture = try await Fixture()
        try fixture.putEPUBDirectory()
        var state = BookDownloadImportState()
        let limited = await fixture.perform { installed in
            _ = try EPubParser.parseMetadataAndCover(from: installed, limits: .init(maxEntryCount: 1))
            return installed
        }
        guard case .failed(let message) = limited else { return XCTFail("Metadata limit was ignored") }
        XCTAssertTrue(message.contains("supported package limits"))
        XCTAssertFalse(state.receive(limited))
        XCTAssertEqual(try fixture.installedNames(), ["book.epub"])
        let retry = await fixture.perform { installed in
            XCTAssertNotNil(try EPubParser.parseMetadataAndCover(from: installed))
            return installed
        }
        XCTAssertTrue(state.receive(retry))
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(try fixture.installedNames(), ["book.epub"])
    }

    func testSourceSymlinkFailsBeforeAnyLibraryFileIsCreated() async throws {
        let fixture = try await Fixture()
        let external = fixture.root.appendingPathComponent("outside")
        try fixture.put(external, "untouched")
        try FileManager.default.createSymbolicLink(at: fixture.source, withDestinationURL: external)
        var state = BookDownloadImportState()
        let result = await fixture.perform()
        guard case .failed = result else { return XCTFail("Source symlink was accepted") }
        XCTAssertFalse(state.receive(result))
        XCTAssertFalse(state.isImported)
        XCTAssertEqual(try fixture.installedNames(), [])
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "untouched")
    }
}
