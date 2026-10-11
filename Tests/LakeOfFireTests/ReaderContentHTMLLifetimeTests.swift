import Foundation
import RealmSwift
import XCTest
@testable import LakeOfFireContent

@MainActor
final class ReaderContentHTMLLifetimeTests: XCTestCase {
    private let fileURL = URL(string: "reader-file://file/load/local/example.txt")!

    private func fixture() throws -> (Realm, HistoryRecord) {
        let realm = try Realm(configuration: Realm.Configuration(
            inMemoryIdentifier: UUID().uuidString, objectTypes: [HistoryRecord.self]
        ))
        let record = HistoryRecord()
        record.url = fileURL
        record.rssContainsFullContent = false
        record.isFromClipboard = false
        record.updateCompoundKey()
        try realm.write { realm.add(record) }
        return (realm, record)
    }

    func testAlreadyInvalidatedRowDoesNotStartIO() async throws {
        let (realm, record) = try fixture()
        try realm.write { realm.delete(record) }
        let result = try await record.htmlToDisplay(
            readFile: { _ in XCTFail("Invalid row started I/O"); return nil },
            resolveMIMEType: { _ in XCTFail("Invalid row loaded metadata"); return nil }
        )
        XCTAssertNil(result)
    }

    func testDeletionDuringReadStopsBeforeMetadata() async throws {
        let (realm, record) = try fixture()
        let result = try await record.htmlToDisplay(
            readFile: { url in
                XCTAssertEqual(url, self.fileURL)
                await Task.yield()
                try realm.write { realm.delete(record) }
                return Data("Original text".utf8)
            },
            resolveMIMEType: { _ in XCTFail("Retired row loaded metadata"); return nil }
        )
        XCTAssertTrue(record.isInvalidated)
        XCTAssertNil(result)
    }

    func testDeletionDuringMetadataDoesNotPublishHTML() async throws {
        let (realm, record) = try fixture()
        let result = try await record.htmlToDisplay(
            readFile: { _ in Data("Original text".utf8) },
            resolveMIMEType: { url in
                XCTAssertEqual(url, self.fileURL)
                await Task.yield()
                try realm.write { realm.delete(record) }
                return "text/plain"
            }
        )
        XCTAssertTrue(record.isInvalidated)
        XCTAssertNil(result)
    }

    func testURLReplacementDuringReadDoesNotLoadSuccessorMetadata() async throws {
        let (realm, record) = try fixture()
        let result = try await record.htmlToDisplay(
            readFile: { _ in
                await Task.yield()
                try realm.write { record.url = URL(string: "reader-file://file/load/local/new.html")! }
                return Data("Original text".utf8)
            },
            resolveMIMEType: { _ in XCTFail("Changed URL loaded metadata"); return nil }
        )
        XCTAssertNil(result)
    }

    func testURLReplacementDuringMetadataDoesNotPublishOriginalBytes() async throws {
        let (realm, record) = try fixture()
        let result = try await record.htmlToDisplay(
            readFile: { _ in Data("Original text".utf8) },
            resolveMIMEType: { _ in
                await Task.yield()
                try realm.write { record.url = URL(string: "reader-file://file/load/local/new.txt")! }
                return "text/plain"
            }
        )
        XCTAssertNil(result)
    }

    func testValidFileAndMissingMIMENormalizeCapturedURL() async throws {
        let (realm, record) = try fixture()
        defer { withExtendedLifetime(realm) {} }
        for mimeType in ["text/plain", nil] as [String?] {
            let result = try await record.htmlToDisplay(
                readFile: { url in
                    XCTAssertEqual(url, self.fileURL)
                    return Data("Readable Japanese text".utf8)
                },
                resolveMIMEType: { url in
                    XCTAssertEqual(url, self.fileURL)
                    return mimeType
                }
            )
            XCTAssertTrue(try XCTUnwrap(result).contains("Readable Japanese text"))
        }
    }

    func testInlineHTMLDoesNotStartFileIO() async throws {
        let (realm, record) = try fixture()
        try realm.write {
            record.rssContainsFullContent = true
            record.html = "<p>Inline content</p>"
        }
        let result = try await record.htmlToDisplay(
            readFile: { _ in XCTFail("Inline content read a file"); return nil },
            resolveMIMEType: { _ in XCTFail("Inline content loaded metadata"); return nil }
        )
        XCTAssertEqual(result, "<p>Inline content</p>")
    }
}
