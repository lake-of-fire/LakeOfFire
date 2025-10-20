import Foundation
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
    static var shared = FeedEntryActor()
}

public class FeedEntry: Object, ObjectKeyIdentifiable, ReaderContentProtocol, ChangeMetadataRecordable {
    @Persisted(primaryKey: true) public var compoundKey = ""
    public var keyPrefix: String? {
        return feedID?.uuidString
    }
    
    @Persisted public var feedID: UUID?
    
    @Persisted(indexed: true) public var url: URL
    @Persisted public var title = ""
    @Persisted public var author = ""
    @Persisted public var imageUrl: URL?
    @Persisted public var sourceIconURL: URL?
    @Persisted public var publicationDate: Date?
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
    @Persisted public var voiceAudioURLs = RealmSwift.List<URL>()
    @Persisted public var redditTranslationsUrl: URL?
    @Persisted public var redditTranslationsTitle: String?
    
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
        bookmark.voiceFrameUrl = voiceFrameUrl
        bookmark.voiceAudioURLs.removeAll()
        bookmark.voiceAudioURLs.append(objectsIn: voiceAudioURLs)
        bookmark.redditTranslationsUrl = redditTranslationsUrl
        bookmark.redditTranslationsTitle = redditTranslationsTitle
        
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

fileprivate func getRssData(rssUrl: URL) async throws -> Data? {
    let configuration = URLSessionConfiguration.ephemeral
    let (data, response) = try await URLSession(configuration: configuration).data(from: rssUrl)
    guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
        throw FeedError.downloadFailed
    }
    return data
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
    private func persist(rssItems: [RSSFeedItem], realmConfiguration: Realm.Configuration, deleteOrphans: Bool) async throws {
        let feedID = id
        let iconUrl = iconUrl
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
            
            let existingEntryIDs = Array(
                realm.objects(FeedEntry.self)
                    .where { $0.feedID == feedID }
                    .filter { !$0.isDeleted }
                    .map { $0.compoundKey }
            )
            
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
                feedEntry.updateCompoundKey()
                incomingIDs.append(feedEntry.compoundKey)
                return feedEntry
            }
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
        }()
    }
    
    @MainActor
    private func persist(atomItems: [AtomFeedEntry], realmConfiguration: Realm.Configuration, deleteOrphans: Bool) async throws {
        let feedID = id
        let sourceIconURL = iconUrl
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
            
            let existingEntryIDs = Array(
                realm.objects(FeedEntry.self)
                    .where { $0.feedID == feedID }
                    .filter { !$0.isDeleted }
                    .map { $0.compoundKey }
            )
            
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
                feedEntry.voiceAudioURLs.append(objectsIn: voiceAudioURLs)
                feedEntry.redditTranslationsUrl = redditTranslationsUrl
                feedEntry.redditTranslationsTitle = redditTranslationsTitle
                feedEntry.updateCompoundKey()
                incomingIDs.append(feedEntry.compoundKey)
                return feedEntry
            }
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
        }()
    }
    
    @MainActor
    func fetch(realmConfiguration: Realm.Configuration) async throws {
        guard var rssData = try await getRssData(rssUrl: rssUrl) else {
            throw FeedError.downloadFailed
        }
        rssData = cleanRssData(rssData)
        let parser = FeedKit.FeedParser(data: rssData)
        return try await withCheckedThrowingContinuation({ [weak self] (continuation: CheckedContinuation<(), Error>) in
            parser.parseAsync { [weak self] parserResult in
                switch parserResult {
                case .success(let feed):
                    switch feed {
                    case .rss(let rssFeed):
                        guard let items = rssFeed.items else {
                            continuation.resume(throwing: FeedError.parserFailed)
                            return
                        }
                        Task { @MainActor [weak self] in
                            guard let self = self else { return }
                            do {
                                try await self.persist(rssItems: items, realmConfiguration: realmConfiguration, deleteOrphans: deleteOrphans)
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
                        Task { @MainActor [weak self] in
                            guard let self = self else { return }
                            do {
                                try await self.persist(atomItems: items, realmConfiguration: realmConfiguration, deleteOrphans: deleteOrphans)
                                continuation.resume(returning: ())
                            } catch {
                                continuation.resume(throwing: error)
                            }
                        }
                        return
                    case .json(let jsonFeed):
                        continuation.resume(throwing: FeedError.parserFailed)
                        return
                    }
                case .failure(let error):
                    debugPrint(error)
                    continuation.resume(throwing: FeedError.parserFailed)
                    return
                }
            }
        })
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
    if !deleteOrphans && entriesToPersist.isEmpty {
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
        if deleteOrphans {
            let orphans = realm.objects(FeedEntry.self)
                .where { !$0.isDeleted && $0.compoundKey.in(existingEntryIDs) && !$0.compoundKey.in(incomingIDs) }
            for orphan in orphans {
                orphan.isDeleted = true
                orphan.refreshChangeMetadata(explicitlyModified: true)
            }
        }

        for payload in payloads {
            if let existing = realm.object(ofType: FeedEntry.self, forPrimaryKey: payload.compoundKey) {
                if applyPayload(payload, to: existing) {
                    existing.refreshChangeMetadata(explicitlyModified: true)
                }
            } else {
                let newEntry = FeedEntry()
                newEntry.compoundKey = payload.compoundKey
                newEntry.feedID = payload.feedID
                newEntry.url = payload.url
                newEntry.createdAt = payload.createdAt
                applyPayload(payload, to: newEntry)
                realm.add(newEntry, update: .error)
                newEntry.refreshChangeMetadata(explicitlyModified: true)
            }
        }
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
    let voiceAudioURLs: [URL]
    let redditTranslationsUrl: URL?
    let redditTranslationsTitle: String?
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
        voiceAudioURLs = Array(entry.voiceAudioURLs)
        redditTranslationsUrl = entry.redditTranslationsUrl
        redditTranslationsTitle = entry.redditTranslationsTitle
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
    let existingVoiceAudio = Array(content.voiceAudioURLs)
    if existingVoiceAudio != payload.voiceAudioURLs {
        content.voiceAudioURLs.removeAll()
        payload.voiceAudioURLs.forEach { content.voiceAudioURLs.append($0) }
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
