import Foundation
import LakeOfFireCore
import RealmSwift
import SwiftSoup
import BigSyncKit
import FeedKit
import RealmSwiftGaps

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
        return realm.objects(Feed.self).where { $0.categoryID == id && !$0.isDeleted }
            .sorted(by: \.title)
            .map { $0 }
    }
    
    public func isEmpty() -> Bool {
        guard let realm else {
            print("Warning: Unexpectedly unmanaged object")
            return true
        }
        return realm.objects(Feed.self).where { $0.categoryID == id && !$0.isDeleted }.first == nil
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
    @Persisted public var order: Double?

    @Persisted public var explicitlyModifiedAt: Date?
    @Persisted public var createdAt = Date()
    @Persisted public var modifiedAt = Date()
    @Persisted public var isDeleted = false

    public static func makePrimaryKey(feedID: UUID, scheme: String, term: String) -> String {
        [feedID.uuidString, scheme, term].joined(separator: "|")
    }

    public func updateCompoundKey() {
        guard let feedID else { return }
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
            .sorted { lhs, rhs in
                switch (lhs.order, rhs.order) {
                case let (l?, r?) where l != r:
                    return l > r
                case (nil, _?):
                    return false
                case (_?, nil):
                    return true
                default:
                    if lhs.publicationDate != rhs.publicationDate {
                        return (lhs.publicationDate ?? .distantPast) > (rhs.publicationDate ?? .distantPast)
                    }
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
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

        for feed in feeds where !feed.isDeleted && !feed.isArchived {
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
        return latestHistoryLastVisitedAt == nil
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
    
    @Persisted public var url: URL
    @Persisted public var title = ""
    @Persisted public var isTitlePrefixOfContent = false
    @Persisted public var author = ""
    @Persisted public var imageUrl: URL?
    @Persisted public var sourceIconURL: URL?
    @Persisted(indexed: true) public var publicationDate: Date?
    @Persisted public var readerContentKindRawValue = ReaderContentKind.readerContent.rawValue
    @Persisted public var feedEntryCollectionKey: String?
    @Persisted public var feedEntryCollectionScheme: String?
    @Persisted public var feedEntryCollectionTerm: String?
    @Persisted public var feedEntryCollectionTitle: String?
    @Persisted public var isPhysicalMedia = false
    
    @Persisted public var isReaderModeOfferHidden = false
    //    @Persisted public var isFromClipboard = false
    @Persisted public var content: Data?
    //    @Persisted public var readerModeAvailabilityOverride: Bool? = nil
    
    public var isFromClipboard = false
    
    public var isReaderModeAvailable: Bool {
        get { return isReaderModeByDefault }
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
    @Persisted public var redditTranslationsUrl: URL?
    @Persisted public var redditTranslationsTitle: String?
    @Persisted public var autoOpenMediaPlayer = false
    
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
    
    public var locationBarTitle: String? {
        url.normalizedHost() ?? url.absoluteString
    }

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
                let legacyHTMLContent = htmlContent
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
            preservingExistingVoiceAudioURL: false,
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

private func logNiponica(_ message: String) {
#if DEBUG
    debugPrint("# NIPONICA \(message)")
#endif
}

private func isNiponicaFeedURL(_ url: URL) -> Bool {
    url.absoluteString.localizedCaseInsensitiveContains("niponica")
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

fileprivate enum FeedFetchResult {
    case notModified(metadata: FeedFetchMetadata)
    case fetched(Data, metadata: FeedFetchMetadata)
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

    func compoundKey(feedID: UUID) -> String {
        FeedEntryCollection.makePrimaryKey(feedID: feedID, scheme: scheme, term: term)
    }
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
        let imageUrl = (attributeDict["cover"] ?? attributeDict["image"])
            .flatMap { URL(string: $0) }
        let url = (attributeDict["href"] ?? attributeDict["url"])
            .flatMap { URL(string: $0) }
        let publicationDate = (attributeDict["published"] ?? attributeDict["updated"] ?? attributeDict["date"])
            .flatMap(Self.parseDate)
        let resolvedTitle = title?.isEmpty == false ? title! : term

        collections.append(
            ParsedFeedEntryCollection(
                scheme: scheme,
                term: term,
                title: resolvedTitle,
                summary: summary?.isEmpty == false ? summary : nil,
                imageUrl: imageUrl,
                url: url,
                publicationDate: publicationDate,
                order: attributeDict["order"].flatMap(Double.init)
            )
        )
    }

    private static func parseDate(_ rawValue: String) -> Date? {
        dateTimeWithFractionalSeconds.date(from: rawValue)
            ?? dateTime.date(from: rawValue)
            ?? dateOnly.date(from: rawValue)
    }

    private static let dateTimeWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let dateTime: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let dateOnly: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()
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

fileprivate let feedHTTPDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter
}()

fileprivate func makeFeedSession() -> URLSession {
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
            feedHTTPDateFormatter.string(from: lastFetchedModifiedAt),
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
        .flatMap { feedHTTPDateFormatter.date(from: $0) }
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
    let shouldLogNiponica = isNiponicaFeedURL(rssUrl)
    if shouldLogNiponica {
        logNiponica(
            "stage=feedFetch.http.begin rssURL=\(rssUrl.absoluteString) lastFetchedETag=\(lastFetchedETag ?? "nil") lastFetchedModifiedAt=\(lastFetchedModifiedAt?.description ?? "nil")"
        )
    }
    let session = makeFeedSession()
    let headRequest = makeFeedRequest(
        url: rssUrl,
        method: "HEAD",
        lastFetchedETag: lastFetchedETag,
        lastFetchedModifiedAt: lastFetchedModifiedAt
    )
    let (_, headResponse) = try await session.data(for: headRequest)
    guard let headHTTPResponse = headResponse as? HTTPURLResponse else {
        if shouldLogNiponica {
            logNiponica("stage=feedFetch.http.error rssURL=\(rssUrl.absoluteString) phase=head reason=nonHTTPResponse response=\(String(describing: headResponse))")
        }
        throw FeedError.downloadFailed
    }

    let headMetadata = feedFetchMetadata(from: headHTTPResponse)
    if shouldLogNiponica {
        logNiponica(
            "stage=feedFetch.http.head rssURL=\(rssUrl.absoluteString) status=\(headHTTPResponse.statusCode) contentType=\(headHTTPResponse.value(forHTTPHeaderField: "Content-Type") ?? "nil") contentLength=\(headHTTPResponse.value(forHTTPHeaderField: "Content-Length") ?? "nil") etag=\(headMetadata.etag ?? "nil") lastModifiedAt=\(headMetadata.lastModifiedAt?.description ?? "nil")"
        )
    }
    switch headHTTPResponse.statusCode {
    case 304:
        if shouldLogNiponica {
            logNiponica("stage=feedFetch.http.notModified rssURL=\(rssUrl.absoluteString) phase=head status=304")
        }
        return .notModified(metadata: headMetadata)
    case let statusCode where isSuccessfulFeedRefreshStatus(statusCode):
        if isFeedUnchanged(
            remoteMetadata: headMetadata,
            lastFetchedETag: lastFetchedETag,
            lastFetchedModifiedAt: lastFetchedModifiedAt
        ) {
            if shouldLogNiponica {
                logNiponica(
                    "stage=feedFetch.http.notModified rssURL=\(rssUrl.absoluteString) phase=head status=\(statusCode) reason=metadataUnchanged"
                )
            }
            return .notModified(metadata: headMetadata)
        }
    default:
        if shouldLogNiponica {
            logNiponica("stage=feedFetch.http.error rssURL=\(rssUrl.absoluteString) phase=head status=\(headHTTPResponse.statusCode) reason=badStatus")
        }
        throw FeedError.downloadFailed
    }

    let getRequest = makeFeedRequest(
        url: rssUrl,
        method: "GET",
        lastFetchedETag: lastFetchedETag,
        lastFetchedModifiedAt: lastFetchedModifiedAt
    )
    let (data, getResponse) = try await session.data(for: getRequest)
    guard let getHTTPResponse = getResponse as? HTTPURLResponse else {
        if shouldLogNiponica {
            logNiponica("stage=feedFetch.http.error rssURL=\(rssUrl.absoluteString) phase=get reason=nonHTTPResponse response=\(String(describing: getResponse))")
        }
        throw FeedError.downloadFailed
    }

    let getMetadata = headMetadata.merged(with: feedFetchMetadata(from: getHTTPResponse))
    if shouldLogNiponica {
        logNiponica(
            "stage=feedFetch.http.get rssURL=\(rssUrl.absoluteString) status=\(getHTTPResponse.statusCode) bytes=\(data.count) contentType=\(getHTTPResponse.value(forHTTPHeaderField: "Content-Type") ?? "nil") contentLength=\(getHTTPResponse.value(forHTTPHeaderField: "Content-Length") ?? "nil") etag=\(getMetadata.etag ?? "nil") lastModifiedAt=\(getMetadata.lastModifiedAt?.description ?? "nil")"
        )
    }
    switch getHTTPResponse.statusCode {
    case 304:
        if shouldLogNiponica {
            logNiponica("stage=feedFetch.http.notModified rssURL=\(rssUrl.absoluteString) phase=get status=304")
        }
        return .notModified(metadata: getMetadata)
    case 200..<300:
        return .fetched(data, metadata: getMetadata)
    case 300..<400:
        if shouldLogNiponica {
            logNiponica("stage=feedFetch.http.notModified rssURL=\(rssUrl.absoluteString) phase=get status=\(getHTTPResponse.statusCode) reason=redirectStatus")
        }
        return .notModified(metadata: getMetadata)
    default:
        if shouldLogNiponica {
            logNiponica("stage=feedFetch.http.error rssURL=\(rssUrl.absoluteString) phase=get status=\(getHTTPResponse.statusCode) reason=badStatus")
        }
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
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
            await realm.asyncRefresh()
            try await realm.asyncWrite {
                guard let feed = realm.object(ofType: Feed.self, forPrimaryKey: feedID) else { return }
                feed.lastRefreshedEntriesAt = Date()
                feed.lastFetchedETag = metadata.etag ?? feed.lastFetchedETag
                feed.lastFetchedModifiedAt = metadata.lastModifiedAt ?? feed.lastFetchedModifiedAt
            }
        }()
    }

    @MainActor
    private func persist(rssItems: [RSSFeedItem], realmConfiguration: Realm.Configuration, deleteOrphans: Bool) async throws {
        let feedID = id
        let iconUrl = iconUrl
        let entryContentKind = entryContentKind
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
            let existingEntries = Array(
                realm.objects(FeedEntry.self)
                    .where { $0.feedID == feedID }
                    .filter { !$0.isDeleted }
                    .map { $0 }
            )
            
            let existingEntryIDs = existingEntries.map(\.compoundKey)
            
            var incomingIDs = [String]()
            let feedEntries: [FeedEntry] = rssItems.reversed().compactMap { item -> FeedEntry? in
                guard let link = item.link?.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
                      let url = URL(string: link)
                else { return nil }
                var imageUrl: URL? = nil
                if let enclosureAttribs = item.enclosure?.attributes, enclosureAttribs.type?.hasPrefix("image/") ?? false {
                    if let imageUrlRaw = enclosureAttribs.url {
                        imageUrl = URL(string: imageUrlRaw)
                    }
//                } else if let rawImageURL = item.media?.contents?
//                    .lazy.compactMap({ $0.attributes?.url })
//                    .first(where: { entryImageExtensions.contains(($0 as NSString).pathExtension.lowercased()) })
                } else if let rawImageURL = item.media?.mediaContents?
                    .lazy.compactMap({ $0.attributes?.url })
                    .first(where: { entryImageExtensions.contains(($0 as NSString).pathExtension.lowercased()) })
                {
                    imageUrl = URL(string: rawImageURL)
                }
                let content = item.content?.contentEncoded ?? item.description
                let rawSubtitleHref = item.media?.mediaSubTitle?.attributes?.href?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let audioSubtitlesURL: URL? = rawSubtitleHref
                    .flatMap { rawValue in
                        guard !rawValue.isEmpty else { return nil }
                        return URL(string: rawValue)
                            ?? rawValue.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:))
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
//                
//                if let existingEntry = realm.object(ofType: FeedEntry.self, forPrimaryKey: FeedEntry.makePrimaryKey(url: url, html: content)) {
//                    if existingEntry.feedID == feedID && existingEntry.html == content && existingEntry.url == url && existingEntry.title == title ?? "" && existingEntry.author == item.author ?? "" && existingEntry.imageUrl == imageUrl && existingEntry.publicationDate == item.pubDate ?? item.dublinCore?.dcDate {
//                        return exi
//                    }
//                }
                
                let feedEntry = FeedEntry()
                feedEntry.feedID = feedID
                feedEntry.html = content
                feedEntry.url = url
                feedEntry.title = title ?? ""
                feedEntry.author = item.author ?? ""
                feedEntry.imageUrl = imageUrl
                feedEntry.sourceIconURL = iconUrl
                feedEntry.publicationDate = item.pubDate ?? item.dublinCore?.dcDate
                feedEntry.readerContentKind = entryContentKind
                feedEntry.audioSubtitlesURL = audioSubtitlesURL
                feedEntry.audioSubtitlesRoleRawValue = audioSubtitlesURL != nil ? AudioSubtitlesRole.content.rawValue : nil
                feedEntry.updateCompoundKey()
                incomingIDs.append(feedEntry.compoundKey)
                return feedEntry
            }
            if deleteOrphans {
                await realm.asyncRefresh()
                try await realm.asyncWrite {
                    let orphans = realm.objects(FeedEntry.self)
                        .where { !$0.isDeleted && $0.compoundKey.in(existingEntryIDs) && !$0.compoundKey.in(incomingIDs) }
                    for orphan in orphans {
                        orphan.isDeleted = true
                        orphan.refreshChangeMetadata(explicitlyModified: true)
                    }
                }
            }
            let entriesToPersist = try await filterEntriesToPersist(realm: realm, entries: feedEntries)
            let payloads = entriesToPersist.map(FeedEntryPayload.init)
            debugPrint(
                "# FEEDNEW stage=feed.fetch.persist.rss",
                "feedID=\(feedID.uuidString)",
                "title=\(title)",
                "existingCount=\(existingEntries.count)",
                "incomingCount=\(feedEntries.count)",
                "newOrChangedCount=\(entriesToPersist.count)",
                "orphansCandidateCount=\(max(existingEntryIDs.count - incomingIDs.count, 0))",
                "existingLatestCreatedAt=\(existingEntries.map { $0.createdAt }.max()?.description ?? "nil")",
                "existingLatestPublicationDate=\(existingEntries.compactMap { $0.publicationDate }.max()?.description ?? "nil")",
                "incomingLatestPublicationDate=\(feedEntries.compactMap { $0.publicationDate }.max()?.description ?? "nil")"
            )
            if !entriesToPersist.isEmpty {
                await realm.asyncRefresh()
                try await realm.asyncWrite {
                    for entry in entriesToPersist {
                        if let existing = realm.object(ofType: FeedEntry.self, forPrimaryKey: entry.compoundKey) {
                            entry.createdAt = existing.createdAt
                        }
                    }
                    realm.add(entriesToPersist, update: .modified)
                }
            }
            for payload in payloads {
                try await syncRelatedReaderContent(with: payload)
            }
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
        let entryContentKind = entryContentKind
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
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
                collection.order = parsedCollection.order
                collection.updateCompoundKey()
                return collection
            }
            var collectionsBySchemeAndTerm = [String: FeedEntryCollection]()
            for collection in collectionObjects {
                collectionsBySchemeAndTerm["\(collection.scheme)\n\(collection.term)"] = collection
            }
            let incomingCollectionKeys = collectionObjects.map(\.compoundKey)
            let existingCollectionKeys = Array(
                realm.objects(FeedEntryCollection.self)
                    .where { $0.feedID == feedID && !$0.isDeleted }
                    .map(\.compoundKey)
            )
            let existingEntries = Array(
                realm.objects(FeedEntry.self)
                    .where { $0.feedID == feedID }
                    .filter { !$0.isDeleted }
                    .map { $0 }
            )
            
            let existingEntryIDs = existingEntries.map(\.compoundKey)
            
            var incomingIDs = [String]()
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
                guard let url = url else { return nil }
                
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

                let rawAtomSubtitleHref = item.links?
                    .first { link in
                        guard link.attributes?.rel == "voice-audio-subtitles" else { return false }
                        let normalizedType = link.attributes?.type?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .lowercased()
                        guard let normalizedType, !normalizedType.isEmpty else { return true }
                        return normalizedType.contains("vtt")
                    }?
                    .attributes?.href?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let audioSubtitlesURL: URL? = rawAtomSubtitleHref
                    .flatMap { rawValue in
                        guard !rawValue.isEmpty else { return nil }
                        return URL(string: rawValue)
                            ?? rawValue.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:))
                    }
                
                // TODO: Refactor into community commentary links
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

                let collection = item.categories?
                    .lazy
                    .compactMap { category -> FeedEntryCollection? in
                        guard
                            let scheme = category.attributes?.scheme,
                            let term = category.attributes?.term
                        else { return nil }
                        return collectionsBySchemeAndTerm["\(scheme)\n\(term)"]
                    }
                    .first
                
                let feedEntry = FeedEntry()
                feedEntry.feedID = feedID
                feedEntry.url = url
                feedEntry.title = title ?? ""
                feedEntry.author = item.authors?.compactMap { $0.name }
                    .joined(separator: ", ") ?? ""
                feedEntry.imageUrl = imageUrl
                feedEntry.sourceIconURL = sourceIconURL
                feedEntry.publicationDate = item.published ?? item.updated
                feedEntry.readerContentKind = entryContentKind
                feedEntry.feedEntryCollectionKey = collection?.compoundKey
                feedEntry.feedEntryCollectionScheme = collection?.scheme
                feedEntry.feedEntryCollectionTerm = collection?.term
                feedEntry.feedEntryCollectionTitle = collection?.title
                feedEntry.html = item.content?.value
                feedEntry.voiceFrameUrl = voiceFrameUrl
                feedEntry.voiceAudioURL = voiceAudioURLs.first
                feedEntry.voiceAudioURLs.append(objectsIn: voiceAudioURLs)
                feedEntry.audioSubtitlesURL = audioSubtitlesURL
                feedEntry.audioSubtitlesRoleRawValue = audioSubtitlesURL != nil ? AudioSubtitlesRole.content.rawValue : nil
                feedEntry.redditTranslationsUrl = redditTranslationsUrl
                feedEntry.redditTranslationsTitle = redditTranslationsTitle
                feedEntry.updateCompoundKey()
                incomingIDs.append(feedEntry.compoundKey)
                return feedEntry
            }
            let entriesToPersist = try await filterEntriesToPersist(realm: realm, entries: feedEntries)
            let payloads = entriesToPersist.map(FeedEntryPayload.init)
            debugPrint(
                "# FEEDNEW stage=feed.fetch.persist.atom",
                "feedID=\(feedID.uuidString)",
                "title=\(title)",
                "existingCount=\(existingEntries.count)",
                "incomingCount=\(feedEntries.count)",
                "newOrChangedCount=\(entriesToPersist.count)",
                "orphansCandidateCount=\(max(existingEntryIDs.count - incomingIDs.count, 0))",
                "existingLatestCreatedAt=\(existingEntries.map { $0.createdAt }.max()?.description ?? "nil")",
                "existingLatestPublicationDate=\(existingEntries.compactMap { $0.publicationDate }.max()?.description ?? "nil")",
                "incomingLatestPublicationDate=\(feedEntries.compactMap { $0.publicationDate }.max()?.description ?? "nil")"
            )
            if !entriesToPersist.isEmpty || !collectionObjects.isEmpty || deleteOrphans {
                await realm.asyncRefresh()
                try await realm.asyncWrite {
                    for collection in collectionObjects {
                        if let existing = realm.object(ofType: FeedEntryCollection.self, forPrimaryKey: collection.compoundKey) {
                            collection.createdAt = existing.createdAt
                        }
                    }
                    realm.add(collectionObjects, update: .modified)
                    if deleteOrphans {
                        let collectionOrphans = realm.objects(FeedEntryCollection.self)
                            .where { !$0.isDeleted && $0.compoundKey.in(existingCollectionKeys) && !$0.compoundKey.in(incomingCollectionKeys) }
                        for orphan in collectionOrphans {
                            orphan.isDeleted = true
                            orphan.refreshChangeMetadata(explicitlyModified: true)
                        }
                        let orphans = realm.objects(FeedEntry.self)
                            .where { !$0.isDeleted && $0.compoundKey.in(existingEntryIDs) && !$0.compoundKey.in(incomingIDs) }
                        for orphan in orphans {
                            orphan.isDeleted = true
                            orphan.refreshChangeMetadata(explicitlyModified: true)
                        }
                    }
                    for entry in entriesToPersist {
                        if let existing = realm.object(ofType: FeedEntry.self, forPrimaryKey: entry.compoundKey) {
                            entry.createdAt = existing.createdAt
                        }
                    }
                    realm.add(entriesToPersist, update: .modified)
                }
            }
            for payload in payloads {
                try await syncRelatedReaderContent(with: payload)
            }
        }()
    }
    
    @MainActor
    func fetch(realmConfiguration: Realm.Configuration) async throws {
        let shouldLogNiponica = title.localizedCaseInsensitiveContains("niponica")
            || isNiponicaFeedURL(rssUrl)
        if shouldLogNiponica {
            logNiponica(
                "stage=feed.fetch.begin feedID=\(id.uuidString) title=\(title) rssURL=\(rssUrl.absoluteString) lastViewedAt=\(lastViewedAt?.description ?? "nil") lastRefreshedEntriesAt=\(lastRefreshedEntriesAt?.description ?? "nil") lastFetchedModifiedAt=\(lastFetchedModifiedAt?.description ?? "nil") lastFetchedETag=\(lastFetchedETag ?? "nil")"
            )
        }
        debugPrint(
            "# FEEDNEW stage=feed.fetch.begin",
            "feedID=\(id.uuidString)",
            "title=\(title)",
            "lastViewedAt=\(lastViewedAt?.description ?? "nil")",
            "lastRefreshedEntriesAt=\(lastRefreshedEntriesAt?.description ?? "nil")",
            "lastFetchedModifiedAt=\(lastFetchedModifiedAt?.description ?? "nil")",
            "lastFetchedETag=\(lastFetchedETag ?? "nil")"
        )
        let fetchResult: FeedFetchResult
        do {
            fetchResult = try await getRssData(
                rssUrl: rssUrl,
                lastFetchedETag: lastFetchedETag,
                lastFetchedModifiedAt: lastFetchedModifiedAt
            )
        } catch {
            if shouldLogNiponica {
                logNiponica(
                    "stage=feed.fetch.error feedID=\(id.uuidString) title=\(title) rssURL=\(rssUrl.absoluteString) phase=http error=\(String(describing: error)) localized=\(error.localizedDescription)"
                )
            }
            throw error
        }
        switch fetchResult {
        case .notModified(let metadata):
            if shouldLogNiponica {
                logNiponica(
                    "stage=feed.fetch.notModified feedID=\(id.uuidString) title=\(title) rssURL=\(rssUrl.absoluteString) etag=\(metadata.etag ?? "nil") lastModifiedAt=\(metadata.lastModifiedAt?.description ?? "nil")"
                )
            }
            debugPrint(
                "# FEEDNEW stage=feed.fetch.notModified",
                "feedID=\(id.uuidString)",
                "title=\(title)",
                "etag=\(metadata.etag ?? "nil")",
                "lastModifiedAt=\(metadata.lastModifiedAt?.description ?? "nil")"
            )
            try await persistFetchMetadata(metadata, realmConfiguration: realmConfiguration)
            return
        case .fetched(var rssData, let metadata):
            if shouldLogNiponica {
                logNiponica(
                    "stage=feed.fetch.fetched feedID=\(id.uuidString) title=\(title) rssURL=\(rssUrl.absoluteString) bytes=\(rssData.count) etag=\(metadata.etag ?? "nil") lastModifiedAt=\(metadata.lastModifiedAt?.description ?? "nil")"
                )
            }
            debugPrint(
                "# FEEDNEW stage=feed.fetch.fetched",
                "feedID=\(id.uuidString)",
                "title=\(title)",
                "bytes=\(rssData.count)",
                "etag=\(metadata.etag ?? "nil")",
                "lastModifiedAt=\(metadata.lastModifiedAt?.description ?? "nil")"
            )
            rssData = cleanRssData(rssData)
            let atomCollections = parseManabiAtomCollections(from: rssData)
            if shouldLogNiponica {
                logNiponica(
                    "stage=feed.fetch.preParse feedID=\(id.uuidString) title=\(title) rssURL=\(rssUrl.absoluteString) cleanedBytes=\(rssData.count) atomCollections=\(atomCollections.count)"
                )
            }
            let parser = FeedKit.FeedParser(data: rssData)
            return try await withCheckedThrowingContinuation({ (continuation: CheckedContinuation<(), Error>) in
                parser.parseAsync { parserResult in
                    switch parserResult {
                    case .success(let feed):
                        switch feed {
                        case .rss(let rssFeed):
                            guard let items = rssFeed.items else {
                                if shouldLogNiponica {
                                    logNiponica(
                                        "stage=feed.fetch.parserError feedID=\(self.id.uuidString) title=\(self.title) rssURL=\(self.rssUrl.absoluteString) feedType=rss reason=nilItems"
                                    )
                                }
                                continuation.resume(throwing: FeedError.parserFailed)
                                return
                            }
                            if shouldLogNiponica {
                                logNiponica(
                                    "stage=feed.fetch.parsed feedID=\(self.id.uuidString) title=\(self.title) rssURL=\(self.rssUrl.absoluteString) feedType=rss items=\(items.count)"
                                )
                            }
                            Task { @MainActor in
                                do {
                                    try await self.persist(rssItems: items, realmConfiguration: realmConfiguration, deleteOrphans: self.deleteOrphans)
                                    try await self.persistFetchMetadata(metadata, realmConfiguration: realmConfiguration)
                                    if shouldLogNiponica {
                                        logNiponica(
                                            "stage=feed.fetch.persisted feedID=\(self.id.uuidString) title=\(self.title) rssURL=\(self.rssUrl.absoluteString) feedType=rss items=\(items.count)"
                                        )
                                    }
                                    continuation.resume(returning: ())
                                } catch {
                                    if shouldLogNiponica {
                                        logNiponica(
                                            "stage=feed.fetch.error feedID=\(self.id.uuidString) title=\(self.title) rssURL=\(self.rssUrl.absoluteString) phase=persist feedType=rss error=\(String(describing: error)) localized=\(error.localizedDescription)"
                                        )
                                    }
                                    continuation.resume(throwing: error)
                                }
                            }
                            return
                        case .atom(let atomFeed):
                            guard let items = atomFeed.entries else {
                                if shouldLogNiponica {
                                    logNiponica(
                                        "stage=feed.fetch.parserError feedID=\(self.id.uuidString) title=\(self.title) rssURL=\(self.rssUrl.absoluteString) feedType=atom reason=nilEntries collections=\(atomCollections.count)"
                                    )
                                }
                                continuation.resume(throwing: FeedError.parserFailed)
                                return
                            }
                            if shouldLogNiponica {
                                logNiponica(
                                    "stage=feed.fetch.parsed feedID=\(self.id.uuidString) title=\(self.title) rssURL=\(self.rssUrl.absoluteString) feedType=atom entries=\(items.count) collections=\(atomCollections.count)"
                                )
                            }
                            Task { @MainActor in
                                do {
                                    try await self.persist(
                                        atomItems: items,
                                        collections: atomCollections,
                                        realmConfiguration: realmConfiguration,
                                        deleteOrphans: self.deleteOrphans
                                    )
                                    try await self.persistFetchMetadata(metadata, realmConfiguration: realmConfiguration)
                                    if shouldLogNiponica {
                                        logNiponica(
                                            "stage=feed.fetch.persisted feedID=\(self.id.uuidString) title=\(self.title) rssURL=\(self.rssUrl.absoluteString) feedType=atom entries=\(items.count) collections=\(atomCollections.count)"
                                        )
                                    }
                                    continuation.resume(returning: ())
                                } catch {
                                    if shouldLogNiponica {
                                        logNiponica(
                                            "stage=feed.fetch.error feedID=\(self.id.uuidString) title=\(self.title) rssURL=\(self.rssUrl.absoluteString) phase=persist feedType=atom error=\(String(describing: error)) localized=\(error.localizedDescription)"
                                        )
                                    }
                                    continuation.resume(throwing: error)
                                }
                            }
                            return
                        case .json:
                            if shouldLogNiponica {
                                logNiponica(
                                    "stage=feed.fetch.parserError feedID=\(self.id.uuidString) title=\(self.title) rssURL=\(self.rssUrl.absoluteString) feedType=json reason=unsupported"
                                )
                            }
                            continuation.resume(throwing: FeedError.parserFailed)
                            return
                        }
                    case .failure(let error):
                        if shouldLogNiponica {
                            logNiponica(
                                "stage=feed.fetch.parserError feedID=\(self.id.uuidString) title=\(self.title) rssURL=\(self.rssUrl.absoluteString) feedType=unknown reason=parseFailure error=\(String(describing: error))"
                            )
                        }
                        continuation.resume(throwing: FeedError.parserFailed)
                        return
                    }
                }
            })
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
                    if let entryValue = entry[propertyName] as? Object,
                       let existingValue = existingEntry[propertyName] as? Object {
                        if entryValue[primaryKey] as? String != existingValue[primaryKey] as? String {
                            differentEntries.append(entry)
                            break
                        }
                    }
                } else if property.isArray {
                    switch property.type {
                    case .string:
                        if let entryList = entry[propertyName] as? List<String>,
                           let existingList = existingEntry[propertyName] as? List<String>,
                           entryList != existingList {
                            differentEntries.append(entry)
                            break
                        }
                        if let entryList = entry[propertyName] as? List<URL>,
                           let existingList = existingEntry[propertyName] as? List<URL>,
                           entryList.map(\.absoluteString) != existingList.map(\.absoluteString) {
                            differentEntries.append(entry)
                            break
                        }
                    default:
                        debugPrint(
                            "# FEED filterEntriesToPersist.unsupportedArrayType",
                            "property=\(propertyName)",
                            "type=\(property.type)"
                        )
                        differentEntries.append(entry)
                        break
                    }
                } else if entry[propertyName] as? NSObject != existingEntry[propertyName] as? NSObject {
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

fileprivate struct FeedEntryPayload {
    let url: URL
    let title: String
    let author: String
    let imageUrl: URL?
    let sourceIconURL: URL?
    let publicationDate: Date?
    let readerContentKindRawValue: String
    let feedEntryCollectionKey: String?
    let feedEntryCollectionScheme: String?
    let feedEntryCollectionTerm: String?
    let feedEntryCollectionTitle: String?
    let content: Data?
    let voiceFrameUrl: URL?
    let voiceAudioURL: URL?
    let voiceAudioURLs: [URL]
    let audioSubtitlesURL: URL?
    let audioSubtitlesRoleRawValue: String?
    let redditTranslationsUrl: URL?
    let redditTranslationsTitle: String?

    init(entry: FeedEntry) {
        url = entry.url
        title = entry.title
        author = entry.author
        imageUrl = entry.imageUrl
        sourceIconURL = entry.sourceIconURL
        publicationDate = entry.publicationDate
        readerContentKindRawValue = entry.readerContentKindRawValue
        feedEntryCollectionKey = entry.feedEntryCollectionKey
        feedEntryCollectionScheme = entry.feedEntryCollectionScheme
        feedEntryCollectionTerm = entry.feedEntryCollectionTerm
        feedEntryCollectionTitle = entry.feedEntryCollectionTitle
        content = entry.content
        voiceFrameUrl = entry.voiceFrameUrl
        voiceAudioURLs = entry.resolvedVoiceAudioURLs
        voiceAudioURL = voiceAudioURLs.first
        audioSubtitlesURL = entry.audioSubtitlesURL
        audioSubtitlesRoleRawValue = entry.audioSubtitlesRoleRawValue
            ?? (entry.audioSubtitlesURL != nil ? AudioSubtitlesRole.content.rawValue : nil)
        redditTranslationsUrl = entry.redditTranslationsUrl
        redditTranslationsTitle = entry.redditTranslationsTitle
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
    if content.content != payload.content {
        content.content = payload.content
        didChange = true
    }
    if content.voiceFrameUrl != payload.voiceFrameUrl {
        content.voiceFrameUrl = payload.voiceFrameUrl
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
    if content.audioSubtitlesURL != payload.audioSubtitlesURL {
        content.audioSubtitlesURL = payload.audioSubtitlesURL
        didChange = true
    }
    if content.audioSubtitlesRoleRawValue != payload.audioSubtitlesRoleRawValue {
        content.audioSubtitlesRoleRawValue = payload.audioSubtitlesRoleRawValue
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
    return didChange
}

@RealmBackgroundActor
fileprivate func syncRelatedReaderContent(with payload: FeedEntryPayload) async throws {
    let mirrors = try await ReaderContentLoader.loadAll(url: payload.url, skipFeedEntries: true)
    for case let object as (Object & ReaderContentProtocol) in mirrors {
        guard let realm = object.realm else { continue }
        try await realm.asyncWrite {
            if applyPayload(payload, to: object) {
                object.refreshChangeMetadata(explicitlyModified: true)
            }
        }
    }
}

fileprivate func cleanRssData(_ rssData: Data) -> Data {
    guard let rssString = String(data: rssData, encoding: .utf8) else { return rssData }
    let cleanedString = rssString.replacingOccurrences(of: "<前編>", with: "&lt;前編&gt;")
    return cleanedString.data(using: .utf8) ?? rssData
}
