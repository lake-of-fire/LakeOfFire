import SwiftUI
import RealmSwift
import AsyncView

public struct FeedView: View {
    @ObservedRealmObject var feed: Feed
    
    @SceneStorage("feedEntrySelection") private var feedEntrySelection: String?
    
    @ObservedResults(FeedEntry.self, configuration: ReaderContentLoader.feedEntryRealmConfiguration, where: { $0.isDeleted == false }) var allEntries
    
    @State private var entries: Results<FeedEntry>? = nil
    
    public var body: some View {
        AsyncView(operation: {
            try await feed.fetch()
        }, showInitialContent: !(entries?.isEmpty ?? true)) { _ in
            if let entries = entries {
                ReaderContentList(contents: Array(entries), entrySelection: $feedEntrySelection, sortOrder: .publicationDate)
            }
        }
//        .id(feed.id)
        .task {
            Task { @MainActor in
                entries = allEntries.where { $0.feed.id == feed.id }
            }
        }
        .onChange(of: feed) { feed in
            Task { @MainActor in
                entries = allEntries.where { $0.feed.id == feed.id }
            }
        }
    }
    
    public init(feed: Feed) {
        self.feed = feed
    }
}
