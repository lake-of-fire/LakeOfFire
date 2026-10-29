import XCTest
import SwiftUI
import SwiftSoup
import RealmSwift
#if canImport(UIKit)
import UIKit
#endif
@testable import LakeOfFireCore
@testable import LakeKit
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

private final class ReaderCallbackTraceCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(String, String)] = []

    func record(_ stage: String, _ detail: String) {
        lock.lock()
        defer { lock.unlock() }
        values.append((stage, detail))
    }

    var snapshot: [(String, String)] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@MainActor
private func makeReaderWebViewHandlerFixture() -> (
    handler: ReaderWebViewHandler,
    taskManager: NavigationTaskManager,
    readerContent: ReaderContent,
    readerModeViewModel: ReaderModeViewModel,
    navigator: WebViewNavigator
) {
    var configuration = Realm.Configuration(
        inMemoryIdentifier: "reader-callback-" + UUID().uuidString,
        objectTypes: [LibraryConfiguration.self, UserScript.self, FeedCategory.self]
    )
    configureLakeOfFireMutationTrackingForTesting(&configuration)
    let taskManager = NavigationTaskManager()
    let readerContent = ReaderContent()
    let readerModeViewModel = ReaderModeViewModel()
    let navigator = WebViewNavigator()
    let handler = ReaderWebViewHandler(
        navigationTaskManager: taskManager,
        readerContent: readerContent,
        readerViewModel: ReaderViewModel(realmConfiguration: configuration, systemScripts: []),
        readerModeViewModel: readerModeViewModel,
        readerMediaPlayerViewModel: ReaderMediaPlayerViewModel(),
        scriptCaller: WebViewScriptCaller(),
        navigator: navigator
    )
    return (handler, taskManager, readerContent, readerModeViewModel, navigator)
}

@MainActor
final class ReaderWebViewCallbackContractTests: XCTestCase {
    func testReaderFontSizeInitializationPreservesExistingStringAndFractionalValues() throws {
        let suite = "reader-font-existing-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("17", forKey: "readerFontSize")
        initializeReaderFontSizeIfNeeded(defaults: defaults, defaultFontSize: 161)
        XCTAssertEqual(defaults.string(forKey: "readerFontSize"), "17")
        XCTAssertEqual(readerStoredFontSize(in: defaults), 17)
        defaults.set(17.5, forKey: "readerFontSize")
        initializeReaderFontSizeIfNeeded(defaults: defaults, defaultFontSize: 161)
        XCTAssertEqual(readerStoredFontSize(in: defaults), 17.5)
    }

    func testReaderFontSizeInitializationDoesNotPersistOverRegisteredString() throws {
        let suite = "reader-font-registered-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let registration = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
        defer {
            defaults.removePersistentDomain(forName: suite)
            defaults.setVolatileDomain(registration, forName: UserDefaults.registrationDomain)
        }
        defaults.register(defaults: ["readerFontSize": "17"])
        initializeReaderFontSizeIfNeeded(defaults: defaults, defaultFontSize: 161)
        XCTAssertEqual(readerStoredFontSize(in: defaults), 17)
        XCTAssertNil(defaults.persistentDomain(forName: suite)?["readerFontSize"])
    }

    func testReaderFontSizeDefaultIsInitializedOnlyOnce() throws {
        let suite = "reader-font-default-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(readerStoredFontSize(in: defaults))
        initializeReaderFontSizeIfNeeded(defaults: defaults, defaultFontSize: 21.4)
        XCTAssertEqual(readerStoredFontSize(in: defaults), 21)
        initializeReaderFontSizeIfNeeded(defaults: defaults, defaultFontSize: 161)
        XCTAssertEqual(readerStoredFontSize(in: defaults), 21)
    }

    func testReaderFontSizeReaderRejectsInvalidValuesWithoutChangingPreferences() throws {
        let suite = "reader-font-invalid-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for value in ["invalid", "0", "-1", "nan", "inf"] {
            defaults.set(value, forKey: "readerFontSize")
            XCTAssertNil(readerStoredFontSize(in: defaults))
            XCTAssertEqual(defaults.string(forKey: "readerFontSize"), value)
        }
    }

#if canImport(UIKit)
    func testReaderFontSizeBaseDoesNotScaleTwiceForAccessibilityTraits() {
        var normal: CGFloat = 0
        var accessible: CGFloat = 0
        UITraitCollection(preferredContentSizeCategory: .large).performAsCurrent {
            normal = readerDefaultFontSizeBase()
        }
        UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge).performAsCurrent {
            accessible = readerDefaultFontSizeBase()
        }
        XCTAssertEqual(normal, 21, accuracy: 0.001)
        XCTAssertEqual(accessible, normal, accuracy: 0.001)
    }
#endif

    func testStoredDirectLoadDistinguishesInapplicableAndSupersededWithoutNavigation() async throws {
        let model = ReaderModeViewModel()
        let navigator = WebViewNavigator()
        let content = Bookmark()
        content.url = URL(string: "https://example.com/article")!
        let inapplicable = try await model.loadStoredReaderContentIfPossible(content: content, navigator: navigator)
        XCTAssertEqual(inapplicable, .inapplicable)
        let superseded = try await model.loadStoredReaderContentIfPossible(
            content: content, navigator: navigator, shouldLoad: { false }
        )
        XCTAssertEqual(superseded, .superseded)
        let cancelled = Task { @MainActor in
            try await model.loadStoredReaderContentIfPossible(content: content, navigator: navigator)
        }
        cancelled.cancel()
        let cancelledOutcome = try await cancelled.value
        XCTAssertEqual(cancelledOutcome, .superseded)
        content.isDeleted = true
        let deletedOutcome = try await model.loadStoredReaderContentIfPossible(content: content, navigator: navigator)
        XCTAssertEqual(deletedOutcome, .superseded, "A deleted selection must not dispatch a fallback loader")
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, "nil")
        XCTAssertNil(model.pendingReaderModeURL)
    }

    func testSupersededReaderDocumentIsRepreparedBeforeItsOnlyNavigation() async throws {
        let model = ReaderModeViewModel()
        let source = URL(string: "https://example.com/submission-fence")!
        let html = "<html><body><h1 id='reader-title'>An article</h1><div id='reader-content'><p>Readable content.</p></div></body></html>"
        let bookmark = Bookmark()
        bookmark.url = source
        bookmark.title = "An article"
        bookmark.html = html
        bookmark.rssContainsFullContent = true
        bookmark.isReaderModeByDefault = true
        let readerContent = ReaderContent()
        readerContent.content = bookmark
        readerContent.pageURL = source
        let navigator = WebViewNavigator()
        model.navigator = navigator
        var validations = 0
        model.isPreparedReadabilityContentCurrent = { _ in
            validations += 1
            XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, "nil",
                           "Superseded preparation must not submit a document")
            return validations > 1
        }
        let scriptCaller = WebViewScriptCaller()
        let finished = expectation(description: "prepared document submitted")
        var failure: String?
        defer { model.cancelReaderModeLoad(for: source) }
        model.beginReaderModeLoad(for: source)
        XCTAssertTrue(model.startRenderTaskIfNeeded(for: source) { generation in
            do {
                try await model.showReadabilityContent(
                    readerContent: readerContent, readabilityContent: html,
                    renderToSelector: nil, in: nil,
                    scriptCaller: scriptCaller, navigator: navigator,
                    renderURL: source, renderGeneration: generation
                )
            } catch {
                await MainActor.run { failure = String(describing: error) }
            }
            await MainActor.run { finished.fulfill() }
        })
        await fulfillment(of: [finished], timeout: 30)
        XCTAssertNil(failure)
        XCTAssertEqual(validations, 2)
        XCTAssertTrue(URL(string: navigator.debugLoadSnapshot.lastRequestURL)?.isReaderDocumentURL == true)
        // A commit may consume the expectation before the preparation task's
        // structured bookkeeping finishes. Its installed presentation remains
        // the submission proof during that interval.
        model.expectSyntheticReaderLoaderCommit(for: nil)
        XCTAssertFalse(model.canAdoptDictionaryPublicationDuringPreparation(for: source))
    }

    func testDictionaryPublicationCanBeAdoptedOnlyBeforeReaderSubmission() async throws {
        let model = ReaderModeViewModel()
        let source = URL(string: "https://example.com/preparing-article")!
        let gate = ReaderCallbackGate()
        defer {
            model.cancelReaderModeLoad(for: source)
            Task { await gate.release() }
        }
        model.beginReaderModeLoad(for: source)
        XCTAssertTrue(model.startRenderTaskIfNeeded(for: source) { _ in await gate.wait() })
        XCTAssertFalse(model.canAdoptDictionaryPublicationDuringPreparation(for: source),
                       "An unfenced renderer must retain the normal refresh path")
        model.isPreparedReadabilityContentCurrent = { _ in true }
        XCTAssertTrue(model.canAdoptDictionaryPublicationDuringPreparation(for: source))
        XCTAssertFalse(model.canAdoptDictionaryPublicationDuringPreparation(
            for: URL(string: "https://example.com/another-article")!))
        model.expectSyntheticReaderLoaderCommit(for: ReaderContentLoader.readerDocumentURL(for: source))
        XCTAssertFalse(model.canAdoptDictionaryPublicationDuringPreparation(for: source),
                       "A submitted document must retain the normal refresh path")
        model.cancelReaderModeLoad(for: source)
        XCTAssertFalse(model.canAdoptDictionaryPublicationDuringPreparation(for: source))
    }

    func testStoredRestorePreparationPreservesBlankSuppressionUntilDocumentLoad() async throws {
        let readerContent = ReaderContent()
        let article = Bookmark()
        article.url = URL(string: "https://example.com/stored-restore")!
        let operationID = UUID()
        readerContent.suppressTransientAboutBlank(
            untilNextNonBlankLoad: article.url, operationID: operationID
        )

        try await readerContent.prepareForDisplay(content: article, recordHistoryVisit: false)
        let blankURL = URL(string: "about:blank")!
        let blank = Bookmark()
        blank.url = blankURL
        var blankResolutions = 0
        try await readerContent.load(url: blankURL) { _ in
            blankResolutions += 1
            return blank
        }
        XCTAssertEqual(blankResolutions, 0)
        XCTAssertEqual(readerContent.pageURL, article.url)
        XCTAssertTrue(readerContent.content === article)

        // A real nonblank document callback completes the protected handoff.
        try await readerContent.load(url: article.url) { _ in article }
        try await readerContent.load(url: blankURL) { _ in
            blankResolutions += 1
            return blank
        }
        XCTAssertEqual(blankResolutions, 1)
        XCTAssertEqual(readerContent.pageURL, blankURL)
    }

    func testExplicitHomeCanCancelPreparedStoredRestore() async throws {
        let readerContent = ReaderContent()
        let article = Bookmark()
        article.url = URL(string: "https://example.com/cancel-stored-restore")!
        let operationID = UUID()
        readerContent.suppressTransientAboutBlank(
            untilNextNonBlankLoad: article.url, operationID: operationID
        )
        try await readerContent.prepareForDisplay(content: article, recordHistoryVisit: false)
        readerContent.releaseTransientAboutBlankSuppression(ifOwnedBy: operationID)

        let blank = Bookmark()
        blank.url = URL(string: "about:blank")!
        try await readerContent.load(url: blank.url) { _ in blank }
        XCTAssertEqual(readerContent.pageURL, blank.url)
        XCTAssertTrue(readerContent.content === blank)
    }

    func testCurrentRestoreCanReleaseSuppressionBeforeExplicitBlankSelection() async throws {
        let readerContent = ReaderContent()
        let articleURL = URL(string: "https://example.com/pending-restore")!
        let article = Bookmark()
        article.url = articleURL
        readerContent.content = article
        readerContent.pageURL = articleURL
        let operationID = UUID()
        readerContent.suppressTransientAboutBlank(
            untilNextNonBlankLoad: articleURL, operationID: operationID
        )
        readerContent.releaseTransientAboutBlankSuppression(ifOwnedBy: operationID)
        let blankURL = URL(string: "about:blank")!
        let blank = Bookmark()
        blank.url = blankURL
        var resolutions = 0
        try await readerContent.load(url: blankURL) { requestedURL in
            XCTAssertEqual(requestedURL, blankURL)
            resolutions += 1
            return blank
        }
        XCTAssertEqual(resolutions, 1)
        XCTAssertEqual(readerContent.pageURL, blankURL)
        XCTAssertEqual(readerContent.content?.url, blankURL)
    }

    func testRetiredSameURLRestoreCannotReleaseSuccessorBlankSuppression() async throws {
        let readerContent = ReaderContent()
        let articleURL = URL(string: "https://example.com/same-url-restore")!
        let article = Bookmark()
        article.url = articleURL
        readerContent.content = article
        readerContent.pageURL = articleURL
        let oldOperation = UUID()
        let successorOperation = UUID()
        readerContent.suppressTransientAboutBlank(
            untilNextNonBlankLoad: articleURL, operationID: oldOperation
        )
        readerContent.suppressTransientAboutBlank(
            untilNextNonBlankLoad: articleURL, operationID: successorOperation
        )
        readerContent.releaseTransientAboutBlankSuppression(ifOwnedBy: oldOperation)
        let blankURL = URL(string: "about:blank")!
        let blank = Bookmark()
        blank.url = blankURL
        var resolutions = 0
        try await readerContent.load(url: blankURL) { _ in
            resolutions += 1
            return blank
        }
        XCTAssertEqual(resolutions, 0)
        XCTAssertEqual(readerContent.pageURL, articleURL)
        readerContent.releaseTransientAboutBlankSuppression(ifOwnedBy: successorOperation)
        try await readerContent.load(url: blankURL) { _ in
            resolutions += 1
            return blank
        }
        XCTAssertEqual(resolutions, 1)
        XCTAssertEqual(readerContent.pageURL, blankURL)
    }

    func testNonBlankSelectionConsumesRestoreSuppressionNormally() async throws {
        let readerContent = ReaderContent()
        let articleURL = URL(string: "https://example.com/finished-restore")!
        let article = Bookmark()
        article.url = articleURL
        readerContent.suppressTransientAboutBlank(
            untilNextNonBlankLoad: articleURL, operationID: UUID()
        )
        try await readerContent.load(url: articleURL) { _ in article }
        let blankURL = URL(string: "about:blank")!
        let blank = Bookmark()
        blank.url = blankURL
        var resolutions = 0
        try await readerContent.load(url: blankURL) { _ in
            resolutions += 1
            return blank
        }
        XCTAssertEqual(resolutions, 1)
        XCTAssertEqual(readerContent.pageURL, blankURL)
    }

    func testQueuedReaderRequestRejectsIntermediateBlankCallbacksBeforeScheduling() async throws {
        let fixture = makeReaderWebViewHandlerFixture()
        let url = URL(string: "https://example.com/reloading-article")!
        let loaderURL = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: url))
        let content = Bookmark()
        content.url = url
        fixture.readerContent.content = content
        fixture.readerContent.pageURL = url
        fixture.readerContent.isRenderingReaderHTML = true
        fixture.readerModeViewModel.beginReaderModeLoad(for: url)
        fixture.readerModeViewModel.readabilityContent = "<article>Current article</article>"
        var publicCallbacks = 0
        fixture.handler.onNavigationCommitted = { _ in publicCallbacks += 1 }
        fixture.handler.onNavigationFinished = { _ in publicCallbacks += 1 }
        fixture.handler.onURLChanged = { _ in publicCallbacks += 1 }
        defer {
            fixture.taskManager.cancelNavigationWork()
            fixture.readerModeViewModel.cancelReaderModeLoad()
        }
        fixture.navigator.load(URLRequest(url: loaderURL))
        XCTAssertTrue(fixture.navigator.hasPendingInternalReaderRequest)
        fixture.handler.onDocumentContextInvalidated(state: .empty, reason: .navigationCommitted)
        fixture.handler.onNavigationCommitted(state: .empty)
        fixture.handler.onURLChanged(state: .empty)
        fixture.handler.onNavigationFinished(state: .empty)
        XCTAssertNil(fixture.taskManager.onNavigationCommittedTask)
        XCTAssertNil(fixture.taskManager.onURLChangedTask)
        XCTAssertNil(fixture.taskManager.onNavigationFinishedTask)
        XCTAssertEqual(publicCallbacks, 0)
        XCTAssertEqual(fixture.readerContent.pageURL, url)
        XCTAssertTrue(fixture.readerContent.isRenderingReaderHTML)
        XCTAssertTrue(fixture.readerModeViewModel.isReaderModeLoadPending(for: url))
        XCTAssertEqual(fixture.readerModeViewModel.readabilityContent, "<article>Current article</article>")
        var targetState = WebViewState.empty
        targetState.pageURL = url
        fixture.handler.onNavigationCommitted(state: targetState)
        let targetCommit = try XCTUnwrap(fixture.taskManager.onNavigationCommittedTask)
        try await targetCommit.value
        XCTAssertEqual(publicCallbacks, 1,
                       "The queued target's real commit must retain normal semantic delivery")
    }

    func testExplicitBlankSupersedesQueuedReaderRequestAndCommitsNormally() async throws {
        let fixture = makeReaderWebViewHandlerFixture()
        let blankURL = URL(string: "about:blank")!
        let content = Bookmark()
        content.url = blankURL
        fixture.readerContent.content = content
        fixture.readerContent.pageURL = blankURL
        fixture.readerContent.isRenderingReaderHTML = true
        fixture.readerModeViewModel.readabilityContent = "<article>Retired article</article>"
        var publicCommits = 0
        fixture.handler.onNavigationCommitted = { _ in publicCommits += 1 }
        defer { fixture.taskManager.cancelNavigationWork() }
        let loaderURL = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(
            for: URL(string: "https://example.com/retired-request")!
        ))
        fixture.navigator.load(URLRequest(url: loaderURL))
        XCTAssertTrue(fixture.navigator.hasPendingInternalReaderRequest)
        fixture.navigator.load(URLRequest(url: blankURL))
        XCTAssertFalse(fixture.navigator.hasPendingInternalReaderRequest)
        fixture.handler.onNavigationCommitted(state: .empty)
        let commit = try XCTUnwrap(fixture.taskManager.onNavigationCommittedTask)
        try await commit.value
        XCTAssertEqual(publicCommits, 1)
        XCTAssertFalse(fixture.readerContent.isRenderingReaderHTML)
        XCTAssertNil(fixture.readerModeViewModel.readabilityContent)
    }

    func testSupersededSameURLRenderCannotSettleReplacementReadiness() async throws {
        let viewModel = ReaderModeViewModel()
        let url = URL(string: "https://example.com/news/same-url-replacement")!
        let oldGate = ReaderCallbackGate()
        let replacementGate = ReaderCallbackGate()
        let oldOperationReturned = expectation(description: "retired render operation resumed")
        defer {
            viewModel.cancelReaderModeLoad(for: url)
            Task {
                await oldGate.release()
                await replacementGate.release()
            }
        }
        viewModel.beginReaderModeLoad(for: url)
        XCTAssertTrue(viewModel.startRenderTaskIfNeeded(for: url) { _ in
            await oldGate.wait()
            oldOperationReturned.fulfill()
        })
        let oldGeneration = try XCTUnwrap(UUID(uuidString:
            viewModel.currentRenderGenerationDescription(for: url)))
        XCTAssertTrue(viewModel.handleRenderedReaderDocumentReady(
            pageURL: url, hasReaderContent: true, renderGeneration: oldGeneration))

        viewModel.cancelReaderModeLoad(for: url)
        viewModel.beginReaderModeLoad(for: url)
        XCTAssertTrue(viewModel.startRenderTaskIfNeeded(for: url) { _ in
            await replacementGate.wait()
        })
        let replacementGeneration = try XCTUnwrap(UUID(uuidString:
            viewModel.currentRenderGenerationDescription(for: url)))
        XCTAssertNotEqual(oldGeneration, replacementGeneration)
        var completions = [URL]()
        viewModel.readerModeLoadCompletionHandler = { completions.append($0) }

        await oldGate.release()
        await fulfillment(of: [oldOperationReturned], timeout: 1)
        XCTAssertFalse(viewModel.handleRenderedReaderDocumentReady(
            pageURL: url, hasReaderContent: true, renderGeneration: oldGeneration))
        XCTAssertFalse(viewModel.handleRenderedReaderDocumentReady(
            pageURL: url, hasReaderContent: true))
        XCTAssertTrue(viewModel.isReaderModeLoadPending(for: url))
        XCTAssertTrue(viewModel.isReaderModeLoading)
        XCTAssertNil(viewModel.lastRenderedURL)
        XCTAssertTrue(completions.isEmpty)
        XCTAssertEqual(viewModel.currentRenderGenerationDescription(for: url),
                       replacementGeneration.uuidString)

        XCTAssertTrue(viewModel.handleRenderedReaderDocumentReady(
            pageURL: url, hasReaderContent: true, renderGeneration: replacementGeneration))
        XCTAssertFalse(viewModel.isReaderModeLoadPending(for: url))
        XCTAssertFalse(viewModel.isReaderModeLoading)
        XCTAssertEqual(completions, [url])
        XCTAssertFalse(viewModel.handleRenderedReaderDocumentReady(
            pageURL: url, hasReaderContent: true, renderGeneration: oldGeneration))
        XCTAssertEqual(completions, [url])
    }

    func testOriginalHTMLFallbackRetiresGeneratedReadinessWait() async throws {
        let fixture = makeReaderWebViewHandlerFixture()
        let viewModel = fixture.readerModeViewModel
        let url = URL(string: "https://example.com/news/unextractable")!
        let gate = ReaderCallbackGate()
        defer { Task { await gate.release() } }
        let savedArticle = Bookmark()
        savedArticle.url = url
        savedArticle.isReaderModeByDefault = true
        fixture.readerContent.content = savedArticle
        fixture.readerContent.pageURL = url
        fixture.readerContent.isRenderingReaderHTML = true
        viewModel.beginReaderModeLoad(for: url)
        XCTAssertTrue(viewModel.startRenderTaskIfNeeded(for: url) { _ in
            await gate.wait()
        })
        let generation = try XCTUnwrap(UUID(uuidString:
            viewModel.currentRenderGenerationDescription(for: url)))
        let html = "<html><body><p>Original page</p></body></html>"
        XCTAssertFalse(viewModel.loadOriginalHTMLAfterReaderModeExtractionFailed(
            html, for: url, generation: UUID(),
            readerContent: fixture.readerContent, navigator: WebViewNavigator()))
        XCTAssertTrue(viewModel.isReaderModeLoadPending(for: url))
        XCTAssertTrue(fixture.readerContent.isRenderingReaderHTML)
        XCTAssertTrue(viewModel.loadOriginalHTMLAfterReaderModeExtractionFailed(
            html, for: url, generation: generation,
            readerContent: fixture.readerContent, navigator: WebViewNavigator()))
        XCTAssertFalse(viewModel.isReaderModeLoadPending(for: url))
        XCTAssertFalse(viewModel.isReaderModeLoading)
        XCTAssertFalse(fixture.readerContent.isRenderingReaderHTML)
        XCTAssertNil(viewModel.lastRenderedURL)
        XCTAssertTrue(viewModel.loadingState.isShowingOriginalHTMLFallback(for: url))
        XCTAssertFalse(viewModel.loadingState.isShowingOriginalHTMLFallback(
            for: URL(string: "https://example.com/news/other")!))
        XCTAssertFalse(viewModel.loadingState.isShowingOriginalHTMLFallback(
            for: try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: url))))
        XCTAssertFalse(viewModel.handleRenderedReaderDocumentReady(
            pageURL: url, hasReaderContent: true, renderGeneration: generation))
        await gate.release()
        var state = WebViewState.empty
        state.pageURL = url
        try await viewModel.onNavigationCommitted(
            readerContent: fixture.readerContent,
            newState: state,
            scriptCaller: WebViewScriptCaller(),
            navigator: WebViewNavigator())
        XCTAssertFalse(viewModel.isReaderMode,
                       "Saved Reader preference must not reenable loading for an original-HTML fallback")
        await viewModel.onNavigationFinished(newState: state, scriptCaller: WebViewScriptCaller())
        XCTAssertFalse(viewModel.isReaderModeLoading)
        XCTAssertTrue(viewModel.loadingState.isShowingOriginalHTMLFallback(for: url))
        viewModel.beginReaderModeLoad(for: url)
        XCTAssertFalse(viewModel.loadingState.isShowingOriginalHTMLFallback(for: url),
                       "A fresh Reader request must require its own readiness again")
    }

    func testCurrentRenderGenerationRecoversAfterEmptyCompletionClearedPendingURL() async throws {
        let viewModel = ReaderModeViewModel()
        let url = URL(string: "https://example.com/news/recovered-restore")!
        let gate = ReaderCallbackGate()
        defer { Task { await gate.release() } }
        viewModel.beginReaderModeLoad(for: url)
        XCTAssertTrue(viewModel.startRenderTaskIfNeeded(for: url) { _ in
            await gate.wait()
        })
        let generation = try XCTUnwrap(UUID(uuidString:
            viewModel.currentRenderGenerationDescription(for: url)))
        // Reproduce the old empty-buffer path's partially settled state.
        viewModel.markReaderModeLoadComplete(for: url)
        XCTAssertFalse(viewModel.isReaderModeLoadPending(for: url))
        XCTAssertNil(viewModel.lastRenderedURL)
        XCTAssertFalse(viewModel.handleRenderedReaderDocumentReady(
            pageURL: url, hasReaderContent: true, renderGeneration: UUID()))
        XCTAssertFalse(viewModel.handleRenderedReaderDocumentReady(
            pageURL: URL(string: "https://example.com/news/other")!,
            hasReaderContent: true, renderGeneration: generation))
        XCTAssertTrue(viewModel.handleRenderedReaderDocumentReady(
            pageURL: url, hasReaderContent: true, renderGeneration: generation))
        XCTAssertEqual(viewModel.lastRenderedURL, url)
    }

    func testGeneratedArticleFinishWaitsForReadinessAfterRawBufferWasCleared() async throws {
        let viewModel = ReaderModeViewModel()
        let url = URL(string: "https://example.com/news/cold-restore")!
        let gate = ReaderCallbackGate()
        defer { Task { await gate.release() } }
        viewModel.beginReaderModeLoad(for: url)
        XCTAssertTrue(viewModel.startRenderTaskIfNeeded(for: url) { _ in
            await gate.wait()
        })
        let generation = try XCTUnwrap(UUID(uuidString:
            viewModel.currentRenderGenerationDescription(for: url)))
        var state = WebViewState.empty
        state.pageURL = url
        await viewModel.onNavigationFinished(newState: state, scriptCaller: WebViewScriptCaller())
        XCTAssertTrue(viewModel.isReaderModeLoadPending(for: url),
                      "Navigation finish must not consume a generated article's readiness owner")
        XCTAssertFalse(viewModel.handleRenderedReaderDocumentReady(
            pageURL: url, hasReaderContent: true, renderGeneration: UUID()))
        XCTAssertTrue(viewModel.handleRenderedReaderDocumentReady(
            pageURL: url, hasReaderContent: true, renderGeneration: generation))
        XCTAssertFalse(viewModel.isReaderModeLoadPending(for: url))
        XCTAssertFalse(viewModel.isReaderModeLoading)
        XCTAssertEqual(viewModel.lastRenderedURL, url,
                       "An empty temporary HTML buffer must not discard validated completion")
        XCTAssertTrue(viewModel.handleRenderedReaderDocumentReady(
            pageURL: url, hasReaderContent: true, renderGeneration: generation),
                      "Foreground replay of the same completed document must remain admissible")
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


extension ReaderWebViewCallbackContractTests {
#if DEBUG
    func testSyntheticArticleLoadDeclinesUnusableStoredHTMLWithoutChangingItsReadability() {
        for (urlString, html) in [
            ("https://example.com/empty-reader", " \n\t "),
            ("https://hypebeast.com/stale-reader", "<html><body class=\"readability-mode\"><div id=\"reader-content\">Stale captured article</div></body></html>"),
        ] {
            let model = ReaderModeViewModel()
            let navigator = WebViewNavigator()
            model.navigator = navigator
            let content = Bookmark()
            content.url = URL(string: urlString)!
            content.isReaderModeByDefault = true
            content.rssContainsFullContent = true
            content.html = html
            let readerContent = ReaderContent()
            readerContent.content = content
            readerContent.pageURL = content.url
            model.readabilityContent = "Mounted source"

            XCTAssertFalse(model.beginSyntheticLoadForCurrentContentIfPossible(
                readerContent: readerContent, scriptCaller: WebViewScriptCaller()), urlString)
            XCTAssertEqual(model.readabilityContent, "Mounted source")
            XCTAssertFalse(model.isReaderModeLoading)
            XCTAssertNil(model.pendingReaderModeURL)
            XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL, "nil")
            XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, "nil")
        }
    }

    func testCancelledSyntheticArticleIntentDoesNotStartAnIndependentRender() async {
        let model = ReaderModeViewModel()
        let navigator = WebViewNavigator()
        model.navigator = navigator
        let content = Bookmark()
        content.url = URL(string: "https://example.com/cancelled-stored-article")!
        content.isReaderModeByDefault = true
        content.rssContainsFullContent = true
        content.html = "<html><body class=\"readability-mode\"><div id=\"reader-content\">保存した記事</div></body></html>"
        let readerContent = ReaderContent()
        readerContent.content = content
        readerContent.pageURL = content.url
        model.readabilityContent = "Existing source"
        let task = Task { @MainActor in
            model.beginSyntheticLoadForCurrentContentIfPossible(
                readerContent: readerContent, scriptCaller: WebViewScriptCaller())
        }
        task.cancel()
        let started = await task.value

        XCTAssertFalse(started)
        XCTAssertEqual(model.readabilityContent, "Existing source")
        XCTAssertFalse(model.isReaderModeLoading)
        XCTAssertNil(model.pendingReaderModeURL)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL, "nil")
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, "nil")
    }

    func testSyntheticArticleLoadDeclinesAnUnstoredPageWithoutChangingItsReadability() {
        let model = ReaderModeViewModel()
        let navigator = WebViewNavigator()
        model.navigator = navigator
        let content = Bookmark()
        content.url = URL(string: "https://example.com/original-page")!
        content.isReaderModeByDefault = true
        let readerContent = ReaderContent()
        readerContent.content = content
        readerContent.pageURL = content.url
        model.readabilityContent = "Mounted original page"

        let started = model.beginSyntheticLoadForCurrentContentIfPossible(
            readerContent: readerContent, scriptCaller: WebViewScriptCaller())

        XCTAssertFalse(started)
        XCTAssertEqual(model.readabilityContent, "Mounted original page")
        XCTAssertFalse(model.isReaderModeLoading)
        XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL, "nil")
        XCTAssertEqual(navigator.debugLoadSnapshot.lastRequestURL, "nil")
    }

    func testStoredArticleRendersWithoutAnIntermediateLoaderNavigation() async throws {
        let model = ReaderModeViewModel()
        let navigator = WebViewNavigator()
        model.navigator = navigator
        let content = Bookmark()
        let url = URL(string: "https://example.com/stored-direct-reader")!
        content.url = url
        content.title = "Stored article"
        content.isReaderModeByDefault = true
        content.isReaderModeAvailable = false
        content.isReaderModeOfferHidden = false
        content.rssContainsFullContent = true
        content.html = "<html><body class=\"readability-mode\"><div id=\"reader-content\"><article><p>保存した記事を読みます。</p></article></div></body></html>"
        let readerContent = ReaderContent()
        readerContent.preloadResolvedContent(content, for: url)
        try await readerContent.prepareForDisplay(url: url)
        readerContent.suppressTransientAboutBlank(untilNextNonBlankLoad: url)
        model.readabilityContent = "<article>Obsolete cached article</article>"
        model.readabilityContainerSelector = "#obsolete-frame-container"
        let processed = ReaderCallbackTraceCapture()
        model.processReadabilityContent = { html, _, _, _, _, _, preprocess in
            processed.record("processed", html)
            return try await preprocess(SwiftSoup.parse(html))
        }
        model.processHTMLBytes = { bytes, _ in bytes }
        defer { model.cancelReaderModeLoad() }
        let returned = expectation(description: "stored article final HTML prepared")
        let started = ReaderLoadTrace.$eventObserver.withValue({ stage, _ in
            if stage == "readerMode.renderTaskReturned" { returned.fulfill() }
        }) {
            model.beginSyntheticLoadForCurrentContentIfPossible(
                readerContent: readerContent, scriptCaller: WebViewScriptCaller())
        }
        XCTAssertTrue(started)
        await fulfillment(of: [returned], timeout: 10)

        XCTAssertTrue(processed.snapshot.contains { $0.1.contains("保存した記事を読みます。") })
        XCTAssertFalse(processed.snapshot.contains { $0.1.contains("Obsolete cached article") })
        XCTAssertNil(model.readabilityContainerSelector)
        let finalURL = try XCTUnwrap(URL(string: navigator.debugLoadSnapshot.lastRequestURL))
        XCTAssertTrue(finalURL.isReaderDocumentURL, "Stored processing must issue only its prepared final-document route")
        XCTAssertTrue(finalURL.matchesReaderURL(url))
        XCTAssertNotNil(ReaderDocumentResourceRegistry.shared.document(at: finalURL))
        XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL, "nil")
        XCTAssertTrue(model.isReaderModeLoading,
                      "Preparing final HTML does not prove that WebKit rendered it")
        let generation = try XCTUnwrap(UUID(uuidString: model.currentRenderGenerationDescription(for: url)))
        XCTAssertFalse(model.handleRenderedReaderDocumentReady(
            pageURL: finalURL, hasReaderContent: true, renderGeneration: UUID()))
        XCTAssertTrue(model.isReaderModeLoading)
        XCTAssertTrue(model.handleRenderedReaderDocumentReady(
            pageURL: finalURL, hasReaderContent: true, renderGeneration: generation))
        XCTAssertFalse(model.isReaderModeLoading)
    }
#endif

    func testRecentEmailLogExportKeepsNewestLaunchAcrossRotation() {
        let archivedLog = "older-launch-start " + String(repeating: "古", count: 1_000)
        let currentLog = "latest-launch 診断"
        let text = recentLogsText(from: [archivedLog, currentLog], byteLimit: 37)
        let heading = "Logs truncated to the most recent 1 MiB for email.\n\n"
        XCTAssertTrue(text.hasPrefix(heading))
        let body = String(text.dropFirst(heading.count))
        XCTAssertTrue(body.hasSuffix(currentLog), "The newest launch must survive the email size limit")
        XCTAssertFalse(body.contains("older-launch-start"))
        XCTAssertFalse(body.contains("\u{FFFD}"))
        XCTAssertLessThanOrEqual(body.utf8.count, 37)
        XCTAssertEqual(recentLogsText(from: [currentLog], byteLimit: 0), "")
    }

    func testLoadingDiagnosticsFilterRejectsProductionAndMissingReceipts() {
        XCTAssertTrue(ReaderLoadTrace.permitsDiagnostics(
            isDevelopmentBuild: false, receiptFilename: "sandboxReceipt"))
        XCTAssertFalse(ReaderLoadTrace.permitsDiagnostics(
            isDevelopmentBuild: false, receiptFilename: "receipt"))
        XCTAssertFalse(ReaderLoadTrace.permitsDiagnostics(
            isDevelopmentBuild: false, receiptFilename: nil))
        XCTAssertFalse(ReaderLoadTrace.permitsDiagnostics(
            isDevelopmentBuild: false, receiptFilename: "unknown"))
        XCTAssertTrue(ReaderLoadTrace.permitsDiagnostics(
            isDevelopmentBuild: true, receiptFilename: nil))
    }

    func testLoadingMilestonesSurviveIntoInAppLogExportWithoutProfilerObserver() async throws {
#if DEBUG
        let isDevelopmentBuild = true
#else
        let isDevelopmentBuild = false
#endif
        let diagnosticsPermitted = ReaderLoadTrace.permitsDiagnostics(
            isDevelopmentBuild: isDevelopmentBuild,
            receiptFilename: Bundle.main.appStoreReceiptURL?.lastPathComponent)
        let operation = UUID()
        let diagnosticWaitStages = [
            "app.coreConstruction",
            "reader.initialLocalMigration", "reader.initialLocalAsset",
            "readerMode.resolveRoute", "processor.refreshDictionaries", "processor.awaitActivation",
            "processor.analysisSession", "processor.cacheRead", "processor.parse", "processor.textAnalysis",
            "bridge.settingsSubscription", "bridge.settingsFont",
            "processor.trackingStatuses", "bridge.readerInitializing",
            "reader.documentPreparation", "reader.documentDelivery", "readerMode.navigationSubmission", "reader.assetRequest", "reader.embedServerStartup",
            "reader.sheetTabSelection", "reader.sheetDismissal",
            "reader.viewModelConstruction", "reader.mediaModelConstruction",
            "reader.viewModelFactory", "reader.readerModeFactory", "reader.scriptSnapshot",
            "processor.semanticPreparation",
            "maintenance.sentenceGraphRepair",
        ]
        let fixture = makeReaderWebViewHandlerFixture()
        let privateURL = "https://example.com/private-diagnostic-content"
        var failedState = WebViewState.empty
        failedState.error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                                    userInfo: [NSURLErrorFailingURLStringErrorKey: privateURL])
        try await ReaderLoadTrace.$operationID.withValue(operation) {
            XCTAssertEqual(ReaderLoadTrace.isRecording("processor.candidateProfile"), diagnosticsPermitted)
            ReaderLoadTrace.event("loading.applied", "loading=true reason=japaneseTextProcessing")
            for step in ["environmentConfigured", "restoreChecked", "boundariesInstalled"] {
                ReaderLoadTrace.event("app.coreInitializationStep", "step=\(step)")
            }
            ReaderLoadTrace.event("webview.construction", "step=webView elapsed_ms=1.250")
            for phase in ["verifiedArtifact", "publicationStarted", "publicationApplied", "stateRead"] {
                ReaderLoadTrace.event("reader.initialLocalAssetStep", "step=jmdict phase=\(phase)")
            }
            ReaderLoadTrace.event("restore.initialTaskScheduled")
            ReaderLoadTrace.event("reader.containerAppeared")
            ReaderLoadTrace.event("processor.candidateProfile", "normalizationCalls=12 normalizationMs=40 semanticSelectionMs=20")
            ReaderLoadTrace.event("processor.semanticEvidenceProfile", "requests=12 identityMs=10 backendMs=5")
            ReaderLoadTrace.event("processor.textAnalysisProgress", "completedNodes=64 totalNodes=512 exactEvidenceCalls=2 elapsedMs=2000")
            ReaderLoadTrace.event("processor.htmlInjectionCache", "result=hit layer=file")
            ReaderLoadTrace.$attempt.withValue(2) { ReaderLoadTrace.event("processor.attempt") }
            ReaderLoadTrace.event("restore.dispatchRetrySkipped", "reason=navigatorHandlingRequest")
            ReaderLoadTrace.event("reader.documentReconstructionRequested")
            ReaderLoadTrace.event("webview.readerNavigationPolicy")
            ReaderLoadTrace.event("readerMode.navigationMainQueueTurn")
            ReaderLoadTrace.event("reader.sheetDetentSelection", "detent=compact selected=nil accessoryPathCount=0")
            for _ in 0..<2 {
                let span = ReaderLoadTrace.begin("bridge.initializeTracking")
                XCTAssertEqual(span != nil, diagnosticsPermitted)
                span?.end("cancelled=true")
            }
            for stage in diagnosticWaitStages {
                let span = ReaderLoadTrace.begin(stage)
                XCTAssertEqual(span != nil, diagnosticsPermitted, stage)
                span?.end()
            }
            fixture.handler.onNavigationFailed(state: failedState, disposition: .preservedCommittedDocument)
            try await fixture.taskManager.onNavigationFailedTask?.value
            fixture.handler.onDocumentContextInvalidated(state: failedState, reason: .webContentProcessTerminated)
            fixture.handler.onDocumentContextInvalidated(state: failedState, reason: .webViewDetached)
        }

        // This is the production export path, including its file-queue flush.
        let export = LoggingViewModel()
        await export.load()
        let logs = try XCTUnwrap(export.logsText)
        let ownRecords = logs.split(whereSeparator: \.isNewline).filter { $0.contains(operation.uuidString) }
        if diagnosticsPermitted {
            for step in ["environmentConfigured", "restoreChecked", "boundariesInstalled"] {
                XCTAssertTrue(ownRecords.contains {
                    $0.contains("event stage=app.coreInitializationStep ") && $0.contains("step=\(step)")
                }, step)
            }
            XCTAssertTrue(ownRecords.contains { $0.contains("event stage=processor.candidateProfile") && $0.contains("normalizationCalls=12") && $0.contains("semanticSelectionMs=20") })
            XCTAssertTrue(ownRecords.contains { $0.contains("event stage=processor.semanticEvidenceProfile") && $0.contains("identityMs=10") && $0.contains("backendMs=5") })
            XCTAssertTrue(ownRecords.contains { $0.contains("event stage=loading.applied") })
            for phase in ["verifiedArtifact", "publicationStarted", "publicationApplied", "stateRead"] {
                XCTAssertTrue(ownRecords.contains {
                    $0.contains("event stage=reader.initialLocalAssetStep")
                        && $0.contains("step=jmdict phase=\(phase)")
                }, phase)
            }
            for stage in ["restore.initialTaskScheduled", "reader.containerAppeared"] {
                XCTAssertTrue(ownRecords.contains { $0.contains("event stage=\(stage) ") }, stage)
            }
            XCTAssertTrue(ownRecords.contains {
                $0.contains("event stage=webview.construction")
                    && $0.contains("step=webView elapsed_ms=1.250")
            })
            XCTAssertTrue(ownRecords.contains { $0.contains("event stage=processor.textAnalysisProgress") && $0.contains("completedNodes=64") })
            XCTAssertTrue(ownRecords.contains { $0.contains("event stage=processor.htmlInjectionCache") && $0.contains("layer=file") })
            XCTAssertTrue(ownRecords.contains {
                $0.contains("event stage=processor.attempt") && $0.contains("attempt=2")
            })
            XCTAssertTrue(ownRecords.contains {
                $0.contains("event stage=restore.dispatchRetrySkipped")
                    && $0.contains("reason=navigatorHandlingRequest")
            })
            XCTAssertTrue(ownRecords.contains {
                $0.contains("event stage=reader.sheetDetentSelection")
                    && $0.contains("detent=compact selected=nil accessoryPathCount=0")
            })
            XCTAssertTrue(ownRecords.contains {
                $0.contains("event stage=reader.documentReconstructionRequested")
            })
            XCTAssertTrue(ownRecords.contains {
                $0.contains("event stage=webview.readerNavigationPolicy")
            })
            XCTAssertTrue(ownRecords.contains {
                $0.contains("event stage=readerMode.navigationMainQueueTurn")
            })
            for stage in diagnosticWaitStages {
                XCTAssertTrue(ownRecords.contains { $0.contains("begin stage=\(stage) ") }, stage)
                XCTAssertTrue(ownRecords.contains { $0.contains("end stage=\(stage) ") }, stage)
            }
            XCTAssertTrue(ownRecords.contains {
                $0.contains("stage=webview.navigationFailed")
                    && $0.contains("disposition=preservedCommittedDocument")
                    && $0.contains("errorCode=\(NSURLErrorTimedOut)")
            })
            for reason in ["webContentProcessTerminated", "webViewDetached"] {
                XCTAssertTrue(ownRecords.contains {
                    $0.contains("stage=webview.documentContextInvalidated") && $0.contains("reason=\(reason)")
                })
            }
            XCTAssertFalse(ownRecords.contains { $0.contains(privateURL) })
            let begins = ownRecords.filter { $0.contains("begin stage=bridge.initializeTracking") }
            let ends = ownRecords.filter { $0.contains("end stage=bridge.initializeTracking") }
            let beginIDs = begins.compactMap { $0.split(separator: " ").first { $0.hasPrefix("span=") } }
            let endIDs = ends.compactMap { $0.split(separator: " ").first { $0.hasPrefix("span=") } }
            XCTAssertEqual(beginIDs.count, 2, ownRecords.joined(separator: "\n"))
            XCTAssertEqual(Set(beginIDs).count, 2, "Unprofiled spans need independent persisted identities")
            XCTAssertEqual(Set(endIDs), Set(beginIDs), "Every exported interval must retain its own identity")
            XCTAssertEqual(endIDs.count, 2)
            XCTAssertTrue(ownRecords.allSatisfy {
                $0.contains("launch=") && $0.contains("build=") && $0.contains("uptime_ms=")
            })
        } else {
            XCTAssertTrue(ownRecords.isEmpty, "App Store diagnostics must stay disabled in exported logs")
        }
        XCTAssertNotNil(export.logsZIPArchive)
    }

    func testDuplicateReaderRequestPreservesReadyStateWhileRenderTaskUnwinds() async throws {
        let model = ReaderModeViewModel()
        let url = URL(string: "https://example.com/ready-active-render")!
        let content = Bookmark()
        content.url = url
        let readerContent = ReaderContent()
        readerContent.content = content
        readerContent.pageURL = url
        let navigator = WebViewNavigator()
        model.navigator = navigator
        let gate = ReaderCallbackGate()
        defer {
            model.cancelReaderModeLoad(for: url)
            Task { await gate.release() }
        }
        model.beginReaderModeLoad(for: url)
        XCTAssertTrue(model.startRenderTaskIfNeeded(for: url) { _ in
            await gate.wait()
        })
        let generation = try XCTUnwrap(UUID(uuidString:
            model.currentRenderGenerationDescription(for: url)))
        XCTAssertTrue(model.handleRenderedReaderDocumentReady(
            pageURL: url, hasReaderContent: true, renderGeneration: generation))
        XCTAssertFalse(model.isReaderModeLoading)
        XCTAssertNil(model.pendingReaderModeURL)

        model.showReaderView(readerContent: readerContent, scriptCaller: WebViewScriptCaller())

        XCTAssertFalse(model.isReaderModeLoading)
        XCTAssertNil(model.pendingReaderModeURL)
        XCTAssertNil(model.expectedSyntheticReaderLoaderURL)
        XCTAssertEqual(model.lastRenderedURL, url)
        XCTAssertEqual(model.currentRenderGenerationDescription(for: url), generation.uuidString)
    }

    func testStalledLoadingIncludesBoundedStagesInExportedLogs() async throws {
#if DEBUG
        let isDevelopmentBuild = true
#else
        let isDevelopmentBuild = false
#endif
        let permitted = ReaderLoadTrace.permitsDiagnostics(isDevelopmentBuild: isDevelopmentBuild,
            receiptFilename: Bundle.main.appStoreReceiptURL?.lastPathComponent)
        let operation = UUID()
        await ReaderLoadTrace.$operationID.withValue(operation) {
            let span = ReaderLoadTrace.begin("processor.analysisSession")
            defer { span?.end("status=fixture-finished") }
            try? await Task.sleep(nanoseconds: 8_500_000_000)
        }
        let export = LoggingViewModel()
        await export.load()
        let logs = try XCTUnwrap(export.logsText)
        let ownRecords = logs.split(whereSeparator: \.isNewline).filter { $0.contains(operation.uuidString) }
        XCTAssertEqual(ownRecords.contains { $0.contains("stage=loading.pendingSnapshot") && $0.contains("processor.analysisSession:") }, permitted)
    }

#if DEBUG
    func testReadyTraceUsesValidatedRenderIdentityAndDistinguishesReplay() async throws {
        let model = ReaderModeViewModel()
        let url = URL(string: "https://example.com/ready-trace")!
        let gate = ReaderCallbackGate()
        defer {
            model.cancelReaderModeLoad(for: url)
            Task { await gate.release() }
        }
        model.beginReaderModeLoad(for: url)
        XCTAssertTrue(model.startRenderTaskIfNeeded(for: url) { _ in
            await gate.wait()
        })
        let generation = try XCTUnwrap(UUID(uuidString:
            model.currentRenderGenerationDescription(for: url)))
        let unrelatedOperation = UUID()
        let capture = ReaderCallbackTraceCapture()
        ReaderLoadTrace.$eventObserver.withValue({ capture.record($0, $1) }) {
            ReaderLoadTrace.$operationID.withValue(unrelatedOperation) {
                XCTAssertFalse(model.handleRenderedReaderDocumentReady(
                    pageURL: url, hasReaderContent: true, renderGeneration: UUID()))
                XCTAssertTrue(capture.snapshot.isEmpty)
                XCTAssertTrue(model.handleRenderedReaderDocumentReady(
                    pageURL: url, hasReaderContent: true, renderGeneration: generation))
                XCTAssertTrue(model.handleRenderedReaderDocumentReady(
                    pageURL: url, hasReaderContent: true, renderGeneration: generation))
                model.markReaderModeLoadComplete(for: url)
                XCTAssertEqual(ReaderLoadTrace.operationID, unrelatedOperation)
            }
        }

        let readiness = capture.snapshot.filter { $0.0 == "readerMode.renderReadyAccepted" }
        XCTAssertEqual(readiness.count, 2)
        XCTAssertTrue(readiness.allSatisfy { $0.1.contains("operation=\(generation.uuidString)") })
        XCTAssertTrue(try XCTUnwrap(readiness.first).1.contains("replay=false"))
        XCTAssertTrue(try XCTUnwrap(readiness.last).1.contains("replay=true"))
        XCTAssertTrue(capture.snapshot.contains { $0.0 == "readerMode.loadCompleted" })
    }
#endif

    func testRenderTaskTraceUsesItsGenerationAsOperationIdentity() async {
        let model = ReaderModeViewModel()
        let completed = expectation(description: "render operation observed trace context")
        defer { model.cancelReaderModeLoad() }
        XCTAssertTrue(model.startRenderTaskIfNeeded(
            for: URL(string: "https://example.com/render-trace")!
        ) { generation in
            XCTAssertEqual(ReaderLoadTrace.operationID, generation)
            completed.fulfill()
        })
        await fulfillment(of: [completed], timeout: 5)
    }

    func testCommitCannotAdoptSelectionChangedDuringFontSetup() async throws {
        let oldURL = URL(string: "reader-file://file/old-article")!
        let newURL = URL(string: "https://example.com/new-article")!
        let oldContent = Bookmark()
        oldContent.url = oldURL
        oldContent.isReaderModeByDefault = true
        let newContent = Bookmark()
        newContent.url = newURL
        let readerContent = ReaderContent()
        readerContent.content = oldContent
        readerContent.pageURL = oldURL
        let model = ReaderModeViewModel()
        let gate = ReaderCallbackGate()
        let fontStarted = expectation(description: "old document font setup suspended")
        let caller = WebViewScriptCaller()
        let owner = UUID()
        var evaluations = 0
        caller.installBinding(
            ownedBy: owner,
            asyncCaller: { _, arguments, _, _ in
                if arguments?["stylesheetURLTemplate"] != nil {
                    fontStarted.fulfill()
                    await gate.wait()
                    return .init(nil)
                }
                evaluations += 1
                return .init(nil)
            },
            unsafeCaller: nil, snapshotCapture: nil,
            coordinateOriginInWindow: { nil }
        )
        defer {
            _ = caller.clearBinding(ownedBy: owner)
            model.cancelReaderModeLoad()
            Task { await gate.release() }
        }
        var state = WebViewState.empty
        state.pageURL = oldURL
        let task = Task { @MainActor in
            try await model.onNavigationCommitted(
                readerContent: readerContent, newState: state,
                scriptCaller: caller, navigator: WebViewNavigator()
            )
        }
        await fulfillment(of: [fontStarted], timeout: 5)
        readerContent.content = newContent
        readerContent.pageURL = newURL
        readerContent.isRenderingReaderHTML = true
        model.beginReaderModeLoad(for: newURL)
        model.readabilityContent = "<article>New content</article>"
        await gate.release()
        do {
            try await task.value
            XCTFail("A suspended commit must not adopt a newer content selection")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(evaluations, 0,
                       "Old pagination setup must not run after selection changes")
        XCTAssertFalse(model.isReaderMode)
        XCTAssertTrue(model.isReaderModeLoadPending(for: newURL))
        XCTAssertTrue(model.isReaderModeLoading)
        XCTAssertEqual(model.readabilityContent, "<article>New content</article>")
        XCTAssertTrue(readerContent.isRenderingReaderHTML)
    }

    func testSuppressedBlankCommitPreservesSelectedArticleThroughHandler() async throws {
        let fixture = makeReaderWebViewHandlerFixture()
        let url = URL(string: "https://example.com/restoring-article")!
        let content = Bookmark()
        content.url = url
        fixture.readerContent.content = content
        fixture.readerContent.pageURL = url
        fixture.readerContent.isRenderingReaderHTML = true
        fixture.readerContent.suppressTransientAboutBlank(untilNextNonBlankLoad: url)
        fixture.readerModeViewModel.beginReaderModeLoad(for: url)
        fixture.readerModeViewModel.readabilityContent = "<article>Restoring content</article>"
        defer { fixture.readerModeViewModel.cancelReaderModeLoad() }
        do {
            try await fixture.handler.handleNavigationCommitted(state: .empty)
            XCTFail("A suppressed blank commit has no authority over the selected article")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(fixture.readerContent.pageURL, url)
        XCTAssertEqual(fixture.readerContent.content?.url, url)
        XCTAssertTrue(fixture.readerContent.isRenderingReaderHTML)
        XCTAssertTrue(fixture.readerModeViewModel.isReaderModeLoadPending(for: url))
        XCTAssertTrue(fixture.readerModeViewModel.isReaderModeLoading)
        XCTAssertEqual(fixture.readerModeViewModel.readabilityContent,
                       "<article>Restoring content</article>")
    }

    func testCancelledReaderModeCommitPreservesCachedContent() async {
        let model = ReaderModeViewModel()
        model.readabilityContent = "<article>Current content</article>"
        model.readabilityContainerSelector = "#current-content"
        let task = Task { @MainActor in
            try await model.onNavigationCommitted(
                readerContent: ReaderContent(), newState: .empty,
                scriptCaller: WebViewScriptCaller(), navigator: WebViewNavigator()
            )
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("An already-canceled callback must stop before clearing cached content")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(model.readabilityContent, "<article>Current content</article>")
        XCTAssertEqual(model.readabilityContainerSelector, "#current-content")
    }

    func testStaleBlankCommitCannotCancelSelectedArticleOrClearItsCache() async {
        let url = URL(string: "https://example.com/selected-article")!
        let content = Bookmark()
        content.url = url
        let readerContent = ReaderContent()
        readerContent.content = content
        readerContent.pageURL = url
        readerContent.isRenderingReaderHTML = true
        let model = ReaderModeViewModel()
        model.beginReaderModeLoad(for: url)
        model.readabilityContent = "<article>Selected content</article>"
        model.readabilityContainerSelector = "#selected-content"
        defer { model.cancelReaderModeLoad() }
        do {
            try await model.onNavigationCommitted(
                readerContent: readerContent, newState: .empty,
                scriptCaller: WebViewScriptCaller(), navigator: WebViewNavigator()
            )
            XCTFail("A commit for a different document must be rejected")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(model.readabilityContent, "<article>Selected content</article>")
        XCTAssertEqual(model.readabilityContainerSelector, "#selected-content")
        XCTAssertTrue(model.isReaderModeLoadPending(for: url))
        XCTAssertTrue(model.isReaderModeLoading)
        XCTAssertTrue(readerContent.isRenderingReaderHTML)
        XCTAssertEqual(readerContent.pageURL, url)
    }

    func testAboutBlankCommitAndFinishSkipJavaScriptButKeepNativeModeTransition() async throws {
        let url = URL(string: "about:blank")!
        let content = Bookmark()
        content.url = url
        content.isReaderModeByDefault = false
        let readerContent = ReaderContent()
        readerContent.content = content
        readerContent.pageURL = url
        let model = ReaderModeViewModel()
        model.isReaderMode = true
        let caller = WebViewScriptCaller()
        let owner = UUID()
        var evaluations = 0
        caller.installBinding(
            ownedBy: owner,
            asyncCaller: { _, _, _, _ in
                evaluations += 1
                return .init(nil)
            },
            unsafeCaller: nil, snapshotCapture: nil,
            coordinateOriginInWindow: { nil }
        )
        defer {
            _ = caller.clearBinding(ownedBy: owner)
            model.cancelReaderModeLoad()
        }
        var state = WebViewState.empty
        state.pageURL = url
        try await model.onNavigationCommitted(
            readerContent: readerContent, newState: state,
            scriptCaller: caller, navigator: WebViewNavigator()
        )
        XCTAssertFalse(model.isReaderMode,
                       "Skipping blank document scripts must preserve native commit behavior")
        await model.onNavigationFinished(newState: state, scriptCaller: caller)
        XCTAssertEqual(evaluations, 0)
        XCTAssertFalse(model.isReaderModeLoading)
    }

    func testAboutBlankFinishPreservesPendingArticleWithoutEvaluatingJavaScript() async {
        let articleURL = URL(string: "https://example.com/pending-article")!
        let model = ReaderModeViewModel()
        model.beginReaderModeLoad(for: articleURL)
        let caller = WebViewScriptCaller()
        let owner = UUID()
        var evaluations = 0
        caller.installBinding(
            ownedBy: owner,
            asyncCaller: { _, _, _, _ in
                evaluations += 1
                return .init(nil)
            },
            unsafeCaller: nil, snapshotCapture: nil,
            coordinateOriginInWindow: { nil }
        )
        defer {
            _ = caller.clearBinding(ownedBy: owner)
            model.cancelReaderModeLoad()
        }
        await model.onNavigationFinished(newState: .empty, scriptCaller: caller)
        XCTAssertEqual(evaluations, 0)
        XCTAssertTrue(model.isReaderModeLoadPending(for: articleURL))
        XCTAssertTrue(model.isReaderModeLoading)
        XCTAssertNil(model.lastRenderedURL)
    }

    func testFinalArticleCommitInitializesPaginationWithImmediateBinding() async throws {
        let url = URL(string: "https://example.com/final-article")!
        let content = Bookmark()
        content.url = url
        content.isReaderModeByDefault = true
        let readerContent = ReaderContent()
        readerContent.content = content
        readerContent.pageURL = url
        let model = ReaderModeViewModel()
        let caller = WebViewScriptCaller()
        let owner = UUID()
        var bookKeys = [String]()
        caller.installBinding(
            ownedBy: owner,
            asyncCaller: { _, arguments, _, _ in
                if let bookKey = arguments?["bookKey"] as? String {
                    bookKeys.append(bookKey)
                }
                return .init(nil)
            },
            unsafeCaller: nil, snapshotCapture: nil,
            coordinateOriginInWindow: { nil }
        )
        defer {
            _ = caller.clearBinding(ownedBy: owner)
            model.cancelReaderModeLoad()
        }
        XCTAssertTrue(caller.canEvaluateJavaScript)
        XCTAssertFalse(caller.hasAsyncCaller,
                       "The mounted binding precedes its published SwiftUI readiness flag")
        var state = WebViewState.empty
        state.pageURL = url
        try await model.onNavigationCommitted(
            readerContent: readerContent, newState: state,
            scriptCaller: caller, navigator: WebViewNavigator()
        )
        XCTAssertEqual(bookKeys, [url.absoluteString])
        XCTAssertTrue(model.isReaderMode)
    }

    func testEmptyLoaderCommitAndFinishDoNotEvaluateDocumentSetup() async throws {
        let url = URL(string: "https://example.com/stored-article")!
        let loaderURL = try XCTUnwrap(ReaderContentLoader.readerLoaderURL(for: url))
        let content = Bookmark()
        content.url = url
        content.isReaderModeByDefault = true
        let readerContent = ReaderContent()
        readerContent.content = content
        readerContent.pageURL = loaderURL
        let model = ReaderModeViewModel()
        let caller = WebViewScriptCaller()
        let owner = UUID()
        var evaluations = 0
        caller.installBinding(
            ownedBy: owner,
            asyncCaller: { _, _, _, _ in
                evaluations += 1
                return .init(nil)
            },
            unsafeCaller: nil, snapshotCapture: nil,
            coordinateOriginInWindow: { nil }
        )
        defer {
            _ = caller.clearBinding(ownedBy: owner)
            model.cancelReaderModeLoad()
        }
        var state = WebViewState.empty
        state.pageURL = loaderURL
        try await model.onNavigationCommitted(
            readerContent: readerContent, newState: state,
            scriptCaller: caller, navigator: WebViewNavigator()
        )
        await model.onNavigationFinished(newState: state, scriptCaller: caller)
        XCTAssertEqual(evaluations, 0,
                       "The empty loader must not wait on font or pagination JavaScript")
    }

    func testPublisherCommitAndFinishDoNotSetUpCustomFont() async throws {
        let url = URL(string: "https://example.com/original")!
        let content = Bookmark()
        content.url = url
        content.isReaderModeByDefault = false
        let readerContent = ReaderContent()
        readerContent.content = content
        readerContent.pageURL = url
        let model = ReaderModeViewModel()
        let caller = WebViewScriptCaller()
        let owner = UUID()
        var paginationKeys: [String] = []
        caller.installBinding(ownedBy: owner, asyncCaller: { _, arguments, _, _ in
            XCTAssertNil(arguments?["stylesheetURLTemplate"], "Publisher callbacks must not install the reader font")
            if let key = arguments?["bookKey"] as? String { paginationKeys.append(key) }
            return .init(nil)
        }, unsafeCaller: nil, snapshotCapture: nil, coordinateOriginInWindow: { nil })
        defer { _ = caller.clearBinding(ownedBy: owner); model.cancelReaderModeLoad() }
        var state = WebViewState.empty
        state.pageURL = url
        try await model.onNavigationCommitted(readerContent: readerContent, newState: state,
                                              scriptCaller: caller, navigator: WebViewNavigator())
        await model.onNavigationFinished(newState: state, scriptCaller: caller)
        XCTAssertEqual(paginationKeys, [url.absoluteString], "Other document setup still runs")
        XCTAssertFalse(model.isReaderMode)
    }

    func testFinalArticleFinishStillEvaluatesDocumentSetup() async throws {
        let model = ReaderModeViewModel()
        let caller = WebViewScriptCaller()
        let owner = UUID()
        var fontEvaluations = 0
        caller.installBinding(
            ownedBy: owner,
            asyncCaller: { _, arguments, _, _ in
                if arguments?["stylesheetURLTemplate"] != nil {
                    fontEvaluations += 1
                }
                return .init(nil)
            },
            unsafeCaller: nil, snapshotCapture: nil,
            coordinateOriginInWindow: { nil }
        )
        defer { _ = caller.clearBinding(ownedBy: owner) }
        var state = WebViewState.empty
        state.pageURL = URL(string: "reader-file://file/final-article")!
        await model.onNavigationFinished(newState: state, scriptCaller: caller)
        XCTAssertEqual(fontEvaluations, 1,
                       "Readiness replay alone must not satisfy the font-setup regression")
    }
}
