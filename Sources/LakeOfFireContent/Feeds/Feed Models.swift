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
    
    @Persisted public var feedID: UUID?
    
    @Persisted public var url: URL
    @Persisted public var title = ""
    @Persisted public var isTitlePrefixOfContent = false
    @Persisted public var author = ""
    @Persisted public var imageUrl: URL?
    @Persisted public var sourceIconURL: URL?
    @Persisted public var publicationDate: Date?
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

fileprivate enum FeedFetchResult {
    case notModified(metadata: FeedFetchMetadata)
    case fetched(Data, metadata: FeedFetchMetadata)
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
    let session = makeFeedSession()
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
    switch headHTTPResponse.statusCode {
    case 304:
        return .notModified(metadata: headMetadata)
    case let statusCode where isSuccessfulFeedRefreshStatus(statusCode):
        if isFeedUnchanged(
            remoteMetadata: headMetadata,
            lastFetchedETag: lastFetchedETag,
            lastFetchedModifiedAt: lastFetchedModifiedAt
        ) {
            return .notModified(metadata: headMetadata)
        }
    default:
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
        throw FeedError.downloadFailed
    }

    let getMetadata = headMetadata.merged(with: feedFetchMetadata(from: getHTTPResponse))
    switch getHTTPResponse.statusCode {
    case 304:
        return .notModified(metadata: getMetadata)
    case 200..<300:
        return .fetched(data, metadata: getMetadata)
    case 300..<400:
        return .notModified(metadata: getMetadata)
    default:
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
    private func persist(atomItems: [AtomFeedEntry], realmConfiguration: Realm.Configuration, deleteOrphans: Bool) async throws {
        let feedID = id
        let sourceIconURL = iconUrl
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
            if !entriesToPersist.isEmpty || deleteOrphans {
                await realm.asyncRefresh()
                try await realm.asyncWrite {
                    if deleteOrphans {
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
        debugPrint(
            "# FEEDNEW stage=feed.fetch.begin",
            "feedID=\(id.uuidString)",
            "title=\(title)",
            "lastViewedAt=\(lastViewedAt?.description ?? "nil")",
            "lastRefreshedEntriesAt=\(lastRefreshedEntriesAt?.description ?? "nil")",
            "lastFetchedModifiedAt=\(lastFetchedModifiedAt?.description ?? "nil")",
            "lastFetchedETag=\(lastFetchedETag ?? "nil")"
        )
        let fetchResult = try await getRssData(
            rssUrl: rssUrl,
            lastFetchedETag: lastFetchedETag,
            lastFetchedModifiedAt: lastFetchedModifiedAt
        )
        switch fetchResult {
        case .notModified(let metadata):
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
            debugPrint(
                "# FEEDNEW stage=feed.fetch.fetched",
                "feedID=\(id.uuidString)",
                "title=\(title)",
                "bytes=\(rssData.count)",
                "etag=\(metadata.etag ?? "nil")",
                "lastModifiedAt=\(metadata.lastModifiedAt?.description ?? "nil")"
            )
            rssData = cleanRssData(rssData)
            let parser = FeedKit.FeedParser(data: rssData)
            return try await withCheckedThrowingContinuation({ (continuation: CheckedContinuation<(), Error>) in
                parser.parseAsync { parserResult in
                    switch parserResult {
                    case .success(let feed):
                        switch feed {
                        case .rss(let rssFeed):
                            guard let items = rssFeed.items else {
                                continuation.resume(throwing: FeedError.parserFailed)
                                return
                            }
                            Task { @MainActor in
                                do {
                                    try await self.persist(rssItems: items, realmConfiguration: realmConfiguration, deleteOrphans: self.deleteOrphans)
                                    try await self.persistFetchMetadata(metadata, realmConfiguration: realmConfiguration)
                                    continuation.resume(returning: ())
                                } catch {
                                    continuation.resume(throwing: error)
                                }
                            }
                            return
                        case .atom(let atomFeed):
                            guard let items = atomFeed.entries else {
                                continuation.resume(throwing: FeedError.parserFailed)
                                return
                            }
                            Task { @MainActor in
                                do {
                                    try await self.persist(atomItems: items, realmConfiguration: realmConfiguration, deleteOrphans: self.deleteOrphans)
                                    try await self.persistFetchMetadata(metadata, realmConfiguration: realmConfiguration)
                                    continuation.resume(returning: ())
                                } catch {
                                    continuation.resume(throwing: error)
                                }
                            }
                            return
                        case .json:
                            continuation.resume(throwing: FeedError.parserFailed)
                            return
                        }
                    case .failure:
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
                    if let entryValue = entry.value(forKey: propertyName) as? Object,
                       let existingValue = existingEntry.value(forKey: propertyName) as? Object {
                        if entryValue.value(forKey: primaryKey) as? String != existingValue.value(forKey: primaryKey) as? String {
                            differentEntries.append(entry)
                            break
                        }
                    }
                } else if property.isArray {
                    switch property.type {
                    case .string:
                        if let entryList = entry.value(forKey: propertyName) as? List<String>,
                           let existingList = existingEntry.value(forKey: propertyName) as? List<String>,
                           entryList != existingList {
                            differentEntries.append(entry)
                            break
                        }
                        if let entryList = entry.value(forKey: propertyName) as? List<URL>,
                           let existingList = existingEntry.value(forKey: propertyName) as? List<URL>,
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

fileprivate struct FeedEntryPayload {
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
    let redditTranslationsUrl: URL?
    let redditTranslationsTitle: String?

    init(entry: FeedEntry) {
        url = entry.url
        title = entry.title
        author = entry.author
        imageUrl = entry.imageUrl
        sourceIconURL = entry.sourceIconURL
        publicationDate = entry.publicationDate
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
