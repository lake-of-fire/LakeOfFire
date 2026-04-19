import Foundation
import RealmSwift

public extension Feed {
    static let automaticEntriesRefreshInterval: TimeInterval = 30 * 60

    @MainActor
    func fetch() async throws {
        try await fetch(realmConfiguration: ReaderContentLoader.feedEntryRealmConfiguration)
    }

    var hasRecentlyRefreshedEntries: Bool {
        guard let lastRefreshedEntriesAt else { return false }
        return Date().timeIntervalSince(lastRefreshedEntriesAt) < Self.automaticEntriesRefreshInterval
    }

    var shouldRefreshAutomaticallyOnFeedAppear: Bool {
        !hasRecentlyRefreshedEntries
    }

    var shouldMarkAsViewedOnAppear: Bool {
        guard let latestEntryCreatedAt else {
            return lastViewedAt == nil
        }
        guard let effectiveFeedSeenDate else {
            return true
        }
        return latestEntryCreatedAt > effectiveFeedSeenDate
    }

    var firstEntryHasAudio: Bool {
        getEntries()?.first?.hasAudio ?? false
    }

    var latestEntryCreatedAt: Date? {
        getEntries()?.map(\.createdAt).max()
    }

    var latestHistoryRecordLastVisitedAtForFeedEntries: Date? {
        guard let historyRealm = try? Realm(configuration: ReaderContentLoader.historyRealmConfiguration) else {
            return nil
        }
        let entryURLStrings = Set((getEntries() ?? []).map { $0.url.absoluteString })
        guard !entryURLStrings.isEmpty else { return nil }
        return historyRealm.objects(HistoryRecord.self)
            .where { !$0.isDeleted }
            .filter(NSPredicate(format: "url IN %@", Array(entryURLStrings)))
            .map { $0.lastVisitedAt }
            .max()
    }

    var effectiveFeedSeenDate: Date? {
        [lastViewedAt, lastSeenFeedEntriesAt, latestHistoryRecordLastVisitedAtForFeedEntries]
            .compactMap { $0 }
            .max()
    }

    func effectiveSeenDate(for entry: FeedEntry, latestHistoryLastVisitedAt: Date?) -> Date? {
        let baseline = [lastViewedAt, lastSeenFeedEntriesAt].compactMap { $0 }.max()
        guard let baseline else { return latestHistoryLastVisitedAt }
        guard let latestHistoryLastVisitedAt else { return baseline }
        return max(baseline, latestHistoryLastVisitedAt)
    }

    func isEntryUnseen(_ entry: FeedEntry, latestHistoryLastVisitedAt: Date?) -> Bool {
        guard showsUnseenBadge else { return false }
        if let effectiveSeenDate = effectiveSeenDate(for: entry, latestHistoryLastVisitedAt: latestHistoryLastVisitedAt) {
            return entry.createdAt > effectiveSeenDate
        }
        return latestHistoryLastVisitedAt == nil
    }

    func hasUnseenEntries(_ entries: [FeedEntry]) -> Bool {
        guard showsUnseenBadge else { return false }
        guard let historyRealm = try? Realm(configuration: ReaderContentLoader.historyRealmConfiguration) else {
            return entries.contains { isEntryUnseen($0, latestHistoryLastVisitedAt: nil) }
        }
        return entries.contains { entry in
            let latestHistoryLastVisitedAt = HistoryRecord.latestLastVisitedAt(for: entry.url, in: historyRealm)
            return isEntryUnseen(entry, latestHistoryLastVisitedAt: latestHistoryLastVisitedAt)
        }
    }

    var hasEntriesNewerThanLastViewedAt: Bool {
        let entries = getEntries() ?? []
        guard showsUnseenBadge else {
            let result = false
            debugPrint(
                "# FEEDNEW stage=feed.unread.evaluate",
                "feedID=\(id.uuidString)",
                "title=\(title)",
                "entryCount=\(entries.count)",
                "lastViewedAt=\(lastViewedAt?.description ?? "nil")",
                "lastSeenFeedEntriesAt=\(lastSeenFeedEntriesAt?.description ?? "nil")",
                "latestEntryCreatedAt=\(latestEntryCreatedAt?.description ?? "nil")",
                "latestHistoryLastVisitedAt=nil",
                "effectiveLastViewedAt=nil",
                "showsUnseenBadge=\(showsUnseenBadge)",
                "result=\(result) reason=badgeHidden"
            )
            return result
        }
        let latestHistoryLastVisitedAt = latestHistoryRecordLastVisitedAtForFeedEntries
        guard let effectiveLastViewedAt = effectiveFeedSeenDate else {
            let result = false
            debugPrint(
                "# FEEDNEW stage=feed.unread.evaluate",
                "feedID=\(id.uuidString)",
                "title=\(title)",
                "entryCount=\(entries.count)",
                "lastViewedAt=\(lastViewedAt?.description ?? "nil")",
                "lastSeenFeedEntriesAt=\(lastSeenFeedEntriesAt?.description ?? "nil")",
                "latestEntryCreatedAt=\(latestEntryCreatedAt?.description ?? "nil")",
                "latestHistoryLastVisitedAt=\(latestHistoryLastVisitedAt?.description ?? "nil")",
                "effectiveLastViewedAt=nil",
                "showsUnseenBadge=\(showsUnseenBadge)",
                "result=\(result) reason=noViewedOrHistoryDate"
            )
            return result
        }
        let latestEntryCreatedAt = entries.map(\.createdAt).max()
        let result = entries.contains(where: { $0.createdAt > effectiveLastViewedAt })
        debugPrint(
            "# FEEDNEW stage=feed.unread.evaluate",
            "feedID=\(id.uuidString)",
            "title=\(title)",
            "entryCount=\(entries.count)",
            "lastViewedAt=\(lastViewedAt?.description ?? "nil")",
            "lastSeenFeedEntriesAt=\(lastSeenFeedEntriesAt?.description ?? "nil")",
            "latestEntryCreatedAt=\(latestEntryCreatedAt?.description ?? "nil")",
            "latestHistoryLastVisitedAt=\(latestHistoryLastVisitedAt?.description ?? "nil")",
            "effectiveLastViewedAt=\(effectiveLastViewedAt)",
            "showsUnseenBadge=\(showsUnseenBadge)",
            "result=\(result)"
        )
        return result
    }

    var shouldRefreshOnCategoryAppear: Bool {
        guard !hasRecentlyRefreshedEntries else { return false }
        let entries = getEntries() ?? []
        guard !entries.isEmpty else { return true }
        guard let lastViewedAt,
              let latestEntryCreatedAt else {
            return false
        }
        return latestEntryCreatedAt < lastViewedAt
    }
}
