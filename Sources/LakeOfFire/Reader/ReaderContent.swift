import SwiftUI
import Combine

private func logReaderLoad(_ message: String) {
    debugPrint("# READERLOAD \(message)")
}

@MainActor
public class ReaderContent: ObservableObject {
    @Published public var content: (any ReaderContentProtocol)? {
        didSet {
            syncLocationBarTitle()
            syncContentTitle()
        }
    }// = ReaderContentLoader.unsavedHome
    @Published public var pageURL = URL(string: "about:blank")! { didSet { syncLocationBarTitle() } }
    @Published public var currentSectionIndex: Int?
    @Published public var locationBarTitle: String?
    @Published public var isReaderProvisionallyNavigating = false
    @Published public var isRenderingReaderHTML = false
    public let contentTitleSubject = PassthroughSubject<String, Never>()
    public private(set) var contentTitle: String = ""
    public private(set) var snippetTitleIsGeneratedFromPrefix = false
    
    private var loadingTask: Task<(any ReaderContentProtocol)?, Error>?
    private var suppressedTransientAboutBlankTargetURL: URL?
    private var preloadedResolvedContentURL: URL?
    private var preloadedContent: (any ReaderContentProtocol)?

    public init() {
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
        let newTitle = content?.title ?? ""
        guard contentTitle != newTitle else { return }
        contentTitle = newTitle
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
    
    @MainActor
    internal func load(url: URL) async throws {
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

        if resolvedContentURL.absoluteString != "about:blank" {
            suppressedTransientAboutBlankTargetURL = nil
        }

        if let loadingTask, pageURL.matchesReaderURL(url) {
            let startedAt = CFAbsoluteTimeGetCurrent()
            _ = try await loadingTask.value
            logReaderLoad(
                "stage=readerContent.load.awaitExistingTask requestURL=\(url.absoluteString) elapsed=\(String(format: "%.3fs", CFAbsoluteTimeGetCurrent() - startedAt))"
            )
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
        loadingTask = Task { @MainActor [weak self] in
            try Task.checkCancellation()
            let content = try await ReaderViewModel.getContent(forURL: url, countsAsHistoryVisit: true) ?? ReaderContentLoader.unsavedHome
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
            logReaderLoad(
                "stage=readerContent.getContent source=cached contentURL=\(content.url.absoluteString) elapsed=\(String(format: "%.3fs", CFAbsoluteTimeGetCurrent() - startedAt))"
            )
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
            debugPrint("# READER contentTitle.update.failed", error.localizedDescription)
        }
    }
}
