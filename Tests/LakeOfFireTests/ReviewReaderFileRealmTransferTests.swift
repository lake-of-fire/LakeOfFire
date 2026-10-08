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
}
