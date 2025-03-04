import SwiftUI

public class ReaderContent: ObservableObject {
    @Published public var content: (any ReaderContentProtocol)?// = ReaderContentLoader.unsavedHome
    @Published public var pageURL = URL(string: "about:blank")! {
        didSet {
            debugPrint("# readerContent pageURL didSet", pageURL)
        }
    }
    @Published public var isReaderProvisionallyNavigating = false
    
    private var loadingTask: Task<(any ReaderContentProtocol)?, Error>?

    public init() {
    }
    
    @MainActor
    internal func load(url: URL) async throws {
        content = nil
        pageURL = url
        
        loadingTask?.cancel()
        loadingTask = Task { @MainActor [weak self] in
            debugPrint("# readerContent.load(...)", url)
            try Task.checkCancellation()
            let content = try await ReaderViewModel.getContent(forURL: url, countsAsHistoryVisit: true) ?? ReaderContentLoader.unsavedHome
            guard content.url.matchesReaderURL(url) else { return nil }
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
