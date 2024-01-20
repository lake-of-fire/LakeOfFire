import Foundation
import RealmSwift
import SwiftUIWebView
import SwiftUtilities
import RealmSwiftGaps

public struct ReaderContentReadingProgressLoader {
    /// Float is progress, Bool is whether article is "finished".
    @RealmBackgroundActor
    public static var readingProgressLoader: ((any ReaderContentModel) async throws -> (Float, Bool)?)?
}

public protocol ReaderContentModel: RealmSwift.Object, ObjectKeyIdentifiable, Equatable, ThreadConfined {
    var compoundKey: String { get set }
    var keyPrefix: String? { get }
    
    var url: URL { get set }
    var title: String { get set }
    var imageUrl: URL? { get set }
    var content: Data? { get set }
    var publicationDate: Date? { get set }
    var isFromClipboard: Bool { get set }
    var imageURLToDisplay: URL? { get }
    
    // Caches.
    var isReaderModeAvailable: Bool { get set }
    
    // TODO: Don't populate these if they already exist in user library... or cull
    var rssURLs: List<URL> { get }
    var rssTitles: List<String> { get }
    var isRSSAvailable: Bool { get set }
    
    // Feed entry metadata.
    var voiceFrameUrl: URL? { get set }
    var voiceAudioURLs: RealmSwift.List<URL> { get set }
    var redditTranslationsUrl: URL? { get set }
    var redditTranslationsTitle: String? { get set }
    
    // Feed options.
    /// Whether the content be viewed directly instead of loading the URL.
    var isReaderModeByDefault: Bool { get set }
    // TODO: rename rssContainsFullContent to be more general.
    /// Whether `content` contains the full content (not just for RSS).
    var rssContainsFullContent: Bool { get set }
    var meaningfulContentMinLength: Int { get set }
    var injectEntryImageIntoHeader: Bool { get set }
    var displayPublicationDate: Bool { get set }
    
    var createdAt: Date { get }
    var isDeleted: Bool { get }
    
    func configureBookmark(_ bookmark: Bookmark)
    func htmlToDisplay(readerFileManager: ReaderFileManager) async -> String?
}

public extension ReaderContentModel {
    var keyPrefix: String? {
        return nil
    }
    
    /// Deprecated, use `content`.
    var htmlContent: String? {
        get {
            return nil
        }
        set { }
    }
    
    @MainActor
    func asyncWrite(_ block: @escaping ((Realm, any ReaderContentModel) -> Void)) async throws {
        let config = realm?.configuration ?? .defaultConfiguration
        let compoundKey = compoundKey
        let cls = type(of: self)// objectSchema.objectClass
        try await Task.detached { @RealmBackgroundActor in
            let realm = try await Realm(configuration: config, actor: RealmBackgroundActor.shared)
            guard let content = realm.object(ofType: cls, forPrimaryKey: compoundKey) else { return }
            try await realm.asyncWrite {
                block(realm, content)
            }
        }.value
    }
}

public protocol DeletableReaderContent: ReaderContentModel {
    var deleteActionTitle: String { get }
    func delete(readerFileManager: ReaderFileManager) async throws
}

public extension URL {
    func matchesReaderURL(_ url: URL?) -> Bool {
        guard let url = url else { return false }
        if url.absoluteString.hasPrefix("internal://local/load/reader?reader-url="), let range = url.absoluteString.range(of: "?reader-url=", options: []), let rawURL = String(url.absoluteString[range.upperBound...]).removingPercentEncoding, let contentURL = URL(string: rawURL) {
            return contentURL == self
        }
        return url == self
    }
}

public extension WebViewState {
    func matches(content: any ReaderContentModel) -> Bool {
        return content.url.matchesReaderURL(pageURL)
    }
}

public extension String {
    var readerContentData: Data? {
        guard let newData = data(using: .utf8) else {
            return nil
        }
        return try? (newData as NSData).compressed(using: .lzfse) as Data
    }
}

extension String {
    // From: https://stackoverflow.com/a/50798549/89373
    public func removingHTMLTags() -> String? {
        if !contains("<") {
            return self
        }
        return replacingOccurrences(of: "<[^>]+>", with: "", options: String.CompareOptions.regularExpression, range: nil)
    }
}

public extension ReaderContentModel {
    var humanReadablePublicationDate: String? {
        guard let publicationDate = publicationDate else { return nil}
        
        let interval = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .nanosecond], from: publicationDate, to: Date())
        let intervalText: String
        if let year = interval.year, year > 0 {
            intervalText = "\(year) year\(year != 1 ? "s" : "")"
        } else if let month = interval.month, month > 0 {
            intervalText = "\(month) month\(month != 1 ? "s" : "")"
        } else if let day = interval.day, day > 0 {
            intervalText = "\(day) day\(day != 1 ? "s" : "")"
        } else if let hour = interval.hour, hour > 0 {
            intervalText = "\(hour) hour\(hour != 1 ? "s" : "")"
        } else if let minute = interval.minute, minute > 0 {
            intervalText = "\(minute) minute\(minute != 1 ? "s" : "")"
        } else if let nanosecond = interval.nanosecond, nanosecond > 0 {
            intervalText = "\(nanosecond / 1000000000) second\(nanosecond != 1000000000 ? "s" : "")"
        } else {
            return nil
        }
        return "\(intervalText) ago"
    }
    
    static func contentToHTML(legacyHTMLContent: String? = nil, content: Data?) -> String? {
        if let legacyHtml = legacyHTMLContent {
            return legacyHtml
        }
        guard let content = content else { return nil }
        let nsContent: NSData = content as NSData
        guard let data = try? nsContent.decompressed(using: .lzfse) as Data? else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
    
    var html: String? {
        get {
            Self.contentToHTML(legacyHTMLContent: htmlContent, content: content)
        }
        set {
            htmlContent = nil
            content = newValue?.readerContentData
        }
    }
    
    @MainActor
    var titleForDisplay: String {
        get {
            var title = title.removingHTMLTags() ?? title
            if title.isEmpty {
                title = "Untitled"
            }
            if isFromClipboard {
                return "📎 " + title
            }
            return title
        }
    }
    
    static func makePrimaryKey(keyPrefix: String? = nil, url: URL? = nil, html: String? = nil) -> String? {
        return makeReaderContentCompoundKey(keyPrefix: keyPrefix, url: url, html: html)
    }
    
    func updateCompoundKey() {
        compoundKey = makeReaderContentCompoundKey(keyPrefix: keyPrefix, url: url, html: html) ?? compoundKey
    }
}

public extension ReaderContentModel {
//    var rawEntryThumbnailContentMode: Int = UIView.ContentMode.scaleAspectFill.rawValue
    /*var entryThumbnailContentMode: UIView.ContentMode {
        get {
            return UIView.ContentMode(rawValue: rawEntryThumbnailContentMode)!
        }
        set {
            rawEntryThumbnailContentMode = newValue.rawValue
        }
    }*/
    
    var isReaderModeByDefault: Bool {
        if isFromClipboard {
            return true
        }
//        guard let bareHostURL = URL(string: "\(url.scheme ?? "https")://\(url.host ?? "")") else { return false }
//        let exists = realm.objects(FeedEntry.self).contains { $0.url.absoluteString.starts(with: bareHostURL.absoluteString) && $0.isReaderModeByDefault } // not strict enough?
        guard let configuration = realm?.configuration else { return false }
        let exists = try! !Realm(configuration: configuration).objects(FeedEntry.self).where { $0.url == url && $0.isReaderModeByDefault }.isEmpty
        return exists
    }
}

public extension ReaderContentModel {
    /// Returns whether the result is having a bookmark or not.
    func toggleBookmark(realmConfiguration: Realm.Configuration) async throws -> Bool {
        if try await removeBookmark(realmConfiguration: realmConfiguration) {
            return false
        }
        try await addBookmark(realmConfiguration: realmConfiguration)
        return true
    }
    
    @MainActor
    func addBookmark(realmConfiguration: Realm.Configuration) async throws {
        let url = url
        let title = title
        let html = html
        let content = content
        let publicationDate = publicationDate
        let imageURL = imageUrl
        let isFromClipboard = isFromClipboard
        let isReaderModeByDefault = isReaderModeByDefault
        try await Task.detached { @RealmBackgroundActor [weak self] in
            guard let self = self else { return }
            let bookmark = try await Bookmark.add(url: url, title: title, imageUrl: imageURL, html: html, content: content, publicationDate: publicationDate, isFromClipboard: isFromClipboard, isReaderModeByDefault: isReaderModeByDefault, realmConfiguration: realmConfiguration)
            await Task { @MainActor [weak self] in
                guard let self = self else { return }
                configureBookmark(bookmark)
            }.value
        }.value
    }
    
    /// Returns whether a matching bookmark was found and deleted.
    @MainActor
    func removeBookmark(realmConfiguration: Realm.Configuration) async throws -> Bool {
        let url = url
        let html = html
        return try await Task.detached { @RealmBackgroundActor in
            let realm = try await Realm(configuration: realmConfiguration, actor: RealmBackgroundActor.shared)
            guard let bookmark = realm.object(ofType: Bookmark.self, forPrimaryKey: Bookmark.makePrimaryKey(url: url, html: html)), !bookmark.isDeleted else {
                return false
            }
            try await realm.asyncWrite {
                bookmark.isDeleted = true
            }
            return true
        }.value
    }
    
    func bookmarkExists(realmConfiguration: Realm.Configuration) -> Bool {
        let realm = try! Realm(configuration: realmConfiguration)
        let pk = Bookmark.makePrimaryKey(url: url, html: html)
        return !(realm.object(ofType: Bookmark.self, forPrimaryKey: pk)?.isDeleted ?? true)
    }
    
    func fetchBookmarks(realmConfiguration: Realm.Configuration) -> [Bookmark] {
        let realm = try! Realm(configuration: realmConfiguration)
        return Array(realm.objects(Bookmark.self).where({ $0.isDeleted == false }).sorted(by: \.createdAt)).reversed()
    }

    @RealmBackgroundActor
    func addHistoryRecord(realmConfiguration: Realm.Configuration, pageURL: URL) async throws -> HistoryRecord {
        let realm = try await Realm(configuration: realmConfiguration, actor: RealmBackgroundActor.shared)
        if let record = realm.object(ofType: HistoryRecord.self, forPrimaryKey: HistoryRecord.makePrimaryKey(url: pageURL, html: html)) {
            try await realm.asyncWrite {
                record.title = title
                record.imageUrl = imageURLToDisplay
                record.isFromClipboard = isFromClipboard
                record.rssContainsFullContent = rssContainsFullContent
                if rssContainsFullContent {
                    record.content = content
                }
                record.voiceFrameUrl = voiceFrameUrl
                for audioURL in voiceAudioURLs {
                    if !record.voiceAudioURLs.contains(audioURL) {
                        record.voiceAudioURLs.append(audioURL)
                    }
                }
                record.injectEntryImageIntoHeader = injectEntryImageIntoHeader
                record.publicationDate = publicationDate
//                record.isReaderModeByDefault = isReaderModeByDefault
                record.displayPublicationDate = displayPublicationDate
                record.lastVisitedAt = Date()
                record.isDeleted = false
                if objectSchema.objectClass == Bookmark.self, let bookmark = self as? Bookmark {
                    record.configureBookmark(bookmark)
                }
            }
            return record
        } else {
            let record = HistoryRecord()
            record.url = pageURL
            record.title = title
            record.imageUrl = imageURLToDisplay
            record.rssContainsFullContent = rssContainsFullContent
            if rssContainsFullContent {
                record.content = content
            }
            record.voiceFrameUrl = voiceFrameUrl
            record.voiceAudioURLs.append(objectsIn: voiceAudioURLs)
            record.publicationDate = publicationDate
            record.displayPublicationDate = displayPublicationDate
            record.isFromClipboard = isFromClipboard
            record.isReaderModeByDefault = isReaderModeByDefault
            record.injectEntryImageIntoHeader = injectEntryImageIntoHeader
            record.lastVisitedAt = Date()
            if objectSchema.objectClass == Bookmark.self, let bookmark = self as? Bookmark {
                await record.configureBookmark(bookmark)
            }
            record.updateCompoundKey()
            try await realm.asyncWrite {
                realm.add(record, update: .modified)
            }
            return record
        }
    }
}

public func makeReaderContentCompoundKey(keyPrefix: String?, url: URL?, html: String?) -> String? {
    guard url != nil || html != nil else {
//        fatalError("Needs either url or htmlContent.")
        return nil
    }
    var key = ""
    if let keyPrefix = keyPrefix {
        key.append(keyPrefix + "-")
    }
    if let url = url, !(url.absoluteString.hasPrefix("about:") || url.absoluteString.hasPrefix("internal://local")) || html == nil {
        key.append(String(format: "%02X", stableHash(url.absoluteString)))
    } else if let html = html {
        key.append((String(format: "%02X", stableHash(html))))
    }
    return key
}
