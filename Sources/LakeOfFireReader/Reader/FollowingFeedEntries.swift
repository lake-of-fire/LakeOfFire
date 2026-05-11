import Foundation
import LakeOfFireContent
import RealmSwift

public extension Feed {
    static func followingEntries(
        from feeds: [Feed],
        historyRealm: Realm? = nil
    ) -> [FeedEntry] {
        let entriesByFeed = feeds
            .filter { $0.isFollowed && !$0.isDeleted && !$0.isArchived }
            .compactMap { feed -> [FeedEntry]? in
                let entries = (feed.getEntries() ?? [])
                    .filter { entry in
                        let latestHistoryLastVisitedAt = historyRealm.map {
                            HistoryRecord.latestLastVisitedAt(for: entry.url, in: $0)
                        }
                        return feed.isEntryUnseen(entry, latestHistoryLastVisitedAt: latestHistoryLastVisitedAt)
                    }
                    .sorted { followingEntryRecencySort(lhs: $0, rhs: $1) }
                return entries.isEmpty ? nil : entries
            }

        var result: [FeedEntry] = []
        var roundIndex = 0
        while true {
            let round = entriesByFeed.compactMap { entries in
                entries.indices.contains(roundIndex) ? entries[roundIndex] : nil
            }
            guard !round.isEmpty else { break }
            result.append(contentsOf: round.sorted { followingEntryRecencySort(lhs: $0, rhs: $1) })
            roundIndex += 1
        }
        return result
    }

    static func followingEntryRecencySort(lhs: FeedEntry, rhs: FeedEntry) -> Bool {
        switch (lhs.publicationDate, rhs.publicationDate) {
        case let (l?, r?):
            if l != r { return l > r }
            return lhs.createdAt > rhs.createdAt
        case (nil, nil):
            return lhs.createdAt > rhs.createdAt
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        }
    }
}
