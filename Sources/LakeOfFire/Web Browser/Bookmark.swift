import Foundation
import RealmSwift
import RealmSwiftGaps
import SwiftCloudDrive
import BigSyncKit

public class Bookmark: Object, ReaderContentProtocol {
    @Persisted(primaryKey: true) public var compoundKey = ""
    
    @Persisted(indexed: true) public var url = URL(string: "about:blank")!
    @Persisted public var title = ""
    @Persisted public var author = ""
    @Persisted public var imageUrl: URL?
    @Persisted public var sourceIconURL: URL?
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
    
    @Persisted public var explicitlyModifiedAt: Date?
    @Persisted public var createdAt = Date()
    @Persisted public var modifiedAt = Date()
    @Persisted public var isDeleted = false
    
    public func imageURLToDisplay() -> URL? {
        return imageUrl
    }
    
    /// Used by subclasses of Bookmark
    @RealmBackgroundActor
    public func configureBookmark(_ bookmark: Bookmark) {
        let url = url
        let targetBookmarkID = bookmark.compoundKey
        Task { @RealmBackgroundActor in
            guard let realm = await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.bookmarkRealmConfiguration) else { return }
            await realm.asyncRefresh()
            try await realm.asyncWrite {
                let deletedBookmarkIDs = Set(realm.objects(Bookmark.self).where { $0.isDeleted }.map { $0.compoundKey })
                for historyRecord in realm.objects(HistoryRecord.self).where({ ($0.bookmarkID == nil || $0.bookmarkID.in(deletedBookmarkIDs)) && !$0.isDeleted }).filter(NSPredicate(format: "url == %@", url.absoluteString)) {
                    historyRecord.bookmarkID = targetBookmarkID
                    historyRecord.refreshChangeMetadata(explicitlyModified: true)
                }
            }
        }
    }
}

extension Bookmark: SyncSkippablePropertiesModel {
    public func skipSyncingProperties() -> Set<String>? {
        if url.isFileURL || url.isHTTP || url.isReaderFileURL {
            return ["htmlContent", "content", "isReaderModeAvailable"]
        }
        return nil
    }
}

public extension Bookmark {
    @RealmBackgroundActor
    static func add(
        url: URL? = nil,
        title: String = "",
        imageUrl: URL? = nil,
        sourceIconURL: URL? = nil,
        html: String? = nil,
        content: Data? = nil,
        publicationDate: Date? = nil,
        isFromClipboard: Bool,
        rssContainsFullContent: Bool,
        isReaderModeByDefault: Bool,
        isReaderModeAvailable: Bool,
        isReaderModeOfferHidden: Bool,
        realmConfiguration: Realm.Configuration
    ) async throws -> Bookmark {
        guard let realm = await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration) else { fatalError("Couldn't get Realm for Bookmark.add") }
        let pk = Bookmark.makePrimaryKey(url: url, html: html)
        if let bookmark = realm.object(ofType: Bookmark.self, forPrimaryKey: pk) {
            await realm.asyncRefresh()
            try await realm.asyncWrite {
                bookmark.title = title
                bookmark.imageUrl = imageUrl
                bookmark.sourceIconURL = sourceIconURL
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
                bookmark.refreshChangeMetadata(explicitlyModified: true)
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
            bookmark.sourceIconURL = sourceIconURL
            bookmark.publicationDate = publicationDate
            bookmark.isFromClipboard = isFromClipboard
            bookmark.isReaderModeByDefault = isReaderModeByDefault
            bookmark.rssContainsFullContent = rssContainsFullContent
            bookmark.isReaderModeAvailable = isReaderModeAvailable
            bookmark.isReaderModeOfferHidden = isReaderModeOfferHidden
            await realm.asyncRefresh()
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
        guard let realm = await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration) else { return }
        await realm.asyncRefresh()
        try await realm.asyncWrite {
            realm.objects(self).setValue(true, forKey: "isDeleted")
            realm.objects(self).setValue(Date(), forKey: "modifiedAt")
        }
    }
}
