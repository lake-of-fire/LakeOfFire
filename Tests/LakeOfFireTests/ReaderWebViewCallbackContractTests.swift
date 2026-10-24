import SwiftUI
import SwiftUIWebView
import WebKit
import RealmSwift
import BigSyncKit
import LakeOfFireContent
import LakeOfFireCore
import LakeOfFireFiles
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import XCTest
@testable import LakeOfFireReader
@testable import RealmSwiftGaps

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
    func testMountedReaderComposesCurrentInheritedProvidersWithoutReplacingItsBinding() async throws {
        let fixture = try await makeProviderFixture { session in
            session.provider(named: "readerProviderProbe", label: "A")
        }
        let session = fixture.session
        let webView = try XCTUnwrap(descendantWebView(in: fixture.view))
        let binding = try XCTUnwrap(session.reader?.scriptCaller.currentJavaScriptBindingToken)

        // The local owner arrives asynchronously on the first mount. Its table
        // and the inherited table must both reach the already-mounted WebView.
        try await waitForMountedJavaScript(
            "!!window.webkit.messageHandlers.ebookNavigationVisibility && !!window.webkit.messageHandlers.readerProviderProbe",
            in: webView
        )
        try await sendProviderMessage("readerProviderProbe", id: "first", in: webView, session: session)
        XCTAssertEqual(session.events, ["A:first"])
        try await sendVisibilityMessage(id: "local-first", hidden: true, in: webView, session: session)
        XCTAssertTrue(session.hidden)
        XCTAssertEqual(session.events, ["A:first", "A:local-first:true"],
            "The real local handler runs before the current inherited handler")

        session.publish(session.provider(named: "readerProviderProbe", label: "B"))
        try await waitForProviderPublication(session, in: webView)
        try await sendProviderMessage("readerProviderProbe", id: "replacement", in: webView, session: session)
        XCTAssertEqual(session.events.filter { $0.hasSuffix(":replacement") }, ["B:replacement"])

        for index in 0..<3 {
            session.publicationToggle.toggle() // An unrelated render keeps the same provider.
            try await waitForProviderPublication(session, in: webView)
            let id = "unrelated-\(index)"
            try await sendProviderMessage("readerProviderProbe", id: id, in: webView, session: session)
            XCTAssertEqual(session.events.filter { $0.hasSuffix(":" + id) }, ["B:" + id])
        }
        XCTAssertTrue(descendantWebView(in: fixture.view) === webView)
        XCTAssertEqual(session.reader?.scriptCaller.currentJavaScriptBindingToken, binding)

        session.publish(session.provider(named: "readerProviderRenamed", label: "C"))
        try await waitForProviderPublication(session, in: webView)
        try await waitForMountedJavaScript(
            "!window.webkit.messageHandlers.readerProviderProbe && !!window.webkit.messageHandlers.readerProviderRenamed",
            in: webView
        )
        try await sendProviderMessage("readerProviderRenamed", id: "renamed", in: webView, session: session)
        XCTAssertEqual(session.events.filter { $0.hasSuffix(":renamed") }, ["C:renamed"])

        let beforeRemoval = session.events
        session.publish(WebViewMessageHandlers())
        try await waitForProviderPublication(session, in: webView)
        try await waitForMountedJavaScript(
            "!window.webkit.messageHandlers.readerProviderProbe && !window.webkit.messageHandlers.readerProviderRenamed && !!window.webkit.messageHandlers.ebookNavigationVisibility",
            in: webView
        )
        try await sendVisibilityMessage(id: "local-only", hidden: false, in: webView, session: session)
        XCTAssertFalse(session.hidden)
        XCTAssertEqual(session.events, beforeRemoval, "Removed providers must not remain appended to the local owner")
        XCTAssertTrue(descendantWebView(in: fixture.view) === webView)
        XCTAssertEqual(session.reader?.scriptCaller.currentJavaScriptBindingToken, binding)
    }

    func testMountedReaderPublishesCancellationOnlyReplacementForLaterCallbacks() async throws {
        let gate = ReaderProviderCallbackGate()
        let fixture = try await makeProviderFixture { session in
            session.blockingProvider(gate: gate).updatingCancellationHandler("readerProviderBlocked") {
                @MainActor [weak session] message in
                session?.cancellations.append("A:" + ReaderProviderMountedSession.messageID(message))
            }
        }
        let session = fixture.session
        session.gates.append(gate)
        let webView = try XCTUnwrap(descendantWebView(in: fixture.view))
        let binding = try XCTUnwrap(session.reader?.scriptCaller.currentJavaScriptBindingToken)
        try await waitForMountedJavaScript("!!window.webkit.messageHandlers.readerProviderBlocked", in: webView)
        _ = try await webView.evaluateJavaScript("window.webkit.messageHandlers.readerProviderBlocked.postMessage('accepted-before')")
        try await waitForMountedCondition { session.entered.contains("accepted-before") }

        // Keep the exact ordinary handler table and replace only its cancellation
        // callback. Future receipts must capture B; an accepted receipt keeps A.
        let replacement = session.inherited.updatingCancellationHandler("readerProviderBlocked") {
            @MainActor [weak session] message in
            session?.cancellations.append("B:" + ReaderProviderMountedSession.messageID(message))
        }
        session.publish(replacement)
        try await waitForProviderPublication(session, in: webView)
        XCTAssertTrue(descendantWebView(in: fixture.view) === webView)
        XCTAssertEqual(session.reader?.scriptCaller.currentJavaScriptBindingToken, binding)
        _ = try await webView.evaluateJavaScript("window.webkit.messageHandlers.readerProviderBlocked.postMessage('accepted-after')")
        try await waitForMountedCondition { session.entered.contains("accepted-after") }

        // Real navigation invalidates the actual coordinator's callback context.
        webView.loadHTMLString("<html><body id='provider-next'>Next</body></html>",
            baseURL: URL(string: "https://example.com/provider-next")!)
        try await waitForMountedCondition { session.cancellations.count == 2 }
        XCTAssertEqual(session.cancellations.sorted(), ["A:accepted-before", "B:accepted-after"])
        await gate.release()
        try await waitForMountedCondition { session.finished.count == 2 }
    }

    private func makeProviderFixture(
        initialHandlers: (ReaderProviderMountedSession) -> WebViewMessageHandlers
    ) async throws -> ReaderProviderMountedFixture {
        let session = try ReaderProviderMountedSession()
        session.inherited = initialHandlers(session)
        let fixture = ReaderProviderMountedFixture(session: session)
        let readerReleased = session.readerReleased
        addTeardownBlock {
            await fixture.unmount()
            for gate in await session.gates { await gate.release() }
            let result = await XCTWaiter.fulfillment(of: [readerReleased], timeout: 5)
            guard result == .completed else {
                XCTFail("The real reader model must retire before shared fixture configuration is restored")
                return
            }
            await session.finishCleanup()
        }
        try await waitForMountedCondition { self.descendantWebView(in: fixture.view) != nil }
        let webView = try XCTUnwrap(descendantWebView(in: fixture.view))
        fixture.webView = webView
        webView.loadHTMLString("<html><body id='provider-ready'>Ready</body></html>",
            baseURL: URL(string: "https://example.com/provider-test")!)
        try await waitForMountedJavaScript("document.body.id === 'provider-ready'", in: webView)
        try await waitForProviderPublication(session, in: webView)
        return fixture
    }

    private func waitForProviderPublication(_ session: ReaderProviderMountedSession, in webView: WKWebView) async throws {
        // Selected WebView updates coordinator.messageHandlers before applying
        // this native property, including when the handler keys are unchanged.
        try await waitForMountedCondition {
            webView.allowsBackForwardNavigationGestures == session.publicationToggle
        }
    }

    private func sendProviderMessage(
        _ name: String, id: String, in webView: WKWebView, session: ReaderProviderMountedSession
    ) async throws {
        _ = try await webView.callAsyncJavaScript(
            "window.webkit.messageHandlers[name].postMessage(id)",
            arguments: ["name": name, "id": id], in: nil, contentWorld: .page
        )
        try await waitForMountedCondition { session.delivered.contains(id) }
    }

    private func sendVisibilityMessage(
        id: String, hidden: Bool, in webView: WKWebView, session: ReaderProviderMountedSession
    ) async throws {
        _ = try await webView.callAsyncJavaScript(
            "window.webkit.messageHandlers.ebookNavigationVisibility.postMessage({testID: id, hideNavigationDueToScroll: hidden, source: 'page-turn.fixture', direction: hidden ? 'forward' : 'backward'})",
            arguments: ["id": id, "hidden": hidden], in: nil, contentWorld: .page
        )
        try await waitForMountedCondition { session.delivered.contains(id) }
    }

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

private actor ReaderProviderCallbackGate {
    private var released = false
    private var waiters = [CheckedContinuation<Void, Never>]()

    func wait() async {
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
private final class ReaderProviderFixtureViewModel: ReaderViewModel {
    private let released: XCTestExpectation

    init(configuration: Realm.Configuration, released: XCTestExpectation) {
        self.released = released
        super.init(realmConfiguration: configuration, systemScripts: [])
    }

    deinit { released.fulfill() }
}

@MainActor
private final class ReaderProviderMountedSession: ObservableObject {
    @Published var inherited = WebViewMessageHandlers()
    @Published var publicationToggle = false
    @Published var hidden = false
    let store = WKWebsiteDataStore.nonPersistent()
    let navigator = WebViewNavigator()
    let content = ReaderContent()
    let mode = ReaderModeViewModel()
    let media = ReaderMediaPlayerViewModel()
    let files = ReaderFileManager()
    let readerReleased = XCTestExpectation(description: "Provider fixture's real reader model released")
    var reader: ReaderViewModel?
    var events = [String]()
    var delivered = Set<String>()
    var entered = Set<String>()
    var finished = Set<String>()
    var cancellations = [String]()
    var gates = [ReaderProviderCallbackGate]()
    private let configuration: Realm.Configuration
    private let previousLibraryConfiguration: Realm.Configuration
    private let previousContentResolver: ReaderContent.ContentResolver?
    private var libraryRealm: Realm?

    init() throws {
        previousLibraryConfiguration = LibraryDataManager.realmConfiguration
        previousContentResolver = ReaderContent.contentResolver
        var configuration = LakeOfFireContent.DefaultRealmConfiguration.configuration
        configuration.fileURL = nil
        configuration.inMemoryIdentifier = "reader-provider-\(UUID().uuidString)"
        self.configuration = configuration
        BigSyncMutationTracking.install(
            configurations: [configuration],
            excludedClassNames: (configuration.objectTypes ?? []).map { $0.className() }
        )
        let realm = try Realm(configuration: configuration)
        try realm.write { realm.add(LibraryConfiguration()) }
        libraryRealm = realm
        LibraryDataManager.realmConfiguration = configuration
        reader = ReaderProviderFixtureViewModel(configuration: configuration, released: readerReleased)
        // These tests exercise message-table transport. Native navigation must
        // not resolve or create content in the application's configured stores.
        ReaderContent.contentResolver = { _, _, _ in nil }
    }

    static func messageID(_ message: WebViewMessage) -> String {
        (message.body as? String) ?? ((message.body as? [String: Any])?["testID"] as? String) ?? ""
    }

    func provider(named name: String, label: String) -> WebViewMessageHandlers {
        WebViewMessageHandlers([
            (name, { @MainActor [weak self] message in
                self?.events.append(label + ":" + Self.messageID(message))
            }),
            ("ebookNavigationVisibility", { @MainActor [weak self] message in
                guard let self else { return }
                events.append(label + ":" + Self.messageID(message) + ":" + String(hidden))
            }),
        ])
    }

    func blockingProvider(gate: ReaderProviderCallbackGate) -> WebViewMessageHandlers {
        WebViewMessageHandlers([
            ("readerProviderBlocked", { @MainActor [weak self] message in
                guard let self else { return }
                let id = Self.messageID(message)
                entered.insert(id)
                await gate.wait()
                finished.insert(id)
            }),
        ])
    }

    func publish(_ handlers: WebViewMessageHandlers) {
        inherited = handlers
        publicationToggle.toggle()
    }

    func observingDelivery(of handlers: WebViewMessageHandlers) -> WebViewMessageHandlers {
        // A downstream observer marks completion after every callback in the
        // real composed table. It keeps exactly that table's registered names.
        let observers: [(String, @Sendable (WebViewMessage) async -> Void)] = handlers.handlers.keys.map { name in
            (name, { @MainActor [weak self] message in
                let id = Self.messageID(message)
                if !id.isEmpty { self?.delivered.insert(id) }
            })
        }
        return handlers + WebViewMessageHandlers(observers)
    }

    func finishCleanup() async {
        ReaderContent.contentResolver = previousContentResolver
        LibraryDataManager.realmConfiguration = previousLibraryConfiguration
        libraryRealm?.invalidate()
        libraryRealm = nil
        if let identifier = configuration.inMemoryIdentifier {
            await releaseReaderProviderFixtureRealms(owner: .shared, identifier: identifier)
        }
    }
}

private func releaseReaderProviderFixtureRealms(owner: isolated RealmBackgroundActor, identifier: String) {
    let cached = owner.cachedRealms.filter { $0.value.configuration.inMemoryIdentifier == identifier }
    guard cached.values.allSatisfy({ !$0.isInWriteTransaction }) else {
        XCTFail("Provider fixture observers must settle before cache cleanup")
        return
    }
    for key in cached.keys { owner.cachedRealms.removeValue(forKey: key)?.invalidate() }
}

@MainActor
private final class ReaderProviderMountedFixture {
    let session: ReaderProviderMountedSession
    weak var webView: WKWebView?
    #if os(iOS)
    private let controller: UIHostingController<AnyView>
    private let window: UIWindow
    #else
    private let controller: NSHostingController<AnyView>
    private let window: NSWindow
    #endif

    var view: ReaderMountedPlatformView { controller.view }

    init(session: ReaderProviderMountedSession) {
        self.session = session
        let root = AnyView(ReaderProviderMountedView(session: session))
        #if os(iOS)
        controller = UIHostingController(rootView: root)
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        window.rootViewController = controller
        window.isHidden = false
        #else
        controller = NSHostingController(rootView: root)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        #endif
    }

    func unmount() {
        webView?.stopLoading()
        controller.rootView = AnyView(EmptyView())
        #if os(iOS)
        window.isHidden = true
        window.rootViewController = nil
        #else
        window.close()
        window.contentViewController = nil
        #endif
        session.reader = nil
    }
}

private struct ReaderProviderMountedView: View {
    @ObservedObject var session: ReaderProviderMountedSession

    var body: some View {
        if let reader = session.reader {
            let publicationToggle = session.publicationToggle
            ReaderWebView(obscuredInsets: nil)
                .readerWebViewDataStore(session.store)
                .modifier(ReaderMessageHandlersViewModifier(hideNavigationDueToScroll: $session.hidden))
                .environment(\.webViewMessageHandlers, session.inherited)
                .environment(\.readerWebViewMessageHandlersTransform, { handlers, _ in
                    session.observingDelivery(of: handlers)
                })
                .environment(\.readerWebViewConfigurationTransform, { config in
                    WebViewConfig(
                        javaScriptEnabled: config.javaScriptEnabled,
                        contentRules: config.contentRules,
                        allowsBackForwardNavigationGestures: publicationToggle,
                        allowsInlineMediaPlayback: config.allowsInlineMediaPlayback,
                        mediaTypesRequiringUserActionForPlayback: config.mediaTypesRequiringUserActionForPlayback,
                        dataDetectorsEnabled: config.dataDetectorsEnabled,
                        isScrollEnabled: config.isScrollEnabled,
                        pageZoom: config.pageZoom,
                        isOpaque: config.isOpaque,
                        backgroundColor: config.backgroundColor,
                        usesSampledPageTopColorForUnderPageBackground: config.usesSampledPageTopColorForUnderPageBackground,
                        usesConfiguredBackgroundForReaderDocuments: config.usesConfiguredBackgroundForReaderDocuments,
                        adjustsScrollViewContentInsetsForSafeArea: config.adjustsScrollViewContentInsetsForSafeArea,
                        hidesTopScrollEdgeEffect: config.hidesTopScrollEdgeEffect,
                        nativeLookupHitTestingEnabled: config.nativeLookupHitTestingEnabled,
                        userScripts: config.userScripts,
                        darkModeSetting: config.darkModeSetting,
                        paginationConfiguration: config.paginationConfiguration
                    )
                })
                .environment(\.webViewNavigator, session.navigator)
                .environmentObject(session.content)
                .environmentObject(reader)
                .environmentObject(reader.scriptCaller)
                .environmentObject(session.mode)
                .environmentObject(session.media)
                .environmentObject(session.files)
        }
    }
}
