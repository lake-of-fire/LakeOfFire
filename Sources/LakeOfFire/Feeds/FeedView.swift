import SwiftUI
import RealmSwift
import RealmSwiftGaps
import AsyncView
import Combine

@MainActor
public class FeedViewModel: ObservableObject {
    @Published var entries: [FeedEntry]? = nil
    
    @RealmBackgroundActor
    private var cancellables = Set<AnyCancellable>()
    private static var lastFetchTimes: [UUID: Date] = [:] // Tracks last fetch time for each feed
    
    public init(feed: Feed) {
        let ref = ThreadSafeReference(to: feed)
        Task { @RealmBackgroundActor in
            let realm = try await Realm(configuration: ReaderContentLoader.feedEntryRealmConfiguration, actor: RealmBackgroundActor.shared)
            guard let feed = realm.resolve(ref) else { return }
            realm.objects(FeedEntry.self)
                .where { $0.feed.id == feed.id }
                .collectionPublisher
                .freeze()
                .removeDuplicates()
                .debounce(for: .seconds(0.1), scheduler: RunLoop.main)
                .sink(receiveCompletion: { _ in}, receiveValue: { [weak self] entries in
                    let undeletedEntries = Array(entries.where { !$0.isDeleted })
                    let refs = undeletedEntries.map { ThreadSafeReference(to: $0) }
                    Task { @MainActor in
                        let realm = try await Realm(configuration: ReaderContentLoader.feedEntryRealmConfiguration, actor: MainActor.shared)
                        self?.entries = refs.compactMap { realm.resolve($0) }
                    }
                })
                .store(in: &cancellables)
        }
    }
    
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
                            sortOrder: .publicationDate)
                    } else {
                        ReaderContentList(
                            contents: entries,
                            entrySelection: $feedEntrySelection,
                            sortOrder: .publicationDate)
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
