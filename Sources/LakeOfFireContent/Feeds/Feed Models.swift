import Foundation
import RealmSwift
import SwiftSoup
import BigSyncKit
@preconcurrency import FeedKit
import RealmSwiftGaps
import LakeOfFireCore
import LakeOfFireAdblock

public class FeedCategory: Object, UnownedSyncableObject, ObjectKeyIdentifiable, Codable, ChangeMetadataRecordable {
    public var needsSyncToAppServer: Bool {
        return false
    }
    
    @Persisted(primaryKey: true) public var id = UUID()
    
    @Persisted public var opmlOwnerName: String?
    @Persisted public var opmlURL: URL?
    
    @Persisted public var title: String
    @Persisted public var backgroundImageUrl: URL
    @Persisted public var isArchived = false
    
    @Persisted public var explicitlyModifiedAt: Date?
    @Persisted public var createdAt: Date
    @Persisted public var modifiedAt = Date()
    @Persisted public var isDeleted = false
    //    @Persisted(originProperty: "category") public var feeds: LinkingObjects<Feed>
    
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case title
        case backgroundImageUrl
        case createdAt
        case modifiedAt
        case isDeleted
    }
    
    public var isUserEditable: Bool {
        return opmlURL == nil
    }
    
    public func getFeeds() -> [Feed]? {
        guard let realm else {
            print("Warning: Unexpectedly unmanaged object")
            return nil
        }
        return realm.objects(Feed.self).where { $0.categoryID == id && $0.directoryID == nil && !$0.isDeleted }
            .map { $0 }
            .sorted(by: feedCollectionChildSort)
    }

    public func getCollectionChildren() -> [FeedCollectionChild]? {
        guard let realm else {
            print("Warning: Unexpectedly unmanaged object")
            return nil
        }
        let directories = Array(realm.objects(FeedDirectory.self).where { $0.categoryID == id && $0.parentDirectoryID == nil && !$0.isDeleted })
            .map(FeedCollectionChild.directory)
        let feeds = Array(realm.objects(Feed.self).where { $0.categoryID == id && $0.directoryID == nil && !$0.isDeleted })
            .map(FeedCollectionChild.feed)
        return (directories + feeds).sorted(by: feedCollectionChildSort)
    }

    public func getDirectories() -> [FeedDirectory]? {
        guard let realm else {
            print("Warning: Unexpectedly unmanaged object")
            return nil
        }
        return realm.objects(FeedDirectory.self).where { $0.categoryID == id && $0.parentDirectoryID == nil && !$0.isDeleted }
            .map { $0 }
            .sorted(by: feedCollectionChildSort)
    }
    
    public func isEmpty() -> Bool {
        guard let realm else {
            print("Warning: Unexpectedly unmanaged object")
            return true
        }
        return realm.objects(Feed.self).where { $0.categoryID == id && !$0.isDeleted }.first == nil
            && realm.objects(FeedDirectory.self).where { $0.categoryID == id && !$0.isDeleted }.first == nil
    }
}

public enum FeedCollectionChild {
    case directory(FeedDirectory)
    case feed(Feed)

    public var id: UUID {
        switch self {
        case .directory(let directory):
            return directory.id
        case .feed(let feed):
            return feed.id
        }
    }

    public var ordinal: Int? {
        switch self {
        case .directory(let directory):
            return directory.ordinal
        case .feed(let feed):
            return feed.ordinal
        }
    }

    public var title: String {
        switch self {
        case .directory(let directory):
            return directory.title
        case .feed(let feed):
            return feed.title
        }
    }

    fileprivate var typeSortRank: Int {
        switch self {
        case .directory:
            return 0
        case .feed:
            return 1
        }
    }
}

private protocol FeedCollectionSortable {
    var id: UUID { get }
    var ordinal: Int? { get }
    var title: String { get }
    var typeSortRank: Int { get }
}

extension FeedDirectory: FeedCollectionSortable {
    fileprivate var typeSortRank: Int { 0 }
}

extension Feed: FeedCollectionSortable {
    fileprivate var typeSortRank: Int { 1 }
}

extension FeedCollectionChild: FeedCollectionSortable {}

private func feedCollectionChildSort<LHS: FeedCollectionSortable, RHS: FeedCollectionSortable>(_ lhs: LHS, _ rhs: RHS) -> Bool {
    let titleComparison = lhs.title.localizedStandardCompare(rhs.title)
    if titleComparison != .orderedSame {
        return titleComparison == .orderedAscending
    }
    if lhs.typeSortRank != rhs.typeSortRank {
        return lhs.typeSortRank < rhs.typeSortRank
    }
    return lhs.id.uuidString < rhs.id.uuidString
}

public class FeedDirectory: Object, UnownedSyncableObject, ObjectKeyIdentifiable, ChangeMetadataRecordable {
    public var needsSyncToAppServer: Bool {
        return false
    }

    @Persisted(primaryKey: true) public var id = UUID()

    @Persisted public var opmlOwnerName: String?
    @Persisted public var opmlURL: URL?

    @Persisted(indexed: true) public var categoryID: UUID?
    @Persisted(indexed: true) public var parentDirectoryID: UUID?
    @Persisted public var title = ""
    @Persisted public var markdownDescription: String?
    @Persisted public var iconUrl: URL?
    @Persisted public var backgroundImageUrl: URL?
    @Persisted public var ordinal: Int?
    @Persisted public var isArchived = false

    @Persisted public var explicitlyModifiedAt: Date?
    @Persisted public var createdAt = Date()
    @Persisted public var modifiedAt = Date()
    @Persisted public var isDeleted = false

    public var isUserEditable: Bool {
        guard let realm, let categoryID else { return false }
        return realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID)?.opmlURL == nil
    }

    public func getFeeds() -> [Feed]? {
        guard let realm else {
            print("Warning: Unexpectedly unmanaged object")
            return nil
        }
        return realm.objects(Feed.self).where { $0.directoryID == id && !$0.isDeleted }
            .map { $0 }
            .sorted(by: feedCollectionChildSort)
    }

    public func getDirectories() -> [FeedDirectory]? {
        guard let realm else {
            print("Warning: Unexpectedly unmanaged object")
            return nil
        }
        return realm.objects(FeedDirectory.self).where { $0.parentDirectoryID == id && !$0.isDeleted }
            .map { $0 }
            .sorted(by: feedCollectionChildSort)
    }

    public func getCollectionChildren() -> [FeedCollectionChild]? {
        guard let realm else {
            print("Warning: Unexpectedly unmanaged object")
            return nil
        }
        let directories = Array(realm.objects(FeedDirectory.self).where { $0.parentDirectoryID == id && !$0.isDeleted })
            .map(FeedCollectionChild.directory)
        let feeds = Array(realm.objects(Feed.self).where { $0.directoryID == id && !$0.isDeleted })
            .map(FeedCollectionChild.feed)
        return (directories + feeds).sorted(by: feedCollectionChildSort)
    }
}

public class FeedEntryCollection: Object, ObjectKeyIdentifiable, ChangeMetadataRecordable {
    @Persisted(primaryKey: true) public var compoundKey = ""
    @Persisted(indexed: true) public var feedID: UUID?
    @Persisted public var scheme = ""
    @Persisted public var term = ""
    @Persisted public var title = ""
    @Persisted public var summary: String?
    @Persisted public var imageUrl: URL?
    @Persisted public var url: URL?
    @Persisted public var publicationDate: Date?
    @Persisted public var order: Int?

    @Persisted public var explicitlyModifiedAt: Date?
    @Persisted public var createdAt = Date()
    @Persisted public var modifiedAt = Date()
    @Persisted public var isDeleted = false

    public var id: String { compoundKey }

    public static func makePrimaryKey(feedID: UUID?, scheme: String, term: String) -> String {
        [feedID?.uuidString ?? "", scheme, term].joined(separator: "|")
    }

    public func updateCompoundKey() {
        compoundKey = Self.makePrimaryKey(feedID: feedID, scheme: scheme, term: term)
    }
}

public class Feed: Object, UnownedSyncableObject, ObjectKeyIdentifiable, Codable, ChangeMetadataRecordable {
    public var needsSyncToAppServer: Bool {
        return false
    }
    
    @Persisted(primaryKey: true) public var id = UUID()
    @Persisted public var title: String
    @Persisted public var categoryID: UUID?
    @Persisted public var directoryID: UUID?
    @Persisted public var ordinal: Int?
    @Persisted public var markdownDescription: String?
    @Persisted public var rssUrl: URL
    @Persisted public var iconUrl: URL
    
    @Persisted public var isReaderModeByDefault = true
    @Persisted public var rssContainsFullContent = false
    @Persisted public var injectEntryImageIntoHeader = false
    @Persisted public var displayPublicationDate = true
    @Persisted public var meaningfulContentMinLength = 0
    @Persisted public var extractImageFromContent = true
    @Persisted public var deleteOrphans = false
    @Persisted public var entryContentKindRawValue = ReaderContentKind.readerContent.rawValue
    
    //    @Persisted(originProperty: "feed") public var entries: LinkingObjects<FeedEntry>
    @Persisted public var isArchived = false
    
    @Persisted public var explicitlyModifiedAt: Date?
    @Persisted public var createdAt = Date()
    @Persisted public var modifiedAt = Date()
    @Persisted public var lastViewedAt: Date?
    @Persisted public var lastSeenFeedEntriesAt: Date?
    @Persisted public var lastRefreshedEntriesAt: Date?
    @Persisted public var lastFetchedETag: String?
    @Persisted public var lastFetchedModifiedAt: Date?
    @Persisted public var showsUnseenBadge = true
    @Persisted public var isFollowed = false
    @Persisted public var followingOrdinal: Int?
    @Persisted public var isDeleted = false
    
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case title
        case directoryID
        case ordinal
        case markdownDescription
        case rssUrl
        case iconUrl
        case isReaderModeByDefault
        case rssContainsFullContent
        case injectEntryImageIntoHeader
        case displayPublicationDate
        case meaningfulContentMinLength
        case extractImageFromContent
        case deleteOrphans
        case entryContentKindRawValue
        case isFollowed
        case followingOrdinal
        case modifiedAt
        case isArchived
    }
    
    public func isUserEditable() -> Bool {
        guard let realm else {
            print("Warning: Unexpectedly unmanaged object")
            return false
        }
        guard let categoryID else { return false }
        return realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID)?.opmlURL == nil
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(directoryID, forKey: .directoryID)
        try container.encode(ordinal, forKey: .ordinal)
        try container.encode(markdownDescription, forKey: .markdownDescription)
        try container.encode(rssUrl, forKey: .rssUrl)
        try container.encode(isReaderModeByDefault, forKey: .isReaderModeByDefault)
        try container.encode(injectEntryImageIntoHeader, forKey: .injectEntryImageIntoHeader)
        try container.encode(displayPublicationDate, forKey: .displayPublicationDate)
        try container.encode(meaningfulContentMinLength, forKey: .meaningfulContentMinLength)
        try container.encode(deleteOrphans, forKey: .deleteOrphans)
        try container.encode(entryContentKindRawValue, forKey: .entryContentKindRawValue)
        try container.encode(isFollowed, forKey: .isFollowed)
        try container.encode(followingOrdinal, forKey: .followingOrdinal)
        try container.encode(modifiedAt, forKey: .modifiedAt)
    }
    
    public override init() {
        super.init()
    }
    
    required public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.directoryID = try container.decodeIfPresent(UUID.self, forKey: .directoryID)
        self.ordinal = try container.decodeIfPresent(Int.self, forKey: .ordinal)
        self.markdownDescription = try container.decode(String.self, forKey: .markdownDescription)
        self.rssUrl = try container.decode(URL.self, forKey: .rssUrl)
        self.isReaderModeByDefault = try container.decode(Bool.self, forKey: .isReaderModeByDefault)
        self.injectEntryImageIntoHeader = try container.decode(Bool.self, forKey: .injectEntryImageIntoHeader)
        self.displayPublicationDate = try container.decode(Bool.self, forKey: .displayPublicationDate)
        self.meaningfulContentMinLength = try container.decode(Int.self, forKey: .meaningfulContentMinLength)
        self.deleteOrphans = try container.decode(Bool.self, forKey: .deleteOrphans)
        self.entryContentKindRawValue = try container.decodeIfPresent(String.self, forKey: .entryContentKindRawValue) ?? ReaderContentKind.readerContent.rawValue
        self.isFollowed = try container.decodeIfPresent(Bool.self, forKey: .isFollowed) ?? false
        self.followingOrdinal = try container.decodeIfPresent(Int.self, forKey: .followingOrdinal)
    }
    
    public func getCategory() -> FeedCategory? {
        guard let realm else {
            print("Warning: Unexpectedly unmanaged object")
            return nil
        }
        guard let categoryID else { return nil }
        return realm.object(ofType: FeedCategory.self, forPrimaryKey: categoryID)
    }
    
    public func getEntries() -> [FeedEntry]? {
        guard let realm else {
            print("Warning: Unexpectedly unmanaged object")
            return nil
        }
        return realm.objects(FeedEntry.self).where { $0.feedID == id && !$0.isDeleted }
            .sorted(by: \.publicationDate)
            .map { $0 }
    }

    public func getCollections() -> [FeedEntryCollection]? {
        guard let realm else {
            print("Warning: Unexpectedly unmanaged object")
            return nil
        }
        return realm.objects(FeedEntryCollection.self)
            .where { $0.feedID == id && !$0.isDeleted }
            .sorted {
                switch ($0.order, $1.order) {
                case let (left?, right?) where left != right:
                    return left > right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    switch ($0.publicationDate, $1.publicationDate) {
                    case let (left?, right?) where left != right:
                        return left > right
                    case (_?, nil):
                        return true
                    case (nil, _?):
                        return false
                    default:
                        return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                    }
                }
            }
    }
}

public extension Feed {
    var entryContentKind: ReaderContentKind {
        get { ReaderContentKind(rawValue: entryContentKindRawValue) ?? .readerContent }
        set { entryContentKindRawValue = newValue.rawValue }
    }

    public static func canonicalFollowingFeedURLKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }

        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        if components.port == 80, components.scheme == "http" {
            components.port = nil
        } else if components.port == 443, components.scheme == "https" {
            components.port = nil
        }

        return components.url?.absoluteString ?? url.absoluteString
    }

    public var canonicalFollowingFeedURLKey: String {
        Self.canonicalFollowingFeedURLKey(for: rssUrl)
    }

    public static func uniqueFollowingFeedRepresentatives(from feeds: [Feed]) -> [Feed] {
        var representativesByURL = [String: Feed]()

        for feed in feeds where !feed.isDeleted && !feed.isArchived && feed.entryContentKind != .contentListing {
            let key = feed.canonicalFollowingFeedURLKey
            guard let current = representativesByURL[key] else {
                representativesByURL[key] = feed
                continue
            }

            if shouldPreferFollowingFeedRepresentative(feed, over: current) {
                representativesByURL[key] = feed
            }
        }

        return representativesByURL.values.sorted { lhs, rhs in
            switch (lhs.followingOrdinal, rhs.followingOrdinal) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
    }

    public static func isFollowingFeedGroup(containing feed: Feed, in feeds: [Feed]) -> Bool {
        let key = feed.canonicalFollowingFeedURLKey
        return feeds.contains {
            !$0.isDeleted &&
            !$0.isArchived &&
            $0.canonicalFollowingFeedURLKey == key &&
            $0.isFollowed
        }
    }

    public static func setFollowingStatusForFeedGroup(
        containing feed: Feed,
        isFollowed: Bool,
        in realm: Realm,
        now: Date = Date()
    ) {
        setFollowingStatusForFeedGroup(
            canonicalFeedURLKey: feed.canonicalFollowingFeedURLKey,
            isFollowed: isFollowed,
            in: realm,
            now: now
        )
    }

    public static func setFollowingStatusForFeedGroup(
        canonicalFeedURLKey: String,
        isFollowed: Bool,
        in realm: Realm,
        now: Date = Date()
    ) {
        let feeds = Array(realm.objects(Feed.self)
            .where { !$0.isDeleted }
        )
        let plan = FeedFollowingStatusUpdatePlanBuilder.makePlan(
            allFeeds: feeds.map { feed in
                FeedFollowingStatusFeedSnapshot(
                    id: feed.id,
                    canonicalFeedURLKey: feed.canonicalFollowingFeedURLKey,
                    followingOrdinal: feed.followingOrdinal
                )
            },
            canonicalFeedURLKey: canonicalFeedURLKey,
            isFollowed: isFollowed
        )
        let feedIDs = Set(plan.feedIDs)

        for feed in feeds where feedIDs.contains(feed.id) {
            feed.isFollowed = plan.isFollowed
            if let ordinal = plan.followingOrdinal {
                feed.followingOrdinal = ordinal
            }
            feed.explicitlyModifiedAt = now
            feed.modifiedAt = now
        }
    }

    public func effectiveSeenDate(for entry: FeedEntry, latestHistoryLastVisitedAt: Date?) -> Date? {
        let baseline = [lastViewedAt, lastSeenFeedEntriesAt].compactMap { $0 }.max()
        guard let baseline else { return latestHistoryLastVisitedAt }
        guard let latestHistoryLastVisitedAt else { return baseline }
        return max(baseline, latestHistoryLastVisitedAt)
    }

    public func isEntryUnseen(_ entry: FeedEntry, latestHistoryLastVisitedAt: Date?) -> Bool {
        guard showsUnseenBadge else { return false }
        if let effectiveSeenDate = effectiveSeenDate(for: entry, latestHistoryLastVisitedAt: latestHistoryLastVisitedAt) {
            return entry.createdAt > effectiveSeenDate
        }
        return latestHistoryLastVisitedAt == nil
    }

    public static func followingEntries(
        from feeds: [Feed],
        historyRealm: Realm? = nil,
        limit: Int? = nil
    ) -> [FeedEntry] {
        let groupedFeeds = Dictionary(grouping: feeds.filter { !$0.isDeleted && !$0.isArchived && $0.entryContentKind != .contentListing }) {
            $0.canonicalFollowingFeedURLKey
        }

        let orderedFeedGroups = groupedFeeds.values.sorted { lhs, rhs in
            let left = representativeOrdinal(in: Array(lhs))
            let right = representativeOrdinal(in: Array(rhs))
            switch (left, right) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                let leftTitle = lhs.map(\.title).min { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } ?? ""
                let rightTitle = rhs.map(\.title).min { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } ?? ""
                return leftTitle.localizedCaseInsensitiveCompare(rightTitle) == .orderedAscending
            }
        }

        let entriesByFeed = orderedFeedGroups.compactMap { feedGroup -> [FeedEntry]? in
            guard feedGroup.contains(where: \.isFollowed) else { return nil }
            let entries = followingEntries(in: Array(feedGroup), historyRealm: historyRealm, limit: limit)
            return entries.isEmpty ? nil : entries
        }

        var result: [FeedEntry] = []
        var roundIndex = 0
        while true {
            let round = entriesByFeed.compactMap { entries in
                entries.indices.contains(roundIndex) ? entries[roundIndex] : nil
            }
            guard !round.isEmpty else { break }
            for entry in round.sorted(by: { followingEntryRecencySort(lhs: $0, rhs: $1) }) {
                result.append(entry)
                if let limit, result.count >= limit {
                    return result
                }
            }
            roundIndex += 1
        }
        return result
    }

    public static func followingEntryRecencySort(lhs: FeedEntry, rhs: FeedEntry) -> Bool {
        switch (lhs.publicationDate, rhs.publicationDate) {
        case let (left?, right?):
            if left != right { return left > right }
            return lhs.createdAt > rhs.createdAt
        case (nil, nil):
            return lhs.createdAt > rhs.createdAt
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        }
    }

    private static func representativeOrdinal(in feedGroup: [Feed]) -> Int? {
        feedGroup.compactMap(\.followingOrdinal).min()
    }

    private static func shouldPreferFollowingFeedRepresentative(_ candidate: Feed, over current: Feed) -> Bool {
        switch (candidate.followingOrdinal, current.followingOrdinal) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }

        if candidate.isFollowed != current.isFollowed {
            return candidate.isFollowed
        }

        let titleComparison = candidate.title.localizedCaseInsensitiveCompare(current.title)
        if titleComparison != .orderedSame {
            return titleComparison == .orderedAscending
        }

        return candidate.modifiedAt > current.modifiedAt
    }

    public static func canonicalFollowingEntryURLKey(for url: URL) -> String {
        canonicalFollowingFeedURLKey(for: url)
    }

    public static func openedFollowingEntryURLKeys(for candidateEntryURLs: [URL], in historyRealm: Realm?) -> Set<String> {
        guard let historyRealm else { return [] }

        var candidateURLStrings = Set<String>()
        candidateURLStrings.reserveCapacity(candidateEntryURLs.count * 2)
        for url in candidateEntryURLs {
            candidateURLStrings.insert(url.absoluteString)
            candidateURLStrings.insert(canonicalFollowingEntryURLKey(for: url))
        }
        guard !candidateURLStrings.isEmpty else { return [] }

        return Set(
            historyRealm.objects(HistoryRecord.self)
                .where { !$0.isDeleted }
                .filter(NSPredicate(format: "url IN %@", Array(candidateURLStrings)))
                .map { canonicalFollowingEntryURLKey(for: $0.url) }
        )
    }

    private static func followingEntries(in feedGroup: [Feed], historyRealm: Realm?, limit: Int?) -> [FeedEntry] {
        var entries: [FeedEntry] = []
        var seenEntryKeys = Set<String>()
        entries.reserveCapacity(limit ?? 0)

        if let realm = feedGroup.first?.realm {
            let feedIDs = feedGroup.map(\.id)
            let baseEntries = realm.objects(FeedEntry.self)
                .where { !$0.isDeleted && $0.feedID.in(feedIDs) }

            let datedEntries = baseEntries
                .filter("publicationDate != nil")
                .sorted(by: [
                    SortDescriptor(keyPath: "publicationDate", ascending: false),
                    SortDescriptor(keyPath: "createdAt", ascending: false)
                ])
            if appendFollowingEntries(
                datedEntries,
                historyRealm: historyRealm,
                seenEntryKeys: &seenEntryKeys,
                entries: &entries,
                limit: limit
            ) {
                return entries
            }

            let undatedEntries = baseEntries
                .filter("publicationDate == nil")
                .sorted(by: [SortDescriptor(keyPath: "createdAt", ascending: false)])
            if appendFollowingEntries(
                undatedEntries,
                historyRealm: historyRealm,
                seenEntryKeys: &seenEntryKeys,
                entries: &entries,
                limit: limit
            ) {
                return entries
            }

            return entries
        }

        let sortedEntries = feedGroup.flatMap { $0.getEntries() ?? [] }
            .sorted(by: { followingEntryRecencySort(lhs: $0, rhs: $1) })
        if appendFollowingEntries(
            sortedEntries,
            historyRealm: historyRealm,
            seenEntryKeys: &seenEntryKeys,
            entries: &entries,
            limit: limit
        ) {
            return entries
        }
        return entries
    }

    private static func appendFollowingEntries<Candidates: Sequence>(
        _ candidates: Candidates,
        historyRealm: Realm?,
        seenEntryKeys: inout Set<String>,
        entries: inout [FeedEntry],
        limit: Int?
    ) -> Bool where Candidates.Element == FeedEntry {
        let batchSize = 128
        var batch: [FeedEntry] = []
        batch.reserveCapacity(batchSize)

        func appendBatch() -> Bool {
            let openedEntryURLKeys = openedFollowingEntryURLKeys(
                for: batch.map(\.url),
                in: historyRealm
            )
            for entry in batch {
                if appendFollowingEntry(
                    entry,
                    openedEntryURLKeys: openedEntryURLKeys,
                    seenEntryKeys: &seenEntryKeys,
                    entries: &entries,
                    limit: limit
                ) {
                    return true
                }
            }
            batch.removeAll(keepingCapacity: true)
            return false
        }

        for entry in candidates {
            batch.append(entry)
            if batch.count >= batchSize, appendBatch() {
                return true
            }
        }

        return !batch.isEmpty && appendBatch()
    }

    private static func appendFollowingEntry(
        _ entry: FeedEntry,
        openedEntryURLKeys: Set<String>,
        seenEntryKeys: inout Set<String>,
        entries: inout [FeedEntry],
        limit: Int?
    ) -> Bool {
        let entryKey = canonicalFollowingEntryURLKey(for: entry.url)
        guard seenEntryKeys.insert(entryKey).inserted else { return false }
        if openedEntryURLKeys.contains(entryKey) {
            return false
        }
        entries.append(entry)
        return limit.map { entries.count >= $0 } ?? false
    }

    private static func isEntryUnseen(latestHistoryLastVisitedAt: Date?) -> Bool {
        latestHistoryLastVisitedAt == nil
    }
}

@globalActor
fileprivate actor FeedEntryActor {
    static let shared = FeedEntryActor()
}

public class FeedEntry: Object, ObjectKeyIdentifiable, ReaderContentProtocol, ChangeMetadataRecordable {
    @Persisted(primaryKey: true) public var compoundKey = ""
    public var keyPrefix: String? {
        return feedID?.uuidString
    }
    
    @Persisted(indexed: true) public var feedID: UUID?
    
    @Persisted(indexed: true) public var url: URL
    @Persisted public var title = ""
    @Persisted public var author = ""
    @Persisted public var imageUrl: URL?
    @Persisted public var sourceIconURL: URL?
    @Persisted(indexed: true) public var publicationDate: Date?
    @Persisted public var isTitlePrefixOfContent = false
    @Persisted public var isPhysicalMedia = false
    
    //    @Persisted public var isFromClipboard = false
    @Persisted public var content: Data?
    //    @Persisted public var readerModeAvailabilityOverride: Bool? = nil
    
    public var isFromClipboard = false
    
    public var locationBarTitle: String? {
        return url.normalizedHost() ?? url.absoluteString
    }
    
    public var isReaderModeAvailable: Bool {
        get { return isReaderModeByDefault }
        set { }
    }
    public var isReaderModeOfferHidden: Bool {
        get { false }
        set { }
    }
    
    // Feed entry metadata.
    public var rssURLs: List<URL> {
        get {
            let list = RealmSwift.List<URL>()
            if let url = getFeed()?.rssUrl {
                list.append(url)
            }
            return list
        }
    }
    public var rssTitles: List<String> {
        get {
            let list = RealmSwift.List<String>()
            if let title = getFeed()?.title {
                list.append(title)
            }
            return list
        }
    }
    public var isRSSAvailable: Bool {
        get { !rssURLs.isEmpty }
        set { }
    }
    @Persisted public var voiceFrameUrl: URL?
    @Persisted public var voiceAudioURL: URL?
    @Persisted public var voiceAudioURLs = RealmSwift.List<URL>()
    @Persisted public var audioSubtitlesURL: URL?
    @Persisted public var audioSubtitlesRoleRawValue: String?
    @Persisted public var primaryMediaIdentity: String?
    @Persisted public var primaryMediaSourceURL: URL?
    @Persisted public var primaryMediaKindRawValue: String?
    @Persisted public var primaryMediaDuration: Double?
    @Persisted public var primaryMediaLastPlaybackTime: Double?
    @Persisted public var offlineMediaID: String?
    @Persisted public var redditTranslationsUrl: URL?
    @Persisted public var redditTranslationsTitle: String?
    @Persisted public var autoOpenMediaPlayer = false
    @Persisted public var readerContentKindRawValue = ReaderContentKind.readerContent.rawValue
    @Persisted public var feedEntryCollectionKey: String?
    @Persisted public var feedEntryCollectionScheme: String?
    @Persisted public var feedEntryCollectionTerm: String?
    @Persisted public var feedEntryCollectionTitle: String?
    
    // Feed options.
    public var isReaderModeByDefault: Bool {
        //        get { readerModeAvailabilityOverride ?? feed?.isReaderModeByDefault ?? true }
        get { getFeed()?.isReaderModeByDefault ?? true }
        set { }
    }
    public var rssContainsFullContent: Bool {
        get { getFeed()?.rssContainsFullContent ?? false }
        set { getFeed()?.rssContainsFullContent = newValue }
    }
    public var meaningfulContentMinLength: Int {
        get { getFeed()?.meaningfulContentMinLength ?? 0 }
        set { getFeed()?.meaningfulContentMinLength = newValue }
    }
    public var injectEntryImageIntoHeader: Bool {
        get { getFeed()?.injectEntryImageIntoHeader ?? false }
        set { getFeed()?.injectEntryImageIntoHeader = newValue }
    }
    public var displayPublicationDate: Bool {
        get { getFeed()?.displayPublicationDate ?? true }
        set { getFeed()?.displayPublicationDate = newValue }
    }
    public var extractImageFromContent: Bool {
        get { getFeed()?.extractImageFromContent ?? false }
        set { getFeed()?.extractImageFromContent = newValue }
    }
    
#warning("TODO: Use createdAt to trim FeedEntry items after N days, N entries etc. or low disk notif")
    @Persisted public var explicitlyModifiedAt: Date?
    @Persisted public var createdAt = Date()
    @Persisted public var modifiedAt = Date()
    @Persisted public var isDeleted = false
    
    public var displayAbsolutePublicationDate: Bool {
        return false
    }
    
    public func getFeed() -> Feed? {
        guard let realm else {
            print("Warning: Unexpectedly unmanaged object")
            return nil
        }
        guard let feedID else { return nil }
        return realm.object(ofType: Feed.self, forPrimaryKey: feedID)
    }
    
    @MainActor
    public func imageURLToDisplay() async throws -> URL? {
        if let imageUrl {
            return imageUrl
        }
        guard let configuration = realm?.configuration else { return nil }
        let compoundKey = compoundKey
        return try await { @FeedEntryActor () -> URL? in
            let realm = try await Realm.open(configuration: configuration)
            guard let feedEntry = realm.object(ofType: FeedEntry.self, forPrimaryKey: compoundKey) else { return nil }
            if feedEntry.extractImageFromContent {
                let legacyHTMLContent = feedEntry.htmlContent
                let ref = compoundKey
                let existingImageURL = feedEntry.imageUrl
                if let html = Self.contentToHTML(
                    legacyHTMLContent: legacyHTMLContent,
                    content: feedEntry.content
                ), let url = Self.imageURLExtractedFromContent(
                    htmlContent: html
                ), existingImageURL != url {
                    try await { @RealmBackgroundActor in
                        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: configuration)
                        guard let entry = realm.object(ofType: FeedEntry.self, forPrimaryKey: ref) else { return }
                        //await realm.asyncRefresh()
                        try await realm.asyncWrite {
                            entry.imageUrl = url
                            entry.refreshChangeMetadata(explicitlyModified: true)
                        }
                    }()
                    return url
                }
                return nil
            }
            return nil
        }()
        return nil
    }
    
    @RealmBackgroundActor
    public func configureBookmark(_ bookmark: Bookmark) {
        let feed = getFeed()
        
        // Feed options.
        bookmark.rssContainsFullContent = feed?.rssContainsFullContent ?? bookmark.rssContainsFullContent
        if bookmark.rssContainsFullContent {
            bookmark.content = content
        }
        bookmark.meaningfulContentMinLength = feed?.meaningfulContentMinLength ?? bookmark.meaningfulContentMinLength
        bookmark.injectEntryImageIntoHeader = feed?.injectEntryImageIntoHeader ?? bookmark.injectEntryImageIntoHeader
        //        bookmark.rawEntryThumbnailContentMode = feed?.contentmode
        bookmark.displayPublicationDate = feed?.displayPublicationDate ?? bookmark.displayPublicationDate
        
        // Feed metadata.
        bookmark.rssURLs.removeAll()
        bookmark.rssTitles.removeAll()
        if let feed = feed {
            bookmark.rssURLs.append(feed.rssUrl)
            bookmark.rssTitles.append(feed.title)
        }
        bookmark.isRSSAvailable = !bookmark.rssURLs.isEmpty
        copyReaderMediaState(
            to: bookmark,
            defaultAudioSubtitlesRole: .content
        )
        bookmark.readerContentKind = readerContentKind
        bookmark.feedEntryCollectionKey = feedEntryCollectionKey
        bookmark.feedEntryCollectionScheme = feedEntryCollectionScheme
        bookmark.feedEntryCollectionTerm = feedEntryCollectionTerm
        bookmark.feedEntryCollectionTitle = feedEntryCollectionTitle

        bookmark.isReaderModeByDefault = isReaderModeByDefault
    }
}

fileprivate extension FeedEntry {
    static func imageURLExtractedFromContent(htmlContent: String) -> URL? {
        guard let doc = try? SwiftSoup.parse(htmlContent) else { return nil }
        doc.outputSettings().prettyPrint(pretty: false)
        do {
            let threshold: Float = 0.3
            
            let imageElements: [Element] = try Array(doc.getElementsByTag("img"))
            let filteredImageElements: [Element] = imageElements.filter({ (imageTag: Element) -> Bool in
                if let src: String = try? imageTag.attr("src"), src.contains("doubleclick.net") {
                    return false
                }
                
                do {
                    let height: Float? = try Float(imageTag.attr("height")),
                        width: Float? = try Float(imageTag.attr("width"))
                    if let width: Float = width, let height: Float = height {
                        return Float(height / width) > threshold
                    } else {
                        return (height ?? 1.0) / (width ?? 1.0) > threshold
                    }
                } catch {
                    return true
                }
            })
            let imageElement: Element? = filteredImageElements.first
            var imageUrlOptional: String? = try imageElement?.attr("src")
            
            // Match images without width or height specified if we can't find an ideal image before.
            if imageUrlOptional == nil {
                imageUrlOptional = try doc.getElementsByTag("img").filter({ imageTag -> Bool in
                    if let src = try? imageTag.attr("src"), src.contains("doubleclick.net") {
                        return false
                    }
                    
                    do {
                        let height = try Float(imageTag.attr("height")),
                            width = try Float(imageTag.attr("width"))
                        return height != nil || width != nil
                    } catch {
                        return true
                    }
                }).first?.attr("src")
            }
            
            // Match YouTube links for thumbnails.
            if imageUrlOptional == nil {
                imageUrlOptional = try doc.getElementsByTag("iframe").compactMap({ iframeTag -> String? in
                    if let src = try? iframeTag.attr("src"),
                       src.hasPrefix("https://www.youtube.com"),
                       let youtubeId = src.split(separator: "/").last {
                        return "https://img.youtube.com/vi/\(youtubeId)/0.jpg"
                    }
                    return nil
                }).first
            }
            if let imageUrl = imageUrlOptional {
                return URL(string: imageUrl)
            }
        } catch {
            debugPrint("Error extracting image URL from content", error)
        }
        return nil
    }
}

public enum FeedError: Error {
    case downloadFailed
    case parserFailed
    case jsonFeedsUnsupported
}

fileprivate struct FeedFetchMetadata {
    let etag: String?
    let lastModifiedAt: Date?

    func merged(with newer: FeedFetchMetadata) -> FeedFetchMetadata {
        FeedFetchMetadata(
            etag: newer.etag ?? etag,
            lastModifiedAt: newer.lastModifiedAt ?? lastModifiedAt
        )
    }
}

fileprivate func logRSS(_ message: String) {
#if DEBUG
    debugPrint("# RSS \(message)")
#endif
}

fileprivate struct ParsedFeedEntryCollection {
    let scheme: String
    let term: String
    let title: String
    let summary: String?
    let imageUrl: URL?
    let url: URL?
    let publicationDate: Date?
    let order: Double?
}

fileprivate final class ManabiAtomCollectionParser: NSObject, XMLParserDelegate {
    private(set) var collections: [ParsedFeedEntryCollection] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let localName = elementName.split(separator: ":").last.map(String.init) ?? elementName
        guard localName == "collection" else { return }
        if let namespaceURI, namespaceURI != "https://manabi.io/feed" {
            return
        }
        guard
            let scheme = attributeDict["scheme"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !scheme.isEmpty,
            let term = (attributeDict["id"] ?? attributeDict["term"])?.trimmingCharacters(in: .whitespacesAndNewlines),
            !term.isEmpty
        else { return }

        let title = attributeDict["title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = attributeDict["summary"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageUrl = (attributeDict["cover"] ?? attributeDict["image"]).flatMap { URL(string: $0) }
        let url = (attributeDict["href"] ?? attributeDict["url"]).flatMap { URL(string: $0) }
        let publicationDate = (attributeDict["published"] ?? attributeDict["updated"] ?? attributeDict["date"])
            .flatMap(Self.parseDate)

        collections.append(
            ParsedFeedEntryCollection(
                scheme: scheme,
                term: term,
                title: title?.isEmpty == false ? title! : term,
                summary: summary?.isEmpty == false ? summary : nil,
                imageUrl: imageUrl,
                url: url,
                publicationDate: publicationDate,
                order: attributeDict["order"].flatMap(Double.init)
            )
        )
    }

    private static func parseDate(_ rawValue: String) -> Date? {
        makeDateTimeWithFractionalSecondsFormatter().date(from: rawValue)
            ?? makeDateTimeFormatter().date(from: rawValue)
            ?? makeDateOnlyFormatter().date(from: rawValue)
    }

    private static func makeDateTimeWithFractionalSecondsFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func makeDateTimeFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    private static func makeDateOnlyFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }
}

fileprivate func parseManabiAtomCollections(from data: Data) -> [ParsedFeedEntryCollection] {
    let parserDelegate = ManabiAtomCollectionParser()
    let parser = XMLParser(data: data)
    parser.shouldProcessNamespaces = true
    parser.delegate = parserDelegate
    _ = parser.parse()
    if parserDelegate.collections.isEmpty {
        let fallbackParser = XMLParser(data: data)
        fallbackParser.shouldProcessNamespaces = false
        fallbackParser.delegate = parserDelegate
        _ = fallbackParser.parse()
    }
    return parserDelegate.collections
}

fileprivate enum FeedFetchResult {
    case notModified(metadata: FeedFetchMetadata)
    case fetched(Data, metadata: FeedFetchMetadata)
}

fileprivate func makeFeedHTTPDateFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter
}

fileprivate func formatFeedHTTPDate(_ date: Date) -> String {
    makeFeedHTTPDateFormatter().string(from: date)
}

fileprivate func parseFeedHTTPDate(_ rawValue: String) -> Date? {
    makeFeedHTTPDateFormatter().date(from: rawValue)
}

private final class FeedSessionOverrideStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var override: (() -> URLSession)?

    var value: (() -> URLSession)? {
        get {
            lock.withLock {
                override
            }
        }
        set {
            lock.withLock {
                override = newValue
            }
        }
    }
}

private let feedSessionOverrideStorage = FeedSessionOverrideStorage()

var makeFeedSessionOverrideForTesting: (() -> URLSession)? {
    get {
        feedSessionOverrideStorage.value
    }
    set {
        feedSessionOverrideStorage.value = newValue
    }
}

fileprivate func makeFeedSession() -> URLSession {
    if let makeFeedSessionOverrideForTesting {
        return makeFeedSessionOverrideForTesting()
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    return URLSession(configuration: configuration)
}

fileprivate func makeFeedRequest(
    url: URL,
    method: String,
    lastFetchedETag: String?,
    lastFetchedModifiedAt: Date?
) -> URLRequest {
    var request = URLRequest(
        url: url,
        cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
        timeoutInterval: 30
    )
    request.httpMethod = method
    if let lastFetchedETag, !lastFetchedETag.isEmpty {
        request.setValue(lastFetchedETag, forHTTPHeaderField: "If-None-Match")
    }
    if let lastFetchedModifiedAt {
        request.setValue(
            formatFeedHTTPDate(lastFetchedModifiedAt),
            forHTTPHeaderField: "If-Modified-Since"
        )
    }
    return request
}

fileprivate func feedFetchMetadata(from response: URLResponse) -> FeedFetchMetadata {
    guard let httpResponse = response as? HTTPURLResponse else {
        return FeedFetchMetadata(etag: nil, lastModifiedAt: nil)
    }
    let etag = httpResponse.value(forHTTPHeaderField: "Etag")
        ?? httpResponse.value(forHTTPHeaderField: "ETag")
    let lastModifiedAt = httpResponse.value(forHTTPHeaderField: "Last-Modified")
        .flatMap(parseFeedHTTPDate)
    return FeedFetchMetadata(etag: etag, lastModifiedAt: lastModifiedAt)
}

fileprivate func isFeedUnchanged(
    remoteMetadata: FeedFetchMetadata,
    lastFetchedETag: String?,
    lastFetchedModifiedAt: Date?
) -> Bool {
    if let remoteETag = remoteMetadata.etag,
       let lastFetchedETag,
       remoteETag == lastFetchedETag {
        return true
    }

    if let remoteLastModifiedAt = remoteMetadata.lastModifiedAt,
       let lastFetchedModifiedAt,
       remoteLastModifiedAt <= lastFetchedModifiedAt {
        return true
    }

    return false
}

fileprivate func isSuccessfulFeedRefreshStatus(_ statusCode: Int) -> Bool {
    (200..<400).contains(statusCode)
}

fileprivate func getRssData(
    rssUrl: URL,
    lastFetchedETag: String?,
    lastFetchedModifiedAt: Date?
) async throws -> FeedFetchResult {
    let session = makeFeedSession()
    logRSS(
        "stage=http.head.start url=\(rssUrl.absoluteString) ifNoneMatch=\(lastFetchedETag ?? "nil") ifModifiedSince=\(lastFetchedModifiedAt.map(formatFeedHTTPDate) ?? "nil")"
    )
    let headRequest = makeFeedRequest(
        url: rssUrl,
        method: "HEAD",
        lastFetchedETag: lastFetchedETag,
        lastFetchedModifiedAt: lastFetchedModifiedAt
    )
    let (_, headResponse) = try await session.data(for: headRequest)
    guard let headHTTPResponse = headResponse as? HTTPURLResponse else {
        throw FeedError.downloadFailed
    }

    let headMetadata = feedFetchMetadata(from: headHTTPResponse)
    logRSS(
        "stage=http.head.response url=\(rssUrl.absoluteString) status=\(headHTTPResponse.statusCode) etag=\(headMetadata.etag ?? "nil") lastModified=\(headMetadata.lastModifiedAt.map(formatFeedHTTPDate) ?? "nil")"
    )
    switch headHTTPResponse.statusCode {
    case 304:
        logRSS("stage=http.notModified source=head304 url=\(rssUrl.absoluteString)")
        return .notModified(metadata: headMetadata)
    case let statusCode where isSuccessfulFeedRefreshStatus(statusCode):
        if isFeedUnchanged(
            remoteMetadata: headMetadata,
            lastFetchedETag: lastFetchedETag,
            lastFetchedModifiedAt: lastFetchedModifiedAt
        ) {
            logRSS("stage=http.notModified source=headMetadata url=\(rssUrl.absoluteString)")
            return .notModified(metadata: headMetadata)
        }
    default:
        logRSS("stage=http.head.error url=\(rssUrl.absoluteString) status=\(headHTTPResponse.statusCode)")
        throw FeedError.downloadFailed
    }

    logRSS("stage=http.get.start url=\(rssUrl.absoluteString)")
    let getRequest = makeFeedRequest(
        url: rssUrl,
        method: "GET",
        lastFetchedETag: lastFetchedETag,
        lastFetchedModifiedAt: lastFetchedModifiedAt
    )
    let (data, getResponse) = try await session.data(for: getRequest)
    guard let getHTTPResponse = getResponse as? HTTPURLResponse else {
        throw FeedError.downloadFailed
    }

    let getMetadata = headMetadata.merged(with: feedFetchMetadata(from: getHTTPResponse))
    logRSS(
        "stage=http.get.response url=\(rssUrl.absoluteString) status=\(getHTTPResponse.statusCode) bytes=\(data.count) etag=\(getMetadata.etag ?? "nil") lastModified=\(getMetadata.lastModifiedAt.map(formatFeedHTTPDate) ?? "nil")"
    )
    switch getHTTPResponse.statusCode {
    case 304:
        logRSS("stage=http.notModified source=get304 url=\(rssUrl.absoluteString)")
        return .notModified(metadata: getMetadata)
    case 200..<300:
        return .fetched(data, metadata: getMetadata)
    case 300..<400:
        logRSS("stage=http.notModified source=getRedirect url=\(rssUrl.absoluteString) status=\(getHTTPResponse.statusCode)")
        return .notModified(metadata: getMetadata)
    default:
        logRSS("stage=http.get.error url=\(rssUrl.absoluteString) status=\(getHTTPResponse.statusCode)")
        throw FeedError.downloadFailed
    }
}

fileprivate func collapseRubyTags(doc: SwiftSoup.Document, restrictToReaderContentElement: Bool = true) throws {
    let pageElement = try doc.getElementById("reader-content")?.getElementsByClass("page").first()
    guard !restrictToReaderContentElement || pageElement != nil else { return }
    
    for rubyTag in try (pageElement ?? doc).getElementsByTag(UTF8Arrays.ruby) {
        for tagName in [UTF8Arrays.rp, UTF8Arrays.rt, UTF8Arrays.rtc] {
            try rubyTag.getElementsByTag(tagName).remove()
        }
        
        let surface = try rubyTag.text(trimAndNormaliseWhitespace: false)
        try rubyTag.before(surface)
        try rubyTag.remove()
    }
}

fileprivate let entryImageExtensions = ["jpg", "jpeg", "png", "webp", "gif"]

public extension Feed {
    @MainActor
    private func persistFetchMetadata(
        _ metadata: FeedFetchMetadata,
        realmConfiguration: Realm.Configuration
    ) async throws {
        let feedID = id
        let rssUrl = rssUrl
        logRSS(
            "stage=metadata.persist.start feedID=\(feedID.uuidString) url=\(rssUrl.absoluteString) etag=\(metadata.etag ?? "nil") lastModified=\(metadata.lastModifiedAt.map(formatFeedHTTPDate) ?? "nil")"
        )
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
            await realm.asyncRefresh()
            try await realm.asyncWrite {
                guard let feed = realm.object(ofType: Feed.self, forPrimaryKey: feedID) else {
                    logRSS("stage=metadata.persist.missingFeed feedID=\(feedID.uuidString) url=\(rssUrl.absoluteString)")
                    return
                }
                feed.lastRefreshedEntriesAt = Date()
                feed.lastFetchedETag = metadata.etag ?? feed.lastFetchedETag
                feed.lastFetchedModifiedAt = metadata.lastModifiedAt ?? feed.lastFetchedModifiedAt
            }
        }()
        logRSS("stage=metadata.persist.finished feedID=\(feedID.uuidString) url=\(rssUrl.absoluteString)")
    }

    @MainActor
    private func persist(rssItems: [RSSFeedItem], realmConfiguration: Realm.Configuration, deleteOrphans: Bool) async throws {
        let feedID = id
        let iconUrl = iconUrl
        let rssUrl = rssUrl
        let entryContentKind = entryContentKind
        var incomingIDs = [String]()
        var skippedItems = 0
        let feedEntries: [FeedEntry] = rssItems.reversed().compactMap { item -> FeedEntry? in
            guard let link = item.link?.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
                  let url = URL(string: link)
            else {
                skippedItems += 1
                return nil
            }
            var imageUrl: URL? = nil
            if let enclosureAttribs = item.enclosure?.attributes, enclosureAttribs.type?.hasPrefix("image/") ?? false {
                if let imageUrlRaw = enclosureAttribs.url {
                    imageUrl = URL(string: imageUrlRaw)
                }
            } else if let rawImageURL = item.media?.mediaContents?
                .lazy.compactMap({ $0.attributes?.url })
                .first(where: { entryImageExtensions.contains(($0 as NSString).pathExtension.lowercased()) })
            {
                imageUrl = URL(string: rawImageURL)
            }
            let content = item.content?.contentEncoded ?? item.description

            let rawSubtitleHref = item.media?.mediaSubTitle?.attributes?.href?
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            let audioSubtitlesURL: URL? = {
                guard let rawValue = rawSubtitleHref, !rawValue.isEmpty else { return nil }
                if let direct = URL(string: rawValue) {
                    return direct
                }
                return rawValue
                    .addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
                    .flatMap { URL(string: $0) }
            }()
            debugPrint(
                "# AUDIO-VTT rss.subtitle.parse",
                "url=\(url)",
                "raw=\(rawSubtitleHref ?? "nil")",
                "normalized=\(audioSubtitlesURL?.absoluteString ?? "nil")",
                "hasMediaSubTitle=\(item.media?.mediaSubTitle != nil)"
            )

            var title = item.title
            do {
                if let feedItemTitle = item.title?.unescapeHTML(), feedItemTitle.contains("<") {
                    if let doc = try? SwiftSoup.parse(feedItemTitle) {
                        doc.outputSettings().prettyPrint(pretty: false)
                        try collapseRubyTags(doc: doc, restrictToReaderContentElement: false)
                        title = try doc.text()
                    }
                }
            } catch { }
            title = title?.trimmingCharacters(in: .whitespacesAndNewlines)

            let feedEntry = FeedEntry()
            feedEntry.feedID = feedID
            feedEntry.html = content
            feedEntry.url = url
            feedEntry.title = title ?? ""
            feedEntry.author = item.author ?? ""
            feedEntry.imageUrl = imageUrl
            feedEntry.sourceIconURL = iconUrl
            feedEntry.publicationDate = item.pubDate ?? item.dublinCore?.dcDate
            feedEntry.audioSubtitlesURL = audioSubtitlesURL
            feedEntry.audioSubtitlesRoleRawValue = audioSubtitlesURL != nil ? AudioSubtitlesRole.content.rawValue : nil
            feedEntry.readerContentKind = entryContentKind
            feedEntry.updateCompoundKey()
            incomingIDs.append(feedEntry.compoundKey)
            return feedEntry
        }
        logRSS(
            "stage=persist.rss.mapped feedID=\(feedID.uuidString) url=\(rssUrl.absoluteString) inputItems=\(rssItems.count) mappedEntries=\(feedEntries.count) skippedInvalidURL=\(skippedItems) deleteOrphans=\(deleteOrphans)"
        )
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
            
            let existingEntryIDs = Array(
                realm.objects(FeedEntry.self)
                    .where { $0.feedID == feedID }
                    .filter { !$0.isDeleted }
                    .map { $0.compoundKey }
            )
            logRSS(
                "stage=persist.rss.beforeUpsert feedID=\(feedID.uuidString) existingEntries=\(existingEntryIDs.count) incomingEntries=\(incomingIDs.count)"
            )
            
            let payloads = try await upsertFeedEntries(
                realm: realm,
                entries: feedEntries,
                existingEntryIDs: existingEntryIDs,
                incomingIDs: incomingIDs,
                deleteOrphans: deleteOrphans
            )
            for payload in payloads {
                try await syncRelatedReaderContent(with: payload)
            }
            logRSS(
                "stage=persist.rss.finished feedID=\(feedID.uuidString) payloadsSynced=\(payloads.count)"
            )
        }()
    }
    
    @MainActor
    private func persist(
        atomItems: [AtomFeedEntry],
        collections: [ParsedFeedEntryCollection],
        realmConfiguration: Realm.Configuration,
        deleteOrphans: Bool
    ) async throws {
        let feedID = id
        let sourceIconURL = iconUrl
        let rssUrl = rssUrl
        let entryContentKind = entryContentKind
        let collectionObjects = collections.map { parsedCollection -> FeedEntryCollection in
            let collection = FeedEntryCollection()
            collection.feedID = feedID
            collection.scheme = parsedCollection.scheme
            collection.term = parsedCollection.term
            collection.title = parsedCollection.title
            collection.summary = parsedCollection.summary
            collection.imageUrl = parsedCollection.imageUrl
            collection.url = parsedCollection.url
            collection.publicationDate = parsedCollection.publicationDate
            collection.order = parsedCollection.order.map(Int.init)
            collection.updateCompoundKey()
            return collection
        }
        var collectionsBySchemeAndTerm = [String: FeedEntryCollection]()
        for collection in collectionObjects {
            collectionsBySchemeAndTerm["\(collection.scheme)\n\(collection.term)"] = collection
        }
        let incomingCollectionKeys = collectionObjects.map(\.compoundKey)
        var incomingIDs = [String]()
        var skippedItems = 0
        let feedEntries: [FeedEntry] = atomItems.reversed().compactMap { (item) -> FeedEntry? in
            var url: URL?
            var imageUrl: URL?
            item.links?.forEach { (link: AtomFeedEntryLink) in
                guard let linkHref = link.attributes?.href?.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
                else { return }

                if (link.attributes?.rel ?? "alternate") == "alternate" {
                    url = URL(string: linkHref)
                } else if let rel = link.attributes?.rel, let type = link.attributes?.type, rel == "enclosure" && type.hasPrefix("image/") {
                    imageUrl = URL(string: linkHref)
                }
            }
            guard let url = url else {
                skippedItems += 1
                return nil
            }

            var voiceFrameUrl: URL? = nil
            if let rawVoiceFrameUrl = item.links?
                .filter({ (link) -> Bool in
                    return (link.attributes?.rel ?? "") == "voice-frame"
                })
                    .first?.attributes?.href
            {
                voiceFrameUrl = URL(string: rawVoiceFrameUrl)
            }

            let voiceAudioURLs: [URL] = (item.links ?? [])
                .filter { $0.attributes?.rel == "voice-audio" }
                .compactMap { $0.attributes?.href }
                .compactMap { URL(string: $0) }
            let rawAtomSubtitleHref = (item.links ?? [])
                .first { $0.attributes?.rel == "voice-audio-subtitles" }
                .flatMap { $0.attributes?.href }
            let audioSubtitlesURL: URL? = rawAtomSubtitleHref
                .flatMap { URL(string: $0) }
            debugPrint(
                "# AUDIO-VTT atom.subtitle.parse",
                "url=\(url)",
                "raw=\(rawAtomSubtitleHref ?? "nil")",
                "normalized=\(audioSubtitlesURL?.absoluteString ?? "nil")"
            )

            var redditTranslationsUrl: URL? = nil, redditTranslationsTitle: String? = nil
            if let redditTranslationsAttrs = item.links?
                .filter({ (link) -> Bool in
                    return (link.attributes?.rel ?? "") == "reddit-translations"
                })
                    .first?.attributes,
               let rawRedditTranslationsUrl = redditTranslationsAttrs.href?
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            {
                redditTranslationsUrl = URL(string: rawRedditTranslationsUrl)
                redditTranslationsTitle = redditTranslationsAttrs.title
            }

            var title = item.title
            do {
                if let feedItemTitle = item.title?.unescapeHTML(), feedItemTitle.contains("<") {
                    if let doc = try? SwiftSoup.parse(feedItemTitle) {
                        doc.outputSettings().prettyPrint(pretty: false)
                        try collapseRubyTags(doc: doc, restrictToReaderContentElement: false)
                        title = try doc.text()
                    }
                }
            } catch { }
            title = title?.trimmingCharacters(in: .whitespacesAndNewlines)

            let feedEntry = FeedEntry()
            feedEntry.feedID = feedID
            feedEntry.url = url
            feedEntry.title = title ?? ""
            feedEntry.author = item.authors?.compactMap { $0.name }
                .joined(separator: ", ") ?? ""
            feedEntry.imageUrl = imageUrl
            feedEntry.sourceIconURL = sourceIconURL
            feedEntry.publicationDate = item.published ?? item.updated
            feedEntry.html = item.content?.value
            feedEntry.voiceFrameUrl = voiceFrameUrl
            feedEntry.voiceAudioURL = voiceAudioURLs.first ?? feedEntry.voiceAudioURL
            feedEntry.audioSubtitlesURL = audioSubtitlesURL
            feedEntry.audioSubtitlesRoleRawValue = audioSubtitlesURL != nil ? AudioSubtitlesRole.content.rawValue : nil
            feedEntry.redditTranslationsUrl = redditTranslationsUrl
            feedEntry.redditTranslationsTitle = redditTranslationsTitle
            feedEntry.readerContentKind = entryContentKind
            if let collection = (item.categories ?? [])
                .compactMap({ category -> FeedEntryCollection? in
                    guard
                        let scheme = category.attributes?.scheme,
                        let term = category.attributes?.term
                    else { return nil }
                    return collectionsBySchemeAndTerm["\(scheme)\n\(term)"]
                })
                .first {
                feedEntry.feedEntryCollectionKey = collection.compoundKey
                feedEntry.feedEntryCollectionScheme = collection.scheme
                feedEntry.feedEntryCollectionTerm = collection.term
                feedEntry.feedEntryCollectionTitle = collection.title
            }
            feedEntry.updateCompoundKey()
            incomingIDs.append(feedEntry.compoundKey)
            return feedEntry
        }
        logRSS(
            "stage=persist.atom.mapped feedID=\(feedID.uuidString) url=\(rssUrl.absoluteString) inputItems=\(atomItems.count) mappedEntries=\(feedEntries.count) skippedInvalidURL=\(skippedItems) deleteOrphans=\(deleteOrphans)"
        )
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
            if !collectionObjects.isEmpty {
                try await realm.asyncWrite {
                    for collection in collectionObjects {
                        if let existing = realm.object(ofType: FeedEntryCollection.self, forPrimaryKey: collection.compoundKey) {
                            collection.createdAt = existing.createdAt
                        }
                    }
                    realm.add(collectionObjects, update: .modified)
                    if deleteOrphans {
                        let collectionOrphans = realm.objects(FeedEntryCollection.self)
                            .where { $0.feedID == feedID && !$0.isDeleted && !$0.compoundKey.in(incomingCollectionKeys) }
                        for orphan in collectionOrphans {
                            orphan.isDeleted = true
                            orphan.refreshChangeMetadata(explicitlyModified: true)
                        }
                    }
                }
            }
            
            let existingEntryIDs = Array(
                realm.objects(FeedEntry.self)
                    .where { $0.feedID == feedID }
                    .filter { !$0.isDeleted }
                    .map { $0.compoundKey }
            )
            logRSS(
                "stage=persist.atom.beforeUpsert feedID=\(feedID.uuidString) existingEntries=\(existingEntryIDs.count) incomingEntries=\(incomingIDs.count)"
            )
            
            let payloads = try await upsertFeedEntries(
                realm: realm,
                entries: feedEntries,
                existingEntryIDs: existingEntryIDs,
                incomingIDs: incomingIDs,
                deleteOrphans: deleteOrphans
            )
            for payload in payloads {
                try await syncRelatedReaderContent(with: payload)
            }
            logRSS(
                "stage=persist.atom.finished feedID=\(feedID.uuidString) payloadsSynced=\(payloads.count)"
            )
        }()
    }
    
    @MainActor
    func fetch(realmConfiguration: Realm.Configuration) async throws {
        let feedID = id
        let feedTitle = title
        let rssUrl = rssUrl
        let lastFetchedETag = lastFetchedETag
        let lastFetchedModifiedAt = lastFetchedModifiedAt
        let lastRefreshedEntriesAt = lastRefreshedEntriesAt
        logRSS(
            "stage=fetch.start feedID=\(feedID.uuidString) title=\(feedTitle) url=\(rssUrl.absoluteString) lastRefresh=\(lastRefreshedEntriesAt?.description ?? "nil") etag=\(lastFetchedETag ?? "nil") lastModified=\(lastFetchedModifiedAt?.description ?? "nil") deleteOrphans=\(deleteOrphans)"
        )
        let fetchResult: FeedFetchResult
        do {
            fetchResult = try await getRssData(
                rssUrl: rssUrl,
                lastFetchedETag: lastFetchedETag,
                lastFetchedModifiedAt: lastFetchedModifiedAt
            )
        } catch {
            logRSS("stage=fetch.download.error feedID=\(feedID.uuidString) url=\(rssUrl.absoluteString) error=\(error)")
            throw error
        }
        switch fetchResult {
        case .notModified(let metadata):
            logRSS("stage=fetch.notModified feedID=\(feedID.uuidString) url=\(rssUrl.absoluteString)")
            try await persistFetchMetadata(metadata, realmConfiguration: realmConfiguration)
            logRSS("stage=fetch.finished feedID=\(feedID.uuidString) url=\(rssUrl.absoluteString) result=notModified")
            return
        case .fetched(var rssData, let metadata):
            logRSS("stage=fetch.fetched feedID=\(feedID.uuidString) url=\(rssUrl.absoluteString) bytesBeforeClean=\(rssData.count)")
            rssData = cleanRssData(rssData)
            logRSS("stage=fetch.cleaned feedID=\(feedID.uuidString) url=\(rssUrl.absoluteString) bytesAfterClean=\(rssData.count)")
            let parser = FeedKit.FeedParser(data: rssData)
            switch parser.parse() {
            case .success(let feed):
                do {
                    switch feed {
                    case .rss(let rssFeed):
                        guard let items = rssFeed.items else {
                            logRSS("stage=parse.rss.error feedID=\(feedID.uuidString) url=\(rssUrl.absoluteString) reason=missingItems")
                            throw FeedError.parserFailed
                        }
                        logRSS("stage=parse.rss.success feedID=\(feedID.uuidString) url=\(rssUrl.absoluteString) items=\(items.count)")
                        try await persist(rssItems: items, realmConfiguration: realmConfiguration, deleteOrphans: deleteOrphans)
                        try await persistFetchMetadata(metadata, realmConfiguration: realmConfiguration)
                        logRSS("stage=fetch.finished feedID=\(feedID.uuidString) url=\(rssUrl.absoluteString) result=rss")
                    case .atom(let atomFeed):
                        guard let items = atomFeed.entries else {
                            logRSS("stage=parse.atom.error feedID=\(feedID.uuidString) url=\(rssUrl.absoluteString) reason=missingEntries")
                            throw FeedError.parserFailed
                        }
                        logRSS("stage=parse.atom.success feedID=\(feedID.uuidString) url=\(rssUrl.absoluteString) entries=\(items.count)")
                        try await persist(
                            atomItems: items,
                            collections: parseManabiAtomCollections(from: rssData),
                            realmConfiguration: realmConfiguration,
                            deleteOrphans: deleteOrphans
                        )
                        try await persistFetchMetadata(metadata, realmConfiguration: realmConfiguration)
                        logRSS("stage=fetch.finished feedID=\(feedID.uuidString) url=\(rssUrl.absoluteString) result=atom")
                    case .json:
                        logRSS("stage=parse.json.unsupported feedID=\(feedID.uuidString) url=\(rssUrl.absoluteString)")
                        throw FeedError.parserFailed
                    }
                } catch {
                    logRSS("stage=fetch.persist.error feedID=\(feedID.uuidString) url=\(rssUrl.absoluteString) error=\(error)")
                    throw error
                }
            case .failure:
                logRSS("stage=parse.failure feedID=\(feedID.uuidString) url=\(rssUrl.absoluteString)")
                throw FeedError.parserFailed
            }
        }
    }
}

@RealmBackgroundActor
fileprivate func filterEntriesToPersist(realm: Realm, entries: [FeedEntry]) async throws -> [FeedEntry] {
    var differentEntries: [FeedEntry] = []
    let compoundKeys = entries.map { $0.compoundKey }
    
    let existingEntries = realm.objects(FeedEntry.self).where { $0.compoundKey.in(compoundKeys) }
    let existingEntriesDict = Dictionary(uniqueKeysWithValues: existingEntries.map { ($0.compoundKey, $0) })
    
    for entry in entries {
        if let existingEntry = existingEntriesDict[entry.compoundKey] {
            let schema = entry.objectSchema
            for property in schema.properties where property.name != "createdAt" && property.name != "modifiedAt" {
                let propertyName = property.name
                if property.type == .object, let objectType = property.objectClassName {
                    let primaryKey = realm.schema[objectType]?.primaryKeyProperty?.name ?? ""
                    if let entryValue = entry.value(forKey: propertyName) as? Object,
                       let existingValue = existingEntry.value(forKey: propertyName) as? Object {
                        if entryValue.value(forKey: primaryKey) as? String != existingValue.value(forKey: primaryKey) as? String {
                            differentEntries.append(entry)
                            break
                        }
                    }
                } else if property.type == .data {
                    if let entryData = entry.value(forKey: propertyName) as? Data,
                       let existingData = existingEntry.value(forKey: propertyName) as? Data {
                        if entryData != existingData {
                            differentEntries.append(entry)
                            break
                        }
                    } else if (entry.value(forKey: propertyName) as? Data) != (existingEntry.value(forKey: propertyName) as? Data) {
                        differentEntries.append(entry)
                        break
                    }
                } else if property.isArray {
                    switch property.type {
                    case .string:
                        if let entryList = entry.value(forKey: propertyName) as? List<String>,
                           let existingList = existingEntry.value(forKey: propertyName) as? List<String> {
                            if entryList != existingList {
                                differentEntries.append(entry)
                                break
                            }
                        }
                    default:
                        fatalError("Comparison for \(property.type) property type for feed entries not currently supported")
                    }
                } else if entry.value(forKey: propertyName) as? NSObject != existingEntry.value(forKey: propertyName) as? NSObject {
                    differentEntries.append(entry)
                    break
                }
            }
        } else {
            differentEntries.append(entry)
        }
    }
    
    return differentEntries
}

@RealmBackgroundActor
fileprivate func upsertFeedEntries(
    realm: Realm,
    entries: [FeedEntry],
    existingEntryIDs: [String],
    incomingIDs: [String],
    deleteOrphans: Bool
) async throws -> [FeedEntryPayload] {
    let entriesToPersist = try await filterEntriesToPersist(realm: realm, entries: entries)
    let feedIDDescription = entries.first?.feedID?.uuidString ?? "nil"
    logRSS(
        "stage=upsert.filtered feedID=\(feedIDDescription) incomingEntries=\(entries.count) existingEntries=\(existingEntryIDs.count) changedOrNewEntries=\(entriesToPersist.count) deleteOrphans=\(deleteOrphans)"
    )
    if !deleteOrphans && entriesToPersist.isEmpty {
        logRSS("stage=upsert.skipped feedID=\(feedIDDescription) reason=noChangedEntries")
        return []
    }

    let payloads: [FeedEntryPayload]
    if entriesToPersist.isEmpty {
        payloads = []
    } else {
        let existingByKey: [String: FeedEntry] = Dictionary(
            uniqueKeysWithValues:
                realm.objects(FeedEntry.self)
                    .where { $0.compoundKey.in(entriesToPersist.map(\.compoundKey)) }
                    .map { ($0.compoundKey, $0) }
        )
        payloads = entriesToPersist.map { entry in
            FeedEntryPayload(entry: entry, existing: existingByKey[entry.compoundKey])
        }
    }

    await realm.asyncRefresh()
    try await realm.asyncWrite {
        var orphanCount = 0
        if deleteOrphans {
            let orphans = realm.objects(FeedEntry.self)
                .where { !$0.isDeleted && $0.compoundKey.in(existingEntryIDs) && !$0.compoundKey.in(incomingIDs) }
            for orphan in orphans {
                orphan.isDeleted = true
                orphan.refreshChangeMetadata(explicitlyModified: true)
                orphanCount += 1
            }
        }

        var createdCount = 0
        var updatedCount = 0
        var unchangedPayloadCount = 0
        for payload in payloads {
            if let existing = realm.object(ofType: FeedEntry.self, forPrimaryKey: payload.compoundKey) {
                let existingSubtitle = existing.audioSubtitlesURL?.absoluteString ?? "nil"
                let payloadSubtitle = payload.audioSubtitlesURL?.absoluteString ?? "nil"
                debugPrint(
                    "# AUDIO-VTT feedEntry.refresh",
                    "url=\(payload.url)",
                    "existingSubtitle=\(existingSubtitle)",
                    "payloadSubtitle=\(payloadSubtitle)",
                    "willUpdate=\(existingSubtitle != payloadSubtitle)"
                )
                if applyPayload(payload, to: existing) {
                    existing.refreshChangeMetadata(explicitlyModified: true)
                    updatedCount += 1
                } else {
                    unchangedPayloadCount += 1
                }
            } else {
                let newEntry = FeedEntry()
                newEntry.compoundKey = payload.compoundKey
                newEntry.feedID = payload.feedID
                newEntry.url = payload.url
                newEntry.createdAt = payload.createdAt
                debugPrint(
                    "# AUDIO-VTT feedEntry.create",
                    "url=\(payload.url)",
                    "subtitle=\(payload.audioSubtitlesURL?.absoluteString ?? "nil")"
                )
                applyPayload(payload, to: newEntry)
                realm.add(newEntry, update: .error)
                newEntry.refreshChangeMetadata(explicitlyModified: true)
                createdCount += 1
            }
        }
        logRSS(
            "stage=upsert.write feedID=\(feedIDDescription) created=\(createdCount) updated=\(updatedCount) unchangedPayloads=\(unchangedPayloadCount) deletedOrphans=\(orphanCount)"
        )
    }

    return payloads
}

fileprivate struct FeedEntryPayload {
    let compoundKey: String
    let feedID: UUID?
    let url: URL
    let title: String
    let author: String
    let imageUrl: URL?
    let sourceIconURL: URL?
    let publicationDate: Date?
    let content: Data?
    let voiceFrameUrl: URL?
    let voiceAudioURL: URL?
    let voiceAudioURLs: [URL]
    let audioSubtitlesURL: URL?
    let audioSubtitlesRoleRawValue: String?
    let primaryMediaIdentity: String?
    let primaryMediaSourceURL: URL?
    let primaryMediaKindRawValue: String?
    let primaryMediaDuration: Double?
    let primaryMediaLastPlaybackTime: Double?
    let offlineMediaID: String?
    let redditTranslationsUrl: URL?
    let redditTranslationsTitle: String?
    let autoOpenMediaPlayer: Bool
    let readerContentKindRawValue: String
    let feedEntryCollectionKey: String?
    let feedEntryCollectionScheme: String?
    let feedEntryCollectionTerm: String?
    let feedEntryCollectionTitle: String?
    let createdAt: Date

    init(entry: FeedEntry, existing: FeedEntry?) {
        compoundKey = entry.compoundKey
        feedID = entry.feedID
        url = entry.url
        title = entry.title
        author = entry.author
        imageUrl = entry.imageUrl
        sourceIconURL = entry.sourceIconURL
        publicationDate = entry.publicationDate
        content = entry.content
        voiceFrameUrl = entry.voiceFrameUrl
        voiceAudioURL = entry.voiceAudioURL
        voiceAudioURLs = entry.resolvedVoiceAudioURLs
        audioSubtitlesURL = entry.audioSubtitlesURL
        audioSubtitlesRoleRawValue = entry.audioSubtitlesRoleRawValue
            ?? (entry.audioSubtitlesURL != nil ? AudioSubtitlesRole.content.rawValue : nil)
        primaryMediaIdentity = entry.primaryMediaIdentity
        primaryMediaSourceURL = entry.primaryMediaSourceURL
        primaryMediaKindRawValue = entry.primaryMediaKindRawValue
        primaryMediaDuration = entry.primaryMediaDuration
        primaryMediaLastPlaybackTime = entry.primaryMediaLastPlaybackTime
        offlineMediaID = entry.offlineMediaID
        redditTranslationsUrl = entry.redditTranslationsUrl
        redditTranslationsTitle = entry.redditTranslationsTitle
        autoOpenMediaPlayer = entry.autoOpenMediaPlayer
        readerContentKindRawValue = entry.readerContentKindRawValue
        feedEntryCollectionKey = entry.feedEntryCollectionKey
        feedEntryCollectionScheme = entry.feedEntryCollectionScheme
        feedEntryCollectionTerm = entry.feedEntryCollectionTerm
        feedEntryCollectionTitle = entry.feedEntryCollectionTitle
        createdAt = existing?.createdAt ?? entry.createdAt
    }
}

@discardableResult
fileprivate func applyPayload(_ payload: FeedEntryPayload, to content: any ReaderContentProtocol) -> Bool {
    var didChange = false
    if content.title != payload.title {
        content.title = payload.title
        didChange = true
    }
    if content.author != payload.author {
        content.author = payload.author
        didChange = true
    }
    if content.imageUrl != payload.imageUrl {
        content.imageUrl = payload.imageUrl
        didChange = true
    }
    if content.sourceIconURL != payload.sourceIconURL {
        content.sourceIconURL = payload.sourceIconURL
        didChange = true
    }
    if content.publicationDate != payload.publicationDate {
        content.publicationDate = payload.publicationDate
        didChange = true
    }
    if content.content != payload.content {
        content.content = payload.content
        didChange = true
    }
    if content.voiceFrameUrl != payload.voiceFrameUrl {
        content.voiceFrameUrl = payload.voiceFrameUrl
        didChange = true
    }
    let targetType = String(describing: type(of: content))
    if content.audioSubtitlesURL != payload.audioSubtitlesURL {
        let oldValue = content.audioSubtitlesURL?.absoluteString ?? "nil"
        let newValue = payload.audioSubtitlesURL?.absoluteString ?? "nil"
        debugPrint(
            "# AUDIO-VTT readerContent.updateSubtitle",
            "url=\(content.url)",
            "old=\(oldValue)",
            "new=\(newValue)",
            "target=\(targetType)"
        )
        content.audioSubtitlesURL = payload.audioSubtitlesURL
        didChange = true
    } else {
        debugPrint(
            "# AUDIO-VTT readerContent.updateSubtitle.skip",
            "url=\(content.url)",
            "value=\(content.audioSubtitlesURL?.absoluteString ?? "nil")",
            "target=\(targetType)"
        )
    }
    if content.audioSubtitlesRoleRawValue != payload.audioSubtitlesRoleRawValue {
        content.audioSubtitlesRoleRawValue = payload.audioSubtitlesRoleRawValue
        didChange = true
    }
    if content.voiceAudioURL != payload.voiceAudioURL {
        content.voiceAudioURL = payload.voiceAudioURL
        didChange = true
    }
    let existingVoiceAudioURLs = Array(content.voiceAudioURLs)
    if existingVoiceAudioURLs != payload.voiceAudioURLs {
        content.voiceAudioURLs.removeAll()
        content.voiceAudioURLs.append(objectsIn: payload.voiceAudioURLs)
        didChange = true
    }
    if content.primaryMediaIdentity != payload.primaryMediaIdentity {
        content.primaryMediaIdentity = payload.primaryMediaIdentity
        didChange = true
    }
    if content.primaryMediaSourceURL != payload.primaryMediaSourceURL {
        content.primaryMediaSourceURL = payload.primaryMediaSourceURL
        didChange = true
    }
    if content.primaryMediaKindRawValue != payload.primaryMediaKindRawValue {
        content.primaryMediaKindRawValue = payload.primaryMediaKindRawValue
        didChange = true
    }
    if content.primaryMediaDuration != payload.primaryMediaDuration {
        content.primaryMediaDuration = payload.primaryMediaDuration
        didChange = true
    }
    if content.primaryMediaLastPlaybackTime != payload.primaryMediaLastPlaybackTime {
        content.primaryMediaLastPlaybackTime = payload.primaryMediaLastPlaybackTime
        didChange = true
    }
    if content.offlineMediaID != payload.offlineMediaID {
        content.offlineMediaID = payload.offlineMediaID
        didChange = true
    }
    if content.redditTranslationsUrl != payload.redditTranslationsUrl {
        content.redditTranslationsUrl = payload.redditTranslationsUrl
        didChange = true
    }
    if content.redditTranslationsTitle != payload.redditTranslationsTitle {
        content.redditTranslationsTitle = payload.redditTranslationsTitle
        didChange = true
    }
    if content.autoOpenMediaPlayer != payload.autoOpenMediaPlayer {
        content.autoOpenMediaPlayer = payload.autoOpenMediaPlayer
        didChange = true
    }
    if content.readerContentKindRawValue != payload.readerContentKindRawValue {
        content.readerContentKindRawValue = payload.readerContentKindRawValue
        didChange = true
    }
    if content.feedEntryCollectionKey != payload.feedEntryCollectionKey {
        content.feedEntryCollectionKey = payload.feedEntryCollectionKey
        didChange = true
    }
    if content.feedEntryCollectionScheme != payload.feedEntryCollectionScheme {
        content.feedEntryCollectionScheme = payload.feedEntryCollectionScheme
        didChange = true
    }
    if content.feedEntryCollectionTerm != payload.feedEntryCollectionTerm {
        content.feedEntryCollectionTerm = payload.feedEntryCollectionTerm
        didChange = true
    }
    if content.feedEntryCollectionTitle != payload.feedEntryCollectionTitle {
        content.feedEntryCollectionTitle = payload.feedEntryCollectionTitle
        didChange = true
    }
    return didChange
}

@RealmBackgroundActor
fileprivate func syncRelatedReaderContent(with payload: FeedEntryPayload) async throws {
    let mirrors = try await ReaderContentLoader.loadAll(url: payload.url, skipFeedEntries: true)
    debugPrint(
        "# AUDIO-VTT readerContent.sync.start",
        "url=\(payload.url)",
        "mirrorCount=\(mirrors.count)"
    )
    for case let object as (Object & ReaderContentProtocol) in mirrors {
        guard let realm = object.realm else {
            debugPrint(
                "# AUDIO-VTT readerContent.sync.skip",
                "url=\(payload.url)",
                "reason=objectHasNoRealm",
                "type=\(String(describing: type(of: object)))"
            )
            continue
        }
        try await realm.asyncWrite {
            if applyPayload(payload, to: object) {
                object.refreshChangeMetadata(explicitlyModified: true)
            }
        }
    }
    debugPrint(
        "# AUDIO-VTT readerContent.sync.complete",
        "url=\(payload.url)",
        "mirrorCount=\(mirrors.count)"
    )
}

fileprivate func cleanRssData(_ rssData: Data) -> Data {
    guard let rssString = String(data: rssData, encoding: .utf8) else { return rssData }
    let cleanedString = rssString.replacingOccurrences(of: "<前編>", with: "&lt;前編&gt;")
    return cleanedString.data(using: .utf8) ?? rssData
}
