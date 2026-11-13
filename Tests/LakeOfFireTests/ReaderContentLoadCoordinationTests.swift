import XCTest
@testable import LakeOfFireContent
@testable import LakeOfFireCore

@MainActor
final class ReaderContentLoadCoordinationTests: XCTestCase {
    private enum ResolverError: Error {
        case failed
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
        let reader = ReaderContent()
        var requestedURLs: [URL] = []
        try await reader.load(url: transport, resolveContent: { requested in
            requestedURLs.append(requested)
            return article
        })
        XCTAssertEqual(requestedURLs, [transport])
        XCTAssertEqual(reader.pageURL, source)
        XCTAssertTrue(reader.content === article)
        XCTAssertEqual(transport.readerContentURL,
                       URL(string: "https://example.com/article?value=a%26b#position"))
    }

    func testValidSnippetAndLegacyLoaderWrappersKeepCurrentSelection() async throws {
        let source = try XCTUnwrap(ReaderContentLoader.snippetURL(key: "stored-snippet"))
        let legacy = try XCTUnwrap(URL(string: "about:snippet?key=stored-snippet"))
        let loader = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: source))
        var nested = try XCTUnwrap(URLComponents(string: "internal://local/load/reader"))
        nested.queryItems = [URLQueryItem(name: "reader-url", value: loader.absoluteString)]
        let wrappers = [source, legacy, loader, try XCTUnwrap(nested.url),
                        try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: legacy))]
        let snippet = HistoryRecord()
        snippet.url = source
        snippet.updateCompoundKey()
        let reader = ReaderContent()
        var requests: [URL] = []
        for wrapper in wrappers {
            try await reader.load(url: wrapper, resolveContent: { requested in
                requests.append(requested)
                return snippet
            })
            XCTAssertEqual(reader.pageURL, source, wrapper.absoluteString)
            XCTAssertTrue(reader.content === snippet, wrapper.absoluteString)
        }
        XCTAssertEqual(requests, [source])
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
