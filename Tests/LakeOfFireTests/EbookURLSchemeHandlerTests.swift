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
    func testCompletedForegroundResponseAvoidsImmediateDuplicateProcessing() async throws {
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
        XCTAssertEqual(second.responseText, first.responseText)
        XCTAssertTrue(second.didCoalesce)
        XCTAssertEqual(invocationCount, 1)
    }

    func testCompletedCacheWarmerResponseServesImmediateForegroundRequest() async throws {
        let counter = EBookProcessorInvocationCounter()
        let cacheWarmerKey = EBookProcessTextRequestKey(
            contentURL: URL(string: "ebook://ebook/load/local/Books/test.epub")!,
            location: "item/xhtml/chapter.xhtml",
            isCacheWarmer: true,
            text: "<html><body>raw</body></html>"
        )
        let foregroundKey = EBookProcessTextRequestKey(
            contentURL: URL(string: "ebook://ebook/load/local/Books/test.epub")!,
            location: "item/xhtml/chapter.xhtml",
            isCacheWarmer: false,
            text: "<html><body>raw</body></html>"
        )
        let deduper = EBookProcessTextRequestDeduper()

        let first = try await deduper.process(key: cacheWarmerKey) {
            let invocation = await counter.increment()
            return "processed-\(invocation)"
        }
        let second = try await deduper.process(key: foregroundKey) {
            let invocation = await counter.increment()
            return "processed-\(invocation)"
        }
        let invocationCount = await counter.value()

        XCTAssertEqual(first.responseText, "processed-1")
        XCTAssertFalse(first.didCoalesce)
        XCTAssertEqual(second.responseText, "processed-1")
        XCTAssertTrue(second.didCoalesce)
        XCTAssertEqual(invocationCount, 1)
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
        let deduper = EBookProcessTextRequestDeduper(completedResponseByteLimit: 1024)

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

    func testCompletedResponseCacheMaintainsByteLimitedLRUOrder() async throws {
        let contentURL = URL(string: "ebook://ebook/load/local/Books/test.epub")!
        let deduper = EBookProcessTextRequestDeduper(completedResponseByteLimit: 10)
        func key(_ location: String) -> EBookProcessTextRequestKey {
            EBookProcessTextRequestKey(contentURL: contentURL, location: location, text: location)
        }

        let firstA = try await deduper.process(key: key("a")) { "aaaa" }
        let firstB = try await deduper.process(key: key("b")) { "bbbb" }
        let refreshedA = try await deduper.process(key: key("a")) { "unexpected" }
        let firstC = try await deduper.process(key: key("c")) { "cccc" }
        let evictedB = try await deduper.process(key: key("b")) { "bbbb" }
        let evictedA = try await deduper.process(key: key("a")) { "aaaa" }

        XCTAssertFalse(firstA.didCoalesce)
        XCTAssertFalse(firstB.didCoalesce)
        XCTAssertTrue(refreshedA.didCoalesce)
        XCTAssertFalse(firstC.didCoalesce)
        XCTAssertFalse(evictedB.didCoalesce)
        XCTAssertFalse(evictedA.didCoalesce)
    }

    func testCacheWarmerCacheHitStillReturnsProcessedContent() async throws {
        let expectedHTML = "<html><body><manabi-segment>cached</manabi-segment></body></html>"
        let actor = EBookProcessingActor(
            ebookTextProcessorCacheHits: { _, _ in true },
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
            ebookTextProcessorCacheHits: nil,
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
            ebookTextProcessorCacheHits: nil,
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
            ebookTextProcessorCacheHits: { _, _ in true },
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
