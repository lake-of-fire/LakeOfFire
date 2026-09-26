import Foundation
import XCTest
import ZIPFoundation
@testable import LakeOfFireContent

/// Exercises the actual Apple snapshot accessor and production scanner, not a
/// coordination stub. The copy/cleanup failure matrix lives in the portable suite.
final class ReaderEBookCoordinatedSnapshotTests: XCTestCase {
    private let files: [(String, Data)] = [
        ("mimetype", Data("application/epub+zip".utf8)),
        ("META-INF/container.xml", Data("<container><rootfiles><rootfile full-path='OPS/book.opf'/></rootfiles></container>".utf8)),
        ("OPS/book.opf", Data("<package><spine/></package>".utf8)),
        ("OPS/chapter.xhtml", Data("<html><body>日本語の本文。</body></html>".utf8))
    ]

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    private func zip(_ url: URL, files: [(String, Data)]) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in files {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                compressionMethod: .deflate) { position, count in
                    data.subdata(in: Int(position)..<(Int(position) + count))
                }
        }
    }
    private func directory(_ root: URL) throws -> URL {
        let url = root.appendingPathComponent("Original.epub", isDirectory: true)
        for (path, data) in files {
            let entry = url.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: entry)
        }
        return url
    }

    func testActualCoordinatedArchiveRetainsExactFingerprintAfterSourceRemoval() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.epub")
        try zip(source, files: files)
        let expected = try ReaderEBookPackageFingerprint.readSnapshot(at: source, packageDocumentPath: "OPS/book.opf")
        let snapshot = try await ReaderEBookPackageSnapshot.capture(at: source)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try snapshot.fingerprint(packageDocumentPath: "OPS/book.opf"), expected)
        try snapshot.validateObservation(snapshot.observationToken)
    }

    func testActualDirectorySnapshotMatchesUnpackedPackageWithoutRenamingResources() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try directory(root)
        let expected = try ReaderEBookPackageFingerprint.readSnapshot(at: source, packageDocumentPath: "OPS/book.opf")
        let snapshot = try await ReaderEBookPackageSnapshot.capture(at: source)
        let archive = try Archive(url: snapshot.packageURL, accessMode: .read)
        XCTAssertEqual(archive.filter { $0.type == .file }.map(\.path).sorted(),
                       files.map(\.0).sorted(), "Snapshot must retain the package resource namespace")
        XCTAssertEqual(try snapshot.fingerprint(packageDocumentPath: "OPS/book.opf"), expected)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: snapshot.packageURL.path)[.type] as? FileAttributeType, .typeRegular)
    }

    func testChildEditWithUnchangedParentTimestampCannotChangeCapturedRevision() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try directory(root)
        let snapshot = try await ReaderEBookPackageSnapshot.capture(at: source)
        let original = try snapshot.fingerprint(packageDocumentPath: "OPS/book.opf")
        let oldDate = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date)
        try Data("<html><body>Changed chapter.</body></html>".utf8).write(to: source.appendingPathComponent("OPS/chapter.xhtml"))
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: source.path)
        XCTAssertEqual(try snapshot.fingerprint(packageDocumentPath: "OPS/book.opf"), original)
        let changed = try await ReaderEBookPackageSnapshot.capture(at: source)
        XCTAssertNotEqual(try changed.fingerprint(packageDocumentPath: "OPS/book.opf").packageSHA256, original.packageSHA256)
        XCTAssertNotEqual(changed.observationToken, snapshot.observationToken)
    }

    func testActualSnapshotRejectsMissingSelectedRendition() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.epub")
        try zip(source, files: files)
        let snapshot = try await ReaderEBookPackageSnapshot.capture(at: source)
        XCTAssertThrowsError(try snapshot.fingerprint(packageDocumentPath: "OTHER/book.opf"))
        // A failed identity lookup does not remove the live user's original.
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testActualSnapshotRetainsCorruptPackageWithoutCallingItAValidIdentity() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("corrupt.epub")
        try Data("not a ZIP".utf8).write(to: source)
        let snapshot = try await ReaderEBookPackageSnapshot.capture(at: source)
        XCTAssertThrowsError(try snapshot.fingerprint(packageDocumentPath: "OPS/book.opf"))
        XCTAssertEqual(try Data(contentsOf: source), Data("not a ZIP".utf8))
    }

    func testRenamedDirectoryDoesNotChangeInternalPathsOrFingerprint() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try directory(root)
        let original = try await ReaderEBookPackageSnapshot.capture(at: source)
        let renamed = root.appendingPathComponent("Renamed 日本語.epub", isDirectory: true)
        try FileManager.default.moveItem(at: source, to: renamed)
        let replacement = try await ReaderEBookPackageSnapshot.capture(at: renamed)
        XCTAssertEqual(try original.fingerprint(packageDocumentPath: "OPS/book.opf"),
                       try replacement.fingerprint(packageDocumentPath: "OPS/book.opf"))
    }

    func testDirectoryWithSymbolicResourceIsNotAcceptedAsIdentity() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try directory(root)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("OPS/linked.xhtml"),
            withDestinationURL: source.appendingPathComponent("OPS/chapter.xhtml"))
        do {
            let snapshot = try await ReaderEBookPackageSnapshot.capture(at: source)
            _ = try snapshot.fingerprint(packageDocumentPath: "OPS/book.opf")
            XCTFail("A symlink cannot be treated as an ordinary package resource")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        }
    }

    func testEnvelopeConversionCannotDiscardOtherTopLevelContent() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("envelope.zip")
        try zip(source, files: files.map { ("Original.epub/" + $0.0, $0.1) }
                + [("other-resource", Data([1]))])
        let snapshot = try await ReaderEBookPackageSnapshot.capture(at: source)
        XCTAssertThrowsError(try ReaderEBookDirectorySnapshotArchive.retainContents(
            of: snapshot, rootName: "Original.epub", maximumBytes: 1_000_000))
        try snapshot.validateObservation(snapshot.observationToken)
    }

    func testEnvelopeConversionDoesNotGuessRootOfOrdinaryEPUB() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.epub")
        try zip(source, files: files)
        let snapshot = try await ReaderEBookPackageSnapshot.capture(at: source)
        XCTAssertThrowsError(try ReaderEBookDirectorySnapshotArchive.retainContents(
            of: snapshot, rootName: "OPS", maximumBytes: 1_000_000))
        XCTAssertEqual(try snapshot.fingerprint(packageDocumentPath: "OPS/book.opf").resources.count, files.count)
    }

}
