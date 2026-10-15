import Foundation
import RealmSwift
import XCTest
@testable import LakeOfFireContent

@MainActor
final class ReaderContentHTMLLifetimeTests: XCTestCase {
    private let fileURL = URL(string: "reader-file://file/load/local/example.txt")!

    private func fixture() throws -> (Realm, HistoryRecord) {
        let configuration = Realm.Configuration(
            inMemoryIdentifier: "HTMLLifetime-\(UUID().uuidString)",
            objectTypes: [HistoryRecord.self]
        )
        let realm = try Realm(configuration: configuration)
        let record = HistoryRecord()
        record.rssContainsFullContent = false
        record.isFromClipboard = false
        record.url = fileURL
        record.updateCompoundKey()
        try realm.write { realm.add(record) }
        return (realm, record)
    }

    func testAlreadyDeletedRowDoesNotReadPersistedFieldsOrStartIO() async throws {
        let (realm, record) = try fixture()
        try realm.write { realm.delete(record) }
        XCTAssertTrue(record.isInvalidated)
        let result = try await record.htmlToDisplay(
            readFile: { _ in XCTFail("Deleted row must not start I/O"); return nil },
            resolveMIMEType: { _ in XCTFail("Deleted row must not load metadata"); return nil }
        )
        XCTAssertNil(result)
    }

    func testDeletionDuringReadDoesNotAccessRetiredURLOrLoadMetadata() async throws {
        let (realm, record) = try fixture()
        let result = try await record.htmlToDisplay(
            readFile: { requestedURL in
                XCTAssertEqual(requestedURL, self.fileURL)
                try realm.write { realm.delete(record) }
                return Data("Original text".utf8)
            },
            resolveMIMEType: { _ in XCTFail("Retired read must stop"); return nil }
        )
        XCTAssertTrue(record.isInvalidated)
        XCTAssertNil(result)
    }

    func testDeletionDuringMetadataResolutionDoesNotPublishHTML() async throws {
        let (realm, record) = try fixture()
        let result = try await record.htmlToDisplay(
            readFile: { _ in Data("Original text".utf8) },
            resolveMIMEType: { requestedURL in
                XCTAssertEqual(requestedURL, self.fileURL)
                try realm.write { realm.delete(record) }
                return "text/plain"
            }
        )
        XCTAssertTrue(record.isInvalidated)
        XCTAssertNil(result)
    }

    func testURLReplacementDuringReadDoesNotCombineOldBytesWithNewMetadata() async throws {
        let (realm, record) = try fixture()
        let result = try await record.htmlToDisplay(
            readFile: { _ in
                try realm.write {
                    record.url = URL(string: "reader-file://file/load/local/replacement.html")!
                }
                return Data("Original text".utf8)
            },
            resolveMIMEType: { _ in XCTFail("Changed URL must stop"); return nil }
        )
        XCTAssertNil(result)
    }

    func testURLReplacementDuringMetadataResolutionDoesNotPublishOldBytes() async throws {
        let (realm, record) = try fixture()
        let result = try await record.htmlToDisplay(
            readFile: { _ in Data("Original text".utf8) },
            resolveMIMEType: { _ in
                try realm.write {
                    record.url = URL(string: "reader-file://file/load/local/replacement.txt")!
                }
                return "text/plain"
            }
        )
        XCTAssertNil(result)
    }

    func testValidFileUsesCapturedURLAndNormalizesText() async throws {
        let (_, record) = try fixture()
        let result = try await record.htmlToDisplay(
            readFile: { requestedURL in
                XCTAssertEqual(requestedURL, self.fileURL)
                return Data("Readable Japanese text".utf8)
            },
            resolveMIMEType: { requestedURL in
                XCTAssertEqual(requestedURL, self.fileURL)
                return "text/plain"
            }
        )
        XCTAssertTrue(try XCTUnwrap(result).contains("Readable Japanese text"))
    }

    func testInlineHTMLStillAvoidsFileAndMetadataIO() async throws {
        let record = HistoryRecord()
        record.rssContainsFullContent = true
        record.html = "<p>Inline text</p>"
        let result = try await record.htmlToDisplay(
            readFile: { _ in XCTFail("Inline content needs no file read"); return nil },
            resolveMIMEType: { _ in XCTFail("Inline content needs no metadata read"); return nil }
        )
        XCTAssertEqual(result, "<p>Inline text</p>")
    }
}
