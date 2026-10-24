import XCTest
import SwiftUI
import Combine
import RealmSwift
import BigSyncKit
import WebKit
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
private final class ReaderOriginalReloadProbe: WKWebView {
    private(set) var reloadCount = 0

    override func reload() -> WKNavigation? {
        reloadCount += 1
        return nil
    }
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
final class ReaderWebViewCallbackContractTests: XCTestCase {
    private func withShowOriginalRealm(
        _ operation: @MainActor (Realm) async throws -> Void
    ) async throws {
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [Bookmark.self, ContentFile.self, HistoryRecord.self, FeedEntry.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let priorBookmarks = ReaderContentLoader.bookmarkRealmConfiguration
        let priorHistory = ReaderContentLoader.historyRealmConfiguration
        let priorFeeds = ReaderContentLoader.feedEntryRealmConfiguration
        defer {
            ReaderContentLoader.bookmarkRealmConfiguration = priorBookmarks
            ReaderContentLoader.historyRealmConfiguration = priorHistory
            ReaderContentLoader.feedEntryRealmConfiguration = priorFeeds
        }
        await ReaderContentLoader.resetTransientCachesForTesting()
        ReaderContentLoader.bookmarkRealmConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        let realm = try Realm(configuration: configuration)
        do {
            try await operation(realm)
        } catch {
            await ReaderContentLoader.resetTransientCachesForTesting()
            throw error
        }
        await ReaderContentLoader.resetTransientCachesForTesting()
    }

    private func showOriginalReloadProbe() -> ReaderOriginalReloadProbe {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return ReaderOriginalReloadProbe(frame: .zero, configuration: configuration)
    }

    private func showOriginalRecord(in realm: Realm, url: URL) throws -> HistoryRecord {
        let record = HistoryRecord()
        record.url = url
        record.isReaderModeByDefault = true
        record.isReaderModeAvailable = false
        record.isReaderModeOfferHidden = true
        record.rssContainsFullContent = true
        record.updateCompoundKey()
        try realm.write {
            realm.add(record)
            record.refreshChangeMetadata(explicitlyModified: true)
        }
        return record
    }

    private func showOriginalHandlers(
        fixture: (handler: ReaderWebViewHandler, taskManager: NavigationTaskManager,
                  readerContent: ReaderContent, readerModeViewModel: ReaderModeViewModel),
        willBegin: ReaderShowOriginalWillBeginHandler? = nil
    ) -> ReaderMessageHandlers {
        ReaderMessageHandlers(
            forceReaderModeWhenAvailable: false,
            scriptCaller: fixture.handler.scriptCaller,
            readerViewModel: fixture.handler.readerViewModel,
            readerModeViewModel: fixture.readerModeViewModel,
            readerContent: fixture.readerContent,
            navigator: fixture.handler.navigator,
            hideNavigationDueToScroll: .constant(false),
            showOriginalWillBeginHandler: willBegin,
            navigationVisibilityWillChangeHandler: nil,
            colorScheme: .light
        )
    }

    func testShowOriginalCurrentActionUpdatesFlagsAndDispatchesOneReload() async throws {
        try await withShowOriginalRealm { realm in
            let fixture = makeReaderWebViewHandlerFixture()
            let source = try XCTUnwrap(URL(string: "https://example.com/show-original-current"))
            let record = try self.showOriginalRecord(in: realm, url: source)
            try await fixture.readerContent.load(url: source, resolveContent: { _ in record })
            fixture.readerModeViewModel.readabilityContent = "Captured reader content"
            fixture.readerModeViewModel.readabilityContainerSelector = "#reader-content"
            let webView = self.showOriginalReloadProbe()
            fixture.handler.navigator.webView = webView
            let caller = fixture.handler.scriptCaller
            let bindingOwner = UUID()
            caller.installBinding(ownedBy: bindingOwner, asyncCaller: { _, _, _, _ in .init(nil) },
                                  unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil })
            defer { _ = caller.clearBinding(ownedBy: bindingOwner) }
            let binding = try XCTUnwrap(caller.currentJavaScriptBindingToken)
            var hookCount = 0
            let handlers = self.showOriginalHandlers(fixture: fixture) { contentURL, pageURL in
                XCTAssertEqual(contentURL, source)
                XCTAssertEqual(pageURL, source)
                hookCount += 1
            }
            try await handlers.showOriginal(requiring: binding)
            XCTAssertEqual(hookCount, 1)
            XCTAssertEqual(webView.reloadCount, 1)
            XCTAssertFalse(record.isReaderModeByDefault)
            XCTAssertTrue(record.isReaderModeAvailable)
            XCTAssertFalse(record.isReaderModeOfferHidden)
            XCTAssertNil(fixture.readerModeViewModel.readabilityContent)
            XCTAssertNil(fixture.readerModeViewModel.readabilityContainerSelector)
        }
    }

    func testSuspendedShowOriginalCannotReloadReplacementOrCancelledDocument() async throws {
        for retirement in ["cancelled", "same-url-binding", "new-url-selection", "deleted-row"] {
            try await withShowOriginalRealm { realm in
                let fixture = makeReaderWebViewHandlerFixture()
                let source = try XCTUnwrap(URL(string: "https://example.com/show-original-retired"))
                let record = try self.showOriginalRecord(in: realm, url: source)
                try await fixture.readerContent.load(url: source, resolveContent: { _ in record })
                let caller = fixture.handler.scriptCaller
                var bindingOwner = UUID()
                caller.installBinding(ownedBy: bindingOwner, asyncCaller: { _, _, _, _ in .init(nil) },
                                      unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil })
                defer { _ = caller.clearBinding(ownedBy: bindingOwner) }
                let binding = try XCTUnwrap(caller.currentJavaScriptBindingToken)
                let webView = self.showOriginalReloadProbe()
                fixture.handler.navigator.webView = webView
                let enteredHook = self.expectation(description: "show-original hook suspended: \(retirement)")
                let gate = ReaderCallbackGate()
                let handlers = self.showOriginalHandlers(fixture: fixture) { _, _ in
                    enteredHook.fulfill()
                    await gate.wait()
                }
                let action = Task { @MainActor in try await handlers.showOriginal(requiring: binding) }
                await self.fulfillment(of: [enteredHook], timeout: 1)
                switch retirement {
                case "cancelled":
                    action.cancel()
                case "same-url-binding":
                    _ = caller.clearBinding(ownedBy: bindingOwner)
                    bindingOwner = UUID()
                    caller.installBinding(ownedBy: bindingOwner, asyncCaller: { _, _, _, _ in .init(nil) },
                                          unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil })
                case "new-url-selection":
                    let destination = try XCTUnwrap(URL(string: "https://example.com/successor"))
                    let successor = HistoryRecord()
                    successor.url = destination
                    try await fixture.readerContent.load(url: destination, resolveContent: { _ in successor })
                default:
                    try realm.write { realm.delete(record) }
                }
                let successorCapture = "Successor capture after old action suspended"
                fixture.readerModeViewModel.readabilityContent = successorCapture
                fixture.readerModeViewModel.readabilityContainerSelector = "#successor"
                fixture.readerContent.isRenderingReaderHTML = true
                await gate.release()
                do {
                    try await action.value
                    XCTFail("Retired show-original action returned successfully: \(retirement)")
                } catch is CancellationError {
                }
                XCTAssertEqual(webView.reloadCount, 0, retirement)
                XCTAssertEqual(fixture.readerModeViewModel.readabilityContent, successorCapture, retirement)
                XCTAssertEqual(fixture.readerModeViewModel.readabilityContainerSelector, "#successor", retirement)
                XCTAssertTrue(fixture.readerContent.isRenderingReaderHTML, retirement)
                if !record.isInvalidated {
                    XCTAssertTrue(record.isReaderModeByDefault, retirement)
                    XCTAssertFalse(record.isReaderModeAvailable, retirement)
                }
            }
        }
    }

    func testShowOriginalIgnoresAlreadyInvalidatedCachedRow() async throws {
        try await withShowOriginalRealm { realm in
            let fixture = makeReaderWebViewHandlerFixture()
            let source = try XCTUnwrap(URL(string: "https://example.com/show-original-deleted"))
            let record = try self.showOriginalRecord(in: realm, url: source)
            try await fixture.readerContent.load(url: source, resolveContent: { _ in record })
            try realm.write { realm.delete(record) }
            let webView = self.showOriginalReloadProbe()
            fixture.handler.navigator.webView = webView
            let caller = fixture.handler.scriptCaller
            let bindingOwner = UUID()
            caller.installBinding(ownedBy: bindingOwner, asyncCaller: { _, _, _, _ in .init(nil) },
                                  unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil })
            defer { _ = caller.clearBinding(ownedBy: bindingOwner) }
            let binding = try XCTUnwrap(caller.currentJavaScriptBindingToken)
            let handlers = self.showOriginalHandlers(fixture: fixture) { _, _ in
                XCTFail("Invalidated cached row must not start the action")
            }
            do {
                try await handlers.showOriginal(requiring: binding)
                XCTFail("Invalidated cached row was accepted")
            } catch is CancellationError {
            }
            XCTAssertEqual(webView.reloadCount, 0)
        }
    }

    func testShowOriginalCannotAdoptOldReceiptOrSynchronousReplacement() async throws {
        for replacesDuringCacheClear in [false, true] {
            try await withShowOriginalRealm { realm in
                let fixture = makeReaderWebViewHandlerFixture()
                let source = try XCTUnwrap(URL(string: "https://example.com/show-original-reentry"))
                let record = try self.showOriginalRecord(in: realm, url: source)
                try await fixture.readerContent.load(url: source, resolveContent: { _ in record })
                let mode = fixture.readerModeViewModel
                mode.readabilityContent = "Original capture"
                mode.readabilityContainerSelector = "#original"
                let caller = fixture.handler.scriptCaller
                let originalOwner = UUID()
                let replacementOwner = UUID()
                caller.installBinding(ownedBy: originalOwner, asyncCaller: { _, _, _, _ in .init(nil) },
                                      unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil })
                defer {
                    _ = caller.clearBinding(ownedBy: originalOwner)
                    _ = caller.clearBinding(ownedBy: replacementOwner)
                }
                let binding = try XCTUnwrap(caller.currentJavaScriptBindingToken)
                let webView = self.showOriginalReloadProbe()
                fixture.handler.navigator.webView = webView
                var hookCount = 0
                let handlers = self.showOriginalHandlers(fixture: fixture) { _, _ in hookCount += 1 }
                var replaced = false
                let replaceDocument = {
                    replaced = true
                    _ = caller.clearBinding(ownedBy: originalOwner)
                    caller.installBinding(ownedBy: replacementOwner, asyncCaller: { _, _, _, _ in .init(nil) },
                                          unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil })
                    mode.readabilityContainerSelector = "#successor"
                    handlers.showOriginalWillBeginHandler = { _, _ in
                        XCTFail("Old action invoked the successor's hook")
                    }
                }
                let publication = mode.$readabilityContent.sink { html in
                    if replacesDuringCacheClear, html == nil, !replaced { replaceDocument() }
                }
                defer { publication.cancel() }
                if !replacesDuringCacheClear { replaceDocument() }
                do {
                    try await handlers.showOriginal(requiring: binding)
                    XCTFail("Retired original receipt was accepted")
                } catch is CancellationError {
                }
                XCTAssertTrue(replaced)
                XCTAssertEqual(hookCount, 0)
                XCTAssertEqual(webView.reloadCount, 0)
                XCTAssertEqual(mode.readabilityContainerSelector, "#successor",
                               "A reentrant first cache clear cannot authorize clearing successor fields")
                XCTAssertTrue(record.isReaderModeByDefault)
                XCTAssertFalse(record.isReaderModeAvailable)
            }
        }
    }

    func testSameURLReplacementRetiresSuspendedReaderRender() async throws {
        for processingSucceeds in [false, true] {
            for deliversCommitBeforeResuming in [false, true] {
                let fixture = makeReaderWebViewHandlerFixture()
                fixture.handler.readerViewModel = ReaderCallbackViewModel(
                    realmConfiguration: makeReaderCallbackLibraryConfiguration(), systemScripts: []
                )
                let source = try XCTUnwrap(URL(string: "reader-file://file/load/local/render-replacement.html"))
                let record = HistoryRecord()
                record.url = source
                record.title = "Reader render fixture"
                record.isReaderModeByDefault = true
                record.isReaderModeAvailable = false
                record.isReaderModeOfferHidden = false
                record.rssContainsFullContent = true
                record.html = "<html><body><p>Original document body.</p></body></html>"
                record.updateCompoundKey()
                fixture.readerContent.preloadResolvedContent(record, for: source)
                try await fixture.readerContent.load(url: source)
                let selectionID = fixture.readerContent.currentSelectionID
                let mode = fixture.readerModeViewModel
                mode.navigator = fixture.handler.navigator
                mode.readerLocalHTMLLoader = { _ in "<html><body><p>Original document body.</p></body></html>" }
                mode.readerPublicationDateLoader = { _ in nil }
                let started = expectation(description: "original document processing suspended")
                let gate = ReaderCallbackGate()
                mode.swiftReadabilityProcessor = { _, _, _, _ in
                    started.fulfill()
                    await gate.wait()
                    return processingSucceeds
                        ? "<html><body><div id='reader-content'>Retired document output.</div></body></html>"
                        : nil
                }
                let caller = fixture.handler.scriptCaller
                let originalOwner = UUID()
                caller.installBinding(ownedBy: originalOwner,
                                      asyncCaller: { _, _, _, _ in .init(nil) },
                                      unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil })
                mode.showReaderView(readerContent: fixture.readerContent, scriptCaller: caller)
                await fulfillment(of: [started], timeout: 1)
                let retiredGeneration = try XCTUnwrap(UUID(uuidString: mode.currentRenderGenerationDescription(for: source)))
                let retiredTask = try XCTUnwrap(mode.readerModeRenderTaskForTesting(for: source))
                XCTAssertNil(mode.expectedSyntheticReaderLoaderURL, "No self-issued HTML navigation exists yet")

                // Reproduce the native committed-replacement ordering: retire the old
                // caller, activate the new document, invalidate, then deliver its commit.
                _ = caller.clearBinding(ownedBy: originalOwner)
                let replacementOwner = UUID()
                caller.installBinding(ownedBy: replacementOwner,
                                      asyncCaller: { _, _, _, _ in .init(nil) },
                                      unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil })
                defer { _ = caller.clearBinding(ownedBy: replacementOwner) }
                var replacementState = WebViewState.empty
                replacementState.pageURL = source
                if deliversCommitBeforeResuming {
                    fixture.handler.onDocumentContextInvalidated(state: replacementState, reason: .navigationCommitted)
                    fixture.handler.onNavigationCommitted(state: replacementState)
                    try await fixture.taskManager.onNavigationCommittedTask?.value
                }
                XCTAssertEqual(fixture.readerContent.currentSelectionID, selectionID,
                               "A same-URL commit reuses the cached selection; binding is the distinguishing identity")
                if deliversCommitBeforeResuming {
                    XCTAssertEqual(mode.currentRenderGenerationDescription(for: source), "nil")
                }
                let replacementCapture = "Replacement document capture"
                mode.beginReaderModeLoad(for: source)
                mode.readabilityContent = replacementCapture
                fixture.readerContent.isRenderingReaderHTML = true

                await gate.release()
                await retiredTask.value
                XCTAssertEqual(fixture.handler.navigator.debugLoadSnapshot.lastDataLoadBaseURL, "nil",
                               "The old document's processing must not replace the newly committed document")
                XCTAssertEqual(mode.readabilityContent, replacementCapture,
                               "Retired processing cannot republish or clear the replacement capture")
                XCTAssertTrue(fixture.readerContent.isRenderingReaderHTML)
                XCTAssertTrue(mode.isReaderModeLoading)
                XCTAssertEqual(mode.pendingReaderModeURL, source)
                XCTAssertEqual(mode.currentRenderGenerationDescription(for: source), "nil",
                               "A stale early return cannot manufacture a completed render owner")
                XCTAssertFalse(mode.handleRenderedReaderDocumentReady(pageURL: source, hasReaderContent: true,
                                                                       renderGeneration: retiredGeneration))
            }
        }
    }

    func testSameBindingRowReplacementDoesNotManufactureCompletedRender() async throws {
        let fixture = makeReaderWebViewHandlerFixture()
        defer { fixture.readerModeViewModel.swiftReadabilityProcessor = nil }
        let source = try XCTUnwrap(URL(string: "reader-file://file/load/local/row-retirement.html"))
        let record = HistoryRecord()
        record.url = source
        record.title = "Reader render fixture"
        record.isReaderModeByDefault = true
        record.isReaderModeAvailable = false
        record.isReaderModeOfferHidden = false
        record.rssContainsFullContent = true
        record.html = "<html><body><p>Source content.</p></body></html>"
        record.updateCompoundKey()
        fixture.readerContent.preloadResolvedContent(record, for: source)
        try await fixture.readerContent.load(url: source)
        let mode = fixture.readerModeViewModel
        mode.navigator = fixture.handler.navigator
        mode.readerLocalHTMLLoader = { _ in record.html }
        mode.readerPublicationDateLoader = { _ in nil }
        let successor = HistoryRecord()
        successor.url = source
        let replacementCapture = "Replacement row capture"
        mode.swiftReadabilityProcessor = { _, _, _, _ in
            await Task.yield()
            fixture.readerContent.content = successor
            fixture.readerContent.isRenderingReaderHTML = true
            mode.readabilityContent = replacementCapture
            return "<html><body><div id='reader-content'>Retired row output.</div></body></html>"
        }
        let caller = fixture.handler.scriptCaller
        let owner = UUID()
        caller.installBinding(ownedBy: owner, asyncCaller: { _, _, _, _ in .init(nil) },
                              unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil })
        defer { _ = caller.clearBinding(ownedBy: owner) }
        mode.showReaderView(readerContent: fixture.readerContent, scriptCaller: caller)
        let retiredGeneration = try XCTUnwrap(UUID(uuidString: mode.currentRenderGenerationDescription(for: source)))
        await mode.waitForReaderModeRender(for: source)
        XCTAssertEqual(fixture.handler.navigator.debugLoadSnapshot.lastDataLoadBaseURL, "nil")
        XCTAssertEqual(mode.readabilityContent, replacementCapture)
        XCTAssertTrue(fixture.readerContent.isRenderingReaderHTML)
        XCTAssertEqual(mode.currentRenderGenerationDescription(for: source), "nil")
        XCTAssertFalse(mode.handleRenderedReaderDocumentReady(pageURL: source, hasReaderContent: true,
                                                               renderGeneration: retiredGeneration))
    }

    func testThrowingCapturedReadabilityCannotCleanUpReplacementBinding() async throws {
        let fixture = makeReaderWebViewHandlerFixture()
        let source = try XCTUnwrap(URL(string: "reader-file://file/load/local/throwing-capture.html"))
        let record = HistoryRecord()
        record.url = source
        record.title = "Captured reader"
        record.isReaderModeByDefault = true
        record.isReaderModeAvailable = false
        record.isReaderModeOfferHidden = false
        record.rssContainsFullContent = true
        record.html = "<html><body><p>Original source.</p></body></html>"
        record.updateCompoundKey()
        fixture.readerContent.preloadResolvedContent(record, for: source)
        try await fixture.readerContent.load(url: source)
        let mode = fixture.readerModeViewModel
        mode.navigator = fixture.handler.navigator
        mode.readerLocalHTMLLoader = { _ in nil }
        mode.readerPublicationDateLoader = { _ in nil }
        mode.readabilityContent = "<html><body><div id='reader-content'>Captured source.</div></body></html>"
        let caller = fixture.handler.scriptCaller
        let originalOwner = UUID()
        let replacementOwner = UUID()
        caller.installBinding(ownedBy: originalOwner, asyncCaller: { _, _, _, _ in .init(nil) },
                              unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil })
        defer {
            _ = caller.clearBinding(ownedBy: originalOwner)
            _ = caller.clearBinding(ownedBy: replacementOwner)
            mode.processReadabilityContent = nil
        }
        let replacementCapture = "Replacement document capture"
        let processed = expectation(description: "captured-readability processor invoked")
        mode.processReadabilityContent = { _, _, _, _, _, _, _ in
            await MainActor.run {
                _ = caller.clearBinding(ownedBy: originalOwner)
                caller.installBinding(ownedBy: replacementOwner, asyncCaller: { _, _, _, _ in .init(nil) },
                                      unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil })
                fixture.readerContent.isRenderingReaderHTML = true
                mode.beginReaderModeLoad(for: source)
                mode.readabilityContent = replacementCapture
                processed.fulfill()
            }
            throw ReaderCallbackTestError.commitFailed
        }
        mode.showReaderView(readerContent: fixture.readerContent, scriptCaller: caller)
        let retiredTask = try XCTUnwrap(mode.readerModeRenderTaskForTesting(for: source))
        let retiredGeneration = try XCTUnwrap(UUID(uuidString: mode.currentRenderGenerationDescription(for: source)))
        await retiredTask.value
        await fulfillment(of: [processed], timeout: 1)
        XCTAssertEqual(fixture.handler.navigator.debugLoadSnapshot.lastDataLoadBaseURL, "nil")
        XCTAssertEqual(mode.readabilityContent, replacementCapture)
        XCTAssertTrue(fixture.readerContent.isRenderingReaderHTML)
        XCTAssertTrue(mode.isReaderModeLoading)
        XCTAssertEqual(mode.pendingReaderModeURL, source)
        XCTAssertEqual(mode.currentRenderGenerationDescription(for: source), "nil")
        XCTAssertFalse(mode.handleRenderedReaderDocumentReady(pageURL: source, hasReaderContent: true,
                                                               renderGeneration: retiredGeneration))
    }

    func testSyntheticExpectationPublicationCannotDispatchAfterSynchronousReplacement() async throws {
        for successorPublication in ["none", "same-url", "different-url", "during-clear"] {
            let fixture = makeReaderWebViewHandlerFixture()
            let source = try XCTUnwrap(URL(string: "reader-file://file/load/local/reentrant-dispatch.html"))
            let successorURL = successorPublication == "same-url" ? source
                : try XCTUnwrap(URL(string: "reader-file://file/load/local/successor-dispatch.html"))
            let record = HistoryRecord()
            record.url = source
            record.title = "Reader render fixture"
            record.isReaderModeByDefault = true
            record.isReaderModeAvailable = false
            record.isReaderModeOfferHidden = false
            record.rssContainsFullContent = true
            record.html = "<html><body><p>Source content.</p></body></html>"
            record.updateCompoundKey()
            fixture.readerContent.preloadResolvedContent(record, for: source)
            try await fixture.readerContent.load(url: source)
            let mode = fixture.readerModeViewModel
            mode.navigator = fixture.handler.navigator
            mode.readerLocalHTMLLoader = { _ in record.html }
            mode.readerPublicationDateLoader = { _ in nil }
            mode.swiftReadabilityProcessor = { _, _, _, _ in
                "<html><body><div id='reader-content'>Processed document.</div></body></html>"
            }
            let caller = fixture.handler.scriptCaller
            let originalOwner = UUID()
            let replacementOwner = UUID()
            caller.installBinding(ownedBy: originalOwner, asyncCaller: { _, _, _, _ in .init(nil) },
                                  unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil })
            defer {
                _ = caller.clearBinding(ownedBy: originalOwner)
                _ = caller.clearBinding(ownedBy: replacementOwner)
            }
            var replaced = false
            var publishedSuccessor = false
            let replacementCapture = "Synchronous replacement capture"
            let publication = mode.$expectedSyntheticReaderLoaderURL.sink { expected in
                if expected == nil, successorPublication == "during-clear", replaced, !publishedSuccessor {
                    publishedSuccessor = true
                    mode.beginReaderModeLoad(for: successorURL)
                    mode.expectSyntheticReaderLoaderCommit(for: successorURL)
                    return
                }
                guard expected != nil, !replaced else { return }
                replaced = true
                _ = caller.clearBinding(ownedBy: originalOwner)
                caller.installBinding(ownedBy: replacementOwner, asyncCaller: { _, _, _, _ in .init(nil) },
                                      unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil })
                mode.beginReaderModeLoad(for: source)
                mode.readabilityContent = replacementCapture
                fixture.readerContent.isRenderingReaderHTML = true
                if successorPublication == "same-url" || successorPublication == "different-url" {
                    publishedSuccessor = true
                    mode.beginReaderModeLoad(for: successorURL)
                    mode.expectSyntheticReaderLoaderCommit(for: successorURL)
                }
            }
            defer { publication.cancel() }
            mode.showReaderView(readerContent: fixture.readerContent, scriptCaller: caller)
            let predecessorTask = try XCTUnwrap(mode.readerModeRenderTaskForTesting(for: source))
            let generation = try XCTUnwrap(UUID(uuidString: mode.currentRenderGenerationDescription(for: source)))
            await predecessorTask.value
            XCTAssertTrue(replaced)
            XCTAssertEqual(fixture.handler.navigator.debugLoadSnapshot.lastDataLoadBaseURL, "nil")
            XCTAssertEqual(mode.expectedSyntheticReaderLoaderURL, successorPublication == "none" ? nil : successorURL)
            XCTAssertEqual(mode.loadingState.expectedSyntheticReaderLoaderURL,
                           successorPublication == "none" ? nil : successorURL)
            if successorPublication != "none" {
                XCTAssertTrue(publishedSuccessor)
                XCTAssertTrue(mode.expectsSyntheticReaderLoaderCommit(for: successorURL))
            }
            XCTAssertEqual(mode.currentRenderGenerationDescription(for: source), "nil")
            XCTAssertEqual(mode.readabilityContent, replacementCapture)
            XCTAssertTrue(fixture.readerContent.isRenderingReaderHTML)
            XCTAssertTrue(mode.isReaderModeLoading)
            XCTAssertEqual(mode.pendingReaderModeURL, successorPublication == "none" ? source : successorURL)
            XCTAssertFalse(mode.handleRenderedReaderDocumentReady(pageURL: source, hasReaderContent: true,
                                                                   renderGeneration: generation))
        }
    }

    func testSelfIssuedReaderDocumentRetainsExactReadyGenerationAcrossCommit() async throws {
        let fixture = makeReaderWebViewHandlerFixture()
        fixture.handler.readerViewModel = ReaderCallbackViewModel(
            realmConfiguration: makeReaderCallbackLibraryConfiguration(), systemScripts: []
        )
        let source = try XCTUnwrap(URL(string: "reader-file://file/load/local/self-dispatch.html"))
        let record = HistoryRecord()
        record.url = source
        record.title = "Reader render fixture"
        record.isReaderModeByDefault = true
        record.isReaderModeAvailable = false
        record.isReaderModeOfferHidden = false
        record.rssContainsFullContent = true
        record.html = "<html><body><p>Source content.</p></body></html>"
        record.updateCompoundKey()
        fixture.readerContent.preloadResolvedContent(record, for: source)
        try await fixture.readerContent.load(url: source)
        let mode = fixture.readerModeViewModel
        mode.navigator = fixture.handler.navigator
        mode.readerLocalHTMLLoader = { _ in record.html }
        mode.readerPublicationDateLoader = { _ in nil }
        mode.swiftReadabilityProcessor = { _, _, _, _ in
            "<html><body><div id='reader-content'>Processed document.</div></body></html>"
        }
        let caller = fixture.handler.scriptCaller
        let originalOwner = UUID()
        caller.installBinding(ownedBy: originalOwner,
                              asyncCaller: { _, _, _, _ in .init(nil) },
                              unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil })
        mode.showReaderView(readerContent: fixture.readerContent, scriptCaller: caller)
        await mode.waitForReaderModeRender(for: source)
        XCTAssertEqual(fixture.handler.navigator.debugLoadSnapshot.lastDataLoadBaseURL, source.absoluteString)
        XCTAssertEqual(mode.expectedSyntheticReaderLoaderURL, source)
        let generation = try XCTUnwrap(UUID(uuidString: mode.currentRenderGenerationDescription(for: source)))

        _ = caller.clearBinding(ownedBy: originalOwner)
        let committedOwner = UUID()
        caller.installBinding(ownedBy: committedOwner,
                              asyncCaller: { _, _, _, _ in .init(nil) },
                              unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil })
        defer { _ = caller.clearBinding(ownedBy: committedOwner) }
        var state = WebViewState.empty
        state.pageURL = source
        fixture.handler.onDocumentContextInvalidated(state: state, reason: .navigationCommitted)
        fixture.handler.onNavigationCommitted(state: state)
        try await fixture.taskManager.onNavigationCommittedTask?.value
        XCTAssertNil(mode.expectedSyntheticReaderLoaderURL)
        XCTAssertEqual(mode.currentRenderGenerationDescription(for: source), generation.uuidString)
        XCTAssertFalse(mode.handleRenderedReaderDocumentReady(pageURL: source, hasReaderContent: true,
                                                               renderGeneration: UUID()))
        XCTAssertTrue(mode.handleRenderedReaderDocumentReady(pageURL: source, hasReaderContent: true,
                                                              renderGeneration: generation))
        XCTAssertEqual(mode.lastRenderedURL, source)
        XCTAssertNil(mode.pendingReaderModeURL)
        XCTAssertFalse(mode.isReaderModeLoading)
    }

    func testRenderDeduplicationUsesDocumentBindingAndDispatchesCurrentLocation() async throws {
        for replacesBinding in [false, true] {
            let fixture = makeReaderWebViewHandlerFixture()
            let source = try XCTUnwrap(URL(string: "reader-file://file/load/local/hash-render.html"))
            let record = HistoryRecord()
            record.url = source
            record.title = "Reader render fixture"
            record.isReaderModeByDefault = true
            record.isReaderModeAvailable = false
            record.isReaderModeOfferHidden = false
            record.rssContainsFullContent = true
            record.html = "<html><body><p>Source content.</p></body></html>"
            record.updateCompoundKey()
            fixture.readerContent.preloadResolvedContent(record, for: source)
            try await fixture.readerContent.load(url: source)
            let mode = fixture.readerModeViewModel
            mode.navigator = fixture.handler.navigator
            mode.readerLocalHTMLLoader = { _ in record.html }
            mode.readerPublicationDateLoader = { _ in nil }
            let gate = ReaderCallbackGate()
            let started = expectation(description: "same-binding processing suspended")
            var processingCalls = 0
            mode.swiftReadabilityProcessor = { _, _, _, _ in
                processingCalls += 1
                let ordinal = processingCalls
                if ordinal == 1 {
                    started.fulfill()
                    await gate.wait()
                }
                return "<html><body><div id='reader-content'>Processed document \(ordinal).</div></body></html>"
            }
            let caller = fixture.handler.scriptCaller
            var owner = UUID()
            caller.installBinding(ownedBy: owner, asyncCaller: { _, _, _, _ in .init(nil) },
                                  unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil })
            defer { _ = caller.clearBinding(ownedBy: owner) }
            mode.showReaderView(readerContent: fixture.readerContent, scriptCaller: caller)
            await fulfillment(of: [started], timeout: 1)
            let generation = mode.currentRenderGenerationDescription(for: source)
            let predecessorTask = try XCTUnwrap(mode.readerModeRenderTaskForTesting(for: source))
            let anchor = try XCTUnwrap(URL(string: source.absoluteString + "#next%2Fpart"))
            try await fixture.readerContent.load(url: anchor)
            if replacesBinding {
                _ = caller.clearBinding(ownedBy: owner)
                owner = UUID()
                caller.installBinding(ownedBy: owner, asyncCaller: { _, _, _, _ in .init(nil) },
                                      unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil })
            }
            mode.showReaderView(readerContent: fixture.readerContent, scriptCaller: caller)
            if replacesBinding {
                XCTAssertNotEqual(mode.currentRenderGenerationDescription(for: source), generation)
                // A new render must finish without waiting for retired processing.
                await mode.waitForReaderModeRender(for: source)
                XCTAssertTrue(mode.readabilityContent?.contains("Processed document 2.") == true)
            } else {
                XCTAssertEqual(mode.currentRenderGenerationDescription(for: source), generation)
            }
            await gate.release()
            await predecessorTask.value
            await mode.waitForReaderModeRender(for: source)
            XCTAssertEqual(processingCalls, replacesBinding ? 2 : 1)
            XCTAssertEqual(fixture.handler.navigator.debugLoadSnapshot.lastDataLoadBaseURL, anchor.absoluteString)
        }
    }

    func testSettledReaderAnchorRoundTripPreservesCacheAndSelection() async throws {
        for sourceText in ["https://example.com/article", "https://example.com/article#original"] {
            for usesLoaderTransport in [false, true] {
                let fixture = makeReaderWebViewHandlerFixture()
                fixture.handler.readerViewModel = ReaderCallbackViewModel(
                    realmConfiguration: makeReaderCallbackLibraryConfiguration(), systemScripts: []
                )
                let source = try XCTUnwrap(URL(string: sourceText))
                let transport = usesLoaderTransport
                    ? try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: source)) : source
                let record = HistoryRecord()
                record.url = source
                record.title = "Article"
                record.isReaderModeByDefault = true
                record.updateCompoundKey()
                fixture.readerContent.preloadResolvedContent(record, for: transport)
                try await fixture.readerContent.load(url: transport)
                let selectionID = fixture.readerContent.currentSelectionID
                let mode = fixture.readerModeViewModel
                let html = "<html><body>Canonical reader cache</body></html>"
                mode.isReaderMode = true
                mode.beginReaderModeLoad(for: source)
                mode.readabilityContent = html
                mode.readabilityContainerSelector = "#reader-content"
                mode.markReaderModeLoadComplete(for: source)

                for fragment in ["next", "third", source.fragment] {
                    var parts = try XCTUnwrap(URLComponents(url: transport, resolvingAgainstBaseURL: false))
                    // The source's persisted fragment is inside a loader's query.
                    // Removing the outer fragment returns to that original identity.
                    parts.fragment = usesLoaderTransport && fragment == source.fragment ? nil : fragment
                    var state = WebViewState.empty
                    state.pageURL = try XCTUnwrap(parts.url)
                    state.isLoading = false
                    try await fixture.handler.handleURLChanged(state: state)

                    XCTAssertEqual(mode.readabilityContent, html, "Lost cache returning to \(state.pageURL)")
                    XCTAssertEqual(mode.readabilityContainerSelector, "#reader-content")
                    XCTAssertEqual(mode.lastRenderedURL, source)
                    XCTAssertFalse(mode.isReaderModeLoading)
                    XCTAssertEqual(fixture.readerContent.currentSelectionID, selectionID)
                    XCTAssertTrue(fixture.readerContent.content === record)
                }
            }
        }
    }

    func testRealReplacementAtDifferentAnchorDoesNotInheritReaderCache() async throws {
        for destination in ["https://example.com/article", "https://example.com/article#new-document"] {
            let fixture = makeReaderWebViewHandlerFixture()
            fixture.handler.readerViewModel = ReaderCallbackViewModel(
                realmConfiguration: makeReaderCallbackLibraryConfiguration(), systemScripts: []
            )
            let source = try XCTUnwrap(URL(string: "https://example.com/article"))
            let record = HistoryRecord()
            record.url = source
            record.isReaderModeByDefault = true
            record.updateCompoundKey()
            fixture.readerContent.preloadResolvedContent(record, for: source)
            try await fixture.readerContent.load(url: source)
            let mode = fixture.readerModeViewModel
            mode.isReaderMode = true
            mode.beginReaderModeLoad(for: source)
            mode.readabilityContent = "Old document cache"
            mode.readabilityContainerSelector = "#old-document"
            mode.markReaderModeLoadComplete(for: source)

            var state = WebViewState.empty
            state.pageURL = try XCTUnwrap(URL(string: destination))
            state.isLoading = false
            try await fixture.handler.handleNavigationCommitted(state: state)

            XCTAssertNil(mode.readabilityContent)
            XCTAssertNil(mode.readabilityContainerSelector)
        }
    }

    func testURLChangeToDifferentPathOrQueryDoesNotPreserveReaderCache() async throws {
        for destination in ["https://example.com/other", "https://example.com/article?chapter=2"] {
            let fixture = makeReaderWebViewHandlerFixture()
            fixture.handler.readerViewModel = ReaderCallbackViewModel(
                realmConfiguration: makeReaderCallbackLibraryConfiguration(), systemScripts: []
            )
            let source = try XCTUnwrap(URL(string: "https://example.com/article"))
            let original = HistoryRecord()
            original.url = source
            original.isReaderModeByDefault = true
            original.updateCompoundKey()
            fixture.readerContent.preloadResolvedContent(original, for: source)
            try await fixture.readerContent.load(url: source)
            let mode = fixture.readerModeViewModel
            mode.isReaderMode = true
            mode.beginReaderModeLoad(for: source)
            mode.readabilityContent = "Old document cache"
            mode.readabilityContainerSelector = "#old-document"
            mode.markReaderModeLoadComplete(for: source)

            let target = try XCTUnwrap(URL(string: destination))
            let replacement = HistoryRecord()
            replacement.url = target
            replacement.isReaderModeByDefault = true
            replacement.updateCompoundKey()
            fixture.readerContent.preloadResolvedContent(replacement, for: target)
            var state = WebViewState.empty
            state.pageURL = target
            state.isLoading = false
            try await fixture.handler.handleURLChanged(state: state)

            XCTAssertTrue(fixture.readerContent.content === replacement)
            XCTAssertEqual(fixture.readerContent.pageURL, target)
            XCTAssertNil(mode.readabilityContent)
            XCTAssertNil(mode.readabilityContainerSelector)
        }
    }

    func testDeferredURLChangeCannotAdoptReplacementDocumentBinding() async throws {
        for queuesBehindCommit in [false, true] {
            let fixture = makeReaderWebViewHandlerFixture()
            let gate = ReaderCallbackGate()
            fixture.taskManager.startOnNavigationCommitted { await gate.wait() }
            fixture.taskManager.startOnNavigationFinished {}
            if !queuesBehindCommit {
                await gate.release()
                try await fixture.taskManager.onNavigationFinishedTask?.value
            }
            let source = try XCTUnwrap(URL(string: "https://example.com/article"))
            let record = HistoryRecord()
            record.url = source
            record.updateCompoundKey()
            fixture.readerContent.preloadResolvedContent(record, for: source)
            try await fixture.readerContent.load(url: source)
            fixture.readerContent.isRenderingReaderHTML = true
            let selectionID = fixture.readerContent.currentSelectionID
            let caller = fixture.handler.scriptCaller
            var evaluations = 0
            let oldOwner = UUID()
            caller.installBinding(ownedBy: oldOwner,
                                  asyncCaller: { _, _, _, _ in evaluations += 1; return .init(nil) },
                                  unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil })
            var state = WebViewState.empty
            state.pageURL = try XCTUnwrap(URL(string: source.absoluteString + "#section"))
            fixture.handler.onURLChanged(state: state)
            // Do not suspend: replace the binding before the scheduled task runs.
            _ = caller.clearBinding(ownedBy: oldOwner)
            let newOwner = UUID()
            caller.installBinding(ownedBy: newOwner,
                                  asyncCaller: { _, _, _, _ in evaluations += 1; return .init(nil) },
                                  unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil })
            defer { _ = caller.clearBinding(ownedBy: newOwner) }
            if queuesBehindCommit {
                await gate.release()
                try await fixture.taskManager.onNavigationFinishedTask?.value
            }
            do {
                try await fixture.taskManager.onURLChangedTask?.value
                XCTFail("The old receipt must fail before selecting on the new document")
            } catch is CancellationError { }
            XCTAssertEqual(evaluations, 0)
            XCTAssertEqual(fixture.readerContent.pageURL, source)
            XCTAssertEqual(fixture.readerContent.currentSelectionID, selectionID)
            XCTAssertTrue(fixture.readerContent.isRenderingReaderHTML)
        }
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
