import SwiftUI
import Foundation
import RealmSwift
import RealmSwiftGaps
import AsyncView
import LakeKit
import Combine
import SwiftUtilities

let feedQueue = DispatchQueue(label: "FeedQueue")

@MainActor
public class FeedViewModel: ObservableObject {
    @Published var entries: [FeedEntry]? = nil {
        didSet {
            let countDescription = entries.map { "\($0.count)" } ?? "nil"
            debugPrint("# FeedViewModel.entries updated feedID=\(feedID.uuidString) title=\(feedTitle) count=\(countDescription)")
        }
    }
    
    @RealmBackgroundActor
    private var cancellables = Set<AnyCancellable>()
    private static var lastFetchTimes: [UUID: Date] = [:] // Tracks last fetch time for each feed
    private let feedID: UUID
    private let feedTitle: String
    
    public init(feed: Feed) {
        self.feedID = feed.id
        self.feedTitle = feed.title
        let feedID = feed.id
        debugPrint("# FeedViewModel.init feedID=\(feedID.uuidString) title=\(feedTitle)")
        Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.feedEntryRealmConfiguration) 
            realm.objects(FeedEntry.self)
                .where { $0.feedID == feedID && !$0.isDeleted }
                .collectionPublisher
                .subscribe(on: feedQueue)
                .map { _ in }
                .debounceLeadingTrailing(for: .seconds(0.3), scheduler: feedQueue)
                .receive(on: feedQueue)
                .sink(receiveCompletion: { _ in}, receiveValue: { [weak self] _ in
                    debugPrint("# FeedViewModel.subscriptionTriggered feedID=\(feedID.uuidString)")
                    Task { @MainActor [weak self] in
                        let realm = try await Realm.open(configuration: ReaderContentLoader.feedEntryRealmConfiguration)
                        debugPrint("# FeedViewModel.reloadEntries feedID=\(feedID.uuidString)")
                        self?.entries = realm.objects(FeedEntry.self).where { $0.feedID == feedID && !$0.isDeleted } .map { $0 }
                        debugPrint("# FeedViewModel.reloadEntriesFinished feedID=\(feedID.uuidString) count=\(self?.entries?.count ?? 0)")
                    }
                })
                .store(in: &cancellables)
        }
    }
    
    @MainActor
    public func fetchIfNeeded(feed: Feed, force: Bool) async throws {
        let now = Date()
        let feedID = self.feedID
        let lastFetchTime = FeedViewModel.lastFetchTimes[feedID]
        let isoFormatter = ISO8601DateFormatter()
        let lastFetchDescription = lastFetchTime.map { isoFormatter.string(from: $0) } ?? "never"
        
        if force || lastFetchTime == nil || now.timeIntervalSince(lastFetchTime!) > 30 * 60 {
            do {
                try await feed.fetch()
                FeedViewModel.lastFetchTimes[feedID] = now
            } catch {
                throw error
            }
        } else {
        }
    }
}

public struct FeedView: View {
    @ObservedRealmObject var feed: Feed
    @ObservedObject var viewModel: FeedViewModel
    var isHorizontal = false

    @Environment(\.contentSelection) private var contentSelection

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
                            includeSource: false,
                            contentSelection: contentSelection
                        ) {
                            EmptyView()
                        }
                    } else {
                        ReaderContentList(
                            contents: entries,
                            sortOrder: .publicationDate,
                            includeSource: false,
                            entrySelection: contentSelection
                        ) {
                        } emptyStateView: {
                            EmptyStateBoxView(
                                title: Text("No Entries Available"),
                                text: Text("This feed is empty. Try refreshing or checking back later."),
                                systemImageName: "newspaper.fill"
                            )
                        }
#if os(iOS)
                        .listStyle(.insetGrouped)
#endif
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
