import Foundation
import LakeOfFireWeb
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireContent
import LakeOfFireCore
import RealmSwift

public extension Feed {
    static let automaticEntriesRefreshInterval: TimeInterval = 30 * 60

    @MainActor
    public func fetch() async throws {
        try await fetch(realmConfiguration: ReaderContentLoader.feedEntryRealmConfiguration)
    }

    public var hasRecentlyRefreshedEntries: Bool {
        guard let lastRefreshedEntriesAt else { return false }
        return Date().timeIntervalSince(lastRefreshedEntriesAt) < Self.automaticEntriesRefreshInterval
    }

    public var shouldRefreshAutomaticallyOnFeedAppear: Bool {
        !hasRecentlyRefreshedEntries
    }

    public var shouldMarkAsViewedOnAppear: Bool {
        guard let latestEntryCreatedAt else {
            return lastViewedAt == nil
        }
        guard let effectiveFeedSeenDate else {
            return true
        }
        return latestEntryCreatedAt > effectiveFeedSeenDate
    }

    public var firstEntryHasAudio: Bool {
        getEntries()?.first?.hasAudio ?? false
    }

    public var hasActiveEntries: Bool {
        guard let realm else { return false }
        return !activeEntries(in: realm).isEmpty
    }

    public var anyEntryHasAudio: Bool {
        guard let realm else {
            print("Warning: Unexpectedly unmanaged object")
            return false
        }
        return activeEntries(in: realm)
            .contains { $0.hasAudio }
    }

    public var latestEntryCreatedAt: Date? {
        guard let realm else {
            return nil
        }
        return activeEntries(in: realm)
            .max(of: \.createdAt)
    }

    public var latestHistoryRecordLastVisitedAtForFeedEntries: Date? {
        latestHistoryRecordLastVisitedAtForFeedEntries(getEntries() ?? [])
    }

    private func latestHistoryRecordLastVisitedAtForFeedEntries(_ entries: [FeedEntry]) -> Date? {
        guard let historyRealm = try? Realm(configuration: ReaderContentLoader.historyRealmConfiguration) else {
            return nil
        }
        let entryURLStrings = Set(entries.map { $0.url.absoluteString })
        guard !entryURLStrings.isEmpty else { return nil }
        return historyRealm.objects(HistoryRecord.self)
            .where { !$0.isDeleted }
            .filter(NSPredicate(format: "url IN %@", Array(entryURLStrings)))
            .map { $0.lastVisitedAt }
            .max()
    }

    public var effectiveFeedSeenDate: Date? {
        resolvedFeedSeenDate(latestHistoryLastVisitedAt: latestHistoryRecordLastVisitedAtForFeedEntries)
    }

    private func resolvedFeedSeenDate(latestHistoryLastVisitedAt: Date?) -> Date? {
        [lastViewedAt, lastSeenFeedEntriesAt, latestHistoryLastVisitedAt]
            .compactMap { $0 }
            .max()
    }

    public func hasUnseenEntries(_ entries: [FeedEntry]) -> Bool {
        guard showsUnseenBadge else { return false }
        guard let historyRealm = try? Realm(configuration: ReaderContentLoader.historyRealmConfiguration) else {
            return entries.contains { isEntryUnseen($0, latestHistoryLastVisitedAt: nil) }
        }
        return entries.contains { entry in
            let latestHistoryLastVisitedAt = HistoryRecord.latestLastVisitedAt(for: entry.url, in: historyRealm)
            return isEntryUnseen(entry, latestHistoryLastVisitedAt: latestHistoryLastVisitedAt)
        }
    }

    public var hasEntriesNewerThanLastViewedAt: Bool {
        guard showsUnseenBadge else { return false }
        let entries = getEntries() ?? []
        let latestHistoryLastVisitedAt = latestHistoryRecordLastVisitedAtForFeedEntries(entries)
        guard let effectiveLastViewedAt = resolvedFeedSeenDate(
            latestHistoryLastVisitedAt: latestHistoryLastVisitedAt
        ) else {
            return false
        }
        return entries.contains { $0.createdAt > effectiveLastViewedAt }
    }

    var shouldRefreshOnCategoryAppear: Bool {
        guard !hasRecentlyRefreshedEntries else { return false }
        guard let realm else { return true }
        let entries = activeEntries(in: realm)
        guard !entries.isEmpty else { return true }
        guard let lastViewedAt,
              let latestEntryCreatedAt = entries.max(of: \.createdAt) else {
            return false
        }
        return latestEntryCreatedAt < lastViewedAt
    }

    private func activeEntries(in realm: Realm) -> Results<FeedEntry> {
        realm.objects(FeedEntry.self)
            .where { $0.feedID == id && !$0.isDeleted }
    }
}
