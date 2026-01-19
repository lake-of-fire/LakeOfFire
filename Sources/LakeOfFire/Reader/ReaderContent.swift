import SwiftUI
import Combine

@MainActor
public class ReaderContent: ObservableObject {
    @Published public var content: (any ReaderContentProtocol)?// = ReaderContentLoader.unsavedHome
    @Published public var pageURL = URL(string: "about:blank")! {
        didSet {
            let pointer = Unmanaged.passUnretained(self).toOpaque()
            if pageURL.isSnippetURL {
                debugPrint("# LOOKUPS ReaderContent.pageURL didSet snippet", pageURL.absoluteString, "self=", pointer)
            } else {
                debugPrint("# LOOKUPS ReaderContent.pageURL didSet", pageURL.absoluteString, "self=", pointer)
            }
        }
    }
    @Published public var currentSectionIndex: Int?
    @Published public var locationBarTitle: String?
    @Published public var isReaderProvisionallyNavigating = false
    @Published public private(set) var isReaderMainFrameNavigating = false
    @Published public private(set) var mainFrameNavigationURL: URL?
    private var mainFrameNavigationTasks: [UUID: URL] = [:]
    private var mainFrameNavigationTaskOrder: [UUID] = []
    public let contentTitleSubject = PassthroughSubject<String, Never>()
    public private(set) var contentTitle: String = ""
    private var cancellables = Set<AnyCancellable>()
    private var loadingTask: Task<(any ReaderContentProtocol)?, Error>?
    
    public init() {
        $content
            .sink { [weak self] newContent in
                guard let self else { return }
//                debugPrint("# new content", newContent?.url)
                self.locationBarTitle = newContent?.locationBarTitle
                let newTitle = newContent?.title ?? ""
                self.contentTitle = newTitle
                if !newTitle.isEmpty {
                    self.contentTitleSubject.send(newTitle)
                }
            }
            .store(in: &cancellables)
    }

    @MainActor
    internal func beginMainFrameNavigationTask(to url: URL) -> UUID {
        let token = UUID()
        mainFrameNavigationTasks[token] = url
        mainFrameNavigationTaskOrder.append(token)
        isReaderMainFrameNavigating = true
        mainFrameNavigationURL = url
        debugPrint(
            "# FLASH mainFrameNavigation.begin",
            flashURLDescription(url),
            "active=\(mainFrameNavigationTaskOrder.count)"
        )
        return token
    }

    @MainActor
    internal func endMainFrameNavigationTask(_ token: UUID) {
        guard let url = mainFrameNavigationTasks.removeValue(forKey: token) else { return }
        if let index = mainFrameNavigationTaskOrder.firstIndex(of: token) {
            mainFrameNavigationTaskOrder.remove(at: index)
        }

        let remainingToken = mainFrameNavigationTaskOrder.last
        let remainingURL = remainingToken.flatMap { mainFrameNavigationTasks[$0] }
        mainFrameNavigationURL = remainingURL
        isReaderMainFrameNavigating = !mainFrameNavigationTaskOrder.isEmpty

        debugPrint(
            "# FLASH mainFrameNavigation.end",
            flashURLDescription(url),
            "active=\(mainFrameNavigationTaskOrder.count)"
        )

        if isReaderMainFrameNavigating {
            return
        }
    }
    
    @MainActor
    internal func load(url: URL) async throws {
        debugPrint("# FLASH ReaderContent.load start", "page=\(flashURLDescription(url))")
        if url.isSnippetURL || url.isReaderURLLoaderURL {
            debugPrint("# SNIPPETLOAD readerContent.load.start", "pageURL=\(url.absoluteString)")
        }

        let resolvedContentURL = ReaderContentLoader.getContentURL(fromLoaderURL: url) ?? url
        let displayURL = resolvedContentURL
        if url.isReaderURLLoaderURL {
            debugPrint(
                "# READERRELOAD readerContent.load.loader",
                "pageURL=\(url.absoluteString)",
                "resolved=\(resolvedContentURL.absoluteString)",
                "currentPage=\(pageURL.absoluteString)"
            )
        }
        if resolvedContentURL.isSnippetURL {
            debugPrint(
                "# SNIPPETLOAD readerContent.load.resolvedURL",
                "pageURL=\(url.absoluteString)",
                "resolved=\(resolvedContentURL.absoluteString)"
            )
        }

        let shouldMarkProvisional = resolvedContentURL.isSnippetURL
        if shouldMarkProvisional && !isReaderProvisionallyNavigating {
            isReaderProvisionallyNavigating = true
            debugPrint("# FLASH provisional.mark", "page=\(flashURLDescription(url))", "state=true")
        }

        if let loadingTask, pageURL.matchesReaderURL(url) {
            debugPrint("# FLASH ReaderContent.load in-flight", "page=\(flashURLDescription(url))")
            _ = try await loadingTask.value
            return
        }

        if let existingContent = content, existingContent.url.matchesReaderURL(resolvedContentURL) {
            debugPrint("# FLASH ReaderContent.load reuse existing content", "page=\(flashURLDescription(url))")
            if !pageURL.matchesReaderURL(url) {
                pageURL = displayURL
                debugPrint("# FLASH ReaderContent.load updated pageURL only", "page=\(flashURLDescription(displayURL))")
            }
            if existingContent.url.isSnippetURL {
                debugPrint(
                    "# SNIPPETLOAD readerContent.load.reuse",
                    "pageURL=\(url.absoluteString)",
                    "contentURL=\(existingContent.url.absoluteString)"
                )
            }
            return
        }

        content = nil
        currentSectionIndex = nil
        pageURL = displayURL
        if url.isReaderURLLoaderURL || displayURL.isReaderURLLoaderURL {
            debugPrint(
                "# READERRELOAD readerContent.load.pageURLSet",
                "pageURL=\(displayURL.absoluteString)",
                "incoming=\(url.absoluteString)"
            )
        }

        loadingTask?.cancel()
        loadingTask = Task { @MainActor [weak self] in
            try Task.checkCancellation()
            debugPrint("# FLASH ReaderContent.load task resolving content", "page=\(flashURLDescription(url))")
            let content = try await ReaderViewModel.getContent(forURL: url, countsAsHistoryVisit: true) ?? ReaderContentLoader.unsavedHome
            guard content.url.matchesReaderURL(resolvedContentURL) else {
                debugPrint("Warning: Mismatched URL in ReaderContent.load:", url.absoluteString, content.url)
                debugPrint("# FLASH ReaderContent.load mismatch", "page=\(flashURLDescription(url))", "content=\(flashURLDescription(content.url))")
                if resolvedContentURL.isSnippetURL {
                    debugPrint(
                        "# SNIPPETLOAD readerContent.load.mismatch",
                        "pageURL=\(url.absoluteString)",
                        "resolved=\(resolvedContentURL.absoluteString)",
                        "contentURL=\(content.url.absoluteString)"
                    )
                }
                return nil
            }
            self?.content = content
            let contentSummary = [
                "url=\(content.url.absoluteString)",
                "isSnippet=\(content.url.isSnippetURL)",
                "hasHTML=\(content.hasHTML)",
                "isReaderModeByDefault=\(content.isReaderModeByDefault)",
                "rssContainsFullContent=\(content.rssContainsFullContent)",
                "isFromClipboard=\(content.isFromClipboard)"
            ].joined(separator: " | ")
            debugPrint("# FLASH ReaderContent.load contentAssigned", contentSummary)
            debugPrint("# FLASH ReaderContent.load task set content", "content=\(flashURLDescription(content.url))")
            if content.url.isSnippetURL {
                debugPrint(
                    "# SNIPPETLOAD readerContent.load.contentAssigned",
                    "contentURL=\(content.url.absoluteString)",
                    "hasHTML=\(content.hasHTML)",
                    "rssFull=\(content.rssContainsFullContent)",
                    "clipboard=\(content.isFromClipboard)"
                )
            }
            return content
        }
        try await loadingTask?.value
        debugPrint("# FLASH ReaderContent.load completed", "page=\(flashURLDescription(url))")
        loadingTask = nil

        if shouldMarkProvisional && isReaderProvisionallyNavigating {
            isReaderProvisionallyNavigating = false
            debugPrint("# FLASH provisional.clear", "page=\(flashURLDescription(url))", "state=false")
        }
    }

    @MainActor
    public func getContent() async throws -> (any ReaderContentProtocol)? {
        if let content {
//            debugPrint("# FLASH ReaderContent.getContent cached", content.url)
            return content
        }
        debugPrint("# FLASH ReaderContent.getContent awaiting loadingTask", pageURL)
        return try await loadingTask?.value
    }

    @MainActor
    public func updateContentTitle(_ newTitle: String) async {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let content else { return }
        guard trimmed != content.title else { return }

        contentTitle = trimmed
        contentTitleSubject.send(trimmed)

        do {
            try await content.writeAllRelatedAsync { _, object in
                object.title = trimmed
                object.refreshChangeMetadata(explicitlyModified: true)
            }
        } catch {
            debugPrint("# READER contentTitle.update.failed", error.localizedDescription)
        }
    }
}
