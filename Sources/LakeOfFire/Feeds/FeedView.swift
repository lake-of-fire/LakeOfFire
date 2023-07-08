import SwiftUI
import RealmSwift
import AsyncView

public struct FeedView: View {
    @ObservedRealmObject var feed: Feed
    
    @SceneStorage("feedEntrySelection") private var feedEntrySelection: String?
    
    @ObservedResults(FeedEntry.self, configuration: ReaderContentLoader.feedEntryRealmConfiguration, where: { $0.isDeleted == false }) var entries
    
    public var body: some View {
        let entries = entries.where { $0.feed == feed }
        AsyncView(operation: {
            try await feed.fetch()
        }, showInitialContent: !entries.isEmpty) { _ in
            ReaderContentList(contents: AnyRealmCollection<FeedEntry>(entries), entrySelection: $feedEntrySelection, sortOrder: [KeyPathComparator(\.publicationDate, order: .reverse)])
        }
//        .id(feed.id)
    }
    
    public init(feed: Feed) {
        self.feed = feed
    }
}
