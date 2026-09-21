import Foundation
import XCTest
import ZIPFoundation
import LakeOfFireContent
@testable import LakeOfFireReader

final class EPubMetadataReadLimitsTests: XCTestCase {
    func testDirectoryMetadataSurvivesLargeNonMetadataAssets() throws {
        try assertLargeAssetsAllowed(zipped: false)
    }

    func testZIPMetadataSurvivesLargeNonMetadataAssets() throws {
        try assertLargeAssetsAllowed(zipped: true)
    }

    func testDirectoryStillRejectsOversizedContainer() throws {
        try assertOversizedMetadataRejected(zipped: false, path: "META-INF/container.xml")
    }

    func testZIPStillRejectsOversizedContainer() throws {
        try assertOversizedMetadataRejected(zipped: true, path: "META-INF/container.xml")
    }

    func testDirectoryStillRejectsOversizedOPF() throws {
        try assertOversizedMetadataRejected(zipped: false, path: "OPS/book.opf")
    }

    func testZIPStillRejectsOversizedOPF() throws {
        try assertOversizedMetadataRejected(zipped: true, path: "OPS/book.opf")
    }

    func testDirectoryStillChecksPackageInventoryLimits() throws {
        try withPackage(zipped: false, mutate: { directory in
            let asset = directory.appendingPathComponent("too-large.bin")
            XCTAssertTrue(FileManager.default.createFile(atPath: asset.path, contents: nil))
            let handle = try FileHandle(forWritingTo: asset)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(ReaderPackageResourceLimits.default.maxEntryBytes) + 1)
        }) { url in
            XCTAssertNil(try EPubParser.parseMetadataAndCover(from: url))
        }
    }

    func testDirectoryRejectsContainerPathTraversal() throws {
        try withPackage(zipped: false, mutate: { directory in
            try Data(self.container.replacingOccurrences(of: "OPS/book.opf", with: "../outside.opf").utf8)
                .write(to: directory.appendingPathComponent("META-INF/container.xml"))
        }) { url in
            XCTAssertNil(try EPubParser.parseMetadataAndCover(from: url))
        }
    }

    func testZIPRejectsCoverPathTraversal() throws {
        try withPackage(zipped: true, mutate: { directory in
            try Data(self.opf.replacingOccurrences(of: "cover.jpg", with: "../../outside.jpg").utf8)
                .write(to: directory.appendingPathComponent("OPS/book.opf"))
        }) { url in
            XCTAssertNil(try EPubParser.parseMetadataAndCover(from: url))
        }
    }

    private func assertLargeAssetsAllowed(zipped: Bool) throws {
        try withPackage(zipped: zipped, mutate: { directory in
            // Neither an unrelated audio file nor the cover image is XML metadata.
            let asset = Data(repeating: 0x5A, count: 9 * 1024 * 1024)
            try asset.write(to: directory.appendingPathComponent("OPS/audio.mp3"))
            try asset.write(to: directory.appendingPathComponent("OPS/cover.jpg"))
        }) { url in
            let metadata = try XCTUnwrap(EPubParser.parseMetadataAndCover(from: url))
            XCTAssertEqual(metadata.title, "Small metadata, large assets")
            XCTAssertEqual(metadata.author, "Example Author")
            XCTAssertEqual(metadata.coverHref, "OPS/cover.jpg")
            XCTAssertEqual(metadata.publicationDate, ISO8601DateFormatter().date(from: "2026-01-02T00:00:00Z"))
        }
    }

    private func assertOversizedMetadataRejected(zipped: Bool, path: String) throws {
        try withPackage(zipped: zipped, mutate: { directory in
            let url = directory.appendingPathComponent(path)
            var data = try Data(contentsOf: url)
            // Keep it valid XML: rejection must come from the byte budget,
            // rather than accidentally passing because XML parsing fails.
            data.append(Data(repeating: 0x20, count: Int(ReaderPackageResourceLimits.metadata.maxEntryBytes) + 1 - data.count))
            try data.write(to: url)
        }) { url in
            XCTAssertNil(try EPubParser.parseMetadataAndCover(from: url))
        }
    }

    private var container: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """
    }

    private var opf: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <package version="3.0" xmlns:dc="http://purl.org/dc/elements/1.1/">
          <metadata><dc:title>Small metadata, large assets</dc:title><dc:creator>Example Author</dc:creator><dc:date>2026-01-02T00:00:00Z</dc:date></metadata>
          <manifest><item id="cover" href="cover.jpg" media-type="image/jpeg" properties="cover-image"/></manifest>
        </package>
        """
    }

    private func withPackage(
        zipped: Bool,
        mutate: (URL) throws -> Void,
        verify: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let package = directory.appendingPathComponent("book", isDirectory: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("OPS"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(container.utf8).write(to: package.appendingPathComponent("META-INF/container.xml"))
        try Data(opf.utf8).write(to: package.appendingPathComponent("OPS/book.opf"))
        try Data([0]).write(to: package.appendingPathComponent("OPS/cover.jpg"))
        try mutate(package)
        if zipped {
            let archive = directory.appendingPathComponent("book.epub")
            try FileManager.default.zipItem(at: package, to: archive, shouldKeepParent: false, compressionMethod: .deflate)
            try verify(archive)
        } else {
            try verify(package)
        }
    }
}
