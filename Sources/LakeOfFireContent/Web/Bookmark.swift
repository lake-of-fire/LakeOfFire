import Foundation
import RealmSwift
import RealmSwiftGaps
import SwiftCloudDrive
import BigSyncKit
import LakeOfFireCore
import LakeOfFireAdblock

private let readerParaBookmarkEmptyParagraphPattern = try! NSRegularExpression(pattern: #"(?is)<p\b[^>]*>\s*</p>"#)
private let readerParaBookmarkBreakOnlyParagraphPattern = try! NSRegularExpression(pattern: #"(?is)<p\b[^>]*>\s*(?:<span\b[^>]*>\s*)?<br\s*/?>\s*(?:</span>\s*)?</p>"#)
private let readerParaBookmarkStandaloneBreakSpanPattern = try! NSRegularExpression(pattern: #"(?is)<span\b[^>]*>\s*<br\s*/?>\s*</span>"#)
private let readerParaBookmarkBreakTagPattern = try! NSRegularExpression(pattern: #"(?is)<br\s*/?>"#)

private func logReaderParaBookmarkPayload(
    stage: String,
    url: URL?,
    html: String?,
    content: Data?
) {
    guard let html else {
        debugPrint(
            "# READERPARA \(stage)",
            "url=\(url?.absoluteString ?? "<nil>")",
            "hasHTML=0",
            "compressedBytes=\(content?.count ?? 0)"
        )
        return
    }
    let range = NSRange(location: 0, length: (html as NSString).length)
    debugPrint(
        "# READERPARA \(stage)",
        "url=\(url?.absoluteString ?? "<nil>")",
        "inputBytes=\(html.utf8.count)",
        "compressedBytes=\(content?.count ?? 0)",
        "emptyParagraphCount=\(readerParaBookmarkEmptyParagraphPattern.numberOfMatches(in: html, options: [], range: range))",
        "breakOnlyParagraphCount=\(readerParaBookmarkBreakOnlyParagraphPattern.numberOfMatches(in: html, options: [], range: range))",
        "standaloneBreakSpanCount=\(readerParaBookmarkStandaloneBreakSpanPattern.numberOfMatches(in: html, options: [], range: range))",
        "breakTagCount=\(readerParaBookmarkBreakTagPattern.numberOfMatches(in: html, options: [], range: range))"
    )
}

open class Bookmark: Object, ReaderContentProtocol, PhysicalMediaCapableProtocol, DeletableReaderContent {
    @Persisted(primaryKey: true) public var compoundKey = ""
    
    @Persisted(indexed: true) public var url = URL(string: "about:blank")!
    @Persisted public var sourceDownloadURL: URL?
    @Persisted public var title = ""
    @Persisted public var author = ""
    @Persisted public var imageUrl: URL?
    @Persisted public var sourceIconURL: URL?
    @Persisted public var publicationDate: Date?
    @Persisted public var isFromClipboard = false
    @Persisted public var isTitlePrefixOfContent = false
    @Persisted public var isPhysicalMedia = false
    
    // Caches
    /// Deprecated, use `content` via `html`.
    @Persisted public var htmlContent: String?
    @Persisted public var content: Data?
    @Persisted public var isReaderModeAvailable = false
    @Persisted public var isReaderModeOfferHidden = false
    
    // Feed entry metadata.
    @Persisted public var rssURLs = RealmSwift.List<URL>()
    @Persisted public var rssTitles = RealmSwift.List<String>()
    @Persisted public var isRSSAvailable = false
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
    
    // Feed options.
    @Persisted public var isReaderModeByDefault = false
    @Persisted public var rssContainsFullContent = false
    @Persisted public var meaningfulContentMinLength = 0
    @Persisted public var injectEntryImageIntoHeader = false
    @Persisted public var displayPublicationDate = true
    @Persisted public var readerContentKindRawValue = ReaderContentKind.readerContent.rawValue
    @Persisted public var feedEntryCollectionKey: String?
    @Persisted public var feedEntryCollectionScheme: String?
    @Persisted public var feedEntryCollectionTerm: String?
    @Persisted public var feedEntryCollectionTitle: String?
    
    @Persisted public var explicitlyModifiedAt: Date?
    @Persisted public var createdAt = Date()
    @Persisted public var modifiedAt = Date()
    @Persisted public var isDeleted = false
    
    open var locationBarTitle: String? {
        let url = url
        if url.isSnippetURL {
            return ReaderContentLoader.resolvedSnippetLocationBarTitle(
                title: title,
                createdAt: createdAt,
                needsClipboardIndicator: needsClipboardIndicator,
                isTitlePrefixOfContent: isTitlePrefixOfContent
            )
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
    
    open var displayAbsolutePublicationDate: Bool {
        return isPhysicalMedia
    }
    
    open func imageURLToDisplay() -> URL? {
        return imageUrl
    }
    
    /// Used by subclasses of Bookmark
    @RealmBackgroundActor
    open func configureBookmark(_ bookmark: Bookmark) {
        guard !isInvalidated, !bookmark.isInvalidated,
              let targetReference = ReaderContentLoader.ContentReference(content: bookmark),
              let targetRealm = bookmark.realm else { return }
        let url = url
        let targetBookmarkID = bookmark.compoundKey
        let historyReferences: [ReaderContentLoader.ContentReference] = targetRealm.schema.objectSchema
            .contains(where: { $0.className == HistoryRecord.className() })
            ? HistoryRecord.openedRecords(matching: url, in: targetRealm)
                .compactMap { ReaderContentLoader.ContentReference(content: $0) }
            : []
        Task { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(
                for: targetReference.realmConfiguration, storageAdmission: targetReference.storageAdmission)
            try await realm.asyncWritePreservingOwnership {
                try Task.checkCancellation()
                try targetReference.validateStorage()
                guard let target = targetReference.resolve(in: realm), !target.isDeleted else { return }
                let timestamp = Date()
                let deletedBookmarkIDs = Set(realm.objects(Bookmark.self).where { $0.isDeleted }.map { $0.compoundKey })
                for reference in historyReferences {
                    guard let historyRecord = reference.resolve(in: realm) as? HistoryRecord,
                          !historyRecord.isDeleted, historyRecord.bookmarkID != targetBookmarkID,
                          historyRecord.bookmarkID == nil || historyRecord.bookmarkID.in(deletedBookmarkIDs) else { continue }
                    historyRecord.bookmarkID = targetBookmarkID
                    historyRecord.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                }
                try targetReference.validateStorage()
                try Task.checkCancellation()
            }
        }
    }

    open var deleteActionTitle: String {
        "Remove from Saved for Later…"
    }
    
    open var deletionConfirmationTitle: String {
        return "Removal Confirmation"
    }
    
    open var deletionConfirmationMessage: String {
        return "Are you sure you want to remove from Saved for Later?"
    }
    
    open var deletionConfirmationActionTitle: String {
        return "Remove"
    }

    @MainActor
    open func delete() async throws {
        guard !isInvalidated,
              let reference = ReaderContentLoader.ContentReference(content: self) else { return }
        let contentURL = url
        let historyConfiguration = ReaderContentLoader.historyRealmConfiguration
        let sameHistoryStore = RealmBackgroundActor.shared.realmCacheKey(
            for: reference.realmConfiguration, includingFileResourceIdentifier: false)
            == RealmBackgroundActor.shared.realmCacheKey(for: historyConfiguration, includingFileResourceIdentifier: false)
        let cleanup = sameHistoryStore ? ReaderContentLoader.TranscriptDeletionContext(
            historyRealmConfiguration: historyConfiguration, ownerHistoryRealmConfiguration: historyConfiguration) : nil
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(
                for: reference.realmConfiguration, storageAdmission: reference.storageAdmission)
            try await realm.asyncWritePreservingOwnership {
                try Task.checkCancellation()
                try reference.validateStorage()
                guard let content = reference.resolve(in: realm), !content.isDeleted else { return }
                content.isDeleted = true
                content.refreshChangeMetadata(explicitlyModified: true)
                try reference.validateStorage()
                try Task.checkCancellation()
            }
            if let cleanup {
                try await ReaderContentLoader.softDeleteTranscriptsIfNoRemainingOwners(contentURL: contentURL, context: cleanup)
            }
        }()
    }

    open func skipSyncingProperties() -> Set<String>? {
        if url.isFileURL || url.isHTTP || url.isReaderFileURL {
            return ["htmlContent", "content", "isReaderModeAvailable"]
        }
        return nil
    }
}

extension Bookmark: SyncSkippablePropertiesModel {}

/// Compare the bookmark's scalar columns and value lists around a configure hook.
/// Detach lists before the hook mutates them; never compare live Realm collections.
@RealmBackgroundActor
private func bookmarkMutationValues(_ bookmark: Bookmark) -> [String: AnyHashable] {
    Dictionary(uniqueKeysWithValues: bookmark.objectSchema.properties.map { property in
        let value: AnyHashable
        switch bookmark[property.name] {
        case let list as RealmSwift.List<URL>:
            value = AnyHashable(Array(list))
        case let list as RealmSwift.List<String>:
            value = AnyHashable(Array(list))
        case nil:
            value = AnyHashable(NSNull())
        case let scalar as AnyHashable:
            value = scalar
        default:
            preconditionFailure("Unsupported bookmark configure value: \(property.name)")
        }
        return (property.name, value)
    })
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
        isTitlePrefixOfContent: Bool = false,
        rssContainsFullContent: Bool,
        isReaderModeByDefault: Bool,
        isReaderModeAvailable: Bool,
        isReaderModeOfferHidden: Bool = false,
        autoOpenMediaPlayer: Bool = false,
        readerContentKind: ReaderContentKind = .readerContent,
        feedEntryCollectionKey: String? = nil,
        feedEntryCollectionScheme: String? = nil,
        feedEntryCollectionTerm: String? = nil,
        feedEntryCollectionTitle: String? = nil,
        realmConfiguration: Realm.Configuration
    ) async throws -> Bookmark {
        let admission = RealmBackgroundActor.shared.captureStorageAdmission(for: realmConfiguration)
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration, storageAdmission: admission)
        return try await realm.asyncWritePreservingOwnership {
            try Task.checkCancellation()
            guard admission.matchesCurrentStorageIdentity({
                RealmBackgroundActor.shared.realmCacheKey(for: realmConfiguration)
            }) else { throw RealmBackgroundActorError.realmFileChangedDuringOpen }
            let bookmark = addInOwnedWrite(
                url: url,
                title: title,
                imageUrl: imageUrl,
                sourceIconURL: sourceIconURL,
                html: html,
                content: content,
                publicationDate: publicationDate,
                isFromClipboard: isFromClipboard,
                isTitlePrefixOfContent: isTitlePrefixOfContent,
                rssContainsFullContent: rssContainsFullContent,
                isReaderModeByDefault: isReaderModeByDefault,
                isReaderModeAvailable: isReaderModeAvailable,
                isReaderModeOfferHidden: isReaderModeOfferHidden,
                autoOpenMediaPlayer: autoOpenMediaPlayer,
                readerContentKind: readerContentKind,
                feedEntryCollectionKey: feedEntryCollectionKey,
                feedEntryCollectionScheme: feedEntryCollectionScheme,
                feedEntryCollectionTerm: feedEntryCollectionTerm,
                feedEntryCollectionTitle: feedEntryCollectionTitle,
                realm: realm
            )
            try Task.checkCancellation()
            guard admission.matchesCurrentStorageIdentity({
                RealmBackgroundActor.shared.realmCacheKey(for: realmConfiguration)
            }) else { throw RealmBackgroundActorError.realmFileChangedDuringOpen }
            return bookmark
        }
    }

    @RealmBackgroundActor
    internal static func addInOwnedWrite(
        url: URL? = nil,
        title: String = "",
        imageUrl: URL? = nil,
        sourceIconURL: URL? = nil,
        html: String? = nil,
        content: Data? = nil,
        publicationDate: Date? = nil,
        isFromClipboard: Bool,
        isTitlePrefixOfContent: Bool = false,
        rssContainsFullContent: Bool,
        isReaderModeByDefault: Bool,
        isReaderModeAvailable: Bool,
        isReaderModeOfferHidden: Bool = false,
        autoOpenMediaPlayer: Bool = false,
        readerContentKind: ReaderContentKind = .readerContent,
        feedEntryCollectionKey: String? = nil,
        feedEntryCollectionScheme: String? = nil,
        feedEntryCollectionTerm: String? = nil,
        feedEntryCollectionTitle: String? = nil,
        realm: Realm,
        at timestamp: Date = Date(),
        configure: (@RealmBackgroundActor (Bookmark) -> Void)? = nil
    ) -> Bookmark {
        precondition(realm.isInWriteTransaction)
        let primaryKey = url.flatMap { $0.snippetKey ?? Bookmark.makePrimaryKey(url: $0) }
            ?? Bookmark.makePrimaryKey(url: nil, html: html ?? Bookmark.contentToHTML(content: content))
            ?? Bookmark.makePrimaryKey(url: URL(string: "about:blank"))
        let existing = primaryKey.flatMap { realm.object(ofType: Bookmark.self, forPrimaryKey: $0) }
        let bookmark = existing ?? Bookmark()
        let isNew = existing == nil
        var didChange = isNew
        if isNew, let url { bookmark.url = url }
        func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<Bookmark, Value>, _ value: Value) {
            guard bookmark[keyPath: keyPath] != value else { return }
            bookmark[keyPath: keyPath] = value
            didChange = true
        }
        let sanitizedTitle = title.removingClipboardIndicatorIfNeeded(isFromClipboard || (url?.isSnippetURL ?? false))
        assign(\.title, sanitizedTitle)
        assign(\.imageUrl, imageUrl)
        assign(\.sourceIconURL, sourceIconURL)
        assign(\.publicationDate, publicationDate)
        assign(\.isFromClipboard, isFromClipboard)
        assign(\.isTitlePrefixOfContent, isTitlePrefixOfContent)
        assign(\.isReaderModeByDefault, isReaderModeByDefault)
        assign(\.isReaderModeAvailable, isReaderModeAvailable)
        assign(\.isReaderModeOfferHidden, isReaderModeOfferHidden)
        assign(\.rssContainsFullContent, rssContainsFullContent)
        assign(\.autoOpenMediaPlayer, autoOpenMediaPlayer)
        assign(\.readerContentKind, readerContentKind)
        assign(\.feedEntryCollectionKey, feedEntryCollectionKey)
        assign(\.feedEntryCollectionScheme, feedEntryCollectionScheme)
        assign(\.feedEntryCollectionTerm, feedEntryCollectionTerm)
        assign(\.feedEntryCollectionTitle, feedEntryCollectionTitle)
        assign(\.isDeleted, false)
        if let html, bookmark.html != html {
            logReaderParaBookmarkPayload(stage: isNew ? "bookmark.persist.create.html" : "bookmark.persist.update.html",
                url: url, html: html, content: html.readerContentData)
            bookmark.html = html
            didChange = true
        } else if html == nil, let content, bookmark.content != content {
            logReaderParaBookmarkPayload(stage: isNew ? "bookmark.persist.create.content" : "bookmark.persist.update.content",
                url: url, html: Bookmark.contentToHTML(content: content), content: content)
            bookmark.content = content
            didChange = true
        }
        if isNew {
            if let primaryKey { bookmark.compoundKey = primaryKey }
            else { bookmark.updateCompoundKey() }
            if url == nil {
                bookmark.url = ReaderContentLoader.snippetURL(key: bookmark.compoundKey) ?? bookmark.url
            }
            realm.add(bookmark)
        }
        if let configure {
            // The hook needs the managed row, and its final values must be in
            // the same journal generation as the base bookmark changes.
            let previousValues = didChange ? nil : bookmarkMutationValues(bookmark)
            configure(bookmark)
            if let previousValues, previousValues != bookmarkMutationValues(bookmark) {
                didChange = true
            }
        }
        if didChange { bookmark.refreshChangeMetadata(explicitlyModified: true, at: timestamp) }
        return bookmark
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
        let admission = RealmBackgroundActor.shared.captureStorageAdmission(for: realmConfiguration)
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration, storageAdmission: admission)
        try await realm.asyncWritePreservingOwnership {
            try Task.checkCancellation()
            guard admission.matchesCurrentStorageIdentity({ RealmBackgroundActor.shared.realmCacheKey(for: realmConfiguration) }) else {
                throw RealmBackgroundActorError.realmFileChangedDuringOpen
            }
            let timestamp = Date()
            for record in realm.objects(self).where({ !$0.isDeleted }) {
                record.isDeleted = true
                record.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
            }
            try Task.checkCancellation()
            guard admission.matchesCurrentStorageIdentity({ RealmBackgroundActor.shared.realmCacheKey(for: realmConfiguration) }) else {
                throw RealmBackgroundActorError.realmFileChangedDuringOpen
            }
        }
    }
}
