import Foundation
import Combine
import WebKit
import XCTest
@testable import SwiftUIWebView
@testable import LakeOfFireContent
@testable import LakeOfFireReader

@MainActor
final class ReaderContentNavigationIntentTests: XCTestCase {
    private let url = URL(string: "https://example.com/saved")!

    private func record() -> HistoryRecord {
        let value = HistoryRecord()
        value.compoundKey = "saved"
        value.url = url
        value.title = "Saved"
        return value
    }

    /// Suspends the real loader at its existing URL-resolution seam. Navigation
    /// and callback effects remain those of the production navigator.
    @MainActor
    private final class Resolver {
        let entered: XCTestExpectation
        private var result: CheckedContinuation<URL?, Never>?
        private(set) var didEnter = false
        private var released = false
        private var releasedURL: URL?
        init(entered: XCTestExpectation) { self.entered = entered }
        func resolve() async -> URL? {
            didEnter = true
            entered.fulfill()
            if released { return releasedURL }
            return await withCheckedContinuation { continuation in
                result = continuation
            }
        }
        func release(_ url: URL?) {
            released = true
            releasedURL = url
            result?.resume(returning: url)
            result = nil
        }
    }

    private func waitForEntry(_ resolver: Resolver,
                              task: Task<ReaderContentLoadResult, Error>) async -> Bool {
        await fulfillment(of: [resolver.entered], timeout: 5)
        guard resolver.didEnter else {
            // Failed arrival must also be safe if the task enters after this
            // timeout. Close/release first, then cancel and join the real task.
            resolver.release(nil)
            task.cancel()
            _ = try? await task.value
            return false
        }
        return true
    }

    func testFirstLoadWithoutReaderModeModelIssuesAndReportsBeforeReturning() async throws {
        let navigator = WebViewNavigator(), content = record()
        var events: [String] = []
        let result = try await navigator.loadResolvedContent(
            content: content, readerModeViewModel: nil,
            shouldLoad: { true }, willDispatchLoad: { events.append("will") },
            didDispatchLoad: { receipt in
                XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, self.url.absoluteString)
                XCTAssertTrue(navigator.isCurrent(receipt))
                events.append("did")
            }, resolveURL: { self.url }
        )
        events.append("returned")
        guard case .issued(let receipt) = result else { return XCTFail("First load must issue") }
        XCTAssertTrue(navigator.isCurrent(receipt))
        XCTAssertEqual(events, ["will", "did", "returned"])
    }

    func testSameURLExplicitRequestDuringResolutionSuppressesOlderLoad() async throws {
        let navigator = WebViewNavigator(), content = record()
        let resolver = Resolver(entered: expectation(description: "First resolver entered"))
        var willCalls = 0, didCalls = 0
        let task = Task { @MainActor in
            try await navigator.loadResolvedContent(content: content, readerModeViewModel: nil,
                shouldLoad: { true }, willDispatchLoad: { willCalls += 1 },
                didDispatchLoad: { _ in didCalls += 1 }, resolveURL: { await resolver.resolve() })
        }
        defer { resolver.release(nil); task.cancel() }
        guard await waitForEntry(resolver, task: task) else { return }
        navigator.load(URLRequest(url: url))
        let replacement = navigator.navigationIntent
        resolver.release(url)
        let result = try await task.value
        XCTAssertEqual(result, .suppressed)
        XCTAssertTrue(navigator.isCurrent(replacement))
        XCTAssertEqual(willCalls, 0)
        XCTAssertEqual(didCalls, 0)
    }

    func testNewerUnresolvedSameURLIntentSupersedesOlderResolverBeforeEitherDispatches() async throws {
        let navigator = WebViewNavigator(), content = record()
        let first = Resolver(entered: expectation(description: "Older resolver entered"))
        let second = Resolver(entered: expectation(description: "Newer resolver entered"))
        var firstDispatches = 0, secondDispatches = 0
        let firstTask = Task { @MainActor in
            try await navigator.loadResolvedContent(content: content, readerModeViewModel: nil,
                shouldLoad: { true }, didDispatchLoad: { _ in firstDispatches += 1 },
                resolveURL: { await first.resolve() })
        }
        defer { first.release(nil); firstTask.cancel() }
        guard await waitForEntry(first, task: firstTask) else { return }
        let secondTask = Task { @MainActor in
            try await navigator.loadResolvedContent(content: content, readerModeViewModel: nil,
                shouldLoad: { true }, didDispatchLoad: { _ in secondDispatches += 1 },
                resolveURL: { await second.resolve() })
        }
        defer { second.release(nil); secondTask.cancel() }
        guard await waitForEntry(second, task: secondTask) else {
            first.release(nil)
            firstTask.cancel()
            _ = try? await firstTask.value
            return
        }
        first.release(url)
        let firstResult = try await firstTask.value
        XCTAssertEqual(firstResult, .suppressed)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, "nil")
        second.release(url)
        let secondResult = try await secondTask.value
        guard case .issued = secondResult else { return XCTFail("Newer resolver must issue") }
        XCTAssertEqual(firstDispatches, 0)
        XCTAssertEqual(secondDispatches, 1)
    }

    func testSourceAdmissionRefusalHasNoLoadingCallbacksOrRequest() async throws {
        let navigator = WebViewNavigator()
        let model = ReaderModeViewModel()
        let content = record()
        content.isReaderModeByDefault = true
        var calls = 0
        let result = try await navigator.loadResolvedContent(content: content, readerModeViewModel: model,
            shouldLoad: { false }, willDispatchLoad: { calls += 1 },
            didDispatchLoad: { _ in calls += 1 }, resolveURL: { self.url })
        XCTAssertEqual(result, .suppressed)
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(model.isReaderModeLoading)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, "nil")
    }

    func testLoadingPublicationCannotDispatchOverItsSynchronousReplacement() async throws {
        let navigator = WebViewNavigator(), model = ReaderModeViewModel(), content = record()
        content.isReaderModeByDefault = true
        let replacementURL = URL(string: "https://example.com/loading-observer")!
        let subscription = model.$isReaderModeLoading.dropFirst().sink { isLoading in
            if isLoading { navigator.load(URLRequest(url: replacementURL)) }
        }
        defer { subscription.cancel() }
        var willCalls = 0, didCalls = 0
        let result = try await navigator.loadResolvedContent(content: content, readerModeViewModel: model,
            shouldLoad: { true }, willDispatchLoad: { willCalls += 1 },
            didDispatchLoad: { _ in didCalls += 1 }, resolveURL: { self.url })
        XCTAssertEqual(result, .suppressed)
        XCTAssertTrue(model.isReaderModeLoading)
        XCTAssertEqual(willCalls, 0)
        XCTAssertEqual(didCalls, 0)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, replacementURL.absoluteString)
    }

    @MainActor
    private final class StalledScheme: NSObject, WKURLSchemeHandler {
        let started: XCTestExpectation
        init(started: XCTestExpectation) { self.started = started }
        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            started.fulfill()
        }
        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
    }

    func testExplicitForceReloadIssuesSameURLWhileOrdinaryLoadRemainsSuppressed() async throws {
        let navigator = WebViewNavigator(), content = record()
        let started = expectation(description: "Real native scheme request is loading")
        let scheme = StalledScheme(started: started)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(scheme, forURLScheme: "handoff-test")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let target = URL(string: "handoff-test://saved/entry")!
        navigator.shouldLoadFallbackOnAttach = false
        navigator.webView = webView
        // The navigator records its actual queued request. A real native load
        // supplies loading state without a URL snapshot or WebView test double.
        navigator.load(URLRequest(url: target))
        webView.load(URLRequest(url: target))
        await fulfillment(of: [started], timeout: 5)
        defer { webView.stopLoading(); navigator.webView = nil }
        XCTAssertTrue(webView.isLoading)
        var callbacks = 0
        let ordinary = try await navigator.loadResolvedContent(content: content, readerModeViewModel: nil,
            shouldLoad: { true }, didDispatchLoad: { _ in callbacks += 1 }, resolveURL: { target })
        XCTAssertEqual(ordinary, .suppressed)
        let forced = try await navigator.loadResolvedContent(content: content, readerModeViewModel: nil,
            shouldLoad: { true }, forceReload: true,
            didDispatchLoad: { receipt in
                XCTAssertTrue(navigator.isCurrent(receipt))
                callbacks += 1
            }, resolveURL: { target })
        guard case .issued = forced else { return XCTFail("Explicit same-URL open must issue") }
        XCTAssertEqual(callbacks, 1)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, target.absoluteString)
    }

    func testLegacyWillCallbackCannotOverwriteItsSynchronousReplacement() async throws {
        let navigator = WebViewNavigator()
        let replacementURL = URL(string: "https://example.com/replacement")!
        var didCalls = 0
        let result = try await navigator.loadResolvedContent(content: record(), readerModeViewModel: nil,
            shouldLoad: { true }, willDispatchLoad: { navigator.load(URLRequest(url: replacementURL)) },
            didDispatchLoad: { _ in didCalls += 1 }, resolveURL: { self.url })
        XCTAssertEqual(result, .suppressed)
        XCTAssertEqual(didCalls, 0)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, replacementURL.absoluteString)
    }

    func testWithdrawalDuringWillCallbackIsRecheckedBeforeDispatch() async throws {
        let navigator = WebViewNavigator()
        var permits = true, didCalls = 0
        let result = try await navigator.loadResolvedContent(content: record(), readerModeViewModel: nil,
            shouldLoad: { permits }, willDispatchLoad: { permits = false },
            revalidateAdmissionBeforeDispatch: true,
            didDispatchLoad: { _ in didCalls += 1 }, resolveURL: { self.url })
        XCTAssertEqual(result, .suppressed)
        XCTAssertEqual(didCalls, 0)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, "nil")
    }

    func testIssuedRequestRemainsIssuedWhenDidCallbackSupersedesIt() async throws {
        let navigator = WebViewNavigator()
        var received: WebViewNavigator.NavigationDispatchReceipt?
        let result = try await navigator.loadResolvedContent(content: record(), readerModeViewModel: nil,
            shouldLoad: { true }, didDispatchLoad: { receipt in
                received = receipt
                XCTAssertTrue(navigator.isCurrent(receipt))
                navigator.load(URLRequest(url: self.url))
                XCTAssertFalse(navigator.isCurrent(receipt))
            }, resolveURL: { self.url })
        guard case .issued(let receipt) = result else { return XCTFail("An issued request cannot become suppressed") }
        XCTAssertEqual(receipt, received)
        XCTAssertFalse(navigator.isCurrent(receipt))
    }

    func testNilResolverAndThrownResolverNeverReportIssuance() async throws {
        enum Failure: Error { case unavailable }
        let navigator = WebViewNavigator()
        var didCalls = 0
        let empty = try await navigator.loadResolvedContent(content: record(), readerModeViewModel: nil,
            shouldLoad: { true }, didDispatchLoad: { _ in didCalls += 1 }, resolveURL: { nil })
        XCTAssertEqual(empty, .suppressed)
        do {
            _ = try await navigator.loadResolvedContent(content: record(), readerModeViewModel: nil,
                shouldLoad: { true }, didDispatchLoad: { _ in didCalls += 1 },
                resolveURL: { throw Failure.unavailable })
            XCTFail("Resolver error must propagate")
        } catch Failure.unavailable {}
        XCTAssertEqual(didCalls, 0)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, "nil")
    }

    func testLegacyAcceptedHintIsCalledOnceAndMayRetireItsOwnPresentationAndTask() async throws {
        let navigator = WebViewNavigator(), content = record()
        var presentationVisible = true, hintCalls = 0, dispatches = 0
        let task = Task { @MainActor in
            try await navigator.loadResolvedContent(content: content, readerModeViewModel: nil,
                shouldLoad: {
                    guard presentationVisible else { return false }
                    hintCalls += 1
                    // Actual accepted content-open hints remove Home. SwiftUI
                    // can cancel that source task as part of its own cleanup.
                    presentationVisible = false
                    withUnsafeCurrentTask { $0?.cancel() }
                    return true
                },
                didDispatchLoad: { _ in dispatches += 1 }, resolveURL: { self.url })
        }
        let result = try await task.value
        guard case .issued = result else { return XCTFail("An accepted legacy hint must still dispatch") }
        XCTAssertEqual(hintCalls, 1)
        XCTAssertEqual(dispatches, 1)
        XCTAssertFalse(presentationVisible)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, url.absoluteString)
    }

    func testTaskCancelledBeforeLoaderEntryCannotReserveOrSupersedeActiveIntent() async throws {
        let navigator = WebViewNavigator(), content = record()
        navigator.load(URLRequest(url: url))
        let active = navigator.navigationIntent
        var resolverCalls = 0, permissionCalls = 0
        let task = Task { @MainActor in
            try await navigator.loadResolvedContent(content: content, readerModeViewModel: nil,
                shouldLoad: { permissionCalls += 1; return true },
                resolveURL: { resolverCalls += 1; return self.url })
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled entry must throw") }
        catch is CancellationError {}
        XCTAssertTrue(navigator.isCurrent(active))
        XCTAssertEqual(resolverCalls, 0)
        XCTAssertEqual(permissionCalls, 0)
    }

    func testTypedCancellationAfterHeldResolverCannotPublishLoadingOrHint() async throws {
        let navigator = WebViewNavigator(), model = ReaderModeViewModel(), content = record()
        content.isReaderModeByDefault = true
        let resolver = Resolver(entered: expectation(description: "Cancellable resolver entered"))
        var hints = 0, dispatches = 0
        let task = Task { @MainActor in
            try await navigator.loadResolvedContent(content: content, readerModeViewModel: model,
                shouldLoad: { true }, willDispatchLoad: { hints += 1 },
                revalidateAdmissionBeforeDispatch: true,
                didDispatchLoad: { _ in dispatches += 1 }, resolveURL: { await resolver.resolve() })
        }
        defer { resolver.release(nil); task.cancel() }
        guard await waitForEntry(resolver, task: task) else { return }
        task.cancel()
        resolver.release(url)
        do { _ = try await task.value; XCTFail("Cancelled resolver completion must throw") }
        catch is CancellationError {}
        XCTAssertFalse(model.isReaderModeLoading)
        XCTAssertEqual(hints, 0)
        XCTAssertEqual(dispatches, 0)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, "nil")
    }

    func testSupersededTypedResolverFailureIsSuppressedBeforeErrorPresentation() async throws {
        enum Failure: Error { case obsolete }
        let navigator = WebViewNavigator(), content = record()
        let resolver = Resolver(entered: expectation(description: "Failing resolver entered"))
        let task = Task { @MainActor in
            try await navigator.loadResolvedContent(content: content, readerModeViewModel: nil,
                shouldLoad: { true }, revalidateAdmissionBeforeDispatch: true,
                resolveURL: {
                    _ = await resolver.resolve()
                    throw Failure.obsolete
                })
        }
        defer { resolver.release(nil); task.cancel() }
        guard await waitForEntry(resolver, task: task) else { return }
        navigator.load(URLRequest(url: url))
        let replacement = navigator.navigationIntent
        resolver.release(url)
        let result = try await task.value
        XCTAssertEqual(result, .suppressed)
        XCTAssertTrue(navigator.isCurrent(replacement))
    }
}
