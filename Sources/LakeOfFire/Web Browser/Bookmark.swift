import Foundation
import RealmSwift
import RealmSwiftGaps
import SwiftCloudDrive

public class Bookmark: Object, ReaderContentProtocol {
    @Persisted(primaryKey: true) public var compoundKey = ""
    
    @Persisted(indexed: true) public var url = URL(string: "about:blank")!
    @Persisted public var title = ""
    @Persisted public var author = ""
    @Persisted public var imageUrl: URL?
    @Persisted public var publicationDate: Date?
    @Persisted public var isFromClipboard = false
    
    // Caches
    /// Deprecated, use `content` via `html`.
    @Persisted public var htmlContent: String?
    @Persisted public var content: Data?
    @Persisted public var isReaderModeAvailable = false
    
    // Feed entry metadata.
    @Persisted public var rssURLs = RealmSwift.List<URL>()
    @Persisted public var rssTitles = RealmSwift.List<String>()
    @Persisted public var isRSSAvailable = false
    @Persisted public var voiceFrameUrl: URL?
    @Persisted public var voiceAudioURLs = RealmSwift.List<URL>()
    @Persisted public var redditTranslationsUrl: URL?
    @Persisted public var redditTranslationsTitle: String?
    
    // Feed options.
    @Persisted public var isReaderModeByDefault = false
    @Persisted public var isReaderModeOfferHidden = false
    @Persisted public var rssContainsFullContent = false
    @Persisted public var meaningfulContentMinLength = 0
    @Persisted public var injectEntryImageIntoHeader = false
    @Persisted public var displayPublicationDate = true
    
    @Persisted public var createdAt = Date()
    @Persisted public var isDeleted = false
    
    public var imageURLToDisplay: URL? { imageUrl }
    
    public func configureBookmark(_ bookmark: Bookmark) {
        let url = url
        Task.detached { @RealmBackgroundActor in
            let realm = try await Realm(configuration: ReaderContentLoader.bookmarkRealmConfiguration, actor: RealmBackgroundActor.shared)
            try await realm.asyncWrite {
                for historyRecord in realm.objects(HistoryRecord.self).where({ ($0.bookmark == nil || $0.bookmark.isDeleted) && !$0.isDeleted }).filter({ $0.url == url }) {
                    historyRecord.bookmark = bookmark
                }
            }
        }
    }
}

public extension Bookmark {
    @RealmBackgroundActor
    static func add(url: URL? = nil, title: String = "", imageUrl: URL? = nil, html: String? = nil, content: Data? = nil, publicationDate: Date? = nil, isFromClipboard: Bool, rssContainsFullContent: Bool, isReaderModeByDefault: Bool, isReaderModeAvailable: Bool, isReaderModeOfferHidden: Bool, realmConfiguration: Realm.Configuration) async throws -> Bookmark {
        let realm = try await Realm(configuration: realmConfiguration, actor: RealmBackgroundActor.shared)
        let pk = Bookmark.makePrimaryKey(url: url, html: html)
        if let bookmark = realm.object(ofType: Bookmark.self, forPrimaryKey: pk) {
            try await realm.asyncWrite {
                bookmark.title = title
                bookmark.imageUrl = imageUrl
                if let html = html {
                    bookmark.html = html
                } else if let content = content {
                    bookmark.content = content
                }
                bookmark.publicationDate = publicationDate
                bookmark.isFromClipboard = isFromClipboard
                bookmark.isReaderModeByDefault = isReaderModeByDefault
                bookmark.isReaderModeAvailable = isReaderModeAvailable
                bookmark.rssContainsFullContent = rssContainsFullContent
                bookmark.isReaderModeOfferHidden = isReaderModeOfferHidden
                bookmark.isDeleted = false
            }
            return bookmark
        } else {
            let bookmark = Bookmark()
            if let html = html {
                bookmark.html = html
            } else if let content = content {
                bookmark.content = content
            }
            if let url = url {
                bookmark.url = url
                bookmark.updateCompoundKey()
            } else {
                bookmark.updateCompoundKey()
                bookmark.url = ReaderContentLoader.snippetURL(key: bookmark.compoundKey) ?? bookmark.url
            }
            bookmark.title = title
            bookmark.imageUrl = imageUrl
            bookmark.publicationDate = publicationDate
            bookmark.isFromClipboard = isFromClipboard
            bookmark.isReaderModeByDefault = isReaderModeByDefault
            bookmark.rssContainsFullContent = rssContainsFullContent
            bookmark.isReaderModeAvailable = isReaderModeAvailable
            bookmark.isReaderModeOfferHidden = isReaderModeOfferHidden
            try await realm.asyncWrite {
                realm.add(bookmark, update: .modified)
            }
            return bookmark
        }
    }
    
//    func fetchRecords() -> [HistoryRecord] {
//        var limitedRecords: [HistoryRecord] = []
//        let records = realm.objects(HistoryRecord.self).filter("isDeleted == false").sorted(byKeyPath: "lastVisitedAt", ascending: false)
//        for idx in 0..<100 {
//            limitedRecords.append(records[idx])
//        }
//        return limitedRecords
//    }
    
    @RealmBackgroundActor
    static func removeAll(realmConfiguration: Realm.Configuration) async throws {
        let realm = try await Realm(configuration: realmConfiguration, actor: RealmBackgroundActor.shared)
        try await realm.asyncWrite {
            realm.objects(self).setValue(true, forKey: "isDeleted")
        }
    }
}
