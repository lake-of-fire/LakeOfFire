import Foundation
import LakeOfFireContent
import XCTest
import ZIPFoundation
@testable import LakeOfFireReader

final class EPubMetadataPackageTests: XCTestCase {
    private let opfSubpath = "OPS/book.opf"

    func testStoredAndDeflatedZIPDirectReadsReturnExactEntryBytes() throws {
        let opf = document(cover: nil)
        let expected = Data(opf.utf8)
        for method in [CompressionMethod.none, .deflate] {
            try withBothPackages(opf: opf, compressionMethod: method) { package in
                guard try package.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true else { return }
                let archive = try Archive(url: package, accessMode: .read)
                let source = try ReaderPackageEntrySource(localURL: package)
                XCTAssertEqual(archive.data(for: opfSubpath), expected)
                XCTAssertEqual(try source.readEntry(subpath: opfSubpath), expected)
            }
        }
    }

    func testStoredZIPRejectsChangedOPFBytesWithStaleChecksum() throws {
        let opf = document(cover: nil).replacingOccurrences(of: "本の名前", with: "Original")
        try withBothPackages(opf: opf, compressionMethod: .none) { package in
            let baseline = try XCTUnwrap(EPubParser.parseMetadataAndCover(from: package))
            XCTAssertEqual(baseline.title, "Original")
            guard try package.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true else { return }

            // Corrupt the stored XML while retaining its byte count and valid syntax.
            var bytes = try Data(contentsOf: package)
            let marker = Data("Original".utf8)
            let titleRange = try XCTUnwrap(bytes.range(of: marker))
            XCTAssertNil(bytes.range(of: marker, in: titleRange.upperBound..<bytes.endIndex))
            bytes[titleRange.lowerBound] = 0x58 // Xriginal
            try bytes.write(to: package)

            let archive = try Archive(url: package, accessMode: .read)
            let entry = try XCTUnwrap(archive[opfSubpath])
            var extracted = Data()
            let checksum = try archive.extract(entry) { extracted.append($0) }
            XCTAssertNotEqual(checksum, entry.checksum)
            XCTAssertEqual(UInt64(extracted.count), entry.uncompressedSize)
            XCTAssertNotNil(extracted.range(of: Data("Xriginal".utf8)))

            try assertCorruptOPF(in: package, archive: archive)
        }
    }

    func testDeflatedZIPRejectsStaleUncompressedSizeWithMatchingChecksum() throws {
        let opf = document(cover: nil)
        let expected = Data(opf.utf8)
        try withBothPackages(opf: opf) { package in
            guard try package.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true else { return }
            XCTAssertNotNil(try EPubParser.parseMetadataAndCover(from: package))

            var bytes = try Data(contentsOf: package)
            // The last copy of this name is in the ZIP central directory. Its
            // fixed header is 46 bytes and declares the uncompressed size at byte 24.
            let pathRange = try XCTUnwrap(bytes.range(of: Data(opfSubpath.utf8), options: .backwards))
            let header = pathRange.lowerBound - 46
            guard header >= bytes.startIndex,
                  bytes[header..<(header + 4)].elementsEqual([0x50, 0x4b, 0x01, 0x02]) else {
                return XCTFail("Could not locate the OPF central directory header")
            }
            let wrongSize = UInt32(expected.count + 1)
            withUnsafeBytes(of: wrongSize.littleEndian) {
                bytes.replaceSubrange((header + 24)..<(header + 28), with: $0)
            }
            try bytes.write(to: package)

            let archive = try Archive(url: package, accessMode: .read)
            let entry = try XCTUnwrap(archive[opfSubpath])
            var extracted = Data()
            let checksum = try archive.extract(entry) { extracted.append($0) }
            XCTAssertEqual(checksum, entry.checksum)
            XCTAssertEqual(extracted, expected)
            XCTAssertEqual(entry.uncompressedSize, UInt64(wrongSize))

            try assertCorruptOPF(in: package, archive: archive)
        }
    }

    func testZIPAndDirectoryCoverlessMetadata() throws {
        try withBothPackages(opf: document(cover: nil)) { package in
            let metadata = try XCTUnwrap(EPubParser.parseMetadataAndCover(from: package))
            XCTAssertEqual(metadata.title, "本の名前")
            XCTAssertEqual(metadata.author, "作者")
            XCTAssertNil(metadata.coverHref)
        }
    }

    func testZIPAndDirectoryDecodeCoverPathExactlyOnce() throws {
        try withBothPackages(opf: document(cover: "Images/%E8%A1%A8%E7%B4%99%20%23%25.jpg")) { package in
            let metadata = try XCTUnwrap(EPubParser.parseMetadataAndCover(from: package))
            XCTAssertEqual(metadata.coverHref, "OPS/Images/表紙 #%.jpg")
        }
    }

    func testZIPAndDirectoryRejectMalformedXMLAfterValidMetadata() throws {
        try withBothPackages(opf: document(cover: "cover.jpg") + "<broken>") { package in
            XCTAssertNil(try EPubParser.parseMetadataAndCover(from: package))
        }
    }

    func testZIPAndDirectoryRejectDeclaredEscapingCover() throws {
        try withBothPackages(opf: document(cover: "../../outside.jpg")) { package in
            XCTAssertNil(try EPubParser.parseMetadataAndCover(from: package))
        }
    }

    private func assertCorruptOPF(in package: URL, archive: Archive, file: StaticString = #filePath, line: UInt = #line) throws {
        let source = try ReaderPackageEntrySource(localURL: package)
        XCTAssertThrowsError(try source.readEntry(subpath: opfSubpath), file: file, line: line) { error in
            guard let packageError = error as? ReaderPackageEntrySourceError,
                  case .packageCorrupt = packageError else {
                return XCTFail("Expected packageCorrupt, got \(error)", file: file, line: line)
            }
        }
        XCTAssertNil(archive.data(for: opfSubpath), file: file, line: line)
        XCTAssertNil(try EPubParser.parseMetadataAndCover(from: package), file: file, line: line)
    }

    private func document(cover: String?) -> String {
        let item = cover.map { "<o:item id=\"cover\" href=\"\($0)\" properties=\"cover-image\" media-type=\"image/jpeg\"/>" } ?? ""
        return """
        <o:package xmlns:o="http://www.idpf.org/2007/opf" xmlns:d="http://purl.org/dc/elements/1.1/" version="3.0">
        <o:metadata><d:title>本の名前</d:title><d:creator>作者</d:creator></o:metadata>
        <o:manifest>\(item)</o:manifest></o:package>
        """
    }

    private func withBothPackages(
        opf: String, compressionMethod: CompressionMethod = .deflate, verify: (URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("book.epub", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("OPS/Images"), withIntermediateDirectories: true)
        try Data("""
        <c:container xmlns:c="urn:oasis:names:tc:opendocument:xmlns:container"><c:rootfiles>
        <c:rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/>
        </c:rootfiles></c:container>
        """.utf8).write(to: directory.appendingPathComponent("META-INF/container.xml"))
        try Data(opf.utf8).write(to: directory.appendingPathComponent("OPS/book.opf"))
        try Data([0xff, 0xd8, 0xff, 0xd9]).write(to: directory.appendingPathComponent("OPS/Images/表紙 #%.jpg"))
        try verify(directory)
        let zip = root.appendingPathComponent("archive.epub")
        try FileManager.default.zipItem(at: directory, to: zip, shouldKeepParent: false, compressionMethod: compressionMethod)
        try verify(zip)
    }
}
