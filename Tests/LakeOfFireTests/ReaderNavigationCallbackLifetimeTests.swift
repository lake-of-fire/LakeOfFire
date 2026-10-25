import XCTest
import Combine
import RealmSwift
import RealmSwiftGaps
import LakeOfFireContent
@testable import SwiftUIWebView
@testable import LakeOfFireReader

private actor NavigationLifetimeGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private enum NavigationLifetimeError: Error {
    case controlledFailure
}

@MainActor
private final class NavigationLifetimeProbe {
    var settingsCount = 0
    var finishCount = 0
    var fontCount = 0
    var paginationCount = 0
    var titles: [String] = []
    var settingsGate: NavigationLifetimeGate?
    var finishGate: NavigationLifetimeGate?
    var fontGate: NavigationLifetimeGate?
    var paginationGate: NavigationLifetimeGate?
    var settingsEntered: XCTestExpectation?
    var finishEntered: XCTestExpectation?
    var fontEntered: XCTestExpectation?
    var paginationEntered: XCTestExpectation?
    var failSettings = false
    var failFinish = false
    var failFont = false
    var failPagination = false

    func evaluate(_ script: String, title: String?, isFontInjection: Bool) async throws -> Bool? {
        if isFontInjection {
            fontCount += 1
            fontEntered?.fulfill()
            await fontGate?.wait()
            if failFont { throw NavigationLifetimeError.controlledFailure }
        } else if script.contains("window.paginationTrackingBookKey = bookKey;") {
            paginationCount += 1
            paginationEntered?.fulfill()
            await paginationGate?.wait()
            if failPagination { throw NavigationLifetimeError.controlledFailure }
        } else if let title {
            titles.append(title)
        } else if script.contains("isNextLoadInReaderMode") {
            finishCount += 1
            finishEntered?.fulfill()
            await finishGate?.wait()
            if failFinish { throw NavigationLifetimeError.controlledFailure }
            return false
        } else if script.contains("--mnb-reader-max-width-override") {
            settingsCount += 1
            settingsEntered?.fulfill()
            await settingsGate?.wait()
            if failSettings { throw NavigationLifetimeError.controlledFailure }
        }
        return nil
    }

    func bind(_ caller: WebViewScriptCaller) {
        caller.installBinding(
            ownedBy: UUID(),
            asyncCaller: { [self] script, arguments, _, _ in
                let value = try await evaluate(
                    script,
                    title: arguments?["title"] as? String,
                    isFontInjection: arguments?["fontCSSBase64"] != nil
                        || arguments?["stylesheetURLTemplate"] != nil
                )
                return .init(value)
            },
            unsafeCaller: nil,
            snapshotCapture: nil
        )
    }
}

@MainActor
private final class NavigationLifetimeReader: ReaderViewModel {
    var beforeCommitReturns: (() async throws -> Void)?
    var commitCount = 0
    var finishTasks: [Task<Void, Never>] = []
    var refreshTasks: [Task<Void, Never>] = []

    override func onNavigationCommitted(content: any ReaderContentProtocol, newState: WebViewState) async throws {
        commitCount += 1
        try await beforeCommitReturns?()
    }

    override func onNavigationFinished(
        content: any ReaderContentProtocol,
        newState: WebViewState,
        documentIsCurrent: @escaping @MainActor () -> Bool,
        completion: ((WebViewState) -> Void)? = nil
    ) -> Task<Void, Never>? {
        let task = super.onNavigationFinished(
            content: content, newState: newState,
            documentIsCurrent: documentIsCurrent, completion: completion
        )
        if let task { finishTasks.append(task) }
        return task
    }

    override func refreshSettingsInWebView(
        content: any ReaderContentProtocol,
        newState: WebViewState? = nil,
        documentIsCurrent: @escaping @MainActor () -> Bool
    ) -> Task<Void, Never>? {
        let task = super.refreshSettingsInWebView(
            content: content, newState: newState, documentIsCurrent: documentIsCurrent
        )
        if let task { refreshTasks.append(task) }
        return task
    }
}

@MainActor
private final class NavigationLifetimeMedia: ReaderMediaPlayerViewModel {
    var committed: [ObjectIdentifier] = []

    override func onNavigationCommitted(content: any ReaderContentProtocol, newState: WebViewState) async throws {
        committed.append(ObjectIdentifier(content))
    }
}

@MainActor
private final class NavigationLifetimeFixture {
    let content: ReaderContent
    let mode: ReaderModeViewModel
    let media: NavigationLifetimeMedia
    let tasks: NavigationTaskManager
    let probe: NavigationLifetimeProbe
    let reader: NavigationLifetimeReader
    var handler: ReaderWebViewHandler
    let libraryConfiguration: Realm.Configuration
    let record: HistoryRecord
    let realm: Realm?
    let state: WebViewState
    var externalFinishCount = 0

    init(managed: Bool, preload: Bool, bindCaller: Bool) throws {
        let content = ReaderContent()
        let mode = ReaderModeViewModel()
        let media = NavigationLifetimeMedia()
        let tasks = NavigationTaskManager()
        let probe = NavigationLifetimeProbe()
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [LibraryConfiguration.self, FeedCategory.self, UserScript.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        let reader = NavigationLifetimeReader(realmConfiguration: configuration, systemScripts: [])
        let record = HistoryRecord()
        record.compoundKey = UUID().uuidString
        record.url = URL(string: "https://example.invalid/navigation-lifetime")!
        record.title = "Original title"
        record.rssContainsFullContent = true
        let realm: Realm?
        if managed {
            var recordConfiguration = Realm.Configuration(
                inMemoryIdentifier: UUID().uuidString, objectTypes: [HistoryRecord.self]
            )
            configureLakeOfFireMutationTrackingForTesting(&recordConfiguration)
            let opened = try Realm(configuration: recordConfiguration, queue: nil)
            try opened.write { opened.add(record) }
            realm = opened
        } else {
            realm = nil
        }
        var initialState = WebViewState.empty
        initialState.pageURL = record.url
        reader.state = initialState
        if preload {
            content.preloadResolvedContent(record, for: initialState.pageURL)
        } else {
            content.pageURL = initialState.pageURL
            content.replaceSelection(with: record)
        }
        mode.sharedFontCSSBase64Provider = { nil }
        if bindCaller { probe.bind(reader.scriptCaller) }
        let handler = ReaderWebViewHandler(
            navigationTaskManager: tasks,
            readerContent: content, readerViewModel: reader,
            readerModeViewModel: mode, readerMediaPlayerViewModel: media,
            scriptCaller: reader.scriptCaller
        )
        self.content = content
        self.mode = mode
        self.media = media
        self.tasks = tasks
        self.probe = probe
        self.libraryConfiguration = configuration
        self.reader = reader
        self.record = record
        self.realm = realm
        self.state = initialState
        self.handler = handler
        handler.onNavigationFinished = { [weak self] _ in
            self?.externalFinishCount += 1
        }
    }

    func rebuildHandler(
        readerContent: ReaderContent? = nil,
        readerViewModel: ReaderViewModel? = nil,
        readerModeViewModel: ReaderModeViewModel? = nil,
        readerMediaPlayerViewModel: ReaderMediaPlayerViewModel? = nil,
        scriptCaller: WebViewScriptCaller? = nil
    ) {
        handler = ReaderWebViewHandler(
            navigationTaskManager: tasks,
            onNavigationFinished: { [weak self] _ in self?.externalFinishCount += 1 },
            readerContent: readerContent ?? content,
            readerViewModel: readerViewModel ?? reader,
            readerModeViewModel: readerModeViewModel ?? mode,
            readerMediaPlayerViewModel: readerMediaPlayerViewModel ?? media,
            scriptCaller: scriptCaller ?? reader.scriptCaller
        )
    }

    func replaceSelection(returnToOriginal: Bool = false) {
        let replacement = HistoryRecord()
        replacement.url = state.pageURL
        replacement.compoundKey = record.compoundKey
        replacement.title = "Successor title"
        replacement.rssContainsFullContent = true
        content.replaceSelection(with: replacement)
        if returnToOriginal { content.replaceSelection(with: record) }
    }
}

/// One teardown owns every test-controlled suspension and every task observer.
/// It restores shared state only after actual work has settled.
@MainActor
private final class NavigationLifetimeCleanup {
    var fixtures: [NavigationLifetimeFixture] = []
    var gates: [NavigationLifetimeGate] = []
    var cancellations: [@MainActor () -> Void] = []
    var observers: [Task<Void, Never>] = []
    let originalResolver: ReaderContent.ContentResolver?
    let originalHistoryConfiguration: Realm.Configuration
    let originalFeedConfiguration: Realm.Configuration
    let originalProviders: [ReaderContentAdditionalProvider]
    private var renderStoreConfiguration: Realm.Configuration?

    init() {
        originalResolver = ReaderContent.contentResolver
        originalHistoryConfiguration = ReaderContentLoader.historyRealmConfiguration
        originalFeedConfiguration = ReaderContentLoader.feedEntryRealmConfiguration
        originalProviders = ReaderContentLoader.additionalContentProviders
    }

    func isolateRenderStores() {
        guard renderStoreConfiguration == nil else { return }
        var configuration = Realm.Configuration(inMemoryIdentifier: UUID().uuidString)
        configuration.objectTypes = [Bookmark.self, HistoryRecord.self, ContentFile.self, Feed.self, FeedEntry.self]
        configureLakeOfFireMutationTrackingForTesting(&configuration)
        renderStoreConfiguration = configuration
        ReaderContentLoader.historyRealmConfiguration = configuration
        ReaderContentLoader.feedEntryRealmConfiguration = configuration
        ReaderContentLoader.additionalContentProviders = []
    }

    func track<Value: Sendable, Failure: Error>(_ task: Task<Value, Failure>) {
        cancellations.append { task.cancel() }
        observers.append(Task { @MainActor in _ = await task.result })
    }

    func finish() async {
        // Snapshot before cancelNavigationWork clears the manager's handles.
        for fixture in fixtures {
            let callbacks = [
                fixture.tasks.onNavigationCommittedTask,
                fixture.tasks.onNavigationFinishedTask,
                fixture.tasks.onNavigationFailedTask,
                fixture.tasks.onURLChangedTask,
            ].compactMap { $0 }
            callbacks.forEach { track($0) }
            fixture.reader.finishTasks.forEach { track($0) }
            fixture.reader.refreshTasks.forEach { track($0) }
            if let render = fixture.mode.activeRenderTask(for: fixture.state.pageURL) {
                track(render)
            }
        }
        cancellations.forEach { $0() }
        fixtures.forEach { $0.tasks.cancelNavigationWork() }
        for gate in gates { await gate.release() }
        for fixture in fixtures {
            await fixture.probe.settingsGate?.release()
            await fixture.probe.finishGate?.release()
            await fixture.probe.fontGate?.release()
            await fixture.probe.paginationGate?.release()
        }

        let joined = XCTestExpectation(description: "Fixture production tasks and observers settled")
        let pending = observers
        let join = Task { @MainActor in
            for observer in pending { await observer.value }
            joined.fulfill()
        }
        let outcome = await XCTWaiter.fulfillment(of: [joined], timeout: 2)
        guard outcome == .completed else {
            join.cancel()
            XCTFail("Fixture work did not settle after cancellation and blocker release; shared resolver/storage were not restored under live work")
            return
        }
        await join.value
        ReaderContent.contentResolver = originalResolver
        ReaderContentLoader.historyRealmConfiguration = originalHistoryConfiguration
        ReaderContentLoader.feedEntryRealmConfiguration = originalFeedConfiguration
        ReaderContentLoader.additionalContentProviders = originalProviders
        if let renderStoreConfiguration {
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: renderStoreConfiguration)
        }
        for fixture in fixtures {
            _ = await RealmBackgroundActor.shared.removeCachedRealm(for: fixture.libraryConfiguration)
        }
        observers.removeAll()
        cancellations.removeAll()
        gates.removeAll()
        fixtures.removeAll()
    }
}


@MainActor
final class ReaderNavigationCallbackLifetimeTests: XCTestCase {
    private var cleanup: NavigationLifetimeCleanup?

    private func cleanupOwner() -> NavigationLifetimeCleanup {
        if let cleanup { return cleanup }
        let owner = NavigationLifetimeCleanup()
        cleanup = owner
        addTeardownBlock { @MainActor in await owner.finish() }
        return owner
    }

    private func fixture(managed: Bool = false, preload: Bool = false, bindCaller: Bool = true) throws -> NavigationLifetimeFixture {
        let owner = cleanupOwner()
        let result = try NavigationLifetimeFixture(managed: managed, preload: preload, bindCaller: bindCaller)
        owner.fixtures.append(result)
        return result
    }

    private func gate() -> NavigationLifetimeGate {
        let result = NavigationLifetimeGate()
        cleanupOwner().gates.append(result)
        return result
    }

    private func own<Value: Sendable, Failure: Error>(_ task: Task<Value, Failure>) -> Task<Value, Failure> {
        cleanupOwner().track(task)
        return task
    }

    /// Observe actual task settlement with a deadline. Failure cleanup releases
    /// only this fixture's gates and never joins an indefinitely suspended task.
    private func settle<Value: Sendable>(
        _ task: Task<Value, Error>,
        releasing gate: NavigationLifetimeGate? = nil
    ) async -> Result<Value, Error>? {
        let done = expectation(description: "Production callback settled")
        var result: Result<Value, Error>?
        let observer = Task { @MainActor in
            result = await task.result
            done.fulfill()
        }
        cleanupOwner().cancellations.append { task.cancel() }
        cleanupOwner().observers.append(observer)
        await fulfillment(of: [done], timeout: 2)
        if result == nil {
            task.cancel()
            await gate?.release()
        }
        return result
    }

    private func settle(
        _ task: Task<Void, Never>,
        releasing gate: NavigationLifetimeGate? = nil
    ) async {
        let done = expectation(description: "Production settings settled")
        var completed = false
        let observer = Task { @MainActor in
            await task.value
            completed = true
            done.fulfill()
        }
        cleanupOwner().cancellations.append { task.cancel() }
        cleanupOwner().observers.append(observer)
        await fulfillment(of: [done], timeout: 2)
        if !completed {
            task.cancel()
            await gate?.release()
        }
    }

    private func commit(_ fixture: NavigationLifetimeFixture) async throws {
        fixture.handler.onNavigationCommitted(state: fixture.state)
        let result = await settle(try XCTUnwrap(fixture.tasks.onNavigationCommittedTask))
        guard case .success? = result else {
            XCTFail("Current commit did not succeed: \(String(describing: result))")
            return
        }
    }

    private func prepareHeldReaderRender(
        _ fixture: NavigationLifetimeFixture,
        gate: NavigationLifetimeGate,
        entered: XCTestExpectation
    ) {
        // Use the captured-readability path, with a date already in the actual
        // canonical HTML so this fixture does not request a metadata fallback.
        fixture.record.rssContainsFullContent = false
        fixture.record.isReaderModeAvailable = true
        fixture.mode.readabilityContent = buildCanonicalReadabilityHTML(
            title: "Original title", byline: "", publishedTime: "2026-10-25",
            content: "<p>Reader preparation is still running.</p>",
            contentURL: fixture.state.pageURL
        )
        fixture.mode.processReadabilityContent = { _, _, _, _, _, _, _ in
            entered.fulfill()
            await gate.wait()
            // Exit through the production failure path after the assertions;
            // no related-store propagation or replacement navigation follows.
            throw NavigationLifetimeError.controlledFailure
        }
    }

    private func startHeldReaderRender(
        _ fixture: NavigationLifetimeFixture,
        gate: NavigationLifetimeGate
    ) async throws -> Task<Void, Never> {
        let entered = expectation(description: "Actual Reader processing suspended")
        prepareHeldReaderRender(fixture, gate: gate, entered: entered)
        fixture.mode.showReaderView(readerContent: fixture.content, scriptCaller: fixture.reader.scriptCaller)
        let task = own(try XCTUnwrap(fixture.mode.activeRenderTask(for: fixture.state.pageURL)))
        await fulfillment(of: [entered], timeout: 2)
        return task
    }

    private func holdFinishAtFontBridge(
        _ fixture: NavigationLifetimeFixture
    ) async throws -> (task: Task<Void, Error>, gate: NavigationLifetimeGate) {
        guard #available(iOS 16.4, macOS 14, *) else {
            throw XCTSkip("The production shared-font bridge requires iOS 16.4 or macOS 14")
        }
        fixture.mode.sharedFontCSSBase64 = Data("body { color: inherit; }".utf8).base64EncodedString()
        let held = gate()
        let entered = expectation(description: "Actual font JavaScript bridge suspended")
        fixture.probe.fontGate = held
        fixture.probe.fontEntered = entered
        fixture.handler.onNavigationFinished(state: fixture.state)
        let task = own(try XCTUnwrap(fixture.tasks.onNavigationFinishedTask))
        await fulfillment(of: [entered], timeout: 2)
        fixture.probe.fontEntered = nil
        return (task, held)
    }

    private func beginDispatchedReaderRender(
        _ fixture: NavigationLifetimeFixture,
        handoffGate: NavigationLifetimeGate,
        dispatched: XCTestExpectation
    ) throws -> Task<Void, Never> {
        // Exercise the actual HTTP HTML pipeline and navigator data issue with
        // empty isolated propagation stores and no attached WKWebView.
        cleanupOwner().isolateRenderStores()
        let url = fixture.state.pageURL
        let html = buildCanonicalReadabilityHTML(
            title: "Original title", byline: "", publishedTime: "2026-10-25",
            content: "<p>A complete Reader document.</p>", contentURL: url
        )
        fixture.mode.readabilityContent = html
        fixture.mode.processReadabilityContent = nil
        let navigator = fixture.mode.navigator ?? WebViewNavigator()
        fixture.mode.navigator = navigator
        fixture.mode.beginReaderModeLoad(for: url, reason: "fixture.actualDataIssue")
        let content = fixture.content
        let mode = fixture.mode
        let caller = fixture.reader.scriptCaller
        let selection = content.makeSelectionCommitFence(requiring: content.currentSelectionID)
        XCTAssertTrue(mode.startRenderTaskIfNeeded(
            for: url, reason: "fixture.actualDataIssue", selectionIsCurrent: selection
        ) { generation in
            do {
                try await mode.showReadabilityContent(
                    readerContent: content, readabilityContent: html,
                    renderToSelector: nil, in: nil, scriptCaller: caller,
                    renderURL: url, renderGeneration: generation, selectionFence: selection
                )
                await MainActor.run {
                    XCTAssertEqual(navigator.debugLoadSnapshot.lastDataLoadBaseURL, url.absoluteString)
                    dispatched.fulfill()
                }
            } catch {
                XCTFail("Actual Reader document preparation failed: \(error)")
                dispatched.fulfill()
                return
            }
            await handoffGate.wait()
        })
        let task = own(try XCTUnwrap(mode.activeRenderTask(for: url)))
        return task
    }

    private func startDispatchedReaderRender(
        _ fixture: NavigationLifetimeFixture,
        handoffGate: NavigationLifetimeGate
    ) async throws -> Task<Void, Never> {
        let dispatched = expectation(description: "Actual Reader HTML issued to navigator")
        let task = try beginDispatchedReaderRender(
            fixture, handoffGate: handoffGate, dispatched: dispatched
        )
        await fulfillment(of: [dispatched], timeout: 2)
        return task
    }

    private func assertIssuedRenderStillPending(
        _ fixture: NavigationLifetimeFixture,
        generation: String,
        html: String?,
        priorExternalFinishes: Int = 0,
        priorMediaCommits: Int = 0
    ) {
        XCTAssertTrue(fixture.mode.isReaderMode)
        XCTAssertTrue(fixture.mode.isReaderModeLoading)
        XCTAssertEqual(fixture.mode.pendingReaderModeURL, fixture.state.pageURL)
        XCTAssertEqual(fixture.mode.expectedSyntheticReaderLoaderURL, fixture.state.pageURL)
        XCTAssertEqual(fixture.mode.currentRenderGenerationDescription(for: fixture.state.pageURL), generation)
        XCTAssertEqual(fixture.mode.readabilityContent, html)
        XCTAssertNil(fixture.mode.lastRenderedURL)
        XCTAssertEqual(fixture.externalFinishCount, priorExternalFinishes)
        XCTAssertEqual(fixture.media.committed.count, priorMediaCommits)
        XCTAssertFalse(fixture.content.isReaderMainFrameNavigating)
    }

    private func finishCurrentDispatchedRender(
        _ fixture: NavigationLifetimeFixture,
        render: Task<Void, Never>,
        handoff: NavigationLifetimeGate
    ) async throws {
        let priorExternalFinishes = fixture.externalFinishCount
        let priorMediaCommits = fixture.media.committed.count
        fixture.reader.beforeCommitReturns = nil
        fixture.probe.fontGate = nil
        fixture.probe.paginationGate = nil
        fixture.probe.failFont = false
        fixture.probe.failPagination = false
        await handoff.release()
        await settle(render)
        try await commit(fixture)
        XCTAssertNil(fixture.mode.expectedSyntheticReaderLoaderURL)
        fixture.handler.onNavigationFinished(state: fixture.state)
        guard case .success? = await settle(try XCTUnwrap(fixture.tasks.onNavigationFinishedTask)) else {
            return XCTFail("The newly committed Reader document could not finish")
        }
        await settle(try XCTUnwrap(fixture.reader.finishTasks.last))
        XCTAssertFalse(fixture.mode.isReaderModeLoading)
        XCTAssertNil(fixture.mode.pendingReaderModeURL)
        XCTAssertEqual(fixture.mode.lastRenderedURL, fixture.state.pageURL)
        XCTAssertEqual(fixture.externalFinishCount, priorExternalFinishes + 1)
        XCTAssertEqual(fixture.media.committed.count, priorMediaCommits + 1)
    }

    func testCommitCapturedDuringPreparationCannotAdoptThatRendersLaterIssue() async throws {
        for cancelAfterIssue in [false, true] {
            let f = try fixture()
            try await commit(f)
            f.handler.onNavigationFinished(state: f.state)
            guard case .success? = await settle(try XCTUnwrap(f.tasks.onNavigationFinishedTask)) else {
                return XCTFail("The original document did not settle before its location callback")
            }
            await settle(try XCTUnwrap(f.reader.finishTasks.last))
            let priorExternalFinishes = f.externalFinishCount
            let priorMediaCommits = f.media.committed.count

            let processing = gate()
            let preparationEntered = expectation(description: "Real HTML byte processing suspended before data issue")
            f.mode.processHTMLBytes = { bytes, _ in
                preparationEntered.fulfill()
                await processing.wait()
                return bytes
            }
            let issued = expectation(description: "The same preparing render issued its actual document")
            let handoff = gate()
            let render = try beginDispatchedReaderRender(f, handoffGate: handoff, dispatched: issued)
            await fulfillment(of: [preparationEntered], timeout: 2)
            let generation = f.mode.currentRenderGenerationDescription(for: f.state.pageURL)
            XCTAssertNotEqual(generation, "nil")
            XCTAssertEqual(f.mode.syntheticLoadElapsedString(for: f.state.pageURL), "nil")
            XCTAssertNil(f.mode.expectedSyntheticReaderLoaderURL)

            let held = gate()
            let commitEntered = expectation(description: "Actual location callback suspended before Mode entry")
            f.reader.beforeCommitReturns = {
                commitEntered.fulfill()
                await held.wait()
            }
            f.handler.onURLChanged(state: f.state)
            let originalCallback = own(try XCTUnwrap(f.tasks.onURLChangedTask))
            await fulfillment(of: [commitEntered], timeout: 2)
            await processing.release()
            await fulfillment(of: [issued], timeout: 2)
            XCTAssertEqual(f.mode.currentRenderGenerationDescription(for: f.state.pageURL), generation)
            let html = f.mode.readabilityContent
            var readerCompletions = 0
            f.mode.readerModeLoadCompletionHandler = { _ in readerCompletions += 1 }
            if cancelAfterIssue {
                f.mode.cancelReaderModeLoad(for: f.state.pageURL, reason: "fixture.issueABA")
                await handoff.release()
                await settle(render)
                XCTAssertEqual(f.mode.currentRenderGenerationDescription(for: f.state.pageURL), "nil")
            }

            await held.release()
            guard case .failure(let error)? = await settle(originalCallback, releasing: held) else {
                return XCTFail("A callback admitted before this render's issue acquired its later phase")
            }
            XCTAssertTrue(error is CancellationError)
            XCTAssertEqual(readerCompletions, 0)
            if cancelAfterIssue {
                XCTAssertEqual(f.mode.readabilityContent, html)
                XCTAssertNil(f.mode.expectedSyntheticReaderLoaderURL)
                XCTAssertNil(f.mode.pendingReaderModeURL)
                XCTAssertFalse(f.mode.isReaderModeLoading)
                XCTAssertEqual(f.externalFinishCount, priorExternalFinishes)
                XCTAssertEqual(f.media.committed.count, priorMediaCommits)
                f.reader.beforeCommitReturns = nil
                try await commit(f)
                f.handler.onNavigationFinished(state: f.state)
                guard case .success? = await settle(try XCTUnwrap(f.tasks.onNavigationFinishedTask)) else {
                    return XCTFail("A fresh callback could not retry after issue cancellation")
                }
                await settle(try XCTUnwrap(f.reader.finishTasks.last))
                XCTAssertEqual(f.externalFinishCount, priorExternalFinishes + 1)
                XCTAssertEqual(f.media.committed.count, priorMediaCommits + 1)
            } else {
                assertIssuedRenderStillPending(
                    f, generation: generation, html: html,
                    priorExternalFinishes: priorExternalFinishes, priorMediaCommits: priorMediaCommits
                )
                try await finishCurrentDispatchedRender(f, render: render, handoff: handoff)
                XCTAssertEqual(readerCompletions, 1)
            }
        }
    }

    func testCurrentReadyDuringCommitFontAwaitPreservesReaderModeAndCanonicalHTML() async throws {
        guard #available(iOS 16.4, macOS 14, *) else {
            throw XCTSkip("The production shared-font bridge requires iOS 16.4 or macOS 14")
        }
        for fails in [false, true] {
            let f = try fixture()
            // Rendering has no durable target for this supported unmanaged
            // source; its default remains false while Reader is shown.
            f.record.isReaderModeByDefault = false
            let handoff = gate()
            let render = try await startDispatchedReaderRender(f, handoffGate: handoff)
            let generation = try XCTUnwrap(UUID(uuidString: f.mode.currentRenderGenerationDescription(for: f.state.pageURL)))
            let html = try XCTUnwrap(f.mode.readabilityContent)
            XCTAssertFalse(f.record.isReaderModeByDefault)
            XCTAssertTrue(f.mode.isReaderMode)
            f.mode.sharedFontCSSBase64 = Data("body { color: inherit; }".utf8).base64EncodedString()
            let held = gate()
            let entered = expectation(description: "Current synthetic commit font bridge suspended: \(fails)")
            f.probe.fontGate = held
            f.probe.fontEntered = entered
            f.probe.failFont = fails
            var readerCompletions = 0
            f.mode.readerModeLoadCompletionHandler = { _ in readerCompletions += 1 }
            f.handler.onNavigationCommitted(state: f.state)
            let currentCommit = own(try XCTUnwrap(f.tasks.onNavigationCommittedTask))
            await fulfillment(of: [entered], timeout: 2)
            f.probe.fontEntered = nil
            XCTAssertEqual(f.mode.readabilityContent, html)

            XCTAssertTrue(f.mode.handleRenderedReaderDocumentReady(
                pageURL: f.state.pageURL, hasReaderContent: true, renderGeneration: generation
            ))
            XCTAssertNil(f.mode.expectedSyntheticReaderLoaderURL)
            XCTAssertNil(f.mode.pendingReaderModeURL)
            XCTAssertFalse(f.mode.isReaderModeLoading)
            XCTAssertEqual(readerCompletions, 1)
            await held.release()
            guard case .success? = await settle(currentCommit, releasing: held) else {
                return XCTFail("Matching readiness incorrectly retired its own native commit: \(fails)")
            }
            XCTAssertTrue(f.mode.isReaderMode)
            XCTAssertFalse(f.record.isReaderModeByDefault)
            XCTAssertEqual(f.mode.readabilityContent, html)
            XCTAssertEqual(f.mode.lastRenderedURL, f.state.pageURL)
            XCTAssertEqual(readerCompletions, 1)

            await handoff.release()
            await settle(render)
            f.handler.onNavigationFinished(state: f.state)
            guard case .success? = await settle(try XCTUnwrap(f.tasks.onNavigationFinishedTask)) else {
                return XCTFail("The already ready current document could not finish")
            }
            await settle(try XCTUnwrap(f.reader.finishTasks.last))
            XCTAssertTrue(f.mode.isReaderMode)
            XCTAssertFalse(f.mode.isReaderModeLoading)
            XCTAssertEqual(f.mode.readabilityContent, html)
            XCTAssertEqual(readerCompletions, 1)
            XCTAssertEqual(f.externalFinishCount, 1)
            XCTAssertEqual(f.media.committed.count, 1)
        }
    }

    func testCommitCapturesRenderAdmissionBeforeTheReaderAwait() async throws {
        let f = try fixture()
        let held = gate()
        let entered = expectation(description: "Original native commit suspended before Mode entry")
        f.reader.beforeCommitReturns = {
            entered.fulfill()
            await held.wait()
        }
        f.handler.onNavigationCommitted(state: f.state)
        let originalCommit = own(try XCTUnwrap(f.tasks.onNavigationCommittedTask))
        await fulfillment(of: [entered], timeout: 2)
        f.handler.onNavigationFinished(state: f.state)
        let originalFinish = own(try XCTUnwrap(f.tasks.onNavigationFinishedTask))
        let handoff = gate()
        let render = try await startDispatchedReaderRender(f, handoffGate: handoff)
        let generation = f.mode.currentRenderGenerationDescription(for: f.state.pageURL)
        let html = f.mode.readabilityContent
        var readerCompletions = 0
        f.mode.readerModeLoadCompletionHandler = { _ in readerCompletions += 1 }

        await held.release()
        for task in [originalCommit, originalFinish] {
            guard case .failure(let error)? = await settle(task, releasing: held) else {
                return XCTFail("A pre-Mode commit acquired a later render's admission")
            }
            XCTAssertTrue(error is CancellationError)
        }
        assertIssuedRenderStillPending(f, generation: generation, html: html)
        XCTAssertEqual(readerCompletions, 0)
        XCTAssertEqual(f.probe.finishCount, 0)

        try await finishCurrentDispatchedRender(f, render: render, handoff: handoff)
        XCTAssertEqual(readerCompletions, 1)
    }

    func testCommitFontSuccessOrFailureCannotConsumeALaterIssuedRender() async throws {
        guard #available(iOS 16.4, macOS 14, *) else {
            throw XCTSkip("The production shared-font bridge requires iOS 16.4 or macOS 14")
        }
        for fails in [false, true] {
            let f = try fixture()
            f.mode.sharedFontCSSBase64 = Data("body { color: inherit; }".utf8).base64EncodedString()
            let held = gate()
            let entered = expectation(description: "Original commit font bridge suspended: \(fails)")
            f.probe.fontGate = held
            f.probe.fontEntered = entered
            f.probe.failFont = fails
            f.handler.onNavigationCommitted(state: f.state)
            let originalCommit = own(try XCTUnwrap(f.tasks.onNavigationCommittedTask))
            await fulfillment(of: [entered], timeout: 2)
            f.probe.fontEntered = nil
            f.handler.onNavigationFinished(state: f.state)
            let originalFinish = own(try XCTUnwrap(f.tasks.onNavigationFinishedTask))
            let handoff = gate()
            let render = try await startDispatchedReaderRender(f, handoffGate: handoff)
            let generation = f.mode.currentRenderGenerationDescription(for: f.state.pageURL)
            let html = f.mode.readabilityContent
            var readerCompletions = 0
            f.mode.readerModeLoadCompletionHandler = { _ in readerCompletions += 1 }

            await held.release()
            for task in [originalCommit, originalFinish] {
                guard case .failure(let error)? = await settle(task, releasing: held) else {
                    return XCTFail("An old font result consumed the replacement expectation: \(fails)")
                }
                XCTAssertTrue(error is CancellationError)
            }
            assertIssuedRenderStillPending(f, generation: generation, html: html)
            XCTAssertEqual(readerCompletions, 0)
            XCTAssertEqual(f.probe.paginationCount, 0)

            try await finishCurrentDispatchedRender(f, render: render, handoff: handoff)
            XCTAssertEqual(readerCompletions, 1)
        }
    }

    func testCommitPaginationSuccessOrFailureCannotConsumeALaterIssuedRender() async throws {
        for fails in [false, true] {
            let f = try fixture()
            let held = gate()
            let entered = expectation(description: "Original commit pagination bridge suspended: \(fails)")
            f.probe.paginationGate = held
            f.probe.paginationEntered = entered
            f.probe.failPagination = fails
            f.handler.onNavigationCommitted(state: f.state)
            let originalCommit = own(try XCTUnwrap(f.tasks.onNavigationCommittedTask))
            await fulfillment(of: [entered], timeout: 2)
            f.probe.paginationEntered = nil
            f.handler.onNavigationFinished(state: f.state)
            let originalFinish = own(try XCTUnwrap(f.tasks.onNavigationFinishedTask))
            let handoff = gate()
            let render = try await startDispatchedReaderRender(f, handoffGate: handoff)
            let generation = f.mode.currentRenderGenerationDescription(for: f.state.pageURL)
            let html = f.mode.readabilityContent
            var readerCompletions = 0
            f.mode.readerModeLoadCompletionHandler = { _ in readerCompletions += 1 }

            await held.release()
            for task in [originalCommit, originalFinish] {
                guard case .failure(let error)? = await settle(task, releasing: held) else {
                    return XCTFail("An old pagination result consumed the replacement expectation: \(fails)")
                }
                XCTAssertTrue(error is CancellationError)
            }
            assertIssuedRenderStillPending(f, generation: generation, html: html)
            XCTAssertEqual(readerCompletions, 0)
            XCTAssertEqual(f.probe.paginationCount, 1)

            try await finishCurrentDispatchedRender(f, render: render, handoff: handoff)
            XCTAssertEqual(readerCompletions, 1)
        }
    }

    func testCommitCannotResetAReplacementThatHasNotIssuedHTML() async throws {
        let f = try fixture()
        let held = gate()
        let entered = expectation(description: "Old reader commit suspended before replacement preparation")
        f.reader.beforeCommitReturns = {
            entered.fulfill()
            await held.wait()
        }
        f.handler.onNavigationCommitted(state: f.state)
        let originalCommit = own(try XCTUnwrap(f.tasks.onNavigationCommittedTask))
        await fulfillment(of: [entered], timeout: 2)
        f.handler.onNavigationFinished(state: f.state)
        let originalFinish = own(try XCTUnwrap(f.tasks.onNavigationFinishedTask))
        let processing = gate()
        _ = try await startHeldReaderRender(f, gate: processing)
        let generation = f.mode.currentRenderGenerationDescription(for: f.state.pageURL)
        let html = f.mode.readabilityContent
        var readerCompletions = 0
        f.mode.readerModeLoadCompletionHandler = { _ in readerCompletions += 1 }
        XCTAssertEqual(f.mode.syntheticLoadElapsedString(for: f.state.pageURL), "nil")
        XCTAssertNil(f.mode.expectedSyntheticReaderLoaderURL)

        await held.release()
        for task in [originalCommit, originalFinish] {
            guard case .failure(let error)? = await settle(task, releasing: held) else {
                return XCTFail("The old commit entered Mode after replacement preparation began")
            }
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(f.mode.isReaderModeLoading)
        XCTAssertEqual(f.mode.pendingReaderModeURL, f.state.pageURL)
        XCTAssertEqual(f.mode.currentRenderGenerationDescription(for: f.state.pageURL), generation)
        XCTAssertEqual(f.mode.readabilityContent, html)
        XCTAssertNil(f.mode.lastRenderedURL)
        XCTAssertNil(f.mode.expectedSyntheticReaderLoaderURL)
        XCTAssertEqual(readerCompletions, 0)
        XCTAssertEqual(f.externalFinishCount, 0)
        XCTAssertTrue(f.media.committed.isEmpty)
        XCTAssertFalse(f.content.isReaderMainFrameNavigating)
    }

    func testCancellingANewRenderDoesNotRestoreTheOldCommitAdmission() async throws {
        let f = try fixture()
        let held = gate()
        let entered = expectation(description: "Original reader commit suspended across render allocation and cancellation")
        f.reader.beforeCommitReturns = {
            entered.fulfill()
            await held.wait()
        }
        f.handler.onNavigationCommitted(state: f.state)
        let originalCommit = own(try XCTUnwrap(f.tasks.onNavigationCommittedTask))
        await fulfillment(of: [entered], timeout: 2)
        f.handler.onNavigationFinished(state: f.state)
        let originalFinish = own(try XCTUnwrap(f.tasks.onNavigationFinishedTask))
        let processing = gate()
        let render = try await startHeldReaderRender(f, gate: processing)
        XCTAssertNotEqual(f.mode.currentRenderGenerationDescription(for: f.state.pageURL), "nil")
        f.mode.cancelReaderModeLoad(for: f.state.pageURL, reason: "fixture.renderABA")
        await processing.release()
        await settle(render)
        XCTAssertEqual(f.mode.currentRenderGenerationDescription(for: f.state.pageURL), "nil")
        let html = f.mode.readabilityContent

        await held.release()
        for task in [originalCommit, originalFinish] {
            guard case .failure(let error)? = await settle(task, releasing: held) else {
                return XCTFail("A nil-to-render-to-nil transition restored old commit authority")
            }
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(f.mode.readabilityContent, html)
        XCTAssertNil(f.mode.pendingReaderModeURL)
        XCTAssertNil(f.mode.expectedSyntheticReaderLoaderURL)
        XCTAssertFalse(f.mode.isReaderModeLoading)
        XCTAssertEqual(f.externalFinishCount, 0)
        XCTAssertTrue(f.media.committed.isEmpty)

        // A fresh callback captures the retained revision and can still retry.
        f.reader.beforeCommitReturns = nil
        try await commit(f)
        f.mode.readerModeLoading(true)
        f.handler.onNavigationFinished(state: f.state)
        guard case .success? = await settle(try XCTUnwrap(f.tasks.onNavigationFinishedTask)) else {
            return XCTFail("A fresh commit could not retry after render cancellation")
        }
        await settle(try XCTUnwrap(f.reader.finishTasks.last))
        XCTAssertFalse(f.mode.isReaderModeLoading)
        XCTAssertEqual(f.externalFinishCount, 1)
        XCTAssertEqual(f.media.committed.count, 1)
    }

    func testDuplicateActiveRenderPreservesCurrentCommitAndOrdinaryPaginationFailure() async throws {
        for fails in [false, true] {
            let f = try fixture()
            let handoff = gate()
            let render = try await startDispatchedReaderRender(f, handoffGate: handoff)
            let generation = f.mode.currentRenderGenerationDescription(for: f.state.pageURL)
            let held = gate()
            let entered = expectation(description: "Current replacement commit pagination suspended: \(fails)")
            f.probe.paginationGate = held
            f.probe.paginationEntered = entered
            f.probe.failPagination = fails
            f.handler.onNavigationCommitted(state: f.state)
            let currentCommit = own(try XCTUnwrap(f.tasks.onNavigationCommittedTask))
            await fulfillment(of: [entered], timeout: 2)
            f.probe.paginationEntered = nil
            XCTAssertFalse(f.mode.startRenderTaskIfNeeded(
                for: f.state.pageURL, reason: "fixture.duplicateActiveRender"
            ) { _ in
                XCTFail("An already active render ran a duplicate operation")
            })
            XCTAssertEqual(f.mode.currentRenderGenerationDescription(for: f.state.pageURL), generation)
            XCTAssertNotEqual(f.mode.syntheticLoadElapsedString(for: f.state.pageURL), "nil")

            await held.release()
            guard case .success? = await settle(currentCommit, releasing: held) else {
                return XCTFail("An unchanged active render retired its current native commit: \(fails)")
            }
            XCTAssertNil(f.mode.expectedSyntheticReaderLoaderURL)
            await handoff.release()
            await settle(render)
            var readerCompletions = 0
            f.mode.readerModeLoadCompletionHandler = { _ in readerCompletions += 1 }
            f.handler.onNavigationFinished(state: f.state)
            guard case .success? = await settle(try XCTUnwrap(f.tasks.onNavigationFinishedTask)) else {
                return XCTFail("Current replacement finish did not settle")
            }
            await settle(try XCTUnwrap(f.reader.finishTasks.last))
            XCTAssertEqual(f.mode.currentRenderGenerationDescription(for: f.state.pageURL), generation)
            XCTAssertFalse(f.mode.isReaderModeLoading)
            XCTAssertNil(f.mode.pendingReaderModeURL)
            XCTAssertEqual(f.mode.lastRenderedURL, f.state.pageURL)
            XCTAssertEqual(readerCompletions, 1)
            XCTAssertEqual(f.externalFinishCount, 1)
            XCTAssertEqual(f.media.committed.count, 1)
        }
    }

    func testPublicModeCommitEntryCapturesItsOwnRenderAdmission() async throws {
        let f = try fixture()
        let held = gate()
        let entered = expectation(description: "Public Mode commit pagination suspended")
        f.probe.paginationGate = held
        f.probe.paginationEntered = entered
        let original = own(Task { @MainActor in
            try await f.mode.onNavigationCommitted(
                readerContent: f.content, newState: f.state, scriptCaller: f.reader.scriptCaller
            )
        })
        await fulfillment(of: [entered], timeout: 2)
        f.probe.paginationEntered = nil
        let handoff = gate()
        let render = try await startDispatchedReaderRender(f, handoffGate: handoff)
        let html = f.mode.readabilityContent
        let generation = f.mode.currentRenderGenerationDescription(for: f.state.pageURL)

        await held.release()
        guard case .failure(let error)? = await settle(original, releasing: held) else {
            return XCTFail("The public Mode entry adopted a later render")
        }
        XCTAssertTrue(error is CancellationError)
        assertIssuedRenderStillPending(f, generation: generation, html: html)

        // Preserve the existing public signature and its fresh current path.
        f.probe.paginationGate = nil
        await handoff.release()
        await settle(render)
        try await f.mode.onNavigationCommitted(
            readerContent: f.content, newState: f.state, scriptCaller: f.reader.scriptCaller
        )
        XCTAssertNil(f.mode.expectedSyntheticReaderLoaderURL)
        XCTAssertTrue(f.mode.isReaderModeLoading)
        let currentGeneration = try XCTUnwrap(UUID(uuidString: generation))
        XCTAssertTrue(f.mode.handleRenderedReaderDocumentReady(
            pageURL: f.state.pageURL, hasReaderContent: true, renderGeneration: currentGeneration
        ))
        XCTAssertFalse(f.mode.isReaderModeLoading)
        XCTAssertNil(f.mode.pendingReaderModeURL)
        XCTAssertEqual(f.mode.lastRenderedURL, f.state.pageURL)
    }

    func testFinishArrivingAfterReaderPreparationStartsCannotCompleteIt() async throws {
        let f = try fixture()
        try await commit(f)
        let processing = gate()
        _ = try await startHeldReaderRender(f, gate: processing)
        var readerCompletions = 0
        f.mode.readerModeLoadCompletionHandler = { _ in readerCompletions += 1 }
        f.handler.onNavigationFinished(state: f.state)
        guard case .success? = await settle(try XCTUnwrap(f.tasks.onNavigationFinishedTask)) else {
            return XCTFail("The original native document's callback did not finish")
        }
        await settle(try XCTUnwrap(f.reader.finishTasks.last))

        XCTAssertTrue(f.mode.isReaderModeLoading)
        XCTAssertEqual(f.mode.pendingReaderModeURL, f.state.pageURL)
        XCTAssertNil(f.mode.lastRenderedURL)
        XCTAssertEqual(readerCompletions, 0)
        XCTAssertEqual(f.probe.finishCount, 0)
        XCTAssertEqual(f.externalFinishCount, 1)
        XCTAssertFalse(f.content.isReaderMainFrameNavigating)
    }

    func testFinishWaitingForCommitCannotAdoptPreparationStartedDuringThatWait() async throws {
        let f = try fixture()
        let committed = gate()
        let commitEntered = expectation(description: "Public callback holds the actual completed mode/media commit")
        f.handler.onNavigationCommitted = { _ in
            commitEntered.fulfill()
            await committed.wait()
        }
        f.handler.onNavigationCommitted(state: f.state)
        let commitTask = own(try XCTUnwrap(f.tasks.onNavigationCommittedTask))
        await fulfillment(of: [commitEntered], timeout: 2)
        f.handler.onNavigationFinished(state: f.state)
        let finish = own(try XCTUnwrap(f.tasks.onNavigationFinishedTask))
        let processing = gate()
        _ = try await startHeldReaderRender(f, gate: processing)
        var readerCompletions = 0
        f.mode.readerModeLoadCompletionHandler = { _ in readerCompletions += 1 }

        await committed.release()
        _ = await settle(commitTask)
        guard case .success? = await settle(finish) else {
            return XCTFail("The native finish did not settle after its actual commit")
        }
        await settle(try XCTUnwrap(f.reader.finishTasks.last))
        XCTAssertTrue(f.mode.isReaderModeLoading)
        XCTAssertEqual(f.mode.pendingReaderModeURL, f.state.pageURL)
        XCTAssertNil(f.mode.lastRenderedURL)
        XCTAssertEqual(readerCompletions, 0)
        XCTAssertEqual(f.probe.finishCount, 0)
        XCTAssertEqual(f.externalFinishCount, 1)
        XCTAssertFalse(f.content.isReaderMainFrameNavigating)
    }

    func testOldFontFinishCannotCompleteANewRenderOfTheSameSelection() async throws {
        let f = try fixture()
        try await commit(f)
        var readerCompletions = 0
        f.mode.readerModeLoadCompletionHandler = { _ in readerCompletions += 1 }
        let finish = try await holdFinishAtFontBridge(f)
        XCTAssertEqual(f.probe.fontCount, 1)
        let processing = gate()
        _ = try await startHeldReaderRender(f, gate: processing)
        let generation = f.mode.currentRenderGenerationDescription(for: f.state.pageURL)
        XCTAssertNotNil(UUID(uuidString: generation))

        await finish.gate.release()
        guard case .success? = await settle(finish.task) else {
            return XCTFail("The unchanged native document's finish was retired")
        }
        await settle(try XCTUnwrap(f.reader.finishTasks.last))
        XCTAssertTrue(f.mode.isReaderModeLoading)
        XCTAssertEqual(f.mode.pendingReaderModeURL, f.state.pageURL)
        XCTAssertNil(f.mode.lastRenderedURL)
        XCTAssertEqual(f.mode.currentRenderGenerationDescription(for: f.state.pageURL), generation)
        XCTAssertEqual(readerCompletions, 0)
        XCTAssertEqual(f.probe.finishCount, 0)
        XCTAssertEqual(f.externalFinishCount, 1)
        XCTAssertFalse(f.content.isReaderMainFrameNavigating)
    }

    func testLateFinishFalseOrErrorKeepsNewRenderLoadingAndAllowsFreshRetry() async throws {
        for fails in [false, true] {
            let f = try fixture()
            try await commit(f)
            var readerCompletions = 0
            f.mode.readerModeLoadCompletionHandler = { _ in readerCompletions += 1 }
            let held = gate()
            f.probe.finishGate = held
            f.probe.failFinish = fails
            let entered = expectation(description: "Old finish query suspended: \(fails)")
            f.probe.finishEntered = entered
            f.handler.onNavigationFinished(state: f.state)
            let finish = own(try XCTUnwrap(f.tasks.onNavigationFinishedTask))
            await fulfillment(of: [entered], timeout: 2)
            f.probe.finishEntered = nil
            let processing = gate()
            let render = try await startHeldReaderRender(f, gate: processing)

            await held.release()
            _ = await settle(finish)
            await settle(try XCTUnwrap(f.reader.finishTasks.last))
            XCTAssertTrue(f.mode.isReaderModeLoading, "failed query: \(fails)")
            XCTAssertEqual(f.mode.pendingReaderModeURL, f.state.pageURL)
            XCTAssertNil(f.mode.lastRenderedURL)
            XCTAssertEqual(readerCompletions, 0)
            XCTAssertEqual(f.externalFinishCount, 1)
            XCTAssertFalse(f.content.isReaderMainFrameNavigating)

            f.mode.cancelReaderModeLoad(for: f.state.pageURL, reason: "fixture.retry")
            await processing.release()
            await settle(render)
            f.probe.finishGate = nil
            f.probe.failFinish = false
            try await commit(f)
            f.mode.readerModeLoading(true)
            f.handler.onNavigationFinished(state: f.state)
            guard case .success? = await settle(try XCTUnwrap(f.tasks.onNavigationFinishedTask)) else {
                return XCTFail("A fresh native finish could not retry")
            }
            await settle(try XCTUnwrap(f.reader.finishTasks.last))
            XCTAssertFalse(f.mode.isReaderModeLoading)
            XCTAssertNil(f.mode.pendingReaderModeURL)
            XCTAssertEqual(f.externalFinishCount, 2)
        }
    }

    func testFinishCannotAdoptAReplacementRenderUUIDForTheSameURL() async throws {
        let f = try fixture()
        let url = f.state.pageURL
        try await commit(f)
        let firstHandoff = gate()
        let firstRender = try await startDispatchedReaderRender(f, handoffGate: firstHandoff)
        let firstGeneration = f.mode.currentRenderGenerationDescription(for: f.state.pageURL)
        try await commit(f)
        var readerCompletions = 0
        f.mode.readerModeLoadCompletionHandler = { _ in readerCompletions += 1 }
        let held = gate()
        let entered = expectation(description: "First render's native finish query suspended")
        f.probe.finishGate = held
        f.probe.finishEntered = entered
        f.handler.onNavigationFinished(state: f.state)
        let finish = own(try XCTUnwrap(f.tasks.onNavigationFinishedTask))
        await fulfillment(of: [entered], timeout: 2)
        f.probe.finishEntered = nil
        XCTAssertEqual(readerCompletions, 1)

        f.mode.cancelReaderModeLoad(for: f.state.pageURL, reason: "fixture.sameURLReplacement")
        let secondProcessing = gate()
        _ = try await startHeldReaderRender(f, gate: secondProcessing)
        let secondGeneration = f.mode.currentRenderGenerationDescription(for: f.state.pageURL)
        XCTAssertNotNil(UUID(uuidString: firstGeneration))
        XCTAssertNotNil(UUID(uuidString: secondGeneration))
        XCTAssertNotEqual(firstGeneration, secondGeneration)
        XCTAssertEqual(f.mode.syntheticLoadElapsedString(for: url), "nil")
        await firstHandoff.release()
        await settle(firstRender)
        await held.release()
        _ = await settle(finish)

        XCTAssertTrue(f.mode.isReaderModeLoading)
        XCTAssertEqual(f.mode.pendingReaderModeURL, f.state.pageURL)
        XCTAssertEqual(f.mode.currentRenderGenerationDescription(for: f.state.pageURL), secondGeneration)
        XCTAssertEqual(readerCompletions, 1)
        XCTAssertEqual(f.externalFinishCount, 1)
    }

    func testCurrentFinishAcceptsActiveToCompletedRenderHandoffOnSuccessOrError() async throws {
        for fails in [false, true] {
            let f = try fixture()
            let url = f.state.pageURL
            try await commit(f)
            let handoff = gate()
            let render = try await startDispatchedReaderRender(f, handoffGate: handoff)
            let generation = f.mode.currentRenderGenerationDescription(for: f.state.pageURL)
            XCTAssertEqual(f.mode.expectedSyntheticReaderLoaderURL, url)
            try await commit(f)
            XCTAssertNil(f.mode.expectedSyntheticReaderLoaderURL)
            var readerCompletions = 0
            f.mode.readerModeLoadCompletionHandler = { _ in readerCompletions += 1 }
            f.probe.failFinish = fails
            let finish = try await holdFinishAtFontBridge(f)

            await handoff.release()
            await settle(render)
            XCTAssertNil(f.mode.activeRenderTask(for: f.state.pageURL))
            XCTAssertEqual(f.mode.currentRenderGenerationDescription(for: f.state.pageURL), generation)
            await finish.gate.release()
            guard case .success? = await settle(finish.task) else {
                return XCTFail("Current render handoff was incorrectly retired")
            }
            await settle(try XCTUnwrap(f.reader.finishTasks.last))
            XCTAssertFalse(f.mode.isReaderModeLoading)
            XCTAssertNil(f.mode.pendingReaderModeURL)
            XCTAssertEqual(f.mode.lastRenderedURL, f.state.pageURL)
            XCTAssertEqual(readerCompletions, 1)
            XCTAssertEqual(f.probe.finishCount, 1)
            XCTAssertEqual(f.externalFinishCount, 1)
        }
    }

    func testOldSameURLRenderedPageCannotConsumeAnUncommittedReplacementExpectation() async throws {
        let f = try fixture()
        try await commit(f)
        let firstHandoff = gate()
        let firstRender = try await startDispatchedReaderRender(f, handoffGate: firstHandoff)
        let firstGeneration = try XCTUnwrap(UUID(uuidString: f.mode.currentRenderGenerationDescription(for: f.state.pageURL)))
        let committed = gate()
        let commitEntered = expectation(description: "First Reader document committed before its public callback completes")
        f.handler.onNavigationCommitted = { _ in
            commitEntered.fulfill()
            await committed.wait()
        }
        f.handler.onNavigationCommitted(state: f.state)
        let firstCommit = own(try XCTUnwrap(f.tasks.onNavigationCommittedTask))
        await fulfillment(of: [commitEntered], timeout: 2)
        XCTAssertNil(f.mode.expectedSyntheticReaderLoaderURL)
        var readerCompletions = 0
        f.mode.readerModeLoadCompletionHandler = { _ in readerCompletions += 1 }
        XCTAssertTrue(f.mode.handleRenderedReaderDocumentReady(
            pageURL: f.state.pageURL, hasReaderContent: true, renderGeneration: firstGeneration
        ))
        XCTAssertEqual(readerCompletions, 1)
        XCTAssertEqual(f.mode.lastRenderedURL, f.state.pageURL)
        await firstHandoff.release()
        await settle(firstRender)

        // Queue the old document's native finish before issuing the replacement.
        // The manager must await its still-held public commit callback.
        f.handler.onNavigationFinished(state: f.state)
        let oldFinish = own(try XCTUnwrap(f.tasks.onNavigationFinishedTask))
        let secondHandoff = gate()
        let secondRender = try await startDispatchedReaderRender(f, handoffGate: secondHandoff)
        let secondGeneration = f.mode.currentRenderGenerationDescription(for: f.state.pageURL)
        XCTAssertNotEqual(secondGeneration, firstGeneration.uuidString)
        XCTAssertTrue(f.mode.isReaderMode)
        XCTAssertTrue(f.mode.isReaderModeLoading)
        XCTAssertEqual(f.mode.lastRenderedURL, f.state.pageURL)
        XCTAssertEqual(f.mode.expectedSyntheticReaderLoaderURL, f.state.pageURL)

        await committed.release()
        _ = await settle(firstCommit)
        guard case .success? = await settle(oldFinish) else {
            return XCTFail("The original native callback did not settle")
        }
        await settle(try XCTUnwrap(f.reader.finishTasks.last))
        XCTAssertTrue(f.mode.isReaderModeLoading)
        XCTAssertEqual(f.mode.pendingReaderModeURL, f.state.pageURL)
        XCTAssertEqual(f.mode.expectedSyntheticReaderLoaderURL, f.state.pageURL)
        XCTAssertEqual(readerCompletions, 1)
        XCTAssertEqual(f.probe.finishCount, 0)
        XCTAssertEqual(f.externalFinishCount, 1)
        XCTAssertFalse(f.content.isReaderMainFrameNavigating)

        f.handler.onNavigationCommitted = nil
        await secondHandoff.release()
        await settle(secondRender)
        try await commit(f)
        XCTAssertNil(f.mode.expectedSyntheticReaderLoaderURL)
        f.handler.onNavigationFinished(state: f.state)
        guard case .success? = await settle(try XCTUnwrap(f.tasks.onNavigationFinishedTask)) else {
            return XCTFail("The actual replacement document's finish was rejected")
        }
        await settle(try XCTUnwrap(f.reader.finishTasks.last))
        XCTAssertFalse(f.mode.isReaderModeLoading)
        XCTAssertNil(f.mode.pendingReaderModeURL)
        XCTAssertEqual(readerCompletions, 2)
        XCTAssertEqual(f.probe.finishCount, 1)
        XCTAssertEqual(f.externalFinishCount, 2)
    }

    func testReaderCompletionReentryKeepsItsNewRenderOutOfTheOldFinishQuery() async throws {
        let f = try fixture()
        try await commit(f)
        let processing = gate()
        let entered = expectation(description: "Completion callback's real Reader render suspended")
        prepareHeldReaderRender(f, gate: processing, entered: entered)
        f.mode.beginReaderModeLoad(for: f.state.pageURL, reason: "fixture.currentFinish")
        var readerCompletions = 0
        var reentrantRender: Task<Void, Never>?
        f.mode.readerModeLoadCompletionHandler = { [weak f] _ in
            guard let f else { return }
            readerCompletions += 1
            f.mode.showReaderView(readerContent: f.content, scriptCaller: f.reader.scriptCaller)
            reentrantRender = f.mode.activeRenderTask(for: f.state.pageURL)
        }
        f.handler.onNavigationFinished(state: f.state)
        let finish = own(try XCTUnwrap(f.tasks.onNavigationFinishedTask))
        await fulfillment(of: [entered], timeout: 2)
        _ = own(try XCTUnwrap(reentrantRender))
        _ = await settle(finish)
        await settle(try XCTUnwrap(f.reader.finishTasks.last))

        XCTAssertTrue(f.mode.isReaderModeLoading)
        XCTAssertEqual(f.mode.pendingReaderModeURL, f.state.pageURL)
        XCTAssertNil(f.mode.lastRenderedURL)
        XCTAssertEqual(readerCompletions, 1)
        XCTAssertEqual(f.probe.finishCount, 0)
        XCTAssertEqual(f.externalFinishCount, 1)
        XCTAssertFalse(f.content.isReaderMainFrameNavigating)
    }

    func testCancelledFinishDoesNotCompleteNewRenderStartedDuringFontWait() async throws {
        let f = try fixture()
        try await commit(f)
        var readerCompletions = 0
        f.mode.readerModeLoadCompletionHandler = { _ in readerCompletions += 1 }
        let finish = try await holdFinishAtFontBridge(f)
        let processing = gate()
        _ = try await startHeldReaderRender(f, gate: processing)
        finish.task.cancel()
        await finish.gate.release()
        guard case .failure(let error)? = await settle(finish.task) else {
            return XCTFail("Cancelled native finish succeeded")
        }
        XCTAssertTrue(error is CancellationError)
        XCTAssertTrue(f.mode.isReaderModeLoading)
        XCTAssertEqual(f.mode.pendingReaderModeURL, f.state.pageURL)
        XCTAssertNil(f.mode.lastRenderedURL)
        XCTAssertEqual(readerCompletions, 0)
        XCTAssertEqual(f.probe.finishCount, 0)
        XCTAssertEqual(f.externalFinishCount, 0)
        XCTAssertFalse(f.content.isReaderMainFrameNavigating)
    }

    func testOwnerReplacementImmediatelyRetiresHeldOldActivityAndAllowsCurrentFinish() async throws {
        let f = try fixture()
        f.content.replaceSelection(with: nil)
        let held = gate()
        let entered = expectation(description: "Old owner's actual resolver suspended")
        ReaderContent.contentResolver = { _, _, _ in
            entered.fulfill()
            await held.wait()
            return f.record
        }
        f.handler.onNavigationCommitted(state: f.state)
        let old = own(try XCTUnwrap(f.tasks.onNavigationCommittedTask))
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(f.content.isReaderMainFrameNavigating)

        let current = ReaderContent()
        let currentRecord = HistoryRecord()
        currentRecord.compoundKey = UUID().uuidString
        currentRecord.url = f.state.pageURL
        currentRecord.title = "Replacement owner"
        currentRecord.rssContainsFullContent = true
        current.pageURL = f.state.pageURL
        current.replaceSelection(with: currentRecord)
        f.rebuildHandler(readerContent: current)
        XCTAssertTrue(old.isCancelled)
        XCTAssertFalse(f.content.isReaderMainFrameNavigating)
        XCTAssertNil(f.tasks.committedCallbackContext)

        f.handler.onNavigationCommitted(state: f.state)
        f.handler.onNavigationFinished(state: f.state)
        guard case .success? = await settle(try XCTUnwrap(f.tasks.onNavigationFinishedTask)) else {
            return XCTFail("Current owner was blocked by old held work")
        }
        await settle(try XCTUnwrap(f.reader.finishTasks.last))
        XCTAssertEqual(f.probe.titles, ["Replacement owner"])
        XCTAssertFalse(current.isReaderMainFrameNavigating)
        await held.release()
        guard case .failure(let error)? = await settle(old, releasing: held) else {
            return XCTFail("Retired owner's held commit survived")
        }
        XCTAssertTrue(error is CancellationError)
        XCTAssertTrue(current.content === currentRecord)
        XCTAssertEqual(f.externalFinishCount, 1)
        XCTAssertEqual(f.probe.titles, ["Replacement owner"])
    }

    func testQueuedFailureCannotPublishForAReplacedOwner() async throws {
        for preserves in [false, true] {
            let f = try fixture()
            try await commit(f)
            var failures = 0
            f.handler.onNavigationFailed = { _ in failures += 1 }
            f.handler.onNavigationFailed(
                state: f.state,
                disposition: preserves ? .preservedCommittedDocument : .terminal
            )
            let failure = own(try XCTUnwrap(f.tasks.onNavigationFailedTask))
            f.rebuildHandler(readerContent: ReaderContent())
            _ = await settle(failure)
            XCTAssertEqual(failures, 0)
            XCTAssertFalse(f.content.isReaderMainFrameNavigating)
        }
    }

    func testActivityPublicationReentryRetiresRemainingFailureAndInvalidationCallbacks() async throws {
        for path in ["preservedFailure", "terminalFailure", "invalidation"] {
            let f = try fixture()
            try await commit(f)
            f.mode.readerModeLoading(true)
            var failures = 0
            var invalidations = 0
            f.handler.onNavigationFailed = { _ in failures += 1 }
            f.handler.onDocumentContextInvalidated = { _, _ in invalidations += 1 }
            let replacement = ReaderContent()
            var replaced = false
            let observation = f.content.$isReaderMainFrameNavigating.dropFirst().sink { navigating in
                guard !navigating, !replaced else { return }
                replaced = true
                f.rebuildHandler(readerContent: replacement)
            }
            defer { observation.cancel() }
            switch path {
            case "preservedFailure":
                f.handler.onNavigationFailed(state: f.state, disposition: .preservedCommittedDocument)
                let failure = own(try XCTUnwrap(f.tasks.onNavigationFailedTask))
                _ = await settle(failure)
            case "terminalFailure":
                f.handler.onNavigationFailed(state: f.state, disposition: .terminal)
                XCTAssertNil(f.tasks.onNavigationFailedTask)
            default:
                f.handler.onDocumentContextInvalidated(
                    state: f.state, reason: .webContentProcessTerminated
                )
            }
            XCTAssertTrue(replaced, path)
            XCTAssertEqual(failures, 0, path)
            XCTAssertEqual(invalidations, 0, path)
            XCTAssertTrue(f.mode.isReaderModeLoading, path)
            XCTAssertFalse(f.content.isReaderMainFrameNavigating, path)
        }
    }

    func testCurrentUnboundPublicFinishStillCompletesWithoutJavaScript() async throws {
        for change in ["live", "binding", "caller", "invalidated"] {
            let f = try fixture(managed: true, bindCaller: false)
            var completions = 0
            f.reader.onNavigationFinished(
                content: f.record, newState: f.state,
                completion: { _ in completions += 1 }
            )
            let task = own(try XCTUnwrap(f.reader.finishTasks.last))
            switch change {
            case "binding": f.probe.bind(f.reader.scriptCaller)
            case "caller": f.reader.scriptCaller = WebViewScriptCaller()
            case "invalidated":
                let realm = try XCTUnwrap(f.realm)
                try realm.write { realm.delete(f.record) }
            default: break
            }
            await settle(task)
            XCTAssertEqual(completions, change == "live" ? 1 : 0, change)
            XCTAssertEqual(f.probe.settingsCount, 0, change)
            XCTAssertTrue(f.probe.titles.isEmpty, change)
        }
    }

    func testRetiredWrapperCallbacksCannotRetireOrFinishCurrentOwner() async throws {
        let f = try fixture()
        try await commit(f)
        let retiredHandler = f.handler
        var retiredCallbacks = 0
        retiredHandler.onNavigationCommitted = { _ in retiredCallbacks += 1 }
        retiredHandler.onNavigationFinished = { _ in retiredCallbacks += 1 }
        retiredHandler.onNavigationFailed = { _ in retiredCallbacks += 1 }
        retiredHandler.onDocumentContextInvalidated = { _, _ in retiredCallbacks += 1 }
        retiredHandler.onURLChanged = { _ in retiredCallbacks += 1 }

        let replacement = ReaderContent()
        let currentRecord = HistoryRecord()
        currentRecord.compoundKey = UUID().uuidString
        currentRecord.url = f.state.pageURL
        currentRecord.title = "Current owner title"
        currentRecord.rssContainsFullContent = true
        replacement.pageURL = f.state.pageURL
        replacement.replaceSelection(with: currentRecord)
        f.rebuildHandler(readerContent: replacement)
        f.handler.onNavigationCommitted(state: f.state)
        guard case .success? = await settle(try XCTUnwrap(f.tasks.onNavigationCommittedTask)) else {
            return XCTFail("Current owner did not commit")
        }
        let currentContext = try XCTUnwrap(f.tasks.committedCallbackContext)
        let currentDocument = f.tasks.makeDocumentCommitFence()
        f.mode.readerModeLoading(true)

        retiredHandler.onNavigationCommitted(state: f.state)
        retiredHandler.onNavigationFinished(state: f.state)
        retiredHandler.onNavigationFailed(state: f.state, disposition: .terminal)
        retiredHandler.onDocumentContextInvalidated(state: f.state, reason: .webContentProcessTerminated)
        retiredHandler.onURLChanged(state: f.state)

        XCTAssertTrue(f.tasks.committedCallbackContext === currentContext)
        XCTAssertTrue(currentDocument())
        XCTAssertTrue(replacement.isReaderMainFrameNavigating)
        XCTAssertTrue(f.mode.isReaderModeLoading)
        XCTAssertNil(f.tasks.onNavigationFinishedTask)
        XCTAssertNil(f.tasks.onNavigationFailedTask)
        XCTAssertNil(f.tasks.onURLChangedTask)
        XCTAssertEqual(retiredCallbacks, 0)
        XCTAssertEqual(f.externalFinishCount, 0)

        f.handler.onNavigationFinished(state: f.state)
        guard case .success? = await settle(try XCTUnwrap(f.tasks.onNavigationFinishedTask)) else {
            return XCTFail("Current owner lost its valid finish")
        }
        await settle(try XCTUnwrap(f.reader.finishTasks.last))
        XCTAssertFalse(replacement.isReaderMainFrameNavigating)
        XCTAssertEqual(f.externalFinishCount, 1)
        XCTAssertEqual(retiredCallbacks, 0)
        XCTAssertEqual(f.probe.titles, ["Current owner title"])
    }

    func testLoadReceiptRejectsDirectContentReplacementDuringResolverPublication() async throws {
        let f = try fixture()
        f.content.replaceSelection(with: nil)
        let replacement = HistoryRecord()
        replacement.compoundKey = UUID().uuidString
        replacement.url = f.state.pageURL
        replacement.title = "Reentrant replacement"
        var replaced = false
        let observation = f.content.contentTitleSubject.sink { title in
            guard title == "Original title", !replaced else { return }
            replaced = true
            // Preserve the selected API's existing direct-publication case:
            // this does not advance selectionID through replaceSelection.
            f.content.content = replacement
        }
        defer { observation.cancel() }
        ReaderContent.contentResolver = { _, _, _ in f.record }
        f.handler.onNavigationCommitted(state: f.state)
        guard case .failure(let error)? = await settle(try XCTUnwrap(f.tasks.onNavigationCommittedTask)) else {
            return XCTFail("Commit adopted a result that its resolver did not publish")
        }
        XCTAssertTrue(error is CancellationError)
        XCTAssertTrue(replaced)
        XCTAssertTrue(f.content.content === replacement)
        XCTAssertEqual(f.reader.commitCount, 0)
        XCTAssertTrue(f.media.committed.isEmpty)
        XCTAssertFalse(f.content.isReaderMainFrameNavigating)
    }

    func testLoadReceiptDoesNotRetainItsContentOwner() async throws {
        var content: ReaderContent? = ReaderContent()
        let record = HistoryRecord()
        record.url = URL(string: "https://example.invalid/load-receipt-owner")!
        record.compoundKey = UUID().uuidString
        content?.preloadResolvedContent(record, for: record.url)
        let receipt = try await XCTUnwrap(content).loadWithSelectionReceipt(url: record.url)
        weak var weakContent = content
        XCTAssertTrue(receipt.isCurrent)
        content = nil
        XCTAssertNil(weakContent)
        XCTAssertFalse(receipt.isCurrent)
    }


    func testRebuiltHandlerUsesPersistentCommitContextAndRejectsReplacementModels() async throws {
        for change in ["same", "content", "reader", "mode", "media", "caller", "aba"] {
            let f = try fixture()
            try await commit(f)
            switch change {
            case "content":
                let replacement = ReaderContent()
                replacement.pageURL = f.state.pageURL
                replacement.replaceSelection(with: f.record)
                f.rebuildHandler(readerContent: replacement)
            case "reader":
                let replacement = NavigationLifetimeReader(
                    realmConfiguration: f.libraryConfiguration, systemScripts: []
                )
                replacement.state = f.state
                replacement.scriptCaller = f.reader.scriptCaller
                f.rebuildHandler(readerViewModel: replacement)
            case "mode": f.rebuildHandler(readerModeViewModel: ReaderModeViewModel())
            case "media": f.rebuildHandler(readerMediaPlayerViewModel: NavigationLifetimeMedia())
            case "caller":
                let replacement = WebViewScriptCaller()
                f.probe.bind(replacement)
                f.rebuildHandler(scriptCaller: replacement)
            case "aba":
                f.rebuildHandler(readerContent: ReaderContent())
                f.rebuildHandler()
            default: f.rebuildHandler()
            }
            // The actual finish callback is delivered to a different wrapper,
            // exactly as ReaderWebView.body reconstructs it after a render.
            f.handler.onNavigationFinished(state: f.state)
            if change == "same" {
                let outcome = await settle(try XCTUnwrap(f.tasks.onNavigationFinishedTask))
                guard case .success? = outcome else { return XCTFail("Rebuilt live handler lost its commit") }
                await settle(try XCTUnwrap(f.reader.finishTasks.last))
                XCTAssertEqual(f.externalFinishCount, 1)
                XCTAssertEqual(f.probe.titles, ["Original title"])
            } else {
                XCTAssertNil(f.tasks.committedCallbackContext, change)
                XCTAssertNil(f.tasks.onNavigationCommittedTask, change)
                XCTAssertNil(f.tasks.onNavigationFinishedTask, change)
                XCTAssertEqual(f.externalFinishCount, 0, change)
                XCTAssertTrue(f.reader.finishTasks.isEmpty, change)
                XCTAssertTrue(f.probe.titles.isEmpty, change)
            }
            XCTAssertFalse(f.content.isReaderMainFrameNavigating, change)
        }
    }

    func testHeldActualResolverCannotDonateSameURLReplacementToOldCommitOrFinish() async throws {
        let f = try fixture()
        f.content.replaceSelection(with: nil)
        f.mode.readabilityContent = "Unchanged readability"
        let held = gate()
        let entered = expectation(description: "Actual ReaderContent resolver suspended")
        ReaderContent.contentResolver = { _, _, _ in
            entered.fulfill()
            await held.wait()
            // Deliberately ignore cancellation to exercise the production
            // resolver's normal nil-result retirement and caller resumption.
            return f.record
        }
        f.handler.onNavigationCommitted(state: f.state)
        let commit = own(try XCTUnwrap(f.tasks.onNavigationCommittedTask))
        f.handler.onNavigationFinished(state: f.state)
        let finish = own(try XCTUnwrap(f.tasks.onNavigationFinishedTask))
        await fulfillment(of: [entered], timeout: 2)
        f.replaceSelection()
        let replacement = f.content.content
        await held.release()
        for task in [commit, finish] {
            guard case .failure(let error)? = await settle(task, releasing: held) else {
                return XCTFail("Retired resolver admitted a successor selection")
            }
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(f.content.content === replacement)
        XCTAssertEqual(f.reader.commitCount, 0)
        XCTAssertEqual(f.mode.readabilityContent, "Unchanged readability")
        XCTAssertTrue(f.media.committed.isEmpty)
        XCTAssertEqual(f.externalFinishCount, 0)
        XCTAssertEqual(f.probe.finishCount, 0)
        XCTAssertEqual(f.probe.settingsCount, 0)
        XCTAssertFalse(f.content.isReaderMainFrameNavigating)
    }

    func testActualCoalescedLoadReceiptsKeepOriginalSelectionAndCallerCancellation() async throws {
        for change in ["live", "replacement", "cancelledWaiter"] {
            let f = try fixture()
            f.content.replaceSelection(with: nil)
            let held = gate()
            let entered = expectation(description: "Shared production resolver entered")
            let waiterEntered = expectation(description: "Coalesced caller entered")
            var resolverCount = 0
            ReaderContent.contentResolver = { _, _, _ in
                resolverCount += 1
                entered.fulfill()
                await held.wait()
                return f.record
            }
            let original = own(Task { @MainActor in
                try await f.content.loadWithSelectionReceipt(url: f.state.pageURL)
            })
            await fulfillment(of: [entered], timeout: 2)
            let waiter = own(Task { @MainActor in
                waiterEntered.fulfill()
                return try await f.content.loadWithSelectionReceipt(url: f.state.pageURL)
            })
            await fulfillment(of: [waiterEntered], timeout: 2)
            if change == "replacement" { f.replaceSelection(returnToOriginal: true) }
            if change == "cancelledWaiter" { waiter.cancel() }
            await held.release()
            let originalResult = await settle(original, releasing: held)
            let waiterResult = await settle(waiter, releasing: held)
            XCTAssertEqual(resolverCount, 1, change)
            if change == "replacement" {
                for outcome in [originalResult, waiterResult] {
                    guard case .failure(let error)? = outcome else {
                        return XCTFail("Coalesced receipt adopted a later selection")
                    }
                    XCTAssertTrue(error is CancellationError)
                }
            } else {
                guard case .success(let receipt)? = originalResult else {
                    return XCTFail("Current original load failed")
                }
                XCTAssertTrue(receipt.isCurrent)
                if change == "cancelledWaiter" {
                    guard case .failure(let error)? = waiterResult else {
                        return XCTFail("Cancelled waiter retained admission")
                    }
                    XCTAssertTrue(error is CancellationError)
                } else {
                    guard case .success(let otherReceipt)? = waiterResult else {
                        return XCTFail("Current coalesced load failed")
                    }
                    XCTAssertTrue(otherReceipt.isCurrent)
                    f.replaceSelection(returnToOriginal: true)
                    XCTAssertFalse(otherReceipt.isCurrent)
                }
                if change == "cancelledWaiter" { f.replaceSelection(returnToOriginal: true) }
                XCTAssertFalse(receipt.isCurrent)
            }
        }
    }

    func testMountedTwoArgumentRefreshCapturesSelectionAndRejectsStalePassedObject() async throws {
        let f = try fixture()
        let refresh: @MainActor (any ReaderContentProtocol, WebViewState?) -> Void =
            f.reader.refreshSettingsInWebView
        refresh(f.record, f.state)
        let queued = own(try XCTUnwrap(f.reader.refreshTasks.last))
        f.replaceSelection(returnToOriginal: true)
        await settle(queued)
        XCTAssertEqual(f.probe.settingsCount, 0)
        XCTAssertTrue(f.probe.titles.isEmpty)

        f.replaceSelection()
        let priorCount = f.reader.refreshTasks.count
        // Mirrors an old readabilityFramePing returning from its await after
        // a same-URL replacement. The current B fence cannot authorize A.
        refresh(f.record, f.state)
        XCTAssertEqual(f.reader.refreshTasks.count, priorCount)

        let current = try XCTUnwrap(f.content.content)
        refresh(current, f.state)
        await settle(try XCTUnwrap(f.reader.refreshTasks.last))
        XCTAssertEqual(f.probe.settingsCount, 1)
        XCTAssertEqual(f.probe.titles, ["Successor title"])

        // Replacing the mounted model without a native navigation still admits
        // a fresh invocation on the unchanged, bound page.
        let newOwner = ReaderContent()
        newOwner.pageURL = f.state.pageURL
        newOwner.replaceSelection(with: current)
        f.rebuildHandler(readerContent: newOwner)
        let beforeNewOwnerRefresh = f.reader.refreshTasks.count
        refresh(current, f.state)
        XCTAssertEqual(f.reader.refreshTasks.count, beforeNewOwnerRefresh + 1)
        await settle(try XCTUnwrap(f.reader.refreshTasks.last))
        XCTAssertEqual(f.probe.settingsCount, 2)
        XCTAssertEqual(f.probe.titles, ["Successor title", "Successor title"])
    }

    func testRebuiltLiveHandlerKeepsAlreadyScheduledSettingsAdmission() async throws {
        let f = try fixture()
        try await commit(f)
        let held = gate()
        f.probe.settingsGate = held
        f.probe.settingsEntered = expectation(description: "Settings held across handler rebuild")
        f.handler.onNavigationFinished(state: f.state)
        _ = await settle(try XCTUnwrap(f.tasks.onNavigationFinishedTask))
        await fulfillment(of: [try XCTUnwrap(f.probe.settingsEntered)], timeout: 2)
        let settings = own(try XCTUnwrap(f.reader.finishTasks.last))
        f.rebuildHandler()
        await held.release()
        await settle(settings, releasing: held)
        XCTAssertEqual(f.probe.titles, ["Original title"])
    }


    func testFinishQueuedBeforeCommitEntryKeepsOriginalLoadedSelection() async throws {
        let f = try fixture(preload: true)
        let held = gate()
        let entered = expectation(description: "Original commit reached reader collaborator")
        f.reader.beforeCommitReturns = {
            entered.fulfill()
            await held.wait()
        }
        f.handler.onNavigationCommitted(state: f.state)
        f.handler.onNavigationFinished(state: f.state)
        let finish = own(try XCTUnwrap(f.tasks.onNavigationFinishedTask))
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(f.externalFinishCount, 0)
        XCTAssertTrue(f.content.content === f.record)
        await held.release()
        guard case .success? = await settle(finish, releasing: held) else {
            return XCTFail("Current queued finish was rejected")
        }
        await settle(try XCTUnwrap(f.reader.finishTasks.last))
        XCTAssertEqual(f.externalFinishCount, 1)
        XCTAssertEqual(f.probe.titles, ["Original title"])
        XCTAssertFalse(f.content.isReaderMainFrameNavigating)
    }

    func testQueuedFinishRejectsSameURLSelectionABA() async throws {
        let f = try fixture()
        try await commit(f)
        f.mode.readerModeLoading(true)
        f.handler.onNavigationFinished(state: f.state)
        let finish = own(try XCTUnwrap(f.tasks.onNavigationFinishedTask))
        f.replaceSelection(returnToOriginal: true)
        guard case .failure(let error)? = await settle(finish) else {
            return XCTFail("Retired queued finish was admitted")
        }
        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(f.externalFinishCount, 0)
        XCTAssertEqual(f.probe.finishCount, 0)
        XCTAssertEqual(f.probe.settingsCount, 0)
        XCTAssertTrue(f.mode.isReaderModeLoading)
        XCTAssertFalse(f.content.isReaderMainFrameNavigating)
    }

    func testDuplicateFinishPublishesExactlyOnce() async throws {
        let f = try fixture()
        try await commit(f)
        f.handler.onNavigationFinished(state: f.state)
        let original = own(try XCTUnwrap(f.tasks.onNavigationFinishedTask))
        f.handler.onNavigationFinished(state: f.state)
        _ = await settle(original)
        await settle(try XCTUnwrap(f.reader.finishTasks.last))
        XCTAssertEqual(f.externalFinishCount, 1)
        XCTAssertEqual(f.probe.finishCount, 1)
        XCTAssertEqual(f.probe.settingsCount, 1)
        XCTAssertEqual(f.probe.titles, ["Original title"])
    }

    func testNewSameURLCommitCannotDonateSelectionToOldQueuedFinish() async throws {
        let f = try fixture()
        let held = gate()
        let entered = expectation(description: "First commit held")
        var first = true
        f.reader.beforeCommitReturns = {
            guard first else { return }
            first = false
            entered.fulfill()
            await held.wait()
        }
        f.handler.onNavigationCommitted(state: f.state)
        await fulfillment(of: [entered], timeout: 2)
        f.handler.onNavigationFinished(state: f.state)
        let oldFinish = own(try XCTUnwrap(f.tasks.onNavigationFinishedTask))
        f.replaceSelection(returnToOriginal: true)
        f.handler.onNavigationCommitted(state: f.state)
        f.handler.onNavigationFinished(state: f.state)
        let newFinish = own(try XCTUnwrap(f.tasks.onNavigationFinishedTask))
        await held.release()
        guard case .failure(let error)? = await settle(oldFinish, releasing: held) else {
            return XCTFail("Old finish borrowed the successor")
        }
        XCTAssertTrue(error is CancellationError)
        guard case .success? = await settle(newFinish) else {
            return XCTFail("Successor finish did not complete")
        }
        await settle(try XCTUnwrap(f.reader.finishTasks.last))
        XCTAssertEqual(f.externalFinishCount, 1)
        XCTAssertEqual(f.probe.titles, ["Original title"])
    }

    func testCommitRevalidatesManagedRowAndSelectionAfterReaderAwait() async throws {
        for change in ["invalidated", "replacement", "aba", "binding", "cancelled", "live"] {
            let f = try fixture(managed: true)
            let held = gate()
            let entered = expectation(description: "Commit held: \(change)")
            f.reader.beforeCommitReturns = {
                entered.fulfill()
                await held.wait()
            }
            f.mode.readabilityContent = "Original readability"
            f.handler.onNavigationCommitted(state: f.state)
            let task = own(try XCTUnwrap(f.tasks.onNavigationCommittedTask))
            await fulfillment(of: [entered], timeout: 2)
            switch change {
            case "invalidated": try XCTUnwrap(f.realm).write { try XCTUnwrap(f.realm).delete(f.record) }
            case "replacement": f.replaceSelection()
            case "aba": f.replaceSelection(returnToOriginal: true)
            case "binding": f.probe.bind(f.reader.scriptCaller)
            case "cancelled": task.cancel()
            default: break
            }
            await held.release()
            let outcome = await settle(task, releasing: held)
            if change == "live" {
                guard case .success? = outcome else { return XCTFail("Live commit failed") }
                XCTAssertEqual(f.media.committed, [ObjectIdentifier(f.record)])
            } else {
                guard case .failure(let error)? = outcome else { return XCTFail("Retired commit succeeded: \(change)") }
                XCTAssertTrue(error is CancellationError, change)
                XCTAssertTrue(f.media.committed.isEmpty, change)
                XCTAssertEqual(f.mode.readabilityContent, "Original readability", change)
            }
        }
    }

    func testLateFinishSuccessOrFailureCannotClearSuccessorLoadingOrCallCompletion() async throws {
        for fails in [false, true] {
            let f = try fixture()
            try await commit(f)
            let held = gate()
            f.probe.finishGate = held
            f.probe.failFinish = fails
            f.probe.finishEntered = expectation(description: "Finish JavaScript held")
            f.handler.onNavigationFinished(state: f.state)
            let finish = own(try XCTUnwrap(f.tasks.onNavigationFinishedTask))
            await fulfillment(of: [try XCTUnwrap(f.probe.finishEntered)], timeout: 2)
            f.replaceSelection(returnToOriginal: true)
            f.mode.readerModeLoading(true)
            f.mode.readabilityContent = "Successor readability"
            await held.release()
            _ = await settle(finish, releasing: held)
            XCTAssertTrue(f.mode.isReaderModeLoading)
            XCTAssertEqual(f.mode.readabilityContent, "Successor readability")
            XCTAssertEqual(f.externalFinishCount, 0)
            XCTAssertTrue(f.reader.finishTasks.isEmpty)
        }
    }

    func testCancelledFinishKeepsLateJavaScriptFromClearingLoading() async throws {
        let f = try fixture()
        try await commit(f)
        let held = gate()
        f.probe.finishGate = held
        f.probe.finishEntered = expectation(description: "Finish held before cancellation")
        f.handler.onNavigationFinished(state: f.state)
        let finish = own(try XCTUnwrap(f.tasks.onNavigationFinishedTask))
        await fulfillment(of: [try XCTUnwrap(f.probe.finishEntered)], timeout: 2)
        finish.cancel()
        f.mode.readerModeLoading(true)
        await held.release()
        _ = await settle(finish, releasing: held)
        XCTAssertTrue(f.mode.isReaderModeLoading)
        XCTAssertEqual(f.externalFinishCount, 0)
        XCTAssertTrue(f.reader.finishTasks.isEmpty)
    }

    func testCurrentFinishFailureKeepsExistingCleanupAndRetry() async throws {
        let f = try fixture()
        try await commit(f)
        f.probe.failFinish = true
        f.mode.readerModeLoading(true)
        f.handler.onNavigationFinished(state: f.state)
        _ = await settle(try XCTUnwrap(f.tasks.onNavigationFinishedTask))
        await settle(try XCTUnwrap(f.reader.finishTasks.last))
        XCTAssertFalse(f.mode.isReaderModeLoading)
        XCTAssertEqual(f.externalFinishCount, 1)
        f.probe.failFinish = false
        try await commit(f)
        f.handler.onNavigationFinished(state: f.state)
        _ = await settle(try XCTUnwrap(f.tasks.onNavigationFinishedTask))
        await settle(try XCTUnwrap(f.reader.finishTasks.last))
        XCTAssertEqual(f.externalFinishCount, 2)
        XCTAssertEqual(f.probe.titles, ["Original title", "Original title"])
    }

    func testSettingsRevalidateOriginalRowSelectionPageCallerAndCancellation() async throws {
        for change in ["invalidated", "selection", "aba", "binding", "caller", "page", "cancelled", "live"] {
            let f = try fixture(managed: true)
            let held = gate()
            f.probe.settingsGate = held
            f.probe.settingsEntered = expectation(description: "Settings held: \(change)")
            let selection = f.content.makeSelectionCommitFence(requiring: f.content.currentSelectionID)
            let task = try XCTUnwrap(f.reader.refreshSettingsInWebView(
                content: f.record, newState: f.state, documentIsCurrent: { selection() }
            ))
            await fulfillment(of: [try XCTUnwrap(f.probe.settingsEntered)], timeout: 2)
            switch change {
            case "invalidated": try XCTUnwrap(f.realm).write { try XCTUnwrap(f.realm).delete(f.record) }
            case "selection": f.replaceSelection()
            case "aba": f.replaceSelection(returnToOriginal: true)
            case "binding": f.probe.bind(f.reader.scriptCaller)
            case "caller":
                f.reader.scriptCaller = WebViewScriptCaller()
                f.probe.bind(f.reader.scriptCaller)
            case "page":
                var state = f.state
                state.pageURL = URL(string: "https://example.invalid/successor")!
                f.reader.state = state
            case "cancelled": task.cancel()
            default: break
            }
            await held.release()
            await settle(task, releasing: held)
            XCTAssertEqual(f.probe.settingsCount, 1, change)
            XCTAssertEqual(f.probe.titles, change == "live" ? ["Original title"] : [], change)
        }
    }

    func testQueuedSettingsAndCompletionCannotAdoptReplacementBinding() async throws {
        let f = try fixture()
        var completions = 0
        let task = try XCTUnwrap(f.reader.onNavigationFinished(
            content: f.record, newState: f.state, documentIsCurrent: { true },
            completion: { _ in completions += 1 }
        ))
        // No actor yield: the production task has not entered yet.
        f.probe.bind(f.reader.scriptCaller)
        await settle(task)
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(f.probe.settingsCount, 0)
        XCTAssertTrue(f.probe.titles.isEmpty)
    }

    func testCompletionReentryRetiresRemainingSettingsWork() async throws {
        let f = try fixture()
        let selection = f.content.makeSelectionCommitFence(requiring: f.content.currentSelectionID)
        var completions = 0
        let task = try XCTUnwrap(f.reader.onNavigationFinished(
            content: f.record, newState: f.state, documentIsCurrent: { selection() },
            completion: { _ in
                completions += 1
                f.replaceSelection(returnToOriginal: true)
            }
        ))
        await settle(task)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(f.probe.settingsCount, 0)
        XCTAssertTrue(f.probe.titles.isEmpty)
    }

    func testDocumentFailureRetiresSettingsButPreservedFailureAllowsCompletion() async throws {
        for preserves in [false, true] {
            let f = try fixture()
            try await commit(f)
            let held = gate()
            f.probe.settingsGate = held
            f.probe.settingsEntered = expectation(description: "Settings held across failure")
            f.handler.onNavigationFinished(state: f.state)
            _ = await settle(try XCTUnwrap(f.tasks.onNavigationFinishedTask))
            await fulfillment(of: [try XCTUnwrap(f.probe.settingsEntered)], timeout: 2)
            let settings = own(try XCTUnwrap(f.reader.finishTasks.last))
            f.handler.onNavigationFailed(
                state: f.state,
                disposition: preserves ? .preservedCommittedDocument : .terminal
            )
            _ = await settle(try XCTUnwrap(f.tasks.onNavigationFailedTask))
            await held.release()
            await settle(settings, releasing: held)
            XCTAssertEqual(f.probe.titles, preserves ? ["Original title"] : [])
        }
    }

    func testDocumentInvalidationRetiresSettingsAfterFinishTaskSettles() async throws {
        let f = try fixture()
        try await commit(f)
        let held = gate()
        f.probe.settingsGate = held
        f.probe.settingsEntered = expectation(description: "Settings held after finish")
        f.handler.onNavigationFinished(state: f.state)
        _ = await settle(try XCTUnwrap(f.tasks.onNavigationFinishedTask))
        await fulfillment(of: [try XCTUnwrap(f.probe.settingsEntered)], timeout: 2)
        let settings = own(try XCTUnwrap(f.reader.finishTasks.last))
        f.handler.onDocumentContextInvalidated(state: f.state, reason: .webContentProcessTerminated)
        await held.release()
        await settle(settings, releasing: held)
        XCTAssertTrue(f.probe.titles.isEmpty)
    }

    func testSettingsFailureCanRetryThroughOriginalTwoArgumentEnvironmentFunction() async throws {
        let f = try fixture()
        f.probe.failSettings = true
        let failed = try XCTUnwrap(f.reader.refreshSettingsInWebView(
            content: f.record, newState: f.state, documentIsCurrent: { true }
        ))
        await settle(failed)
        XCTAssertTrue(f.probe.titles.isEmpty)
        f.probe.failSettings = false
        let entered = expectation(description: "Two-argument refresh reached actual settings")
        f.probe.settingsEntered = entered
        let refresh: @MainActor (any ReaderContentProtocol, WebViewState?) -> Void =
            f.reader.refreshSettingsInWebView
        refresh(f.record, f.state)
        await fulfillment(of: [entered], timeout: 2)
        await settle(try XCTUnwrap(f.reader.refreshTasks.last))
        XCTAssertEqual(f.probe.settingsCount, 2)
        XCTAssertEqual(f.probe.titles, ["Original title"])
    }

    func testAdmissionPredicateReentryCannotReadAnInvalidatedRow() async throws {
        let f = try fixture(managed: true)
        var called = false
        let task = f.reader.refreshSettingsInWebView(
            content: f.record, newState: f.state, documentIsCurrent: {
                if !called {
                    called = true
                    do { try XCTUnwrap(f.realm).write { try XCTUnwrap(f.realm).delete(f.record) } }
                    catch { XCTFail("Could not retire test row: \(error)") }
                }
                return true
            }
        )
        XCTAssertTrue(called)
        XCTAssertNil(task)
        XCTAssertTrue(f.record.isInvalidated)
        XCTAssertEqual(f.probe.settingsCount, 0)
    }
}
