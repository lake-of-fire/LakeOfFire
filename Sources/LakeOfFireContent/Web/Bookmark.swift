import Foundation
import RealmSwift
import RealmSwiftGaps
import SwiftCloudDrive
import BigSyncKit
import LakeOfFireCore
import LakeOfFireAdblock

public class Bookmark: Object, ReaderContentProtocol, PhysicalMediaCapableProtocol, DeletableReaderContent {
    @Persisted(primaryKey: true) public var compoundKey = ""
    
    @Persisted(indexed: true) public var url = URL(string: "about:blank")!
    @Persisted public var sourceDownloadURL: URL?
    @Persisted public var title = ""
    @Persisted public var author = ""
    @Persisted public var imageUrl: URL?
    @Persisted public var sourceIconURL: URL?
    @Persisted public var publicationDate: Date?
    @Persisted public var isFromClipboard = false
    @Persisted public var isPhysicalMedia = false
    
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
    @Persisted public var voiceAudioURL: URL?
    @Persisted public var audioSubtitlesURL: URL?
    @Persisted public var redditTranslationsUrl: URL?
    @Persisted public var redditTranslationsTitle: String?
    
    // Feed options.
    @Persisted public var isReaderModeByDefault = false
    @Persisted public var rssContainsFullContent = false
    @Persisted public var meaningfulContentMinLength = 0
    @Persisted public var injectEntryImageIntoHeader = false
    @Persisted public var displayPublicationDate = true
    
    @Persisted public var explicitlyModifiedAt: Date?
    @Persisted public var createdAt = Date()
    @Persisted public var modifiedAt = Date()
    @Persisted public var isDeleted = false
    
    public var locationBarTitle: String? {
        let url = url
        if url.isSnippetURL {
            return "Snippet: \(createdAt.formatted())"
        } else if url.isEBookURL {
            return title
        } else if url.isReaderFileURL {
            return url.lastPathComponent
        } else if url.isReaderURLLoaderURL {
            if let loadURLHost = ReaderContentLoader.getContentURL(fromLoaderURL: url)?.normalizedHost() {
                return loadURLHost
            }
        } else if url.absoluteString == "about:blank" {
            return nil
        } else if url.scheme == "http" || url.scheme == "https" {
            if let googleQuery = url.googleSearchQuery {
                return googleQuery
            }
            // Otherwise, fall back to host or full URL
            return url.normalizedHost() ?? url.absoluteString
        }
        return url.normalizedHost() ?? url.absoluteString
    }
    
    public var displayAbsolutePublicationDate: Bool {
        return isPhysicalMedia
    }
    
    public func imageURLToDisplay() -> URL? {
        return imageUrl
    }
    
    /// Used by subclasses of Bookmark
    @RealmBackgroundActor
    public func configureBookmark(_ bookmark: Bookmark) {
        let url = url
        let targetBookmarkID = bookmark.compoundKey
        Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.bookmarkRealmConfiguration)
            //            await realm.asyncRefresh()
            try await realm.asyncWrite {
                let deletedBookmarkIDs = Set(realm.objects(Bookmark.self).where { $0.isDeleted }.map { $0.compoundKey })
                for historyRecord in realm.objects(HistoryRecord.self).where({ ($0.bookmarkID == nil || $0.bookmarkID.in(deletedBookmarkIDs)) && !$0.isDeleted }).filter(NSPredicate(format: "url == %@", url.absoluteString)) {
                    historyRecord.bookmarkID = targetBookmarkID
                    historyRecord.refreshChangeMetadata(explicitlyModified: true)
                }
            }
        }
    }
    
    public var deleteActionTitle: String {
        "Remove from Saved for Later…"
    }
    
    public var deletionConfirmationTitle: String {
        return "Removal Confirmation"
    }
    
    public var deletionConfirmationMessage: String {
        return "Are you sure you want to remove from Saved for Later?"
    }
    
    public var deletionConfirmationActionTitle: String {
        return "Remove"
    }

    @MainActor
    public func delete() async throws {
        guard let contentRef = ReaderContentLoader.ContentReference(content: self) else { return }
        try await { @RealmBackgroundActor in
            guard let content = try await contentRef.resolveOnBackgroundActor() else { return }
            //            await content.realm?.asyncRefresh()
            try await content.realm?.asyncWrite {
                //            for videoStatus in realm.objects(VideoS)
                content.isDeleted = true
                content.refreshChangeMetadata(explicitlyModified: true)
            }
        }()
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
    static func get(forURL url: URL, realm: Realm) -> Self? {
        return realm.objects(Self.self)
            .filter(NSPredicate(format: "isDeleted == false AND url == %@", url.absoluteString as CVarArg))
            .sorted(byKeyPath: "createdAt", ascending: false)
            .first
    }
    
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
        realmConfiguration: Realm.Configuration
    ) async throws -> Bookmark {
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
        let pk = Bookmark.makePrimaryKey(url: url)
        let shouldStripClipboardIndicator = isFromClipboard || (url?.isSnippetURL ?? false)
        let sanitizedTitle = title.removingClipboardIndicatorIfNeeded(shouldStripClipboardIndicator)
        if let bookmark = realm.object(ofType: Bookmark.self, forPrimaryKey: pk) {
            //            await realm.asyncRefresh()
            try await realm.asyncWrite {
                bookmark.title = sanitizedTitle
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
            bookmark.title = sanitizedTitle
            bookmark.imageUrl = imageUrl
            bookmark.sourceIconURL = sourceIconURL
            bookmark.publicationDate = publicationDate
            bookmark.isFromClipboard = isFromClipboard
            bookmark.isReaderModeByDefault = isReaderModeByDefault
            bookmark.rssContainsFullContent = rssContainsFullContent
            bookmark.isReaderModeAvailable = isReaderModeAvailable
            //            await realm.asyncRefresh()
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
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
        //        await realm.asyncRefresh()
        try await realm.asyncWrite {
            realm.objects(self).setValue(true, forKey: "isDeleted")
            realm.objects(self).setValue(Date(), forKey: "modifiedAt")
        }
    }
}
