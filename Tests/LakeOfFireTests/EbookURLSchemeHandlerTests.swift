import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ZIPFoundation
import SwiftSoup
@testable import LakeOfFireContent
@testable import LakeOfFireCore
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
    sidecar: String = "",
    isAuthoritativelyProcessed: Bool = true
) -> EbookProcessedSectionPayload {
    EbookProcessedSectionPayload(
        documentHTML: Data(documentHTML.utf8),
        segmentSidecar: Data(sidecar.utf8),
        isAuthoritativelyProcessed: isAuthoritativelyProcessed
    )
}

private let ebookTestProcessingVariant = EbookProcessingVariant(
    availableDictionaryIDs: ["jmdict"],
    includeJLPTClasses: false,
    romajiModeEnabled: false
)
private func ebookUTF16Data(
    _ text: String,
    encoding: String.Encoding,
    byteOrderMark: [UInt8] = []
) -> Data {
    var data = Data(byteOrderMark)
    data.append(text.data(using: encoding)!)
    return data
}

private func ebookTestBase64URLToken(for string: String) -> String {
    Data(string.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

final class EbookURLSchemeHandlerTests: XCTestCase {
    func testPathBackedEntryRequestDecodesPackageSubpathExactlyOnce() throws {
        let mainDocumentURL = try XCTUnwrap(
            URL(string: "ebook://ebook/load/local/Books/test.epub")
        )
        let token = ebookTestBase64URLToken(for: mainDocumentURL.absoluteString)

        let literalPercentURL = try XCTUnwrap(
            URL(string: "ebook://ebook/entry-source/\(token)/OPS/chapter%2520name.xhtml")
        )
        let literalPercentRequest = try XCTUnwrap(
            ebookPathBackedEntryRequest(from: literalPercentURL)
        )
        XCTAssertEqual(literalPercentRequest.mainDocumentURL, mainDocumentURL)
        XCTAssertEqual(literalPercentRequest.subpath, "OPS/chapter%20name.xhtml")

        let literalEncodedSlashURL = try XCTUnwrap(
            URL(string: "ebook://ebook/entry-source/\(token)/OPS/chapter%252Fname.xhtml")
        )
        XCTAssertEqual(
            ebookPathBackedEntryRequest(from: literalEncodedSlashURL)?.subpath,
            "OPS/chapter%2Fname.xhtml"
        )

        let whitespaceURL = try XCTUnwrap(
            URL(string: "ebook://ebook/entry-source/\(token)/%20chapter.xhtml%20")
        )
        let whitespaceRequest = try XCTUnwrap(
            ebookPathBackedEntryRequest(from: whitespaceURL)
        )
        XCTAssertEqual(whitespaceRequest.mainDocumentURL, mainDocumentURL)
        XCTAssertEqual(whitespaceRequest.subpath, " chapter.xhtml ")
    }

    func testExternalizingCanonicalSidecarKeepsAggregateAndPublishesRawJSON() throws {
        let canonicalJSON = #"{"v":10,"t":{},"s":[]}"#
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
            segmentSidecar: Data(#"{"v":10,"s":[]}"#.utf8)
        )

        let first = publishingCanonicalReaderSegmentSidecar(payload, scheme: .ebook)
        let second = publishingCanonicalReaderSegmentSidecar(payload, scheme: .ebook)

        XCTAssertEqual(first.endpointURL, second.endpointURL)
        XCTAssertEqual(first.signature, second.signature)
        let responseDocument = String(decoding: ebookHTMLDataWithInjectedResponseMetadata(
            first.documentHTML,
            baseURL: "ebook://ebook/entry-source/token/chapter.xhtml",
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
        let canonicalJSON = #"{"v":10,"t":{"語":[1]},"s":[]}"#
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
        legacyEncoded.replaceSubrange(0..<7, with: Array("MNBPSC3".utf8))

        XCTAssertNil(decodedEbookProcessedSectionCacheValue(legacyEncoded))
    }

    func testProcessedSidecarCacheRequiresDurableIdentityForEverySegment() {
        let valid = EbookProcessedSectionPayload(
            documentHTML: Data("<m-m id=runtime>text</m-m>".utf8),
            segmentSidecar: Data(#"{"v":10,"t":{"h":["hash"],"sid":["sentence"]},"s":[["!runtime",0,null,null,null,null,null,null,null,0]]}"#.utf8)
        )
        let missingSentenceIdentity = EbookProcessedSectionPayload(
            documentHTML: Data("<m-m id=runtime>text</m-m>".utf8),
            segmentSidecar: Data(#"{"v":10,"t":{"h":["hash"],"sid":[]},"s":[["!runtime",0]]}"#.utf8)
        )
        let previousSchemaVersion = EbookProcessedSectionPayload(
            documentHTML: Data("<m-m id=runtime>text</m-m>".utf8),
            segmentSidecar: Data(#"{"v":9,"t":{"h":["hash"],"sid":["sentence"]},"s":[["!runtime",0,null,null,null,null,null,null,null,0]]}"#.utf8)
        )

        XCTAssertTrue(ebookProcessedSectionPayloadHasDurableSegmentIdentities(valid))
        XCTAssertFalse(ebookProcessedSectionPayloadHasDurableSegmentIdentities(missingSentenceIdentity))
        XCTAssertFalse(ebookProcessedSectionPayloadHasDurableSegmentIdentities(previousSchemaVersion))
    }

    func testProcessedSidecarCacheRejectsMissingOrIncompleteSegmentCoverage() {
        let documentHTML = Data("<html><body><m-m id=a>A</m-m><m-m id=b>B</m-m></body></html>".utf8)
        let missingSidecar = EbookProcessedSectionPayload(
            documentHTML: documentHTML,
            segmentSidecar: Data()
        )
        let emptySidecar = EbookProcessedSectionPayload(
            documentHTML: documentHTML,
            segmentSidecar: Data(#"{"v":10,"t":{"h":[],"sid":[]},"s":[]}"#.utf8)
        )
        let incompleteSidecar = EbookProcessedSectionPayload(
            documentHTML: documentHTML,
            segmentSidecar: Data(#"{"v":10,"t":{"h":["hash"],"sid":["sentence"]},"s":[["a",0,null,null,null,null,null,null,null,0]]}"#.utf8)
        )
        let segmentFreeDocument = EbookProcessedSectionPayload(
            documentHTML: Data("<html><body><m-metadata>Plain text</m-metadata></body></html>".utf8),
            segmentSidecar: Data()
        )
        let nonAuthoritativeFallback = EbookProcessedSectionPayload(
            documentHTML: Data("<html><body>Raw fallback</body></html>".utf8),
            segmentSidecar: Data(),
            isAuthoritativelyProcessed: false
        )

        XCTAssertFalse(ebookProcessedSectionPayloadHasDurableSegmentIdentities(missingSidecar))
        XCTAssertFalse(ebookProcessedSectionPayloadHasDurableSegmentIdentities(emptySidecar))
        XCTAssertFalse(ebookProcessedSectionPayloadHasDurableSegmentIdentities(incompleteSidecar))
        XCTAssertTrue(ebookProcessedSectionPayloadHasDurableSegmentIdentities(segmentFreeDocument))
        XCTAssertFalse(ebookProcessedSectionPayloadHasDurableSegmentIdentities(nonAuthoritativeFallback))
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
            bodyAttributes: ["data-mnb-native-cache-outcome": "final-direct-hit"]
        ), as: UTF8.self)

        XCTAssertTrue(result.contains("<HEAD><base href=\"ebook://ebook/entry-source/token/chapter.xhtml?x=1&amp;y=2\">"))
        XCTAssertTrue(result.contains("<BODY class=\"book\""))
        XCTAssertTrue(result.contains("data-mnb-native-cache-outcome=\"final-direct-hit\""))
        XCTAssertFalse(result.contains("data-mnb-writing-direction="))
        XCTAssertFalse(result.contains("data-mnb-writing-mode="))
        XCTAssertTrue(result.contains("<p>本文</p>"))
    }

    func testResponseMetadataByteInjectionWrapsHTMLFragment() {
        let result = String(decoding: ebookHTMLDataWithInjectedResponseMetadata(
            Data("<section>本文</section>".utf8),
            baseURL: "ebook://ebook/entry-source/token/chapter.xhtml",
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
            bodyAttributes: ["data-response": "ready"],
            presentation: EbookSectionPresentation(
                revision: "presentation-1",
                bodyAttributes: ["data-mnb-dark-theme": "current"],
                bodyStyleProperties: [
                    "font-family": "'not allowlisted'",
                    "font-size": "18px",
                ]
            )
        ), as: UTF8.self)

        XCTAssertTrue(result.contains("<HEAD data-note=\"2>1\"><base href="))
        XCTAssertTrue(result.contains("<BODY data-note='3>2' style='color:red;font-size:18px!important;' data-mnb-dark-theme=\"current\" data-mnb-presentation-revision=\"presentation-1\" data-mnb-presentation-schema-version=\"1\" data-response=\"ready\">"))
    }

    func testResponseMetadataReplacesManagedPresentationAttributesBeforeLayout() {
        let html = """
        <html><head></head><body data-mnb-dark-theme="stale" data-mnb-settings-initialized="false" data-publisher="kept" style="color:red;font-size:9px">Text</body></html>
        """
        let result = String(decoding: ebookHTMLDataWithInjectedResponseMetadata(
            Data(html.utf8),
            baseURL: "ebook://ebook/entry-source/token/chapter.xhtml",
            bodyAttributes: [:],
            presentation: EbookSectionPresentation(
                revision: "presentation-2",
                bodyAttributes: [
                    "data-mnb-dark-theme": "current",
                    "data-mnb-settings-initialized": "true",
                    "data-publisher": "not-allowlisted",
                ],
                bodyStyleProperties: [
                    "font-size": "18px",
                    "background": "red",
                    "font-weight": "600;display:none",
                ]
            )
        ), as: UTF8.self)

        XCTAssertEqual(result.components(separatedBy: "data-mnb-dark-theme=").count - 1, 1)
        XCTAssertEqual(result.components(separatedBy: "data-mnb-settings-initialized=").count - 1, 1)
        XCTAssertTrue(result.contains("data-mnb-dark-theme=\"current\""))
        XCTAssertTrue(result.contains("data-mnb-settings-initialized=\"true\""))
        XCTAssertTrue(result.contains("data-mnb-presentation-schema-version=\"1\""))
        XCTAssertTrue(result.contains("data-mnb-presentation-revision=\"presentation-2\""))
        XCTAssertTrue(result.contains("data-publisher=\"kept\""))
        XCTAssertFalse(result.contains("not-allowlisted"))
        XCTAssertTrue(result.contains("style=\"color:red;font-size:9px;font-size:18px!important;\""))
        XCTAssertFalse(result.contains("background:red"))
        XCTAssertFalse(result.contains("display:none"))
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
        XCTAssertEqual(result.pageStatsOutcome, .unsupported)
    }

    func testNativeSectionPrewarmDecodesUTF16SourceText() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let packageRoot = temporaryRoot
            .appendingPathComponent("book.epub", isDirectory: true)
        let contentDirectory = packageRoot
            .appendingPathComponent("item/xhtml", isDirectory: true)
        let chapterURL = contentDirectory
            .appendingPathComponent("chapter.xhtml")
        let chapterHTML = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>日本語</body></html>"
        let chapterData = ebookUTF16Data(
            chapterHTML,
            encoding: .utf16LittleEndian,
            byteOrderMark: [0xFF, 0xFE]
        )

        try FileManager.default.createDirectory(at: contentDirectory, withIntermediateDirectories: true)
        try chapterData.write(to: chapterURL)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        let source = try ReaderPackageEntrySource(localURL: packageRoot)
        let actor = EBookProcessingActor(
            ebookTextProcessor: { _, _, text, _, isCacheWarmer, _, _, _, _ in
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
            contentURL: URL(string: "ebook://ebook/load/local/Books/test.epub")!,
            sectionHref: "item/xhtml/chapter.xhtml",
            source: source
        )

        XCTAssertEqual(result.requestBytes, chapterData.count)
    }

    func testReaderPackageEntrySourceDetectsAndDecodesUTF16PublicationResources() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        let source = try ReaderPackageEntrySource(localURL: temporaryRoot)
        let text = "<package>日本語</package>"
        let littleEndianWithBOM = ebookUTF16Data(
            text,
            encoding: .utf16LittleEndian,
            byteOrderMark: [0xFF, 0xFE]
        )
        let bigEndianWithBOM = ebookUTF16Data(
            text,
            encoding: .utf16BigEndian,
            byteOrderMark: [0xFE, 0xFF]
        )
        let littleEndianXMLSignature = ebookUTF16Data(text, encoding: .utf16LittleEndian)
        let bigEndianXMLSignature = ebookUTF16Data(text, encoding: .utf16BigEndian)

        XCTAssertEqual(ReaderPackageEntrySource.decodeText(littleEndianWithBOM), text)
        XCTAssertEqual(ReaderPackageEntrySource.decodeText(bigEndianWithBOM), text)
        XCTAssertEqual(ReaderPackageEntrySource.decodeText(littleEndianXMLSignature), text)
        XCTAssertEqual(ReaderPackageEntrySource.decodeText(bigEndianXMLSignature), text)
        let packageMetadata = try source.mimeType(
            subpath: "OPS/package.opf",
            data: littleEndianWithBOM
        )
        XCTAssertEqual(packageMetadata.textEncodingName, "utf-16le")
        let packageResponse = ebookHTTPResponse(
            url: URL(string: "ebook://ebook/entry?subpath=OPS/package.opf")!,
            mimeType: packageMetadata.mimeType,
            byteCount: littleEndianWithBOM.count,
            textEncodingName: packageMetadata.textEncodingName
        )
        XCTAssertEqual(
            packageResponse.value(forHTTPHeaderField: "Content-Type"),
            "application/oebps-package+xml; charset=utf-16le"
        )
        XCTAssertEqual(
            try source.mimeType(subpath: "OPS/chapter.xhtml", data: bigEndianWithBOM).textEncodingName,
            "utf-16be"
        )
        XCTAssertEqual(
            try source.mimeType(subpath: "OPS/book.css", data: Data("body {}".utf8)).textEncodingName,
            "utf-8"
        )
        XCTAssertNil(
            try source.mimeType(subpath: "OPS/cover.png", data: littleEndianWithBOM).textEncodingName
        )
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

    func testReaderPackageEntrySourcePreservesExactWhitespaceAndPercentPaths() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let packageRoot = temporaryRoot
            .appendingPathComponent("book.epub", isDirectory: true)
        let contentDirectory = packageRoot
            .appendingPathComponent("OPS", isDirectory: true)
        let payloads = [
            "OPS/chapter.xhtml": "plain",
            "OPS/chapter.xhtml ": "trailing-space",
            "OPS/chapter.xhtml\u{00A0}": "trailing-nonbreaking-space",
            "OPS/styles.css ": "body {}",
            "OPS/chapter%20.xhtml": "literal-percent",
            "OPS/chapter%2Fname.xhtml": "literal-encoded-slash",
            " chapter.xhtml ": "root-whitespace",
        ]

        try FileManager.default.createDirectory(
            at: contentDirectory,
            withIntermediateDirectories: true
        )
        for (subpath, payload) in payloads {
            let fileURL = packageRoot.appendingPathComponent(subpath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(payload.utf8).write(to: fileURL)
        }
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let source = try ReaderPackageEntrySource(localURL: packageRoot)
        XCTAssertEqual(Set(try source.enumerateEntries().map(\.path)), Set(payloads.keys))
        for (subpath, payload) in payloads {
            XCTAssertEqual(
                String(decoding: try source.readEntry(subpath: subpath), as: UTF8.self),
                payload
            )
            XCTAssertEqual(try ReaderPackageEntrySource.sanitizeSubpath(subpath), subpath)
        }
        let xhtmlMetadata = try source.mimeType(subpath: "OPS/chapter.xhtml ")
        XCTAssertEqual(xhtmlMetadata.mimeType, "application/xhtml+xml")
        XCTAssertEqual(xhtmlMetadata.textEncodingName, "utf-8")

        let nonbreakingSpaceXHTMLMetadata = try source.mimeType(
            subpath: "OPS/chapter.xhtml\u{00A0}"
        )
        XCTAssertEqual(nonbreakingSpaceXHTMLMetadata.mimeType, "application/xhtml+xml")
        XCTAssertEqual(nonbreakingSpaceXHTMLMetadata.textEncodingName, "utf-8")

        let cssMetadata = try source.mimeType(subpath: "OPS/styles.css ")
        XCTAssertEqual(cssMetadata.mimeType, "text/css")
        XCTAssertEqual(cssMetadata.textEncodingName, "utf-8")
    }

    func testReaderPackageEntrySourceUsesCanonicalImageMIMETypes() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let packageRoot = temporaryRoot
            .appendingPathComponent("book.epub", isDirectory: true)
        try FileManager.default.createDirectory(
            at: packageRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let source = try ReaderPackageEntrySource(localURL: packageRoot)
        XCTAssertEqual(
            try source.mimeType(subpath: "OPS/cover.jpg").mimeType,
            "image/jpeg"
        )
        XCTAssertEqual(
            try source.mimeType(subpath: "OPS/cover.svg").mimeType,
            "image/svg+xml"
        )
    }

    func testReaderPackageImageDataUsesContainedPackageEntrySource() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let packageRoot = temporaryRoot
            .appendingPathComponent("book.epub", isDirectory: true)
        let contentDirectory = packageRoot
            .appendingPathComponent("OPS", isDirectory: true)
        let coverURL = contentDirectory.appendingPathComponent("cover.png")
        let outsideURL = temporaryRoot.appendingPathComponent("outside.png")
        let coverData = Data([0x89, 0x50, 0x4E, 0x47])

        try FileManager.default.createDirectory(
            at: contentDirectory,
            withIntermediateDirectories: true
        )
        try coverData.write(to: coverURL)
        try Data("outside".utf8).write(to: outsideURL)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        XCTAssertEqual(
            try readerPackageImageData(
                localPackageURL: packageRoot,
                subpath: "OPS/cover.png"
            ),
            coverData
        )
        XCTAssertThrowsError(
            try readerPackageImageData(
                localPackageURL: packageRoot,
                subpath: "../outside.png"
            )
        ) { error in
            guard case ReaderPackageEntrySourceError.invalidSubpath = error else {
                XCTFail("Expected traversal to fail closed, got \(error)")
                return
            }
        }
    }

    func testReaderPackageEntrySourceResolvesRendererCompatibleRelativeHrefs() {
        XCTAssertEqual(
            ReaderPackageEntrySource.resolveSubpath(
                "../Images/cover%20art.jpg#thumbnail",
                relativeTo: "OPS/Text"
            ),
            "OPS/Images/cover art.jpg"
        )
        XCTAssertEqual(
            ReaderPackageEntrySource.resolveSubpath(
                "chapter%2Fpart.xhtml",
                relativeTo: "OPS"
            ),
            "OPS/chapter%2Fpart.xhtml"
        )
        XCTAssertEqual(
            ReaderPackageEntrySource.resolveSubpath(
                " chapter.xhtml ",
                relativeTo: "OPS"
            ),
            "OPS/chapter.xhtml"
        )
        XCTAssertEqual(
            ReaderPackageEntrySource.resolveSubpath(
                "\u{00A0}chapter.xhtml\u{00A0}",
                relativeTo: "OPS"
            ),
            "OPS/\u{00A0}chapter.xhtml\u{00A0}"
        )
        XCTAssertEqual(
            ReaderPackageEntrySource.resolveSubpath(
                "OPS/chapter:one/package.opf",
                relativeTo: ""
            ),
            "OPS/chapter:one/package.opf"
        )
        XCTAssertNil(
            ReaderPackageEntrySource.resolveSubpath(
                "web+epub:external.opf",
                relativeTo: "OPS"
            )
        )
        XCTAssertNil(
            ReaderPackageEntrySource.resolveSubpath(
                "../../../outside.jpg",
                relativeTo: "OPS/Text"
            )
        )
    }

    func testEPubParserUsesTypedContainedPackageAndNormalizesCoverHref() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let packageRoot = temporaryRoot
            .appendingPathComponent("book.epub", isDirectory: true)
        let metadataDirectory = packageRoot
            .appendingPathComponent("META-INF", isDirectory: true)
        let opfDirectory = packageRoot
            .appendingPathComponent("OPS/Text", isDirectory: true)
        let imageDirectory = packageRoot
            .appendingPathComponent("OPS/Images", isDirectory: true)
        let outsideOPF = temporaryRoot.appendingPathComponent("outside.opf")

        try FileManager.default.createDirectory(
            at: metadataDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: opfDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: imageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let containerXML = """
        <?xml version="1.0"?>
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="../outside.opf" media-type="application/x-other"/>
            <rootfile full-path="OPS/Text/package.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        try Data(containerXML.utf8).write(
            to: metadataDirectory.appendingPathComponent("container.xml")
        )

        let insideOPF = """
        <package version="3.0" xmlns="http://www.idpf.org/2007/opf"
                 xmlns:dc="http://purl.org/dc/elements/1.1/">
          <metadata>
            <dc:title>Inside Book</dc:title>
            <dc:creator>Inside Author</dc:creator>
          </metadata>
          <manifest>
            <item id="cover" properties="cover-image"
                  href="../Images/cover%20art.jpg" media-type="image/jpeg"/>
            <item id="not-cover" properties="not-cover-image"
                  href="../../../outside.jpg" media-type="image/jpeg"/>
          </manifest>
        </package>
        """
        try Data(insideOPF.utf8).write(
            to: opfDirectory.appendingPathComponent("package.opf")
        )
        try Data([0xFF, 0xD8, 0xFF]).write(
            to: imageDirectory.appendingPathComponent("cover art.jpg")
        )

        let outsideDocument = """
        <package version="3.0" xmlns:dc="http://purl.org/dc/elements/1.1/">
          <metadata><dc:title>Outside Book</dc:title></metadata>
          <manifest>
            <item id="cover" properties="cover-image"
                  href="outside.jpg" media-type="image/jpeg"/>
          </manifest>
        </package>
        """
        try Data(outsideDocument.utf8).write(to: outsideOPF)

        let metadata = try XCTUnwrap(
            EPubParser.parseMetadataAndCover(from: packageRoot)
        )
        XCTAssertEqual(metadata.title, "Inside Book")
        XCTAssertEqual(metadata.author, "Inside Author")
        let coverHref = try XCTUnwrap(metadata.coverHref)
        XCTAssertEqual(coverHref, "OPS/Images/cover art.jpg")
        XCTAssertEqual(
            try readerPackageImageData(
                localPackageURL: packageRoot,
                subpath: coverHref
            ),
            Data([0xFF, 0xD8, 0xFF])
        )
    }

    func testEPubParserResolvesContainerRootfileURLExactlyOnce() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let packageRoot = temporaryRoot
            .appendingPathComponent("book.epub", isDirectory: true)
        let metadataDirectory = packageRoot
            .appendingPathComponent("META-INF", isDirectory: true)
        let opfDirectory = packageRoot
            .appendingPathComponent("OPS", isDirectory: true)
        let packageURL = opfDirectory
            .appendingPathComponent("package%2Fname x.opf")

        try FileManager.default.createDirectory(
            at: metadataDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: opfDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        try Data("""
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OPS/package%252Fname%20x.opf"
                      media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """.utf8).write(
            to: metadataDirectory.appendingPathComponent("container.xml")
        )
        try Data("""
        <package xmlns="http://www.idpf.org/2007/opf"
                 xmlns:dc="http://purl.org/dc/elements/1.1/"
                 version="3.0">
          <metadata><dc:title>Encoded Package Path</dc:title></metadata>
          <manifest/>
        </package>
        """.utf8).write(to: packageURL)

        let metadata = try XCTUnwrap(
            EPubParser.parseMetadataAndCover(from: packageRoot)
        )
        XCTAssertEqual(metadata.title, "Encoded Package Path")
    }

    func testEPubParserSupportsNamespaceQualifiedPackageAndUsesPrimaryMetadata() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let packageRoot = temporaryRoot
            .appendingPathComponent("book.epub", isDirectory: true)
        let metadataDirectory = packageRoot
            .appendingPathComponent("META-INF", isDirectory: true)
        let opfDirectory = packageRoot
            .appendingPathComponent("OPS", isDirectory: true)
        let imageDirectory = opfDirectory
            .appendingPathComponent("Images", isDirectory: true)

        try FileManager.default.createDirectory(
            at: metadataDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: imageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let containerXML = """
        <?xml version="1.0"?>
        <c:container xmlns:c="urn:oasis:names:tc:opendocument:xmlns:container">
          <c:rootfiles>
            <c:rootfile full-path="OPS/package.opf"
                        media-type="application/oebps-package+xml"/>
          </c:rootfiles>
        </c:container>
        """
        try Data(containerXML.utf8).write(
            to: metadataDirectory.appendingPathComponent("container.xml")
        )

        let packageDocument = """
        <pkg:package xmlns:pkg="http://www.idpf.org/2007/opf"
                     xmlns:dc="http://purl.org/dc/elements/1.1/"
                     version="3.0">
          <pkg:metadata>
            <dc:title>Primary
              Title</dc:title>
            <dc:title>Secondary Title</dc:title>
            <dc:creator>Primary
              Author</dc:creator>
            <dc:creator>Secondary Author</dc:creator>
            <pkg:meta name="cover" content="legacy-cover"/>
          </pkg:metadata>
          <pkg:manifest>
            <pkg:item id="legacy-cover" href="Images/legacy.jpg"
                      media-type="image/jpeg"/>
            <pkg:item id="primary-cover" href="Images/primary.jpg"
                      media-type="image/jpeg" properties="other cover-image"/>
          </pkg:manifest>
          <pkg:spine/>
        </pkg:package>
        """
        try Data(packageDocument.utf8).write(
            to: opfDirectory.appendingPathComponent("package.opf")
        )
        try Data([0xFF, 0xD8, 0xFF]).write(
            to: imageDirectory.appendingPathComponent("primary.jpg")
        )

        let metadata = try XCTUnwrap(
            EPubParser.parseMetadataAndCover(from: packageRoot)
        )
        XCTAssertEqual(metadata.title, "Primary Title")
        XCTAssertEqual(metadata.author, "Primary Author")
        XCTAssertEqual(metadata.coverHref, "OPS/Images/primary.jpg")
    }

    func testEPubParserKeepsCoverlessMetadataAndParsesW3CDatePrecisions() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let packageRoot = temporaryRoot
            .appendingPathComponent("book.epub", isDirectory: true)
        let metadataDirectory = packageRoot
            .appendingPathComponent("META-INF", isDirectory: true)
        let opfDirectory = packageRoot
            .appendingPathComponent("OPS", isDirectory: true)

        try FileManager.default.createDirectory(
            at: metadataDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: opfDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        try Data("""
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OPS/package.opf"
                      media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """.utf8).write(
            to: metadataDirectory.appendingPathComponent("container.xml")
        )
        try Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"></html>".utf8)
            .write(to: opfDirectory.appendingPathComponent("chapter.xhtml"))

        let cases: [(value: String, year: Int, month: Int, day: Int, hour: Int, minute: Int)] = [
            ("2024", 2024, 1, 1, 0, 0),
            ("2024-05", 2024, 5, 1, 0, 0),
            ("2024-05-12", 2024, 5, 12, 0, 0),
            ("2024-05-12T14:30Z", 2024, 5, 12, 14, 30),
            ("2024-05-12T14:30:45Z", 2024, 5, 12, 14, 30),
            ("2024-05-12T14:30:45.125Z", 2024, 5, 12, 14, 30),
        ]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        for (index, testCase) in cases.enumerated() {
            let optionalUnsafeCover = index.isMultiple(of: 2) ? "" : """
                <item id="cover" href="../../outside.jpg"
                      media-type="image/jpeg" properties="cover-image"/>
            """
            let packageDocument = """
            <package xmlns="http://www.idpf.org/2007/opf"
                     xmlns:dc="http://purl.org/dc/elements/1.1/"
                     version="3.0">
              <metadata>
                <dc:title>Coverless Book</dc:title>
                <dc:creator>Metadata Author</dc:creator>
                <dc:date>\(testCase.value)</dc:date>
              </metadata>
              <manifest>
                <item id="chapter" href="chapter.xhtml"
                      media-type="application/xhtml+xml"/>
                \(optionalUnsafeCover)
              </manifest>
              <spine><itemref idref="chapter"/></spine>
            </package>
            """
            try Data(packageDocument.utf8).write(
                to: opfDirectory.appendingPathComponent("package.opf")
            )

            let metadata = try XCTUnwrap(
                EPubParser.parseMetadataAndCover(from: packageRoot),
                "Failed to parse \(testCase.value)"
            )
            XCTAssertEqual(metadata.title, "Coverless Book")
            XCTAssertEqual(metadata.author, "Metadata Author")
            XCTAssertNil(metadata.coverHref)
            let publicationDate = try XCTUnwrap(metadata.publicationDate)
            let dateComponents = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: publicationDate
            )
            XCTAssertEqual(dateComponents.year, testCase.year)
            XCTAssertEqual(dateComponents.month, testCase.month)
            XCTAssertEqual(dateComponents.day, testCase.day)
            XCTAssertEqual(dateComponents.hour, testCase.hour)
            XCTAssertEqual(dateComponents.minute, testCase.minute)
        }
    }

    func testEPubParserIgnoresNestedPackageLookalikes() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let packageRoot = temporaryRoot
            .appendingPathComponent("book.epub", isDirectory: true)
        let metadataDirectory = packageRoot
            .appendingPathComponent("META-INF", isDirectory: true)
        let opfDirectory = packageRoot
            .appendingPathComponent("OPS", isDirectory: true)
        let imageDirectory = opfDirectory
            .appendingPathComponent("Images", isDirectory: true)

        try FileManager.default.createDirectory(
            at: metadataDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: imageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        try Data("""
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OPS/package.opf"
                      media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """.utf8).write(
            to: metadataDirectory.appendingPathComponent("container.xml")
        )

        try Data("""
        <package xmlns:dc="http://purl.org/dc/elements/1.1/"
                 xmlns:ext="urn:example:extension"
                 version="3.0">
          <metadata>
            <dc:title>Primary Title</dc:title>
            <ext:wrapper>
              <metadata><dc:title>Nested Title</dc:title></metadata>
            </ext:wrapper>
          </metadata>
          <manifest>
            <item id="cover" href="Images/primary.jpg"
                  media-type="image/jpeg" properties="cover-image"/>
          </manifest>
          <ext:wrapper>
            <manifest>
              <item id="nested-cover" href="Images/nested.jpg"
                    media-type="image/jpeg" properties="cover-image"/>
            </manifest>
          </ext:wrapper>
          <spine/>
        </package>
        """.utf8).write(to: opfDirectory.appendingPathComponent("package.opf"))
        try Data([0xFF, 0xD8, 0xFF]).write(
            to: imageDirectory.appendingPathComponent("primary.jpg")
        )

        let metadata = try XCTUnwrap(
            EPubParser.parseMetadataAndCover(from: packageRoot)
        )
        XCTAssertEqual(metadata.title, "Primary Title")
        XCTAssertEqual(metadata.coverHref, "OPS/Images/primary.jpg")
    }

    func testEPubParserIgnoresNestedContainerRootfileLookalikes() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let packageRoot = temporaryRoot
            .appendingPathComponent("book.epub", isDirectory: true)
        let metadataDirectory = packageRoot
            .appendingPathComponent("META-INF", isDirectory: true)
        let opfDirectory = packageRoot
            .appendingPathComponent("OPS", isDirectory: true)

        try FileManager.default.createDirectory(
            at: metadataDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: opfDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let containerXML = """
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
                   xmlns:ext="urn:example:extension">
          <ext:wrapper>
            <rootfile full-path="OPS/package.opf"
                      media-type="application/oebps-package+xml"/>
          </ext:wrapper>
        </container>
        """
        try Data(containerXML.utf8).write(
            to: metadataDirectory.appendingPathComponent("container.xml")
        )
        try Data("""
        <package xmlns="http://www.idpf.org/2007/opf"
                 xmlns:dc="http://purl.org/dc/elements/1.1/"
                 version="3.0">
          <metadata><dc:title>Nested Rootfile</dc:title></metadata>
          <manifest>
            <item id="cover" href="cover.jpg" properties="cover-image"
                  media-type="image/jpeg"/>
          </manifest>
          <spine/>
        </package>
        """.utf8).write(to: opfDirectory.appendingPathComponent("package.opf"))

        XCTAssertNil(try EPubParser.parseMetadataAndCover(from: packageRoot))
    }

    func testEPubParserRejectsMalformedContainerAfterTypedRootfile() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let packageRoot = temporaryRoot
            .appendingPathComponent("book.epub", isDirectory: true)
        let metadataDirectory = packageRoot
            .appendingPathComponent("META-INF", isDirectory: true)
        let opfDirectory = packageRoot
            .appendingPathComponent("OPS", isDirectory: true)

        try FileManager.default.createDirectory(
            at: metadataDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: opfDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let malformedContainer = """
        <container><rootfiles>
          <rootfile full-path="OPS/package.opf"
                    media-type="application/oebps-package+xml"/>
        """
        try Data(malformedContainer.utf8).write(
            to: metadataDirectory.appendingPathComponent("container.xml")
        )
        try Data("""
        <package version="3.0" xmlns:dc="http://purl.org/dc/elements/1.1/">
          <metadata><dc:title>Partial Book</dc:title></metadata>
          <manifest>
            <item id="cover" properties="cover-image"
                  href="cover.jpg" media-type="image/jpeg"/>
          </manifest>
        </package>
        """.utf8).write(to: opfDirectory.appendingPathComponent("package.opf"))

        XCTAssertNil(try EPubParser.parseMetadataAndCover(from: packageRoot))
    }

    func testReaderPackageDirectoryEnumerationIncludesDotPrefixedPackageResources() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let packageRoot = temporaryRoot
            .appendingPathComponent("book.epub", isDirectory: true)
        let hiddenDirectory = packageRoot
            .appendingPathComponent("OPS/.assets", isDirectory: true)
        let hiddenChapterURL = hiddenDirectory
            .appendingPathComponent(".chapter.xhtml")

        try FileManager.default.createDirectory(at: hiddenDirectory, withIntermediateDirectories: true)
        try Data("<html></html>".utf8).write(to: hiddenChapterURL)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        let source = try ReaderPackageEntrySource(localURL: packageRoot)
        let entries = try source.enumerateEntries()

        XCTAssertEqual(entries.map(\.path), ["OPS/.assets/.chapter.xhtml"])
        XCTAssertEqual(
            String(decoding: try source.readEntry(subpath: "OPS/.assets/.chapter.xhtml"), as: UTF8.self),
            "<html></html>"
        )
    }

    func testReaderPackageDirectorySourceRejectsEmbeddedNullSubpaths() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let packageRoot = temporaryRoot
            .appendingPathComponent("book.epub", isDirectory: true)
        let contentDirectory = packageRoot
            .appendingPathComponent("OPS", isDirectory: true)
        let chapterURL = contentDirectory
            .appendingPathComponent("chapter.xhtml")

        try FileManager.default.createDirectory(
            at: contentDirectory,
            withIntermediateDirectories: true
        )
        try Data("<html></html>".utf8).write(to: chapterURL)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let source = try ReaderPackageEntrySource(localURL: packageRoot)
        XCTAssertThrowsError(
            try source.readEntry(subpath: "OPS/chapter.xhtml\0ignored")
        ) { error in
            guard case ReaderPackageEntrySourceError.invalidSubpath = error else {
                XCTFail("Expected invalidSubpath for embedded NUL, got \(error)")
                return
            }
        }
    }

    func testReaderPackageDirectorySourceRejectsNonRegularEntriesWithoutBlocking() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let packageRoot = temporaryRoot
            .appendingPathComponent("book.epub", isDirectory: true)
        let metadataDirectory = packageRoot
            .appendingPathComponent("META-INF", isDirectory: true)
        let fifoURL = metadataDirectory
            .appendingPathComponent("container.xml")

        try FileManager.default.createDirectory(
            at: metadataDirectory,
            withIntermediateDirectories: true
        )
        XCTAssertEqual(mkfifo(fifoURL.path, mode_t(0o600)), 0)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let source = try ReaderPackageEntrySource(localURL: packageRoot)
        XCTAssertThrowsError(
            try source.readEntry(subpath: "META-INF/container.xml")
        ) { error in
            guard case ReaderPackageEntrySourceError.invalidSubpath = error else {
                XCTFail("Expected invalidSubpath for FIFO entry, got \(error)")
                return
            }
        }
    }

    func testReaderPackageDirectorySourceRejectsSymbolicLinkEscapes() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let packageRoot = temporaryRoot
            .appendingPathComponent("book.epub", isDirectory: true)
        let linkedPackageRoot = temporaryRoot
            .appendingPathComponent("linked-book.epub", isDirectory: true)
        let contentDirectory = packageRoot
            .appendingPathComponent("OPS", isDirectory: true)
        let chapterURL = contentDirectory
            .appendingPathComponent("chapter.xhtml")
        let outsideDirectory = temporaryRoot
            .appendingPathComponent("outside", isDirectory: true)
        let outsideChapterURL = outsideDirectory
            .appendingPathComponent("secret.xhtml")
        let escapedDirectoryURL = contentDirectory
            .appendingPathComponent("escaped", isDirectory: true)
        let escapedFileURL = contentDirectory
            .appendingPathComponent("escaped-file.xhtml")

        try FileManager.default.createDirectory(at: contentDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        try Data("<html>inside</html>".utf8).write(to: chapterURL)
        try Data("<html>outside</html>".utf8).write(to: outsideChapterURL)
        try FileManager.default.createSymbolicLink(at: linkedPackageRoot, withDestinationURL: packageRoot)
        try FileManager.default.createSymbolicLink(at: escapedDirectoryURL, withDestinationURL: outsideDirectory)
        try FileManager.default.createSymbolicLink(at: escapedFileURL, withDestinationURL: outsideChapterURL)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        let source = try ReaderPackageEntrySource(localURL: linkedPackageRoot)
        XCTAssertEqual(try source.enumerateEntries().map(\.path), ["OPS/chapter.xhtml"])
        XCTAssertEqual(
            String(decoding: try source.readEntry(subpath: "OPS/chapter.xhtml"), as: UTF8.self),
            "<html>inside</html>"
        )
        for escapedSubpath in ["OPS/escaped/secret.xhtml", "OPS/escaped-file.xhtml"] {
            XCTAssertThrowsError(try source.readEntry(subpath: escapedSubpath)) { error in
                guard case ReaderPackageEntrySourceError.invalidSubpath = error else {
                    XCTFail("Expected invalidSubpath for \(escapedSubpath), got \(error)")
                    return
                }
            }
        }
    }

    func testReaderPackageDirectorySourceRejectsReplacedAncestorSymlink() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let originalParent = temporaryRoot
            .appendingPathComponent("mounted", isDirectory: true)
        let movedParent = temporaryRoot
            .appendingPathComponent("mounted-original", isDirectory: true)
        let replacementParent = temporaryRoot
            .appendingPathComponent("replacement", isDirectory: true)
        let originalPackageRoot = originalParent
            .appendingPathComponent("book.epub", isDirectory: true)
        let replacementPackageRoot = replacementParent
            .appendingPathComponent("book.epub", isDirectory: true)
        let originalChapterURL = originalPackageRoot
            .appendingPathComponent("OPS/chapter.xhtml")
        let replacementChapterURL = replacementPackageRoot
            .appendingPathComponent("OPS/chapter.xhtml")

        try fileManager.createDirectory(
            at: originalChapterURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: replacementChapterURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("<html>inside</html>".utf8).write(to: originalChapterURL)
        try Data("<html>outside</html>".utf8).write(to: replacementChapterURL)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let source = try ReaderPackageEntrySource(localURL: originalPackageRoot)
        try fileManager.moveItem(at: originalParent, to: movedParent)
        try fileManager.createSymbolicLink(
            at: originalParent,
            withDestinationURL: replacementParent
        )

        XCTAssertThrowsError(
            try source.readEntry(subpath: "OPS/chapter.xhtml")
        ) { error in
            guard case ReaderPackageEntrySourceError.invalidSubpath = error else {
                XCTFail("Expected invalidSubpath for replaced ancestor symlink, got \(error)")
                return
            }
        }
        XCTAssertThrowsError(try source.enumerateEntries()) { error in
            guard case ReaderPackageEntrySourceError.invalidSubpath = error else {
                XCTFail("Expected invalidSubpath while enumerating replaced directory, got \(error)")
                return
            }
        }
    }

    func testReaderPackageDirectorySourceRejectsReplacedAncestorDirectory() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let mountedParent = temporaryRoot
            .appendingPathComponent("mounted", isDirectory: true)
        let movedParent = temporaryRoot
            .appendingPathComponent("mounted-original", isDirectory: true)
        let packageRoot = mountedParent
            .appendingPathComponent("book.epub", isDirectory: true)
        let chapterURL = packageRoot
            .appendingPathComponent("OPS/chapter.xhtml")

        try fileManager.createDirectory(
            at: chapterURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("<html>inside</html>".utf8).write(to: chapterURL)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let source = try ReaderPackageEntrySource(localURL: packageRoot)
        try fileManager.moveItem(at: mountedParent, to: movedParent)

        let replacementChapterURL = packageRoot
            .appendingPathComponent("OPS/chapter.xhtml")
        try fileManager.createDirectory(
            at: replacementChapterURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("<html>replacement</html>".utf8).write(to: replacementChapterURL)

        XCTAssertThrowsError(
            try source.readEntry(subpath: "OPS/chapter.xhtml")
        ) { error in
            guard case ReaderPackageEntrySourceError.invalidSubpath = error else {
                XCTFail("Expected invalidSubpath for replaced ancestor directory, got \(error)")
                return
            }
        }
    }

#if DEBUG
    func testReaderPackageEntrySourceCacheBoundsRetainedPublicationRecords() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let cache = ReaderPackageEntrySourceCache(maximumSourceCount: 2)
        let readerFileManager = ReaderFileManager()

        for index in 0..<3 {
            let packageRoot = temporaryRoot
                .appendingPathComponent("book-\(index).epub", isDirectory: true)
            let chapterURL = packageRoot
                .appendingPathComponent("OPS/chapter.xhtml")
            try fileManager.createDirectory(
                at: chapterURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("<html>\(index)</html>".utf8).write(to: chapterURL)

            var components = URLComponents()
            components.scheme = "ebook"
            components.host = "ebook"
            components.path = "/load/local/cache-limit-\(index).epub"
            components.queryItems = [
                URLQueryItem(name: "diagnosticLocalFilePath", value: packageRoot.path),
            ]
            let packageURL = try XCTUnwrap(components.url)
            _ = try await cache.cachedSource(
                forPackageURL: packageURL,
                readerFileManager: readerFileManager
            )
        }

        let cachedSourceCount = await cache.cachedSourceCount
        XCTAssertEqual(cachedSourceCount, 2)
    }

    func testReaderPackageEntrySourceCacheInvalidatesWhenOnlyAnEntryPathChanges() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let packageRoot = temporaryRoot
            .appendingPathComponent("book.epub", isDirectory: true)
        let contentDirectory = packageRoot
            .appendingPathComponent("OPS", isDirectory: true)
        let oldChapterURL = contentDirectory
            .appendingPathComponent("old.xhtml")
        let newChapterURL = contentDirectory
            .appendingPathComponent("new.xhtml")
        let anchorURL = contentDirectory
            .appendingPathComponent("anchor.bin")

        try fileManager.createDirectory(at: contentDirectory, withIntermediateDirectories: true)
        try Data("<html>chapter</html>".utf8).write(to: oldChapterURL)
        try Data("anchor".utf8).write(to: anchorURL)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newestDate = fixedDate.addingTimeInterval(3_600)
        func restoreMetadata(chapterURL: URL) throws {
            try fileManager.setAttributes([.modificationDate: fixedDate], ofItemAtPath: packageRoot.path)
            try fileManager.setAttributes([.modificationDate: fixedDate], ofItemAtPath: contentDirectory.path)
            try fileManager.setAttributes([.modificationDate: fixedDate], ofItemAtPath: chapterURL.path)
            try fileManager.setAttributes([.modificationDate: newestDate], ofItemAtPath: anchorURL.path)
        }
        try restoreMetadata(chapterURL: oldChapterURL)

        var components = URLComponents()
        components.scheme = "ebook"
        components.host = "ebook"
        components.path = "/load/local/cache-freshness.epub"
        components.queryItems = [
            URLQueryItem(name: "diagnosticLocalFilePath", value: packageRoot.path),
        ]
        let packageURL = try XCTUnwrap(components.url)
        let cache = ReaderPackageEntrySourceCache()
        let readerFileManager = ReaderFileManager()

        let first = try await cache.cachedSource(
            forPackageURL: packageURL,
            readerFileManager: readerFileManager
        )
        XCTAssertEqual(first.entries.map(\.path), ["OPS/anchor.bin", "OPS/old.xhtml"])

        try fileManager.moveItem(at: oldChapterURL, to: newChapterURL)
        try restoreMetadata(chapterURL: newChapterURL)

        let second = try await cache.cachedSource(
            forPackageURL: packageURL,
            readerFileManager: readerFileManager
        )
        XCTAssertEqual(second.entries.map(\.path), ["OPS/anchor.bin", "OPS/new.xhtml"])
    }

    func testReaderPackageEntrySourceCacheInvalidatesWhenDirectoryIdentityChangesWithoutMetadataChange() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let packageRoot = temporaryRoot
            .appendingPathComponent("book.epub", isDirectory: true)
        let displacedPackageRoot = temporaryRoot
            .appendingPathComponent("book-original.epub", isDirectory: true)
        let chapterSubpath = "OPS/chapter.xhtml"
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

        func installPackage(content: String) throws {
            let chapterURL = packageRoot.appendingPathComponent(chapterSubpath)
            try fileManager.createDirectory(
                at: chapterURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(content.utf8).write(to: chapterURL)
            try fileManager.setAttributes(
                [.modificationDate: fixedDate],
                ofItemAtPath: chapterURL.path
            )
        }

        try installPackage(content: "first")
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        var components = URLComponents()
        components.scheme = "ebook"
        components.host = "ebook"
        components.path = "/load/local/cache-root-identity.epub"
        components.queryItems = [
            URLQueryItem(name: "diagnosticLocalFilePath", value: packageRoot.path),
        ]
        let packageURL = try XCTUnwrap(components.url)
        let cache = ReaderPackageEntrySourceCache()
        let readerFileManager = ReaderFileManager()

        let first = try await cache.cachedSource(
            forPackageURL: packageURL,
            readerFileManager: readerFileManager
        )
        XCTAssertEqual(
            String(decoding: try first.source.readEntry(subpath: chapterSubpath), as: UTF8.self),
            "first"
        )

        try fileManager.moveItem(at: packageRoot, to: displacedPackageRoot)
        try installPackage(content: "other")

        let second = try await cache.cachedSource(
            forPackageURL: packageURL,
            readerFileManager: readerFileManager
        )
        XCTAssertEqual(second.entries.map(\.path), [chapterSubpath])
        XCTAssertEqual(
            String(decoding: try second.source.readEntry(subpath: chapterSubpath), as: UTF8.self),
            "other"
        )
    }

    func testReaderPackageEntrySourceCacheInvalidatesWhenArchiveIdentityChangesWithoutMetadataChange() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let archiveURL = temporaryRoot.appendingPathComponent("book.epub")
        let replacementArchiveURL = temporaryRoot.appendingPathComponent("replacement.epub")
        let displacedArchiveURL = temporaryRoot.appendingPathComponent("book-original.epub")
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

        func createArchive(at url: URL, entryPath: String) throws {
            guard let archive = Archive(url: url, accessMode: .create) else {
                XCTFail("Expected archive to be created at \(url.path)")
                return
            }
            let payload = Data("chapter".utf8)
            try archive.addEntry(
                with: entryPath,
                type: .file,
                uncompressedSize: Int64(payload.count)
            ) { position, size in
                payload.subdata(in: Int(position)..<Int(position) + size)
            }
            try fileManager.setAttributes(
                [.modificationDate: fixedDate],
                ofItemAtPath: url.path
            )
        }

        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        try createArchive(at: archiveURL, entryPath: "OPS/old.xhtml")
        try createArchive(at: replacementArchiveURL, entryPath: "OPS/new.xhtml")
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let originalSize = try XCTUnwrap(
            fileManager.attributesOfItem(atPath: archiveURL.path)[.size] as? NSNumber
        )
        let replacementSize = try XCTUnwrap(
            fileManager.attributesOfItem(atPath: replacementArchiveURL.path)[.size] as? NSNumber
        )
        XCTAssertEqual(originalSize, replacementSize)

        var components = URLComponents()
        components.scheme = "ebook"
        components.host = "ebook"
        components.path = "/load/local/cache-archive-identity.epub"
        components.queryItems = [
            URLQueryItem(name: "diagnosticLocalFilePath", value: archiveURL.path),
        ]
        let packageURL = try XCTUnwrap(components.url)
        let cache = ReaderPackageEntrySourceCache()
        let readerFileManager = ReaderFileManager()

        let first = try await cache.cachedSource(
            forPackageURL: packageURL,
            readerFileManager: readerFileManager
        )
        XCTAssertEqual(first.entries.map(\.path), ["OPS/old.xhtml"])

        try fileManager.moveItem(at: archiveURL, to: displacedArchiveURL)
        try fileManager.moveItem(at: replacementArchiveURL, to: archiveURL)
        try fileManager.setAttributes(
            [.modificationDate: fixedDate],
            ofItemAtPath: archiveURL.path
        )

        let second = try await cache.cachedSource(
            forPackageURL: packageURL,
            readerFileManager: readerFileManager
        )
        XCTAssertEqual(second.entries.map(\.path), ["OPS/new.xhtml"])
    }
#endif


#if canImport(Darwin) || canImport(Glibc)
    func testReaderPackageArchiveSourceRejectsReplacementAfterConstruction() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let archiveURL = temporaryRoot.appendingPathComponent("book.epub")
        let replacementURL = temporaryRoot.appendingPathComponent("replacement.epub")
        let displacedURL = temporaryRoot.appendingPathComponent("book-original.epub")

        func createArchive(at url: URL, entryPath: String, content: String) throws {
            guard let archive = Archive(url: url, accessMode: .create) else {
                XCTFail("Expected archive to be created at \(url.path)")
                return
            }
            let payload = Data(content.utf8)
            try archive.addEntry(
                with: entryPath,
                type: .file,
                uncompressedSize: Int64(payload.count)
            ) { position, size in
                payload.subdata(in: Int(position)..<Int(position) + size)
            }
        }

        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        try createArchive(at: archiveURL, entryPath: "OPS/old.xhtml", content: "old")
        try createArchive(at: replacementURL, entryPath: "OPS/new.xhtml", content: "new")

        let source = try ReaderPackageEntrySource(localURL: archiveURL)
        XCTAssertEqual(source.enumerateEntries().map(\.path), ["OPS/old.xhtml"])

        try fileManager.moveItem(at: archiveURL, to: displacedURL)
        try fileManager.moveItem(at: replacementURL, to: archiveURL)

        XCTAssertThrowsError(try source.enumerateEntries())
        XCTAssertThrowsError(try source.readEntry(subpath: "OPS/new.xhtml"))

        let replacementSource = try ReaderPackageEntrySource(localURL: archiveURL)
        XCTAssertEqual(replacementSource.enumerateEntries().map(\.path), ["OPS/new.xhtml"])
        XCTAssertEqual(
            String(decoding: try replacementSource.readEntry(subpath: "OPS/new.xhtml"), as: UTF8.self),
            "new"
        )
    }

    func testReaderPackageArchiveCacheInvalidatesSameInodeRewriteWithRestoredMTime() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let archiveURL = temporaryRoot.appendingPathComponent("book.epub")
        let replacementURL = temporaryRoot.appendingPathComponent("replacement.epub")
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

        func createArchive(at url: URL, content: String) throws {
            guard let archive = Archive(url: url, accessMode: .create) else {
                XCTFail("Expected archive to be created at \(url.path)")
                return
            }
            let payload = Data(content.utf8)
            try archive.addEntry(
                with: "OPS/chapter.xhtml",
                type: .file,
                uncompressedSize: Int64(payload.count)
            ) { position, size in
                payload.subdata(in: Int(position)..<Int(position) + size)
            }
            try fileManager.setAttributes([.modificationDate: fixedDate], ofItemAtPath: url.path)
        }

        func inode(at url: URL) throws -> UInt64 {
            var info = stat()
            guard url.path.withCString({ stat($0, &info) }) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            return UInt64(info.st_ino)
        }

        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        try createArchive(at: archiveURL, content: "old")
        try createArchive(at: replacementURL, content: "new")
        let replacementData = try Data(contentsOf: replacementURL)
        XCTAssertEqual(
            try fileManager.attributesOfItem(atPath: archiveURL.path)[.size] as? NSNumber,
            try fileManager.attributesOfItem(atPath: replacementURL.path)[.size] as? NSNumber
        )

        var components = URLComponents()
        components.scheme = "ebook"
        components.host = "ebook"
        components.path = "/load/local/cache-archive-state.epub"
        components.queryItems = [
            URLQueryItem(name: "diagnosticLocalFilePath", value: archiveURL.path),
        ]
        let packageURL = try XCTUnwrap(components.url)
        let cache = ReaderPackageEntrySourceCache()
        let readerFileManager = ReaderFileManager()

        let first = try await cache.cachedSource(
            forPackageURL: packageURL,
            readerFileManager: readerFileManager
        )
        XCTAssertEqual(
            String(decoding: try first.source.readEntry(subpath: "OPS/chapter.xhtml"), as: UTF8.self),
            "old"
        )

        let originalInode = try inode(at: archiveURL)
        try replacementData.write(to: archiveURL, options: [])
        try fileManager.setAttributes([.modificationDate: fixedDate], ofItemAtPath: archiveURL.path)
        XCTAssertEqual(try inode(at: archiveURL), originalInode)

        XCTAssertThrowsError(try first.source.enumerateEntries())
        XCTAssertThrowsError(try first.source.readEntry(subpath: "OPS/chapter.xhtml"))

        let second = try await cache.cachedSource(
            forPackageURL: packageURL,
            readerFileManager: readerFileManager
        )
        XCTAssertEqual(
            String(decoding: try second.source.readEntry(subpath: "OPS/chapter.xhtml"), as: UTF8.self),
            "new"
        )
    }
#endif

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

    func testReaderPackageArchiveSourceAdvertisesOnlyFirstAddressableEntryPerPath() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let archiveURL = temporaryRoot.appendingPathComponent("book.epub")
        let firstEntryData = Data("first".utf8)
        let duplicateEntryData = Data("second-is-longer".utf8)

        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        guard let archive = Archive(url: archiveURL, accessMode: .create) else {
            XCTFail("Expected archive to be created")
            return
        }
        func addEntry(path: String, data: Data) throws {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count)
            ) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }

        try addEntry(path: "OPS/chapter.xhtml", data: firstEntryData)
        try addEntry(path: "../outside.xhtml", data: Data("outside".utf8))
        try addEntry(path: "OPS\\windows.xhtml", data: Data("windows".utf8))
        try addEntry(path: "OPS/chapter.xhtml", data: duplicateEntryData)

        let source = try ReaderPackageEntrySource(localURL: archiveURL)

        XCTAssertEqual(
            try source.enumerateEntries(),
            [ReaderPackageEntryMetadata(path: "OPS/chapter.xhtml", size: firstEntryData.count)]
        )
        XCTAssertEqual(
            String(decoding: try source.readEntry(subpath: "OPS/chapter.xhtml"), as: UTF8.self),
            "first"
        )
        XCTAssertThrowsError(try source.readEntry(subpath: "../outside.xhtml"))
        XCTAssertThrowsError(try source.readEntry(subpath: "OPS\\windows.xhtml"))
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
        XCTAssertFalse(result.isAuthoritativelyProcessed)
    }

    func testEbookTextProcessorPropagatesCancellation() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/Books/test.epub"))

        do {
            _ = try await ebookTextProcessor(
                contentURL: contentURL,
                sectionLocation: "item/xhtml/title.xhtml",
                content: "<html><body>Original</body></html>",
                contentFingerprint: "fingerprint",
                isCacheWarmer: false,
                processReadabilityContent: { _, _, _, _, _, _, _ in
                    throw CancellationError()
                },
                processHTMLDocument: nil,
                processHTMLBytes: nil,
                processHTML: nil
            )
            XCTFail("Cancellation must not become a successful raw section response")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
    }

    func testEbookTextProcessorRejectsSuccessfulReadabilityResultAfterTaskCancellation() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/Books/test.epub"))
        let task = Task {
            try await ebookTextProcessor(
                contentURL: contentURL,
                sectionLocation: "item/xhtml/title.xhtml",
                content: "<html><body>Original</body></html>",
                contentFingerprint: "fingerprint",
                isCacheWarmer: false,
                processReadabilityContent: { content, _, sectionURL, _, _, _, _ in
                    withUnsafeCurrentTask { currentTask in
                        currentTask?.cancel()
                    }
                    return try SwiftSoup.parse(content, sectionURL?.absoluteString ?? "")
                },
                processHTMLDocument: nil,
                processHTMLBytes: nil,
                processHTML: nil
            )
        }

        do {
            _ = try await task.value
            XCTFail("Cancelled processing must not publish a successful document")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
    }

    func testEbookTextProcessorTreatsTaskCancellationAsCancellationEvenForAnotherError() async throws {
        enum ExpectedProcessingError: Error {
            case failedAfterCancellation
        }

        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/Books/test.epub"))
        let task = Task {
            try await ebookTextProcessor(
                contentURL: contentURL,
                sectionLocation: "item/xhtml/title.xhtml",
                content: "<html><body>Original</body></html>",
                contentFingerprint: "fingerprint",
                isCacheWarmer: false,
                processReadabilityContent: { _, _, _, _, _, _, _ in
                    withUnsafeCurrentTask { currentTask in
                        currentTask?.cancel()
                    }
                    throw ExpectedProcessingError.failedAfterCancellation
                },
                processHTMLDocument: nil,
                processHTMLBytes: nil,
                processHTML: nil
            )
        }

        do {
            _ = try await task.value
            XCTFail("Cancelled processing must not become a recoverable raw fallback")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
    }

    func testEbookTextProcessorMarksRecoverableFallbackAsNonAuthoritative() async throws {
        enum ExpectedProcessingError: Error {
            case failed
        }

        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/Books/test.epub"))
        let originalText = "<html><body>Original</body></html>"
        let result = try await ebookTextProcessor(
            contentURL: contentURL,
            sectionLocation: "item/xhtml/title.xhtml",
            content: originalText,
            contentFingerprint: "fingerprint",
            isCacheWarmer: false,
            processReadabilityContent: { _, _, _, _, _, _, _ in
                throw ExpectedProcessingError.failed
            },
            processHTMLDocument: nil,
            processHTMLBytes: nil,
            processHTML: nil
        )

        XCTAssertEqual(String(decoding: result.documentHTML, as: UTF8.self), originalText)
        XCTAssertTrue(result.segmentSidecar.isEmpty)
        XCTAssertFalse(result.isAuthoritativelyProcessed)
    }

    func testSectionProcessingDeduperCoalescesEquivalentInFlightRequests() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/test.epub"))
        let key = EBookSectionProcessingRequestKey(
            contentURL: contentURL,
            location: "chapter.xhtml",
            contentData: Data("本文".utf8),
            processingVariant: ebookTestProcessingVariant
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

    func testSectionProcessingDeduperKeepsSharedProducerAliveWhenOriginalCallerIsCancelled() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/test.epub"))
        let key = EBookSectionProcessingRequestKey(
            contentURL: contentURL,
            location: "chapter.xhtml",
            contentData: Data("本文".utf8),
            processingVariant: ebookTestProcessingVariant
        )
        let gate = EbookTestGate()
        let invocationCounter = EbookTestInvocationCounter()
        let started = expectation(description: "shared producer starts")
        let deduper = EBookSectionProcessingDeduper()

        let originalCaller = Task {
            try await deduper.process(key: key) {
                await invocationCounter.increment()
                started.fulfill()
                await gate.waitUntilReleased()
                try Task.checkCancellation()
                return ebookTestPayload("shared-after-cancellation")
            }
        }
        await fulfillment(of: [started], timeout: 1)

        let activeWaiter = Task {
            try await deduper.process(key: key) {
                XCTFail("The active waiter must reuse the independent shared producer")
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

        originalCaller.cancel()
        await gate.release()

        do {
            _ = try await originalCaller.value
            XCTFail("The cancelled caller must retain its own cancellation result")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }

        let activeResult = try await activeWaiter.value
        XCTAssertEqual(
            String(decoding: activeResult.payload.documentHTML, as: UTF8.self),
            "shared-after-cancellation"
        )
        XCTAssertTrue(activeResult.didCoalesce)
        let invocationCount = await invocationCounter.count
        XCTAssertEqual(invocationCount, 1)
    }

    func testSectionProcessingDeduperCancelledWaiterReturnsBeforeSharedProducerCompletes() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/test.epub"))
        let key = EBookSectionProcessingRequestKey(
            contentURL: contentURL,
            location: "chapter.xhtml",
            contentData: Data("本文".utf8),
            processingVariant: ebookTestProcessingVariant
        )
        let gate = EbookTestGate()
        let started = expectation(description: "shared producer starts")
        let cancelledWaiterFinished = expectation(description: "cancelled waiter finishes promptly")
        let deduper = EBookSectionProcessingDeduper()

        let activeCaller = Task {
            try await deduper.process(key: key) {
                started.fulfill()
                await gate.waitUntilReleased()
                return ebookTestPayload("active-result")
            }
        }
        await fulfillment(of: [started], timeout: 1)

        let cancelledWaiter = Task {
            try await deduper.process(key: key) {
                XCTFail("The coalesced waiter must not start another producer")
                return ebookTestPayload("duplicate")
            }
        }
        for _ in 0..<1_000 {
            if await deduper.inFlightWaiterCountForTesting(key: key) > 0 {
                break
            }
            await Task.yield()
        }

        let cancellationObserver = Task {
            do {
                _ = try await cancelledWaiter.value
                XCTFail("The cancelled waiter must not wait for the shared producer")
            } catch is CancellationError {
                cancelledWaiterFinished.fulfill()
            } catch {
                XCTFail("Expected CancellationError, received \(error)")
            }
        }
        cancelledWaiter.cancel()
        await fulfillment(of: [cancelledWaiterFinished], timeout: 1)

        await gate.release()
        let activeResult = try await activeCaller.value
        _ = await cancellationObserver.result
        XCTAssertEqual(String(decoding: activeResult.payload.documentHTML, as: UTF8.self), "active-result")
    }

    func testSectionProcessingDeduperCancelsProducerWhenItsLastWaiterCancels() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/test.epub"))
        let key = EBookSectionProcessingRequestKey(
            contentURL: contentURL,
            location: "chapter.xhtml",
            contentData: Data("本文".utf8),
            processingVariant: ebookTestProcessingVariant
        )
        let producerStarted = expectation(description: "producer starts")
        let producerCancelled = expectation(description: "orphaned producer is cancelled")
        let callerCancelled = expectation(description: "last waiter finishes with cancellation")
        let deduper = EBookSectionProcessingDeduper()

        let onlyCaller = Task {
            try await deduper.process(key: key) {
                producerStarted.fulfill()
                return try await withTaskCancellationHandler {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                    return ebookTestPayload("unexpected")
                } onCancel: {
                    producerCancelled.fulfill()
                }
            }
        }
        await fulfillment(of: [producerStarted], timeout: 1)

        let cancellationObserver = Task {
            do {
                _ = try await onlyCaller.value
                XCTFail("The last cancelled waiter must not receive a result")
            } catch is CancellationError {
                callerCancelled.fulfill()
            } catch {
                XCTFail("Expected CancellationError, received \(error)")
            }
        }
        onlyCaller.cancel()
        await fulfillment(of: [callerCancelled, producerCancelled], timeout: 1)
        _ = await cancellationObserver.result

        let replacement = try await deduper.process(key: key) {
            ebookTestPayload("replacement")
        }
        XCTAssertEqual(String(decoding: replacement.payload.documentHTML, as: UTF8.self), "replacement")
        XCTAssertFalse(replacement.didCoalesce)
    }

    func testProcessedSectionCacheProbePreservesCancellationAfterReaderReturns() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/test.epub"))
        let gate = EbookTestGate()
        let cacheReadStarted = expectation(description: "cache read starts")

        let probe = Task {
            try await probeEbookProcessedSectionCache(
                reader: { _, _, _ in
                    cacheReadStarted.fulfill()
                    await gate.waitUntilReleased()
                    return nil
                },
                contentURL: contentURL,
                location: "chapter.xhtml",
                contentFingerprint: "fingerprint"
            )
        }
        await fulfillment(of: [cacheReadStarted], timeout: 1)
        probe.cancel()
        await gate.release()

        do {
            _ = try await probe.value
            XCTFail("Cancellation must not become a cache miss")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
    }

    func testProcessedSectionCacheProbePropagatesReaderCancellation() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/test.epub"))

        do {
            _ = try await probeEbookProcessedSectionCache(
                reader: { _, _, _ in throw CancellationError() },
                contentURL: contentURL,
                location: "chapter.xhtml",
                contentFingerprint: "fingerprint"
            )
            XCTFail("Reader cancellation must not become a cache miss")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
    }

    func testProcessedSectionCacheProbeRejectsCancellationWithoutAReader() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/test.epub"))
        let probe = Task {
            try await probeEbookProcessedSectionCache(
                reader: nil,
                contentURL: contentURL,
                location: "chapter.xhtml",
                contentFingerprint: "fingerprint"
            )
        }
        probe.cancel()

        do {
            _ = try await probe.value
            XCTFail("Cancellation must not become an unavailable cache result")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
    }

    func testProcessedSectionCacheProbeKeepsNonCancellationFailuresRetryable() async throws {
        enum ExpectedCacheError: Error {
            case failed
        }
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/test.epub"))

        let result = try await probeEbookProcessedSectionCache(
            reader: { _, _, _ in throw ExpectedCacheError.failed },
            contentURL: contentURL,
            location: "chapter.xhtml",
            contentFingerprint: "fingerprint"
        )

        XCTAssertNil(result.payload)
        XCTAssertTrue(result.outcome.hasPrefix("error:"))
    }

    func testSectionProcessingDeduplicationDoesNotCrossHandlerOwners() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/test.epub"))
        let key = EBookSectionProcessingRequestKey(
            contentURL: contentURL,
            location: "chapter.xhtml",
            contentData: Data("本文".utf8),
            processingVariant: ebookTestProcessingVariant
        )
        let firstGate = EbookTestGate()
        let firstStarted = expectation(description: "first handler processing starts")
        let secondStarted = expectation(description: "second handler processing starts independently")
        let firstHandler = EbookURLSchemeHandler()
        let secondHandler = EbookURLSchemeHandler()

        let firstTask = Task {
            try await firstHandler.processSectionForRequest(key: key) {
                firstStarted.fulfill()
                await firstGate.waitUntilReleased()
                return ebookTestPayload("first-owner")
            }
        }
        await fulfillment(of: [firstStarted], timeout: 1)

        let secondTask = Task {
            try await secondHandler.processSectionForRequest(key: key) {
                secondStarted.fulfill()
                return ebookTestPayload("second-owner")
            }
        }
        await fulfillment(of: [secondStarted], timeout: 1)
        let second = try await secondTask.value
        await firstGate.release()
        let first = try await firstTask.value

        XCTAssertEqual(String(decoding: first.payload.documentHTML, as: UTF8.self), "first-owner")
        XCTAssertEqual(String(decoding: second.payload.documentHTML, as: UTF8.self), "second-owner")
        XCTAssertFalse(first.didCoalesce)
        XCTAssertFalse(second.didCoalesce)
    }

    func testSectionProcessingDeduperProducerInheritsExactProcessingVariantContext() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/test.epub"))
        let variant = EbookProcessingVariant(
            availableDictionaryIDs: ["jmnedict", "jmdict"],
            includeJLPTClasses: true,
            romajiModeEnabled: true
        )
        let key = EBookSectionProcessingRequestKey(
            contentURL: contentURL,
            location: "chapter.xhtml",
            contentData: Data("本文".utf8),
            processingVariant: variant
        )
        let deduper = EBookSectionProcessingDeduper()

        let result = try await EbookProcessingVariantContext.$current.withValue(variant) {
            try await deduper.process(key: key) {
                XCTAssertEqual(EbookProcessingVariantContext.current, variant)
                return ebookTestPayload("variant-owned")
            }
        }

        XCTAssertEqual(String(decoding: result.payload.documentHTML, as: UTF8.self), "variant-owned")
        XCTAssertFalse(result.didCoalesce)
    }

    func testSectionProcessingDeduperDoesNotCoalesceDifferentProcessingVariants() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/test.epub"))
        let contentData = Data("本文".utf8)
        let firstKey = EBookSectionProcessingRequestKey(
            contentURL: contentURL,
            location: "chapter.xhtml",
            contentData: contentData,
            processingVariant: EbookProcessingVariant(
                availableDictionaryIDs: ["jmdict"],
                includeJLPTClasses: false,
                romajiModeEnabled: false
            )
        )
        let secondKey = EBookSectionProcessingRequestKey(
            contentURL: contentURL,
            location: "chapter.xhtml",
            contentData: contentData,
            processingVariant: EbookProcessingVariant(
                availableDictionaryIDs: ["jmdict", "jmnedict"],
                includeJLPTClasses: true,
                romajiModeEnabled: true
            )
        )
        let firstGate = EbookTestGate()
        let firstStarted = expectation(description: "first variant starts")
        let secondStarted = expectation(description: "second variant starts independently")
        let invocationCounter = EbookTestInvocationCounter()
        let deduper = EBookSectionProcessingDeduper()

        let firstTask = Task {
            try await deduper.process(key: firstKey) {
                await invocationCounter.increment()
                firstStarted.fulfill()
                await firstGate.waitUntilReleased()
                return ebookTestPayload("first-variant")
            }
        }
        await fulfillment(of: [firstStarted], timeout: 1)

        let secondTask = Task {
            try await deduper.process(key: secondKey) {
                await invocationCounter.increment()
                secondStarted.fulfill()
                return ebookTestPayload("second-variant")
            }
        }
        await fulfillment(of: [secondStarted], timeout: 1)
        let secondResult = try await secondTask.value
        await firstGate.release()
        let firstResult = try await firstTask.value

        XCTAssertEqual(String(decoding: firstResult.payload.documentHTML, as: UTF8.self), "first-variant")
        XCTAssertEqual(String(decoding: secondResult.payload.documentHTML, as: UTF8.self), "second-variant")
        XCTAssertFalse(firstResult.didCoalesce)
        XCTAssertFalse(secondResult.didCoalesce)
        let invocationCount = await invocationCounter.count
        XCTAssertEqual(invocationCount, 2)
    }

    func testSectionProcessingDeduperDoesNotRetainCompletedResponses() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/test.epub"))
        let key = EBookSectionProcessingRequestKey(
            contentURL: contentURL,
            location: "chapter.xhtml",
            contentData: Data("本文".utf8),
            processingVariant: ebookTestProcessingVariant
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
        let canonicalJSON = #"{"v":10,"t":{"h":[],"sid":[]},"s":[]}"#
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

    func testEbookTextProcessorPropagatesReadabilityCancellation() async throws {
        do {
            _ = try await ebookTextProcessor(
                contentURL: URL(string: "ebook://ebook/load/local/Books/test.epub")!,
                sectionLocation: "OPS/chapter.xhtml",
                content: "<html><body>raw</body></html>",
                contentFingerprint: nil,
                isCacheWarmer: false,
                processReadabilityContent: { _, _, _, _, _, _, _ in
                    throw CancellationError()
                },
                processHTMLDocument: nil,
                processHTMLBytes: nil,
                processHTML: nil
            )
            XCTFail("Cancellation must not become a successful raw-content fallback")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testCancelledForegroundProcessingDoesNotPublishLateProcessorResult() async throws {
        let gate = EbookTestGate()
        let started = expectation(description: "processor starts")
        let writerInvocationCounter = EbookTestInvocationCounter()
        let actor = EBookProcessingActor(
            ebookProcessedTextCacheWriter: { _, _, _, _ in
                await writerInvocationCounter.increment()
            },
            ebookTextProcessor: { _, _, _, _, _, _, _, _, _ in
                started.fulfill()
                await gate.waitUntilReleased()
                return ebookTestPayload("<html><body>obsolete</body></html>")
            },
            processReadabilityContent: nil,
            processHTMLDocument: nil,
            processHTMLBytes: nil,
            processHTML: nil
        )

        let task = Task {
            try await actor.process(
                contentURL: URL(string: "ebook://ebook/load/local/Books/test.epub")!,
                location: "OPS/chapter.xhtml",
                text: "<html><body>raw</body></html>",
                isCacheWarmer: false
            )
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        await gate.release()

        do {
            _ = try await task.value
            XCTFail("A cancelled owner must not publish or return a late processor result")
        } catch is CancellationError {
            // Expected.
        }
        let writerInvocationCount = await writerInvocationCounter.count
        XCTAssertEqual(writerInvocationCount, 0)
    }
}
