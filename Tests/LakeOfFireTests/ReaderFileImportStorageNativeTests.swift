import Foundation
import XCTest
@preconcurrency import SwiftCloudDrive
@testable import LakeOfFireContent

@MainActor
final class ReaderFileImportStorageNativeTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source: URL
        let library: URL
        init() throws {
            source = root.appendingPathComponent("incoming/book.epub")
            library = root.appendingPathComponent("library", isDirectory: true)
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func drive() async throws -> CloudDrive {
            let result = try await CloudDrive(storage: .localDirectory(rootURL: library))
            XCTAssertEqual(result.rootDirectory.standardizedFileURL.path, library.standardizedFileURL.path)
            return result
        }
        func put(_ url: URL, _ value: String) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(value.utf8).write(to: url)
        }
        func install(using drive: CloudDrive, source: URL? = nil) async throws -> RootRelativePath {
            try await ReaderFileImportStorage.install(fileURL: source ?? self.source, targetDirectory: .root,
                drive: drive, pathExtension: "epub", collisionTag: { _ in "ABCDEF" })
        }
    }

    func testRealDriveFreshAndRepeatedImportReuseTheSamePath() async throws {
        let f = try Fixture(); try f.put(f.source, "new")
        let drive = try await f.drive()
        let first = try await f.install(using: drive)
        let second = try await f.install(using: drive)
        XCTAssertEqual(first.path, "book.epub")
        XCTAssertEqual(second.path, first.path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.library.path), ["book.epub"])
    }

    func testRealDriveReusesTheSourceAlreadyInsideTheLibrary() async throws {
        let f = try Fixture(); let original = f.library.appendingPathComponent("book.epub")
        try f.put(original, "existing")
        let drive = try await f.drive()
        let result = try await f.install(using: drive, source: original)
        XCTAssertEqual(result.path, "book.epub")
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "existing")
    }

    func testRealDriveSkipsOccupiedHashSuffixAndThenReusesIdenticalSuffix() async throws {
        let f = try Fixture(); try f.put(f.source, "new")
        try f.put(f.library.appendingPathComponent("book.epub"), "old")
        try f.put(f.library.appendingPathComponent("book (ABCDEF).epub"), "other")
        let drive = try await f.drive()
        let result = try await f.install(using: drive)
        let again = try await f.install(using: drive)
        XCTAssertEqual(result.path, "book (ABCDEF-2).epub")
        XCTAssertEqual(again.path, result.path)
        XCTAssertEqual(try String(contentsOf: f.library.appendingPathComponent("book (ABCDEF).epub"), encoding: .utf8), "other")
    }

    func testDirectoryWithSameConcatenatedBytesButDifferentNamesIsNotReused() async throws {
        let f = try Fixture()
        try f.put(f.source.appendingPathComponent("one.xhtml"), "same")
        try f.put(f.library.appendingPathComponent("book.epub/two.xhtml"), "same")
        let drive = try await f.drive()
        let result = try await f.install(using: drive)
        XCTAssertEqual(result.path, "book (ABCDEF).epub")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.library.appendingPathComponent("book.epub/two.xhtml").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.library.appendingPathComponent("book (ABCDEF).epub/one.xhtml").path))
    }

    func testIdenticalDirectoriesAreReused() async throws {
        let f = try Fixture()
        try f.put(f.source.appendingPathComponent("OPS/本文.xhtml"), "日本語")
        let drive = try await f.drive()
        let first = try await f.install(using: drive)
        let second = try await f.install(using: drive)
        XCTAssertEqual(first.path, second.path)
        XCTAssertEqual(first.path, "book.epub")
    }

    func testFileDirectoryMismatchChoosesAnotherName() async throws {
        let f = try Fixture(); try f.put(f.source, "new")
        try f.put(f.library.appendingPathComponent("book.epub/keep"), "unchanged")
        let drive = try await f.drive()
        let result = try await f.install(using: drive)
        XCTAssertEqual(result.path, "book (ABCDEF).epub")
        XCTAssertEqual(try String(contentsOf: f.library.appendingPathComponent("book.epub/keep"), encoding: .utf8), "unchanged")
    }

    func testDanglingDestinationSymlinkIsOccupiedNotFollowed() async throws {
        let f = try Fixture(); try f.put(f.source, "new")
        let target = f.root.appendingPathComponent("missing")
        try FileManager.default.createSymbolicLink(at: f.library.appendingPathComponent("book.epub"), withDestinationURL: target)
        let drive = try await f.drive()
        let result = try await f.install(using: drive)
        XCTAssertEqual(result.path, "book (ABCDEF).epub")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: f.library.appendingPathComponent("book.epub").path), target.path)
    }

    func testOccupiedLeafSymlinkAndFirstCollisionSymlinkAdvanceToNextSuffix() async throws {
        let f = try Fixture(); try f.put(f.source, "new")
        let firstTarget = f.root.appendingPathComponent("missing-one")
        let secondTarget = f.root.appendingPathComponent("missing-two")
        try FileManager.default.createSymbolicLink(
            at: f.library.appendingPathComponent("book.epub"),
            withDestinationURL: firstTarget
        )
        try FileManager.default.createSymbolicLink(
            at: f.library.appendingPathComponent("book (ABCDEF).epub"),
            withDestinationURL: secondTarget
        )
        let drive = try await f.drive()

        let result = try await f.install(using: drive)

        XCTAssertEqual(result.path, "book (ABCDEF-2).epub")
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstTarget.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondTarget.path))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: f.library.appendingPathComponent("book.epub").path
            ),
            firstTarget.path
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: f.library.appendingPathComponent("book (ABCDEF).epub").path
            ),
            secondTarget.path
        )
        XCTAssertEqual(
            try String(
                contentsOf: f.library.appendingPathComponent("book (ABCDEF-2).epub"),
                encoding: .utf8
            ),
            "new"
        )
    }

    func testSymlinkedTargetParentStillFailsClosed() async throws {
        let f = try Fixture()
        try f.put(f.source, "new")
        let outside = f.root.appendingPathComponent(
            "outside-library",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        let linkedParent = f.library.appendingPathComponent(
            "imports",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedParent,
            withDestinationURL: outside
        )
        let drive = try await f.drive()

        do {
            _ = try await ReaderFileImportStorage.install(
                fileURL: f.source,
                targetDirectory: RootRelativePath(path: "imports"),
                drive: drive,
                pathExtension: "epub",
                collisionTag: { _ in "ABCDEF" }
            )
            XCTFail("Expected symlinked parent rejection")
        } catch {
            // Root-relative validation owns the exact error type. The security
            // invariant is that the external destination is never written.
        }

        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                atPath: outside.path
            ).isEmpty
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: linkedParent.path
            ),
            outside.path
        )
    }

    func testSourceSymlinkIsRejectedWithoutInstallation() async throws {
        let f = try Fixture(); let target = f.root.appendingPathComponent("outside")
        try f.put(target, "private")
        try FileManager.default.createSymbolicLink(at: f.source, withDestinationURL: target)
        let drive = try await f.drive()
        do { _ = try await f.install(using: drive); XCTFail("Expected source rejection") }
        catch { XCTAssertEqual((error as NSError).code, CocoaError.fileReadUnsupportedScheme.rawValue) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.library.path).isEmpty)
    }
}

final class ReaderFileImportPackageManifestTests: XCTestCase {
    private func roots(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("a"), second = root.appendingPathComponent("b")
        for directory in [first, second] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try body(first, second)
    }
    private func put(_ root: URL, _ name: String, _ bytes: String) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: url)
    }
    private func digest(_ url: URL) throws -> Data { try ReaderFileImportPackageManifest.digest(at: url) }

    func testOrderAndOuterDirectoryNameDoNotChangeManifest() throws {
        try roots { a, b in
            try put(a, "b", "2"); try put(a, "a", "1")
            try put(b, "a", "1"); try put(b, "b", "2")
            XCTAssertEqual(try digest(a), try digest(b))
        }
    }
    func testRelativeNamesDistinguishEqualBytes() throws {
        try roots { a, b in
            try put(a, "a", "same"); try put(b, "b", "same")
            XCTAssertNotEqual(try digest(a), try digest(b))
        }
    }
    func testFileBoundariesDistinguishEqualConcatenations() throws {
        try roots { a, b in
            try put(a, "1", "ab"); try put(a, "2", "c")
            try put(b, "1", "a"); try put(b, "2", "bc")
            XCTAssertNotEqual(try digest(a), try digest(b))
        }
    }
    func testEmptyDirectoryIsPartOfIdentity() throws {
        try roots { a, b in
            try FileManager.default.createDirectory(at: a.appendingPathComponent("empty"), withIntermediateDirectories: true)
            XCTAssertNotEqual(try digest(a), try digest(b))
        }
    }
    func testHiddenFilesArePartOfIdentity() throws {
        try roots { a, b in
            try put(a, ".hidden", "data")
            XCTAssertNotEqual(try digest(a), try digest(b))
        }
    }
    func testSymlinkTargetsAreLiteralAndExternalBytesAreNotRead() throws {
        try roots { a, b in
            let external = a.deletingLastPathComponent().appendingPathComponent("outside")
            try Data("before".utf8).write(to: external)
            for root in [a, b] { try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: external) }
            let before = try digest(a)
            try Data("after".utf8).write(to: external)
            XCTAssertEqual(before, try digest(a))
            XCTAssertEqual(before, try digest(b))
        }
    }
    func testChangedSymlinkTargetChangesManifest() throws {
        try roots { a, b in
            try FileManager.default.createSymbolicLink(atPath: a.appendingPathComponent("link").path, withDestinationPath: "missing-a")
            try FileManager.default.createSymbolicLink(atPath: b.appendingPathComponent("link").path, withDestinationPath: "missing-b")
            XCTAssertNotEqual(try digest(a), try digest(b))
        }
    }
    func testMultiChunkContentChangeIsDetected() throws {
        try roots { a, b in
            let bytes = String(repeating: "x", count: 150_000)
            try put(a, "data", bytes + "a"); try put(b, "data", bytes + "b")
            XCTAssertNotEqual(try digest(a), try digest(b))
        }
    }
    func testNonDirectoryRootIsRejected() throws {
        try roots { a, _ in
            try put(a, "file", "data")
            XCTAssertThrowsError(try digest(a.appendingPathComponent("file")))
        }
    }
}
