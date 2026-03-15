import SwiftUI

@MainActor
public class ReaderContent: ObservableObject {
    @Published public var content: (any ReaderContentProtocol)?// = ReaderContentLoader.unsavedHome
    @Published public var pageURL = URL(string: "about:blank")!
    @Published public var isReaderProvisionallyNavigating = false
    @Published public var isRenderingReaderHTML = false
    
    private var loadingTask: Task<(any ReaderContentProtocol)?, Error>?

    public init() {
    }
    
    @MainActor
    internal func load(url: URL) async throws {
        let resolvedContentURL = ReaderContentLoader.getContentURL(fromLoaderURL: url) ?? url
        let displayURL = resolvedContentURL

        if url.absoluteString == "about:blank" {
            if let existingContent = content, !existingContent.url.isNativeReaderView {
                pageURL = existingContent.url
                isRenderingReaderHTML = false
                return
            }
            if let loadingTask {
                if let inFlightContent = try await loadingTask.value, !inFlightContent.url.isNativeReaderView {
                    content = inFlightContent
                    pageURL = inFlightContent.url
                    isRenderingReaderHTML = false
                    return
                }
            }
        }

        if let loadingTask, pageURL.matchesReaderURL(url) {
            _ = try await loadingTask.value
            return
        }

        if let existingContent = content, existingContent.url.matchesReaderURL(resolvedContentURL) {
            if !pageURL.matchesReaderURL(url) {
                pageURL = displayURL
            }
            return
        }

        content = nil
        pageURL = displayURL
        
        loadingTask?.cancel()
        loadingTask = Task { @MainActor [weak self] in
            try Task.checkCancellation()
            let content = try await ReaderViewModel.getContent(forURL: url, countsAsHistoryVisit: true) ?? ReaderContentLoader.unsavedHome
            guard content.url.matchesReaderURL(resolvedContentURL) else {
                debugPrint("Warning: Mismatched URL in ReaderContent.load:", url.absoluteString, content.url)
                return nil
            }
            self?.content = content
            return content
        }
        try await loadingTask?.value
        loadingTask = nil
    }
    
    @MainActor
    public func getContent() async throws -> (any ReaderContentProtocol)? {
        if let content {
            return content
        }
        return try await loadingTask?.value
    }
}
