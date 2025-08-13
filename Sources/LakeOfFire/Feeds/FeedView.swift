import SwiftUI
import RealmSwift
import RealmSwiftGaps
import AsyncView
import Combine

let feedQueue = DispatchQueue(label: "FeedQueue")

@MainActor
public class FeedViewModel: ObservableObject {
    @Published var entries: [FeedEntry]? = nil
    
    @RealmBackgroundActor
    private var cancellables = Set<AnyCancellable>()
    private static var lastFetchTimes: [UUID: Date] = [:] // Tracks last fetch time for each feed
    
    public init(feed: Feed) {
        let feedID = feed.id
        Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.feedEntryRealmConfiguration) 
            realm.objects(FeedEntry.self)
                .where { $0.feedID == feedID && !$0.isDeleted }
                .collectionPublisher
                .subscribe(on: feedQueue)
                .map { _ in }
                .debounce(for: .seconds(0.3), scheduler: feedQueue)
                .receive(on: feedQueue)
                .sink(receiveCompletion: { _ in}, receiveValue: { [weak self] _ in
                    Task { @MainActor [weak self] in
                        let realm = try await Realm.open(configuration: ReaderContentLoader.feedEntryRealmConfiguration)
                        self?.entries = realm.objects(FeedEntry.self).where { $0.feedID == feedID && !$0.isDeleted } .map { $0 }
                    }
                })
                .store(in: &cancellables)
        }
    }
    
    @MainActor
    public func fetchIfNeeded(feed: Feed, force: Bool) async throws {
        let now = Date()
        let feedID = feed.id
        let lastFetchTime = FeedViewModel.lastFetchTimes[feedID]
        
        if force || lastFetchTime == nil || now.timeIntervalSince(lastFetchTime!) > 30 * 60 {
            try await feed.fetch()
            FeedViewModel.lastFetchTimes[feedID] = now
        }
    }
}

public struct FeedView: View {
    @ObservedRealmObject var feed: Feed
    @ObservedObject var viewModel: FeedViewModel
    var isHorizontal = false
    
    @SceneStorage("feedEntrySelection") private var feedEntrySelection: String?
    
    public var body: some View {
        AsyncView(operation: { forceRefreshRequested in
            try await viewModel.fetchIfNeeded(feed: feed, force: forceRefreshRequested)
        }, showInitialContent: !(viewModel.entries?.isEmpty ?? true)) { _ in
            if let entries = viewModel.entries {
                Group {
                    if isHorizontal {
                        ReaderContentHorizontalList(
                            contents: entries,
                            sortOrder: .publicationDate,
                            includeSource: false
                        )
                    } else {
                        ReaderContentList(
                            contents: entries,
                            entrySelection: $feedEntrySelection,
                            sortOrder: .publicationDate
                        )
                    }
                }
            }
        }
    }
    
    public init(feed: Feed, viewModel: FeedViewModel, isHorizontal: Bool = false) {
        self.feed = feed
        self.viewModel = viewModel
        self.isHorizontal = isHorizontal
    }
}
