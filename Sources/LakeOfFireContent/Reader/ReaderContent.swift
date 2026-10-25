import SwiftUI
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

/// Admission to the exact selection and content result used by a load.
/// A later selection permanently retires the grant. The actual content result
/// must also remain selected when the receipt is checked.
public struct ReaderContentLoadReceipt: Sendable {
    private let admission: @MainActor @Sendable () -> Bool

    fileprivate init(admission: @escaping @MainActor @Sendable () -> Bool) {
        self.admission = admission
    }

    @MainActor
    public var isCurrent: Bool { admission() }

    @MainActor
    fileprivate func requiringCurrent() throws -> Self {
        try Task.checkCancellation()
        guard isCurrent else { throw CancellationError() }
        return self
    }

    fileprivate static var rejected: Self { .init(admission: { false }) }
}

private func logReaderLoad(_ message: String) {
#if DEBUG
    debugPrint("# READERLOAD \(message)")
#endif
}

private func logTitleTrace(_ message: String) {
}

@MainActor
private func validReaderContent(_ content: (any ReaderContentProtocol)?) -> (any ReaderContentProtocol)? {
    guard let content, !content.isInvalidated else { return nil }
    return content
}

@MainActor
public class ReaderContent: ObservableObject {
    public typealias ContentResolver = @MainActor (_ url: URL, _ countsAsHistoryVisit: Bool, _ source: String) async throws -> (any ReaderContentProtocol)?

    nonisolated(unsafe) public static var contentResolver: ContentResolver?

    @Published public var content: (any ReaderContentProtocol)? {
        didSet {
            let oldContent = validReaderContent(oldValue)
            let newContent = validReaderContent(content)
            logTitleTrace(
                "stage=readerContent.content.didSet pageURL=\(pageURL.absoluteString) oldContentURL=\(oldContent?.url.absoluteString ?? "nil") newContentURL=\(newContent?.url.absoluteString ?? "nil") oldType=\(oldContent.map { String(describing: type(of: $0)) } ?? "nil") newType=\(newContent.map { String(describing: type(of: $0)) } ?? "nil") oldTitle=\(oldContent?.title.debugTitleFragment ?? "<nil>") newTitle=\(newContent?.title.debugTitleFragment ?? "<nil>") oldLocationBarTitle=\(oldContent?.locationBarTitle.debugTitleFragment ?? "<nil>") newLocationBarTitle=\(newContent?.locationBarTitle.debugTitleFragment ?? "<nil>")"
            )
            syncLocationBarTitle()
            syncContentTitle()
        }
    }// = ReaderContentLoader.unsavedHome
    @Published public var pageURL = URL(string: "about:blank")! {
        didSet {
            logTitleTrace(
                "stage=readerContent.pageURL.didSet oldPageURL=\(oldValue.absoluteString) newPageURL=\(pageURL.absoluteString) contentURL=\(validReaderContent(content)?.url.absoluteString ?? "nil") currentLocationBarTitle=\(locationBarTitle.debugTitleFragment)"
            )
            syncLocationBarTitle()
        }
    }
    @Published public var currentSectionIndex: Int?
    @Published public var locationBarTitle: String?
    @Published public var isReaderProvisionallyNavigating = false
    @Published public var isRenderingReaderHTML = false
    @Published public private(set) var isReaderMainFrameNavigating = false
    @Published public private(set) var mainFrameNavigationURL: URL?
    public let contentTitleSubject = PassthroughSubject<String, Never>()
    public private(set) var contentTitle: String = ""
    private var contentTitleURL: URL?
    private var mainFrameNavigationTasks: [UUID: URL] = [:]
    private var mainFrameNavigationTaskOrder: [UUID] = []
    public private(set) var snippetTitleIsGeneratedFromPrefix = false

    private var loadingTask: Task<(any ReaderContentProtocol)?, Error>?
    // Selection ownership outlives its resolver task and queued result delivery.
    private var selectionID: UUID?
    private var selectionLifetime = ReaderContentSelectionLifetime()
    @MainActor private struct CapturedSelectionAdmission {
        let selectionID: UUID
        let lifetime: ReaderContentSelectionLifetime
        weak var content: (any ReaderContentProtocol)?
        let contentURL: URL
        let permits: @MainActor () -> Bool
    }
    private var capturedSelectionAdmission: CapturedSelectionAdmission?
    private var loadingResolvedContentURL: URL?
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

    /// Selects caller-resolved content and retires any earlier asynchronous resolver.
    /// The caller retains responsibility for its navigation/display URL.
    public func replaceSelection(with content: (any ReaderContentProtocol)?) {
        replaceSelection(with: content, admission: nil)
    }

    /// An optional admission keeps later same-source native loads on this exact
    /// capture. Rejection cannot fall through to a fresh generic resolution.
    public func replaceSelection(
        with content: (any ReaderContentProtocol)?,
        admission: (@MainActor () -> Bool)?
    ) {
        let retiredTask = loadingTask
        let requestID = UUID()
        selectionLifetime.withdraw()
        selectionLifetime = ReaderContentSelectionLifetime()
        selectionID = requestID
        capturedSelectionAdmission = nil
        if let admission, let content = validReaderContent(content) {
            capturedSelectionAdmission = CapturedSelectionAdmission(
                selectionID: requestID, lifetime: selectionLifetime,
                content: content, contentURL: content.url,
                permits: admission
            )
        }
        loadingTask = nil
        loadingResolvedContentURL = nil
        retiredTask?.cancel()
        guard selectionID == requestID else { return }
        self.content = validReaderContent(content)
    }

    @MainActor
    public func refreshObservedContentState() {
        syncLocationBarTitle()
        syncContentTitle()
        objectWillChange.send()
    }

    @MainActor
    public func beginMainFrameNavigationTask(to url: URL) -> UUID {
        let token = UUID()
        mainFrameNavigationTasks[token] = url
        mainFrameNavigationTaskOrder.append(token)
        isReaderMainFrameNavigating = true
        mainFrameNavigationURL = url
        return token
    }

    @MainActor
    public func endMainFrameNavigationTask(_ token: UUID) {
        guard mainFrameNavigationTasks.removeValue(forKey: token) != nil else { return }
        if let index = mainFrameNavigationTaskOrder.firstIndex(of: token) {
            mainFrameNavigationTaskOrder.remove(at: index)
        }
        let remainingToken = mainFrameNavigationTaskOrder.last
        mainFrameNavigationURL = remainingToken.flatMap { mainFrameNavigationTasks[$0] }
        isReaderMainFrameNavigating = !mainFrameNavigationTaskOrder.isEmpty
    }

    private func syncLocationBarTitle() {
        guard pageURL.absoluteString != "about:blank" else {
            snippetTitleIsGeneratedFromPrefix = false
            locationBarTitle = nil
            logTitleTrace(
                "stage=readerContent.syncLocationBarTitle action=clear reason=aboutBlank pageURL=\(pageURL.absoluteString) contentURL=\(validReaderContent(content)?.url.absoluteString ?? "nil")"
            )
            return
        }
        guard let content = validReaderContent(content),
              content.url.matchesReaderURL(pageURL) else {
            snippetTitleIsGeneratedFromPrefix = false
            locationBarTitle = nil
            logTitleTrace(
                "stage=readerContent.syncLocationBarTitle action=clear reason=contentMismatch pageURL=\(pageURL.absoluteString) contentURL=\(validReaderContent(content)?.url.absoluteString ?? "nil") contentType=\(validReaderContent(content).map { String(describing: type(of: $0)) } ?? "nil") contentTitle=\(validReaderContent(content)?.title.debugTitleFragment ?? "<nil>")"
            )
            return
        }
        let trimmedTitle = resolvedLocationBarTitle(for: content)?.trimmingCharacters(in: .whitespacesAndNewlines)
        locationBarTitle = (trimmedTitle?.isEmpty == false) ? trimmedTitle : nil
        guard !content.isInvalidated else { return }
        logTitleTrace(
            "stage=readerContent.syncLocationBarTitle action=set pageURL=\(pageURL.absoluteString) contentURL=\(content.url.absoluteString) contentType=\(String(describing: type(of: content))) contentTitle=\(content.title.debugTitleFragment) rawLocationBarTitle=\(content.locationBarTitle.debugTitleFragment) resolvedTitle=\(trimmedTitle.debugTitleFragment) finalLocationBarTitle=\(locationBarTitle.debugTitleFragment) snippetTitleIsGeneratedFromPrefix=\(snippetTitleIsGeneratedFromPrefix)"
        )
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
        guard let content = validReaderContent(content) else {
            logTitleTrace(
                "stage=readerContent.syncContentTitle action=preserve reason=noContent existingTitle=\(contentTitle.debugTitleFragment) pageURL=\(pageURL.absoluteString)"
            )
            return
        }
        let newTitle = content.title
        let newTitleURL = content.url
        guard contentTitle != newTitle || contentTitleURL?.absoluteString != newTitleURL.absoluteString else { return }
        logTitleTrace(
            "stage=readerContent.syncContentTitle action=set oldTitle=\(contentTitle.debugTitleFragment) newTitle=\(newTitle.debugTitleFragment) oldContentURL=\(contentTitleURL?.absoluteString ?? "nil") newContentURL=\(newTitleURL.absoluteString) pageURL=\(pageURL.absoluteString)"
        )
        contentTitle = newTitle
        contentTitleURL = newTitleURL
        guard !newTitle.isEmpty else { return }
        contentTitleSubject.send(newTitle)
    }

    private func matchesResolvedContentURL(_ contentURL: URL, resolvedContentURL: URL) -> Bool {
        contentURL.absoluteString == resolvedContentURL.absoluteString
            || contentURL.matchesReaderURL(resolvedContentURL)
    }

    private func consumeTransientAboutBlankSuppressionIfMatching(resolvedContentURL: URL) {
        guard let suppressedTransientAboutBlankTargetURL,
              matchesResolvedContentURL(
                suppressedTransientAboutBlankTargetURL,
                resolvedContentURL: resolvedContentURL
              ) else {
            return
        }
        self.suppressedTransientAboutBlankTargetURL = nil
    }

    @MainActor
    public func suppressTransientAboutBlank(untilNextNonBlankLoad targetURL: URL) {
        let resolvedTargetURL = ReaderContentLoader.getContentURL(fromLoaderURL: targetURL) ?? targetURL
        guard resolvedTargetURL.absoluteString != "about:blank" else { return }
        suppressedTransientAboutBlankTargetURL = resolvedTargetURL
        logReaderLoad(
            "stage=readerContent.load.suppressAboutBlank targetURL=\(resolvedTargetURL.absoluteString)"
        )
    }

    @MainActor
    public func preloadResolvedContent(_ content: any ReaderContentProtocol, for targetURL: URL) {
        let resolvedTargetURL = ReaderContentLoader.getContentURL(fromLoaderURL: targetURL) ?? targetURL
        guard !content.isInvalidated else { return }
        guard content.url.matchesReaderURL(resolvedTargetURL) else {
            logReaderLoad(
                "stage=readerContent.preload.skip targetURL=\(resolvedTargetURL.absoluteString) contentURL=\(content.url.absoluteString) reason=mismatch"
            )
            return
        }
        preloadedResolvedContentURL = resolvedTargetURL
        preloadedContent = content
        logReaderLoad(
            "stage=readerContent.preload targetURL=\(resolvedTargetURL.absoluteString) contentURL=\(content.url.absoluteString) contentType=\(String(describing: type(of: content))) key=\(content.compoundKey)"
        )
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
    public func load(url: URL) async throws {
        // Keep the established Void API's quiet retirement settlement.
        _ = try await loadCapturingSelection(url: url)
    }

    /// Continuations which publish must retain the actual load's receipt rather
    /// than capturing whichever selection is current when they resume.
    @MainActor
    public func loadWithSelectionReceipt(url: URL) async throws -> ReaderContentLoadReceipt {
        let receipt = try await loadCapturingSelection(url: url)
        return try receipt.requiringCurrent()
    }

    private func makeLoadReceipt(
        selectionFence: @escaping @Sendable () -> Bool,
        expectedContent: (any ReaderContentProtocol)?,
        admission: CapturedSelectionAdmission? = nil
    ) -> ReaderContentLoadReceipt {
        let expectedIdentity = expectedContent.map { ObjectIdentifier($0) }
        return .init(admission: { [weak self] in
            guard selectionFence(), let self else { return false }
            if let admission, !self.admits(admission) { return false }
            // A caller predicate may synchronously replace this selection.
            guard selectionFence() else { return false }
            let currentContent = content
            guard currentContent?.isInvalidated != true else { return false }
            return currentContent.map { ObjectIdentifier($0) } == expectedIdentity
        })
    }

    private func admits(_ admission: CapturedSelectionAdmission) -> Bool {
        guard admission.lifetime.permitsCommit(),
              selectionID == admission.selectionID else { return false }
        guard admission.permits(), admission.lifetime.permitsCommit(),
              selectionID == admission.selectionID,
              let current = validReaderContent(content),
              current === admission.content,
              matchesResolvedContentURL(current.url, resolvedContentURL: admission.contentURL) else {
            // Withdraw only the original token, including after predicate reentry.
            // A predicate becoming true later must not revive a rejected capture.
            admission.lifetime.withdraw()
            return false
        }
        return true
    }

    private func loadCapturingSelection(url: URL) async throws -> ReaderContentLoadReceipt {
        try Task.checkCancellation()
        let entryFence = makeSelectionCommitFence(requiring: selectionID)
        let entryAdmission = capturedSelectionAdmission
        let resolvedContentURL = ReaderContentLoader.getContentURL(fromLoaderURL: url) ?? url
        let displayURL = resolvedContentURL
        if let entryAdmission,
           matchesResolvedContentURL(entryAdmission.contentURL, resolvedContentURL: resolvedContentURL) {
            guard admits(entryAdmission), entryFence() else { return .rejected }
            let capturedContent = content
            if !matchesResolvedContentURL(pageURL, resolvedContentURL: displayURL) {
                pageURL = displayURL
            }
            guard entryFence(), admits(entryAdmission) else { return .rejected }
            consumeTransientAboutBlankSuppressionIfMatching(resolvedContentURL: resolvedContentURL)
            return makeLoadReceipt(selectionFence: entryFence, expectedContent: capturedContent,
                                   admission: entryAdmission)
        }
        logReaderLoad(
            "stage=readerContent.load.begin requestURL=\(url.absoluteString) resolvedContentURL=\(resolvedContentURL.absoluteString) currentPageURL=\(pageURL.absoluteString) currentContentURL=\(validReaderContent(content)?.url.absoluteString ?? "nil") hasLoadingTask=\(loadingTask != nil)"
        )

        if resolvedContentURL.absoluteString == "about:blank",
           let suppressedTargetURL = suppressedTransientAboutBlankTargetURL,
           suppressedTargetURL.absoluteString != "about:blank" {
            logReaderLoad(
                "stage=readerContent.load.skipTransientAboutBlank requestURL=\(url.absoluteString) targetURL=\(suppressedTargetURL.absoluteString)"
            )
            return makeLoadReceipt(selectionFence: entryFence, expectedContent: content,
                                   admission: entryAdmission)
        }

        if resolvedContentURL.absoluteString == "about:blank",
           WebViewReaderLoadActivity.shared.hasPendingPreProvisionalLoad {
            logReaderLoad(
                "stage=readerContent.load.skipActiveInternalLoaderAboutBlank requestURL=\(url.absoluteString)"
            )
            return makeLoadReceipt(selectionFence: entryFence, expectedContent: content,
                                   admission: entryAdmission)
        }

        if resolvedContentURL.absoluteString != "about:blank",
           let suppressedTargetURL = suppressedTransientAboutBlankTargetURL,
           !matchesResolvedContentURL(suppressedTargetURL, resolvedContentURL: resolvedContentURL) {
            suppressedTransientAboutBlankTargetURL = nil
        }

        if entryAdmission == nil, let loadingTask,
           !loadingTask.isCancelled,
           let loadingResolvedContentURL,
           matchesResolvedContentURL(loadingResolvedContentURL, resolvedContentURL: resolvedContentURL) {
            let startedAt = CFAbsoluteTimeGetCurrent()
            logReaderLoad(
                "stage=readerContent.load.reuseLoadingTask requestURL=\(url.absoluteString) resolvedContentURL=\(resolvedContentURL.absoluteString) loadingResolvedContentURL=\(loadingResolvedContentURL.absoluteString) currentPageURL=\(pageURL.absoluteString) currentContentURL=\(validReaderContent(content)?.url.absoluteString ?? "nil")"
            )
            let loadedContent = try await loadingTask.value
            logReaderLoad(
                "stage=readerContent.load.awaitExistingTask requestURL=\(url.absoluteString) resolvedContentURL=\(resolvedContentURL.absoluteString) loadingResolvedContentURL=\(loadingResolvedContentURL.absoluteString) elapsed=\(String(format: "%.3fs", CFAbsoluteTimeGetCurrent() - startedAt))"
            )
            return makeLoadReceipt(selectionFence: entryFence, expectedContent: loadedContent,
                                   admission: entryAdmission)
        }

        // Reusing an accepted display without pending work is not a new selection.
        // Keep readers of its completed resolver valid.
        if entryAdmission == nil, loadingTask == nil, let existingContent = validReaderContent(content),
           matchesResolvedContentURL(existingContent.url, resolvedContentURL: resolvedContentURL),
           matchesResolvedContentURL(pageURL, resolvedContentURL: displayURL) {
            consumeTransientAboutBlankSuppressionIfMatching(resolvedContentURL: resolvedContentURL)
            return makeLoadReceipt(selectionFence: entryFence, expectedContent: existingContent,
                                   admission: entryAdmission)
        }

        // Retire the previous selection before cached or preloaded content can publish.
        let retiredTask = loadingTask
        let requestID = UUID()
        selectionLifetime.withdraw()
        selectionLifetime = ReaderContentSelectionLifetime()
        selectionID = requestID
        capturedSelectionAdmission = nil
        let requestFence = makeSelectionCommitFence(requiring: requestID)
        loadingTask = nil
        loadingResolvedContentURL = nil
        defer { finishLoading(ifOwnedBy: requestID) }
        retiredTask?.cancel()
        guard selectionID == requestID else { return .rejected }

        if let existingContent = validReaderContent(content),
           matchesResolvedContentURL(existingContent.url, resolvedContentURL: resolvedContentURL) {
            let pageAlreadyMatchesDisplay = pageURL.absoluteString == displayURL.absoluteString
                || pageURL.matchesReaderURL(displayURL)
            if pageAlreadyMatchesDisplay {
                consumeTransientAboutBlankSuppressionIfMatching(resolvedContentURL: resolvedContentURL)
                logReaderLoad(
                    "stage=readerContent.load.reuseExistingContent.sameDisplay requestURL=\(url.absoluteString) existingContentURL=\(existingContent.url.absoluteString) displayURL=\(displayURL.absoluteString) currentPageURL=\(pageURL.absoluteString)"
                )
                return makeLoadReceipt(selectionFence: requestFence, expectedContent: existingContent)
            }
            consumeTransientAboutBlankSuppressionIfMatching(resolvedContentURL: resolvedContentURL)
            if !pageURL.matchesReaderURL(url) {
                logReaderLoad(
                    "stage=readerContent.load.reuseExistingContent requestURL=\(url.absoluteString) existingContentURL=\(existingContent.url.absoluteString) displayURL=\(displayURL.absoluteString)"
                )
                pageURL = displayURL
            }
            return makeLoadReceipt(selectionFence: requestFence, expectedContent: existingContent)
        }

        if let preloadedContent = consumePreloadedContentIfMatching(resolvedContentURL: resolvedContentURL) {
            consumeTransientAboutBlankSuppressionIfMatching(resolvedContentURL: resolvedContentURL)
            logReaderLoad(
                "stage=readerContent.load.usePreloadedContent requestURL=\(url.absoluteString) resolvedContentURL=\(resolvedContentURL.absoluteString) contentURL=\(preloadedContent.url.absoluteString) key=\(preloadedContent.compoundKey)"
            )
            currentSectionIndex = nil
            guard selectionID == requestID, !preloadedContent.isInvalidated else { return .rejected }
            content = preloadedContent
            guard selectionID == requestID, !preloadedContent.isInvalidated,
                  content === preloadedContent else { return .rejected }
            pageURL = displayURL
            logReaderLoad(
                "stage=readerContent.load.finish requestURL=\(url.absoluteString) pageURL=\(pageURL.absoluteString) contentURL=\(validReaderContent(preloadedContent)?.url.absoluteString ?? "nil")"
            )
            return makeLoadReceipt(selectionFence: requestFence, expectedContent: preloadedContent)
        }

        logReaderLoad(
            "stage=readerContent.load.clearState requestURL=\(url.absoluteString) newPageURL=\(displayURL.absoluteString)"
        )
        content = nil
        guard selectionID == requestID else { return .rejected }
        currentSectionIndex = nil
        guard selectionID == requestID else { return .rejected }
        pageURL = displayURL
        guard selectionID == requestID else { return .rejected }

        loadingResolvedContentURL = resolvedContentURL
        let task = Task<(any ReaderContentProtocol)?, Error> { @MainActor [weak self] in
            // Release the owned slot before coalesced waiters observe completion.
            defer { self?.finishLoading(ifOwnedBy: requestID) }
            try Task.checkCancellation()
            let content = try await Self.contentResolver?(
                url,
                true,
                "ReaderContent.load"
            ) ?? ReaderContentLoader.unsavedHome
            guard !content.isInvalidated else { return nil }
            guard self?.selectionID == requestID else {
                logReaderLoad(
                    "stage=readerContent.load.discardStaleContent requestURL=\(url.absoluteString) resolvedContentURL=\(resolvedContentURL.absoluteString) returnedContentURL=\(content.url.absoluteString)"
                )
                return nil
            }
            guard content.url.matchesReaderURL(resolvedContentURL) else {
                logReaderLoad(
                    "stage=readerContent.load.mismatchedContent requestURL=\(url.absoluteString) resolvedContentURL=\(resolvedContentURL.absoluteString) returnedContentURL=\(content.url.absoluteString)"
                )
                debugPrint("Warning: Mismatched URL in ReaderContent.load:", url.absoluteString, content.url)
                return nil
            }
            self?.consumeTransientAboutBlankSuppressionIfMatching(resolvedContentURL: resolvedContentURL)
            self?.content = content
            // Publication subscribers can retire the selection synchronously.
            guard !content.isInvalidated, self?.selectionID == requestID,
                  self?.content === content else { return nil }
            logReaderLoad(
                "stage=readerContent.load.contentResolved requestURL=\(url.absoluteString) contentURL=\(content.url.absoluteString) contentType=\(String(describing: type(of: content))) key=\(content.compoundKey)"
            )
            return content
        }
        loadingTask = task
        let loadedContent = try await task.value
        let finalContentURL = validReaderContent(loadedContent)?.url.absoluteString
            ?? validReaderContent(content)?.url.absoluteString ?? "nil"
        logReaderLoad(
            "stage=readerContent.load.finish requestURL=\(url.absoluteString) pageURL=\(pageURL.absoluteString) contentURL=\(finalContentURL)"
        )
        return makeLoadReceipt(selectionFence: requestFence, expectedContent: loadedContent)
    }

    private func finishLoading(ifOwnedBy requestID: UUID) {
        guard selectionID == requestID else { return }
        loadingTask = nil
        loadingResolvedContentURL = nil
    }

    @MainActor
    public func prepareForDisplay(url: URL) async throws {
        try await load(url: url)
    }

    @MainActor
    public func getContent() async throws -> (any ReaderContentProtocol)? {
        let startedAt = CFAbsoluteTimeGetCurrent()
        if let content {
            return validReaderContent(content)
        }
        let expectedSelectionID = selectionID
        let resolvedContent = try await loadingTask?.value
        // A completed task value is valid only in the selection that admitted it.
        guard selectionID == expectedSelectionID,
              let resolvedContent, !resolvedContent.isInvalidated,
              content === resolvedContent else { return nil }
        let contentURL = resolvedContent.url.absoluteString
        logReaderLoad(
            "stage=readerContent.getContent source=loadingTask contentURL=\(contentURL) elapsed=\(String(format: "%.3fs", CFAbsoluteTimeGetCurrent() - startedAt))"
        )
        return resolvedContent
    }

    @MainActor
    public func updateContentTitle(_ newTitle: String) async {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let content else { return }
        guard trimmed != content.title else { return }
        logTitleTrace(
            "stage=readerContent.updateContentTitle begin pageURL=\(pageURL.absoluteString) contentURL=\(content.url.absoluteString) oldTitle=\(content.title.debugTitleFragment) requestedTitle=\(newTitle.debugTitleFragment) trimmedTitle=\(trimmed.debugTitleFragment)"
        )
        let isTitlePrefixOfContent =
            content.url.isSnippetURL &&
            ReaderContentLoader.snippetTitleMatchesGeneratedPrefix(
                trimmed,
                sourceHTML: content.html
            )

        content.title = trimmed
        content.isTitlePrefixOfContent = isTitlePrefixOfContent
        syncLocationBarTitle()
        syncContentTitle()

        do {
            let contentURL = content.url
            try await ReaderContentLoader.updateContent(url: contentURL) { object in
                guard object.title != trimmed || object.isTitlePrefixOfContent != isTitlePrefixOfContent else {
                    return false
                }
                object.title = trimmed
                object.isTitlePrefixOfContent = isTitlePrefixOfContent
                return true
            }
            logTitleTrace(
                "stage=readerContent.updateContentTitle persisted contentURL=\(contentURL.absoluteString) finalTitle=\(trimmed.debugTitleFragment) isTitlePrefixOfContent=\(isTitlePrefixOfContent)"
            )
        } catch {
            debugPrint("# EPUB  contentTitle.update.failed", error.localizedDescription)
        }
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
