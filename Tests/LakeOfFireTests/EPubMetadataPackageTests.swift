import Foundation
import XCTest
import ZIPFoundation
@testable import LakeOfFireReader

final class EPubMetadataPackageTests: XCTestCase {
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

    private func document(cover: String?) -> String {
        let item = cover.map { "<o:item id=\"cover\" href=\"\($0)\" properties=\"cover-image\" media-type=\"image/jpeg\"/>" } ?? ""
        return """
        <o:package xmlns:o="http://www.idpf.org/2007/opf" xmlns:d="http://purl.org/dc/elements/1.1/" version="3.0">
        <o:metadata><d:title>本の名前</d:title><d:creator>作者</d:creator></o:metadata>
        <o:manifest>\(item)</o:manifest></o:package>
        """
    }

    private func withBothPackages(opf: String, verify: (URL) throws -> Void) throws {
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
        try FileManager.default.zipItem(at: directory, to: zip, shouldKeepParent: false, compressionMethod: .deflate)
        try verify(zip)
    }
}
