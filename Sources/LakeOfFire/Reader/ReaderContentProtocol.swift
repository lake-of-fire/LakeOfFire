import Foundation
import RealmSwift
import SwiftUIWebView
import SwiftUtilities
import RealmSwiftGaps
import BigSyncKit

public let clipboardIndicatorPrefixPattern = #"^(?:📎\s*)+"#

public extension String {
    func removingClipboardIndicatorPrefix() -> String {
        replacingOccurrences(of: clipboardIndicatorPrefixPattern, with: "", options: [.regularExpression])
    }
    
    func removingClipboardIndicatorIfNeeded(_ shouldRemove: Bool) -> String {
        guard shouldRemove else { return self }
        return removingClipboardIndicatorPrefix()
    }
}

@globalActor
public actor ReaderContentReadingProgressLoader {
    public static var shared = ReaderContentReadingProgressLoader()
    
    public init() { }
    
    /// Float is progress, Bool is whether article is "finished".
    public static var readingProgressLoader: ((URL) async throws -> (Float, Bool)?)?
    public static var readingProgressMetadataLoader: ((URL) async throws -> ReaderContentProgressMetadata?)?
}

public struct ReaderContentProgressMetadata {
    public let totalWordCount: Int?
    public let remainingTime: TimeInterval?
    
    public init(totalWordCount: Int?, remainingTime: TimeInterval?) {
        self.totalWordCount = totalWordCount
        self.remainingTime = remainingTime
    }
}

public protocol ReaderContentProtocol: RealmSwift.Object, ObjectKeyIdentifiable, Equatable, ThreadConfined, ChangeMetadataRecordable {
    var realm: Realm? { get }
    
    var compoundKey: String { get set }
    var keyPrefix: String? { get }
    
    var url: URL { get set }
    var title: String { get set }
    var author: String { get set }
    var imageUrl: URL? { get set }
    var sourceIconURL: URL? { get set }
    var content: Data? { get set }
    var publicationDate: Date? { get set }
    var isFromClipboard: Bool { get set }
    var isPhysicalMedia: Bool { get set }
    
    // Caches.
    var isReaderModeAvailable: Bool { get set }
    
    // TODO: Don't populate these if they already exist in user library... or cull
    var rssURLs: List<URL> { get }
    var rssTitles: List<String> { get }
    var isRSSAvailable: Bool { get set }
    
    // Feed entry metadata.
    var voiceFrameUrl: URL? { get set }
    var voiceAudioURLs: RealmSwift.List<URL> { get set }
    var audioSubtitlesURL: URL? { get set }
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
    var modifiedAt: Date { get set }
    var isDeleted: Bool { get set }
    
    var displayAbsolutePublicationDate: Bool { get }
    var locationBarTitle: String? { get }

    func imageURLToDisplay() async throws -> URL?
    @RealmBackgroundActor
    func configureBookmark(_ bookmark: Bookmark)
}

public extension ReaderContentProtocol {
    var keyPrefix: String? {
        return nil
    }
    
    var canBookmark: Bool {
        guard !url.isNativeReaderView else {
            return false
        }
        return url.absoluteString != "about:blank"
    }
    
    @MainActor
    func asyncWrite(_ block: @escaping ((Realm, any ReaderContentProtocol) -> Void)) async throws {
        let config = realm?.configuration ?? .defaultConfiguration
        let compoundKey = compoundKey
        let cls = type(of: self)// objectSchema.objectClass
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: config)
            guard let content = realm.object(ofType: cls, forPrimaryKey: compoundKey) else { return }
//            await realm.asyncRefresh()
            try await realm.asyncWrite {
                block(realm, content)
            }
        }()
        await realm?.asyncRefresh()
    }
}

public protocol DeletableReaderContent: ReaderContentProtocol {
    var isDeleted: Bool { get set }
    var deleteActionTitle: String { get }
    var deletionConfirmationTitle: String { get }
    var deletionConfirmationMessage: String { get }
    var deletionConfirmationActionTitle: String { get }
    func delete() async throws
}

public extension URL {
    func matchesReaderURL(_ url: URL?) -> Bool {
        guard let url = url else { return false }
        if let contentURL = ReaderContentLoader.getContentURL(fromLoaderURL: url) {
            return urlsMatchWithoutHash(contentURL, self)
        }
        return urlsMatchWithoutHash(url, self)
    }
}

public extension WebViewState {
    func matches(content: any ReaderContentProtocol) -> Bool {
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

fileprivate let humanReadableAbsoluteDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .long
    formatter.timeStyle = .none
    return formatter
}()

public extension ReaderContentProtocol {
    var humanReadablePublicationDate: String? {
        guard let publicationDate else { return nil}

        if displayAbsolutePublicationDate {
            return ReaderDateFormatter.absoluteString(
                from: publicationDate,
                dateFormatter: humanReadableAbsoluteDateFormatter
            )
        } else {
            return ReaderDateFormatter.relativeOrAbsoluteString(
                from: publicationDate,
                fallbackFormatter: humanReadableAbsoluteDateFormatter,
                style: .short
            )
        }
    }
    
    static func contentToHTML(legacyHTMLContent: String? = nil, content: Data?) -> String? {
        if let legacyHtml = legacyHTMLContent {
            return legacyHtml
        }
        guard let content else { return nil }
        let nsContent: NSData = content as NSData
        guard let data = try? nsContent.decompressed(using: .lzfse) as Data? else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
    
    // TODO: Refactor to put on background thread
    @MainActor
    public func htmlToDisplay(readerFileManager: ReaderFileManager) async throws -> String? {
        // rssContainsFullContent name is out of date; it just means this object contains the full content (RSS or otherwise)
        if rssContainsFullContent || isFromClipboard {
            let html = self.html
            try Task.checkCancellation()
            if url.isSnippetURL {
                let bytes = html?.utf8.count ?? 0
                let preview = html.flatMap { snippetPreview($0, maxLength: 240) } ?? "<nil>"
                debugPrint(
                    "# READER snippetContent.rawHTML",
                    "url=\(url.absoluteString)",
                    "bytes=\(bytes)",
                    "preview=\(preview)"
                )
            }
            return html
        } else if url.isReaderFileURL {
            guard let data = try? await readerFileManager.read(fileURL: url) else {
                return nil
            }
            try Task.checkCancellation()
            let html = String(decoding: data, as: UTF8.self)
            return html
        }
        return nil
    }
    
    /// Deprecated, use `content` or `html`.
    var htmlContent: String? {
        get {
            return nil
        }
        set { }
    }
    
    internal var html: String? {
        get {
            Self.contentToHTML(legacyHTMLContent: htmlContent, content: content)
        }
        set {
            htmlContent = nil
            content = newValue?.readerContentData
        }
    }
    
    var hasHTML: Bool {
        if rssContainsFullContent || isFromClipboard || url.isSnippetURL {
            if htmlContent != nil {
                return true
            }
            return content != nil
        } else if url.isReaderFileURL {
            return true // Expects file to exist
        }
        return false
    }
    
    var needsClipboardIndicator: Bool {
        isFromClipboard || url.isSnippetURL
    }
    
    var titleForDisplay: String {
        get {
            var displayTitle = title.removingClipboardIndicatorIfNeeded(needsClipboardIndicator)
            displayTitle = displayTitle.removingHTMLTags() ?? displayTitle
            if displayTitle.isEmpty {
                displayTitle = "Untitled"
            }
            if needsClipboardIndicator {
                return "📎 " + displayTitle
            }
            return displayTitle
        }
    }
    
    static func makePrimaryKey(url: URL? = nil, existingKey: String? = nil) -> String? {
        return makeReaderContentCompoundKey(url: url, existingKey: existingKey)
    }

    func updateCompoundKey() {
        compoundKey = makeReaderContentCompoundKey(url: url, existingKey: compoundKey) ?? compoundKey
    }
}

private func snippetPreview(_ html: String, maxLength: Int = 240) -> String {
    let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "<empty>" }
    guard trimmed.count > maxLength else { return trimmed }
    let idx = trimmed.index(trimmed.startIndex, offsetBy: maxLength)
    return String(trimmed[..<idx]) + "…"
}

public extension ReaderContentProtocol {
//    var rawEntryThumbnailContentMode: Int = UIView.ContentMode.scaleAspectFill.rawValue
    /*var entryThumbnailContentMode: UIView.ContentMode {
        get {
            return UIView.ContentMode(rawValue: rawEntryThumbnailContentMode)!
        }
        set {
            rawEntryThumbnailContentMode = newValue.rawValue
        }
    }*/
    
//    var isReaderModeByDefault: Bool {
//        if isFromClipboard {
//            return true
//        }
////        guard let bareHostURL = URL(string: "\(url.scheme ?? "https")://\(url.host ?? "")") else { return false }
////        let exists = realm.objects(FeedEntry.self).contains { $0.url.absoluteString.starts(with: bareHostURL.absoluteString) && $0.isReaderModeByDefault } // not strict enough?
//        guard let configuration = realm?.configuration else { return false }
//        let exists = try! !Realm(configuration: configuration).objects(FeedEntry.self).filter(NSPredicate(format: "url == %@", url.absoluteString)).where { $0.isReaderModeByDefault }.isEmpty
//        return exists
//    }
}

public extension ReaderContentProtocol {
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
        let compoundKey = compoundKey
        let url = url
        let title = title
        let html = html
        let content = content
        let publicationDate = publicationDate
        let imageURL = imageUrl
        let sourceIconURL = sourceIconURL
        let isFromClipboard = isFromClipboard
        let isReaderModeByDefault = isReaderModeByDefault
        let rssContainsFullContent = rssContainsFullContent
        let isReaderModeAvailable = isReaderModeAvailable
        try await { @RealmBackgroundActor [weak self] in
            guard let self = self else { return }
            let bookmark = try await Bookmark.add(
                url: url,
                title: title,
                imageUrl: imageURL,
                sourceIconURL: sourceIconURL,
                html: html,
                content: content,
                publicationDate: publicationDate,
                isFromClipboard: isFromClipboard,
                rssContainsFullContent: rssContainsFullContent,
                isReaderModeByDefault: isReaderModeByDefault,
                isReaderModeAvailable: isReaderModeAvailable,
                realmConfiguration: realmConfiguration
            )
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
            if let content = realm.object(ofType: Self.self, forPrimaryKey: compoundKey) {
                content.configureBookmark(bookmark)
            }
            
            let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.historyRealmConfiguration)
            if let historyRecord = HistoryRecord.get(forURL: url, realm: historyRealm), historyRecord.isDemoted != false {
                try await historyRecord.realm?.asyncWrite {
                    historyRecord.isDemoted = false
                    historyRecord.refreshChangeMetadata(explicitlyModified: true)
                }
            }
        }()
    }
    
    /// Returns whether a matching bookmark was found and deleted.
    @MainActor
    func removeBookmark(realmConfiguration: Realm.Configuration) async throws -> Bool {
        let url = url
        let html = html
        return try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
            guard let bookmark = realm.object(ofType: Bookmark.self, forPrimaryKey: Bookmark.makePrimaryKey(url: url)), !bookmark.isDeleted else {
                return false
            }
//            await realm.asyncRefresh()
            try await realm.asyncWrite {
                bookmark.isDeleted = true
                bookmark.refreshChangeMetadata(explicitlyModified: true)
            }
            return true
        }()
    }
    
    func bookmarkExists(realmConfiguration: Realm.Configuration) -> Bool {
        let realm = try! Realm(configuration: realmConfiguration)
        let pk = Bookmark.makePrimaryKey(url: url)
        return !(realm.object(ofType: Bookmark.self, forPrimaryKey: pk)?.isDeleted ?? true)
    }
    
    func fetchBookmarks(realmConfiguration: Realm.Configuration) -> [Bookmark] {
        let realm = try! Realm(configuration: realmConfiguration)
        return Array(realm.objects(Bookmark.self).where({ $0.isDeleted == false }).sorted(by: \.createdAt)).reversed()
    }
    
    @RealmBackgroundActor
    func addHistoryRecord(realmConfiguration: Realm.Configuration, pageURL: URL) async throws -> HistoryRecord {
        var imageURL: URL?
        let ref = ThreadSafeReference(to: self)
        if let config = realm?.configuration {
            imageURL = try await { @MainActor in
                let realm = try await Realm(configuration: config, actor: MainActor.shared)
                let content = realm.resolve(ref)
                return try await content?.imageURLToDisplay()
            }()
        }
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
        let sanitizedTitle = title.removingClipboardIndicatorIfNeeded(isFromClipboard || pageURL.isSnippetURL)

        if let record = realm.object(ofType: HistoryRecord.self, forPrimaryKey: HistoryRecord.makePrimaryKey(url: pageURL)) {
//            await realm.asyncRefresh()
            try await realm.asyncWrite {
                record.title = sanitizedTitle
                record.imageUrl = imageURL
                record.sourceIconURL = sourceIconURL
                record.isFromClipboard = isFromClipboard
                record.rssContainsFullContent = rssContainsFullContent
                if rssContainsFullContent {
                    record.content = content
                }
                record.isReaderModeByDefault = isReaderModeByDefault
                record.isReaderModeAvailable = isReaderModeAvailable
                record.voiceFrameUrl = voiceFrameUrl
                record.audioSubtitlesURL = audioSubtitlesURL
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
                record.refreshChangeMetadata(explicitlyModified: true)
            }
            return record
        } else {
            let record = HistoryRecord()
            record.url = pageURL
            record.title = sanitizedTitle
            record.imageUrl = imageURL
            record.sourceIconURL = sourceIconURL
            record.rssContainsFullContent = rssContainsFullContent
            if rssContainsFullContent {
                record.content = content
            }
            record.voiceFrameUrl = voiceFrameUrl
            record.audioSubtitlesURL = audioSubtitlesURL
            record.voiceAudioURLs.append(objectsIn: voiceAudioURLs)
            record.publicationDate = publicationDate
            record.displayPublicationDate = displayPublicationDate
            record.isFromClipboard = isFromClipboard
            record.isReaderModeByDefault = isReaderModeByDefault
            record.isReaderModeAvailable = isReaderModeAvailable
            record.injectEntryImageIntoHeader = injectEntryImageIntoHeader
            record.lastVisitedAt = Date()
            if objectSchema.objectClass == FeedEntry.self || objectSchema.objectClass == Bookmark.self, let bookmark = self as? Bookmark {
                record.configureBookmark(bookmark)
            }
            record.updateCompoundKey()
//            await realm.asyncRefresh()
            try await realm.asyncWrite {
                realm.add(record, update: .modified)
            }
            
            try await record.refreshDemotedStatus()

            return record
        }
    }
}

public func makeReaderContentCompoundKey(url: URL?, existingKey: String? = nil) -> String? {
    if let url = url {
        if let snippetKey = url.snippetKey {
            return snippetKey
        }

        if url.scheme?.lowercased() == "about" {
            return existingKey.nonEmpty ?? UUID().uuidString
        }

        return String(format: "%02X", stableHash(url.absoluteString))
    }

    return existingKey.nonEmpty ?? UUID().uuidString
}
private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self, !value.isEmpty else { return nil }
        return value
    }
}
