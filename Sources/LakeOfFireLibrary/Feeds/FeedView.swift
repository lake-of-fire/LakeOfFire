import LakeOfFireWeb
import SwiftUI
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireReader
import LakeOfFireContent
import LakeOfFireCore
import RealmSwift
import RealmSwiftGaps
import AsyncView
import Combine
import LakeKit

let feedQueue = DispatchQueue(label: "FeedQueue")



private func logNiponica(_ message: String) {
#if DEBUG
    ()
#endif
}

private func isNiponicaFeed(_ feed: Feed) -> Bool {
    feed.title.localizedCaseInsensitiveContains("niponica")
        || feed.rssUrl.absoluteString.localizedCaseInsensitiveContains("niponica")
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
    @Published var entries: [FeedEntry]? = nil
    @Published var collections: [FeedEntryCollection]? = nil
    @Published var isFeedGroupFollowed = false

    private static var recentAutomaticFetchAttempts: [UUID: Date] = [:]
    private static let automaticFetchAttemptSuppressionInterval: TimeInterval = 60
    private let instanceID = UUID()
    private let canonicalFeedURLKey: String
    
    @RealmBackgroundActor
    private var cancellables = Set<AnyCancellable>()

    @MainActor
    private func reloadEntries(feedID: UUID, reason: String) async {
        do {
            let realm = try await Realm.open(configuration: ReaderContentLoader.feedEntryRealmConfiguration)
            let feedIDs = Feed.activeFeedGroupIDs(
                canonicalFeedURLKey: canonicalFeedURLKey,
                in: realm,
                fallback: feedID
            )
            let entries = Array(
                realm.objects(FeedEntry.self)
                    .where { $0.feedID.in(feedIDs) && !$0.isDeleted }
            )
            self.entries = entries
        } catch {
        }
    }

    @MainActor
    private func reloadCollections(feedID: UUID, reason: String) async {
        do {
            let realm = try await Realm.open(configuration: ReaderContentLoader.feedEntryRealmConfiguration)
            let feedIDs = Feed.activeFeedGroupIDs(
                canonicalFeedURLKey: canonicalFeedURLKey,
                in: realm,
                fallback: feedID
            )
            collections = sortFeedEntryCollections(Array(
                realm.objects(FeedEntryCollection.self)
                    .where { $0.feedID.in(feedIDs) && !$0.isDeleted }
            ))
        } catch {
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
        } catch {
        }
    }
    
    public init(feed: Feed) {
        entries = feed.getEntries()
        collections = feed.getCollections()
        isFeedGroupFollowed = feed.isFollowed
        canonicalFeedURLKey = feed.canonicalFollowingFeedURLKey
        let feedID = feed.id
        let canonicalFeedURLKey = canonicalFeedURLKey
        Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.feedEntryRealmConfiguration) 
            let feedIDs = Feed.activeFeedGroupIDs(
                canonicalFeedURLKey: canonicalFeedURLKey,
                in: realm,
                fallback: feedID
            )
            realm.objects(FeedEntry.self)
                .where { $0.feedID.in(feedIDs) && !$0.isDeleted }
                .collectionPublisher
                .subscribe(on: feedQueue)
                .map { _ in }
                .debounce(for: .seconds(0.3), scheduler: feedQueue)
                .receive(on: feedQueue)
                .sink(receiveCompletion: { _ in}, receiveValue: { [weak self] _ in
                    Task { @MainActor [weak self] in
                        await self?.reloadEntries(feedID: feedID, reason: "entriesChanged")
                    }
                })
                .store(in: &cancellables)

            realm.objects(FeedEntryCollection.self)
                .where { $0.feedID.in(feedIDs) && !$0.isDeleted }
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
                        await self?.reloadEntries(feedID: feedID, reason: "feedsChanged")
                        await self?.reloadCollections(feedID: feedID, reason: "feedsChanged")
                    }
                })
                .store(in: &cancellables)
        }
        Task { @MainActor [weak self] in
            await self?.reloadFollowedStatus(reason: "init")
            await self?.reloadEntries(feedID: feedID, reason: "init")
            await self?.reloadCollections(feedID: feedID, reason: "init")
        }
    }
    
    @MainActor
    public func fetchIfNeeded(feed: Feed, force: Bool) async throws {
        if isNiponicaFeed(feed) {
            logNiponica(
                "stage=feedViewModel.fetchIfNeeded.begin instanceID=\(instanceID.uuidString) feedID=\(feed.id.uuidString) title=\(feed.title) rssURL=\(feed.rssUrl.absoluteString) force=\(force) entries=\(entries?.count ?? -1) lastRefreshedEntriesAt=\(feed.lastRefreshedEntriesAt?.description ?? "nil") lastFetchedModifiedAt=\(feed.lastFetchedModifiedAt?.description ?? "nil") lastFetchedETag=\(feed.lastFetchedETag ?? "nil") shouldAutoRefresh=\(feed.shouldRefreshAutomaticallyOnFeedAppear)"
            )
        }
        if force {
            do {
                try await feed.fetch()
            } catch {
                if isNiponicaFeed(feed) {
                    logNiponica(
                        "stage=feedViewModel.fetchIfNeeded.error instanceID=\(instanceID.uuidString) feedID=\(feed.id.uuidString) title=\(feed.title) rssURL=\(feed.rssUrl.absoluteString) reason=force error=\(String(describing: error)) localized=\(error.localizedDescription) entries=\(entries?.count ?? -1)"
                    )
                }
                throw error
            }
            await reloadEntries(feedID: feed.id, reason: "forceFetchComplete")
            if isNiponicaFeed(feed) {
                logNiponica(
                    "stage=feedViewModel.fetchIfNeeded.end instanceID=\(instanceID.uuidString) feedID=\(feed.id.uuidString) title=\(feed.title) result=fetchedForce entries=\(entries?.count ?? -1)"
                )
            }
            return
        }

        guard feed.shouldRefreshAutomaticallyOnFeedAppear else {
            if isNiponicaFeed(feed) {
                logNiponica(
                    "stage=feedViewModel.fetchIfNeeded.end instanceID=\(instanceID.uuidString) feedID=\(feed.id.uuidString) title=\(feed.title) result=skipFresh entries=\(entries?.count ?? -1)"
                )
            }
            return
        }

        let now = Date()
        if let lastAttempt = Self.recentAutomaticFetchAttempts[feed.id],
           now.timeIntervalSince(lastAttempt) < Self.automaticFetchAttemptSuppressionInterval {
            await reloadEntries(feedID: feed.id, reason: "skipRecentAttempt")
            if isNiponicaFeed(feed) {
                logNiponica(
                    "stage=feedViewModel.fetchIfNeeded.end instanceID=\(instanceID.uuidString) feedID=\(feed.id.uuidString) title=\(feed.title) result=skipRecentAttempt elapsed=\(String(format: "%.2f", now.timeIntervalSince(lastAttempt))) entries=\(entries?.count ?? -1)"
                )
            }
            return
        }

        Self.recentAutomaticFetchAttempts[feed.id] = now
        do {
            try await feed.fetch()
        } catch {
            if isNiponicaFeed(feed) {
                logNiponica(
                    "stage=feedViewModel.fetchIfNeeded.error instanceID=\(instanceID.uuidString) feedID=\(feed.id.uuidString) title=\(feed.title) rssURL=\(feed.rssUrl.absoluteString) reason=autoStale error=\(String(describing: error)) localized=\(error.localizedDescription) entries=\(entries?.count ?? -1)"
                )
            }
            throw error
        }
        await reloadEntries(feedID: feed.id, reason: "autoFetchComplete")
        if isNiponicaFeed(feed) {
            logNiponica(
                "stage=feedViewModel.fetchIfNeeded.end instanceID=\(instanceID.uuidString) feedID=\(feed.id.uuidString) title=\(feed.title) result=fetchedAuto entries=\(entries?.count ?? -1)"
            )
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
#if os(iOS)
    @Environment(\.editMode) private var editMode
#endif

    private var entries: [FeedEntry] {
        viewModel.entries ?? []
    }

    private var showsMarkAllAsSeenAction: Bool {
        feed.showsUnseenBadge && !entries.isEmpty
    }

    private var allowsVideoMakerSelection: Bool {
#if DEBUG
        true
#else
        false
#endif
    }

#if DEBUG
    private var showsSelectionInOverflowMenu: Bool {
#if os(iOS)
        if #available(iOS 26, *) {
            return true
        }
        return false
#else
        return false
#endif
    }

    private var showsSelectionToolbarButton: Bool {
#if os(iOS)
        !showsSelectionInOverflowMenu
#else
        false
#endif
    }
#endif

#if DEBUG && os(iOS)
    private func setSelectionModeActive(_ isActive: Bool) {
        editMode?.wrappedValue = isActive ? .active : .inactive
    }
#endif

    private func entryIDsDescription(_ entries: [FeedEntry]?) -> String {
        (entries ?? []).map(\.compoundKey).joined(separator: ",")
    }

    private func consumeInitialScrollEntryIDIfNeeded(_ content: FeedEntry) {
        if content.compoundKey == initialScrollEntryID {
            hasAppliedInitialScrollEntryID = true
        }
    }

    private func logFeedViewFlash(_ stage: String, entries: [FeedEntry]?, showInitialContent: Bool? = nil) {
        let showInitialContentDescription = showInitialContent.map(String.init(describing:)) ?? "nil"
    }

    @ViewBuilder
    private func feedContent(entries: [FeedEntry]) -> some View {
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
                    allowEditing: allowsVideoMakerSelection,
                    onContentAppear: { content in
                        consumeInitialScrollEntryIDIfNeeded(content)
                    },
                    scrollTargetID: activeScrollTargetID,
                    supplementarySections: {
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
                    },
                    headerView: {
                        EmptyView()
                    },
                    emptyStateView: {
                        EmptyStateBoxView(
                            title: Text("No Entries Available"),
                            text: Text("This feed is empty. Try refreshing or checking back later."),
                            systemImageName: "newspaper.fill"
                        )
                    }
                )
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
        .onAppear {
            logFeedViewFlash("contentAppear", entries: entries)
        }
        .onDisappear {
            logFeedViewFlash("contentDisappear", entries: entries)
        }
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
        let currentEntries = viewModel.entries
        let isFeedGroupFollowed = viewModel.isFeedGroupFollowed
        let allowsFollowing = feed.entryContentKind != .contentListing
        let showInitialContent = !(currentEntries?.isEmpty ?? true)
        AsyncView(operation: { forceRefreshRequested in
            if isNiponicaFeed(feed) {
                logNiponica(
                    "stage=feedView.asyncOperation.begin feedID=\(feed.id.uuidString) title=\(feed.title) rssURL=\(feed.rssUrl.absoluteString) force=\(forceRefreshRequested) entries=\(viewModel.entries?.count ?? -1) showInitialContent=\(showInitialContent)"
                )
            }
            logFeedViewFlash("asyncOperation force=\(forceRefreshRequested)", entries: viewModel.entries, showInitialContent: showInitialContent)
            do {
                try await viewModel.fetchIfNeeded(feed: feed, force: forceRefreshRequested)
                if isNiponicaFeed(feed) {
                    logNiponica(
                        "stage=feedView.asyncOperation.end feedID=\(feed.id.uuidString) title=\(feed.title) result=success entries=\(viewModel.entries?.count ?? -1)"
                    )
                }
            } catch {
                if isNiponicaFeed(feed) {
                    logNiponica(
                        "stage=feedView.asyncOperation.error feedID=\(feed.id.uuidString) title=\(feed.title) rssURL=\(feed.rssUrl.absoluteString) error=\(String(describing: error)) localized=\(error.localizedDescription) entries=\(viewModel.entries?.count ?? -1)"
                    )
                }
                throw error
            }
        }, showInitialContent: showInitialContent) { _ in
            let contentEntries = viewModel.entries
            if let contentEntries {
                feedContent(entries: contentEntries)
                    .onAppear {
                        logFeedViewFlash("contentBuilderVisible", entries: contentEntries, showInitialContent: showInitialContent)
                    }
            } else {
                Color.clear
                    .onAppear {
                        logFeedViewFlash("contentBuilderNil", entries: nil, showInitialContent: showInitialContent)
                    }
            }
        }
        .onAppear {
            logFeedViewFlash("appear", entries: currentEntries, showInitialContent: showInitialContent)
        }
        .onDisappear {
            logFeedViewFlash("disappear", entries: viewModel.entries)
        }
        .onChange(of: viewModel.entries?.map(\.compoundKey) ?? []) { entryIDs in
        }
        .task(id: feed.id) {
            try? await markFeedAsViewed()
        }
        .toolbar {
            ToolbarItem(placement: toolbarTrailingPlacement) {
#if DEBUG
#if os(iOS)
                if showsToolbar,
                   !isHorizontal,
                   !(currentEntries?.isEmpty ?? true),
                   showsSelectionToolbarButton {
                    EditButton()
                }
#endif
#else
                EmptyView()
#endif
            }
            ToolbarItem(placement: toolbarTrailingPlacement) {
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
#if DEBUG
                        if !isHorizontal && !(currentEntries?.isEmpty ?? true) {
#if os(iOS)
                            if showsSelectionInOverflowMenu {
                                Button {
                                    setSelectionModeActive(editMode?.wrappedValue == .inactive)
                                } label: {
                                    Label(editMode?.wrappedValue == .inactive ? "Select" : "Done", systemImage: "checklist")
                                }
                            }
#endif
                        }
#endif
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
#if os(iOS)
        .navigationBarTitleDisplayMode(.automatic)
#endif
    }
    
    public init(feed: Feed, viewModel: FeedViewModel, isHorizontal: Bool = false, showsToolbar: Bool = true, initialScrollEntryID: String? = nil) {
        self.feed = feed
        self.viewModel = viewModel
        self.isHorizontal = isHorizontal
        self.showsToolbar = showsToolbar
        self.initialScrollEntryID = initialScrollEntryID
    }

    private var toolbarTrailingPlacement: ToolbarItemPlacement {
#if os(macOS)
        .automatic
#else
        .navigationBarTrailing
#endif
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
            let now = Date()
            let feeds = realm.objects(Feed.self)
                .where { !$0.isDeleted }
                .filter { $0.canonicalFollowingFeedURLKey == canonicalFeedURLKey }
            let ordinal = feeds.compactMap(\.followingOrdinal).min()
                ?? (isFollowed ? ((realm.objects(Feed.self).compactMap(\.followingOrdinal).max() ?? -1) + 1) : nil)
            for feed in feeds {
                feed.isFollowed = isFollowed
                if let ordinal {
                    feed.followingOrdinal = ordinal
                }
                feed.explicitlyModifiedAt = now
                feed.modifiedAt = now
            }
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
    static var defaultValue: CGFloat = .greatestFiniteMagnitude

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
