import SwiftUI

public class ReaderContent: ObservableObject {
    @Published public var content: (any ReaderContentProtocol) = ReaderContentLoader.unsavedHome
    @Published public var pageURL = URL(string: "about:blank")!
    @Published public var isReaderProvisionallyNavigating = false
    
    public init() {
    }
    
    @MainActor
    internal func load(url: URL) async throws {
        content = try await ReaderViewModel.getContent(forURL: url) ?? ReaderContentLoader.unsavedHome
        pageURL = url
    }
}
