import XCTest
import BigSyncKit
@testable import RealmSwiftGaps
import SwiftUI
@preconcurrency import WebKit
import RealmSwift
@testable import SwiftUIWebView
@testable import LakeOfFireContent
import LakeOfFireCore
@testable import LakeOfFireReader

final class ReaderDocumentMutationAdmissionTests: XCTestCase {
    private let current = URL(string: "https://example.com/article#visible")!

    func testTopLevelAdmissionRequiresPayloadWebKitAndCurrentDocumentToAgree() {
        XCTAssertTrue(ReaderDocumentMutationAdmission.acceptsTopLevelDocument(
            claimedURL: URL(string: "https://example.com/article#reported"),
            frameMainDocumentURL: URL(string: "https://example.com/article#loaded"),
            currentPageURL: current,
            requiresMainFrame: true,
            isMainFrame: true
        ))

        XCTAssertFalse(ReaderDocumentMutationAdmission.acceptsTopLevelDocument(
            claimedURL: URL(string: "https://victim.example/article"),
            frameMainDocumentURL: URL(string: "https://example.com/article"),
            currentPageURL: current,
            requiresMainFrame: true,
            isMainFrame: true
        ))
        XCTAssertFalse(ReaderDocumentMutationAdmission.acceptsTopLevelDocument(
            claimedURL: URL(string: "https://example.com/article"),
            frameMainDocumentURL: URL(string: "https://example.com/previous"),
            currentPageURL: current,
            requiresMainFrame: true,
            isMainFrame: true
        ))
        XCTAssertFalse(ReaderDocumentMutationAdmission.acceptsTopLevelDocument(
            claimedURL: URL(string: "https://example.com/article"),
            frameMainDocumentURL: URL(string: "https://example.com/article"),
            currentPageURL: current,
            requiresMainFrame: true,
            isMainFrame: false
        ))
    }

    func testFrameTargetCannotNameAnUnrelatedRecord() {
        XCTAssertTrue(ReaderDocumentMutationAdmission.acceptsFrameTarget(
            claimedFrameURL: URL(string: "https://www.youtube.com/watch?v=abcdefghijk#captions"),
            frameRequestURL: URL(string: "https://www.youtube.com/watch?v=abcdefghijk")
        ))
        XCTAssertFalse(ReaderDocumentMutationAdmission.acceptsFrameTarget(
            claimedFrameURL: URL(string: "https://www.youtube.com/watch?v=otherrecord"),
            frameRequestURL: URL(string: "https://www.youtube.com/watch?v=abcdefghijk")
        ))
    }
}


private actor ReadabilityReceiptGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func release() {
        released = true
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
private final class ReadabilityReceiptFrameProbe: NSObject, WKScriptMessageHandler {
    let receive: (WKFrameInfo) -> Void
    init(receive: @escaping (WKFrameInfo) -> Void) { self.receive = receive }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        receive(message.frameInfo)
    }
}

@MainActor
private final class ReadabilityReceiptScriptProbe {
    var calls = 0
    var cancelAfterDispatch = false
}

extension ReaderDocumentMutationAdmissionTests {
    @MainActor
    private func capturedFrame(for url: URL) async throws -> (WKWebView, WKFrameInfo) {
        let received = expectation(description: "Capture actual WebKit frame provenance")
        var captured: WKFrameInfo?
        let probe = ReadabilityReceiptFrameProbe { frame in
            guard captured == nil else { return }
            captured = frame
            received.fulfill()
        }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(probe, name: "receiptFrame")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString("<html><body><script>window.webkit.messageHandlers.receiptFrame.postMessage('ready')</script></body></html>", baseURL: url)
        await fulfillment(of: [received], timeout: 5)
        let frame = try XCTUnwrap(captured)
        XCTAssertTrue(frame.isMainFrame)
        XCTAssertEqual(frame.request.mainDocumentURL?.removingFragmentIfNeeded(), url)
        return (webView, frame)
    }

    @MainActor
    private func receiptFixture(url: URL) throws -> (ReaderMessageHandlers, HistoryRecord, ReadabilityReceiptScriptProbe) {
        let reader = ReaderContent()
        let row = HistoryRecord()
        row.url = url
        row.title = "Current article"
        row.rssContainsFullContent = false
        row.isReaderModeByDefault = true
        row.updateCompoundKey()
        reader.content = row
        reader.pageURL = url
        let caller = WebViewScriptCaller()
        let probe = ReadabilityReceiptScriptProbe()
        installReceiptBinding(on: caller, probe: probe)
        var library = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        library.objectTypes = [LibraryConfiguration.self, FeedCategory.self, UserScript.self]
        configureLakeOfFireMutationTrackingForTesting(&library)
        let viewModel = ReaderViewModel(realmConfiguration: library, systemScripts: [])
        viewModel.scriptCaller = caller
        var state = WebViewState.empty
        state.pageURL = url
        viewModel.state = state
        let mode = ReaderModeViewModel()
        let navigator = WebViewNavigator()
        mode.navigator = navigator
        let handlers = ReaderMessageHandlers(
            forceReaderModeWhenAvailable: false, scriptCaller: caller,
            readerViewModel: viewModel, readerModeViewModel: mode,
            readerContent: reader, navigator: navigator,
            hideNavigationDueToScroll: .constant(false),
            showOriginalWillBeginHandler: nil,
            navigationVisibilityWillChangeHandler: nil, colorScheme: .light
        )
        return (handlers, row, probe)
    }

    @MainActor
    private func installReceiptBinding(on caller: WebViewScriptCaller, probe: ReadabilityReceiptScriptProbe) {
        caller.installBinding(
            ownedBy: UUID(),
            asyncCaller: { _, _, _, _ in
                probe.calls += 1
                if probe.cancelAfterDispatch {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                return .init(nil)
            }, unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil }
        )
    }

    @MainActor
    func testParsedReadabilityKeepsOriginalReceiptAcrossPublicationDateAwait() async throws {
        let url = URL(string: "https://example.invalid/readability-receipt")!
        let (webView, frame) = try await capturedFrame(for: url)
        defer { webView.configuration.userContentController.removeScriptMessageHandler(forName: "receiptFrame") }
        for change in ["binding", "selection", "owners", "cancelled", "live"] {
            let (handlers, row, probe) = try receiptFixture(url: url)
            let mode = handlers.readerModeViewModel
            let originalHTML = "<html><body>Current cached article</body></html>"
            mode.readabilityContent = originalHTML
            let gate = ReadabilityReceiptGate()
            let entered = expectation(description: "Actual parsed handler awaits publication date: \(change)")
            mode.readerPublicationDateLoader = { _ in
                entered.fulfill()
                await gate.wait()
                return nil
            }
            let output = "<html><body><div id='reader-content'>Old receipt article</div></body></html>"
            let message = WebViewMessage(
                frameInfo: frame, uuid: UUID(), name: "readabilityParsed",
                body: ["pageURL": url.absoluteString, "windowURL": url.absoluteString,
                       "title": "Old receipt", "byline": "", "content": "Old receipt article",
                       "inputHTML": output, "outputHTML": output],
                javaScriptBindingToken: handlers.scriptCaller.currentJavaScriptBindingToken
            )
            if change == "live" {
                row.isReaderModeByDefault = false
                // End after the admitted publication/JS effect, before unrelated durable discovery.
                probe.cancelAfterDispatch = true
            }
            let handler = try XCTUnwrap(handlers.webViewMessageHandlers.handlers["readabilityParsed"])
            let task = Task { await handler(message) }
            await fulfillment(of: [entered], timeout: 2)
            if change == "binding" {
                installReceiptBinding(on: handlers.scriptCaller, probe: probe)
            } else if change == "selection" {
                let other = HistoryRecord()
                other.url = URL(string: "https://example.invalid/other-selection")!
                other.updateCompoundKey()
                try await handlers.readerContent.load(url: other.url, resolveContent: { _ in other })
                try await handlers.readerContent.load(url: url, resolveContent: { _ in row })
            } else if change == "owners" {
                let successorContent = ReaderContent()
                successorContent.content = row
                successorContent.pageURL = url
                let successorMode = ReaderModeViewModel()
                successorMode.readabilityContent = "Successor cached article"
                successorMode.beginReaderModeLoad(for: url)
                handlers.update(
                    forceReaderModeWhenAvailable: false,
                    scriptCaller: handlers.scriptCaller,
                    readerViewModel: handlers.readerViewModel,
                    readerModeViewModel: successorMode,
                    readerContent: successorContent,
                    navigator: handlers.navigator,
                    hideNavigationDueToScroll: .constant(false),
                    showOriginalWillBeginHandler: nil,
                    navigationVisibilityWillChangeHandler: nil,
                    ebookOpeningPreparer: nil, colorScheme: .light
                )
            } else if change == "cancelled" {
                task.cancel()
            }
            await gate.release()
            await task.value
            XCTAssertEqual(mode.readabilityContent, change == "live" ? output : originalHTML, change)
            XCTAssertEqual(probe.calls, change == "live" ? 1 : 0, change)
            XCTAssertNil(mode.pendingReaderModeURL, change)
            XCTAssertEqual(handlers.navigator.debugLoadSnapshot.lastDataLoadBaseURL, "nil", change)
            if change == "owners" {
                XCTAssertEqual(handlers.readerModeViewModel.readabilityContent, "Successor cached article")
                XCTAssertEqual(handlers.readerModeViewModel.pendingReaderModeURL, url)
                XCTAssertTrue(handlers.readerModeViewModel.isReaderModeLoading)
            }
            mode.readerPublicationDateLoader = nil
        }
    }



    @MainActor
    func testQueuedAvailabilityWriteRetainsOriginalHandlerOwners() async throws {
        let url = URL(string: "https://example.invalid/queued-readability-owners")!
        let (webView, frame) = try await capturedFrame(for: url)
        defer { webView.configuration.userContentController.removeScriptMessageHandler(forName: "receiptFrame") }
        let previousBookmark = ReaderContentLoader.bookmarkRealmConfiguration
        let previousHistory = ReaderContentLoader.historyRealmConfiguration
        let previousFeed = ReaderContentLoader.feedEntryRealmConfiguration
        defer {
            ReaderContentLoader.bookmarkRealmConfiguration = previousBookmark
            ReaderContentLoader.historyRealmConfiguration = previousHistory
            ReaderContentLoader.feedEntryRealmConfiguration = previousFeed
        }
        for replaceOwners in [false, true] {
            var configuredRealm = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
            configuredRealm.objectTypes = [Bookmark.self, ContentFile.self, HistoryRecord.self, FeedEntry.self]
            configureLakeOfFireMutationTrackingForTesting(&configuredRealm)
            let configuration = configuredRealm
            ReaderContentLoader.bookmarkRealmConfiguration = configuration
            ReaderContentLoader.historyRealmConfiguration = configuration
            ReaderContentLoader.feedEntryRealmConfiguration = configuration
            await ReaderContentLoader.resetTransientCachesForTesting()
            let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
            let row = HistoryRecord()
            row.url = url
            row.title = "Availability source"
            row.isReaderModeByDefault = false
            row.isReaderModeAvailable = false
            row.isReaderModeOfferHidden = false
            row.rssContainsFullContent = true
            row.updateCompoundKey()
            try realm.write {
                realm.add(row)
                row.refreshChangeMetadata(explicitlyModified: true)
            }
            let journalID = row.objectSchema.className + "." + row.compoundKey
            let seededGeneration = try XCTUnwrap(realm.object(
                ofType: BigSyncPendingMutation.self, forPrimaryKey: journalID
            )).generation
            let seededModifiedAt = row.modifiedAt
            let seededExplicitlyModifiedAt = row.explicitlyModifiedAt
            let (handlers, _, _) = try receiptFixture(url: url)
            let originalContent = handlers.readerContent
            originalContent.content = nil
            try await originalContent.load(url: url, resolveContent: { _ in row })
            XCTAssertTrue(originalContent.content === row)
            let originalSelection = originalContent.makeSelectionCommitFence(
                requiring: originalContent.currentSelectionID
            )
            let message = WebViewMessage(
                frameInfo: frame, uuid: UUID(), name: "readabilityParsed",
                body: ["pageURL": url.absoluteString, "windowURL": url.absoluteString,
                       "title": "", "byline": "", "content": "", "inputHTML": "", "outputHTML": ""],
                javaScriptBindingToken: handlers.scriptCaller.currentJavaScriptBindingToken
            )
            let gate = ReadabilityReceiptGate()
            let entered = expectation(description: "Availability discovery queued: \(replaceOwners)")
            await { @RealmBackgroundActor in
                ReaderContentLoader.loadAllDiscoveryGateForTesting = {
                    entered.fulfill()
                    await gate.wait()
                }
            }()
            let handler = try XCTUnwrap(handlers.webViewMessageHandlers.handlers["readabilityParsed"])
            let task = Task { await handler(message) }
            addTeardownBlock {
                await gate.release()
                await task.value
                await ReaderContentLoader.resetTransientCachesForTesting()
                _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
            }
            await fulfillment(of: [entered], timeout: 2)
            let contentOwner: ReaderContent
            let modeOwner: ReaderModeViewModel
            if replaceOwners {
                contentOwner = ReaderContent()
                contentOwner.content = row
                contentOwner.pageURL = url
                modeOwner = ReaderModeViewModel()
            } else {
                contentOwner = handlers.readerContent
                modeOwner = handlers.readerModeViewModel
            }
            // Exercise the retained StateObject's actual dependency update boundary.
            handlers.update(
                forceReaderModeWhenAvailable: false,
                scriptCaller: handlers.scriptCaller,
                readerViewModel: handlers.readerViewModel,
                readerModeViewModel: modeOwner, readerContent: contentOwner,
                navigator: handlers.navigator, hideNavigationDueToScroll: .constant(false),
                showOriginalWillBeginHandler: nil, navigationVisibilityWillChangeHandler: nil,
                ebookOpeningPreparer: nil, colorScheme: .light
            )
            XCTAssertTrue(originalSelection(), "Identity replacement must not retire ReaderContent's own selection")
            await gate.release()
            await task.value
            await realm.asyncRefresh()
            XCTAssertEqual(row.isReaderModeAvailable, !replaceOwners)
            XCTAssertEqual(row.isReaderModeOfferHidden, !replaceOwners)
            let settledGeneration = try XCTUnwrap(realm.object(
                ofType: BigSyncPendingMutation.self, forPrimaryKey: journalID
            )).generation
            if replaceOwners {
                XCTAssertEqual(settledGeneration, seededGeneration)
                XCTAssertEqual(row.modifiedAt, seededModifiedAt)
                XCTAssertEqual(row.explicitlyModifiedAt, seededExplicitlyModifiedAt)
            } else {
                XCTAssertNotEqual(settledGeneration, seededGeneration)
            }
            await ReaderContentLoader.resetTransientCachesForTesting()
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
        }
    }


    @MainActor
    func testSuspendedFramePingCannotRegisterIntoSameURLReplacementBinding() async throws {
        let url = URL(string: "https://example.invalid/frame-ping-receipt")!
        let (webView, frame) = try await capturedFrame(for: url)
        defer { webView.configuration.userContentController.removeScriptMessageHandler(forName: "receiptFrame") }
        var configuredRealm = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuredRealm.objectTypes = [Bookmark.self, ContentFile.self, HistoryRecord.self, FeedEntry.self]
        configureLakeOfFireMutationTrackingForTesting(&configuredRealm)
        let configuration = configuredRealm
        let previousBookmark = ReaderContentLoader.bookmarkRealmConfiguration
        let previousHistory = ReaderContentLoader.historyRealmConfiguration
        let previousFeed = ReaderContentLoader.feedEntryRealmConfiguration
        defer {
            ReaderContentLoader.bookmarkRealmConfiguration = previousBookmark
            ReaderContentLoader.historyRealmConfiguration = previousHistory
            ReaderContentLoader.feedEntryRealmConfiguration = previousFeed
        }
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        await ReaderContentLoader.resetTransientCachesForTesting()
        let realm = try await Realm(configuration: configuration, actor: MainActor.shared)
        let row = HistoryRecord()
        row.url = url
        row.title = "Frame ping source"
        row.updateCompoundKey()
        try realm.write {
            realm.add(row)
            row.refreshChangeMetadata(explicitlyModified: true)
        }
        let (handlers, _, probe) = try receiptFixture(url: url)
        handlers.readerContent.content = nil
        try await handlers.readerContent.load(url: url, resolveContent: { _ in row })
        XCTAssertTrue(handlers.readerContent.content === row)
        let originalSelection = handlers.readerContent.makeSelectionCommitFence(
            requiring: handlers.readerContent.currentSelectionID
        )
        // Keep the selection alive while forcing the handler's actual resolver path.
        handlers.readerContent.content = nil
        let staleUUID = "stale-frame-ping"
        let successorUUID = "current-frame-ping"
        let message = WebViewMessage(
            frameInfo: frame, uuid: UUID(), name: "readabilityFramePing",
            body: ["uuid": staleUUID, "windowURL": url.absoluteString],
            javaScriptBindingToken: handlers.scriptCaller.currentJavaScriptBindingToken
        )
        let gate = ReadabilityReceiptGate()
        let entered = expectation(description: "Frame ping content lookup discovery queued")
        await { @RealmBackgroundActor in
            ReaderContentLoader.loadAllDiscoveryGateForTesting = {
                entered.fulfill()
                await gate.wait()
            }
        }()
        let handler = try XCTUnwrap(handlers.webViewMessageHandlers.handlers["readabilityFramePing"])
        let task = Task { await handler(message) }
        addTeardownBlock {
            await gate.release()
            await task.value
            await ReaderContentLoader.resetTransientCachesForTesting()
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
        }
        await fulfillment(of: [entered], timeout: 2)
        installReceiptBinding(on: handlers.scriptCaller, probe: probe)
        XCTAssertTrue(handlers.scriptCaller.addMultiTargetFrame(frame, uuid: successorUUID))
        XCTAssertTrue(originalSelection())
        await gate.release()
        await task.value
        XCTAssertNil(handlers.scriptCaller.frame(forUUID: staleUUID))
        XCTAssertTrue(handlers.scriptCaller.frame(forUUID: successorUUID) === frame)
        XCTAssertEqual(probe.calls, 0)
        await ReaderContentLoader.resetTransientCachesForTesting()
        let admittedUUID = "admitted-current-frame-ping"
        let admittedMessage = WebViewMessage(
            frameInfo: frame, uuid: UUID(), name: "readabilityFramePing",
            body: ["uuid": admittedUUID, "windowURL": url.absoluteString],
            javaScriptBindingToken: handlers.scriptCaller.currentJavaScriptBindingToken
        )
        probe.cancelAfterDispatch = true
        await handler(admittedMessage)
        XCTAssertTrue(handlers.scriptCaller.frame(forUUID: admittedUUID) === frame)
        _ = await RealmBackgroundActor.shared.removeCachedRealm(for: configuration)
    }

    @MainActor
    func testUnavailableReadabilityCannotClearModeAfterSameURLBindingReplacement() async throws {
        let url = URL(string: "https://example.invalid/unavailable-receipt")!
        let (webView, frame) = try await capturedFrame(for: url)
        defer { webView.configuration.userContentController.removeScriptMessageHandler(forName: "receiptFrame") }
        let (handlers, _, probe) = try receiptFixture(url: url)
        handlers.readerModeViewModel.isReaderMode = true
        let gate = ReadabilityReceiptGate()
        let entered = expectation(description: "Unavailable handler reaches original document JS")
        handlers.scriptCaller.installBinding(
            ownedBy: UUID(),
            asyncCaller: { _, _, _, _ in
                entered.fulfill()
                await gate.wait()
                return .init(nil)
            }, unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil }
        )
        let message = WebViewMessage(
            frameInfo: frame, uuid: UUID(), name: "readabilityModeUnavailable",
            body: ["pageURL": url.absoluteString, "windowURL": url.absoluteString],
            javaScriptBindingToken: handlers.scriptCaller.currentJavaScriptBindingToken
        )
        let handler = try XCTUnwrap(handlers.webViewMessageHandlers.handlers["readabilityModeUnavailable"])
        let task = Task { await handler(message) }
        await fulfillment(of: [entered], timeout: 2)
        installReceiptBinding(on: handlers.scriptCaller, probe: probe)
        await gate.release()
        await task.value
        XCTAssertTrue(handlers.readerModeViewModel.isReaderMode)
        XCTAssertEqual(probe.calls, 0)
    }

    @MainActor
    func testAutomaticReadabilityUsesOriginalReceiptBindingAfterDelay() async throws {
        let url = URL(string: "https://example.invalid/automatic-receipt")!
        let (webView, frame) = try await capturedFrame(for: url)
        defer { webView.configuration.userContentController.removeScriptMessageHandler(forName: "receiptFrame") }
        for change in ["live", "binding", "contentOwner"] {
            let (handlers, _, probe) = try receiptFixture(url: url)
            let message = WebViewMessage(
                frameInfo: frame, uuid: UUID(), name: "readabilityNeedsUpdate",
                body: ["reason": "initial", "windowURL": url.absoluteString],
                javaScriptBindingToken: handlers.scriptCaller.currentJavaScriptBindingToken
            )
            let handler = try XCTUnwrap(handlers.webViewMessageHandlers.handlers["readabilityNeedsUpdate"])
            await handler(message)
            let delayed = try XCTUnwrap(handlers.automaticReadabilityTask)
            if change == "binding" {
                installReceiptBinding(on: handlers.scriptCaller, probe: probe)
            } else if change == "contentOwner" {
                let successor = ReaderContent()
                successor.pageURL = url
                handlers.update(
                    forceReaderModeWhenAvailable: false,
                    scriptCaller: handlers.scriptCaller,
                    readerViewModel: handlers.readerViewModel,
                    readerModeViewModel: handlers.readerModeViewModel,
                    readerContent: successor, navigator: handlers.navigator,
                    hideNavigationDueToScroll: .constant(false),
                    showOriginalWillBeginHandler: nil,
                    navigationVisibilityWillChangeHandler: nil,
                    ebookOpeningPreparer: nil, colorScheme: .light
                )
            }
            await delayed.value
            XCTAssertEqual(probe.calls, change == "live" ? 1 : 0, change)
        }
    }
}
