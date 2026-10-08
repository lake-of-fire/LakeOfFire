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

    func permitsCommit() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCurrent
    }

    func withdraw() {
        lock.lock()
        defer { lock.unlock() }
        isCurrent = false
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
    private var suppressedTransientAboutBlankTargetURL: URL?
    private var preloadedResolvedContentURL: URL?
    private var preloadedContent: (any ReaderContentProtocol)?

    public init() {
    }

    deinit {
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
        guard let content,
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
        guard let content else {
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
        guard content.url.matchesReaderURL(resolvedTargetURL) else {
            return
        }
        preloadedResolvedContentURL = resolvedTargetURL
        preloadedContent = content
    }

    private func consumePreloadedContentIfMatching(resolvedContentURL: URL) -> (any ReaderContentProtocol)? {
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
    public func load(url: URL) async throws {
        try await load(url: url) { url in
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
        resolveContent: @escaping @MainActor (URL) async throws -> (any ReaderContentProtocol)?
    ) async throws {
        try Task.checkCancellation()
        let resolvedContentURL = ReaderContentLoader.getContentURL(fromLoaderURL: url) ?? url
        let displayURL = resolvedContentURL

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
            _ = try await loadingTask.value
            return
        }

        // Reopening the already displayed content is not a new selection.
        // Keep completed readers valid, but still retire any unrelated task.
        if loadingTask == nil, let existingContent = content,
           matchesResolvedContentURL(existingContent.url, resolvedContentURL: resolvedContentURL),
           matchesResolvedContentURL(pageURL, resolvedContentURL: displayURL) {
            return
        }

        // Every new selection retires the preceding load, including cached and
        // preloaded fast paths. Withdraw its identity before cancellation can
        // invoke callbacks; an old completion may never republish its content.
        let retiredTask = loadingTask
        let loadID = UUID()
        selectionLifetime.withdraw()
        selectionLifetime = ReaderContentSelectionLifetime()
        selectionID = loadID
        loadingTask = nil
        loadingResolvedContentURL = nil
        defer { finishLoading(ifOwnedBy: loadID) }
        retiredTask?.cancel()

        if let existingContent = content,
           matchesResolvedContentURL(existingContent.url, resolvedContentURL: resolvedContentURL) {
            let pageAlreadyMatchesDisplay = matchesResolvedContentURL(
                pageURL, resolvedContentURL: displayURL
            )
            if pageAlreadyMatchesDisplay {
                return
            }
            if !pageURL.matchesReaderURL(url) {
                pageURL = displayURL
            }
            return
        }

        if let preloadedContent = consumePreloadedContentIfMatching(resolvedContentURL: resolvedContentURL) {
            currentSectionIndex = nil
            content = preloadedContent
            pageURL = displayURL
            return
        }

        content = nil
        currentSectionIndex = nil
        pageURL = displayURL
        
        loadingResolvedContentURL = resolvedContentURL
        let task = Task<(any ReaderContentProtocol)?, Error> { @MainActor [weak self, loadID] in
            // Finish before any coalesced waiter receives success/error. Its
            // immediate retry must not rejoin this already-completed task.
            defer { self?.finishLoading(ifOwnedBy: loadID) }
            try Task.checkCancellation()
            let content = try await resolveContent(url) ?? ReaderContentLoader.unsavedHome
            guard content.url.matchesReaderURL(resolvedContentURL) else {
                debugPrint("Warning: Mismatched URL in ReaderContent.load:", url.absoluteString, content.url)
                return nil
            }
            guard let self, self.selectionID == loadID else {
                return nil
            }
            self.content = content
            return content
        }
        loadingTask = task
        _ = try await task.value
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
            return content
        }
        let selectionID = self.selectionID
        let resolvedContent = try await loadingTask?.value
        // Completing a task makes its value available, not permanently current.
        // Navigation or a publication subscriber may replace the selection
        // before this waiter resumes. Never return the displaced value or
        // substitute the newly displayed content for the original read.
        guard self.selectionID == selectionID,
              let resolvedContent, content === resolvedContent else { return nil }
        return resolvedContent
    }

    @MainActor
    @discardableResult
    public func updateContentTitle(_ newTitle: String, for targetURL: URL? = nil) async throws -> Bool {
        guard let contentURL = targetURL ?? content?.url else { return false }
        let didChange = try await ReaderContentLoader.updateSnippetTitle(
            contentURL: contentURL,
            title: newTitle
        )
        // The rename belongs to the snippet captured when its UI was opened.
        // A completed write must not replace a subsequently displayed document.
        guard let observedContent = content,
              observedContent.url == contentURL,
              let reference = ReaderContentLoader.ContentReference(content: observedContent),
              let refreshedContent = try await reference.resolveOnMainActor(),
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
