import Foundation
import XCTest
import ZIPFoundation
@testable import LakeOfFireContent

final class ReaderEBookPackageFingerprintTests: XCTestCase {
    private let files: [(String, Data)] = [
        ("mimetype", Data("application/epub+zip".utf8)),
        ("META-INF/container.xml", Data("<container><rootfiles><rootfile full-path='OPS/book.opf'/></rootfiles></container>".utf8)),
        ("OPS/book.opf", Data("<package><spine/></package>".utf8)),
        ("OPS/chapter.xhtml", Data("<html><body>日本語<img src='page.jpg'/></body></html>".utf8)),
        ("OPS/page.jpg", Data([0, 1, 2, 3]))
    ]
    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    private func zip(_ url: URL, files: [(String, Data)], compressed: Bool = false, date: Date = Date(timeIntervalSince1970: 1_600_000_000)) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for (path, bytes) in files {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count),
                modificationDate: date, compressionMethod: compressed ? .deflate : .none) { offset, count in
                    bytes.subdata(in: Int(offset)..<Int(offset) + count)
                }
        }
    }
    private func fingerprint(_ url: URL, limits: ReaderEBookFingerprintLimits = .default) throws -> ReaderEBookPackageFingerprint {
        try .readSnapshot(at: url, packageDocumentPath: "OPS/book.opf", limits: limits)
    }
    func testRecompressionTimestampsEntryOrderAndOuterNameDoNotChangeIdentity() throws {
        try withRoot { root in
            let a = root.appendingPathComponent("cloud.epub")
            let b = root.appendingPathComponent("renamed-local.epub")
            try zip(a, files: files)
            try zip(b, files: files.reversed(), compressed: true, date: Date(timeIntervalSince1970: 1_700_000_000))
            XCTAssertNotEqual(try Data(contentsOf: a), try Data(contentsOf: b))
            XCTAssertEqual(try fingerprint(a), try fingerprint(b))
        }
    }
    func testUnpackedAndPackedPackagesAgree() throws {
        try withRoot { root in
            let directory = root.appendingPathComponent("unpacked", isDirectory: true)
            for (path, data) in files {
                let target = directory.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target)
            }
            let archive = root.appendingPathComponent("book.epub")
            try zip(archive, files: files)
            XCTAssertEqual(try fingerprint(directory), try fingerprint(archive))
        }
    }
    func testDifferentImageWithSameChapterMarkupChangesRevision() throws {
        try withRoot { root in
            let a = root.appendingPathComponent("a.epub"), b = root.appendingPathComponent("b.epub")
            try zip(a, files: files)
            try zip(b, files: files.map { $0.0 == "OPS/page.jpg" ? ($0.0, Data([4, 5, 6, 7])) : $0 })
            XCTAssertNotEqual(try fingerprint(a).packageSHA256, try fingerprint(b).packageSHA256)
        }
    }
    func testMetadataEditChangesRevisionNotProofOfDifferentLogicalBook() throws {
        try withRoot { root in
            let a = root.appendingPathComponent("a.epub"), b = root.appendingPathComponent("b.epub")
            try zip(a, files: files)
            try zip(b, files: files.map { $0.0 == "OPS/book.opf" ? ($0.0, Data("<package><metadata/><spine/></package>".utf8)) : $0 })
            XCTAssertNotEqual(try fingerprint(a).packageSHA256, try fingerprint(b).packageSHA256)
        }
    }
    func testDuplicateArchivePathRejectedInsteadOfSilentlySkipped() throws {
        try withRoot { root in
            let url = root.appendingPathComponent("duplicate.epub")
            try zip(url, files: files + [("OPS/chapter.xhtml", Data("different".utf8))])
            XCTAssertThrowsError(try fingerprint(url)) {
                XCTAssertEqual($0 as? ReaderEBookFingerprintError, .ambiguousPath("OPS/chapter.xhtml"))
            }
        }
    }
    func testTraversalAndWhitespaceArchivePathsRejected() throws {
        try withRoot { root in
            for (index, path) in ["../outside", "OPS/./chapter", "OPS//chapter", " OPS/chapter"].enumerated() {
                let url = root.appendingPathComponent("bad-\(index).epub")
                try zip(url, files: files + [(path, Data([1]))])
                XCTAssertThrowsError(try fingerprint(url))
            }
        }
    }
    func testDirectorySymlinksRejectedRatherThanIgnored() throws {
        try withRoot { root in
            let dir = root.appendingPathComponent("unpacked", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: root)
            XCTAssertThrowsError(try fingerprint(dir))
        }
    }
    func testMissingSelectedPackageDocumentRejected() throws {
        try withRoot { root in
            let url = root.appendingPathComponent("missing.epub")
            try zip(url, files: files.filter { $0.0 != "OPS/book.opf" })
            XCTAssertThrowsError(try fingerprint(url))
        }
    }
    func testMimetypeMustMatchExactly() throws {
        try withRoot { root in
            let url = root.appendingPathComponent("mime.epub")
            try zip(url, files: files.map { $0.0 == "mimetype" ? ($0.0, Data("application/epub+zip\n".utf8)) : $0 })
            XCTAssertThrowsError(try fingerprint(url))
        }
    }
    func testEntryCountAndByteBudgetsAppliedBeforeHashing() throws {
        try withRoot { root in
            let url = root.appendingPathComponent("limits.epub")
            try zip(url, files: files)
            for limits in [ReaderEBookFingerprintLimits(maxEntryCount: 2),
                           ReaderEBookFingerprintLimits(maxEntryBytes: 2),
                           ReaderEBookFingerprintLimits(maxAggregateUncompressedBytes: 2)] {
                XCTAssertThrowsError(try fingerprint(url, limits: limits))
            }
        }
    }
    func testTruncatedCentralDirectoryCannotBecomeAPartialFingerprint() throws {
        try withRoot { root in
            let url = root.appendingPathComponent("truncated.epub")
            try zip(url, files: files)
            var data = try Data(contentsOf: url)
            let range = try XCTUnwrap(data.range(of: Data([0x50, 0x4b, 0x01, 0x02]), options: .backwards))
            data[range.lowerBound] = 0
            try data.write(to: url)
            XCTAssertThrowsError(try fingerprint(url))
        }
    }
    func testAdvertisedEntryCountCannotHideAnIncompleteIterator() throws {
        try withRoot { root in
            let url = root.appendingPathComponent("count.epub")
            try zip(url, files: files)
            var data = try Data(contentsOf: url)
            let range = try XCTUnwrap(data.range(of: Data([0x50, 0x4b, 0x05, 0x06]), options: .backwards))
            data[range.lowerBound + 8] += 1
            data[range.lowerBound + 10] += 1
            try data.write(to: url)
            XCTAssertThrowsError(try fingerprint(url))
        }
    }
    func testFrozenVersionOneFingerprintVector() throws {
        try withRoot { root in
            let url = root.appendingPathComponent("vector.epub")
            try zip(url, files: files)
            XCTAssertEqual(try fingerprint(url).packageSHA256,
                "afb9b15e5ecc9489960371370272369001a12f5f23515e77fbc1e9fdce155980")
        }
    }
    func testCancellationIsNotAValidPartialIdentity() async throws {
        let task = Task { () throws -> ReaderEBookPackageFingerprint in
            withUnsafeCurrentTask { $0?.cancel() }
            return try ReaderEBookPackageFingerprint.readSnapshot(at: URL(fileURLWithPath: "/does-not-exist"),
                                                                  packageDocumentPath: "OPS/book.opf")
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
    }
    func testResourcePathsAndSelectedRenditionAreRetained() throws {
        try withRoot { root in
            let url = root.appendingPathComponent("book.epub")
            try zip(url, files: files)
            let result = try fingerprint(url)
            XCTAssertEqual(result.packageDocumentPath, "OPS/book.opf")
            XCTAssertEqual(result.resources.map(\.path), files.map(\.0).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
            XCTAssertTrue(result.resources.allSatisfy { $0.sha256.count == 64 })
        }
    }
}
