import XCTest
import SwiftSoup
@preconcurrency import WebKit
#if os(iOS)
import UIKit
#endif
import SwiftUI
import Combine
import RealmSwift
@testable import SwiftUIWebView
@testable import LakeOfFireContent
@testable import LakeOfFireReader

private actor ReaderCallbackGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !isOpen else { return }
        isOpen = true
        let waiters = waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private enum ReaderCallbackTestError: Error {
    case commitFailed
}

@MainActor
private final class ReaderCallbackViewModel: ReaderViewModel {
    var beforeCommitReturns: (() async throws -> Void)?
    var committedCount = 0
    var finishedContents: [ObjectIdentifier] = []

    override func onNavigationCommitted(content: any ReaderContentProtocol, newState: WebViewState) async throws {
        committedCount += 1
        try await beforeCommitReturns?()
    }

    override func onNavigationFinished(content: any ReaderContentProtocol, newState: WebViewState,
                                      documentIsCurrent: @escaping @MainActor () -> Bool = { true },
                                      completion: ((WebViewState) -> Void)? = nil) {
        finishedContents.append(ObjectIdentifier(content))
        completion?(newState)
    }
}

@MainActor
private final class ReaderCallbackMediaViewModel: ReaderMediaPlayerViewModel {
    var committedContents: [ObjectIdentifier] = []

    override func onNavigationCommitted(content: any ReaderContentProtocol, newState: WebViewState) async throws {
        committedContents.append(ObjectIdentifier(content))
    }
}

@MainActor
private final class ReaderSettingsDispatchProbe {
    var settingsCount = 0
    var titles: [String] = []
}

@MainActor
private func makeReaderCallbackLibraryConfiguration() -> Realm.Configuration {
    var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
    configuration.objectTypes = [LibraryConfiguration.self, FeedCategory.self, UserScript.self]
    configureLakeOfFireMutationTrackingForTesting(&configuration)
    return configuration
}

@MainActor
private func makeReaderWebViewHandlerFixture() -> (
    handler: ReaderWebViewHandler,
    taskManager: NavigationTaskManager,
    readerContent: ReaderContent,
    readerModeViewModel: ReaderModeViewModel
) {
    let taskManager = NavigationTaskManager()
    let readerContent = ReaderContent()
    let readerModeViewModel = ReaderModeViewModel()
    let handler = ReaderWebViewHandler(
        navigationTaskManager: taskManager,
        readerContent: readerContent,
        readerViewModel: ReaderViewModel(realmConfiguration: makeReaderCallbackLibraryConfiguration(), systemScripts: []),
        readerModeViewModel: readerModeViewModel,
        readerMediaPlayerViewModel: ReaderMediaPlayerViewModel(),
        scriptCaller: WebViewScriptCaller(),
        navigator: WebViewNavigator()
    )
    return (handler, taskManager, readerContent, readerModeViewModel)
}


@MainActor
private final class ReaderGeneratedReadinessFixture: NSObject, WKURLSchemeHandler, WKNavigationDelegate, WKScriptMessageHandler {
    let html: Data
    let loaded: XCTestExpectation
    let pending: XCTestExpectation
    let ready: XCTestExpectation
    let receive: @Sendable (WebViewMessage) async -> Void
    let nativeIsReady: @MainActor () -> Bool
    private var reportedPending = false
    private var reportedReady = false
    private var messageTasks: [Task<Void, Never>] = []

    init(
        html: Data,
        loaded: XCTestExpectation,
        pending: XCTestExpectation,
        ready: XCTestExpectation,
        receive: @escaping @Sendable (WebViewMessage) async -> Void,
        nativeIsReady: @escaping @MainActor () -> Bool
    ) {
        self.html = html
        self.loaded = loaded
        self.pending = pending
        self.ready = ready
        self.receive = receive
        self.nativeIsReady = nativeIsReady
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let url = urlSchemeTask.request.url!
        // Exercise the real local-scheme injection with a deterministic system
        // font stylesheet. No bundled font file or network access is needed.
        let isStylesheet = url.path == "/manabi-fonts.css"
        let payload = isStylesheet ? Data("html { font-family: serif; }".utf8) : html
        urlSchemeTask.didReceive(URLResponse(
            url: url, mimeType: isStylesheet ? "text/css" : "text/html",
            expectedContentLength: payload.count, textEncodingName: "utf-8"
        ))
        urlSchemeTask.didReceive(payload)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded.fulfill()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let receipt = WebViewMessage(
            frameInfo: message.frameInfo, uuid: UUID(), name: message.name, body: body
        )
        messageTasks.append(Task { @MainActor in
            await receive(receipt)
            if body["hasRenderReadyMarker"] as? Bool == true,
               body["fontPending"] as? Bool == true,
               !reportedPending {
                reportedPending = true
                pending.fulfill()
            }
            if body["hasReaderRenderReady"] as? Bool == true,
               nativeIsReady(), !reportedReady {
                reportedReady = true
                ready.fulfill()
            }
        })
    }

    func drainMessages() async {
        while !messageTasks.isEmpty {
            let tasks = messageTasks
            messageTasks.removeAll()
            for task in tasks { await task.value }
        }
    }

    func stop() {
        messageTasks.forEach { $0.cancel() }
        messageTasks.removeAll()
    }
}

@MainActor
final class ReaderWebViewCallbackContractTests: XCTestCase {

    func testGeneratedReadableDocumentFontSettlementPublishesNativeReadiness() async throws {
        let fixture = makeReaderWebViewHandlerFixture()
        let mode = fixture.readerModeViewModel
        let reader = fixture.readerContent
        let navigator = fixture.handler.navigator
        let url = URL(string: "internal://local/snippet?key=generated-font-readiness")!
        let (realm, row) = try cachedHistoryRecord(url: url)
        let readableHTML = "<html><body><div id='reader-content'><p>Readable fallback source 日本語.</p></div></body></html>"
        try realm.write {
            row.title = "Readable fallback"
            row.html = readableHTML
            row.rssContainsFullContent = true
            row.isReaderModeByDefault = true
            row.isReaderModeAvailable = false
            row.isReaderModeOfferHidden = false
        }
        reader.pageURL = url
        reader.content = row
        reader.isRenderingReaderHTML = true
        mode.navigator = navigator
        mode.readerLocalHTMLLoader = { _ in readableHTML }
        mode.readerPublicationDateLoader = { _ in nil }
        var generatedHTML: Data?
        mode.processHTMLBytes = { bytes, _ in
            await MainActor.run { generatedHTML = Data(bytes) }
            return bytes
        }
        defer {
            mode.readerLocalHTMLLoader = nil
            mode.readerPublicationDateLoader = nil
            mode.processHTMLBytes = nil
            withExtendedLifetime(realm) {}
        }

        mode.showReaderView(readerContent: reader, scriptCaller: fixture.handler.scriptCaller)
        await mode.waitForReaderModeRender(for: url)
        let html = try XCTUnwrap(generatedHTML, "The actual renderer must dispatch readable source")
        let parsed = try SwiftSoup.parse(String(decoding: html, as: UTF8.self))
        XCTAssertEqual(try parsed.getElementById("reader-content")?.text(), "Readable fallback source 日本語.")
        XCTAssertTrue(try parsed.select("[data-mnb-native-sidecar-content-fingerprint]").isEmpty)
        XCTAssertEqual(try parsed.select("html").first()?.attr("data-mnb-reader-render-ready"), "1")
        XCTAssertEqual(try parsed.select("html").first()?.attr("data-mnb-font-pending"), "1")
        XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL, url.absoluteString)

        var state = WebViewState.empty
        state.pageURL = url
        fixture.handler.readerViewModel.state = state
        let loaded = expectation(description: "generated reader document loads")
        let pending = expectation(description: "generated reader remains font pending")
        let ready = expectation(description: "actual doc-state receiver accepts current readiness")
        let receive = try XCTUnwrap(fixture.handler.webViewMessageHandlers.handlers["readerDocState"])
        let nativeFixture = ReaderGeneratedReadinessFixture(
            html: html, loaded: loaded, pending: pending, ready: ready,
            receive: receive,
            nativeIsReady: { fixture.handler.readerViewModel.state.hasReaderRenderReady }
        )
        let controller = WKUserContentController()
        controller.add(nativeFixture, name: "readerDocState")
        let script = ReaderDocStateUserScript().userScript
        controller.addUserScript(script.webKitUserScript)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(nativeFixture, forURLScheme: "internal")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 430, height: 932), configuration: configuration)
        webView.navigationDelegate = nativeFixture
#if os(iOS)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive },
            "This native WebKit control requires the app-hosted test plan")
        weak var previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        host.view.frame = webView.frame
        host.view.addSubview(webView)
        window.rootViewController = host
        window.frame = webView.frame
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
#endif
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
            controller.removeScriptMessageHandler(forName: "readerDocState")
            nativeFixture.stop()
#if os(iOS)
            webView.removeFromSuperview()
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
#endif
        }
        webView.load(URLRequest(url: url))
        await fulfillment(of: [loaded, pending], timeout: 10)
        await nativeFixture.drainMessages()
        XCTAssertFalse(fixture.handler.readerViewModel.state.hasReaderRenderReady)
        XCTAssertTrue(mode.isReaderModeLoadPending(for: url))
        let bindingOwner = UUID()
        fixture.handler.scriptCaller.installBinding(
            ownedBy: bindingOwner,
            asyncCaller: { source, arguments, frame, world in
                let result = try await webView.callAsyncJavaScript(
                    source,
                    arguments: arguments?.mapValues { $0 as Any } ?? [:],
                    in: frame,
                    contentWorld: world ?? .page
                )
                return .init(result)
            },
            unsafeCaller: nil,
            snapshotCapture: nil,
            coordinateOriginInWindow: { nil }
        )
        defer { _ = fixture.handler.scriptCaller.clearBinding(ownedBy: bindingOwner) }
        // Run the real injector. Its asynchronous font completion clears the
        // gate; the production mutation observer and receiver settle native state.
        await mode.injectSharedFontIfNeeded(
            scriptCaller: fixture.handler.scriptCaller, pageURL: url
        )
        await fulfillment(of: [ready], timeout: 5)
        await nativeFixture.drainMessages()
        XCTAssertTrue(fixture.handler.readerViewModel.state.hasReaderRenderReady)
        XCTAssertFalse(mode.isReaderModeLoadPending(for: url))
        XCTAssertFalse(mode.isReaderModeLoading)
        XCTAssertFalse(reader.isRenderingReaderHTML)
        let injectionMode = try await webView.evaluateJavaScript("globalThis.manabiReaderFontInjectionMode")
        XCTAssertEqual(injectionMode as? String, "local-scheme")
        let pendingAttribute = try await webView.evaluateJavaScript("document.documentElement.hasAttribute('data-mnb-font-pending')")
        XCTAssertEqual(pendingAttribute as? Bool, false)
        withExtendedLifetime((fixture, nativeFixture, webView)) {}
    }

    private func cachedHistoryRecord(url: URL) throws -> (Realm, HistoryRecord) {
        let realm = try Realm(configuration: .init(
            inMemoryIdentifier: UUID().uuidString, objectTypes: [HistoryRecord.self]
        ), queue: nil)
        let record = HistoryRecord()
        record.compoundKey = UUID().uuidString
        record.url = url
        try realm.write { realm.add(record) }
        return (realm, record)
    }

    func testCommitRejectsCachedRowInvalidatedDuringLoadPublication() async throws {
        let fixture = makeReaderWebViewHandlerFixture()
        let reader = ReaderCallbackViewModel(realmConfiguration: makeReaderCallbackLibraryConfiguration(), systemScripts: [])
        let media = ReaderCallbackMediaViewModel(readAloudController: ReaderReadAloudController())
        fixture.handler.readerViewModel = reader
        fixture.handler.readerMediaPlayerViewModel = media
        let url = URL(string: "https://example.invalid/invalidated-publication")!
        let (realm, record) = try cachedHistoryRecord(url: url)
        fixture.readerContent.pageURL = url
        fixture.readerContent.preloadResolvedContent(record, for: url)
        fixture.readerContent.isRenderingReaderHTML = true
        fixture.readerModeViewModel.beginReaderModeLoad(for: url)
        fixture.readerModeViewModel.expectSyntheticReaderLoaderCommit(for: url)
        let publication = fixture.readerContent.$content.sink { content in
            guard content === record, !record.isInvalidated else { return }
            do { try realm.write { realm.delete(record) } }
            catch { XCTFail("Could not invalidate the published row: \(error)") }
        }
        defer { publication.cancel() }
        var state = WebViewState.empty
        state.pageURL = url

        try await fixture.handler.handleNavigationCommitted(state: state)

        XCTAssertTrue(record.isInvalidated)
        XCTAssertEqual(reader.committedCount, 0)
        XCTAssertTrue(media.committedContents.isEmpty)
        XCTAssertFalse(fixture.readerContent.isRenderingReaderHTML)
        XCTAssertFalse(fixture.readerModeViewModel.isReaderModeLoading)
    }

    func testCommitRevalidatesCachedSelectionAfterReaderCallback() async throws {
        for change in ["invalidated", "removed", "replacement", "lateFailureReplacement", "binding", "cancelled", "live"] {
            let fixture = makeReaderWebViewHandlerFixture()
            let reader = ReaderCallbackViewModel(realmConfiguration: makeReaderCallbackLibraryConfiguration(), systemScripts: [])
            let media = ReaderCallbackMediaViewModel(readAloudController: ReaderReadAloudController())
            fixture.handler.readerViewModel = reader
            fixture.handler.readerMediaPlayerViewModel = media
            let url = URL(string: "https://example.invalid/suspended-commit")!
            let (realm, record) = try cachedHistoryRecord(url: url)
            fixture.readerContent.content = record
            fixture.readerContent.pageURL = url
            fixture.readerContent.isRenderingReaderHTML = true
            fixture.readerModeViewModel.beginReaderModeLoad(for: url)
            fixture.readerModeViewModel.expectSyntheticReaderLoaderCommit(for: url)
            fixture.readerModeViewModel.sharedFontCSSBase64Provider = { nil }
            let html = "<main>Current reader</main>"
            fixture.readerModeViewModel.readabilityContent = html
            let entered = expectation(description: "Reader commit suspended: \(change)")
            let gate = ReaderCallbackGate()
            reader.beforeCommitReturns = {
                entered.fulfill()
                await gate.wait()
                if change == "lateFailureReplacement" { throw ReaderCallbackTestError.commitFailed }
            }
            var state = WebViewState.empty
            state.pageURL = url
            let callback = Task { @MainActor in
                try await fixture.handler.handleNavigationCommitted(state: state)
            }
            await fulfillment(of: [entered], timeout: 5)
            if change == "invalidated" {
                try realm.write { realm.delete(record) }
            } else if change == "removed" {
                fixture.readerContent.content = nil
            } else if ["replacement", "lateFailureReplacement"].contains(change) {
                // Equal URL and primary key do not transfer physical selection ownership.
                let replacement = HistoryRecord()
                replacement.url = url
                replacement.compoundKey = record.compoundKey
                fixture.readerContent.content = replacement
            } else if change == "binding" {
                fixture.handler.scriptCaller.installBinding(
                    ownedBy: UUID(), asyncCaller: { _, _, _, _ in .init(nil) },
                    unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil }
                )
            } else if change == "cancelled" {
                callback.cancel()
            }
            await gate.release()
            do {
                try await callback.value
                XCTAssertEqual(change, "live")
            } catch is CancellationError {
                XCTAssertNotEqual(change, "live")
            }

            XCTAssertEqual(media.committedContents, change == "live" ? [ObjectIdentifier(record)] : [], change)
            let missingCurrentContent = ["invalidated", "removed"].contains(change)
            XCTAssertEqual(fixture.readerContent.isRenderingReaderHTML, !missingCurrentContent, change)
            XCTAssertEqual(fixture.readerModeViewModel.isReaderModeLoading, !missingCurrentContent, change)
            XCTAssertEqual(fixture.readerModeViewModel.readabilityContent, missingCurrentContent ? nil : html, change)
        }
    }

    func testFinishRevalidatesCachedRowAfterModeCallback() async throws {
        for change in ["invalidated", "replacement", "binding", "cancelled", "live"] {
            let fixture = makeReaderWebViewHandlerFixture()
            let reader = ReaderCallbackViewModel(realmConfiguration: makeReaderCallbackLibraryConfiguration(), systemScripts: [])
            fixture.handler.readerViewModel = reader
            let url = URL(string: "https://example.invalid/suspended-finish")!
            let (realm, record) = try cachedHistoryRecord(url: url)
            fixture.readerContent.content = record
            fixture.readerContent.pageURL = url
            fixture.readerContent.isRenderingReaderHTML = true
            fixture.readerModeViewModel.beginReaderModeLoad(for: url)
            let html = "<main>Pending reader</main>"
            fixture.readerModeViewModel.readabilityContent = html
            let entered = expectation(description: "Mode finish suspended: \(change)")
            let gate = ReaderCallbackGate()
            fixture.readerModeViewModel.sharedFontCSSBase64Provider = {
                entered.fulfill()
                await gate.wait()
                return nil
            }
            var state = WebViewState.empty
            state.pageURL = url
            let callback = Task { @MainActor in
                await fixture.handler.handleNavigationFinished(state: state)
            }
            await fulfillment(of: [entered], timeout: 5)
            if change == "invalidated" {
                try realm.write { realm.delete(record) }
            } else if change == "replacement" {
                let replacement = HistoryRecord()
                replacement.url = url
                replacement.compoundKey = record.compoundKey
                fixture.readerContent.content = replacement
            } else if change == "binding" {
                fixture.handler.scriptCaller.installBinding(
                    ownedBy: UUID(), asyncCaller: { _, _, _, _ in .init(nil) },
                    unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil }
                )
            } else if change == "cancelled" {
                callback.cancel()
            }
            await gate.release()
            await callback.value

            XCTAssertEqual(reader.finishedContents, change == "live" ? [ObjectIdentifier(record)] : [], change)
            XCTAssertTrue(fixture.readerContent.isRenderingReaderHTML, change)
            XCTAssertEqual(fixture.readerModeViewModel.isReaderModeLoading,
                           !["invalidated", "live"].contains(change), change)
            XCTAssertEqual(fixture.readerModeViewModel.readabilityContent, html, change)
        }
    }

    func testProductionFinishSettingsRevalidateAfterSuspendedJavaScript() async throws {
        for change in ["invalidated", "replacement", "binding", "page", "live"] {
            let url = URL(string: "https://example.invalid/production-finish-settings")!
            let (realm, record) = try cachedHistoryRecord(url: url)
            try realm.write {
                record.title = "Original reader title"
                record.rssContainsFullContent = true
            }
            let content = ReaderContent()
            content.content = record
            content.pageURL = url
            var model: ReaderViewModel? = ReaderViewModel(realmConfiguration: makeReaderCallbackLibraryConfiguration(), systemScripts: [])
            weak var pendingModel = model
            var state = WebViewState.empty
            state.pageURL = url
            model?.state = state
            let caller = try XCTUnwrap(model?.scriptCaller)
            let dispatches = ReaderSettingsDispatchProbe()
            let entered = expectation(description: "Production settings suspended: \(change)")
            let gate = ReaderCallbackGate()
            caller.installBinding(
                ownedBy: UUID(),
                asyncCaller: { _, arguments, _, _ in
                    if let title = arguments?["title"] as? String {
                        dispatches.titles.append(title)
                    } else {
                        dispatches.settingsCount += 1
                        entered.fulfill()
                        await gate.wait()
                    }
                    return .init(nil)
                },
                unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil }
            )
            let selectionIsCurrent = content.makeSelectionCommitFence(requiring: content.currentSelectionID)
            model?.onNavigationFinished(content: record, newState: state, documentIsCurrent: {
                selectionIsCurrent() && content.content === record && content.pageURL.matchesReaderURL(url)
            })
            await fulfillment(of: [entered], timeout: 5)
            if change == "invalidated" {
                try realm.write { realm.delete(record) }
            } else if change == "replacement" {
                let replacement = HistoryRecord()
                replacement.url = url
                replacement.compoundKey = record.compoundKey
                content.content = replacement
            } else if change == "binding" {
                caller.installBinding(
                    ownedBy: UUID(),
                    asyncCaller: { _, _, _, _ in
                        XCTFail("Retired settings must not send title work to a replacement binding")
                        return .init(nil)
                    },
                    unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil }
                )
            } else if change == "page" {
                var successorState = state
                successorState.pageURL = URL(string: "https://example.invalid/successor")!
                model?.state = successorState
            }
            // The production settings task retains its model while suspended.
            // Releasing the external owner lets deallocation prove that the
            // actual unstructured task has completed before assertions.
            model = nil
            XCTAssertNotNil(pendingModel)
            await gate.release()
            let deadline = Date().addingTimeInterval(5)
            while pendingModel != nil, Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertNil(pendingModel, "Production settings task did not finish: \(change)")
            XCTAssertEqual(dispatches.settingsCount, 1, change)
            XCTAssertEqual(dispatches.titles, change == "live" ? ["Original reader title"] : [], change)
        }
    }

    func testProductionSettingsSchedulingCannotAdoptRetiredDocument() async throws {
        for entryPoint in ["finish", "settings"] {
            for change in ["invalidated", "binding", "page"] {
                let url = URL(string: "https://example.invalid/queued-settings")!
                let (realm, record) = try cachedHistoryRecord(url: url)
                let model = ReaderViewModel(realmConfiguration: makeReaderCallbackLibraryConfiguration(), systemScripts: [])
                var state = WebViewState.empty
                state.pageURL = url
                model.state = state
                let unexpected = expectation(description: "Retired \(entryPoint) must stay inert: \(change)")
                unexpected.isInverted = true
                let caller = model.scriptCaller
                caller.installBinding(
                    ownedBy: UUID(), asyncCaller: { _, _, _, _ in
                        unexpected.fulfill()
                        return .init(nil)
                    },
                    unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil }
                )
                if entryPoint == "finish" {
                    model.onNavigationFinished(content: record, newState: state, completion: { _ in
                        unexpected.fulfill()
                    })
                } else {
                    model.refreshSettingsInWebView(content: record, newState: state)
                }
                // Still on the same MainActor turn: both production tasks are
                // queued, so this retires their captured owner before admission.
                if change == "invalidated" {
                    try realm.write { realm.delete(record) }
                } else if change == "binding" {
                    caller.installBinding(
                        ownedBy: UUID(), asyncCaller: { _, _, _, _ in
                            unexpected.fulfill()
                            return .init(nil)
                        },
                        unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil }
                    )
                } else {
                    var successorState = state
                    successorState.pageURL = URL(string: "https://example.invalid/successor")!
                    model.state = successorState
                }
                await fulfillment(of: [unexpected], timeout: 0.05)
            }
        }
    }

    func testCancelledCommitCannotReleaseNewerReaderRender() async {
        let fixture = makeReaderWebViewHandlerFixture()
        fixture.readerContent.isRenderingReaderHTML = true
        let task = Task { @MainActor in
            try await fixture.handler.handleNavigationCommitted(state: .empty)
        }

        task.cancel()

        do {
            try await task.value
            XCTFail("A canceled commit must stop before mutating reader state")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertTrue(
            fixture.readerContent.isRenderingReaderHTML,
            "An obsolete commit must not release the current render overlay"
        )
    }

    func testTerminalNavigationFailureReleasesOwnedReaderRender() async throws {
        let fixture = makeReaderWebViewHandlerFixture()
        let url = URL(string: "https://example.com/failed")!
        fixture.readerContent.pageURL = url
        fixture.readerContent.isRenderingReaderHTML = true
        fixture.readerModeViewModel.beginReaderModeLoad(for: url)
        var state = WebViewState.empty
        state.pageURL = url

        fixture.handler.onNavigationFailed(
            state: state,
            disposition: .terminal
        )
        try await fixture.taskManager.onNavigationFailedTask?.value

        XCTAssertFalse(fixture.readerContent.isRenderingReaderHTML)
        XCTAssertFalse(fixture.readerModeViewModel.isReaderModeLoading)
        XCTAssertFalse(fixture.readerModeViewModel.isReaderModeLoadPending(for: url))
    }

    func testProvisionalNavigationFailurePreservesCommittedReaderRender()
    async throws {
        let fixture = makeReaderWebViewHandlerFixture()
        let url = URL(string: "https://example.com/committed")!
        fixture.readerContent.pageURL = url
        fixture.readerContent.isRenderingReaderHTML = true
        fixture.readerModeViewModel.beginReaderModeLoad(for: url)
        var state = WebViewState.empty
        state.pageURL = url

        fixture.handler.onNavigationFailed(
            state: state,
            disposition: .preservedCommittedDocument
        )
        try await fixture.taskManager.onNavigationFailedTask?.value

        XCTAssertTrue(fixture.readerContent.isRenderingReaderHTML)
        XCTAssertTrue(fixture.readerModeViewModel.isReaderModeLoading)
        XCTAssertTrue(fixture.readerModeViewModel.isReaderModeLoadPending(for: url))
    }

    func testWebContentProcessTerminationReleasesOwnedReaderRender() {
        let fixture = makeReaderWebViewHandlerFixture()
        let url = URL(string: "https://example.com/terminated")!
        fixture.readerContent.pageURL = url
        fixture.readerContent.isRenderingReaderHTML = true
        fixture.readerModeViewModel.beginReaderModeLoad(for: url)
        var state = WebViewState.empty
        state.pageURL = url

        fixture.handler.onDocumentContextInvalidated(
            state: state,
            reason: .webContentProcessTerminated
        )

        XCTAssertFalse(fixture.readerContent.isRenderingReaderHTML)
        XCTAssertFalse(fixture.readerModeViewModel.isReaderModeLoading)
        XCTAssertFalse(fixture.readerModeViewModel.isReaderModeLoadPending(for: url))
    }

    func testIPadReaderModeDoesNotUseSplitViewLeadingSafeAreaAsWebKitInset() {
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

    func testIPadEBookDoesNotUseSplitViewLeadingSafeAreaAsWebKitInset() {
        let resolved = ReaderWebViewObscuredInsetResolver.resolve(
            obscuredInsets: EdgeInsets(top: 0, leading: 450, bottom: 0, trailing: 0),
            additionalInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
            usesEBookChromeInsets: true,
            preservesLeadingSafeAreaInset: false
        )

        XCTAssertEqual(resolved.leading, 0)
    }

    func testCommitFailureSuppressesFinishAndPendingURLChange() async {
        let manager = NavigationTaskManager()
        var finishCount = 0
        var urlCount = 0

        manager.startOnNavigationCommitted {
            throw ReaderCallbackTestError.commitFailed
        }
        manager.startOnURLChanged {
            urlCount += 1
        }
        manager.startOnNavigationFinished {
            finishCount += 1
        }

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

    func testFinishWaitsForCommitAndRunsExactlyOnce() async throws {
        let manager = NavigationTaskManager()
        let commitGate = ReaderCallbackGate()
        var finishCount = 0

        manager.startOnNavigationCommitted {
            await commitGate.wait()
        }
        manager.startOnNavigationFinished {
            finishCount += 1
        }
        manager.startOnNavigationFinished {
            finishCount += 100
        }

        await Task.yield()
        XCTAssertEqual(finishCount, 0)
        await commitGate.release()
        try await manager.onNavigationFinishedTask?.value
        XCTAssertEqual(finishCount, 1)

        manager.startOnNavigationFinished {
            finishCount += 1000
        }
        await Task.yield()
        XCTAssertEqual(finishCount, 1)
    }

    func testURLChangeBeforeDidFinishQueuesBehindDocumentFinish() async throws {
        let manager = NavigationTaskManager()
        var order: [String] = []

        manager.startOnNavigationCommitted {
            order.append("commit")
        }
        try await manager.onNavigationCommittedTask?.value
        manager.startOnURLChanged {
            order.append("url")
        }

        await Task.yield()
        XCTAssertEqual(order, ["commit"])
        XCTAssertNil(manager.onURLChangedTask)

        manager.startOnNavigationFinished {
            order.append("finish")
        }
        try await manager.onNavigationFinishedTask?.value
        try await manager.onURLChangedTask?.value
        XCTAssertEqual(order, ["commit", "finish", "url"])
    }

    func testURLChangeDuringSemanticFinishKeepsOnlyLatestMutation() async throws {
        let manager = NavigationTaskManager()
        let finishGate = ReaderCallbackGate()
        let finishStarted = expectation(description: "semantic finish started")
        var order: [String] = []

        manager.startOnNavigationCommitted {
            order.append("commit")
        }
        try await manager.onNavigationCommittedTask?.value
        manager.startOnNavigationFinished {
            order.append("finish-start")
            finishStarted.fulfill()
            await finishGate.wait()
            order.append("finish-end")
        }

        await fulfillment(of: [finishStarted], timeout: 1)
        manager.startOnURLChanged {
            order.append("stale-url")
        }
        manager.startOnURLChanged {
            order.append("latest-url")
        }
        await Task.yield()
        XCTAssertEqual(order, ["commit", "finish-start"])

        await finishGate.release()
        try await manager.onNavigationFinishedTask?.value
        try await manager.onURLChangedTask?.value
        XCTAssertEqual(
            order,
            ["commit", "finish-start", "finish-end", "latest-url"]
        )
    }

    func testURLChangeBeforeFirstCommitIsIgnored() async {
        let manager = NavigationTaskManager()
        var urlCount = 0

        manager.startOnURLChanged {
            urlCount += 1
        }
        await Task.yield()

        XCTAssertEqual(urlCount, 0)
        XCTAssertNil(manager.onURLChangedTask)
    }

    func testSettledDocumentURLChangeRunsWithoutAnotherDidFinish() async throws {
        let manager = NavigationTaskManager()
        var order: [String] = []

        manager.startOnNavigationCommitted {
            order.append("commit")
        }
        manager.startOnNavigationFinished {
            order.append("finish")
        }
        try await manager.onNavigationFinishedTask?.value

        manager.startOnURLChanged {
            order.append("url")
        }
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
                try await Task.sleep(nanoseconds: 30_000_000_000)
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
        await fulfillment(
            of: [firstCommitCancelled, replacementCommitCalled],
            timeout: 1
        )
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
                try await Task.sleep(nanoseconds: 30_000_000_000)
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
        manager.startOnURLChanged {
            lateURLCount += 1
        }
        await Task.yield()
        XCTAssertEqual(lateURLCount, 0)
        XCTAssertNil(manager.onURLChangedTask)
    }

    func testNavigationFailureCancelsPendingDocumentWorkBeforeFailureCallback() async {
        let manager = NavigationTaskManager()
        let committedStarted = expectation(description: "committed callback started")
        let committedCancelled = expectation(description: "committed callback cancelled")
        let pendingURLCalled = expectation(description: "pending URL callback must not run")
        pendingURLCalled.isInverted = true
        let failureCalled = expectation(description: "failure callback called")

        manager.startOnNavigationCommitted {
            committedStarted.fulfill()
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch is CancellationError {
                committedCancelled.fulfill()
                throw CancellationError()
            }
        }
        manager.startOnURLChanged {
            pendingURLCalled.fulfill()
        }

        await fulfillment(of: [committedStarted], timeout: 1)
        manager.startOnNavigationFailed {
            failureCalled.fulfill()
        }
        await fulfillment(
            of: [committedCancelled, failureCalled],
            timeout: 1
        )
        await fulfillment(of: [pendingURLCalled], timeout: 0.05)
    }

    func testSharedFontInjectionRejectsMountedCallerWithoutDocumentIdentity() async throws {
        let viewModel = ReaderModeViewModel()
        let caller = WebViewScriptCaller()
        let owner = UUID()
        var evaluations = 0
        caller.installBinding(
            ownedBy: owner,
            asyncCaller: { _, _, _, _ in
                evaluations += 1
                return .init(nil)
            },
            unsafeCaller: nil,
            snapshotCapture: nil,
            coordinateOriginInWindow: { nil },
            documentGenerationProvider: { nil }
        )
        defer { _ = caller.clearBinding(ownedBy: owner) }
        XCTAssertTrue(caller.canEvaluateJavaScript)
        XCTAssertNil(caller.currentJavaScriptBindingToken)

        await viewModel.injectSharedFontIfNeeded(
            scriptCaller: caller,
            pageURL: URL(string: "ebook:///missing-document-identity.epub")!
        )
        XCTAssertEqual(evaluations, 0)
    }

    func testSharedFontInjectionCannotAdoptReplacementBinding() async throws {
        let viewModel = ReaderModeViewModel()
        let caller = WebViewScriptCaller()
        let firstOwner = UUID()
        caller.installBinding(
            ownedBy: firstOwner,
            asyncCaller: { _, _, _, _ in
                XCTFail("Retired binding must not execute")
                return .init(nil)
            },
            unsafeCaller: nil,
            snapshotCapture: nil,
            coordinateOriginInWindow: { nil }
        )
        let retiredBinding = try XCTUnwrap(
            caller.currentJavaScriptBindingToken
        )
        _ = caller.clearBinding(ownedBy: firstOwner)

        let replacementOwner = UUID()
        let replacementEvaluation = expectation(
            description: "retired injection must not run on replacement binding"
        )
        replacementEvaluation.isInverted = true
        caller.installBinding(
            ownedBy: replacementOwner,
            asyncCaller: { _, _, _, _ in
                replacementEvaluation.fulfill()
                return .init(nil)
            },
            unsafeCaller: nil,
            snapshotCapture: nil,
            coordinateOriginInWindow: { nil }
        )
        defer { _ = caller.clearBinding(ownedBy: replacementOwner) }

        await viewModel.injectSharedFontIfNeeded(
            scriptCaller: caller,
            pageURL: URL(string: "ebook:///binding-fence.epub")!,
            requiring: retiredBinding
        )

        await fulfillment(of: [replacementEvaluation], timeout: 0.05)
    }

    func testNavigationFinishedCannotSettleReplacementBindingAfterFontWait()
    async throws {
        let viewModel = ReaderModeViewModel()
        let caller = WebViewScriptCaller()
        let firstOwner = UUID()
        let fontEvaluationStarted = expectation(
            description: "original document font injection started"
        )
        let gate = ReaderCallbackGate()
        caller.installBinding(
            ownedBy: firstOwner,
            asyncCaller: { _, _, _, _ in
                fontEvaluationStarted.fulfill()
                await gate.wait()
                return .init(nil)
            },
            unsafeCaller: nil,
            snapshotCapture: nil,
            coordinateOriginInWindow: { nil }
        )

        let url = URL(string: "ebook:///same-url-replacement.epub")!
        viewModel.beginReaderModeLoad(for: url)
        var state = WebViewState.empty
        state.pageURL = url

        let finish = Task { @MainActor in
            await viewModel.onNavigationFinished(
                newState: state,
                scriptCaller: caller
            )
        }
        await fulfillment(of: [fontEvaluationStarted], timeout: 1)

        _ = caller.clearBinding(ownedBy: firstOwner)
        let replacementOwner = UUID()
        caller.installBinding(
            ownedBy: replacementOwner,
            asyncCaller: { _, _, _, _ in .init(nil) },
            unsafeCaller: nil,
            snapshotCapture: nil,
            coordinateOriginInWindow: { nil }
        )
        defer { _ = caller.clearBinding(ownedBy: replacementOwner) }

        await gate.release()
        await finish.value

        XCTAssertTrue(viewModel.isReaderModeLoading)
        XCTAssertTrue(viewModel.isReaderModeLoadPending(for: url))
    }

    func testPreservedDocumentFailureKeepsSettledURLLifecycleAvailable() async throws {
        let manager = NavigationTaskManager()
        var order: [String] = []

        manager.startOnNavigationCommitted {
            order.append("commit")
        }
        manager.startOnNavigationFinished {
            order.append("finish")
        }
        try await manager.onNavigationFinishedTask?.value

        manager.startOnNavigationFailed(preservingCommittedDocument: true) {
            order.append("recoverable-failure")
        }
        try await manager.onNavigationFailedTask?.value

        manager.startOnURLChanged {
            order.append("url")
        }
        try await manager.onURLChangedTask?.value

        XCTAssertEqual(order, ["commit", "finish", "recoverable-failure", "url"])
    }
}
