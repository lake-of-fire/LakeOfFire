import SwiftUI
import SwiftUIWebView
import WebKit
import RealmSwift
import LakeOfFireContent
import LakeOfFireFiles
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import XCTest
@testable import LakeOfFireReader

private actor ReaderCallbackGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private enum ReaderCallbackTestError: Error {
    case commitFailed
}

@MainActor
final class ReaderWebViewCallbackContractTests: XCTestCase {
    func testMountedReaderChangesWebViewAndCallbackStoreTogether() async throws {
        let originalResolver = ReaderContent.contentResolver
        defer { ReaderContent.contentResolver = originalResolver }
        let session = ReaderMountedSession()
        let root = ReaderMountedSessionView(session: session)
        #if os(iOS)
        let controller = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        #else
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer { window.close(); window.contentViewController = nil }
        #endif
        weak var previousWebView: WKWebView?
        for token in ["first", "second"] {
            let store = WKWebsiteDataStore.nonPersistent()
            let cookie = try XCTUnwrap(HTTPCookie(properties: [
                .domain: "example.com", .path: "/", .name: "reader-session", .value: token,
            ]))
            await withCheckedContinuation { continuation in
                store.httpCookieStore.setCookie(cookie) { continuation.resume() }
            }
            session.store = store
            try await waitForMountedCondition {
                guard let view = self.descendantWebView(in: controller.view) else { return false }
                return view.configuration.websiteDataStore === store && view !== previousWebView
            }
            let webView = try XCTUnwrap(descendantWebView(in: controller.view))
            previousWebView = webView
            session.objectWillChange.send()
            await Task.yield()
            XCTAssertTrue(descendantWebView(in: controller.view) === webView)
            webView.loadHTMLString(
                "<html><body id='ready'><a id='pdf' href='https://example.com/book.pdf'>PDF</a></body></html>",
                baseURL: URL(string: "https://example.com/")
            )
            try await waitForMountedJavaScript("document.body.id === 'ready'", in: webView)
            let cookies = try await webView.evaluateJavaScript("document.cookie") as? String
            XCTAssertEqual(cookies, "reader-session=\(token)")
            let previousCount = session.callbackStores.count
            _ = try await webView.evaluateJavaScript("document.getElementById('pdf').click()")
            try await waitForMountedCondition { session.callbackStores.count > previousCount }
            XCTAssertTrue(session.callbackStores.last === store)
            XCTAssertNotEqual(webView.url?.path, "/book.pdf")
        }
        XCTAssertEqual(session.callbackStores.count, 2)
        XCTAssertFalse(session.callbackStores[0] === session.callbackStores[1])
    }

    #if os(iOS)
    func testPoolOwnerBreaksLegacyFactoryPrewarmerRetentionCycle() {
        weak var weakOwner: ReaderWebViewPoolOwner?
        weak var weakPrewarmer: WebViewPrewarmer?
        weak var weakPool: WebViewPool?
        autoreleasepool {
            let owner = ReaderWebViewPoolOwner()
            weakOwner = owner
            weakPrewarmer = owner.prewarmer
            weakPool = owner.prewarmer.pool
            let prewarmer = owner.prewarmer
            // Reproduce the legacy WebView factory's retained prewarmer without
            // launching a WebKit process. The owner itself is not captured.
            prewarmer.pool.totalCountTarget = 0
            prewarmer.pool.setCreationClosureIfNeeded {
                withExtendedLifetime(prewarmer) {}
                return EnhancedWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
            }
        }
        XCTAssertNil(weakOwner)
        XCTAssertNil(weakPrewarmer)
        XCTAssertNil(weakPool)
    }
    #endif

    private func waitForMountedCondition(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitForMountedJavaScript(_ script: String, in webView: WKWebView) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while (try? await webView.evaluateJavaScript(script)) as? Bool != true {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func descendantWebView(in view: ReaderMountedPlatformView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for child in view.subviews {
            if let webView = descendantWebView(in: child) { return webView }
        }
        return nil
    }

    func testOnlyPhoneReaderExpandsIntoEverySafeArea() {
        XCTAssertTrue(ReaderWebViewSafeAreaPolicy.expandsIntoAllSafeAreas(isPhone: true))
        XCTAssertFalse(ReaderWebViewSafeAreaPolicy.expandsIntoAllSafeAreas(isPhone: false))
    }

    func testIPadReaderModeDoesNotApplySplitViewLeadingInsetInsideWebKit() {
        let resolved = ReaderWebViewObscuredInsetResolver.resolve(
            obscuredInsets: EdgeInsets(top: 0, leading: 450, bottom: 0, trailing: 0),
            additionalInsets: EdgeInsets(top: 0, leading: 450, bottom: 0, trailing: 0),
            usesEBookChromeInsets: false,
            preservesLeadingSafeAreaInset: false
        )

        XCTAssertEqual(resolved.leading, 0)
    }

    func testPhoneReaderModeRetainsPhysicalLeadingSafeAreaInset() {
        let resolved = ReaderWebViewObscuredInsetResolver.resolve(
            obscuredInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
            additionalInsets: EdgeInsets(top: 0, leading: 44, bottom: 0, trailing: 0),
            usesEBookChromeInsets: false,
            preservesLeadingSafeAreaInset: true
        )

        XCTAssertEqual(resolved.leading, 44)
    }

    func testIPadEBookDoesNotApplySplitViewLeadingInsetInsideWebKit() {
        let resolved = ReaderWebViewObscuredInsetResolver.resolve(
            obscuredInsets: EdgeInsets(top: 0, leading: 450, bottom: 0, trailing: 0),
            additionalInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
            usesEBookChromeInsets: true,
            preservesLeadingSafeAreaInset: false
        )

        XCTAssertEqual(resolved.leading, 0)
    }

    func testIgnoredSampledTopRetainsFallbackAndClampPolicy() {
        let resolved = ReaderWebViewObscuredInsetResolver.resolve(
            obscuredInsets: EdgeInsets(top: 160, leading: 0, bottom: 0, trailing: 0),
            additionalInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
            usesEBookChromeInsets: false,
            preservesLeadingSafeAreaInset: false,
            ignoresSampledTopObscuredInset: true,
            fallbackTopInset: 47
        )

        XCTAssertEqual(resolved.top, 88)
    }

    func testCommitFailureSuppressesFinishAndPendingURLChange() async {
        let manager = NavigationTaskManager()
        var finishCount = 0
        var urlCount = 0

        manager.startOnNavigationCommitted { throw ReaderCallbackTestError.commitFailed }
        manager.startOnURLChanged { urlCount += 1 }
        manager.startOnNavigationFinished { finishCount += 1 }

        do {
            try await manager.onNavigationFinishedTask?.value
            XCTFail("A failed commit must fail the matching finish task")
        } catch ReaderCallbackTestError.commitFailed {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(finishCount, 0)
        XCTAssertEqual(urlCount, 0)
        XCTAssertNil(manager.onURLChangedTask)
    }

    func testFinishWaitsForCommitAndRunsOnce() async throws {
        let manager = NavigationTaskManager()
        let gate = ReaderCallbackGate()
        let commitStarted = expectation(description: "commit started")
        var finishCount = 0

        manager.startOnNavigationCommitted {
            commitStarted.fulfill()
            await gate.wait()
        }
        manager.startOnNavigationFinished { finishCount += 1 }
        manager.startOnNavigationFinished { finishCount += 100 }

        await fulfillment(of: [commitStarted], timeout: 1)
        XCTAssertEqual(finishCount, 0)
        await gate.release()
        try await manager.onNavigationFinishedTask?.value
        XCTAssertEqual(finishCount, 1)
    }

    func testURLChangeBeforeDidFinishQueuesBehindDocumentFinish() async throws {
        let manager = NavigationTaskManager()
        var order = [String]()

        manager.startOnNavigationCommitted { order.append("commit") }
        try await manager.onNavigationCommittedTask?.value
        manager.startOnURLChanged { order.append("url") }

        await Task.yield()
        XCTAssertEqual(order, ["commit"])
        XCTAssertNil(manager.onURLChangedTask)

        manager.startOnNavigationFinished { order.append("finish") }
        try await manager.onNavigationFinishedTask?.value
        try await manager.onURLChangedTask?.value
        XCTAssertEqual(order, ["commit", "finish", "url"])
    }

    func testURLChangeDuringFinishKeepsOnlyLatestMutation() async throws {
        let manager = NavigationTaskManager()
        let gate = ReaderCallbackGate()
        let finishStarted = expectation(description: "finish started")
        var order = [String]()

        manager.startOnNavigationCommitted { order.append("commit") }
        manager.startOnNavigationFinished {
            order.append("finish-start")
            finishStarted.fulfill()
            await gate.wait()
            order.append("finish-end")
        }
        await fulfillment(of: [finishStarted], timeout: 1)
        manager.startOnURLChanged { order.append("stale-url") }
        manager.startOnURLChanged { order.append("latest-url") }

        await gate.release()
        try await manager.onNavigationFinishedTask?.value
        try await manager.onURLChangedTask?.value
        XCTAssertEqual(order, ["commit", "finish-start", "finish-end", "latest-url"])
    }

    func testURLChangeBeforeFirstCommitIsIgnored() async {
        let manager = NavigationTaskManager()
        var urlCount = 0

        manager.startOnURLChanged { urlCount += 1 }
        await Task.yield()

        XCTAssertEqual(urlCount, 0)
        XCTAssertNil(manager.onURLChangedTask)
    }

    func testSettledDocumentURLChangeRunsWithoutAnotherDidFinish() async throws {
        let manager = NavigationTaskManager()
        var order = [String]()

        manager.startOnNavigationCommitted { order.append("commit") }
        manager.startOnNavigationFinished { order.append("finish") }
        try await manager.onNavigationFinishedTask?.value

        manager.startOnURLChanged { order.append("url") }
        try await manager.onURLChangedTask?.value
        XCTAssertEqual(order, ["commit", "finish", "url"])
    }

    func testNewCommitCancelsFinishWaitingOnPreviousCommit() async {
        let manager = NavigationTaskManager()
        let firstCommitStarted = expectation(description: "first commit started")
        let firstCommitCancelled = expectation(description: "first commit cancelled")
        let staleFinishCalled = expectation(description: "stale finish must not run")
        staleFinishCalled.isInverted = true
        let replacementCommitCalled = expectation(description: "replacement commit called")

        manager.startOnNavigationCommitted {
            firstCommitStarted.fulfill()
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                firstCommitCancelled.fulfill()
                throw CancellationError()
            }
        }
        manager.startOnNavigationFinished {
            staleFinishCalled.fulfill()
        }

        await fulfillment(of: [firstCommitStarted], timeout: 1)
        manager.startOnNavigationCommitted {
            replacementCommitCalled.fulfill()
        }
        await fulfillment(of: [firstCommitCancelled, replacementCommitCalled], timeout: 1)
        await fulfillment(of: [staleFinishCalled], timeout: 0.05)
    }

    func testTerminalCancellationStopsRunningURLCallbackAndClearsTasks() async throws {
        let manager = NavigationTaskManager()
        let urlStarted = expectation(description: "URL callback started")
        let urlCancelled = expectation(description: "URL callback cancelled")

        manager.startOnNavigationCommitted {}
        manager.startOnNavigationFinished {}
        try await manager.onNavigationFinishedTask?.value
        manager.startOnURLChanged {
            urlStarted.fulfill()
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                urlCancelled.fulfill()
                throw CancellationError()
            }
        }

        await fulfillment(of: [urlStarted], timeout: 1)
        manager.cancelNavigationWork()
        await fulfillment(of: [urlCancelled], timeout: 1)

        XCTAssertNil(manager.onNavigationCommittedTask)
        XCTAssertNil(manager.onNavigationFinishedTask)
        XCTAssertNil(manager.onNavigationFailedTask)
        XCTAssertNil(manager.onURLChangedTask)

        var lateURLCount = 0
        manager.startOnURLChanged { lateURLCount += 1 }
        await Task.yield()
        XCTAssertEqual(lateURLCount, 0)
        XCTAssertNil(manager.onURLChangedTask)
    }

    func testTerminalFailureCancelsDocumentWork() async {
        let manager = NavigationTaskManager()
        let commitStarted = expectation(description: "commit started")
        let commitCancelled = expectation(description: "commit cancelled")
        let failureCalled = expectation(description: "failure called")

        manager.startOnNavigationCommitted {
            commitStarted.fulfill()
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                commitCancelled.fulfill()
                throw CancellationError()
            }
        }
        await fulfillment(of: [commitStarted], timeout: 1)
        manager.startOnNavigationFailed {
            failureCalled.fulfill()
        }

        await fulfillment(of: [commitCancelled, failureCalled], timeout: 1)
    }

    func testNavigationFailureCancelsPendingDocumentWorkBeforeFailureCallback() async {
        let manager = NavigationTaskManager()
        let commitStarted = expectation(description: "commit started")
        let commitCancelled = expectation(description: "commit cancelled")
        let pendingURLCalled = expectation(description: "pending URL callback must not run")
        pendingURLCalled.isInverted = true
        let failureCalled = expectation(description: "failure callback called")

        manager.startOnNavigationCommitted {
            commitStarted.fulfill()
            do {
                try await Task.sleep(for: .seconds(30))
            } catch is CancellationError {
                commitCancelled.fulfill()
                throw CancellationError()
            }
        }
        manager.startOnURLChanged {
            pendingURLCalled.fulfill()
        }

        await fulfillment(of: [commitStarted], timeout: 1)
        manager.startOnNavigationFailed {
            failureCalled.fulfill()
        }
        await fulfillment(of: [commitCancelled, failureCalled], timeout: 1)
        await fulfillment(of: [pendingURLCalled], timeout: 0.05)
    }

    func testPreservedDocumentFailureKeepsSettledURLLifecycle() async throws {
        let manager = NavigationTaskManager()
        var order = [String]()

        manager.startOnNavigationCommitted { order.append("commit") }
        manager.startOnNavigationFinished { order.append("finish") }
        try await manager.onNavigationFinishedTask?.value
        manager.startOnNavigationFailed(preservingCommittedDocument: true) {
            order.append("recoverable-failure")
        }
        try await manager.onNavigationFailedTask?.value
        manager.startOnURLChanged { order.append("url") }
        try await manager.onURLChangedTask?.value

        XCTAssertEqual(order, ["commit", "finish", "recoverable-failure", "url"])
    }
}

#if os(iOS)
private typealias ReaderMountedPlatformView = UIView
#else
private typealias ReaderMountedPlatformView = NSView
#endif

@MainActor
private final class ReaderMountedSession: ObservableObject {
    @Published var store = WKWebsiteDataStore.nonPersistent()
    var callbackStores: [WKWebsiteDataStore] = []
    let content = ReaderContent()
    let reader = ReaderViewModel(realmConfiguration: .init(inMemoryIdentifier: UUID().uuidString), systemScripts: [])
    let mode = ReaderModeViewModel()
    let media = ReaderMediaPlayerViewModel()
    let files = ReaderFileManager()
}

private struct ReaderMountedSessionView: View {
    @ObservedObject var session: ReaderMountedSession

    var body: some View {
        ReaderWebView(obscuredInsets: nil)
            .readerWebViewDataStore(session.store)
            .readerNavigationActionContextHandler { context in
                await MainActor.run {
                    guard context.action.request.url?.path == "/book.pdf" else { return nil }
                    session.callbackStores.append(context.websiteDataStore)
                    return .cancel
                }
            }
            .environmentObject(session.content)
            .environmentObject(session.reader)
            .environmentObject(session.reader.scriptCaller)
            .environmentObject(session.mode)
            .environmentObject(session.media)
            .environmentObject(session.files)
    }
}
