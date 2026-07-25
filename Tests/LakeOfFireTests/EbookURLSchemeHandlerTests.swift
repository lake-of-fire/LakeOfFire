import XCTest
import SwiftSoup
@testable import LakeOfFireReader

private actor EBookProcessorInvocationCounter {
    private var count = 0

    func increment() -> Int {
        count += 1
        return count
    }

    func value() -> Int {
        count
    }
}

private actor EBookProcessingGate {
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
    func testExternalizingTypedSidecarAvoidsEmbeddedJSONRoundTrip() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manabi-sidecar-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = ReaderExternalSegmentSidecarStore(directoryURL: directoryURL)
        let canonicalJSON = #"{"v":9,"t":{"h":["hash"],"sid":["sentence"],"pid":["paragraph"]},"s":[["!a",0,null,null,null,null,null,null,null,0,0]]}"#
        let documentHTML = "<html><head></head><body><m-m>A</m-m></body></html>"

        let result = externalizingReaderSegmentSidecar(
            documentHTML: Array(documentHTML.utf8),
            canonicalSidecar: Data(canonicalJSON.utf8),
            scheme: .ebook,
            store: store
        )
        let output = String(decoding: result.documentHTML, as: UTF8.self)

        XCTAssertFalse(output.contains(canonicalJSON))
        XCTAssertTrue(output.contains("meta name=\"mnb-segment-sidecar\""))
        XCTAssertEqual(result.canonicalSidecarByteCount, canonicalJSON.utf8.count)
        XCTAssertTrue(ebookProcessedHTMLHasDurableSegmentIdentities(output, store: store))
        let endpoint = try XCTUnwrap(result.endpointURL.flatMap(URL.init(string:)))
        XCTAssertEqual(
            readerExternalSegmentSidecarResponse(for: endpoint, scheme: .ebook, store: store)?.data,
            Data(canonicalJSON.utf8)
        )
    }

    func testDescriptorBackedCacheValidationRejectsMissingOrInvalidSidecar() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manabi-sidecar-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = ReaderExternalSegmentSidecarStore(directoryURL: directoryURL)
        let documentHTML = "<html><head></head><body><m-m>A</m-m></body></html>"
        let invalidJSON = #"{"v":9,"t":{"sid":[]},"s":[["!a"]]}"#
        let invalid = externalizingReaderSegmentSidecar(
            documentHTML: Array(documentHTML.utf8),
            canonicalSidecar: Data(invalidJSON.utf8),
            scheme: .ebook,
            store: store
        )
        let invalidHTML = String(decoding: invalid.documentHTML, as: UTF8.self)
        XCTAssertFalse(ebookProcessedHTMLHasDurableSegmentIdentities(invalidHTML, store: store))

        let missingHTML = invalidHTML.replacingOccurrences(
            of: invalid.endpointURL ?? "",
            with: "ebook://ebook/processed-section-sidecar/" + String(repeating: "0", count: 64)
        )
        XCTAssertFalse(ebookProcessedHTMLHasDurableSegmentIdentities(missingHTML, store: store))
    }

    func testExternalizingCanonicalSidecarPublishesContentAddressedJSON() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manabi-sidecar-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = ReaderExternalSegmentSidecarStore(directoryURL: directoryURL)
        let canonicalJSON = #"{"v":9,"t":{},"s":[]}"#
        let aggregateJSON = #"{"count":0}"#
        let html = """
        <html><head><title>Test</title></head><body>
        <script id="mnb-segment-metadata-aggregate">\(aggregateJSON)</script>
        <script id="mnb-segment-metadata" type="application/json">\(canonicalJSON)</script>
        </body></html>
        """

        let result = externalizingCanonicalReaderSegmentSidecar(
            in: Array(html.utf8),
            scheme: .ebook,
            store: store
        )
        let output = String(decoding: result.documentHTML, as: UTF8.self)

        XCTAssertFalse(output.contains("id=\"mnb-segment-metadata\""))
        XCTAssertTrue(output.contains("id=\"mnb-segment-metadata-aggregate\""))
        XCTAssertTrue(output.contains("meta name=\"mnb-segment-sidecar\""))
        XCTAssertLessThan(
            try XCTUnwrap(output.range(of: "meta name=\"mnb-segment-sidecar\"")?.lowerBound),
            try XCTUnwrap(output.range(of: "</head>")?.lowerBound)
        )
        XCTAssertEqual(result.canonicalSidecarByteCount, canonicalJSON.utf8.count)
        let endpoint = try XCTUnwrap(result.endpointURL.flatMap(URL.init(string:)))
        let served = try XCTUnwrap(readerExternalSegmentSidecarResponse(
            for: endpoint,
            scheme: .ebook,
            store: store
        ))
        XCTAssertEqual(served.data, Data(canonicalJSON.utf8))
        XCTAssertEqual(served.response.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(
            served.response.value(forHTTPHeaderField: "X-Manabi-Sidecar-Signature"),
            result.signature
        )
    }

    func testExternalSidecarSurvivesMemoryEvictionAndStoreRestart() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manabi-sidecar-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let firstStore = ReaderExternalSegmentSidecarStore(
            directoryURL: directoryURL,
            totalByteLimit: 1,
            countLimit: 1
        )
        let firstHTML = """
        <html><head></head><body>
        <script id="mnb-segment-metadata">{"v":9,"t":{},"s":[]}</script>
        </body></html>
        """
        let first = externalizingCanonicalReaderSegmentSidecar(
            in: Array(firstHTML.utf8),
            scheme: .ebook,
            store: firstStore
        )
        let endpoint = try XCTUnwrap(first.endpointURL.flatMap(URL.init(string:)))

        let secondHTML = """
        <html><body>
        <script id="mnb-segment-metadata">{"v":9,"t":{},"s":[["1"]]}</script>
        </body></html>
        """
        _ = externalizingCanonicalReaderSegmentSidecar(
            in: Array(secondHTML.utf8),
            scheme: .ebook,
            store: firstStore
        )
        XCTAssertNotNil(readerExternalSegmentSidecarResponse(
            for: endpoint,
            scheme: .ebook,
            store: firstStore
        ))

        let restartedStore = ReaderExternalSegmentSidecarStore(
            directoryURL: directoryURL,
            totalByteLimit: 1,
            countLimit: 1
        )
        XCTAssertNotNil(readerExternalSegmentSidecarResponse(
            for: endpoint,
            scheme: .ebook,
            store: restartedStore
        ))
        let token = endpoint.lastPathComponent
        try Data("corrupt".utf8).write(to: directoryURL.appendingPathComponent(token), options: [.atomic])
        let corruptedStore = ReaderExternalSegmentSidecarStore(directoryURL: directoryURL)
        XCTAssertNil(readerExternalSegmentSidecarResponse(
            for: endpoint,
            scheme: .ebook,
            store: corruptedStore
        ))
        _ = externalizingCanonicalReaderSegmentSidecar(
            in: Array(firstHTML.utf8),
            scheme: .ebook,
            store: corruptedStore
        )
        XCTAssertNotNil(readerExternalSegmentSidecarResponse(
            for: endpoint,
            scheme: .ebook,
            store: corruptedStore
        ))
        XCTAssertNil(readerExternalSegmentSidecarResponse(
            for: URL(string: "ebook://ebook/processed-section-sidecar/not-a-token")!,
            scheme: .ebook,
            store: restartedStore
        ))
    }

    func testProcessTextResponseExternalizesOnlyCanonicalSidecar() throws {
        let canonicalJSON = #"{"v":9,"t":{},"s":[]}"#
        let html = """
        <html><head></head><body>
        <script id="mnb-segment-metadata">\(canonicalJSON)</script>
        </body></html>
        """

        let response = try XCTUnwrap(ebookProcessTextResponseData(
            processedText: html,
            isCacheWarmer: false
        ))
        let responseHTML = String(decoding: response, as: UTF8.self)

        XCTAssertFalse(responseHTML.contains("id=\"mnb-segment-metadata\""))
        XCTAssertTrue(responseHTML.contains("meta name=\"mnb-segment-sidecar\""))
        XCTAssertEqual(
            ebookProcessTextResponseData(processedText: html, isCacheWarmer: true),
            Data()
        )
    }

    func testProcessedHTMLCacheRequiresDurableIdentityForEveryGeneratedSegment() {
        let valid = """
        <html><body><m-m>A</m-m><m-m>B</m-m>
        <script id="mnb-segment-metadata" type="application/json">
        {"v":9,"t":{"h":["hash-a","hash-b"],"sid":["sentence-a","sentence-b"],"pid":["paragraph-a"]},"s":[["!a",0,null,null,null,null,null,null,null,0,0],["!b",1,null,null,null,null,null,null,null,1,0]]}
        </script></body></html>
        """
        let missingStableIdentity = """
        <html><body><m-m>A</m-m>
        <script id="mnb-segment-metadata" type="application/json">
        {"v":9,"t":{"sid":[]},"s":[["!a"]]}
        </script></body></html>
        """
        let incompleteCoverage = """
        <html><body><m-m>A</m-m><m-m>B</m-m>
        <script id="mnb-segment-metadata" type="application/json">
        {"v":9,"t":{"h":["hash-a"],"sid":["sentence-a"]},"s":[["!a",0,null,null,null,null,null,null,null,0]]}
        </script></body></html>
        """

        XCTAssertTrue(ebookProcessedHTMLHasDurableSegmentIdentities(valid))
        XCTAssertFalse(ebookProcessedHTMLHasDurableSegmentIdentities(missingStableIdentity))
        XCTAssertFalse(ebookProcessedHTMLHasDurableSegmentIdentities(incompleteCoverage))
        XCTAssertFalse(ebookProcessedHTMLHasDurableSegmentIdentities("<m-m>A</m-m>"))
        XCTAssertTrue(ebookProcessedHTMLHasDurableSegmentIdentities("<mnb-segment-metadata></mnb-segment-metadata>"))
    }

    func testProcessedSectionEnvelopeRoundTripsSeparatedDocumentAndSidecar() throws {
        let payload = EbookProcessedSectionPayload(
            documentHTML: Data("<html><body><m-m id=\"runtime\">猫</m-m></body></html>".utf8),
            segmentSidecar: Data(
                #"{"v":9,"t":{"h":["hash"],"sid":["sentence"],"pid":["paragraph"]},"s":[["!runtime",0,null,null,null,null,null,null,null,0,0]]}"#.utf8
            )
        )

        let encoded = encodedEbookProcessedSectionCacheValue(payload)
        let decoded = try XCTUnwrap(decodedEbookProcessedSectionCacheValue(encoded))

        XCTAssertEqual(decoded.documentHTML, payload.documentHTML)
        XCTAssertEqual(decoded.segmentSidecar, payload.segmentSidecar)
        XCTAssertTrue(ebookProcessedSectionPayloadHasDurableSegmentIdentities(decoded))
    }

    func testProcessedSectionEnvelopeRejectsLegacyAndTruncatedValues() {
        let payload = EbookProcessedSectionPayload(
            documentHTML: Data("<html><body>猫</body></html>".utf8),
            segmentSidecar: Data()
        )
        let encoded = encodedEbookProcessedSectionCacheValue(payload)
        var legacy = encoded
        legacy.replaceSubrange(0..<7, with: Array("MNBPSC2".utf8))

        XCTAssertNil(decodedEbookProcessedSectionCacheValue(legacy))
        XCTAssertNil(decodedEbookProcessedSectionCacheValue(Array(encoded.dropLast())))
    }

    func testProcessedSectionDurabilityRequiresExactV9SegmentCoverage() {
        let document = Data("<m-m id=\"a\">猫</m-m><m-m id=\"b\">犬</m-m>".utf8)
        let incomplete = EbookProcessedSectionPayload(
            documentHTML: document,
            segmentSidecar: Data(
                #"{"v":9,"t":{"h":["hash"],"sid":["sentence"]},"s":[["!a",0,null,null,null,null,null,null,null,0]]}"#.utf8
            )
        )
        let legacy = EbookProcessedSectionPayload(
            documentHTML: document,
            segmentSidecar: Data(
                #"{"v":3,"t":{"h":["hash"],"sid":["sentence"]},"s":[["!a",0,null,null,null,null,null,null,null,0],["!b",0,null,null,null,null,null,null,null,0]]}"#.utf8
            )
        )
        let duplicateRuntimeIdentifier = EbookProcessedSectionPayload(
            documentHTML: document,
            segmentSidecar: Data(
                #"{"v":9,"t":{"h":["hash"],"sid":["sentence"],"pid":["paragraph"]},"s":[["!a",0,null,null,null,null,null,null,null,0,0],["!a",0,null,null,null,null,null,null,null,0,0]]}"#.utf8
            )
        )
        let transitionalTenFieldTuple = EbookProcessedSectionPayload(
            documentHTML: Data("<m-m id=\"a\">猫</m-m>".utf8),
            segmentSidecar: Data(
                #"{"v":9,"t":{"h":["hash"],"sid":["sentence"]},"s":[["!a",0,null,null,null,null,null,null,null,0]]}"#.utf8
            )
        )

        XCTAssertFalse(ebookProcessedSectionPayloadHasDurableSegmentIdentities(incomplete))
        XCTAssertFalse(ebookProcessedSectionPayloadHasDurableSegmentIdentities(legacy))
        XCTAssertFalse(
            ebookProcessedSectionPayloadHasDurableSegmentIdentities(duplicateRuntimeIdentifier)
        )
        XCTAssertFalse(
            ebookProcessedSectionPayloadHasDurableSegmentIdentities(transitionalTenFieldTuple)
        )
    }

    func testProcessingRegeneratesCachedHTMLWithoutDurableSegmentIdentity() async throws {
        let cachedPayload = ebookTestPayload("<html><body><m-m>stale</m-m></body></html>")
        let regeneratedHTML = """
        <html><body><m-m>fresh</m-m>
        <script id="mnb-segment-metadata" type="application/json">
        {"v":9,"t":{"h":["hash"],"sid":["sentence"],"pid":["paragraph"]},"s":[["!fresh",0,null,null,null,null,null,null,null,0,0]]}
        </script></body></html>
        """
        let actor = EBookProcessingActor(
            ebookProcessedTextCacheReader: { _, _, _, _ in cachedPayload },
            ebookTextProcessor: { _, _, _, _, _, _, _, _, _ in
                ebookTestPayload(regeneratedHTML)
            },
            processReadabilityContent: nil,
            processHTMLDocument: nil,
            processHTMLBytes: nil,
            processHTML: nil
        )

        let result = try await actor.process(
            contentURL: URL(string: "ebook://ebook/load/local/Books/test.epub")!,
            location: "item/xhtml/chapter.xhtml",
            text: "<html><body>raw</body></html>",
            isCacheWarmer: false
        )

        XCTAssertEqual(String(decoding: result.documentHTML, as: UTF8.self), regeneratedHTML)
    }

    func testDirectSectionRequestPreservesUnicodeIdentityAndRejectsDuplicateOrUnsafeSubpaths() throws {
        var components = URLComponents()
        components.scheme = "ebook"
        components.host = "ebook"
        components.path = "/processed-section"
        components.queryItems = [
            URLQueryItem(name: "sourceURL", value: "ebook://ebook/load/local/Books/日本語.epub"),
            URLQueryItem(name: "subpath", value: "OPS/日本語/chapter 1.xhtml"),
            URLQueryItem(name: "direct", value: "1")
        ]
        let request = try XCTUnwrap(ebookDirectSectionRequest(from: try XCTUnwrap(components.url)))

        XCTAssertEqual(
            request.sourceURL.absoluteString,
            "ebook://ebook/load/local/Books/%E6%97%A5%E6%9C%AC%E8%AA%9E.epub"
        )
        XCTAssertEqual(request.subpath, "OPS/日本語/chapter 1.xhtml")

        components.queryItems?.append(URLQueryItem(name: "subpath", value: "OPS/other.xhtml"))
        XCTAssertNil(ebookDirectSectionRequest(from: try XCTUnwrap(components.url)))
        XCTAssertNil(normalizedEbookEntrySubpath("../secret.xhtml"))
        XCTAssertNil(normalizedEbookEntrySubpath("OPS/../secret.xhtml"))
        XCTAssertNil(normalizedEbookEntrySubpath("/OPS/chapter.xhtml"))
        XCTAssertNil(normalizedEbookEntrySubpath("OPS\\chapter.xhtml"))
    }

    func testPathBackedEntryRequiresOwningProcessedDocumentSource() throws {
        let sourceURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/Books/test.epub"))
        let token = ebookBase64URLToken(for: sourceURL.absoluteString)
        let entryURL = try XCTUnwrap(URL(string: "ebook://ebook/entry-source/\(token)/OPS/images/cover.jpg"))
        var ownerComponents = URLComponents()
        ownerComponents.scheme = "ebook"
        ownerComponents.host = "ebook"
        ownerComponents.path = "/processed-section"
        ownerComponents.queryItems = [
            URLQueryItem(name: "sourceURL", value: sourceURL.absoluteString),
            URLQueryItem(name: "subpath", value: "OPS/chapter.xhtml")
        ]

        let request = try XCTUnwrap(ebookPathBackedEntryRequest(
            from: entryURL,
            mainDocumentURL: try XCTUnwrap(ownerComponents.url)
        ))
        XCTAssertEqual(request.sourceURL, sourceURL)
        XCTAssertEqual(request.subpath, "OPS/images/cover.jpg")

        ownerComponents.queryItems = [
            URLQueryItem(name: "sourceURL", value: "ebook://ebook/load/local/Books/other.epub"),
            URLQueryItem(name: "subpath", value: "OPS/chapter.xhtml")
        ]
        XCTAssertNil(ebookPathBackedEntryRequest(
            from: entryURL,
            mainDocumentURL: try XCTUnwrap(ownerComponents.url)
        ))
        XCTAssertNil(ebookPathBackedEntryRequest(from: entryURL, mainDocumentURL: nil))
    }

    func testDirectSectionMetadataInjectionPreservesDocumentBytesAndInstallsPathBackedBase() {
        let html = """
        <!doctype html><HTML data-note='1>0'><HEAD><base href="old/"></HEAD><BODY class="book">
        <m-s><m-m>本文</m-m></m-s></BODY></HTML>
        """
        let result = ebookHTMLWithInjectedDirectSectionMetadata(
            html,
            baseURL: "ebook://ebook/entry-source/token/OPS/",
            sourceHref: "OPS/chapter.xhtml"
        )

        XCTAssertTrue(result.contains(
            "<HEAD><base href=\"ebook://ebook/entry-source/token/OPS/\"><base href=\"old/\">"
        ))
        XCTAssertTrue(result.contains(
            "<BODY class=\"book\" data-mnb-source-href=\"OPS/chapter.xhtml\" "
                + "data-mnb-has-sentences=\"true\" data-mnb-has-segments=\"true\">"
        ))
        XCTAssertTrue(result.contains("<m-s><m-m>本文</m-m></m-s>"))

        XCTAssertEqual(
            ebookHTMLWithInjectedDirectSectionMetadata(
                "<section>fragment</section>",
                baseURL: "ebook://ebook/entry-source/token/",
                sourceHref: "chapter.xhtml"
            ),
            "<!doctype html><html><head><base href=\"ebook://ebook/entry-source/token/\"></head>"
                + "<body data-mnb-source-href=\"chapter.xhtml\"><section>fragment</section></body></html>"
        )
    }

    func testDirectSectionPresentationHintInjectionPreservesProcessedDocument() {
        let html = "<html><head></head><body data-note=\"2 > 1\" class=\"book\"><m-m>本文</m-m></body></html>"
        let result = ebookHTMLWithInjectedPresentationHints(
            html,
            writingHint: EBookProcessedSectionWritingHint(
                direction: "vertical",
                writingMode: "vertical-lr"
            )
        )

        XCTAssertEqual(
            result,
            "<html><head></head><body data-note=\"2 > 1\" class=\"book\" "
                + "data-mnb-writing-direction=\"vertical\" "
                + "data-mnb-writing-mode=\"vertical-lr\" "
                + "data-mnb-foliate-writing-direction=\"vertical\" "
                + "data-mnb-foliate-writing-mode=\"vertical-lr\">"
                + "<m-m>本文</m-m></body></html>"
        )
    }

    func testDirectSectionWritingHintRequiresOneCompleteNormalizedPair() throws {
        let accepted = try XCTUnwrap(URL(string:
            "ebook://ebook/processed-section?mnbWritingDirection=vertical&mnbWritingMode=vertical-lr"
        ))
        let acceptedHint = try XCTUnwrap(ebookProcessedSectionWritingHint(from: accepted))
        XCTAssertEqual(acceptedHint.direction, "vertical")
        XCTAssertEqual(acceptedHint.writingMode, "vertical-lr")

        let rejectedURLs = [
            "ebook://ebook/processed-section?mnbWritingDirection=vertical",
            "ebook://ebook/processed-section?mnbWritingDirection=horizontal&mnbWritingMode=horizontal-tb",
            "ebook://ebook/processed-section?mnbWritingDirection=vertical&mnbWritingMode=sideways-rl",
            "ebook://ebook/processed-section?mnbWritingDirection=vertical&mnbWritingDirection=vertical&mnbWritingMode=vertical-rl"
        ]
        for rawURL in rejectedURLs {
            XCTAssertNil(ebookProcessedSectionWritingHint(from: try XCTUnwrap(URL(string: rawURL))))
        }
    }

    func testSectionPresentationReplacesStaleCachedSettingsAndRejectsUnknownFields() throws {
        let html = """
        <html><body data-mnb-romaji-mode-enabled="false" data-unknown="preserved"
        style='font-size:12px;color:red'>本文</body></html>
        """
        let result = ebookHTMLApplyingSectionPresentation(
            html,
            presentation: EbookSectionPresentation(
                revision: "ABC123",
                bodyAttributes: [
                    "data-mnb-romaji-mode-enabled": "true",
                    "data-mnb-settings-initialized": "true",
                    "data-not-allowlisted": "rejected"
                ],
                bodyStyleProperties: [
                    "font-size": "24px",
                    "font-weight": "600",
                    "--mnb-content-font": "'YuKyokasho Yoko', 'YuKyokasho'",
                    "position": "fixed"
                ]
            )
        )
        let body = try XCTUnwrap(SwiftSoup.parse(result).body())

        XCTAssertEqual(try body.attr("data-mnb-romaji-mode-enabled"), "true")
        XCTAssertEqual(try body.attr("data-mnb-settings-initialized"), "true")
        XCTAssertEqual(try body.attr("data-mnb-presentation-schema-version"), "1")
        XCTAssertEqual(try body.attr("data-mnb-presentation-revision"), "ABC123")
        XCTAssertEqual(try body.attr("data-unknown"), "preserved")
        XCTAssertFalse(body.hasAttr("data-not-allowlisted"))
        let style = try body.attr("style")
        XCTAssertTrue(style.contains("color:red"))
        XCTAssertTrue(style.contains("font-size:24px!important"))
        XCTAssertTrue(style.contains("font-weight:600!important"))
        XCTAssertTrue(style.contains("--mnb-content-font:'YuKyokasho Yoko', 'YuKyokasho'!important"))
        XCTAssertFalse(style.contains("position:fixed"))
        XCTAssertEqual(result.components(separatedBy: "data-mnb-romaji-mode-enabled=").count - 1, 1)
        XCTAssertEqual(result.components(separatedBy: "font-size:24px!important").count - 1, 1)
        XCTAssertEqual(
            ebookHTMLApplyingSectionPresentation(result, presentation: EbookSectionPresentation(
                revision: "ABC123",
                bodyAttributes: ["data-mnb-romaji-mode-enabled": "true"],
                bodyStyleProperties: ["font-size": "24px"]
            )).components(separatedBy: "font-size:24px!important").count - 1,
            1
        )
    }

    func testEbookSchemeTaskPriorityKeepsOnlyDirectSectionLoadsForeground() throws {
        let foregroundURLs = [
            "ebook://ebook/load/local/Books/test.epub",
            "ebook://ebook/load/viewer-assets/foliate-js/paginator.js",
            "ebook://ebook/processed-section?subpath=chapter.xhtml&direct=1",
        ]
        let utilityURLs = [
            "ebook://ebook/processed-section?subpath=chapter.xhtml",
            "ebook://ebook/processed-section?subpath=chapter.xhtml&direct=0",
            "ebook://ebook/processed-section?subpath=chapter.xhtml&direct=true",
            "ebook://ebook/processed-section?subpath=chapter.xhtml&direct=1&direct=1",
            "ebook://ebook/processed-section?subpath=chapter.xhtml&direct",
        ]

        for rawURL in foregroundURLs {
            XCTAssertEqual(
                ebookURLSchemeTaskPriority(for: try XCTUnwrap(URL(string: rawURL))),
                .userInitiated,
                rawURL
            )
        }
        for rawURL in utilityURLs {
            XCTAssertEqual(
                ebookURLSchemeTaskPriority(for: try XCTUnwrap(URL(string: rawURL))),
                .utility,
                rawURL
            )
        }
    }

    func testEbookViewerAssetCacheReadsEachResolvedBundleURLOnce() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let firstURL = directoryURL.appendingPathComponent("first.js")
        let secondURL = directoryURL.appendingPathComponent("second.css")
        try Data("first-revision".utf8).write(to: firstURL)
        try Data("second-asset".utf8).write(to: secondURL)
        let cache = EbookViewerAssetCache()

        let firstRead = try await cache.data(for: firstURL)
        XCTAssertEqual(firstRead, Data("first-revision".utf8))
        try Data("changed-on-disk".utf8).write(to: firstURL)

        let cachedRead = try await cache.data(for: firstURL)
        let secondRead = try await cache.data(for: secondURL)
        XCTAssertEqual(cachedRead, Data("first-revision".utf8))
        XCTAssertEqual(secondRead, Data("second-asset".utf8))
    }

    func testEbookBundleResourceResponseDisablesCaching() throws {
        let response = ebookHTTPResponse(
            url: URL(string: "ebook://ebook/load/viewer-assets/ebook-viewer.js")!,
            mimeType: "text/javascript",
            byteCount: 123,
            textEncodingName: "utf-8",
            additionalHeaderFields: [
                "Cache-Control": "no-store, no-cache, must-revalidate",
                "Pragma": "no-cache",
                "Expires": "0",
            ]
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "text/javascript; charset=utf-8")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Length"), "123")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Cache-Control"), "no-store, no-cache, must-revalidate")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Pragma"), "no-cache")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Expires"), "0")
    }

    func testMissingViewerAssetReturns404InsteadOfViewerHTMLFallback() throws {
        let assetURL = try XCTUnwrap(URL(string: "ebook://ebook/load/viewer-assets/foliate-js/missing.js"))
        let response = try XCTUnwrap(missingEbookViewerAssetResponse(for: assetURL))

        XCTAssertEqual(response.statusCode, 404)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertNil(missingEbookViewerAssetResponse(
            for: try XCTUnwrap(URL(string: "ebook://ebook/load/local/Books/example.epub"))
        ))
    }

    func testForegroundProcessingWaitsForCachePublicationBeforeReturning() async throws {
        let writerGate = EBookProcessingGate()
        let completionCounter = EBookProcessorInvocationCounter()
        let actor = EBookProcessingActor(
            ebookProcessedTextCacheReader: nil,
            ebookProcessedTextCacheWriter: { _, _, _, _, _ in
                await writerGate.waitUntilReleased()
            },
            ebookTextProcessor: { _, _, _, _, _, _, _, _, _ in ebookTestPayload("processed") },
            processReadabilityContent: nil,
            processHTMLDocument: nil,
            processHTMLBytes: nil,
            processHTML: nil
        )

        let processingTask = Task {
            let result = try await actor.process(
                contentURL: URL(string: "ebook://ebook/load/local/Books/test.epub")!,
                location: "item/xhtml/chapter.xhtml",
                text: "raw",
                isCacheWarmer: false
            )
            _ = await completionCounter.increment()
            return result
        }

        for _ in 0..<1_000 {
            if await writerGate.isWaitingForRelease() { break }
            await Task.yield()
        }
        let writerIsWaiting = await writerGate.isWaitingForRelease()
        let completionCountBeforeRelease = await completionCounter.value()
        XCTAssertTrue(writerIsWaiting)
        XCTAssertEqual(completionCountBeforeRelease, 0)

        await writerGate.release()
        let processedPayload = try await processingTask.value
        XCTAssertEqual(String(decoding: processedPayload.documentHTML, as: UTF8.self), "processed")
        let completionCountAfterRelease = await completionCounter.value()
        XCTAssertEqual(completionCountAfterRelease, 1)
    }

    func testProcessTextRequestDeduperDoesNotRetainCompletedResponses() async throws {
        let counter = EBookProcessorInvocationCounter()
        let key = EBookProcessTextRequestKey(
            contentURL: URL(string: "ebook://ebook/load/local/Books/test.epub")!,
            location: "item/xhtml/chapter.xhtml",
            isCacheWarmer: false,
            text: "<html><body>raw</body></html>"
        )
        let deduper = EBookProcessTextRequestDeduper()

        let first = try await deduper.process(key: key) {
            let invocation = await counter.increment()
            return ebookTestPayload("<html><body>processed-\(invocation)</body></html>")
        }
        let second = try await deduper.process(key: key) {
            let invocation = await counter.increment()
            return ebookTestPayload("<html><body>processed-\(invocation)</body></html>")
        }
        let invocationCount = await counter.value()

        XCTAssertEqual(String(decoding: first.payload.documentHTML, as: UTF8.self), "<html><body>processed-1</body></html>")
        XCTAssertFalse(first.didCoalesce)
        XCTAssertEqual(String(decoding: second.payload.documentHTML, as: UTF8.self), "<html><body>processed-2</body></html>")
        XCTAssertFalse(second.didCoalesce)
        XCTAssertEqual(invocationCount, 2)
    }

    func testForegroundAndCacheWarmerRequestsDoNotCoalesceModeSpecificOutput() async throws {
        let contentURL = URL(string: "ebook://ebook/load/local/Books/test.epub")!
        let text = "<html><body>raw</body></html>"
        let cacheWarmerKey = EBookProcessTextRequestKey(
            contentURL: contentURL,
            location: "item/xhtml/chapter.xhtml",
            isCacheWarmer: true,
            text: text
        )
        let foregroundKey = EBookProcessTextRequestKey(
            contentURL: contentURL,
            location: "item/xhtml/chapter.xhtml",
            isCacheWarmer: false,
            text: text
        )
        let counter = EBookProcessorInvocationCounter()
        let gate = EBookProcessingGate()
        let started = expectation(description: "Cache warmer processing starts")
        let deduper = EBookProcessTextRequestDeduper()

        let cacheWarmerTask = Task {
            try await deduper.process(key: cacheWarmerKey) {
                _ = await counter.increment()
                started.fulfill()
                await gate.waitUntilReleased()
                return ebookTestPayload("<html><body>processed</body></html>")
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let foregroundTask = Task {
            try await deduper.process(key: foregroundKey) {
                _ = await counter.increment()
                return ebookTestPayload("<html><body>foreground</body></html>")
            }
        }
        await gate.release()

        let cacheWarmerResult = try await cacheWarmerTask.value
        let foregroundResult = try await foregroundTask.value
        XCTAssertEqual(String(decoding: cacheWarmerResult.payload.documentHTML, as: UTF8.self), "<html><body>processed</body></html>")
        XCTAssertEqual(String(decoding: foregroundResult.payload.documentHTML, as: UTF8.self), "<html><body>foreground</body></html>")
        XCTAssertFalse(cacheWarmerResult.didCoalesce)
        XCTAssertFalse(foregroundResult.didCoalesce)
        let invocationCount = await counter.value()
        XCTAssertEqual(invocationCount, 2)
    }

    func testCacheWarmerDoesNotReadLivePreparedTextCache() async throws {
        let actor = EBookProcessingActor(
            ebookProcessedTextCacheReader: { _, _, _, _ in
                XCTFail("Cache warmers must not consume live presentation HTML")
                return ebookTestPayload("<html><body>live presentation</body></html>")
            },
            ebookTextProcessor: { _, _, _, _, isCacheWarmer, _, _, _, _ in
                XCTAssertTrue(isCacheWarmer)
                return ebookTestPayload("<html><body>neutral warmer result</body></html>")
            },
            processReadabilityContent: nil,
            processHTMLBytes: nil,
            processHTML: nil
        )

        let result = try await actor.process(
            contentURL: URL(string: "ebook://ebook/load/local/Books/test.epub")!,
            location: "item/xhtml/title.xhtml",
            text: "<html><body>raw</body></html>",
            isCacheWarmer: true
        )

        XCTAssertEqual(String(decoding: result.documentHTML, as: UTF8.self), "<html><body>neutral warmer result</body></html>")
    }

    func testCacheWarmerProcessingReturnsProcessedContentToCaller() async throws {
        let expectedHTML = "<html><body><manabi-segment>cached</manabi-segment></body></html>"
        let actor = EBookProcessingActor(
            ebookTextProcessor: { _, _, _, _, _, _, _, _, _ in ebookTestPayload(expectedHTML) },
            processReadabilityContent: nil,
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

    func testForegroundUsesPersistedProcessedTextWithoutReprocessing() async throws {
        let expectedHTML = """
        <html><body><m-m>persisted</m-m>
        <script id="mnb-segment-metadata" type="application/json">
        {"v":9,"t":{"h":["hash"],"sid":["sentence"],"pid":["paragraph"]},"s":[["!persisted",0,null,null,null,null,null,null,null,0,0]]}
        </script></body></html>
        """
        let actor = EBookProcessingActor(
            ebookProcessedTextCacheReader: { _, _, _, _ in
                let split = try XCTUnwrap(splitCanonicalReaderSegmentSidecar(from: Array(expectedHTML.utf8)))
                return split
            },
            ebookTextProcessor: { _, _, _, _, _, _, _, _, _ in
                XCTFail("A persisted cache hit should bypass ebook text processing")
                return ebookTestPayload("<html><body>unexpected processed value</body></html>")
            },
            processReadabilityContent: nil,
            processHTMLDocument: nil,
            processHTMLBytes: nil,
            processHTML: nil
        )

        let result = try await actor.process(
            contentURL: URL(string: "ebook://ebook/load/local/Books/test.epub")!,
            location: "item/xhtml/chapter.xhtml",
            text: "<html><body>raw</body></html>",
            isCacheWarmer: false
        )

        let expectedPayload = try XCTUnwrap(
            splitCanonicalReaderSegmentSidecar(from: Array(expectedHTML.utf8))
        )
        XCTAssertEqual(result.documentHTML, expectedPayload.documentHTML)
        XCTAssertEqual(result.segmentSidecar, expectedPayload.segmentSidecar)
    }

    func testProcessingCanSkipCacheReadAfterCallerAlreadyMissed() async throws {
        let expectedHTML = "<html><body>processed once</body></html>"
        let actor = EBookProcessingActor(
            ebookProcessedTextCacheReader: { _, _, _, _ in
                XCTFail("The scheme handler already performed this cache read")
                return ebookTestPayload("<html><body>unexpected cached value</body></html>")
            },
            ebookTextProcessor: { _, _, _, _, _, _, _, _, _ in ebookTestPayload(expectedHTML) },
            processReadabilityContent: nil,
            processHTMLDocument: nil,
            processHTMLBytes: nil,
            processHTML: nil
        )

        let result = try await actor.process(
            contentURL: URL(string: "ebook://ebook/load/local/Books/test.epub")!,
            location: "item/xhtml/chapter.xhtml",
            text: "<html><body>raw</body></html>",
            isCacheWarmer: false,
            shouldReadProcessedCache: false
        )

        XCTAssertEqual(String(decoding: result.documentHTML, as: UTF8.self), expectedHTML)
    }

    func testCacheWarmerProcessTextResponseDoesNotReturnProcessedContent() throws {
        let processedHTML = "<html><body><manabi-segment>cached</manabi-segment></body></html>"

        let cacheWarmerData = try XCTUnwrap(ebookProcessTextResponseData(
            processedText: processedHTML,
            isCacheWarmer: true
        ))
        let liveData = try XCTUnwrap(ebookProcessTextResponseData(
            processedText: processedHTML,
            isCacheWarmer: false
        ))

        XCTAssertTrue(cacheWarmerData.isEmpty)
        XCTAssertEqual(String(data: liveData, encoding: .utf8), processedHTML)
    }

    func testCacheWarmerWithoutProcessorFallsBackToOriginalText() async throws {
        let originalText = "<html><body>raw</body></html>"
        let actor = EBookProcessingActor(
            ebookTextProcessor: nil,
            processReadabilityContent: nil,
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
}
