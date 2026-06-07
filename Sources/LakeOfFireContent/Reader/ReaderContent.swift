import SwiftUI
import LakeOfFireCore
import Combine

private let activeInternalReaderLoaderTraceIDKey = "SwiftUIWebView.activeInternalReaderLoader.traceID"
private let activeInternalReaderLoaderURLKey = "SwiftUIWebView.activeInternalReaderLoader.url"



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

        if resolvedContentURL.absoluteString == "about:blank",
           let suppressedTargetURL = suppressedTransientAboutBlankTargetURL,
           suppressedTargetURL.absoluteString != "about:blank" {
            return
        }

        if resolvedContentURL.absoluteString == "about:blank",
           let activeInternalLoaderWait = activeInternalLoaderWaitContext() {
            return
        }

        if resolvedContentURL.absoluteString != "about:blank" {
            suppressedTransientAboutBlankTargetURL = nil
        }

        if let loadingTask,
           let loadingResolvedContentURL,
           matchesResolvedContentURL(loadingResolvedContentURL, resolvedContentURL: resolvedContentURL) {
            let startedAt = CFAbsoluteTimeGetCurrent()
            _ = try await loadingTask.value
            return
        }

        if let existingContent = content,
           matchesResolvedContentURL(existingContent.url, resolvedContentURL: resolvedContentURL) {
            let pageAlreadyMatchesDisplay = pageURL.absoluteString == displayURL.absoluteString
                || pageURL.matchesReaderURL(displayURL)
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
        
        loadingTask?.cancel()
        loadingResolvedContentURL = resolvedContentURL
        loadingTask = Task { @MainActor [weak self] in
            try Task.checkCancellation()
            let content = try await ReaderContentLoader.getContent(
                forURL: url,
                countsAsHistoryVisit: true,
                source: "ReaderContent.load"
            ) ?? ReaderContentLoader.unsavedHome
            guard content.url.matchesReaderURL(resolvedContentURL) else {
                debugPrint("Warning: Mismatched URL in ReaderContent.load:", url.absoluteString, content.url)
                return nil
            }
            self?.content = content
            return content
        }
        let loadedContent = try await loadingTask?.value
        loadingTask = nil
        loadingResolvedContentURL = nil
        let finalContentURL = loadedContent.flatMap { $0 }?.url.absoluteString ?? content?.url.absoluteString ?? "nil"
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
        return content
    }

    @MainActor
    public func updateContentTitle(_ newTitle: String) async {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let content else { return }
        guard trimmed != content.title else { return }
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
        } catch {
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
