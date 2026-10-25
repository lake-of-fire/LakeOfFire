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
    var titles: [String] = []
    var settingsGate: NavigationLifetimeGate?
    var finishGate: NavigationLifetimeGate?
    var settingsEntered: XCTestExpectation?
    var finishEntered: XCTestExpectation?
    var failSettings = false
    var failFinish = false

    func evaluate(_ script: String, title: String?) async throws -> Bool? {
        if let title {
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
                let value = try await evaluate(script, title: arguments?["title"] as? String)
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

    init() {
        originalResolver = ReaderContent.contentResolver
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
        }
        cancellations.forEach { $0() }
        fixtures.forEach { $0.tasks.cancelNavigationWork() }
        for gate in gates { await gate.release() }
        for fixture in fixtures {
            await fixture.probe.settingsGate?.release()
            await fixture.probe.finishGate?.release()
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

    func testCapturedAdmissionRejectsQueuedNativeCommitBeforeResolverPreparationAndPublicCallback() async throws {
        let f = try fixture(managed: true)
        var admitted = true
        var resolverCalls = 0
        var publicCommits = 0
        ReaderContent.contentResolver = { _, _, _ in
            resolverCalls += 1
            return f.record
        }
        f.handler.onNavigationCommitted = { _ in publicCommits += 1 }
        f.content.replaceSelection(with: f.record, admission: { admitted })
        f.mode.readabilityContent = "Existing preparation"
        f.handler.onNavigationCommitted(state: f.state)
        let queued = own(try XCTUnwrap(f.tasks.onNavigationCommittedTask))
        // No actor yield: dispatch occurred, but the actual commit consumer has
        // not yet entered ReaderContent.loadWithSelectionReceipt.
        admitted = false
        guard case .failure(let error)? = await settle(queued) else {
            return XCTFail("Retired capture reached native preparation")
        }
        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(resolverCalls, 0)
        XCTAssertEqual(f.reader.commitCount, 0)
        XCTAssertTrue(f.media.committed.isEmpty)
        XCTAssertEqual(publicCommits, 0)
        XCTAssertEqual(f.mode.readabilityContent, "Existing preparation")
        XCTAssertFalse(f.content.isReaderMainFrameNavigating)

        // Rejection is one-way until an explicit, newly admitted selection.
        admitted = true
        do {
            _ = try await f.content.loadWithSelectionReceipt(url: f.state.pageURL)
            XCTFail("A rejected capture revived")
        } catch is CancellationError { }
        f.content.replaceSelection(with: f.record, admission: { admitted })
        try await commit(f)
        XCTAssertEqual(f.reader.commitCount, 1)
        XCTAssertEqual(publicCommits, 1)
        XCTAssertEqual(resolverCalls, 0)
    }

    func testCapturedReceiptRechecksAdmissionAfterActualReaderCommitAwait() async throws {
        let f = try fixture(managed: true)
        var admitted = true
        var publicCommits = 0
        let held = gate()
        let entered = expectation(description: "Captured commit suspended in the reader")
        f.content.replaceSelection(with: f.record, admission: { admitted })
        f.mode.readabilityContent = "Unchanged preparation"
        f.handler.onNavigationCommitted = { _ in publicCommits += 1 }
        f.reader.beforeCommitReturns = {
            entered.fulfill()
            await held.wait()
        }
        f.handler.onNavigationCommitted(state: f.state)
        let task = own(try XCTUnwrap(f.tasks.onNavigationCommittedTask))
        await fulfillment(of: [entered], timeout: 2)
        admitted = false
        await held.release()
        guard case .failure(let error)? = await settle(task, releasing: held) else {
            return XCTFail("Receipt did not retain its original admission")
        }
        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(f.reader.commitCount, 1)
        XCTAssertTrue(f.media.committed.isEmpty)
        XCTAssertEqual(publicCommits, 0)
        XCTAssertEqual(f.mode.readabilityContent, "Unchanged preparation")
    }

    func testCapturedPredicateReentryCannotBorrowOrRetireAReplacementSelection() async throws {
        let f = try fixture()
        let successor = HistoryRecord(value: f.record)
        successor.title = "Successor"
        var replace = false
        f.content.replaceSelection(with: f.record, admission: { [weak content = f.content] in
            if replace { content?.replaceSelection(with: successor, admission: { true }) }
            return true
        })
        let original = try await f.content.loadWithSelectionReceipt(url: f.state.pageURL)
        replace = true
        XCTAssertFalse(original.isCurrent)
        XCTAssertTrue(f.content.content === successor)
        let replacement = try await f.content.loadWithSelectionReceipt(url: f.state.pageURL)
        XCTAssertTrue(replacement.isCurrent)
        XCTAssertFalse(original.isCurrent)
        XCTAssertTrue(replacement.isCurrent, "An old receipt must not withdraw the replacement token")
    }

    func testCapturedAdmissionQuietRetirementAndExplicitDifferentURLNavigation() async throws {
        let f = try fixture()
        var resolverCalls = 0
        let successor = HistoryRecord()
        successor.url = URL(string: "https://example.invalid/different-document")!
        successor.updateCompoundKey()
        ReaderContent.contentResolver = { url, _, _ in
            resolverCalls += 1
            XCTAssertEqual(url, successor.url)
            return successor
        }
        f.content.replaceSelection(with: f.record, admission: { false })
        try await f.content.load(url: f.state.pageURL)
        XCTAssertEqual(resolverCalls, 0)
        XCTAssertTrue(f.content.content === f.record)
        do {
            _ = try await f.content.loadWithSelectionReceipt(url: f.state.pageURL)
            XCTFail("Strict native load accepted quietly retired content")
        } catch is CancellationError { }
        let current = try await f.content.loadWithSelectionReceipt(url: successor.url)
        XCTAssertTrue(current.isCurrent)
        XCTAssertTrue(f.content.content === successor)
        XCTAssertEqual(resolverCalls, 1)
        f.content.replaceSelection(with: f.record)
        let explicit = try await f.content.loadWithSelectionReceipt(url: f.state.pageURL)
        XCTAssertTrue(explicit.isCurrent)
        XCTAssertFalse(current.isCurrent)
        XCTAssertEqual(resolverCalls, 1)
    }

    func testCancelledNativeCallbackDoesNotRetireAnotherCurrentCapturedLoad() async throws {
        let f = try fixture()
        f.content.replaceSelection(with: f.record, admission: { true })
        f.handler.onNavigationCommitted(state: f.state)
        let cancelled = own(try XCTUnwrap(f.tasks.onNavigationCommittedTask))
        cancelled.cancel()
        guard case .failure(let error)? = await settle(cancelled) else {
            return XCTFail("Cancelled native callback ran")
        }
        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(f.reader.commitCount, 0)
        let receipt = try await f.content.loadWithSelectionReceipt(url: f.state.pageURL)
        XCTAssertTrue(receipt.isCurrent)
        try await commit(f)
        XCTAssertEqual(f.reader.commitCount, 1)
    }

    func testDifferentURLAlreadyPublishedContentRetiresOldCapturedAdmission() async throws {
        let f = try fixture()
        f.content.replaceSelection(with: f.record, admission: { false })
        let oldSelection = f.content.currentSelectionID
        let successor = HistoryRecord()
        successor.url = URL(string: "https://example.invalid/published-successor")!
        successor.updateCompoundKey()
        f.content.content = successor
        f.content.pageURL = successor.url
        ReaderContent.contentResolver = { _, _, _ in
            XCTFail("Already published successor unnecessarily entered generic resolution")
            return nil
        }
        let receipt = try await f.content.loadWithSelectionReceipt(url: successor.url)
        XCTAssertTrue(receipt.isCurrent)
        XCTAssertTrue(f.content.content === successor)
        XCTAssertNotEqual(f.content.currentSelectionID, oldSelection)
    }

    func testCapturedAdmissionAlsoFencesSuppressedBlankReceipt() async throws {
        let f = try fixture()
        var admitted = true
        f.content.replaceSelection(with: f.record, admission: { admitted })
        f.content.suppressTransientAboutBlank(untilNextNonBlankLoad: f.state.pageURL)
        let blank = URL(string: "about:blank")!
        let receipt = try await f.content.loadWithSelectionReceipt(url: blank)
        XCTAssertTrue(receipt.isCurrent)
        admitted = false
        XCTAssertFalse(receipt.isCurrent)
        XCTAssertEqual(f.content.pageURL, f.state.pageURL)
        do {
            _ = try await f.content.loadWithSelectionReceipt(url: blank)
            XCTFail("Transient blank borrowed a retired source")
        } catch is CancellationError { }
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
