import SwiftUI
import Foundation
import RealmSwift
import RealmSwiftGaps
import AsyncView
import LakeKit
import Combine
import SwiftUtilities
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent
import LakeOfFireContentUI

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
                .debounce(for: .seconds(0.3), scheduler: feedQueue)
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
        if force || feed.shouldRefreshAutomaticallyOnFeedAppear {
            do {
                try await feed.fetch()
            } catch {
                throw error
            }
        }
    }
}

public struct FeedView: View {
    @ObservedRealmObject var feed: Feed
    @ObservedObject var viewModel: FeedViewModel
    var isHorizontal = false
    var showsToolbar = true

    @Environment(\.contentSelection) private var contentSelection

    private var entries: [FeedEntry] {
        viewModel.entries ?? []
    }

    private var showsMarkAllAsSeenAction: Bool {
        feed.hasUnseenEntries(entries)
    }

    private var showUnseenBadgeBinding: Binding<Bool> {
        Binding(
            get: { feed.showsUnseenBadge },
            set: { newValue in
                Task { @MainActor in
                    try? await setShowsUnseenBadge(newValue)
                }
            }
        )
    }

    public var body: some View {
        AsyncView(operation: { forceRefreshRequested in
            try await viewModel.fetchIfNeeded(feed: feed, force: forceRefreshRequested)
        }, showInitialContent: !(viewModel.entries?.isEmpty ?? true)) { _ in
            if let entries = viewModel.entries {
                let entryIDs = entries.map(\.compoundKey)
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
                        .animation(.easeInOut(duration: 0.25), value: entryIDs)
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
                        .animation(.easeInOut(duration: 0.25), value: entryIDs)
#if os(iOS)
                        .listStyle(.insetGrouped)
#endif
                    }
                }
            }
        }
        .task(id: feed.id) {
            try? await markFeedAsViewed()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if showsToolbar {
                    Menu {
                        if showsMarkAllAsSeenAction {
                            Button("Mark All as Seen") {
                                Task { @MainActor in
                                    try? await markAllEntriesAsSeen()
                                }
                            }
                        }
                        Toggle(isOn: showUnseenBadgeBinding) {
                            Text("Show Unseen Badge")
                        }
                    } label: {
                        Label("More Options", systemImage: "ellipsis")
                            .labelStyle(.iconOnly)
                    }
                }
            }
        }
    }
    
    public init(feed: Feed, viewModel: FeedViewModel, isHorizontal: Bool = false, showsToolbar: Bool = true) {
        self.feed = feed
        self.viewModel = viewModel
        self.isHorizontal = isHorizontal
        self.showsToolbar = showsToolbar
    }

    @MainActor
    private func markFeedAsViewed() async throws {
        guard feed.shouldMarkAsViewedOnAppear else { return }
        try await Realm.asyncWrite(
            ThreadSafeReference(to: feed),
            configuration: ReaderContentLoader.feedEntryRealmConfiguration
        ) { _, feed in
            feed.lastViewedAt = Date()
        }
    }

    @MainActor
    private func markAllEntriesAsSeen() async throws {
        guard feed.hasUnseenEntries(entries) else { return }
        try await Realm.asyncWrite(
            ThreadSafeReference(to: feed),
            configuration: ReaderContentLoader.feedEntryRealmConfiguration
        ) { _, feed in
            feed.lastSeenFeedEntriesAt = Date()
        }
    }

    @MainActor
    private func setShowsUnseenBadge(_ showsUnseenBadge: Bool) async throws {
        guard feed.showsUnseenBadge != showsUnseenBadge else { return }
        try await Realm.asyncWrite(
            ThreadSafeReference(to: feed),
            configuration: ReaderContentLoader.feedEntryRealmConfiguration
        ) { _, feed in
            feed.showsUnseenBadge = showsUnseenBadge
        }
    }
}
