import XCTest
@testable import LakeOfFireReader

final class ReaderSnippetPipelineDiagnosticsTests: XCTestCase {
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
