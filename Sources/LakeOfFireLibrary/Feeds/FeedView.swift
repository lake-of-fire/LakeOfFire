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

private func logDetent(_ message: String) {
#if DEBUG
    debugPrint("# DETENT \(message)")
#endif
}

private func logFeedFlash(_ message: String) {
#if DEBUG
    debugPrint("# FEEDFLASH \(message)")
#endif
}

@MainActor
public class FeedViewModel: ObservableObject {
    @Published var entries: [FeedEntry]? = nil
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
            let entries = Array(
                realm.objects(FeedEntry.self)
                    .where { $0.feedID == feedID && !$0.isDeleted }
            )
            logFeedFlash(
                "model.reloadEntries instanceID=\(instanceID.uuidString) feedID=\(feedID.uuidString) reason=\(reason) entries=\(entries.count) entryIDs=\(entries.map(\.compoundKey).joined(separator: ","))"
            )
            self.entries = entries
        } catch {
            logFeedFlash(
                "model.reloadEntries.error instanceID=\(instanceID.uuidString) feedID=\(feedID.uuidString) reason=\(reason) error=\(error.localizedDescription)"
            )
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
            logFeedFlash(
                "model.reloadFollowedStatus instanceID=\(instanceID.uuidString) feedURLKey=\(canonicalFeedURLKey) reason=\(reason) isFollowed=\(isFeedGroupFollowed)"
            )
        } catch {
            logFeedFlash(
                "model.reloadFollowedStatus.error instanceID=\(instanceID.uuidString) feedURLKey=\(canonicalFeedURLKey) reason=\(reason) error=\(error.localizedDescription)"
            )
        }
    }
    
    public init(feed: Feed) {
        entries = feed.getEntries()
        isFeedGroupFollowed = feed.isFollowed
        canonicalFeedURLKey = feed.canonicalFollowingFeedURLKey
        let feedID = feed.id
        logDetent(
            "feedViewModel.init instanceID=\(instanceID.uuidString) feedID=\(feedID.uuidString) title=\(feed.title) initialEntries=\(entries?.count ?? -1) lastRefreshedEntriesAt=\(feed.lastRefreshedEntriesAt?.description ?? "nil") shouldAutoRefresh=\(feed.shouldRefreshAutomaticallyOnFeedAppear)"
        )
        logFeedFlash(
            "model.init instanceID=\(instanceID.uuidString) feedID=\(feedID.uuidString) title=\(feed.title) initialEntries=\(entries?.count ?? -1) entryIDs=\((entries ?? []).map(\.compoundKey).joined(separator: ",")) lastRefreshedEntriesAt=\(feed.lastRefreshedEntriesAt?.description ?? "nil") shouldAutoRefresh=\(feed.shouldRefreshAutomaticallyOnFeedAppear)"
        )
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
                        let entries = Array(realm.objects(FeedEntry.self).where { $0.feedID == feedID && !$0.isDeleted })
                        logDetent(
                            "feedViewModel.entriesChanged instanceID=\(self?.instanceID.uuidString ?? "nil") feedID=\(feedID.uuidString) entries=\(entries.count)"
                        )
                        logFeedFlash(
                            "model.entriesChanged instanceID=\(self?.instanceID.uuidString ?? "nil") feedID=\(feedID.uuidString) entries=\(entries.count) entryIDs=\(entries.map(\.compoundKey).joined(separator: ","))"
                        )
                        self?.entries = entries
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
        }
    }
    
    @MainActor
    public func fetchIfNeeded(feed: Feed, force: Bool) async throws {
        logDetent(
            "feedViewModel.fetchIfNeeded.begin instanceID=\(instanceID.uuidString) feedID=\(feed.id.uuidString) title=\(feed.title) force=\(force) entries=\(entries?.count ?? -1) lastRefreshedEntriesAt=\(feed.lastRefreshedEntriesAt?.description ?? "nil") shouldAutoRefresh=\(feed.shouldRefreshAutomaticallyOnFeedAppear)"
        )
        logFeedFlash(
            "fetchIfNeeded.begin instanceID=\(instanceID.uuidString) feedID=\(feed.id.uuidString) title=\(feed.title) force=\(force) entries=\(entries?.count ?? -1) lastRefreshedEntriesAt=\(feed.lastRefreshedEntriesAt?.description ?? "nil") shouldAutoRefresh=\(feed.shouldRefreshAutomaticallyOnFeedAppear)"
        )
        if force {
            logDetent("feedViewModel.fetchIfNeeded.fetch instanceID=\(instanceID.uuidString) feedID=\(feed.id.uuidString) reason=force")
            logFeedFlash("fetchIfNeeded.fetch instanceID=\(instanceID.uuidString) feedID=\(feed.id.uuidString) reason=force")
            try await feed.fetch()
            await reloadEntries(feedID: feed.id, reason: "forceFetchComplete")
            logDetent("feedViewModel.fetchIfNeeded.end instanceID=\(instanceID.uuidString) feedID=\(feed.id.uuidString) result=fetchedForce")
            logFeedFlash("fetchIfNeeded.end instanceID=\(instanceID.uuidString) feedID=\(feed.id.uuidString) result=fetchedForce entries=\(entries?.count ?? -1)")
            return
        }

        guard feed.shouldRefreshAutomaticallyOnFeedAppear else {
            logDetent("feedViewModel.fetchIfNeeded.end instanceID=\(instanceID.uuidString) feedID=\(feed.id.uuidString) result=skipFresh")
            logFeedFlash("fetchIfNeeded.end instanceID=\(instanceID.uuidString) feedID=\(feed.id.uuidString) result=skipFresh entries=\(entries?.count ?? -1)")
            return
        }

        let now = Date()
        if let lastAttempt = Self.recentAutomaticFetchAttempts[feed.id],
           now.timeIntervalSince(lastAttempt) < Self.automaticFetchAttemptSuppressionInterval {
            await reloadEntries(feedID: feed.id, reason: "skipRecentAttempt")
            logDetent(
                "feedViewModel.fetchIfNeeded.end instanceID=\(instanceID.uuidString) feedID=\(feed.id.uuidString) result=skipRecentAttempt elapsed=\(String(format: "%.2f", now.timeIntervalSince(lastAttempt)))"
            )
            logFeedFlash(
                "fetchIfNeeded.end instanceID=\(instanceID.uuidString) feedID=\(feed.id.uuidString) result=skipRecentAttempt elapsed=\(String(format: "%.2f", now.timeIntervalSince(lastAttempt))) entries=\(entries?.count ?? -1)"
            )
            return
        }

        Self.recentAutomaticFetchAttempts[feed.id] = now
        logDetent("feedViewModel.fetchIfNeeded.fetch instanceID=\(instanceID.uuidString) feedID=\(feed.id.uuidString) reason=autoStale")
        logFeedFlash("fetchIfNeeded.fetch instanceID=\(instanceID.uuidString) feedID=\(feed.id.uuidString) reason=autoStale")
        try await feed.fetch()
        await reloadEntries(feedID: feed.id, reason: "autoFetchComplete")
        logDetent("feedViewModel.fetchIfNeeded.end instanceID=\(instanceID.uuidString) feedID=\(feed.id.uuidString) result=fetchedAuto")
        logFeedFlash("fetchIfNeeded.end instanceID=\(instanceID.uuidString) feedID=\(feed.id.uuidString) result=fetchedAuto entries=\(entries?.count ?? -1)")
    }
}

public struct FeedView: View {
    @ObservedRealmObject var feed: Feed
    @ObservedObject var viewModel: FeedViewModel
    var isHorizontal = false
    var showsToolbar = true
    @State private var showsReaderContentNewBadges = true
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

    private func logFeedViewFlash(_ stage: String, entries: [FeedEntry]?, showInitialContent: Bool? = nil) {
        let showInitialContentDescription = showInitialContent.map(String.init(describing:)) ?? "nil"
        logFeedFlash(
            "view.\(stage) feedID=\(feed.id.uuidString) title=\(feed.title) isHorizontal=\(isHorizontal) showsToolbar=\(showsToolbar) entries=\(entries?.count ?? -1) entryIDs=\(entryIDsDescription(entries)) showInitialContent=\(showInitialContentDescription)"
        )
    }

    @ViewBuilder
    private func feedContent(entries: [FeedEntry]) -> some View {
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
                    allowEditing: allowsVideoMakerSelection
                ) {
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
        .onAppear {
            logFeedViewFlash("contentAppear", entries: entries)
        }
        .onDisappear {
            logFeedViewFlash("contentDisappear", entries: entries)
        }
    }

    public var body: some View {
        let currentEntries = viewModel.entries
        let isFeedGroupFollowed = viewModel.isFeedGroupFollowed
        let showInitialContent = !(currentEntries?.isEmpty ?? true)
        AsyncView(operation: { forceRefreshRequested in
            logDetent(
                "feedView.asyncOperation feedID=\(feed.id.uuidString) title=\(feed.title) force=\(forceRefreshRequested) entries=\(viewModel.entries?.count ?? -1)"
            )
            logFeedViewFlash("asyncOperation force=\(forceRefreshRequested)", entries: viewModel.entries, showInitialContent: showInitialContent)
            try await viewModel.fetchIfNeeded(feed: feed, force: forceRefreshRequested)
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
            logDetent(
                "feedView.appear feedID=\(feed.id.uuidString) title=\(feed.title) isHorizontal=\(isHorizontal) showsToolbar=\(showsToolbar) entries=\(viewModel.entries?.count ?? -1)"
            )
            logFeedViewFlash("appear", entries: currentEntries, showInitialContent: showInitialContent)
        }
        .onDisappear {
            logDetent(
                "feedView.disappear feedID=\(feed.id.uuidString) title=\(feed.title) isHorizontal=\(isHorizontal) showsToolbar=\(showsToolbar) entries=\(viewModel.entries?.count ?? -1)"
            )
            logFeedViewFlash("disappear", entries: viewModel.entries)
        }
        .onChange(of: viewModel.entries?.map(\.compoundKey) ?? []) { entryIDs in
            logFeedFlash(
                "view.entriesChanged feedID=\(feed.id.uuidString) title=\(feed.title) entries=\(viewModel.entries?.count ?? -1) entryIDs=\(entryIDs.joined(separator: ","))"
            )
        }
        .task(id: feed.id) {
            logDetent(
                "feedView.markViewedTask feedID=\(feed.id.uuidString) title=\(feed.title)"
            )
            try? await markFeedAsViewed()
        }
        .toolbar {
            ToolbarItem(placement: toolbarTrailingPlacement) {
#if DEBUG
                if showsToolbar,
                   !isHorizontal,
                   !(currentEntries?.isEmpty ?? true),
                   showsSelectionToolbarButton {
                    EditButton()
                }
#else
                EmptyView()
#endif
            }
            ToolbarItem(placement: toolbarTrailingPlacement) {
                if showsToolbar {
                    Button {
                        Task { @MainActor in
                            try? await setFollowed(!isFeedGroupFollowed)
                        }
                    } label: {
                        Label(isFeedGroupFollowed ? "Following" : "Follow", systemImage: isFeedGroupFollowed ? "checkmark" : "plus")
                    }
                }
            }
            ToolbarItem(placement: toolbarTrailingPlacement) {
                if showsToolbar {
                    Menu {
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
                }
            }
        }
#if os(iOS)
        .navigationBarTitleDisplayMode(.automatic)
#endif
    }
    
    public init(feed: Feed, viewModel: FeedViewModel, isHorizontal: Bool = false, showsToolbar: Bool = true) {
        self.feed = feed
        self.viewModel = viewModel
        self.isHorizontal = isHorizontal
        self.showsToolbar = showsToolbar
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
