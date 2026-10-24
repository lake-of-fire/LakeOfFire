import Foundation
import RealmSwift
import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireReader

@MainActor
final class ReaderContentHTMLLifetimeTests: XCTestCase {
    private let fileURL = URL(string: "reader-file://file/load/local/example.txt")!

    private enum FixtureError: Error {
        case unavailable
    }

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

    func testFileReadFailureDoesNotLoadMetadata() async throws {
        let (_, record) = try fixture()
        let result = try await record.htmlToDisplay(
            readFile: { _ in throw FixtureError.unavailable },
            resolveMIMEType: { _ in XCTFail("Failed read must stop"); return nil }
        )
        XCTAssertNil(result)
    }

    func testMissingMIMETypeStillNormalizesFileText() async throws {
        let (_, record) = try fixture()
        let result = try await record.htmlToDisplay(
            readFile: { _ in Data("Readable file text".utf8) },
            resolveMIMEType: { requestedURL in
                XCTAssertEqual(requestedURL, self.fileURL)
                return nil
            }
        )
        XCTAssertTrue(try XCTUnwrap(result).contains("Readable file text"))
    }

    func testMIMEFailureStillNormalizesFileText() async throws {
        let (_, record) = try fixture()
        let result = try await record.htmlToDisplay(
            readFile: { _ in Data("Readable file text".utf8) },
            resolveMIMEType: { _ in throw FixtureError.unavailable }
        )
        XCTAssertTrue(try XCTUnwrap(result).contains("Readable file text"))
    }

    func testCancellationDuringReadDoesNotStartMetadata() async throws {
        let (_, record) = try fixture()
        let task = Task { @MainActor in
            try await record.htmlToDisplay(
                readFile: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return Data("Cancelled file text".utf8)
                },
                resolveMIMEType: { _ in XCTFail("Cancelled read must stop"); return nil }
            )
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled file read must not publish HTML")
        } catch is CancellationError {
            // The child task's cancellation is observed before metadata starts.
        }
    }

    func testCancellationDuringMetadataDoesNotPublishHTML() async throws {
        let (_, record) = try fixture()
        let task = Task { @MainActor in
            try await record.htmlToDisplay(
                readFile: { _ in Data("Cancelled file text".utf8) },
                resolveMIMEType: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return "text/plain"
                }
            )
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled metadata resolution must not publish HTML")
        } catch is CancellationError {
            // A completed read is not an admitted presentation result.
        }
    }

    func testConsumerRejectsAlreadyDeletedContentBeforeLoading() async throws {
        let (realm, record) = try fixture()
        try realm.write { realm.delete(record) }
        let result = try await locallyRetrievableReaderHTML(for: record) {
            XCTFail("Retired content must not invoke its getter")
            return nil
        }
        XCTAssertNil(result)
    }

    func testConsumerRejectsDeletedContentAfterGetterReturnsNil() async throws {
        let (realm, record) = try fixture()
        let result = try await locallyRetrievableReaderHTML(for: record) {
            try await record.htmlToDisplay(
                readFile: { _ in
                    try realm.write { realm.delete(record) }
                    return Data("Original file text".utf8)
                },
                resolveMIMEType: { _ in XCTFail("Retired read must stop"); return nil }
            )
        }
        XCTAssertTrue(record.isInvalidated)
        XCTAssertNil(result, "Nil from the getter must not trigger an invalidated URL read")
    }

    func testConsumerDoesNotAdoptReplacementSnippetAfterFileRead() async throws {
        let (realm, record) = try fixture()
        let snippetURL = try XCTUnwrap(ReaderContentLoader.snippetURL(key: "replacement"))
        let result = try await locallyRetrievableReaderHTML(for: record) {
            try await record.htmlToDisplay(
                readFile: { _ in
                    try realm.write {
                        record.url = snippetURL
                        record.html = "<p>Successor snippet</p>"
                    }
                    return Data("Original file text".utf8)
                },
                resolveMIMEType: { _ in XCTFail("Replaced read must stop"); return nil }
            )
        }
        XCTAssertEqual(record.url, snippetURL)
        XCTAssertNil(result, "An old file request must not publish a successor's snippet fallback")
    }

    func testConsumerPreservesCurrentSnippetFallbackAndTrimsHTML() async throws {
        let record = HistoryRecord()
        record.url = try XCTUnwrap(ReaderContentLoader.snippetURL(key: "current"))
        record.rssContainsFullContent = false
        record.isFromClipboard = false
        record.html = "  <p>Current snippet</p>\n"
        let result = try await locallyRetrievableReaderHTML(for: record) {
            try await record.htmlToDisplay(
                readFile: { _ in XCTFail("A snippet needs no file read"); return nil },
                resolveMIMEType: { _ in XCTFail("A snippet needs no MIME metadata"); return nil }
            )
        }
        XCTAssertEqual(result, "<p>Current snippet</p>")
    }

    func testConsumerRejectsCancellationAfterFailedFileRead() async throws {
        let (_, record) = try fixture()
        let task = Task { @MainActor in
            try await locallyRetrievableReaderHTML(for: record) {
                try await record.htmlToDisplay(
                    readFile: { _ in
                        withUnsafeCurrentTask { $0?.cancel() }
                        throw CancellationError()
                    },
                    resolveMIMEType: { _ in XCTFail("Failed read must stop"); return nil }
                )
            }
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled loading must not become a successful presentation result")
        } catch is CancellationError {
            // The consumer rechecks cancellation even when best-effort I/O returns nil.
        }
    }
}
