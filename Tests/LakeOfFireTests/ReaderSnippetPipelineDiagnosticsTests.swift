import XCTest
import SwiftSoup
@testable import LakeOfFireReader

private actor ReaderSnippetRecoveryTestRecorder {
    private(set) var republishCalls = 0
    private(set) var processCalls = 0

    func recordRepublishCall() {
        republishCalls += 1
    }

    func recordProcessCall() {
        processCalls += 1
    }
}

final class ReaderSnippetPipelineDiagnosticsTests: XCTestCase {
    @MainActor
    func testSupersededReadabilityPreparationRetriesBeforeSubmitting() async throws {
        var attempts = 0
        var submissions = 0
        try await retrySupersededReadabilityPreparation {
            attempts += 1
            if attempts < 3 { throw ReaderPreparedReadabilityDocumentError.superseded }
            submissions += 1
        }
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(submissions, 1)
    }

    @MainActor
    func testRepeatedReadabilitySupersessionTerminatesWithoutSubmission() async {
        var attempts = 0
        do {
            try await retrySupersededReadabilityPreparation {
                attempts += 1
                throw ReaderPreparedReadabilityDocumentError.superseded
            }
            XCTFail("Repeated dictionary changes must terminate preparation")
        } catch ReaderPreparedReadabilityDocumentError.superseded {
            XCTAssertEqual(attempts, 3)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    @MainActor
    func testReadabilityPreparationDoesNotRetryUnrelatedErrors() async {
        var attempts = 0
        do {
            try await retrySupersededReadabilityPreparation {
                attempts += 1
                throw URLError(.cannotDecodeContentData)
            }
            XCTFail("A content error must propagate")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotDecodeContentData)
            XCTAssertEqual(attempts, 1)
        }
    }

    @MainActor
    func testCancelledReadabilityPreparationDoesNotRetry() async {
        var attempts = 0
        let task = Task { @MainActor in
            try await retrySupersededReadabilityPreparation {
                attempts += 1
                withUnsafeCurrentTask { $0?.cancel() }
                throw ReaderPreparedReadabilityDocumentError.superseded
            }
        }
        do { try await task.value; XCTFail("Cancelled owner must not prepare another document") }
        catch is CancellationError { XCTAssertEqual(attempts, 1) }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testUnchangedSnippetTitlePreservesPreparedRubyAndLookupIdentity() throws {
        let document = try SwiftSoup.parse("""
        <html><body><h1 id="reader-title"><m-c><m-s><m-m id="native-title-word"><ruby class="mnb-gen"><m-t>学校</m-t><rt>がっこう</rt><rp>(</rp></ruby></m-m>へ行く</m-s></m-c></h1>
        <script id="mnb-segment-metadata">{"version":1}</script></body></html>
        """)
        let before = try document.outerHtml()

        XCTAssertFalse(try updateSnippetReaderTitleIfNeeded(in: document, title: "学校へ行く"))
        XCTAssertEqual(try document.outerHtml(), before)
        XCTAssertEqual(try document.getElementById("native-title-word")?.select("rt").text(), "がっこう")
    }

    func testRenamedSnippetTitleUpdatesItsVisibleHeading() throws {
        let document = try SwiftSoup.parse("""
        <h1 id="reader-title"><m-c><m-m id="previous-title">古い題名</m-m></m-c></h1>
        """)

        XCTAssertTrue(try updateSnippetReaderTitleIfNeeded(in: document, title: "新しい題名"))
        XCTAssertEqual(try document.getElementById("reader-title")?.text(), "新しい題名")
        XCTAssertNil(try document.getElementById("previous-title"))
        XCTAssertFalse(try updateSnippetReaderTitleIfNeeded(in: document, title: "新しい題名"))
    }

    func testMissingSnippetTitleDoesNotCreateAnotherHeading() throws {
        let document = try SwiftSoup.parse("<p>本文</p>")
        let before = try document.outerHtml()
        XCTAssertFalse(try updateSnippetReaderTitleIfNeeded(in: document, title: "題名"))
        XCTAssertEqual(try document.outerHtml(), before)
    }

    func testPersistedSnippetAuthorityFailureReprocessesCleanSourceThroughInjectedProcessor() async throws {
        let source = """
        <html>
          <head>
            <title>Source title</title>
            <script id="mnb-segment-metadata">stale sidecar</script>
            <meta name="mnb-segment-sidecar" content="internal://local/reader-sidecar/stale">
          </head>
          <body class="readability-mode" data-mnb-analysis-session-cache-identifier="foreign">
            <div id="reader-header"><h1 id="reader-title">Source title</h1></div>
            <div id="reader-content">
              <m-c><m-s><m-m id="old-segment"><ruby class="mnb-src">学<rt>がく</rt><rp>(</rp></ruby><m-t>校</m-t></m-m>と<ruby class="mnb-gen"><m-t>行</m-t><rt>い</rt></ruby></m-s></m-c>。
            </div>
          </body>
        </html>
        """
        let document = try SwiftSoup.parse(source)
        let snippetURL = try XCTUnwrap(URL(string: "internal://local/snippet?key=recovery"))
        let recorder = ReaderSnippetRecoveryTestRecorder()

        let recovered = try await processPersistedSnippetWithCurrentReadabilityProcessor(
            document: document,
            readabilityContent: source,
            url: snippetURL,
            tracksReadingProgress: true,
            processReadabilityContent: { content, contentURL, _, _, _, _, preprocessDoc in
                await recorder.recordProcessCall()
                let parsed = try SwiftSoup.parse(content, contentURL.absoluteString)
                return await preprocessDoc(parsed)
            },
            republishReaderModeRuntimeAuthority: { _, _, _ in
                await recorder.recordRepublishCall()
                return false
            },
            preprocessDoc: { $0 }
        )

        let republishCalls = await recorder.republishCalls
        let processCalls = await recorder.processCalls
        XCTAssertEqual(republishCalls, 1)
        XCTAssertEqual(processCalls, 1)
        XCTAssertEqual(try recovered.getElementById("reader-title")?.text(), "Source title")
        XCTAssertEqual(try recovered.getElementById("reader-content")?.text(), "学がく(校と行。")
        XCTAssertTrue(try recovered.select("ruby.mnb-src rt").count == 1)
        XCTAssertEqual(try recovered.select("ruby.mnb-src").first()?.text(), "学がく(")
        XCTAssertTrue(try recovered.select("ruby.mnb-gen").isEmpty)
        XCTAssertTrue(try recovered.select("m-m, m-t, m-s, m-c").isEmpty)
        XCTAssertTrue(try recovered.select("script#mnb-segment-metadata, meta[name=mnb-segment-sidecar]").isEmpty)
        XCTAssertFalse(try recovered.body()?.hasAttr("data-mnb-analysis-session-cache-identifier") == true)
    }

    func testPersistedSnippetRoutingDoesNotRequireRetainedInlineSidecar() {
        let content = "<body class='readability-mode'><div id='reader-content'><m-s>犬。</m-s></div></body>"
        XCTAssertTrue(hasPersistedReaderSegmentMarkup(in: content))
        XCTAssertTrue(hasPersistedReaderSegmentMarkup(in:
            "<head><meta name='mnb-segment-sidecar' content='internal://local/reader-sidecar/old'></head>" + content
        ))
        XCTAssertFalse(hasPersistedReaderSegmentMarkup(in:
            "<body class='readability-mode'><div id='reader-content'><p>犬。</p></div></body>"
        ))
    }

    func testAdmittedPersistedSnippetRetainsDocumentWithoutReprocessing() async throws {
        let document = try SwiftSoup.parse("<html><body>犬。</body></html>")
        let recorder = ReaderSnippetRecoveryTestRecorder()
        let result = try await processPersistedSnippetWithCurrentReadabilityProcessor(
            document: document,
            readabilityContent: "unused",
            url: try XCTUnwrap(URL(string: "internal://local/snippet?key=current")),
            tracksReadingProgress: true,
            processReadabilityContent: { _, _, _, _, _, _, _ in
                await recorder.recordProcessCall()
                return document
            },
            republishReaderModeRuntimeAuthority: { _, _, _ in true },
            preprocessDoc: { $0 }
        )
        XCTAssertTrue(result === document)
        let processCalls = await recorder.processCalls
        XCTAssertEqual(processCalls, 0)
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
