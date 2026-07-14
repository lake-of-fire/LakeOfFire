import XCTest
import ZIPFoundation
import SwiftSoup
@testable import LakeOfFireContent
@testable import LakeOfFireReader

private actor EbookTestGate {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var isWaiting = false

    func waitUntilReleased() async {
        isWaiting = true
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func isWaitingForRelease() -> Bool {
        isWaiting
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor EbookTestInvocationCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private func ebookTestPayload(
    _ documentHTML: String,
    sidecar: String = ""
) -> EbookProcessedSectionPayload {
    EbookProcessedSectionPayload(
        documentHTML: Data(documentHTML.utf8),
        segmentSidecar: Data(sidecar.utf8)
    )
}

final class EbookURLSchemeHandlerTests: XCTestCase {
    func testExternalizingCanonicalSidecarKeepsAggregateAndPublishesRawJSON() throws {
        let canonicalJSON = #"{"v":9,"t":{},"s":[]}"#
        let aggregateJSON = #"{"c":0,"j":[],"n":[],"k":[],"sid":[]}"#
        let html = """
        <html><head><title>Test</title></head><body><p>本文</p>
        <script id="mnb-segment-metadata-aggregate" type="application/json" data-mnb-seg-meta-aggregate="true">\(aggregateJSON)</script>
        <script id="mnb-segment-metadata" type="application/json" data-mnb-seg-meta="true">\(canonicalJSON)</script>
        </body></html>
        """

        let result = externalizingCanonicalReaderSegmentSidecar(
            in: Array(html.utf8),
            scheme: .ebook
        )
        let output = String(decoding: result.documentHTML, as: UTF8.self)

        XCTAssertFalse(output.contains("id=\"mnb-segment-metadata\""))
        XCTAssertTrue(output.contains("id=\"mnb-segment-metadata-aggregate\""))
        XCTAssertTrue(output.contains("meta name=\"mnb-segment-sidecar\""))
        XCTAssertTrue(output.contains("ebook://ebook/processed-section-sidecar/"))
        XCTAssertLessThan(
            try XCTUnwrap(output.range(of: "meta name=\"mnb-segment-sidecar\"")?.lowerBound),
            try XCTUnwrap(output.range(of: "</head>")?.lowerBound)
        )
        XCTAssertEqual(result.canonicalSidecarByteCount, canonicalJSON.utf8.count)
        let endpointURL = try XCTUnwrap(result.endpointURL)
        let token = try XCTUnwrap(URL(string: endpointURL)?.lastPathComponent)
        let stored = try XCTUnwrap(ReaderExternalSegmentSidecarStore.shared.entry(for: token))
        XCTAssertEqual(String(decoding: stored.data, as: UTF8.self), canonicalJSON)
        XCTAssertEqual(stored.signature, result.signature)
    }

    func testExternalSidecarIdentityIsDeterministicAndCacheable() throws {
        let payload = EbookProcessedSectionPayload(
            documentHTML: Data("<html><head></head><body>本文</body></html>".utf8),
            segmentSidecar: Data(#"{"v":9,"s":[]}"#.utf8)
        )

        let first = publishingCanonicalReaderSegmentSidecar(payload, scheme: .ebook)
        let second = publishingCanonicalReaderSegmentSidecar(payload, scheme: .ebook)

        XCTAssertEqual(first.endpointURL, second.endpointURL)
        XCTAssertEqual(first.signature, second.signature)
        let responseDocument = String(decoding: ebookHTMLDataWithInjectedResponseMetadata(
            first.documentHTML,
            baseURL: "ebook://ebook/entry-source/token/chapter.xhtml",
            writingHint: nil,
            bodyAttributes: [:],
            additionalHeadMarkup: first.headDescriptor
        ), as: UTF8.self)
        XCTAssertTrue(responseDocument.contains("<head><base href="))
        XCTAssertTrue(responseDocument.contains("<meta name=\"mnb-segment-sidecar\""))
        let endpoint = try XCTUnwrap(first.endpointURL.flatMap(URL.init(string:)))
        let served = try XCTUnwrap(readerExternalSegmentSidecarResponse(for: endpoint, scheme: .ebook))
        XCTAssertEqual(served.data, payload.segmentSidecar)
        XCTAssertEqual(served.response.value(forHTTPHeaderField: "Cache-Control"), "no-store")
    }

    func testPublishedSidecarRemainsAvailableForDocumentLifetime() throws {
        let firstPayload = ebookTestPayload("<html></html>", sidecar: #"{"index":0}"#)
        let first = publishingCanonicalReaderSegmentSidecar(firstPayload, scheme: .ebook)
        let firstEndpoint = try XCTUnwrap(first.endpointURL.flatMap(URL.init(string:)))

        // This exceeded the former entry limit and evicted an otherwise valid
        // sidecar URL retained by the first document.
        for index in 1...40 {
            _ = publishingCanonicalReaderSegmentSidecar(
                ebookTestPayload("<html></html>", sidecar: "{\"index\":\(index)}"),
                scheme: .ebook
            )
        }

        let served = try XCTUnwrap(
            readerExternalSegmentSidecarResponse(for: firstEndpoint, scheme: .ebook)
        )
        XCTAssertEqual(served.data, firstPayload.segmentSidecar)
    }

    func testEvictedSidecarRegeneratesFromContentAddressedStorageAcrossStoreInstances() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manabi-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let firstStore = ReaderExternalSegmentSidecarStore(
            directoryURL: directoryURL,
            totalByteLimit: 1,
            countLimit: 1
        )
        let firstPayload = ebookTestPayload("<html></html>", sidecar: #"{"index":0}"#)
        let first = publishingCanonicalReaderSegmentSidecar(
            firstPayload,
            scheme: .ebook,
            store: firstStore
        )
        let endpoint = try XCTUnwrap(first.endpointURL.flatMap(URL.init(string:)))

        _ = publishingCanonicalReaderSegmentSidecar(
            ebookTestPayload("<html></html>", sidecar: #"{"index":1}"#),
            scheme: .ebook,
            store: firstStore
        )
        XCTAssertEqual(
            readerExternalSegmentSidecarResponse(
                for: endpoint,
                scheme: .ebook,
                store: firstStore
            )?.data,
            firstPayload.segmentSidecar
        )

        let restartedStore = ReaderExternalSegmentSidecarStore(
            directoryURL: directoryURL,
            totalByteLimit: 1,
            countLimit: 1
        )
        XCTAssertEqual(
            readerExternalSegmentSidecarResponse(
                for: endpoint,
                scheme: .ebook,
                store: restartedStore
            )?.data,
            firstPayload.segmentSidecar
        )
    }

    func testSpeechProgressSaturatesOverflowingUTF16Range() {
        XCTAssertEqual(
            ReaderTTSProgressEvaluator.fraction(
                text: "A😀B",
                spokenRange: NSRange(location: Int.max - 1, length: 10)
            ),
            1
        )
        XCTAssertEqual(
            ReaderTTSProgressEvaluator.fraction(
                text: "本文",
                spokenRange: NSRange(location: NSNotFound, length: 0)
            ),
            0
        )
        XCTAssertEqual(
            ReaderTTSProgressEvaluator.fraction(
                text: "本文",
                spokenRange: NSRange(location: -1, length: 1)
            ),
            0
        )
        XCTAssertEqual(
            ReaderTTSProgressEvaluator.fraction(
                text: "",
                spokenRange: NSRange(location: 0, length: 1)
            ),
            0
        )
    }

    func testUnversionedViewerAssetsDisableBrowserCaching() throws {
        let response = ebookHTTPResponse(
            url: try XCTUnwrap(URL(string: "ebook://ebook/load/viewer-assets/foliate-js/paginator.js")),
            mimeType: "text/javascript",
            byteCount: 123,
            textEncodingName: "utf-8",
            additionalHeaderFields: ebookViewerAssetCacheHeaderFields()
        )

        XCTAssertEqual(
            response.value(forHTTPHeaderField: "Cache-Control"),
            "no-store, no-cache, must-revalidate"
        )
        XCTAssertEqual(response.value(forHTTPHeaderField: "Pragma"), "no-cache")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Expires"), "0")
    }

    func testExternalizingCanonicalSidecarLeavesHTMLWithoutCanonicalSidecarUnchanged() {
        let html = "<html><head></head><body><p>本文</p></body></html>"

        let result = externalizingCanonicalReaderSegmentSidecar(
            in: Array(html.utf8),
            scheme: .internalReader
        )

        XCTAssertEqual(result.documentHTML, Data(html.utf8))
        XCTAssertEqual(result.canonicalSidecarByteCount, 0)
        XCTAssertNil(result.endpointURL)
        XCTAssertNil(result.signature)
    }

    func testProcessedSidecarCacheEnvelopeRoundTripsWithoutRescanningCombinedHTML() throws {
        let canonicalJSON = #"{"v":9,"t":{"語":[1]},"s":[]}"#
        let aggregateJSON = #"{"c":1,"j":["語"]}"#
        let html = """
        <html><head></head><body><p>本文</p>
        <script id="mnb-segment-metadata-aggregate" type="application/json">\(aggregateJSON)</script>
        <script id="mnb-segment-metadata" type="application/json" data-mnb-seg-meta="true">\(canonicalJSON)</script>
        </body></html>
        """

        let payload = try XCTUnwrap(splitCanonicalReaderSegmentSidecar(from: Array(html.utf8)))
        let encoded = encodedEbookProcessedSectionCacheValue(payload)
        let decoded = try XCTUnwrap(decodedEbookProcessedSectionCacheValue(encoded))
        let splitDocument = String(decoding: decoded.documentHTML, as: UTF8.self)

        XCTAssertFalse(splitDocument.contains("id=\"mnb-segment-metadata\""))
        XCTAssertTrue(splitDocument.contains("id=\"mnb-segment-metadata-aggregate\""))
        XCTAssertEqual(String(decoding: decoded.segmentSidecar, as: UTF8.self), canonicalJSON)

    }

    func testProcessedSidecarCacheEnvelopeRejectsTruncatedValue() throws {
        let html = "<html><body><script id=\"mnb-segment-metadata\">{}</script></body></html>"
        let payload = try XCTUnwrap(splitCanonicalReaderSegmentSidecar(from: Array(html.utf8)))
        let encoded = encodedEbookProcessedSectionCacheValue(payload)

        XCTAssertNil(decodedEbookProcessedSectionCacheValue(Array(encoded.dropLast())))
    }

    func testProcessedSidecarCacheEnvelopeRejectsPreStableIdentityVersion() throws {
        let html = "<html><body><script id=\"mnb-segment-metadata\">{}</script></body></html>"
        let payload = try XCTUnwrap(splitCanonicalReaderSegmentSidecar(from: Array(html.utf8)))
        var legacyEncoded = encodedEbookProcessedSectionCacheValue(payload)
        legacyEncoded.replaceSubrange(0..<7, with: Array("MNBPSC2".utf8))

        XCTAssertNil(decodedEbookProcessedSectionCacheValue(legacyEncoded))
    }

    func testProcessedSidecarCacheRequiresDurableIdentityForEverySegment() {
        let valid = EbookProcessedSectionPayload(
            documentHTML: Data("<m-m id=runtime>text</m-m>".utf8),
            segmentSidecar: Data(#"{"v":9,"t":{"h":["hash"],"sid":["sentence"]},"s":[["!runtime",0,null,null,null,null,null,null,null,0]]}"#.utf8)
        )
        let missingSentenceIdentity = EbookProcessedSectionPayload(
            documentHTML: Data("<m-m id=runtime>text</m-m>".utf8),
            segmentSidecar: Data(#"{"v":9,"t":{"h":["hash"],"sid":[]},"s":[["!runtime",0]]}"#.utf8)
        )

        XCTAssertTrue(ebookProcessedSectionPayloadHasDurableSegmentIdentities(valid))
        XCTAssertFalse(ebookProcessedSectionPayloadHasDurableSegmentIdentities(missingSentenceIdentity))
    }

    func testProcessedSidecarCacheRejectsMissingOrIncompleteSegmentCoverage() {
        let documentHTML = Data("<html><body><m-m id=a>A</m-m><m-m id=b>B</m-m></body></html>".utf8)
        let missingSidecar = EbookProcessedSectionPayload(
            documentHTML: documentHTML,
            segmentSidecar: Data()
        )
        let emptySidecar = EbookProcessedSectionPayload(
            documentHTML: documentHTML,
            segmentSidecar: Data(#"{"v":9,"t":{"h":[],"sid":[]},"s":[]}"#.utf8)
        )
        let incompleteSidecar = EbookProcessedSectionPayload(
            documentHTML: documentHTML,
            segmentSidecar: Data(#"{"v":9,"t":{"h":["hash"],"sid":["sentence"]},"s":[["a",0,null,null,null,null,null,null,null,0]]}"#.utf8)
        )
        let segmentFreeDocument = EbookProcessedSectionPayload(
            documentHTML: Data("<html><body>Plain text</body></html>".utf8),
            segmentSidecar: Data()
        )

        XCTAssertFalse(ebookProcessedSectionPayloadHasDurableSegmentIdentities(missingSidecar))
        XCTAssertFalse(ebookProcessedSectionPayloadHasDurableSegmentIdentities(emptySidecar))
        XCTAssertFalse(ebookProcessedSectionPayloadHasDurableSegmentIdentities(incompleteSidecar))
        XCTAssertTrue(ebookProcessedSectionPayloadHasDurableSegmentIdentities(segmentFreeDocument))
    }

    func testInlineSharedReaderFontCSSInjectsBothDirectionalFamilies() throws {
        let doc = try SwiftSoup.parse("<html><head></head><body class=\"readability-mode\"><p>本文</p></body></html>")
        let css = """
        @font-face {
          font-family: 'YuKyokasho';
          src: url("data:font/woff2;base64,AAAA") format("woff2");
        }
        """

        try upsertInlineSharedReaderFontCSS(css, in: doc)

        let style = try XCTUnwrap(doc.getElementById("mnb-custom-fonts-inline"))
        let script = try XCTUnwrap(doc.getElementById("mnb-custom-fonts-inline-bootstrap"))
        let styleText = try style.html()
        let scriptText = try script.html()

        XCTAssertTrue(styleText.contains("font-family: 'YuKyokasho';"))
        XCTAssertTrue(styleText.contains("font-family: 'YuKyokasho Yoko';"))
        XCTAssertTrue(scriptText.contains("manabiReaderFontCSSText"))
        XCTAssertTrue(scriptText.contains("manabiReaderFontInjectionMode"))
        XCTAssertTrue(scriptText.contains("manabiHorizontalFontFamilyName"))
        XCTAssertTrue(scriptText.contains("manabiVerticalFontFamilyName"))
        XCTAssertEqual(try doc.getElementsByTag("html").first()?.attr("data-mnb-horizontal-font-family"), "YuKyokasho")
        XCTAssertEqual(try doc.getElementsByTag("html").first()?.attr("data-mnb-vertical-font-family"), "YuKyokasho Yoko")
        XCTAssertTrue((try doc.getElementsByTag("html").first()?.attr("style") ?? "").contains("--mnb-content-font: 'YuKyokasho';"))
        XCTAssertTrue((try doc.body()?.attr("style") ?? "").contains("--mnb-content-vertical-font: 'YuKyokasho Yoko';"))
    }

    func testResponseMetadataByteInjectionDecoratesUppercaseDocumentWithoutReserializingContent() {
        let html = "<!doctype html><HTML><HEAD><title>T</title></HEAD><BODY class=\"book\"><p>本文</p></BODY></HTML>"
        let result = String(decoding: ebookHTMLDataWithInjectedResponseMetadata(
            Data(html.utf8),
            baseURL: "ebook://ebook/entry-source/token/chapter.xhtml?x=1&y=2",
            writingHint: EBookProcessedSectionWritingHint(
                direction: "vertical",
                writingMode: "vertical-rl"
            ),
            bodyAttributes: ["data-mnb-native-cache-outcome": "final-direct-hit"]
        ), as: UTF8.self)

        XCTAssertTrue(result.contains("<HEAD><base href=\"ebook://ebook/entry-source/token/chapter.xhtml?x=1&amp;y=2\">"))
        XCTAssertTrue(result.contains("<BODY class=\"book\""))
        XCTAssertTrue(result.contains("data-mnb-native-cache-outcome=\"final-direct-hit\""))
        XCTAssertTrue(result.contains("data-mnb-writing-direction=\"vertical\""))
        XCTAssertTrue(result.contains("data-mnb-writing-mode=\"vertical-rl\""))
        XCTAssertTrue(result.contains("<p>本文</p>"))
    }

    func testResponseMetadataByteInjectionWrapsHTMLFragment() {
        let result = String(decoding: ebookHTMLDataWithInjectedResponseMetadata(
            Data("<section>本文</section>".utf8),
            baseURL: "ebook://ebook/entry-source/token/chapter.xhtml",
            writingHint: nil,
            bodyAttributes: ["data-test": "ok"]
        ), as: UTF8.self)

        XCTAssertEqual(
            result,
            "<!doctype html><html><head><base href=\"ebook://ebook/entry-source/token/chapter.xhtml\"></head><body data-test=\"ok\"><section>本文</section></body></html>"
        )
    }

    func testResponseMetadataScannerHandlesGreaterThanInsideQuotedAttributesAndInjectsPresentation() {
        let html = "<HTML data-note='1>0'><HEAD data-note=\"2>1\"></HEAD><BODY data-note='3>2' style='color:red'>本文</BODY></HTML>"
        let result = String(decoding: ebookHTMLDataWithInjectedResponseMetadata(
            Data(html.utf8),
            baseURL: "ebook://ebook/entry-source/token/chapter.xhtml",
            writingHint: nil,
            bodyAttributes: ["data-response": "ready"],
            presentation: EbookSectionPresentation(
                bodyAttributes: ["data-presentation": "current"],
                bodyStyleDeclarations: "font-family:'Reader Font';font-size:18px;"
            )
        ), as: UTF8.self)

        XCTAssertTrue(result.contains("<HEAD data-note=\"2>1\"><base href="))
        XCTAssertTrue(result.contains("<BODY data-note='3>2' style='color:red;font-family:&#39;Reader Font&#39;;font-size:18px;' data-presentation=\"current\" data-response=\"ready\">"))
    }

    func testNativeSectionPrewarmReadsEntryAndRunsCacheWarmerProcessor() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let packageRoot = temporaryRoot
            .appendingPathComponent("book.epub", isDirectory: true)
        let contentDirectory = packageRoot
            .appendingPathComponent("item/xhtml", isDirectory: true)
        let chapterURL = contentDirectory
            .appendingPathComponent("chapter.xhtml")
        let chapterHTML = "<html><body>native prewarm</body></html>"

        try FileManager.default.createDirectory(at: contentDirectory, withIntermediateDirectories: true)
        try Data(chapterHTML.utf8).write(to: chapterURL)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        let source = try ReaderPackageEntrySource(localURL: packageRoot)
        let contentURL = URL(string: "ebook://ebook/load/local/Books/test.epub")!
        let actor = EBookProcessingActor(
            ebookTextProcessor: { receivedContentURL, sectionHref, text, _, isCacheWarmer, _, _, _, _ in
                XCTAssertEqual(receivedContentURL, contentURL)
                XCTAssertEqual(sectionHref, "item/xhtml/chapter.xhtml")
                XCTAssertEqual(text, chapterHTML)
                XCTAssertTrue(isCacheWarmer)
                return ebookTestPayload("<html><body>processed</body></html>")
            },
            processReadabilityContent: nil,
            processHTMLDocument: nil,
            processHTMLBytes: nil,
            processHTML: nil
        )

        let result = try await actor.prewarm(
            contentURL: contentURL,
            sectionHref: "item/xhtml/chapter.xhtml",
            source: source
        )

        XCTAssertEqual(result.sectionHref, "item/xhtml/chapter.xhtml")
        XCTAssertEqual(result.requestBytes, chapterHTML.utf8.count)
        XCTAssertEqual(result.responseBytes, "<html><body>processed</body></html>".utf8.count)
        XCTAssertTrue(result.pageStatsRequested)
        XCTAssertFalse(result.pageStatsProduced)
    }

    func testReaderPackageDirectoryEnumerationHandlesStandardizedRootPaths() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let packageRoot = temporaryRoot
            .appendingPathComponent("book.epub", isDirectory: true)
        let contentDirectory = packageRoot
            .appendingPathComponent("OPS", isDirectory: true)
        let chapterURL = contentDirectory
            .appendingPathComponent("chapter1.xhtml")

        try FileManager.default.createDirectory(at: contentDirectory, withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: chapterURL)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        let source = try ReaderPackageEntrySource(localURL: packageRoot)
        let entries = try source.enumerateEntries()

        XCTAssertEqual(entries.map(\.path), ["OPS/chapter1.xhtml"])
    }

    func testReaderPackageArchiveSourceEnumeratesAndReadsEntriesWithoutExpansion() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let archiveURL = temporaryRoot.appendingPathComponent("book.epub")
        let chapterPath = "OPS/chapter1.xhtml"
        let chapterHTML = "<html><body>chapter</body></html>"

        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        guard let archive = Archive(url: archiveURL, accessMode: .create) else {
            XCTFail("Expected archive to be created")
            return
        }
        try archive.addEntry(with: chapterPath, type: .file, uncompressedSize: Int64(chapterHTML.utf8.count)) { position, size in
            let bytes = Array(chapterHTML.utf8)
            return Data(bytes[Int(position)..<Int(position) + size])
        }

        let source = try ReaderPackageEntrySource(localURL: archiveURL)
        let entries = try source.enumerateEntries()

        XCTAssertEqual(entries.map(\.path), [chapterPath])
        XCTAssertEqual(String(decoding: try source.readEntry(subpath: chapterPath), as: UTF8.self), chapterHTML)
    }

    func testCacheWarmerProcessingReturnsProcessedContent() async throws {
        let expectedHTML = "<html><body><manabi-segment>cached</manabi-segment></body></html>"
        let actor = EBookProcessingActor(
            ebookTextProcessor: { _, _, _, _, _, _, _, _, _ in ebookTestPayload(expectedHTML) },
            processReadabilityContent: nil,
            processHTMLDocument: nil,
            processHTMLBytes: nil,
            processHTML: nil
        )

        let result = try await actor.process(
            contentURL: URL(string: "ebook://ebook/load/local/Books/test.epub")!,
            location: "item/xhtml/title.xhtml",
            text: "<html><body>raw</body></html>",
            isCacheWarmer: true
        )

        XCTAssertEqual(String(decoding: result.documentHTML, as: UTF8.self), expectedHTML)
    }

    func testCacheWarmerWithoutProcessorFallsBackToOriginalText() async throws {
        let originalText = "<html><body>raw</body></html>"
        let actor = EBookProcessingActor(
            ebookTextProcessor: nil,
            processReadabilityContent: nil,
            processHTMLDocument: nil,
            processHTMLBytes: nil,
            processHTML: nil
        )

        let result = try await actor.process(
            contentURL: URL(string: "ebook://ebook/load/local/Books/test.epub")!,
            location: "item/xhtml/title.xhtml",
            text: originalText,
            isCacheWarmer: true
        )

        XCTAssertEqual(String(decoding: result.documentHTML, as: UTF8.self), originalText)
    }

    func testSectionProcessingDeduperCoalescesEquivalentInFlightRequests() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/test.epub"))
        let key = EBookSectionProcessingRequestKey(
            contentURL: contentURL,
            location: "chapter.xhtml",
            contentData: Data("本文".utf8)
        )
        let gate = EbookTestGate()
        let invocationCounter = EbookTestInvocationCounter()
        let started = expectation(description: "processing starts")
        let deduper = EBookSectionProcessingDeduper()

        let firstTask = Task {
            try await deduper.process(key: key) {
                await invocationCounter.increment()
                started.fulfill()
                await gate.waitUntilReleased()
                return ebookTestPayload("shared")
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let secondTask = Task {
            try await deduper.process(key: key) {
                XCTFail("Equivalent in-flight work should reuse the active operation")
                return ebookTestPayload("duplicate")
            }
        }
        for _ in 0..<1_000 {
            if await deduper.inFlightWaiterCountForTesting(key: key) > 0 {
                break
            }
            await Task.yield()
        }
        let waiterCount = await deduper.inFlightWaiterCountForTesting(key: key)
        XCTAssertEqual(waiterCount, 1)
        await gate.release()

        let first = try await firstTask.value
        let second = try await secondTask.value
        let invocationCount = await invocationCounter.count
        XCTAssertEqual(String(decoding: first.payload.documentHTML, as: UTF8.self), "shared")
        XCTAssertEqual(String(decoding: second.payload.documentHTML, as: UTF8.self), "shared")
        XCTAssertFalse(first.didCoalesce)
        XCTAssertTrue(second.didCoalesce)
        XCTAssertEqual(invocationCount, 1)
    }

    func testSectionProcessingDeduperDoesNotRetainCompletedResponses() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/test.epub"))
        let key = EBookSectionProcessingRequestKey(
            contentURL: contentURL,
            location: "chapter.xhtml",
            contentData: Data("本文".utf8)
        )
        let deduper = EBookSectionProcessingDeduper()
        let invocationCounter = EbookTestInvocationCounter()

        let first = try await deduper.process(key: key) {
            await invocationCounter.increment()
            return ebookTestPayload("first")
        }
        let second = try await deduper.process(key: key) {
            await invocationCounter.increment()
            return ebookTestPayload("second")
        }

        XCTAssertEqual(String(decoding: first.payload.documentHTML, as: UTF8.self), "first")
        XCTAssertEqual(String(decoding: second.payload.documentHTML, as: UTF8.self), "second")
        XCTAssertFalse(first.didCoalesce)
        XCTAssertFalse(second.didCoalesce)
        let invocationCount = await invocationCounter.count
        XCTAssertEqual(invocationCount, 2)
    }

    func testCacheWarmerDoesNotPopulateDisplayReadyProcessedTextCache() async throws {
        let writerInvocationCounter = EbookTestInvocationCounter()
        let actor = EBookProcessingActor(
            ebookProcessedTextCacheWriter: { _, _, _, _ in
                await writerInvocationCounter.increment()
            },
            ebookTextProcessor: { _, _, _, _, _, _, _, _, _ in
                ebookTestPayload("<html><body>warmer result</body></html>")
            },
            processReadabilityContent: nil,
            processHTMLDocument: nil,
            processHTMLBytes: nil,
            processHTML: nil
        )

        _ = try await actor.process(
            contentURL: URL(string: "ebook://ebook/load/local/Books/test.epub")!,
            location: "item/xhtml/chapter.xhtml",
            text: "<html><body>raw</body></html>",
            isCacheWarmer: true
        )

        let writerInvocationCount = await writerInvocationCounter.count
        XCTAssertEqual(writerInvocationCount, 0)
    }

    func testForegroundProcessingPopulatesDisplayReadyProcessedTextCache() async throws {
        let writerCalled = expectation(description: "display-ready cache writer runs")
        let canonicalJSON = #"{"v":9,"t":{},"s":[]}"#
        let processedHTML = "<html><body>foreground result<script id=\"mnb-segment-metadata\">\(canonicalJSON)</script></body></html>"
        let actor = EBookProcessingActor(
            ebookProcessedTextCacheWriter: { _, _, _, payload in
                XCTAssertEqual(String(decoding: payload.documentHTML, as: UTF8.self), "<html><body>foreground result</body></html>")
                XCTAssertEqual(String(decoding: payload.segmentSidecar, as: UTF8.self), canonicalJSON)
                writerCalled.fulfill()
            },
            ebookTextProcessor: { _, _, _, _, _, _, _, _, _ in
                try XCTUnwrap(splitCanonicalReaderSegmentSidecar(from: Array(processedHTML.utf8)))
            },
            processReadabilityContent: nil,
            processHTMLDocument: nil,
            processHTMLBytes: nil,
            processHTML: nil
        )

        _ = try await actor.process(
            contentURL: URL(string: "ebook://ebook/load/local/Books/test.epub")!,
            location: "item/xhtml/chapter.xhtml",
            text: "<html><body>raw</body></html>",
            isCacheWarmer: false
        )

        await fulfillment(of: [writerCalled], timeout: 1)
    }
}
