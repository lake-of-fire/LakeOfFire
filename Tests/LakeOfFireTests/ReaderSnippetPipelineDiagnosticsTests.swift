import XCTest
import SwiftSoup
@testable import LakeOfFireReader

final class ReaderSnippetPipelineDiagnosticsTests: XCTestCase {
    func testForeignPersistedAuthorityRegeneratesSnippetSource() async throws {
        let persisted = try SwiftSoup.parse(
            "<html><body><div id=\"reader-content\">old</div></body></html>"
        )
        let regenerated = try await readerSnippetDocumentAfterAuthorityAttempt(
            persistedDocument: persisted,
            didRepublish: false
        ) {
            try SwiftSoup.parse(
                "<html><body><div id=\"reader-content\">fresh</div></body></html>"
            )
        }

        XCTAssertEqual(try regenerated.getElementById("reader-content")?.text(), "fresh")
        XCTAssertEqual(try persisted.getElementById("reader-content")?.text(), "old")
    }

    func testCurrentPersistedAuthoritySkipsSnippetRegeneration() async throws {
        let persisted = try SwiftSoup.parse(
            "<html><body><div id=\"reader-content\">current</div></body></html>"
        )
        var regenerationCount = 0
        let retained = try await readerSnippetDocumentAfterAuthorityAttempt(
            persistedDocument: persisted,
            didRepublish: true
        ) {
            regenerationCount += 1
            return try SwiftSoup.parse("<html><body>unexpected</body></html>")
        }

        XCTAssertTrue(retained === persisted)
        XCTAssertEqual(regenerationCount, 0)
    }

    func testFinalDocumentSnapshotReportsProcessedReaderStructure() {
        let snapshot = ReaderSnippetFinalDocumentSnapshot.make(htmlBytes: Array("""
        <html><head><script id="mnb-segment-metadata">{}</script></head><body>
        <div id="reader-content"><m-m id="segment-1">word</m-m></div>
        </body></html>
        """.utf8))

        XCTAssertTrue(snapshot.parsedSuccessfully)
        XCTAssertTrue(snapshot.readerContentContainerPresent)
        XCTAssertEqual(snapshot.segmentCount, 1)
        XCTAssertTrue(snapshot.inlineSidecarPresent)
        XCTAssertFalse(snapshot.externalSidecarDescriptorPresent)
    }

    func testFinalDocumentSnapshotReportsExternalizedProcessedSidecar() {
        let snapshot = ReaderSnippetFinalDocumentSnapshot.make(htmlBytes: Array("""
        <html><head><meta name="mnb-segment-sidecar" content="internal://local/reader-sidecar/token"></head>
        <body><div id="reader-content"><m-m id="segment-1">word</m-m></div></body></html>
        """.utf8))

        XCTAssertTrue(snapshot.parsedSuccessfully)
        XCTAssertTrue(snapshot.readerContentContainerPresent)
        XCTAssertEqual(snapshot.segmentCount, 1)
        XCTAssertFalse(snapshot.inlineSidecarPresent)
        XCTAssertTrue(snapshot.externalSidecarDescriptorPresent)
    }

    func testFinalDocumentSnapshotReportsRawSnippetWithoutSegmentation() {
        let snapshot = ReaderSnippetFinalDocumentSnapshot.make(htmlBytes: Array("""
        <html><body><p>raw snippet</p></body></html>
        """.utf8))

        XCTAssertTrue(snapshot.parsedSuccessfully)
        XCTAssertFalse(snapshot.readerContentContainerPresent)
        XCTAssertEqual(snapshot.segmentCount, 0)
        XCTAssertFalse(snapshot.inlineSidecarPresent)
        XCTAssertFalse(snapshot.externalSidecarDescriptorPresent)
    }
}
