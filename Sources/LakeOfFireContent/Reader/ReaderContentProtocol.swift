import Foundation
import LakeOfFireCore
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

public struct ReaderContentProgressMetadata: Sendable {
    public let totalWordCount: Int?
    public let remainingTime: TimeInterval?

    public init(totalWordCount: Int?, remainingTime: TimeInterval?) {
        self.totalWordCount = totalWordCount
        self.remainingTime = remainingTime
    }
}

public enum AudioSubtitlesRole: String, CaseIterable, Sendable {
    case content
    case media
}

private enum ReaderContentFormatters {
    static let snippetChromeDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d/yy"
        return formatter
    }()
}

public extension Date {
    var readerSnippetChromeDateString: String {
        ReaderContentFormatters.snippetChromeDate.string(from: self)
    }
}

public protocol ReaderContentProtocol: RealmSwift.Object, ObjectKeyIdentifiable, Equatable, ThreadConfined, ChangeMetadataRecordable {
    var realm: Realm? { get }
    
    var compoundKey: String { get set }
    var keyPrefix: String? { get }
    
    var url: URL { get set }
    var title: String { get set }
    var isTitlePrefixOfContent: Bool { get set }
    var author: String { get set }
    var imageUrl: URL? { get set }
    var sourceIconURL: URL? { get set }
    var content: Data? { get set }
    var publicationDate: Date? { get set }
    var isFromClipboard: Bool { get set }
    var isPhysicalMedia: Bool { get set }
    
    var isReaderModeOfferHidden: Bool { get set }

    // Caches.
    var isReaderModeAvailable: Bool { get set }
    
    // TODO: Don't populate these if they already exist in user library... or cull
    var rssURLs: List<URL> { get }
    var rssTitles: List<String> { get }
    var isRSSAvailable: Bool { get set }
    
    // Feed entry metadata.
    var voiceFrameUrl: URL? { get set }
    var voiceAudioURL: URL? { get set }
    var voiceAudioURLs: RealmSwift.List<URL> { get set }
    var audioSubtitlesURL: URL? { get set }
    var audioSubtitlesRoleRawValue: String? { get set }
    var redditTranslationsUrl: URL? { get set }
    var redditTranslationsTitle: String? { get set }
    var autoOpenMediaPlayer: Bool { get set }
    
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
    var defaultSnippetChromeTitle: String {
        "Snippet — \(createdAt.readerSnippetChromeDateString)"
    }

    var resolvedVoiceAudioURLs: [URL] {
        var urls = Array(voiceAudioURLs)
        if let voiceAudioURL, !urls.contains(voiceAudioURL) {
            urls.insert(voiceAudioURL, at: 0)
        }
        return urls
    }

    var audioSubtitlesRole: AudioSubtitlesRole? {
        get { audioSubtitlesRoleRawValue.flatMap(AudioSubtitlesRole.init(rawValue:)) }
        set { audioSubtitlesRoleRawValue = newValue?.rawValue }
    }

    var hasContentAudio: Bool {
        voiceAudioURL != nil || !voiceAudioURLs.isEmpty || (audioSubtitlesURL != nil && audioSubtitlesRole != .media)
    }

    var hasAudio: Bool {
        hasContentAudio
    }

    var contentSubtitleURL: URL? {
        audioSubtitlesRole == .media ? nil : audioSubtitlesURL
    }

    @discardableResult
    func copyReaderMediaState<T: ReaderContentProtocol>(
        to destination: T,
        preservingExistingVoiceAudioURL: Bool = true,
        defaultAudioSubtitlesRole: AudioSubtitlesRole? = nil
    ) -> T {
        destination.voiceFrameUrl = voiceFrameUrl
        let resolvedVoiceAudioURLs = resolvedVoiceAudioURLs
        let resolvedVoiceAudioURL = resolvedVoiceAudioURLs.first
        if preservingExistingVoiceAudioURL {
            destination.voiceAudioURL = resolvedVoiceAudioURL ?? destination.voiceAudioURL
        } else {
            destination.voiceAudioURL = resolvedVoiceAudioURL
        }
        destination.voiceAudioURLs.removeAll()
        destination.voiceAudioURLs.append(objectsIn: resolvedVoiceAudioURLs)
        destination.audioSubtitlesURL = audioSubtitlesURL
        destination.audioSubtitlesRoleRawValue = audioSubtitlesRoleRawValue ?? defaultAudioSubtitlesRole?.rawValue
        destination.redditTranslationsUrl = redditTranslationsUrl
        destination.redditTranslationsTitle = redditTranslationsTitle
        destination.autoOpenMediaPlayer = autoOpenMediaPlayer
        return destination
    }

    var keyPrefix: String? {
        return nil
    }

    var defaultLocationBarTitle: String? {
        let url = url
        if url.absoluteString == "about:blank" {
            return nil
        }
        if url.isReaderFileURL {
            return url.lastPathComponent
        }
        if let googleQuery = url.googleSearchQuery {
            return googleQuery
        }
        if let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return url.normalizedHost() ?? url.absoluteString
        }
        return url.normalizedHost() ?? url.absoluteString
    }

    var locationBarTitle: String? {
        defaultLocationBarTitle
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

public extension DeletableReaderContent {
    var deletionConfirmationTitle: String {
        "Are you sure?"
    }

    var deletionConfirmationMessage: String {
        "Do you really want to delete \(title.truncate(20))? Deletion cannot be undone."
    }

    var deletionConfirmationActionTitle: String {
        "Delete"
    }
}

public extension URL {
    func matchesReaderURL(_ url: URL?) -> Bool {
        guard let url = url else { return false }
        if let lhsKey = snippetKey, let rhsKey = url.snippetKey, lhsKey == rhsKey {
            return true
        }
        let lhsContentURL = ReaderContentLoader.getContentURL(fromLoaderURL: self) ?? self
        let rhsContentURL = ReaderContentLoader.getContentURL(fromLoaderURL: url) ?? url
        return lhsContentURL == rhsContentURL
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

fileprivate let longDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
}()

public extension ReaderContentProtocol {
    var humanReadablePublicationDate: String? {
        guard let publicationDate else { return nil}
        
        let oneMonthAgo = Calendar.current.date(byAdding: .month, value: -1, to: Date())
        if displayAbsolutePublicationDate || oneMonthAgo.map({ publicationDate < $0 }) == true {
            return longDateFormatter.string(from: publicationDate)
        } else {
            return ReaderDateFormatter.relativeString(from: publicationDate)
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
            try Task.checkCancellation()
            return html
        } else if url.isReaderFileURL {
            guard let data = try? await readerFileManager.read(fileURL: url) else { return nil }
            try Task.checkCancellation()
            let text = String(decoding: data, as: UTF8.self)
            if let resolvedContentFile = try? await ReaderFileManager.get(fileURL: url) {
                return ReaderContentLoader.normalizeIngestedText(
                    text,
                    mimeType: resolvedContentFile.mimeType,
                    pathExtension: url.pathExtension,
                    source: .file
                ).html
            } else {
                return ReaderContentLoader.normalizeIngestedText(text, pathExtension: url.pathExtension, source: .file).html
            }
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
    
    public var html: String? {
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
            ReaderContentLoader.resolvedDisplayTitle(
                title,
                needsClipboardIndicator: needsClipboardIndicator,
                addClipboardIndicator: needsClipboardIndicator
            )
        }
    }
    
    static func makePrimaryKey(url: URL? = nil, html: String? = nil) -> String? {
        return makeReaderContentCompoundKey(url: url, html: html)
    }
    
    func updateCompoundKey() {
        compoundKey = makeReaderContentCompoundKey(url: url, html: html) ?? compoundKey
    }
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
        let isTitlePrefixOfContent = isTitlePrefixOfContent
        let isReaderModeByDefault = isReaderModeByDefault
        let rssContainsFullContent = rssContainsFullContent
        let isReaderModeAvailable = isReaderModeAvailable
        let isReaderModeOfferHidden = isReaderModeOfferHidden
        let voiceFrameURL = voiceFrameUrl
        let resolvedVoiceAudioURLList = resolvedVoiceAudioURLs
        let resolvedVoiceAudioURL = resolvedVoiceAudioURLList.first
        let resolvedAudioSubtitlesURL = audioSubtitlesURL
        let resolvedAudioSubtitlesRoleRawValue = audioSubtitlesRoleRawValue
        let resolvedRedditTranslationsURL = redditTranslationsUrl
        let resolvedRedditTranslationsTitle = redditTranslationsTitle
        let autoOpenMediaPlayer = autoOpenMediaPlayer
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
                isTitlePrefixOfContent: isTitlePrefixOfContent,
                rssContainsFullContent: rssContainsFullContent,
                isReaderModeByDefault: isReaderModeByDefault,
                isReaderModeAvailable: isReaderModeAvailable,
                isReaderModeOfferHidden: isReaderModeOfferHidden,
                autoOpenMediaPlayer: autoOpenMediaPlayer,
                realmConfiguration: realmConfiguration
            )
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
            if let managedBookmark = realm.object(ofType: Bookmark.self, forPrimaryKey: bookmark.compoundKey) {
                try await realm.asyncWrite {
                    if let content = realm.object(ofType: Self.self, forPrimaryKey: compoundKey) {
                        content.configureBookmark(managedBookmark)
                    } else {
                        managedBookmark.voiceFrameUrl = voiceFrameURL
                        managedBookmark.voiceAudioURL = resolvedVoiceAudioURL
                        managedBookmark.voiceAudioURLs.removeAll()
                        managedBookmark.voiceAudioURLs.append(objectsIn: resolvedVoiceAudioURLList)
                        managedBookmark.audioSubtitlesURL = resolvedAudioSubtitlesURL
                        managedBookmark.audioSubtitlesRoleRawValue = resolvedAudioSubtitlesRoleRawValue ?? (resolvedAudioSubtitlesURL != nil ? AudioSubtitlesRole.content.rawValue : nil)
                        managedBookmark.redditTranslationsUrl = resolvedRedditTranslationsURL
                        managedBookmark.redditTranslationsTitle = resolvedRedditTranslationsTitle
                        managedBookmark.autoOpenMediaPlayer = autoOpenMediaPlayer
                    }
                    managedBookmark.refreshChangeMetadata(explicitlyModified: true)
                }
            }
            
            if let historyRecord = try await HistoryRecord.get(forURL: url), historyRecord.isDemoted != false {
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
            guard let bookmark = realm.object(ofType: Bookmark.self, forPrimaryKey: Bookmark.makePrimaryKey(url: url, html: html)), !bookmark.isDeleted else {
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
        let pk = Bookmark.makePrimaryKey(url: url, html: html)
        return !(realm.object(ofType: Bookmark.self, forPrimaryKey: pk)?.isDeleted ?? true)
    }
    
    func fetchBookmarks(realmConfiguration: Realm.Configuration) -> [Bookmark] {
        let realm = try! Realm(configuration: realmConfiguration)
        return Array(realm.objects(Bookmark.self).where({ $0.isDeleted == false }).sorted(by: \.createdAt)).reversed()
    }
    
    @RealmBackgroundActor
    func addHistoryRecord(realmConfiguration: Realm.Configuration, pageURL: URL) async throws -> HistoryRecord {
        let resolvedPageURL = ReaderContentLoader.getContentURL(fromLoaderURL: pageURL) ?? pageURL
        let resolvedContentURL = ReaderContentLoader.getContentURL(fromLoaderURL: url) ?? url
        debugPrint(
            "# READERLOAD",
            "stage=history.add.begin",
            "contentURL=\(url.absoluteString)",
            "contentIsLoaderURL=\(url.isReaderURLLoaderURL)",
            "pageURL=\(pageURL.absoluteString)",
            "pageIsLoaderURL=\(pageURL.isReaderURLLoaderURL)",
            "resolvedContentURL=\(resolvedContentURL.absoluteString)",
            "resolvedPageURL=\(resolvedPageURL.absoluteString)"
        )
        debugPrint(
            "# READERMODE",
            "stage=history.add.begin",
            "sourceType=\(String(describing: type(of: self)))",
            "contentURL=\(url.absoluteString)",
            "pageURL=\(pageURL.absoluteString)",
            "sourceReaderDefault=\(isReaderModeByDefault)",
            "sourceReaderAvailable=\(isReaderModeAvailable)",
            "rssContainsFullContent=\(rssContainsFullContent)"
        )
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
        if let record = realm.object(ofType: HistoryRecord.self, forPrimaryKey: HistoryRecord.makePrimaryKey(url: pageURL, html: html)) {
//            await realm.asyncRefresh()
            debugPrint(
                "# READERLOAD",
                "stage=history.add.reuse",
                "recordURL=\(record.url.absoluteString)",
                "recordIsLoaderURL=\(record.url.isReaderURLLoaderURL)",
                "pageURL=\(pageURL.absoluteString)"
            )
            let oldReaderDefault = record.isReaderModeByDefault
            let oldReaderAvailable = record.isReaderModeAvailable
            let oldReaderOfferHidden = record.isReaderModeOfferHidden
            try await realm.asyncWrite {
                record.title = title
                record.isTitlePrefixOfContent = isTitlePrefixOfContent
                record.imageUrl = imageURL
                record.sourceIconURL = sourceIconURL
                record.isFromClipboard = isFromClipboard
                record.rssContainsFullContent = rssContainsFullContent
                if rssContainsFullContent {
                    record.content = content
                }
                record.voiceFrameUrl = voiceFrameUrl
                let resolvedVoiceAudioURLList = resolvedVoiceAudioURLs
                record.voiceAudioURL = resolvedVoiceAudioURLList.first
                record.voiceAudioURLs.removeAll()
                record.voiceAudioURLs.append(objectsIn: resolvedVoiceAudioURLList)
                record.audioSubtitlesURL = audioSubtitlesURL
                record.audioSubtitlesRoleRawValue = audioSubtitlesRoleRawValue ?? (audioSubtitlesURL != nil ? AudioSubtitlesRole.content.rawValue : nil)
                record.autoOpenMediaPlayer = autoOpenMediaPlayer
                record.injectEntryImageIntoHeader = injectEntryImageIntoHeader
                record.publicationDate = publicationDate
                record.isReaderModeByDefault = isReaderModeByDefault
                record.isReaderModeAvailable = isReaderModeAvailable
                record.isReaderModeOfferHidden = isReaderModeOfferHidden
                record.displayPublicationDate = displayPublicationDate
                record.lastVisitedAt = Date()
                record.isDeleted = false
                if objectSchema.objectClass == Bookmark.self, let bookmark = self as? Bookmark {
                    record.configureBookmark(bookmark)
                }
                record.refreshChangeMetadata(explicitlyModified: true)
            }
            debugPrint(
                "# READERMODE",
                "stage=history.add.reuse.persist",
                "sourceType=\(String(describing: type(of: self)))",
                "recordURL=\(record.url.absoluteString)",
                "pageURL=\(pageURL.absoluteString)",
                "oldReaderDefault=\(oldReaderDefault)",
                "newReaderDefault=\(record.isReaderModeByDefault)",
                "oldReaderAvailable=\(oldReaderAvailable)",
                "newReaderAvailable=\(record.isReaderModeAvailable)",
                "oldOfferHidden=\(oldReaderOfferHidden)",
                "newOfferHidden=\(record.isReaderModeOfferHidden)",
                "rssContainsFullContent=\(record.rssContainsFullContent)"
            )
            return record
        } else {
            let record = HistoryRecord()
            record.url = pageURL
            debugPrint(
                "# READERLOAD",
                "stage=history.add.create",
                "recordURL=\(record.url.absoluteString)",
                "recordIsLoaderURL=\(record.url.isReaderURLLoaderURL)",
                "pageURL=\(pageURL.absoluteString)"
            )
            record.title = title
            record.isTitlePrefixOfContent = isTitlePrefixOfContent
            record.imageUrl = imageURL
            record.sourceIconURL = sourceIconURL
            record.rssContainsFullContent = rssContainsFullContent
            if rssContainsFullContent {
                record.content = content
            }
            record.voiceFrameUrl = voiceFrameUrl
            let resolvedVoiceAudioURLList = resolvedVoiceAudioURLs
            record.voiceAudioURL = resolvedVoiceAudioURLList.first
            record.voiceAudioURLs.append(objectsIn: resolvedVoiceAudioURLList)
            record.audioSubtitlesURL = audioSubtitlesURL
            record.audioSubtitlesRoleRawValue = audioSubtitlesRoleRawValue ?? (audioSubtitlesURL != nil ? AudioSubtitlesRole.content.rawValue : nil)
            record.autoOpenMediaPlayer = autoOpenMediaPlayer
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
            debugPrint(
                "# READERMODE",
                "stage=history.add.create.persist",
                "sourceType=\(String(describing: type(of: self)))",
                "recordURL=\(record.url.absoluteString)",
                "pageURL=\(pageURL.absoluteString)",
                "readerDefault=\(record.isReaderModeByDefault)",
                "readerAvailable=\(record.isReaderModeAvailable)",
                "offerHidden=\(record.isReaderModeOfferHidden)",
                "rssContainsFullContent=\(record.rssContainsFullContent)"
            )
            
            try await record.refreshDemotedStatus()

            return record
        }
    }
}

public func makeReaderContentCompoundKey(url: URL?, html: String?) -> String? {
    guard url != nil || html != nil else {
//        fatalError("Needs either url or htmlContent.")
        return nil
    }
    var key = ""
    if let url = url, !(url.absoluteString.hasPrefix("about:") || url.absoluteString.hasPrefix("internal://local")) || html == nil {
        key.append(String(format: "%02X", stableHash(url.absoluteString)))
    } else if let html = html {
        key.append((String(format: "%02X", stableHash(html))))
    }
    return key
}
