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
    @Published public var locationBarTitle: String?
    @Published public var isReaderProvisionallyNavigating = false
    private var cancellables = Set<AnyCancellable>()
    private var loadingTask: Task<(any ReaderContentProtocol)?, Error>?
    
    public init() {
        $content
            .sink { [weak self] newContent in
                guard let self else { return }
//                debugPrint("# new content", newContent?.url)
                self.locationBarTitle = newContent?.locationBarTitle
            }
            .store(in: &cancellables)
    }
    
    @MainActor
    internal func load(url: URL) async throws {
        debugPrint("# FLASH ReaderContent.load start", url)

        let resolvedContentURL = ReaderContentLoader.getContentURL(fromLoaderURL: url) ?? url

        if let loadingTask, pageURL.matchesReaderURL(url) {
            debugPrint("# FLASH ReaderContent.load in-flight", url)
            _ = try await loadingTask.value
            return
        }

        if let existingContent = content, existingContent.url.matchesReaderURL(resolvedContentURL) {
            debugPrint("# FLASH ReaderContent.load reuse existing content", url)
            if !pageURL.matchesReaderURL(url) {
                pageURL = url
                debugPrint("# FLASH ReaderContent.load updated pageURL only", url)
            }
            return
        }

        content = nil
        pageURL = url

        loadingTask?.cancel()
        loadingTask = Task { @MainActor [weak self] in
            try Task.checkCancellation()
            debugPrint("# FLASH ReaderContent.load task resolving content", url)
            let content = try await ReaderViewModel.getContent(forURL: url, countsAsHistoryVisit: true) ?? ReaderContentLoader.unsavedHome
            guard content.url.matchesReaderURL(resolvedContentURL) else {
                debugPrint("Warning: Mismatched URL in ReaderContent.load:", url.absoluteString, content.url)
                debugPrint("# FLASH ReaderContent.load mismatch", url, content.url)
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
            debugPrint("# FLASH ReaderContent.load task set content", content.url)
            return content
        }
        try await loadingTask?.value
        debugPrint("# FLASH ReaderContent.load completed", url)
        loadingTask = nil
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
}
