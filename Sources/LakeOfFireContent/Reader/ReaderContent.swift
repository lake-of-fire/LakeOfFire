import SwiftUI
import Combine

private let activeInternalReaderLoaderTraceIDKey = "SwiftUIWebView.activeInternalReaderLoader.traceID"
private let activeInternalReaderLoaderURLKey = "SwiftUIWebView.activeInternalReaderLoader.url"

private func logReaderLoad(_ message: String) {
#if DEBUG
    debugPrint("# READERLOAD \(message)")
#endif
}

private func logTitleTrace(_ message: String) {
#if DEBUG
    debugPrint("# TITLE \(message)")
#endif
}

@MainActor
public class ReaderContent: ObservableObject {
    public typealias ContentResolver = @MainActor (_ url: URL, _ countsAsHistoryVisit: Bool, _ source: String) async throws -> (any ReaderContentProtocol)?

    nonisolated(unsafe) public static var contentResolver: ContentResolver?

    @Published public var content: (any ReaderContentProtocol)? {
        didSet {
            logTitleTrace(
                "stage=readerContent.content.didSet pageURL=\(pageURL.absoluteString) oldContentURL=\(oldValue?.url.absoluteString ?? "nil") newContentURL=\(content?.url.absoluteString ?? "nil") oldType=\(oldValue.map { String(describing: type(of: $0)) } ?? "nil") newType=\(content.map { String(describing: type(of: $0)) } ?? "nil") oldTitle=\(oldValue?.title.debugTitleFragment ?? "<nil>") newTitle=\(content?.title.debugTitleFragment ?? "<nil>") oldLocationBarTitle=\(oldValue?.locationBarTitle.debugTitleFragment ?? "<nil>") newLocationBarTitle=\(content?.locationBarTitle.debugTitleFragment ?? "<nil>")"
            )
            syncLocationBarTitle()
            syncContentTitle()
        }
    }// = ReaderContentLoader.unsavedHome
    @Published public var pageURL = URL(string: "about:blank")! {
        didSet {
            logTitleTrace(
                "stage=readerContent.pageURL.didSet oldPageURL=\(oldValue.absoluteString) newPageURL=\(pageURL.absoluteString) contentURL=\(content?.url.absoluteString ?? "nil") currentLocationBarTitle=\(locationBarTitle.debugTitleFragment)"
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
    private var loadingResolvedContentURL: URL?
    private var suppressedTransientAboutBlankTargetURL: URL?
    private var preloadedResolvedContentURL: URL?
    private var preloadedContent: (any ReaderContentProtocol)?

    public init() {
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
                "stage=readerContent.syncLocationBarTitle action=clear reason=aboutBlank pageURL=\(pageURL.absoluteString) contentURL=\(content?.url.absoluteString ?? "nil")"
            )
            return
        }
        guard let content,
              content.url.matchesReaderURL(pageURL) else {
            snippetTitleIsGeneratedFromPrefix = false
            locationBarTitle = nil
            logTitleTrace(
                "stage=readerContent.syncLocationBarTitle action=clear reason=contentMismatch pageURL=\(pageURL.absoluteString) contentURL=\(content?.url.absoluteString ?? "nil") contentType=\(content.map { String(describing: type(of: $0)) } ?? "nil") contentTitle=\(content?.title.debugTitleFragment ?? "<nil>")"
            )
            return
        }
        let trimmedTitle = resolvedLocationBarTitle(for: content)?.trimmingCharacters(in: .whitespacesAndNewlines)
        locationBarTitle = (trimmedTitle?.isEmpty == false) ? trimmedTitle : nil
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
        guard let content else {
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

    private func activeInternalLoaderWaitContext() -> (traceID: String, requestURL: String)? {
        let defaults = UserDefaults.standard
        guard let traceID = defaults.string(forKey: activeInternalReaderLoaderTraceIDKey),
              let requestURL = defaults.string(forKey: activeInternalReaderLoaderURLKey) else {
            return nil
        }
        return (traceID, requestURL)
    }

    @MainActor
    public func load(url: URL) async throws {
        let resolvedContentURL = ReaderContentLoader.getContentURL(fromLoaderURL: url) ?? url
        let displayURL = resolvedContentURL
        logReaderLoad(
            "stage=readerContent.load.begin requestURL=\(url.absoluteString) resolvedContentURL=\(resolvedContentURL.absoluteString) currentPageURL=\(pageURL.absoluteString) currentContentURL=\(content?.url.absoluteString ?? "nil") hasLoadingTask=\(loadingTask != nil)"
        )

        if resolvedContentURL.absoluteString == "about:blank",
           let suppressedTargetURL = suppressedTransientAboutBlankTargetURL,
           suppressedTargetURL.absoluteString != "about:blank" {
            logReaderLoad(
                "stage=readerContent.load.skipTransientAboutBlank requestURL=\(url.absoluteString) targetURL=\(suppressedTargetURL.absoluteString)"
            )
            return
        }

        if resolvedContentURL.absoluteString == "about:blank",
           let activeInternalLoaderWait = activeInternalLoaderWaitContext() {
            logReaderLoad(
                "stage=readerContent.load.skipActiveInternalLoaderAboutBlank requestURL=\(url.absoluteString) activeLoaderURL=\(activeInternalLoaderWait.requestURL) traceID=\(activeInternalLoaderWait.traceID)"
            )
            return
        }

        if resolvedContentURL.absoluteString != "about:blank" {
            suppressedTransientAboutBlankTargetURL = nil
        }

        if let loadingTask,
           let loadingResolvedContentURL,
           matchesResolvedContentURL(loadingResolvedContentURL, resolvedContentURL: resolvedContentURL) {
            let startedAt = CFAbsoluteTimeGetCurrent()
            logReaderLoad(
                "stage=readerContent.load.reuseLoadingTask requestURL=\(url.absoluteString) resolvedContentURL=\(resolvedContentURL.absoluteString) loadingResolvedContentURL=\(loadingResolvedContentURL.absoluteString) currentPageURL=\(pageURL.absoluteString) currentContentURL=\(content?.url.absoluteString ?? "nil")"
            )
            _ = try await loadingTask.value
            logReaderLoad(
                "stage=readerContent.load.awaitExistingTask requestURL=\(url.absoluteString) resolvedContentURL=\(resolvedContentURL.absoluteString) loadingResolvedContentURL=\(loadingResolvedContentURL.absoluteString) elapsed=\(String(format: "%.3fs", CFAbsoluteTimeGetCurrent() - startedAt))"
            )
            return
        }

        if let existingContent = content,
           matchesResolvedContentURL(existingContent.url, resolvedContentURL: resolvedContentURL) {
            let pageAlreadyMatchesDisplay = pageURL.absoluteString == displayURL.absoluteString
                || pageURL.matchesReaderURL(displayURL)
            if pageAlreadyMatchesDisplay {
                logReaderLoad(
                    "stage=readerContent.load.reuseExistingContent.sameDisplay requestURL=\(url.absoluteString) existingContentURL=\(existingContent.url.absoluteString) displayURL=\(displayURL.absoluteString) currentPageURL=\(pageURL.absoluteString)"
                )
                return
            }
            if !pageURL.matchesReaderURL(url) {
                logReaderLoad(
                    "stage=readerContent.load.reuseExistingContent requestURL=\(url.absoluteString) existingContentURL=\(existingContent.url.absoluteString) displayURL=\(displayURL.absoluteString)"
                )
                pageURL = displayURL
            }
            return
        }

        if let preloadedContent = consumePreloadedContentIfMatching(resolvedContentURL: resolvedContentURL) {
            logReaderLoad(
                "stage=readerContent.load.usePreloadedContent requestURL=\(url.absoluteString) resolvedContentURL=\(resolvedContentURL.absoluteString) contentURL=\(preloadedContent.url.absoluteString) key=\(preloadedContent.compoundKey)"
            )
            currentSectionIndex = nil
            content = preloadedContent
            pageURL = displayURL
            logReaderLoad(
                "stage=readerContent.load.finish requestURL=\(url.absoluteString) pageURL=\(pageURL.absoluteString) contentURL=\(preloadedContent.url.absoluteString)"
            )
            return
        }

        logReaderLoad(
            "stage=readerContent.load.clearState requestURL=\(url.absoluteString) newPageURL=\(displayURL.absoluteString)"
        )
        content = nil
        currentSectionIndex = nil
        pageURL = displayURL

        loadingTask?.cancel()
        loadingResolvedContentURL = resolvedContentURL
        loadingTask = Task { @MainActor [weak self] in
            try Task.checkCancellation()
            let content = try await Self.contentResolver?(
                url,
                true,
                "ReaderContent.load"
            ) ?? ReaderContentLoader.unsavedHome
            guard content.url.matchesReaderURL(resolvedContentURL) else {
                logReaderLoad(
                    "stage=readerContent.load.mismatchedContent requestURL=\(url.absoluteString) resolvedContentURL=\(resolvedContentURL.absoluteString) returnedContentURL=\(content.url.absoluteString)"
                )
                debugPrint("Warning: Mismatched URL in ReaderContent.load:", url.absoluteString, content.url)
                return nil
            }
            self?.content = content
            logReaderLoad(
                "stage=readerContent.load.contentResolved requestURL=\(url.absoluteString) contentURL=\(content.url.absoluteString) contentType=\(String(describing: type(of: content))) key=\(content.compoundKey)"
            )
            return content
        }
        let loadedContent = try await loadingTask?.value
        loadingTask = nil
        loadingResolvedContentURL = nil
        let finalContentURL = loadedContent.flatMap { $0 }?.url.absoluteString ?? content?.url.absoluteString ?? "nil"
        logReaderLoad(
            "stage=readerContent.load.finish requestURL=\(url.absoluteString) pageURL=\(pageURL.absoluteString) contentURL=\(finalContentURL)"
        )
    }

    @MainActor
    public func prepareForDisplay(url: URL) async throws {
        try await load(url: url)
    }

    @MainActor
    public func getContent() async throws -> (any ReaderContentProtocol)? {
        let startedAt = CFAbsoluteTimeGetCurrent()
        if let content {
            return content
        }
        let content = try await loadingTask?.value
        let contentURL = content?.url.absoluteString ?? "nil"
        logReaderLoad(
            "stage=readerContent.getContent source=loadingTask contentURL=\(contentURL) elapsed=\(String(format: "%.3fs", CFAbsoluteTimeGetCurrent() - startedAt))"
        )
        return content
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
