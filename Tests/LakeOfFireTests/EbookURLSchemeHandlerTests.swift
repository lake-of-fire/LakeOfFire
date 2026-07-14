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
