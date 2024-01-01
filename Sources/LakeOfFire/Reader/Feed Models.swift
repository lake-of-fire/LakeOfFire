import Foundation
import RealmSwift
import SwiftSoup
import BigSyncKit
import FeedKit
import RealmSwiftGaps

public class FeedCategory: Object, UnownedSyncableObject, ObjectKeyIdentifiable, Codable {
    public var needsSyncToServer: Bool {
        return false
    }
    
    @Persisted(primaryKey: true) public var id = UUID()
    
    @Persisted public var opmlOwnerName: String?
    @Persisted public var opmlURL: URL?
    
    @Persisted public var title: String
    @Persisted public var backgroundImageUrl: URL
    @Persisted public var createdAt: Date
    @Persisted public var modifiedAt: Date
    @Persisted public var isArchived = false
    @Persisted public var isDeleted = false
    @Persisted(originProperty: "category") public var feeds: LinkingObjects<Feed>
    
    public enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case title
        case backgroundImageUrl // = "background_image_url"
        case createdAt //= "created_at"
        case modifiedAt //= "modified_at"
        case isDeleted //= "is_deleted"
    }
    
    public var isUserEditable: Bool {
        return opmlURL == nil
    }
}

public class Feed: Object, UnownedSyncableObject, ObjectKeyIdentifiable, Codable {
    public var needsSyncToServer: Bool {
        return false
    }
    
    @Persisted(primaryKey: true) public var id = UUID()
    @Persisted public var title: String
    @Persisted public var category: FeedCategory?
    @Persisted public var markdownDescription = ""
    @Persisted public var rssUrl: URL
    @Persisted public var iconUrl: URL
    @Persisted public var modifiedAt: Date
    
    @Persisted public var isReaderModeByDefault = true
    @Persisted public var rssContainsFullContent = false
    @Persisted public var injectEntryImageIntoHeader = false
    @Persisted public var displayPublicationDate = true
    @Persisted public var meaningfulContentMinLength = 0
    @Persisted public var extractImageFromContent = true
    
    @Persisted(originProperty: "feed") public var entries: LinkingObjects<FeedEntry>
    @Persisted public var isArchived = false
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
        case modifiedAt
        case isArchived
    }
    
    public var isUserEditable: Bool {
        return category?.opmlURL == nil
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
        self.modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
    }
}

public class FeedEntry: Object, ObjectKeyIdentifiable, ReaderContentModel {
    @Persisted(primaryKey: true) public var compoundKey = ""
    public var keyPrefix: String? {
        return feed?.primaryKeyValue
    }
    
    @Persisted public var feed: Feed?
    
    @Persisted public var url: URL
    @Persisted public var title = ""
    @Persisted public var imageUrl: URL?
    @Persisted public var publicationDate: Date?
//    @Persisted public var isFromClipboard = false
    @Persisted public var content: Data?
//    @Persisted public var readerModeAvailabilityOverride: Bool? = nil
    
    public var isFromClipboard = false
    
    public func htmlToDisplay(readerFileManager: ReaderFileManager) async -> String? {
        if rssContainsFullContent {
            return Self.contentToHTML(legacyHTMLContent: htmlContent, content: content)
        }
        return nil
    }
    
    public var imageURLToDisplay: URL? {
        if extractImageFromContent, imageUrl == nil, let content = content, let configuration = realm?.configuration {
            let legacyHTMLContent = htmlContent
            let ref = ThreadSafeReference(to: self)
            Task.detached { @RealmBackgroundActor in
                if let html = Self.contentToHTML(legacyHTMLContent: legacyHTMLContent, content: content), let url = Self.imageURLExtractedFromContent(htmlContent: html) {
                    let realm = try await Realm(configuration: configuration, actor: RealmBackgroundActor.shared)
                    guard let entry = realm.resolve(ref) else { return }
                    try await realm.asyncWrite {
                        entry.imageUrl = url
                    }
                }
            }
        }
        return imageUrl
    }
        
    public var isReaderModeAvailable: Bool {
        get { return isReaderModeByDefault }
        set { }
    }
    
    // Feed entry metadata.
    public var rssURLs: List<URL> {
        get {
            let list = RealmSwift.List<URL>()
            if let url = feed?.rssUrl {
                list.append(url)
            }
            return list
        }
    }
    public var rssTitles: List<String> {
        get {
            let list = RealmSwift.List<String>()
            if let title = feed?.title {
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
        get { feed?.isReaderModeByDefault ?? true }
        set { }
    }
    public var rssContainsFullContent: Bool {
        get { feed?.rssContainsFullContent ?? false }
        set { feed?.rssContainsFullContent = newValue }
    }
    public var meaningfulContentMinLength: Int {
        get { feed?.meaningfulContentMinLength ?? 0 }
        set { feed?.meaningfulContentMinLength = newValue }
    }
    public var injectEntryImageIntoHeader: Bool {
        get { feed?.injectEntryImageIntoHeader ?? false }
        set { feed?.injectEntryImageIntoHeader = newValue }
    }
    public var displayPublicationDate: Bool {
        get { feed?.displayPublicationDate ?? true }
        set { feed?.displayPublicationDate = newValue }
    }
    public var extractImageFromContent: Bool {
        get { feed?.extractImageFromContent ?? false }
        set { feed?.extractImageFromContent = newValue }
    }
    
    #warning("TODO: Use createdAt to trim FeedEntry items after N days, N entries etc. or low disk notif")
    @Persisted public var createdAt = Date()
    @Persisted public var isDeleted = false
    
    @MainActor
    public func configureBookmark(_ bookmark: Bookmark) {
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
            
            let imageElements: [Element] = try Array(doc.select("img"))
            let filteredImageElements: [Element] = imageElements.filter({ (imageTag: Element) -> Bool in
                if let src: String = try? imageTag.attr("src"), src.contains("doubleclick.net") {
                    return false
                }
                
                do {
                    let height: Float? = try Float(imageTag.attr("height")), width: Float? = try Float(imageTag.attr("width"))
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
                imageUrlOptional = try doc.select("img").filter({ imageTag -> Bool in
                    if let src = try? imageTag.attr("src"), src.contains("doubleclick.net") {
                        return false
                    }
                    
                    do {
                        let height = try Float(imageTag.attr("height")), width = try Float(imageTag.attr("width"))
                        return height != nil || width != nil
                    } catch {
                        return true
                    }
                }).first?.attr("src")
            }
            
            // Match YouTube links for thumbnails.
            if imageUrlOptional == nil {
                imageUrlOptional = try doc.select("iframe").compactMap({ iframeTag -> String? in
                    if let src = try? iframeTag.attr("src"), src.hasPrefix("https://www.youtube.com"), let youtubeId = src.split(separator: "/").last {
                        return "https://img.youtube.com/vi/\(youtubeId)/0.jpg"
                    }
                    return nil
                }).first
            }
            if let imageUrl = imageUrlOptional {
                return URL(string: imageUrl)
            }
        } catch { }
        return nil
    }
}

public enum FeedError: Error {
    case downloadFailed
    case parserFailed
    case jsonFeedsUnsupported
}

fileprivate func getRssData(rssUrl: URL) async throws -> Data? {
    let (data, response) = try await URLSession.shared.data(from: rssUrl)
    guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
        throw FeedError.downloadFailed
    }
    return data
}

fileprivate func collapseRubyTags(doc: SwiftSoup.Document, restrictToReaderContentElement: Bool = true) throws {
    let pageElement = try doc.getElementsByClass("reader-content").first()?.getElementsByClass("page").first()
    guard !restrictToReaderContentElement || pageElement != nil else { return }
    
    for rubyTag in try (pageElement ?? doc).getElementsByTag("ruby") {
        for tagName in ["rp", "rt", "rtc"] {
            try rubyTag.getElementsByTag(tagName).remove()
        }
        
        let surface = try rubyTag.text(trimAndNormaliseWhitespace: false)
        try rubyTag.before(surface)
        try rubyTag.remove()
    }
}

public extension Feed {
    @RealmBackgroundActor
    private func persist(rssItems: [RSSFeedItem], realmConfiguration: Realm.Configuration) async throws {
        let realm = try await Realm(configuration: realmConfiguration, actor: RealmBackgroundActor.shared)
        let feedEntries: [FeedEntry] = rssItems.reversed().compactMap { item -> FeedEntry? in
            guard let link = item.link?.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed), let url = URL(string: link) else { return nil }
            var imageUrl: URL? = nil
            if let enclosureAttribs = item.enclosure?.attributes, enclosureAttribs.type?.hasPrefix("image/") ?? false {
                if let imageUrlRaw = enclosureAttribs.url {
                    imageUrl = URL(string: imageUrlRaw)
                }
            }
            let content = item.content?.contentEncoded ?? item.description
            
            var title = item.title
            do {
                if let feedItemTitle = item.title?.unescapeHTML(), let doc = try? SwiftSoup.parse(feedItemTitle) {
                    doc.outputSettings().prettyPrint(pretty: false)
                    try collapseRubyTags(doc: doc, restrictToReaderContentElement: false)
                    title = try doc.text()
                } else {
                    print("Failed to parse HTML in order to transform content.")
                    throw FeedError.parserFailed
                }
            } catch { }
            title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            
            let feedEntry = FeedEntry()
            feedEntry.feed = realm.object(ofType: Feed.self, forPrimaryKey: self.id)
            feedEntry.html = content
            feedEntry.url = url
            feedEntry.title = title ?? ""
            feedEntry.imageUrl = imageUrl
            feedEntry.publicationDate = item.pubDate ?? item.dublinCore?.dcDate
            feedEntry.updateCompoundKey()
            return feedEntry
        }
        try await realm.asyncWrite {
            realm.add(feedEntries, update: .modified)
        }
    }
    
    @RealmBackgroundActor
    private func persist(atomItems: [AtomFeedEntry], realmConfiguration: Realm.Configuration) async throws {
        let realm = try await Realm(configuration: realmConfiguration, actor: RealmBackgroundActor.shared)
        let feedEntries: [FeedEntry] = atomItems.reversed().compactMap { (item) -> FeedEntry? in
            var url: URL?
            var imageUrl: URL?
            item.links?.forEach { (link: AtomFeedEntryLink) in
                guard let linkHref = link.attributes?.href?.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) else { return }
                
                if (link.attributes?.rel ?? "alternate") == "alternate" {
                    url = URL(string: linkHref)
                } else if let rel = link.attributes?.rel, let type = link.attributes?.type, rel == "enclosure" && type.hasPrefix("image/") {
                    imageUrl = URL(string: linkHref)
                }
            }
            guard let url = url else { return nil }
            
            var voiceFrameUrl: URL? = nil
            if let rawVoiceFrameUrl = item.links?.filter({ (link) -> Bool in
                return (link.attributes?.rel ?? "") == "voice-frame"
            }).first?.attributes?.href {
                voiceFrameUrl = URL(string: rawVoiceFrameUrl)
            }
            
            let voiceAudioURLs: [URL] = (item.links ?? [])
                .filter { $0.attributes?.rel == "voice-audio" }
                .compactMap { $0.attributes?.href }
                .compactMap { URL(string: $0) }
            
            // TODO: Refactor into community commentary links
            var redditTranslationsUrl: URL? = nil, redditTranslationsTitle: String? = nil
            if let redditTranslationsAttrs = item.links?.filter({ (link) -> Bool in
                return (link.attributes?.rel ?? "") == "reddit-translations"
            }).first?.attributes, let rawRedditTranslationsUrl = redditTranslationsAttrs.href?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                redditTranslationsUrl = URL(string: rawRedditTranslationsUrl)
                redditTranslationsTitle = redditTranslationsAttrs.title
            }
            
            var title = item.title
            do {
                if let feedItemTitle = item.title, let doc = try? SwiftSoup.parse(feedItemTitle) {
                    doc.outputSettings().prettyPrint(pretty: false)
                    try collapseRubyTags(doc: doc, restrictToReaderContentElement: false)
                    title = try doc.text()
                } else {
                    print("Failed to parse HTML in order to transform content.")
                }
            } catch { }
            title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            
            let feedEntry = FeedEntry()
            feedEntry.feed = realm.object(ofType: Feed.self, forPrimaryKey: self.id)
            feedEntry.url = url
            feedEntry.title = title ?? ""
            feedEntry.imageUrl = imageUrl
            feedEntry.publicationDate = item.published ?? item.updated
            feedEntry.html = item.content?.value
            feedEntry.voiceFrameUrl = voiceFrameUrl
            feedEntry.voiceAudioURLs.append(objectsIn: voiceAudioURLs)
            feedEntry.redditTranslationsUrl = redditTranslationsUrl
            feedEntry.redditTranslationsTitle = redditTranslationsTitle
            feedEntry.updateCompoundKey()
            return feedEntry
        }
        try await realm.asyncWrite {
            realm.add(feedEntries, update: .modified)
        }
    }
    
    @MainActor
    func fetch(realmConfiguration: Realm.Configuration) async throws {
        guard var rssData = try await getRssData(rssUrl: rssUrl) else {
            throw FeedError.downloadFailed
        }
        
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
                                try await self.persist(rssItems: items, realmConfiguration: realmConfiguration)
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
                                try await self.persist(atomItems: items, realmConfiguration: realmConfiguration)
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
                case .failure(_):
                    continuation.resume(throwing: FeedError.parserFailed)
                    return
                }
                continuation.resume(returning: ())
            }
        })
    }
}

fileprivate func cleanRssData(_ rssData: Data) -> Data {
    guard let rssString = String(data: rssData, encoding: .utf8) else { return rssData }
    let cleanedString = rssString.replacingOccurrences(of: "<前編>", with: "&lt;前編&gt;")
    return cleanedString.data(using: .utf8) ?? rssData
}
