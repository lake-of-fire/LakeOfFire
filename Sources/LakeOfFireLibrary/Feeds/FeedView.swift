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
    private let source: FeedViewProjectionSource?
    private let feedID: UUID
    private let feedTitle: String
    private let canonicalFeedURLKey: String
    private var reloadIDs: [FeedViewProjectionKind: UUID] = [:]
    private let beforeRead: (@MainActor @Sendable (FeedViewProjectionKind) async throws -> Void)?
    private let beforePublication: (@MainActor @Sendable (FeedViewProjectionKind) async throws -> Void)?
    private let observerDidRefresh: (@MainActor @Sendable (FeedViewProjectionKind) -> Void)?
    private let fetchFeed: @MainActor @Sendable (Feed, Realm.Configuration) async throws -> Void

    private func readProjection<Value>(
        _ kind: FeedViewProjectionKind,
        reason: String,
        read: (Realm) -> Value,
        publish: (Value) -> Void
    ) async {
        guard !Task.isCancelled, let source else { return }
        let reloadID = UUID()
        reloadIDs[kind] = reloadID
        do {
            let request = try source.request()
            try await beforeRead?(kind)
            let (realm, original) = try await request.openOnMainActor()
            guard !Task.isCancelled, reloadIDs[kind] == reloadID else { return }
            guard request.owner.contains(original, in: realm) else {
                throw FeedViewProjectionFailure.retiredSource
            }
            let value = read(realm)
            try await beforePublication?(kind)
            guard !Task.isCancelled, reloadIDs[kind] == reloadID else { return }
            guard request.owner.contains(original, in: realm) else {
                throw FeedViewProjectionFailure.retiredSource
            }
            publish(value)
        } catch is CancellationError {
            // Cancellation of one request does not clear a newer projection.
        } catch FeedViewProjectionFailure.retiredSource {
            guard !Task.isCancelled, reloadIDs[kind] == reloadID else { return }
            reloadIDs.removeAll()
            entries = nil
            collections = nil
            isFeedGroupFollowed = false
        } catch {
            // Keep the previous valid projection on an ordinary open/read error.
            // Later observer delivery or an explicit refresh retries this path.
            logRSS("stage=feedView.reload.error feedID=\(feedID.uuidString) reason=\(reason) error=\(error)")
        }
    }

    private func reloadEntries(feedID: UUID, reason: String) async {
        await readProjection(.entries, reason: reason) { realm in
            let feedIDs = Feed.activeFeedGroupIDs(
                canonicalFeedURLKey: canonicalFeedURLKey,
                in: realm,
                fallback: feedID
            )
            return Array(realm.objects(FeedEntry.self)
                .where { $0.feedID.in(feedIDs) && !$0.isDeleted })
        } publish: { entries in
            self.entries = entries
        }
    }

    private func reloadCollections(feedID: UUID, reason: String) async {
        await readProjection(.collections, reason: reason) { realm in
            let feedIDs = Feed.activeFeedGroupIDs(
                canonicalFeedURLKey: canonicalFeedURLKey,
                in: realm,
                fallback: feedID
            )
            return sortFeedEntryCollections(Array(realm.objects(FeedEntryCollection.self)
                .where { $0.feedID.in(feedIDs) && !$0.isDeleted }))
        } publish: { collections in
            self.collections = collections
        }
    }

    private func reloadFollowedStatus(reason: String) async {
        await readProjection(.followedStatus, reason: reason) { realm in
            realm.objects(Feed.self)
                .where { !$0.isDeleted }
                .filter { $0.canonicalFollowingFeedURLKey == self.canonicalFeedURLKey }
                .contains(where: \.isFollowed)
        } publish: { isFollowed in
            isFeedGroupFollowed = isFollowed
        }
    }

    // The initializer and real feed observers use this same refresh boundary.
    // It is internal so focused fixtures can await actual Realm-backed delivery.
    func refreshProjection(reason: String = "refresh") async {
        await reloadFollowedStatus(reason: reason)
        await reloadEntries(feedID: feedID, reason: reason)
        await reloadCollections(feedID: feedID, reason: reason)
    }

    public convenience init(feed: Feed) {
        self.init(feed: feed, observesRealm: true)
    }

    init(
        feed: Feed,
        observesRealm: Bool,
        beforeRead: (@MainActor @Sendable (FeedViewProjectionKind) async throws -> Void)? = nil,
        beforePublication: (@MainActor @Sendable (FeedViewProjectionKind) async throws -> Void)? = nil,
        beforeObserverOpen: (@RealmBackgroundActor @Sendable () async throws -> Void)? = nil,
        observerDidRefresh: (@MainActor @Sendable (FeedViewProjectionKind) -> Void)? = nil,
        fetchFeed: @escaping @MainActor @Sendable (Feed, Realm.Configuration) async throws -> Void = {
            try await $0.fetch(realmConfiguration: $1)
        }
    ) {
        let source = FeedViewProjectionSource(feed: feed)
        self.source = source
        feedID = source?.owner.feedID ?? UUID()
        feedTitle = source?.title ?? ""
        canonicalFeedURLKey = source?.owner.canonicalURLKey ?? ""
        self.beforeRead = beforeRead
        self.beforePublication = beforePublication
        self.observerDidRefresh = observerDidRefresh
        self.fetchFeed = fetchFeed
        guard let source else { return }
        // Preserve the original caller's live MainActor collection values.
        isFeedGroupFollowed = feed.isFollowed
        collections = feed.getCollections()
        guard observesRealm else { return }

        let feedID = feedID
        let canonicalFeedURLKey = canonicalFeedURLKey
        guard let observerRequest = try? source.request() else { return }
        debugPrint("# FeedViewModel.init feedID=\(feedID.uuidString) title=\(feedTitle)")
        Task { @RealmBackgroundActor [weak self] in
            do {
                try await beforeObserverOpen?()
                let (realm, original) = try await observerRequest.openOnRealmActor()
                guard !Task.isCancelled, observerRequest.owner.contains(original, in: realm),
                      let self else { return }
                let feedIDs = Feed.activeFeedGroupIDs(
                    canonicalFeedURLKey: canonicalFeedURLKey,
                    in: realm,
                    fallback: feedID
                )
                realm.objects(FeedEntry.self)
                    .where { $0.feedID.in(feedIDs) && !$0.isDeleted }
                    .collectionPublisher
                    .subscribe(on: feedQueue)
                    .map { @Sendable _ in }
                    .debounce(for: .seconds(0.3), scheduler: feedQueue)
                    .receive(on: feedQueue)
                    .sink(receiveCompletion: { @Sendable _ in }, receiveValue: { @Sendable [weak self] _ in
                        Task { @MainActor [weak self] in
                            await self?.reloadEntries(feedID: feedID, reason: "entriesChanged")
                            self?.observerDidRefresh?(.entries)
                        }
                    })
                    .store(in: &cancellables)

                realm.objects(FeedEntryCollection.self)
                    .where { $0.feedID.in(feedIDs) && !$0.isDeleted }
                    .collectionPublisher
                    .subscribe(on: feedQueue)
                    .map { @Sendable _ in }
                    .debounce(for: .seconds(0.3), scheduler: feedQueue)
                    .receive(on: feedQueue)
                    .sink(receiveCompletion: { @Sendable _ in }, receiveValue: { @Sendable [weak self] _ in
                        Task { @MainActor [weak self] in
                            await self?.reloadCollections(feedID: feedID, reason: "collectionsChanged")
                            self?.observerDidRefresh?(.collections)
                        }
                    })
                    .store(in: &cancellables)

                realm.objects(Feed.self)
                    .where { !$0.isDeleted }
                    .collectionPublisher
                    .subscribe(on: feedQueue)
                    .map { @Sendable _ in }
                    .debounce(for: .seconds(0.3), scheduler: feedQueue)
                    .receive(on: feedQueue)
                    .sink(receiveCompletion: { @Sendable _ in }, receiveValue: { @Sendable [weak self] _ in
                        Task { @MainActor [weak self] in
                            await self?.refreshProjection(reason: "feedsChanged")
                            self?.observerDidRefresh?(.followedStatus)
                        }
                    })
                    .store(in: &cancellables)
            } catch {
                logRSS("stage=feedView.observer.error feedID=\(feedID.uuidString) error=\(error)")
            }
        }
        Task { @MainActor [weak self] in
            await self?.refreshProjection(reason: "init")
        }
    }

    public func fetchIfNeeded(feed: Feed, force: Bool) async throws {
        try Task.checkCancellation()
        guard let source, source.matchesPresentedFeed(feed) else { throw CancellationError() }
        let request = try source.request()
        let (realm, original) = try await request.openOnMainActor()
        guard request.owner.contains(original, in: realm) else { throw CancellationError() }
        let shouldRefresh = original.shouldRefreshAutomaticallyOnFeedAppear
        let title = original.title
        let url = original.rssUrl
        logRSS(
            "stage=feedView.fetchDecision feedID=\(feedID.uuidString) title=\(title) url=\(url.absoluteString) force=\(force) shouldRefreshOnAppear=\(shouldRefresh) lastRefresh=\(original.lastRefreshedEntriesAt?.description ?? "nil") hasRecentlyRefreshed=\(original.hasRecentlyRefreshedEntries)"
        )
        if force || shouldRefresh {
            do {
                try await fetchFeed(original, request.owner.configuration)
                try Task.checkCancellation()
                guard request.owner.contains(original, in: realm) else { throw CancellationError() }
                await reloadEntries(feedID: feedID, reason: force ? "forceFetchComplete" : "autoFetchComplete")
                try Task.checkCancellation()
                guard request.owner.contains(original, in: realm) else { throw CancellationError() }
                logRSS("stage=feedView.fetchFinished feedID=\(feedID.uuidString) title=\(title)")
            } catch {
                logRSS("stage=feedView.fetchError feedID=\(feedID.uuidString) title=\(title) error=\(error)")
                throw error
            }
        } else {
            logRSS("stage=feedView.fetchSkipped feedID=\(feedID.uuidString) title=\(title) reason=recentlyRefreshed")
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
    @State private var hasAppliedInitialScrollEntryID = false

    @Environment(\.contentSelection) private var contentSelection

    private var entries: [FeedEntry] {
        viewModel.entries ?? []
    }

    private var showsMarkAllAsSeenAction: Bool {
        feed.showsUnseenBadge && !entries.isEmpty
    }

    @MainActor
    private func applyInitialScrollEntryIDIfNeeded() {
        guard let initialScrollEntryID,
              entries.contains(where: { $0.compoundKey == initialScrollEntryID }) else {
            return
        }
        if contentSelection.wrappedValue != initialScrollEntryID {
            contentSelection.wrappedValue = initialScrollEntryID
        }
    }

    public var body: some View {
        let displayedFeed = feed
        let commandSource = FeedViewCommandSource(feed: displayedFeed)
        let isFeedGroupFollowed = viewModel.isFeedGroupFollowed
        let allowsFollowing = feed.entryContentKind != .contentListing
        AsyncView(operation: { forceRefreshRequested in
            try await viewModel.fetchIfNeeded(feed: feed, force: forceRefreshRequested)
        }, showInitialContent: !(viewModel.entries?.isEmpty ?? true)) { _ in
            if let entries = viewModel.entries {
                let entryIDs = entries.map(\.compoundKey)
                let collections = viewModel.collections ?? []
                let activeScrollTargetID = hasAppliedInitialScrollEntryID ? nil : initialScrollEntryID
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
                            onContentAppear: { content in
                                if content.compoundKey == initialScrollEntryID {
                                    hasAppliedInitialScrollEntryID = true
                                }
                            },
                            scrollTargetID: activeScrollTargetID
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
                        .onAppear {
                            applyInitialScrollEntryIDIfNeeded()
                        }
                        .onChange(of: entryIDs) { _ in
                            applyInitialScrollEntryIDIfNeeded()
                        }
#if os(iOS)
                        .listStyle(.insetGrouped)
#endif
                    }
                }
            }
    }
        .task(id: feed.id) { @MainActor in
            try? await commandSource?.markingViewed()?.write()
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if showsToolbar {
                    Menu {
                        if allowsFollowing {
                            Section {
                                Button {
                                    guard let command = FeedViewCommand.following(
                                        !isFeedGroupFollowed, feed: displayedFeed
                                    ) else { return }
                                    Task {
                                        try? await command.write()
                                    }
                                } label: {
                                    Label(isFeedGroupFollowed ? "Following" : "Follow", systemImage: isFeedGroupFollowed ? "checkmark" : "plus")
                                }
                            }
                        }
                        if showsMarkAllAsSeenAction {
                            Button("Mark All as Seen") {
                                guard let command = FeedViewCommand.markingAllEntriesSeen(
                                    feed: displayedFeed, hasEntries: !entries.isEmpty
                                ) else { return }
                                Task {
                                    try? await command.write()
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
                    .modifier {
                        if #available(iOS 16, macOS 13, *) {
                            $0.menuIndicator(.hidden)
                        } else {
                            $0
                        }
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
    let titleVisibilityCoordinateSpaceName: String

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
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: FeedEntryCollectionTitleVisibilityPreferenceKey.self,
                                value: proxy.frame(in: .named(titleVisibilityCoordinateSpaceName)).maxY
                            )
                        }
                    }
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

private struct FeedEntryCollectionTitleVisibilityPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

private struct FeedEntryCollectionView: View {
    @ObservedRealmObject var collection: FeedEntryCollection
    @ObservedObject var viewModel: FeedViewModel
    @Environment(\.contentSelection) private var contentSelection
    @State private var showsReaderContentNewBadges = true
    @State private var showsInlineNavigationTitle = false

    private let titleVisibilityCoordinateSpaceName = "FeedEntryCollectionTitleVisibility"

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
            rendersHeaderViewInSectionHeader: true,
            supplementarySections: {
                EmptyView()
            },
            headerView: {
                FeedEntryCollectionHeader(
                    collection: collection,
                    titleVisibilityCoordinateSpaceName: titleVisibilityCoordinateSpaceName
                )
            },
            emptyStateView: {
                EmptyStateBoxView(
                    title: Text("No Entries Available"),
                    text: Text("This collection is empty. Try refreshing or checking back later."),
                    systemImageName: "newspaper.fill"
                )
            }
        )
        .coordinateSpace(name: titleVisibilityCoordinateSpaceName)
        .onPreferenceChange(FeedEntryCollectionTitleVisibilityPreferenceKey.self) { titleMaxY in
            showsInlineNavigationTitle = titleMaxY <= 0
        }
        .navigationTitle(navigationTitle)
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

    private var navigationTitle: String {
#if os(iOS)
        showsInlineNavigationTitle ? collection.title : ""
#else
        collection.title
#endif
    }
}
