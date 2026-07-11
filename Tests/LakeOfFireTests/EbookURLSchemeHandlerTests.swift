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

final class EbookURLSchemeHandlerTests: XCTestCase {
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

    func testPresentationHintsInjectBodyAttributesWithoutReserializingDocument() throws {
        let html = "<!doctype html><html><head><title>T</title></head><body class=\"p-text\"><p>本文</p></body></html>"
        let result = ebookHTMLWithInjectedPresentationHints(
            html,
            writingHint: EBookProcessedSectionWritingHint(direction: "vertical", writingMode: "vertical-rl")
        )

        XCTAssertEqual(
            result,
            "<!doctype html><html><head><title>T</title></head><body class=\"p-text\" data-mnb-writing-direction=\"vertical\" data-mnb-writing-mode=\"vertical-rl\" data-mnb-foliate-writing-direction=\"vertical\" data-mnb-foliate-writing-mode=\"vertical-rl\"><p>本文</p></body></html>"
        )
    }

    func testPresentationHintsLeaveBodylessFragmentUnchanged() throws {
        let html = "<section><p>本文</p></section>"

        XCTAssertEqual(
            ebookHTMLWithInjectedPresentationHints(
                html,
                writingHint: EBookProcessedSectionWritingHint(direction: "vertical", writingMode: "vertical-rl")
            ),
            html
        )
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
                return "<html><body>processed</body></html>"
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

    func testCacheWarmerCacheHitStillReturnsProcessedContent() async throws {
        let expectedHTML = "<html><body><manabi-segment>cached</manabi-segment></body></html>"
        let actor = EBookProcessingActor(
            ebookTextProcessor: { _, _, _, _, _, _, _, _, _ in expectedHTML },
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

        XCTAssertEqual(result, originalText)
    }

    func testProcessTextRequestKeyIncludesCacheWarmerProcessingMode() throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/test.epub"))
        let foreground = EBookProcessTextRequestKey(
            contentURL: contentURL,
            location: "chapter.xhtml",
            isCacheWarmer: false,
            text: "本文"
        )
        let cacheWarmer = EBookProcessTextRequestKey(
            contentURL: contentURL,
            location: "chapter.xhtml",
            isCacheWarmer: true,
            text: "本文"
        )

        XCTAssertNotEqual(foreground, cacheWarmer)
    }

    func testProcessTextRequestDeduperDoesNotCoalesceDifferentProcessingModes() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/test.epub"))
        let foregroundKey = EBookProcessTextRequestKey(
            contentURL: contentURL,
            location: "chapter.xhtml",
            isCacheWarmer: false,
            text: "本文"
        )
        let cacheWarmerKey = EBookProcessTextRequestKey(
            contentURL: contentURL,
            location: "chapter.xhtml",
            isCacheWarmer: true,
            text: "本文"
        )
        let expectedHTML = "<html><body>processed</body></html>"
        let gate = EbookTestGate()
        let invocationCounter = EbookTestInvocationCounter()
        let started = expectation(description: "processing starts")
        let deduper = EBookProcessTextRequestDeduper()

        let cacheWarmerTask = Task {
            try await deduper.process(key: cacheWarmerKey) {
                await invocationCounter.increment()
                started.fulfill()
                await gate.waitUntilReleased()
                return expectedHTML
            }
        }
        await fulfillment(of: [started], timeout: 1)

        let foregroundTask = Task {
            try await deduper.process(key: foregroundKey) {
                await invocationCounter.increment()
                return "<html><body>foreground</body></html>"
            }
        }
        let foregroundResult = try await foregroundTask.value
        await gate.release()

        let cacheWarmerResult = try await cacheWarmerTask.value
        XCTAssertEqual(cacheWarmerResult.responseText, expectedHTML)
        XCTAssertEqual(foregroundResult.responseText, "<html><body>foreground</body></html>")
        XCTAssertFalse(cacheWarmerResult.didCoalesce)
        XCTAssertEqual(cacheWarmerResult.cacheOutcome, "processed")
        XCTAssertFalse(foregroundResult.didCoalesce)
        XCTAssertEqual(foregroundResult.cacheOutcome, "processed")
        let invocationCount = await invocationCounter.count
        XCTAssertEqual(invocationCount, 2)
        let foregroundData = try XCTUnwrap(ebookProcessTextResponseData(
            processedText: foregroundResult.responseText,
            isCacheWarmer: false
        ))
        let cacheWarmerData = try XCTUnwrap(ebookProcessTextResponseData(
            processedText: cacheWarmerResult.responseText,
            isCacheWarmer: true
        ))
        XCTAssertFalse(foregroundData.isEmpty)
        XCTAssertTrue(cacheWarmerData.isEmpty)
    }

    func testProcessTextRequestDeduperCoalescesEquivalentInFlightRequests() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/test.epub"))
        let key = EBookProcessTextRequestKey(
            contentURL: contentURL,
            location: "chapter.xhtml",
            isCacheWarmer: false,
            text: "本文"
        )
        let gate = EbookTestGate()
        let invocationCounter = EbookTestInvocationCounter()
        let started = expectation(description: "processing starts")
        let deduper = EBookProcessTextRequestDeduper()

        let firstTask = Task {
            try await deduper.process(key: key) {
                await invocationCounter.increment()
                started.fulfill()
                await gate.waitUntilReleased()
                return "shared"
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let secondTask = Task {
            try await deduper.process(key: key) {
                XCTFail("Equivalent in-flight work should reuse the active operation")
                return "duplicate"
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
        XCTAssertEqual(first.responseText, "shared")
        XCTAssertEqual(second.responseText, "shared")
        XCTAssertFalse(first.didCoalesce)
        XCTAssertTrue(second.didCoalesce)
        XCTAssertEqual(invocationCount, 1)
    }

    func testProcessTextRequestDeduperDoesNotRetainCompletedResponses() async throws {
        let contentURL = try XCTUnwrap(URL(string: "ebook://ebook/load/local/test.epub"))
        let key = EBookProcessTextRequestKey(
            contentURL: contentURL,
            location: "chapter.xhtml",
            isCacheWarmer: false,
            text: "本文"
        )
        let deduper = EBookProcessTextRequestDeduper()
        let invocationCounter = EbookTestInvocationCounter()

        let first = try await deduper.process(key: key) {
            await invocationCounter.increment()
            return "first"
        }
        let second = try await deduper.process(key: key) {
            await invocationCounter.increment()
            return "second"
        }

        XCTAssertEqual(first.responseText, "first")
        XCTAssertEqual(second.responseText, "second")
        XCTAssertFalse(first.didCoalesce)
        XCTAssertFalse(second.didCoalesce)
        let invocationCount = await invocationCounter.count
        XCTAssertEqual(invocationCount, 2)
    }

    func testCacheWarmerDoesNotPopulateDisplayReadyProcessedTextCache() async throws {
        let writerInvocationCounter = EbookTestInvocationCounter()
        let actor = EBookProcessingActor(
            ebookProcessedTextCacheWriter: { _, _, _, _, _ in
                await writerInvocationCounter.increment()
            },
            ebookTextProcessor: { _, _, _, _, _, _, _, _, _ in
                "<html><body>warmer result</body></html>"
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
        let actor = EBookProcessingActor(
            ebookProcessedTextCacheWriter: { _, _, _, _, processedText in
                XCTAssertEqual(processedText, "<html><body>foreground result</body></html>")
                writerCalled.fulfill()
            },
            ebookTextProcessor: { _, _, _, _, _, _, _, _, _ in
                "<html><body>foreground result</body></html>"
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
