import SwiftUI
import Combine

@MainActor
public class ReaderContent: ObservableObject {
    @Published public var content: (any ReaderContentProtocol)?// = ReaderContentLoader.unsavedHome
    @Published public var pageURL = URL(string: "about:blank")!
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
        content = nil
        pageURL = url
        
        loadingTask?.cancel()
        loadingTask = Task { @MainActor [weak self] in
            try Task.checkCancellation()
            let content = try await ReaderViewModel.getContent(forURL: url, countsAsHistoryVisit: true) ?? ReaderContentLoader.unsavedHome
            guard content.url.matchesReaderURL(url) else {
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
