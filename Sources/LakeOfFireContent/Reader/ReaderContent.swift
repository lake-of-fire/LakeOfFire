import SwiftUI
import LakeOfFireCore
import Combine
import SwiftUIWebView
import Foundation

/// A selection can only lose authority. The fence retains this tiny token,
/// never its MainActor content owner or a replacement selection.
private final class ReaderContentSelectionLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var isCurrent = true
    private var withdrawalObservers: [@Sendable () -> Void] = []

    func permitsCommit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCurrent
    }

    func onWithdrawal(_ observer: @escaping @Sendable () -> Void) {
        lock.lock()
        if isCurrent {
            withdrawalObservers.append(observer)
            lock.unlock()
        } else {
            lock.unlock()
            observer()
        }
    }

    func withdraw() {
        lock.lock()
        guard isCurrent else { lock.unlock(); return }
        isCurrent = false
        let observers = withdrawalObservers
        withdrawalObservers.removeAll()
        lock.unlock()
        observers.forEach { $0() }
    }
}

@MainActor
public class ReaderContent: ObservableObject {
    @Published public var content: (any ReaderContentProtocol)? {
        didSet {
            syncLocationBarTitle()
            syncContentTitle()
        }
    }// = ReaderContentLoader.unsavedHome
    @Published public var pageURL = URL(string: "about:blank")! {
        didSet {
            syncLocationBarTitle()
        }
    }
    @Published public var currentSectionIndex: Int?
    @Published public var locationBarTitle: String?
    @Published public var isReaderProvisionallyNavigating = false
    @Published public var isRenderingReaderHTML = false
    public let contentTitleSubject = PassthroughSubject<String, Never>()
    public private(set) var contentTitle: String = ""
    private var contentTitleURL: URL?
    public private(set) var snippetTitleIsGeneratedFromPrefix = false
    
    private var loadingTask: Task<(any ReaderContentProtocol)?, Error>?
    private var loadingResolvedContentURL: URL?
    // The last admitted selection outlives its loading task: a completed task
    // may still have readers queued to receive its result.
    private var selectionID: UUID?
    private var selectionLifetime = ReaderContentSelectionLifetime()
    private var selectionHandoff: ReaderContentSelectionHandoff?
    private var suppressedTransientAboutBlankTargetURL: URL?
    private var preloadedResolvedContentURL: URL?
    private var preloadedContent: (any ReaderContentProtocol)?

    public init() {
    }

    /// Cached model identity is optional after cleanup; the mounted document's
    /// native identity continues to live in pageURL and its selection fence.
    public var cachedContentURL: URL? {
        validCachedContent?.url
    }

    /// Read the current row rather than the retained contentTitle projection,
    /// which can outlive a removed cached model.
    public var cachedContentTitle: String? {
        validCachedContent?.title
    }

    /// Only use this model synchronously on MainActor. Revalidate after any
    /// suspension; a valid row can still be removed while work is pending.
    public var validCachedContent: (any ReaderContentProtocol)? {
        guard let content, !content.isInvalidated else { return nil }
        return content
    }

    deinit {
        selectionHandoff?.withdraw()
        selectionLifetime.withdraw()
    }

    /// The existing native content selection, including its unresolved load.
    public var currentSelectionID: UUID? { selectionID }

    /// Capture before suspending. A replacement selection closes this fence
    /// permanently, even if navigation later returns to the same URL.
    public func makeSelectionCommitFence(requiring expectedID: UUID?) -> @Sendable () -> Bool {
        guard selectionID == expectedID else { return { false } }
        let lifetime = selectionLifetime
        return { lifetime.permitsCommit() }
    }

    /// Called synchronously at native URL publication, before semantic deferral.
    @discardableResult
    public func receiveSelectionIntent(_ intent: WebViewURLTransitionIntent) -> ReaderContentSelectionHandoff? {
        guard intent.isCurrent, intent.representsURLChange else { return nil }
        if let selectionHandoff, selectionHandoff.intent === intent {
            return selectionHandoff.permitsCapture ? selectionHandoff : nil
        }
        selectionHandoff?.withdraw()
        // A cancelled owner closes its lifetime synchronously, even while its
        // resolver ignores cancellation. A different native intent may retry;
        // the old token and load identity remain permanently retired.
        if !selectionLifetime.permitsCommit() {
            let retiredTask = loadingTask
            loadingTask = nil
            loadingResolvedContentURL = nil
            selectionLifetime = ReaderContentSelectionLifetime()
            selectionID = UUID()
            retiredTask?.cancel()
        }
        let handoff = ReaderContentSelectionHandoff(intent: intent,
            predecessorSelectionID: selectionID,
            predecessorIsCurrent: makeSelectionCommitFence(requiring: selectionID))
        selectionHandoff = handoff
        return handoff
    }

    public func selectionHandoff(for intent: WebViewURLTransitionIntent) -> ReaderContentSelectionHandoff? {
        guard let selectionHandoff, selectionHandoff.intent === intent,
              selectionHandoff.permitsCapture else { return nil }
        return selectionHandoff
    }

    public func withdrawSelectionIntent(_ intent: WebViewURLTransitionIntent? = nil) {
        guard intent == nil || selectionHandoff?.intent === intent else { return }
        selectionHandoff?.withdraw()
        // Keep this exact intent's closed handoff until a different native
        // intent replaces it. A fragment or retry cannot revive failed work.
    }

    @MainActor
    public func refreshObservedContentState() {
        syncLocationBarTitle()
        syncContentTitle()
        objectWillChange.send()
    }

    private func syncLocationBarTitle() {
        guard pageURL.absoluteString != "about:blank" else {
            snippetTitleIsGeneratedFromPrefix = false
            locationBarTitle = nil
            return
        }
        guard let content, !content.isInvalidated,
              content.url.matchesReaderURL(pageURL) else {
            snippetTitleIsGeneratedFromPrefix = false
            locationBarTitle = nil
            return
        }
        let trimmedTitle = resolvedLocationBarTitle(for: content)?.trimmingCharacters(in: .whitespacesAndNewlines)
        locationBarTitle = (trimmedTitle?.isEmpty == false) ? trimmedTitle : nil
    }

    private func resolvedLocationBarTitle(for content: any ReaderContentProtocol) -> String? {
        guard content.url.isSnippetURL else {
            snippetTitleIsGeneratedFromPrefix = false
            return content.locationBarTitle
        }

        snippetTitleIsGeneratedFromPrefix = content.isTitlePrefixOfContent
        return ReaderContentLoader.resolvedSnippetLocationBarTitle(
            title: content.title,
            createdAt: content.createdAt,
            needsClipboardIndicator: content.needsClipboardIndicator,
            isTitlePrefixOfContent: content.isTitlePrefixOfContent
        )
    }

    private func syncContentTitle() {
        guard let content, !content.isInvalidated else {
            return
        }
        let newTitle = content.title
        let newTitleURL = content.url
        guard contentTitle != newTitle || contentTitleURL?.absoluteString != newTitleURL.absoluteString else { return }
        contentTitle = newTitle
        contentTitleURL = newTitleURL
        guard !newTitle.isEmpty else { return }
        contentTitleSubject.send(newTitle)
    }

    private func matchesResolvedContentURL(_ contentURL: URL, resolvedContentURL: URL) -> Bool {
        contentURL.absoluteString == resolvedContentURL.absoluteString
            || contentURL.matchesReaderURL(resolvedContentURL)
    }

    @MainActor
    public func suppressTransientAboutBlank(untilNextNonBlankLoad targetURL: URL) {
        let resolvedTargetURL = ReaderContentLoader.getContentURL(fromLoaderURL: targetURL) ?? targetURL
        guard resolvedTargetURL.absoluteString != "about:blank" else { return }
        suppressedTransientAboutBlankTargetURL = resolvedTargetURL
    }

    @MainActor
    public func preloadResolvedContent(_ content: any ReaderContentProtocol, for targetURL: URL) {
        let resolvedTargetURL = ReaderContentLoader.getContentURL(fromLoaderURL: targetURL) ?? targetURL
        guard !content.isInvalidated, content.url.matchesReaderURL(resolvedTargetURL) else {
            return
        }
        preloadedResolvedContentURL = resolvedTargetURL
        preloadedContent = content
    }

    private func consumePreloadedContentIfMatching(resolvedContentURL: URL) -> (any ReaderContentProtocol)? {
        if preloadedContent?.isInvalidated == true {
            preloadedResolvedContentURL = nil
            preloadedContent = nil
            return nil
        }
        guard let preloadedResolvedContentURL,
              let preloadedContent,
              preloadedContent.url.matchesReaderURL(resolvedContentURL),
              preloadedResolvedContentURL.matchesReaderURL(resolvedContentURL) else {
            return nil
        }
        self.preloadedResolvedContentURL = nil
        self.preloadedContent = nil
        return preloadedContent
    }

    @MainActor
    public func load(url: URL, consuming intent: WebViewURLTransitionIntent? = nil) async throws {
        try await load(url: url, consuming: intent) { url in
            try await ReaderContentLoader.getContent(
                forURL: url,
                countsAsHistoryVisit: true,
                source: "ReaderContent.load"
            )
        }
    }

    /// The resolver supplies content only; this owner retains coalescing,
    /// cancellation and display publication for both production and tests.
    @MainActor
    func load(
        url: URL,
        consuming intent: WebViewURLTransitionIntent? = nil,
        resolveContent: @escaping @MainActor (URL) async throws -> (any ReaderContentProtocol)?
    ) async throws {
        let handoff = intent.flatMap { expected in
            selectionHandoff?.intent === expected ? selectionHandoff : nil
        }
        defer { handoff?.withdrawIfUnselected() }
        try Task.checkCancellation()
        let resolvedContentURL = ReaderContentLoader.getContentURL(fromLoaderURL: url) ?? url
        let displayURL = resolvedContentURL
        if let intent {
            guard let handoff, handoff.permitsCapture,
                  resolvedContentURL.matchesReaderURL(intent.destinationURL) else { throw CancellationError() }
        }

        if resolvedContentURL.absoluteString == "about:blank",
           let suppressedTargetURL = suppressedTransientAboutBlankTargetURL,
           suppressedTargetURL.absoluteString != "about:blank" {
            return
        }

        if resolvedContentURL.absoluteString == "about:blank",
           WebViewReaderLoadActivity.shared.hasPendingPreProvisionalLoad {
            return
        }

        if resolvedContentURL.absoluteString != "about:blank" {
            suppressedTransientAboutBlankTargetURL = nil
        }

        if let loadingTask,
           let loadingResolvedContentURL,
           matchesResolvedContentURL(loadingResolvedContentURL, resolvedContentURL: resolvedContentURL) {
            let loadID = selectionID
            if let handoff {
                guard handoff.beginSelection(selectionID: loadID,
                    fence: makeSelectionCommitFence(requiring: loadID)) else { throw CancellationError() }
                selectionLifetime.onWithdrawal { [weak handoff] in handoff?.withdraw() }
            }
            _ = try await withTaskCancellationHandler {
                try await loadingTask.value
            } onCancel: {
                // Retire this consuming intent without cancelling the shared resolver.
                handoff?.withdraw()
            }
            if handoff != nil {
                try Task.checkCancellation()
                guard selectionID == loadID, handoff?.permitsCapture != false else { throw CancellationError() }
            }
            completeSelectionHandoff(handoff, selectionID: loadID, url: resolvedContentURL)
            return
        }

        // Reopening the already displayed content is not a new selection.
        // Keep completed readers valid, but still retire any unrelated task.
        if handoff?.isPending != true, loadingTask == nil, selectionLifetime.permitsCommit(),
           let existingContent = content, !existingContent.isInvalidated,
           matchesResolvedContentURL(existingContent.url, resolvedContentURL: resolvedContentURL),
           matchesResolvedContentURL(pageURL, resolvedContentURL: displayURL) {
            completeSelectionHandoff(handoff, selectionID: selectionID, url: resolvedContentURL)
            return
        }

        // Every new selection retires the preceding load, including cached and
        // preloaded fast paths. Withdraw its identity before cancellation can
        // invoke callbacks; an old completion may never republish its content.
        if let handoff {
            guard handoff.predecessorSelectionID == selectionID, handoff.permitsCapture else {
                throw CancellationError()
            }
        } else {
            withdrawSelectionIntent()
        }
        let retiredTask = loadingTask
        let loadID = UUID()
        let nextLifetime = ReaderContentSelectionLifetime()
        if let handoff {
            guard handoff.beginSelection(selectionID: loadID,
                fence: { nextLifetime.permitsCommit() }) else { throw CancellationError() }
            nextLifetime.onWithdrawal { [weak handoff] in handoff?.withdraw() }
        }
        selectionLifetime.withdraw()
        selectionLifetime = nextLifetime
        selectionID = loadID
        loadingTask = nil
        loadingResolvedContentURL = nil
        defer {
            completeSelectionHandoff(handoff, selectionID: loadID, url: resolvedContentURL)
            finishLoading(ifOwnedBy: loadID)
        }
        // Cover synchronous cached/preloaded publication as well as resolver
        // suspension. Cancellation closes this caller's captured lifetime,
        // never a replacement selection or a coalesced caller's owner.
        try await withTaskCancellationHandler {
            retiredTask?.cancel()
            func validatePublication() throws {
                try Task.checkCancellation()
                guard selectionID == loadID, nextLifetime.permitsCommit(),
                      handoff?.permitsCapture != false else { throw CancellationError() }
            }
            try validatePublication()

            if let existingContent = content, !existingContent.isInvalidated,
               matchesResolvedContentURL(existingContent.url, resolvedContentURL: resolvedContentURL) {
                let pageAlreadyMatchesDisplay = matchesResolvedContentURL(
                    pageURL, resolvedContentURL: displayURL
                )
                if pageAlreadyMatchesDisplay {
                    return
                }
                if !pageURL.matchesReaderURL(url) {
                    pageURL = displayURL
                    try validatePublication()
                }
                return
            }

            if let preloadedContent = consumePreloadedContentIfMatching(resolvedContentURL: resolvedContentURL) {
                currentSectionIndex = nil
                try validatePublication()
                content = preloadedContent
                try validatePublication()
                pageURL = displayURL
                try validatePublication()
                return
            }

            content = nil
            try validatePublication()
            currentSectionIndex = nil
            try validatePublication()
            pageURL = displayURL
            try validatePublication()

            loadingResolvedContentURL = resolvedContentURL
            let task = Task<(any ReaderContentProtocol)?, Error> { @MainActor [weak self, loadID] in
                // Finish before any coalesced waiter receives success/error. Its
                // immediate retry must not rejoin this already-completed task.
                defer { self?.finishLoading(ifOwnedBy: loadID) }
                try Task.checkCancellation()
                let content = try await resolveContent(url) ?? ReaderContentLoader.unsavedHome
                // Preserve the existing nonthrowing retirement result for a superseded load.
                guard let self, self.selectionID == loadID else { return nil }
                try Task.checkCancellation()
                guard handoff?.permitsCapture != false else { throw CancellationError() }
                guard !content.isInvalidated else { return nil }
                guard content.url.matchesReaderURL(resolvedContentURL) else {
                    debugPrint("Warning: Mismatched URL in ReaderContent.load:", url.absoluteString, content.url)
                    return nil
                }
                self.content = content
                guard self.selectionID == loadID, nextLifetime.permitsCommit(),
                      handoff?.permitsCapture != false, self.content === content else { return nil }
                return content
            }
            loadingTask = task
            _ = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                // Nested handler order must not let resolver cancellation
                // callbacks observe a still-current owner.
                nextLifetime.withdraw()
                handoff?.withdraw()
                task.cancel()
            }
            try Task.checkCancellation()
        } onCancel: {
            nextLifetime.withdraw()
            handoff?.withdraw()
        }
    }

    private func completeSelectionHandoff(_ handoff: ReaderContentSelectionHandoff?,
                                          selectionID expectedID: UUID?, url: URL) {
        guard let handoff else { return }
        guard !Task.isCancelled, handoff.intent.isCurrent,
              selectionID == expectedID, let content, !content.isInvalidated,
              matchesResolvedContentURL(content.url, resolvedContentURL: url),
              matchesResolvedContentURL(pageURL, resolvedContentURL: url) else {
            handoff.withdraw()
            return
        }
        handoff.completeSelection(selectionID: expectedID)
    }

    private func finishLoading(ifOwnedBy loadID: UUID) {
        // Old completion is independent of a new selection's loading slot.
        guard selectionID == loadID else { return }
        loadingResolvedContentURL = nil
        loadingTask = nil
    }

    @MainActor
    public func prepareForDisplay(url: URL) async throws {
        try await load(url: url)
    }
    
    @MainActor
    public func getContent() async throws -> (any ReaderContentProtocol)? {
        if let content {
            return content.isInvalidated ? nil : content
        }
        let selectionID = self.selectionID
        let resolvedContent = try await loadingTask?.value
        // Completing a task makes its value available, not permanently current.
        // Navigation or a publication subscriber may replace the selection
        // before this waiter resumes. Never return the displaced value or
        // substitute the newly displayed content for the original read.
        guard self.selectionID == selectionID,
              let resolvedContent, !resolvedContent.isInvalidated,
              content === resolvedContent else { return nil }
        return resolvedContent
    }

    @MainActor
    @discardableResult
    public func updateContentTitle(_ newTitle: String, for targetURL: URL? = nil) async throws -> Bool {
        let contentURL: URL
        if let targetURL {
            contentURL = targetURL
        } else {
            guard let content, !content.isInvalidated else { return false }
            contentURL = content.url
        }
        let didChange = try await ReaderContentLoader.updateSnippetTitle(
            contentURL: contentURL,
            title: newTitle
        )
        // The rename belongs to the snippet captured when its UI was opened.
        // A completed write must not replace a subsequently displayed document.
        guard let observedContent = content, !observedContent.isInvalidated,
              observedContent.url == contentURL,
              let reference = ReaderContentLoader.ContentReference(content: observedContent),
              let refreshedContent = try await reference.resolveOnMainActor(),
              !refreshedContent.isInvalidated,
              content === observedContent else { return didChange }
        content = refreshedContent
        refreshObservedContentState()
        return didChange
    }
}

private extension String {
    var debugTitleFragment: String {
        let normalized = replacingOccurrences(of: "\n", with: "\\n")
        if normalized.isEmpty {
            return "\"\""
        }
        return "\"\(normalized.truncate(120, trailing: "…"))\""
    }
}

private extension Optional where Wrapped == String {
    var debugTitleFragment: String {
        guard let value = self else { return "<nil>" }
        return value.debugTitleFragment
    }
}
