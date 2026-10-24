import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireCore

@MainActor
final class ReaderContentLoadCoordinationTests: XCTestCase {
    private enum ResolverError: Error {
        case failed
    }

    func testStaleResolverCompletionCannotPublishOverNewerTarget() async throws {
        let originalResolver = ReaderContent.contentResolver
        let resolver = ControlledReaderContentResolver()
        ReaderContent.contentResolver = { url, _, _ in
            await resolver.resolve(url)
        }
        defer {
            ReaderContent.contentResolver = originalResolver
        }

        let readerContent = ReaderContent()
        let olderURL = try XCTUnwrap(URL(string: "https://example.com/older"))
        let newerURL = try XCTUnwrap(URL(string: "https://example.com/newer"))

        let olderLoad = Task { @MainActor in
            try await readerContent.load(url: olderURL)
        }
        await resolver.waitUntilRequested(olderURL)

        let newerLoad = Task { @MainActor in
            try await readerContent.load(url: newerURL)
        }
        await resolver.waitUntilRequested(newerURL)

        resolver.finish(olderURL)
        _ = try await olderLoad.value

        XCTAssertEqual(readerContent.pageURL, newerURL)
        XCTAssertNil(readerContent.content)

        resolver.finish(newerURL)
        _ = try await newerLoad.value

        XCTAssertEqual(readerContent.pageURL, newerURL)
        XCTAssertEqual(readerContent.content?.url, newerURL)
    }

    func testFailedResolverDoesNotPoisonRetryForSameTarget() async throws {
        let originalResolver = ReaderContent.contentResolver
        var attemptCount = 0
        ReaderContent.contentResolver = { url, _, _ in
            attemptCount += 1
            if attemptCount == 1 {
                throw ResolverError.failed
            }
            let content = Bookmark()
            content.url = url
            content.updateCompoundKey()
            return content
        }
        defer {
            ReaderContent.contentResolver = originalResolver
        }

        let readerContent = ReaderContent()
        let url = try XCTUnwrap(URL(string: "https://example.com/retry"))

        do {
            try await readerContent.load(url: url)
            XCTFail("Expected the first resolver attempt to fail")
        } catch ResolverError.failed {
        }

        try await readerContent.load(url: url)

        XCTAssertEqual(attemptCount, 2)
        XCTAssertEqual(readerContent.content?.url, url)
    }

    func testOverlappingNavigationTokensKeepNewestNavigationActive() throws {
        let readerContent = ReaderContent()
        let olderURL = try XCTUnwrap(URL(string: "https://example.com/older"))
        let newerURL = try XCTUnwrap(URL(string: "https://example.com/newer"))

        let olderToken = readerContent.beginMainFrameNavigationTask(to: olderURL)
        let newerToken = readerContent.beginMainFrameNavigationTask(to: newerURL)

        readerContent.endMainFrameNavigationTask(olderToken)
        XCTAssertTrue(readerContent.isReaderMainFrameNavigating)
        XCTAssertEqual(readerContent.mainFrameNavigationURL, newerURL)

        readerContent.endMainFrameNavigationTask(olderToken)
        XCTAssertTrue(readerContent.isReaderMainFrameNavigating)
        XCTAssertEqual(readerContent.mainFrameNavigationURL, newerURL)

        readerContent.endMainFrameNavigationTask(newerToken)
        XCTAssertFalse(readerContent.isReaderMainFrameNavigating)
        XCTAssertNil(readerContent.mainFrameNavigationURL)
    }

    func testTransientBlankDoesNotCancelMatchingPendingLoadAndIsConsumedOnSuccess() async throws {
        let originalResolver = ReaderContent.contentResolver
        let resolver = ControlledReaderContentResolver()
        ReaderContent.contentResolver = { url, _, _ in
            await resolver.resolve(url)
        }
        defer {
            ReaderContent.contentResolver = originalResolver
        }

        let readerContent = ReaderContent()
        let targetURL = try XCTUnwrap(URL(string: "https://example.com/restored"))
        let blankURL = try XCTUnwrap(URL(string: "about:blank"))
        readerContent.suppressTransientAboutBlank(untilNextNonBlankLoad: targetURL)

        let targetLoad = Task { @MainActor in
            try await readerContent.load(url: targetURL)
        }
        await resolver.waitUntilRequested(targetURL)

        try await readerContent.load(url: blankURL)
        XCTAssertEqual(readerContent.pageURL, targetURL)
        XCTAssertFalse(resolver.wasRequested(blankURL))

        resolver.finish(targetURL)
        _ = try await targetLoad.value
        XCTAssertEqual(readerContent.content?.url, targetURL)

        let blankLoad = Task { @MainActor in
            try await readerContent.load(url: blankURL)
        }
        await resolver.waitUntilRequested(blankURL)
        resolver.finish(blankURL)
        _ = try await blankLoad.value

        XCTAssertEqual(readerContent.pageURL, blankURL)
        XCTAssertEqual(readerContent.content?.url, blankURL)
    }

    func testMalformedSnippetRoutesCannotReuseCurrentSelectionDirectlyOrThroughLoader() async throws {
        let snippetURL = try XCTUnwrap(ReaderContentLoader.snippetURL(key: "stored-snippet"))
        let snippet = HistoryRecord()
        snippet.url = snippetURL
        snippet.compoundKey = "stored-snippet"
        snippet.title = "Stored snippet"

        let originalResolver = ReaderContent.contentResolver
        var requestedURLs = [URL]()
        ReaderContent.contentResolver = { requestedURL, _, _ in
            requestedURLs.append(requestedURL)
            return requestedURL == snippetURL ? snippet : nil
        }
        defer {
            ReaderContent.contentResolver = originalResolver
        }

        for value in [
            "internal://local/snippet-other?key=stored-snippet",
            "internal://local/snippet/?key=stored-snippet",
            "internal://local/snippet#key=stored-snippet",
            "internal://local/snippet?key=stored-snippet&key=other",
            "internal://local/snippet?key=stored-snippet&other=x",
            "internal://user@local/snippet?key=stored-snippet",
            "internal://local:443/snippet?key=stored-snippet",
            "about:snippet-other?key=stored-snippet",
            "about:snippet#key=stored-snippet",
        ] {
            let malformedURL = try XCTUnwrap(URL(string: value))
            XCTAssertNil(ReaderContentLoader.readerLoaderURL(for: malformedURL), value)
            // The production builder rejects these inputs; model an incoming
            // malformed transport without weakening its admission policy.
            var loader = try XCTUnwrap(URLComponents(string: "internal://local/load/reader"))
            loader.queryItems = [URLQueryItem(name: "reader-url", value: malformedURL.absoluteString)]
            let loaderURL = try XCTUnwrap(loader.url)
            XCTAssertFalse(snippetURL.matchesReaderURL(malformedURL), value)
            XCTAssertFalse(snippetURL.matchesReaderURL(loaderURL), value)

            for requestedURL in [malformedURL, loaderURL] {
                requestedURLs.removeAll()
                let readerContent = ReaderContent()
                try await readerContent.load(url: snippetURL)
                XCTAssertTrue(readerContent.content === snippet)

                try await readerContent.load(url: requestedURL)

                XCTAssertEqual(requestedURLs, [snippetURL, requestedURL], requestedURL.absoluteString)
                XCTAssertEqual(readerContent.pageURL, requestedURL, requestedURL.absoluteString)
                XCTAssertNil(readerContent.content, requestedURL.absoluteString)
            }
        }
    }

    func testNestedArticleLoaderPublishesSourceIdentityAndPreservesResolverInput() async throws {
        let source = try XCTUnwrap(URL(string: "https://example.com/article?value=a%26b#source"))
        let article = HistoryRecord()
        article.url = source
        article.title = "Stored article"
        article.updateCompoundKey()
        let inner = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: source))
        var outer = try XCTUnwrap(URLComponents(string: "internal://local/load/reader"))
        outer.queryItems = [URLQueryItem(name: "reader-url", value: inner.absoluteString)]
        outer.fragment = "position"
        let transport = try XCTUnwrap(outer.url)

        let originalResolver = ReaderContent.contentResolver
        var requestedURLs = [URL]()
        ReaderContent.contentResolver = { requestedURL, _, _ in
            requestedURLs.append(requestedURL)
            return article
        }
        defer { ReaderContent.contentResolver = originalResolver }

        let reader = ReaderContent()
        try await reader.load(url: transport)
        XCTAssertEqual(requestedURLs, [transport])
        XCTAssertEqual(reader.pageURL, source)
        XCTAssertTrue(reader.content === article)
        XCTAssertEqual(transport.readerContentURL, URL(string: "https://example.com/article?value=a%26b#position"))
    }

    func testValidSnippetAndLegacyLoaderWrappersKeepCurrentSelection() async throws {
        let snippetURL = try XCTUnwrap(ReaderContentLoader.snippetURL(key: "stored-snippet"))
        let legacyURL = try XCTUnwrap(URL(string: "about:snippet?key=stored-snippet"))
        let loaderURL = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: snippetURL))
        var nestedLoader = try XCTUnwrap(URLComponents(string: "internal://local/load/reader"))
        nestedLoader.queryItems = [URLQueryItem(name: "reader-url", value: loaderURL.absoluteString)]
        let nestedLoaderURL = try XCTUnwrap(nestedLoader.url)
        let legacyLoaderURL = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: legacyURL))
        let snippet = HistoryRecord()
        snippet.url = snippetURL
        snippet.compoundKey = "stored-snippet"
        snippet.title = "Stored snippet"

        let originalResolver = ReaderContent.contentResolver
        var requestedURLs = [URL]()
        ReaderContent.contentResolver = { requestedURL, _, _ in
            requestedURLs.append(requestedURL)
            return snippet
        }
        defer {
            ReaderContent.contentResolver = originalResolver
        }

        let readerContent = ReaderContent()
        try await readerContent.load(url: snippetURL)

        for requestedURL in [snippetURL, legacyURL, loaderURL, nestedLoaderURL, legacyLoaderURL] {
            XCTAssertTrue(snippetURL.matchesReaderURL(requestedURL), requestedURL.absoluteString)
            XCTAssertEqual(ReaderContentLoader.getContentURL(fromLoaderURL: requestedURL), snippetURL)

            try await readerContent.load(url: requestedURL)

            XCTAssertTrue(readerContent.content === snippet)
            XCTAssertEqual(readerContent.pageURL, snippetURL)
            XCTAssertEqual(requestedURLs, [snippetURL])
        }
    }
}

@MainActor
private final class ControlledReaderContentResolver {
    private var requestedURLs = Set<URL>()
    private var continuations: [URL: CheckedContinuation<Void, Never>] = [:]

    func resolve(_ url: URL) async -> (any ReaderContentProtocol)? {
        requestedURLs.insert(url)
        await withCheckedContinuation { continuation in
            continuations[url] = continuation
        }

        let content = Bookmark()
        content.url = url
        content.updateCompoundKey()
        return content
    }

    func waitUntilRequested(_ url: URL) async {
        while !requestedURLs.contains(url) {
            await Task.yield()
        }
    }

    func finish(_ url: URL) {
        continuations.removeValue(forKey: url)?.resume()
    }

    func wasRequested(_ url: URL) -> Bool {
        requestedURLs.contains(url)
    }
}
