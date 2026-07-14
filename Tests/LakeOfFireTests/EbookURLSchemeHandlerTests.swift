import XCTest
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

final class EbookURLSchemeHandlerTests: XCTestCase {
    func testExternalizingCanonicalSidecarPublishesContentAddressedJSON() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("manabi-sidecar-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = ReaderExternalSegmentSidecarStore(directoryURL: directoryURL)
        let canonicalJSON = #"{"v":3,"t":{},"s":[]}"#
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
        <script id="mnb-segment-metadata">{"v":3,"t":{},"s":[]}</script>
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
        <script id="mnb-segment-metadata">{"v":3,"t":{},"s":[["1"]]}</script>
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
        let canonicalJSON = #"{"v":3,"t":{},"s":[]}"#
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
        <mnb-sen><mnb-seg>本文</mnb-seg></mnb-sen></BODY></HTML>
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
        XCTAssertTrue(result.contains("<mnb-sen><mnb-seg>本文</mnb-seg></mnb-sen>"))

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
            ebookTextProcessor: { _, _, _, _, _, _, _, _, _ in "processed" },
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
        let processedText = try await processingTask.value
        XCTAssertEqual(processedText, "processed")
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
            return "<html><body>processed-\(invocation)</body></html>"
        }
        let second = try await deduper.process(key: key) {
            let invocation = await counter.increment()
            return "<html><body>processed-\(invocation)</body></html>"
        }
        let invocationCount = await counter.value()

        XCTAssertEqual(first.responseText, "<html><body>processed-1</body></html>")
        XCTAssertFalse(first.didCoalesce)
        XCTAssertEqual(second.responseText, "<html><body>processed-2</body></html>")
        XCTAssertFalse(second.didCoalesce)
        XCTAssertEqual(invocationCount, 2)
    }

    func testForegroundAndCacheWarmerRequestsCoalesceWhileProcessing() async throws {
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
                return "<html><body>processed</body></html>"
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let foregroundTask = Task {
            try await deduper.process(key: foregroundKey) {
                _ = await counter.increment()
                return "unexpected second result"
            }
        }

        for _ in 0..<1_000 {
            if await gate.isWaitingForRelease(),
               await deduper.inFlightWaiterCountForTesting(key: foregroundKey) == 1 {
                break
            }
            await Task.yield()
        }
        let waiterCount = await deduper.inFlightWaiterCountForTesting(key: foregroundKey)
        XCTAssertEqual(waiterCount, 1)
        await gate.release()

        let cacheWarmerResult = try await cacheWarmerTask.value
        let foregroundResult = try await foregroundTask.value
        XCTAssertEqual(cacheWarmerResult.responseText, foregroundResult.responseText)
        XCTAssertFalse(cacheWarmerResult.didCoalesce)
        XCTAssertTrue(foregroundResult.didCoalesce)
        let invocationCount = await counter.value()
        XCTAssertEqual(invocationCount, 1)
    }

    func testCacheWarmerCacheHitStillReturnsProcessedContent() async throws {
        let expectedHTML = "<html><body><manabi-segment>cached</manabi-segment></body></html>"
        let actor = EBookProcessingActor(
            ebookTextProcessor: { _, _, _, _, _, _, _, _, _ in expectedHTML },
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

        XCTAssertEqual(result, expectedHTML)
    }

    func testCacheWarmerUsesPersistedProcessedTextWithoutReprocessing() async throws {
        let expectedHTML = "<html><body><manabi-segment>persisted</manabi-segment></body></html>"
        let actor = EBookProcessingActor(
            ebookProcessedTextCacheReader: { _, _, _, _ in expectedHTML },
            ebookTextProcessor: { _, _, _, _, _, _, _, _, _ in
                XCTFail("A persisted cache hit should bypass ebook text processing")
                return "<html><body>unexpected processed value</body></html>"
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
            isCacheWarmer: true
        )

        XCTAssertEqual(result, expectedHTML)
    }

    func testProcessingCanSkipCacheReadAfterCallerAlreadyMissed() async throws {
        let expectedHTML = "<html><body>processed once</body></html>"
        let actor = EBookProcessingActor(
            ebookProcessedTextCacheReader: { _, _, _, _ in
                XCTFail("The scheme handler already performed this cache read")
                return "<html><body>unexpected cached value</body></html>"
            },
            ebookTextProcessor: { _, _, _, _, _, _, _, _, _ in expectedHTML },
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

        XCTAssertEqual(result, expectedHTML)
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

        XCTAssertEqual(result, originalText)
    }
}
