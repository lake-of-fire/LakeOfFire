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

private func logRSS(_ message: String) {
#if DEBUG
    debugPrint("# RSS \(message)")
#endif
}

private func sortFeedEntryCollections(_ collections: [FeedEntryCollection]) -> [FeedEntryCollection] {
    collections.sorted { lhs, rhs in
        switch (lhs.order, rhs.order) {
        case let (left?, right?) where left != right:
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            if lhs.publicationDate != rhs.publicationDate {
                return (lhs.publicationDate ?? .distantPast) > (rhs.publicationDate ?? .distantPast)
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}

@MainActor
public class FeedViewModel: ObservableObject {
    @Published var entries: [FeedEntry]? = nil {
        didSet {
            let countDescription = entries.map { "\($0.count)" } ?? "nil"
            debugPrint("# FeedViewModel.entries updated feedID=\(feedID.uuidString) title=\(feedTitle) count=\(countDescription)")
        }
    }
    @Published var isFeedGroupFollowed = false
    @Published var collections: [FeedEntryCollection]? = nil
    
    @RealmBackgroundActor
    private var cancellables = Set<AnyCancellable>()
    private let feedID: UUID
    private let feedTitle: String
    private let canonicalFeedURLKey: String

    @MainActor
    private func reloadEntries(feedID: UUID, reason: String) async {
        do {
            let realm = try await Realm.open(configuration: ReaderContentLoader.feedEntryRealmConfiguration)
            let entries = Array(
                realm.objects(FeedEntry.self)
                    .where { $0.feedID == feedID && !$0.isDeleted }
            )
            logRSS("stage=feedView.reloadEntries feedID=\(feedID.uuidString) reason=\(reason) count=\(entries.count)")
            self.entries = entries
        } catch {
            logRSS("stage=feedView.reloadEntries.error feedID=\(feedID.uuidString) reason=\(reason) error=\(error)")
        }
    }

    @MainActor
    private func reloadCollections(feedID: UUID, reason: String) async {
        do {
            let realm = try await Realm.open(configuration: ReaderContentLoader.feedEntryRealmConfiguration)
            collections = sortFeedEntryCollections(Array(
                realm.objects(FeedEntryCollection.self)
                    .where { $0.feedID == feedID && !$0.isDeleted }
            ))
            logRSS("stage=feedView.reloadCollections feedID=\(feedID.uuidString) reason=\(reason) count=\(collections?.count ?? 0)")
        } catch {
            logRSS("stage=feedView.reloadCollections.error feedID=\(feedID.uuidString) reason=\(reason) error=\(error)")
        }
    }

    @MainActor
    private func reloadFollowedStatus(reason: String) async {
        do {
            let realm = try await Realm.open(configuration: ReaderContentLoader.feedEntryRealmConfiguration)
            isFeedGroupFollowed = realm.objects(Feed.self)
                .where { !$0.isDeleted }
                .filter { $0.canonicalFollowingFeedURLKey == self.canonicalFeedURLKey }
                .contains(where: \.isFollowed)
            logRSS("stage=feedView.reloadFollowedStatus feedURLKey=\(canonicalFeedURLKey) reason=\(reason) isFollowed=\(isFeedGroupFollowed)")
        } catch {
            logRSS("stage=feedView.reloadFollowedStatus.error feedURLKey=\(canonicalFeedURLKey) reason=\(reason) error=\(error)")
        }
    }
    
    public init(feed: Feed) {
        self.feedID = feed.id
        self.feedTitle = feed.title
        self.canonicalFeedURLKey = feed.canonicalFollowingFeedURLKey
        self.isFeedGroupFollowed = feed.isFollowed
        self.collections = feed.getCollections()
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
                        self?.entries = Array(realm.objects(FeedEntry.self).where { $0.feedID == feedID && !$0.isDeleted })
                        debugPrint("# FeedViewModel.reloadEntriesFinished feedID=\(feedID.uuidString) count=\(self?.entries?.count ?? 0)")
                    }
                })
                .store(in: &cancellables)

            realm.objects(FeedEntryCollection.self)
                .where { $0.feedID == feedID && !$0.isDeleted }
                .collectionPublisher
                .subscribe(on: feedQueue)
                .map { _ in }
                .debounce(for: .seconds(0.3), scheduler: feedQueue)
                .receive(on: feedQueue)
                .sink(receiveCompletion: { _ in}, receiveValue: { [weak self] _ in
                    Task { @MainActor [weak self] in
                        await self?.reloadCollections(feedID: feedID, reason: "collectionsChanged")
                    }
                })
                .store(in: &cancellables)

            realm.objects(Feed.self)
                .where { !$0.isDeleted }
                .collectionPublisher
                .subscribe(on: feedQueue)
                .map { _ in }
                .debounce(for: .seconds(0.3), scheduler: feedQueue)
                .receive(on: feedQueue)
                .sink(receiveCompletion: { _ in}, receiveValue: { [weak self] _ in
                    Task { @MainActor [weak self] in
                        await self?.reloadFollowedStatus(reason: "feedsChanged")
                    }
                })
                .store(in: &cancellables)
        }
        Task { @MainActor [weak self] in
            await self?.reloadFollowedStatus(reason: "init")
            await self?.reloadCollections(feedID: feedID, reason: "init")
        }
    }
    
    @MainActor
    public func fetchIfNeeded(feed: Feed, force: Bool) async throws {
        let shouldRefresh = feed.shouldRefreshAutomaticallyOnFeedAppear
        logRSS(
            "stage=feedView.fetchDecision feedID=\(feed.id.uuidString) title=\(feed.title) url=\(feed.rssUrl.absoluteString) force=\(force) shouldRefreshOnAppear=\(shouldRefresh) lastRefresh=\(feed.lastRefreshedEntriesAt?.description ?? "nil") hasRecentlyRefreshed=\(feed.hasRecentlyRefreshedEntries)"
        )
        if force || shouldRefresh {
            do {
                try await feed.fetch()
                await reloadEntries(feedID: feed.id, reason: force ? "forceFetchComplete" : "autoFetchComplete")
                logRSS("stage=feedView.fetchFinished feedID=\(feed.id.uuidString) title=\(feed.title)")
            } catch {
                logRSS("stage=feedView.fetchError feedID=\(feed.id.uuidString) title=\(feed.title) error=\(error)")
                throw error
            }
        } else {
            logRSS("stage=feedView.fetchSkipped feedID=\(feed.id.uuidString) title=\(feed.title) reason=recentlyRefreshed")
        }
    }
}

public struct FeedView: View {
    @ObservedRealmObject var feed: Feed
    @ObservedObject var viewModel: FeedViewModel
    var isHorizontal = false
    var showsToolbar = true
    var initialScrollEntryID: String?
    @State private var showsReaderContentNewBadges = true

    @Environment(\.contentSelection) private var contentSelection

    private var entries: [FeedEntry] {
        viewModel.entries ?? []
    }

    private var showsMarkAllAsSeenAction: Bool {
        feed.showsUnseenBadge && !entries.isEmpty
    }

    public var body: some View {
        let isFeedGroupFollowed = viewModel.isFeedGroupFollowed
        let allowsFollowing = feed.entryContentKind != .contentListing
        AsyncView(operation: { forceRefreshRequested in
            try await viewModel.fetchIfNeeded(feed: feed, force: forceRefreshRequested)
        }, showInitialContent: !(viewModel.entries?.isEmpty ?? true)) { _ in
            if let entries = viewModel.entries {
                let entryIDs = entries.map(\.compoundKey)
                let collections = viewModel.collections ?? []
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
                        .id("feed-horizontal-\(feed.id.uuidString)")
                        .animation(.easeInOut(duration: 0.25), value: entryIDs)
                    } else {
                        ReaderContentList(
                            contents: entries,
                            sortOrder: .publicationDate,
                            includeSource: false,
                            entrySelection: contentSelection,
                            useDefaultRowInsets: true,
                            showsNewBadges: showsReaderContentNewBadges,
                            separateRowsIntoSections: true,
                            listSectionSpacing: 10,
                            scrollTargetID: initialScrollEntryID
                        ) {
                            if !collections.isEmpty {
                                Section {
                                    ForEach(collections) { collection in
                                        NavigationLink {
                                            FeedEntryCollectionView(
                                                collection: collection,
                                                viewModel: viewModel
                                            )
                                        } label: {
                                            FeedEntryCollectionCell(collection: collection)
                                        }
                                    }
                                } header: {
                                    Text("Collections")
                                }
                            }
                        } headerView: {
                            EmptyView()
                        } emptyStateView: {
                            EmptyStateBoxView(
                                title: Text("No Entries Available"),
                                text: Text("This feed is empty. Try refreshing or checking back later."),
                                systemImageName: "newspaper.fill"
                            )
                        }
                        .id("feed-vertical-\(feed.id.uuidString)")
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
            ToolbarItem(placement: .automatic) {
                if showsToolbar {
                    Menu {
                        if allowsFollowing {
                            Section {
                                Button {
                                    Task { @MainActor in
                                        try? await setFollowed(!isFeedGroupFollowed)
                                    }
                                } label: {
                                    Label(isFeedGroupFollowed ? "Following" : "Follow", systemImage: isFeedGroupFollowed ? "checkmark" : "plus")
                                }
                            }
                        }
                        if showsMarkAllAsSeenAction {
                            Button("Mark All as Seen") {
                                Task { @MainActor in
                                    try? await markAllEntriesAsSeen()
                                }
                            }
                        }
                        Toggle(isOn: $showsReaderContentNewBadges) {
                            Text("Show New Badge")
                        }
                    } label: {
                        Label("More Options", systemImage: "ellipsis")
                            .labelStyle(.iconOnly)
                    }
                }
            }
        }
    }
    
    public init(feed: Feed, viewModel: FeedViewModel, isHorizontal: Bool = false, showsToolbar: Bool = true, initialScrollEntryID: String? = nil) {
        self.feed = feed
        self.viewModel = viewModel
        self.isHorizontal = isHorizontal
        self.showsToolbar = showsToolbar
        self.initialScrollEntryID = initialScrollEntryID
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
        guard feed.showsUnseenBadge, !entries.isEmpty else { return }
        try await Realm.asyncWrite(
            ThreadSafeReference(to: feed),
            configuration: ReaderContentLoader.feedEntryRealmConfiguration
        ) { _, feed in
            feed.lastSeenFeedEntriesAt = Date()
        }
    }

    @MainActor
    private func setFollowed(_ isFollowed: Bool) async throws {
        guard feed.entryContentKind != .contentListing else { return }
        let canonicalFeedURLKey = feed.canonicalFollowingFeedURLKey
        try await Realm.asyncWrite(configuration: ReaderContentLoader.feedEntryRealmConfiguration) { realm in
            Feed.setFollowingStatusForFeedGroup(
                canonicalFeedURLKey: canonicalFeedURLKey,
                isFollowed: isFollowed,
                in: realm
            )
        }
    }
}

private struct FeedEntryCollectionCell: View {
    @ObservedRealmObject var collection: FeedEntryCollection

    var body: some View {
        HStack(spacing: 12) {
            if let imageUrl = collection.imageUrl {
                AsyncImage(url: imageUrl) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        Rectangle()
                            .fill(Color.secondary.opacity(0.18))
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(collection.title)
                    .font(.headline)
                    .lineLimit(2)
                if let metadataText {
                    Text(metadataText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var metadataText: String? {
        if let publicationDate = collection.publicationDate {
            return publicationDate.formatted(date: .abbreviated, time: .omitted)
        }
        return collection.summary
    }
}

private struct FeedEntryCollectionHeader: View {
    @ObservedRealmObject var collection: FeedEntryCollection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let imageUrl = collection.imageUrl {
                AsyncImage(url: imageUrl) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        Rectangle()
                            .fill(Color.secondary.opacity(0.18))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(collection.title)
                    .font(.title3.weight(.semibold))
                if let publicationDate = collection.publicationDate {
                    Text(publicationDate.formatted(date: .abbreviated, time: .omitted))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let summary = collection.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
    }
}

private struct FeedEntryCollectionView: View {
    @ObservedRealmObject var collection: FeedEntryCollection
    @ObservedObject var viewModel: FeedViewModel
    @Environment(\.contentSelection) private var contentSelection
    @State private var showsReaderContentNewBadges = true

    private var entries: [FeedEntry] {
        (viewModel.entries ?? []).filter { $0.feedEntryCollectionKey == collection.compoundKey }
    }

    var body: some View {
        ReaderContentList(
            contents: entries,
            sortOrder: .publicationDate,
            includeSource: false,
            entrySelection: contentSelection,
            useDefaultRowInsets: true,
            showsNewBadges: showsReaderContentNewBadges,
            separateRowsIntoSections: true,
            supplementarySections: {
                EmptyView()
            },
            headerView: {
                FeedEntryCollectionHeader(collection: collection)
            },
            emptyStateView: {
                EmptyStateBoxView(
                    title: Text("No Entries Available"),
                    text: Text("This collection is empty. Try refreshing or checking back later."),
                    systemImageName: "newspaper.fill"
                )
            }
        )
        .navigationTitle(collection.title)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
#endif
        .toolbar {
            ToolbarItem(placement: toolbarTrailingPlacement) {
                Menu {
                    Toggle(isOn: $showsReaderContentNewBadges) {
                        Text("Show New Badge")
                    }
                } label: {
                    Label("More Options", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
            }
        }
    }

    private var toolbarTrailingPlacement: ToolbarItemPlacement {
#if os(macOS)
        .automatic
#else
        .navigationBarTrailing
#endif
    }
}
