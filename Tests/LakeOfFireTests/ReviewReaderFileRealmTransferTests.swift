import Foundation
import RealmSwift
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireFiles

@MainActor
final class ReviewReaderFileRealmTransferTests: XCTestCase {
    /// Run this case alone on RED: Realm may terminate the process for the
    /// wrong-executor property read. A missing-module/build failure is not red.
    func testLiveManagedMetadataCanProduceAResponseOnTheSchemeActor() async throws {
        var configuration = Realm.Configuration()
        configuration.inMemoryIdentifier = "review-file-response-" + UUID().uuidString
        configuration.objectTypes = [ContentFile.self]
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let file = ContentFile()
        file.url = URL(string: "reader-file://file/load/local/book.txt")!
        file.mimeType = "text/plain"
        file.updateCompoundKey()
        try realm.write { realm.add(file) }
        let key = file.compoundKey
        XCTAssertNotNil(file.realm)
        XCTAssertFalse(file.isFrozen)
        let payload = try await ReaderFileDocumentLoader.load(
            url: file.url,
            metadata: { realm.object(ofType: ContentFile.self, forPrimaryKey: key) },
            read: { Data("visible document text".utf8) }
        )
        let value = try XCTUnwrap(payload)
        XCTAssertEqual(value.mimeType, "text/html")
        XCTAssertEqual(value.textEncodingName, "UTF-8")
        XCTAssertTrue(String(decoding: value.data, as: UTF8.self).contains("visible document text"))
    }
    func testMissingMetadataReturnsNoDocument() async throws {
        let payload = try await ReaderFileDocumentLoader.load(
            url: URL(string: "reader-file://file/load/local/missing.txt")!,
            metadata: { nil }, read: { Data("text".utf8) }
        )
        XCTAssertNil(payload)
    }
    func testBinaryPayloadRemainsUnchanged() async throws {
        let file = ContentFile()
        file.mimeType = "application/octet-stream"
        let bytes = Data([0xff, 0xfe, 0, 1])
        let payload = try await ReaderFileDocumentLoader.load(
            url: URL(string: "reader-file://file/load/local/data.bin")!,
            metadata: { file }, read: { bytes }
        )
        XCTAssertEqual(payload?.data, bytes)
        XCTAssertEqual(payload?.mimeType, "application/octet-stream")
        XCTAssertNil(payload?.textEncodingName)
    }

    private static let byteOrderMarkEncodings: [(mark: [UInt8], encoding: String.Encoding)] = [
        ([0xef, 0xbb, 0xbf], .utf8),
        ([0xff, 0xfe], .utf16LittleEndian),
        ([0xfe, 0xff], .utf16BigEndian),
        ([0xff, 0xfe, 0x00, 0x00], .utf32LittleEndian),
        ([0x00, 0x00, 0xfe, 0xff], .utf32BigEndian),
    ]

    func testUTF8AndBOMEncodedMarkdownNormalizeToUTF8HTML() async throws {
        let heading = "日本語の見出し"
        let paragraph = "本文を読めます。📖"
        let markdown = "# \(heading)\n\n\(paragraph)"
        let encodings = [(mark: [UInt8](), encoding: String.Encoding.utf8)] + Self.byteOrderMarkEncodings
        for (mark, encoding) in encodings {
            let bytes = Data(mark) + (try XCTUnwrap(markdown.data(using: encoding)))
            let payload = try await loadTextFile(bytes, pathExtension: "md", mimeType: "text/markdown")
            let html = try XCTUnwrap(String(data: payload.data, encoding: .utf8))
            XCTAssertEqual(payload.mimeType, "text/html", "\(encoding)")
            XCTAssertEqual(payload.textEncodingName, "UTF-8", "\(encoding)")
            XCTAssertTrue(html.contains("<h1") && html.contains("\(heading)</h1>"), "\(encoding)")
            XCTAssertTrue(html.contains("<p>\(paragraph)</p>"), "\(encoding)")
            XCTAssertFalse(html.contains("\u{feff}"), "\(encoding)")
        }
    }

    func testMarkedHTMLPreservesLiteralLeadingFEFFInSlicedData() async throws {
        let html = "\u{feff}<p>本文\u{fffd}📖</p>"
        for (mark, encoding) in Self.byteOrderMarkEncodings {
            let input = Data([0xa5]) + Data(mark) + (try XCTUnwrap(html.data(using: encoding)))
            let payload = try await loadTextFile(input.dropFirst(), pathExtension: "html", mimeType: "text/html")
            XCTAssertEqual(payload.data, Data(html.utf8), "\(encoding)")
            XCTAssertEqual(payload.mimeType, "text/html", "\(encoding)")
            XCTAssertEqual(payload.textEncodingName, "UTF-8", "\(encoding)")
        }
    }

    func testUTF16PlainTextNormalizesWithoutInterpretingMarkup() async throws {
        let text = "日本語 <b>本文</b> & 続き"
        let bytes = Data([0xfe, 0xff]) + (try XCTUnwrap(text.data(using: .utf16BigEndian)))
        let payload = try await loadTextFile(bytes, pathExtension: "txt", mimeType: "text/plain")
        let html = try XCTUnwrap(String(data: payload.data, encoding: .utf8))
        XCTAssertEqual(payload.mimeType, "text/html")
        XCTAssertEqual(payload.textEncodingName, "UTF-8")
        XCTAssertTrue(html.contains("日本語 &lt;b&gt;本文&lt;/b&gt; &amp; 続き"))
        XCTAssertFalse(html.contains("<b>本文</b>"))
    }

    func testMalformedUnicodeTextRemainsAnUnmodifiedRawResponse() async throws {
        let inputs: [[UInt8]] = [
            [0xff], // Invalid UTF-8 without a BOM.
            [0xef, 0xbb, 0xbf, 0xff],
            [0xff, 0xfe, 0x61], // Truncated UTF-16LE code unit.
            [0xff, 0xfe, 0x00, 0xd8], // Lone UTF-16LE high surrogate.
            [0xff, 0xfe, 0x00, 0x00, 0x61], // Truncated UTF-32LE code unit.
            [0xff, 0xfe, 0x00, 0x00, 0x00, 0xd8, 0x00, 0x00], // Surrogate scalar in UTF-32LE.
            [0x00, 0x00, 0xfe, 0xff, 0x00, 0x11, 0x00, 0x00], // Out-of-range scalar in UTF-32BE.
        ]
        for input in inputs {
            let bytes = Data(input)
            let payload = try await loadTextFile(bytes, pathExtension: "md", mimeType: "text/markdown")
            XCTAssertEqual(payload.data, bytes, "\(input)")
            XCTAssertEqual(payload.mimeType, "text/markdown", "\(input)")
            XCTAssertNil(payload.textEncodingName, "\(input)")
        }
    }

    func testUnsupportedTextFormatRemainsAnUnmodifiedRawResponse() async throws {
        let bytes = Data([0xfe, 0xff, 0x00, 0x61])
        let payload = try await loadTextFile(bytes, pathExtension: "csv", mimeType: "text/csv")
        XCTAssertEqual(payload.data, bytes)
        XCTAssertEqual(payload.mimeType, "text/csv")
        XCTAssertNil(payload.textEncodingName)
    }

    private func loadTextFile(
        _ bytes: Data,
        pathExtension: String,
        mimeType: String
    ) async throws -> ReaderFileDocumentPayload {
        let file = ContentFile()
        file.url = URL(string: "reader-file://file/load/local/book.\(pathExtension)")!
        file.mimeType = mimeType
        let payload = try await ReaderFileDocumentLoader.load(
            url: file.url,
            metadata: { file },
            read: { bytes }
        )
        return try XCTUnwrap(payload)
    }
}
