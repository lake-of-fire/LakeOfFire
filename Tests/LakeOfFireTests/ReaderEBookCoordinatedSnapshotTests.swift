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
}
