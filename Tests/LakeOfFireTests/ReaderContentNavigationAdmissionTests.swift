import Foundation
import LakeOfFireCore
import SwiftUIWebView
import XCTest
@testable import LakeOfFireContent

@MainActor
final class ReaderContentNavigationAdmissionTests: XCTestCase {
    private enum ResolutionError: Error, Equatable {
        case failed
    }

    private enum SuspensionPoint: Equatable {
        case contentURL
        case previousContent
    }

    @MainActor
    private final class Gate {
        let entered = XCTestExpectation(description: "Producer suspended")
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered.fulfill()
            }
        }

        func open() {
            isOpen = true
            let continuation = continuation
            self.continuation = nil
            continuation?.resume()
        }
    }

    @MainActor
    private final class ModeHandler: ReaderModeLoadHandling {
        var began: [URL] = []
        var cancelled: [URL?] = []
        var onPublication: (() -> Void)?

        func beginReaderModeLoad(for url: URL, suppressSpinner: Bool, reason: String?) {
            XCTAssertFalse(suppressSpinner)
            XCTAssertEqual(reason, "webViewNavigator.load.prefetch")
            began.append(url)
            onPublication?()
        }

        func cancelReaderModeLoad(for url: URL?) {
            cancelled.append(url)
            onPublication?()
        }
    }

    private func content(_ value: String = "https://example.com/article", readerMode: Bool = true) -> Bookmark {
        let content = Bookmark()
        content.url = URL(string: value)!
        content.isReaderModeByDefault = readerMode
        content.updateCompoundKey()
        return content
    }

    private func assertNoPublication(
        navigator: WebViewNavigator,
        handler: ModeHandler,
        dispatches: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, "nil", file: file, line: line)
        XCTAssertTrue(handler.began.isEmpty, file: file, line: line)
        XCTAssertTrue(handler.cancelled.isEmpty, file: file, line: line)
        XCTAssertEqual(dispatches, 0, file: file, line: line)
    }

    func testRejectedEntryDoesNotStartEitherProducer() async throws {
        let navigator = WebViewNavigator()
        let handler = ModeHandler()
        let content = content()
        var resolutions = 0
        var prefetches = 0
        var dispatches = 0

        try await navigator.loadResolvedContent(
            content: content,
            readerModeViewModel: handler,
            shouldLoad: { false },
            willDispatchLoad: { dispatches += 1 },
            resolveURL: { resolutions += 1; return content.url },
            resolvePreviousContent: { _ in prefetches += 1; return nil }
        )

        XCTAssertEqual(resolutions, 0)
        XCTAssertEqual(prefetches, 0)
        assertNoPublication(navigator: navigator, handler: handler, dispatches: dispatches)
    }

    func testCancellationBeforeEntryDoesNotStartEitherProducer() async throws {
        let navigator = WebViewNavigator()
        let handler = ModeHandler()
        let content = content()
        var resolutions = 0
        var prefetches = 0
        var dispatches = 0
        let task = Task { @MainActor in
            try await navigator.loadResolvedContent(
                content: content,
                readerModeViewModel: handler,
                willDispatchLoad: { dispatches += 1 },
                resolveURL: { resolutions += 1; return content.url },
                resolvePreviousContent: { _ in prefetches += 1; return nil }
            )
        }
        task.cancel()
        try await task.value

        XCTAssertEqual(resolutions, 0)
        XCTAssertEqual(prefetches, 0)
        assertNoPublication(navigator: navigator, handler: handler, dispatches: dispatches)
    }

    private func verifyRetiredProducer(
        at point: SuspensionPoint,
        cancelTask: Bool
    ) async throws {
        let navigator = WebViewNavigator()
        let handler = ModeHandler()
        let content = content()
        let gate = Gate()
        var admitted = true
        var prefetches = 0
        var dispatches = 0
        let task = Task { @MainActor in
            try await navigator.loadResolvedContent(
                content: content,
                readerModeViewModel: handler,
                shouldLoad: { admitted },
                willDispatchLoad: { dispatches += 1 },
                resolveURL: {
                    if point == .contentURL { await gate.wait() }
                    return content.url
                },
                resolvePreviousContent: { _ in
                    prefetches += 1
                    if point == .previousContent { await gate.wait() }
                    return nil
                }
            )
        }
        addTeardownBlock {
            task.cancel()
            await gate.open()
            _ = try? await task.value
        }
        await fulfillment(of: [gate.entered], timeout: 1)
        if cancelTask { task.cancel() } else { admitted = false }
        gate.open()
        try await task.value

        XCTAssertEqual(prefetches, point == .contentURL ? 0 : 1)
        assertNoPublication(navigator: navigator, handler: handler, dispatches: dispatches)
    }

    func testRetirementDuringContentURLResolutionPreventsPrefetchAndPublication() async throws {
        try await verifyRetiredProducer(at: .contentURL, cancelTask: false)
    }

    func testRetirementDuringPreviousContentPrefetchPreventsPublication() async throws {
        try await verifyRetiredProducer(at: .previousContent, cancelTask: false)
    }

    func testCancellationDuringContentURLResolutionPreventsPublication() async throws {
        try await verifyRetiredProducer(at: .contentURL, cancelTask: true)
    }

    func testCancellationDuringPreviousContentPrefetchPreventsPublication() async throws {
        try await verifyRetiredProducer(at: .previousContent, cancelTask: true)
    }

    func testAcceptedPrefetchPreservesTrackingPolicyAndConsumesOneDispatch() async throws {
        let navigator = WebViewNavigator()
        let handler = ModeHandler()
        let original = content(readerMode: false)
        let previous = content("https://example.com/stored", readerMode: true)
        var admitted = true
        var dispatches = 0
        var prefetchURLs: [URL] = []

        try await navigator.loadResolvedContent(
            content: original,
            readerModeViewModel: handler,
            shouldLoad: { admitted },
            willDispatchLoad: {
                XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, "nil")
                dispatches += 1
                admitted = false
            },
            resolveURL: { original.url },
            resolvePreviousContent: { url in prefetchURLs.append(url); return previous }
        )

        XCTAssertEqual(prefetchURLs, [original.url])
        XCTAssertEqual(handler.began, [previous.url])
        XCTAssertTrue(handler.cancelled.isEmpty)
        XCTAssertEqual(dispatches, 1)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, original.url.absoluteString)
    }

    func testNonReaderPrefetchPreservesCancellationPolicy() async throws {
        let navigator = WebViewNavigator()
        let handler = ModeHandler()
        let original = content()
        let previous = content("https://example.com/stored", readerMode: false)

        try await navigator.loadResolvedContent(
            content: original,
            readerModeViewModel: handler,
            resolveURL: { original.url },
            resolvePreviousContent: { _ in previous }
        )

        XCTAssertTrue(handler.began.isEmpty)
        XCTAssertEqual(handler.cancelled, [previous.url])
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, original.url.absoluteString)
    }

    func testCurrentMissingURLThrowsWithoutConsumingAndCanRetry() async throws {
        let navigator = WebViewNavigator()
        let handler = ModeHandler()
        let content = content()
        var dispatches = 0
        do {
            try await navigator.loadResolvedContent(
                content: content,
                readerModeViewModel: handler,
                willDispatchLoad: { dispatches += 1 },
                resolveURL: { nil },
                resolvePreviousContent: { _ in XCTFail("Missing URLs cannot prefetch"); return nil }
            )
            XCTFail("Expected unresolved URL failure")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Reader content could not resolve a navigable URL for \(content.url.absoluteString)"
            )
        }
        assertNoPublication(navigator: navigator, handler: handler, dispatches: dispatches)

        try await navigator.loadResolvedContent(
            content: content,
            readerModeViewModel: handler,
            willDispatchLoad: { dispatches += 1 },
            resolveURL: { content.url },
            resolvePreviousContent: { _ in nil }
        )
        XCTAssertEqual(dispatches, 1)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, content.url.absoluteString)
    }

    func testRetiredMissingURLDoesNotPublishAnUnresolvedError() async throws {
        let navigator = WebViewNavigator()
        let handler = ModeHandler()
        let content = content()
        var admitted = true
        var dispatches = 0
        try await navigator.loadResolvedContent(
            content: content,
            readerModeViewModel: handler,
            shouldLoad: { admitted },
            willDispatchLoad: { dispatches += 1 },
            resolveURL: { admitted = false; return nil },
            resolvePreviousContent: { _ in XCTFail("Missing URLs cannot prefetch"); return nil }
        )
        assertNoPublication(navigator: navigator, handler: handler, dispatches: dispatches)
    }

    func testProducerFailuresPropagateWithoutPresentationOrConsumption() async throws {
        for failurePoint in [SuspensionPoint.contentURL, .previousContent] {
            let navigator = WebViewNavigator()
            let handler = ModeHandler()
            let content = content()
            var dispatches = 0
            do {
                try await navigator.loadResolvedContent(
                    content: content,
                    readerModeViewModel: handler,
                    willDispatchLoad: { dispatches += 1 },
                    resolveURL: {
                        if failurePoint == .contentURL { throw ResolutionError.failed }
                        return content.url
                    },
                    resolvePreviousContent: { _ in throw ResolutionError.failed }
                )
                XCTFail("Expected producer failure")
            } catch {
                XCTAssertEqual(error as? ResolutionError, .failed)
            }
            assertNoPublication(navigator: navigator, handler: handler, dispatches: dispatches)
        }
    }

    func testAbsentModeHandlerSkipsPrefetchAndStillDispatches() async throws {
        let navigator = WebViewNavigator()
        let content = content()
        var dispatches = 0
        try await navigator.loadResolvedContent(
            content: content,
            readerModeViewModel: nil,
            willDispatchLoad: { dispatches += 1 },
            resolveURL: { content.url },
            resolvePreviousContent: { _ in XCTFail("No mode handler needs no prefetch"); return nil }
        )
        XCTAssertEqual(dispatches, 1)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, content.url.absoluteString)
    }

    func testForcedSnippetRetainsLoaderRoutingAndOriginalTrackingURL() async throws {
        let navigator = WebViewNavigator()
        let handler = ModeHandler()
        let snippet = content("internal://local/snippet?key=navigation-admission", readerMode: false)
        let loaderURL = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: snippet.url))
        var prefetchURLs: [URL] = []

        try await navigator.loadResolvedContent(
            content: snippet,
            readerModeViewModel: handler,
            forceReaderModeForSnippets: true,
            resolveURL: { snippet.url },
            resolvePreviousContent: { url in prefetchURLs.append(url); return nil }
        )

        XCTAssertEqual(prefetchURLs, [loaderURL])
        XCTAssertEqual(handler.began, [snippet.url])
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, loaderURL.absoluteString)
    }

    func testEBookSkipsPreviousContentPrefetch() async throws {
        let navigator = WebViewNavigator()
        let handler = ModeHandler()
        let book = content("ebook://local/book.epub")
        var dispatches = 0

        try await navigator.loadResolvedContent(
            content: book,
            readerModeViewModel: handler,
            willDispatchLoad: { dispatches += 1 },
            resolveURL: { book.url },
            resolvePreviousContent: { _ in XCTFail("EBooks bypass the ordinary prefetch"); return nil }
        )

        XCTAssertEqual(dispatches, 1)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, book.url.absoluteString)
        XCTAssertTrue(handler.began.isEmpty)
        XCTAssertTrue(handler.cancelled.isEmpty)
    }

    func testRetirementFromModePublicationPreventsFinalNavigation() async throws {
        let navigator = WebViewNavigator()
        let handler = ModeHandler()
        let content = content()
        var admitted = true
        var dispatches = 0
        handler.onPublication = { admitted = false }

        try await navigator.loadResolvedContent(
            content: content,
            readerModeViewModel: handler,
            shouldLoad: { admitted },
            willDispatchLoad: { dispatches += 1 },
            resolveURL: { content.url },
            resolvePreviousContent: { _ in nil }
        )

        XCTAssertEqual(handler.began, [content.url])
        XCTAssertEqual(dispatches, 0)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, "nil")
    }

    func testHeldOldRequestCannotOverwriteAcceptedSuccessor() async throws {
        let navigator = WebViewNavigator()
        let handler = ModeHandler()
        let older = content("https://example.com/older")
        let newer = content("https://example.com/newer")
        let gate = Gate()
        var currentRequest = 1
        var dispatched: [Int] = []
        let oldTask = Task { @MainActor in
            try await navigator.loadResolvedContent(
                content: older,
                readerModeViewModel: handler,
                shouldLoad: { currentRequest == 1 },
                willDispatchLoad: { dispatched.append(1) },
                resolveURL: { await gate.wait(); return older.url },
                resolvePreviousContent: { _ in nil }
            )
        }
        addTeardownBlock {
            oldTask.cancel()
            await gate.open()
            _ = try? await oldTask.value
        }
        await fulfillment(of: [gate.entered], timeout: 1)
        currentRequest = 2
        try await navigator.loadResolvedContent(
            content: newer,
            readerModeViewModel: handler,
            shouldLoad: { currentRequest == 2 },
            willDispatchLoad: { dispatched.append(2) },
            resolveURL: { newer.url },
            resolvePreviousContent: { _ in nil }
        )
        gate.open()
        try await oldTask.value

        XCTAssertEqual(dispatched, [2])
        XCTAssertEqual(handler.began, [newer.url])
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, newer.url.absoluteString)
    }
}
