import Foundation
import RealmSwift
import SwiftUIWebView
import SwiftUtilities
import RealmSwiftGaps
import BigSyncKit
import LakeOfFireCore

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
    nonisolated(unsafe) public static var shared = ReaderContentReadingProgressLoader()

    public init() { }

    /// Float is progress, Bool is whether article is "finished".
    nonisolated(unsafe) public static var readingProgressLoader: ((URL) async throws -> (Float, Bool)?)?
    nonisolated(unsafe) public static var readingProgressMetadataLoader: ((URL) async throws -> ReaderContentProgressMetadata?)?
    nonisolated(unsafe) public static var ebookInitialRestoreLoader: ((URL) async throws -> ReaderContentEbookInitialRestore?)?
}

public struct ReaderContentEbookInitialRestore: Sendable {
    public let cfi: String
    public let fractionalCompletion: Float?

    public init(cfi: String, fractionalCompletion: Float?) {
        self.cfi = cfi
        self.fractionalCompletion = fractionalCompletion
    }
}

@globalActor
public actor ReaderContentSyncStatusLoader {
    public static let shared = ReaderContentSyncStatusLoader()

    public init() { }

    nonisolated(unsafe) public static var syncStatusLoader: (@Sendable (URL) async throws -> ReaderContentSyncStatusPresentation?)?
}

public struct ReaderContentSyncStatusPresentation: Sendable, Hashable {
    public let title: String
    public let imageName: String
    public let imageIsSystemSymbol: Bool

    public init(title: String, imageName: String, imageIsSystemSymbol: Bool) {
        self.title = title
        self.imageName = imageName
        self.imageIsSystemSymbol = imageIsSystemSymbol
    }
}

public enum ReaderContentSyncStatusPresentationBuilder {
    public static func menuPresentation(
        for url: URL,
        externalPresentation: ReaderContentSyncStatusPresentation?
    ) -> ReaderContentSyncStatusPresentation {
        if let externalPresentation {
            return externalPresentation
        }
        return defaultPresentation(for: url)
    }

    public static func defaultPresentation(for url: URL) -> ReaderContentSyncStatusPresentation {
        switch url.scheme?.lowercased() {
        case "ebook", "reader-file":
            if url.pathComponents.dropFirst(2).first?.lowercased() == "icloud" {
                return ReaderContentSyncStatusPresentation(
                    title: "iCloud",
                    imageName: "icloud",
                    imageIsSystemSymbol: true
                )
            }
            return ReaderContentSyncStatusPresentation(title: "Local Only", imageName: "internaldrive", imageIsSystemSymbol: true)
        default:
            return ReaderContentSyncStatusPresentation(title: "Local Only", imageName: "internaldrive", imageIsSystemSymbol: true)
        }
    }
}

public enum ReaderPrimaryMediaKind: String, Sendable, Codable {
    case audio
    case video
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

public enum ReaderContentKind: String, CaseIterable, Sendable {
    case readerContent
    case contentListing
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

    // TODO: Don't populate these if they already exist in My Library... or cull
    var rssURLs: List<URL> { get }
    var rssTitles: List<String> { get }
    var isRSSAvailable: Bool { get set }

    // Feed entry metadata.
    var voiceFrameUrl: URL? { get set }
    var voiceAudioURL: URL? { get set }
    var voiceAudioURLs: RealmSwift.List<URL> { get set }
    var audioSubtitlesURL: URL? { get set }
    var audioSubtitlesRoleRawValue: String? { get set }
    var primaryMediaIdentity: String? { get set }
    var primaryMediaSourceURL: URL? { get set }
    var primaryMediaKindRawValue: String? { get set }
    var primaryMediaDuration: Double? { get set }
    var primaryMediaLastPlaybackTime: Double? { get set }
    var offlineMediaID: String? { get set }
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
    var readerContentKindRawValue: String { get set }
    var feedEntryCollectionKey: String? { get set }
    var feedEntryCollectionScheme: String? { get set }
    var feedEntryCollectionTerm: String? { get set }
    var feedEntryCollectionTitle: String? { get set }

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
    var readerContentKind: ReaderContentKind {
        get { ReaderContentKind(rawValue: readerContentKindRawValue) ?? .readerContent }
        set { readerContentKindRawValue = newValue.rawValue }
    }

    var isContentListing: Bool {
        readerContentKind == .contentListing
    }

    var tracksReadingProgress: Bool {
        !isContentListing
    }

    var primaryMediaKind: ReaderPrimaryMediaKind? {
        get {
            primaryMediaKindRawValue.flatMap { ReaderPrimaryMediaKind(rawValue: $0) }
        }
        set {
            primaryMediaKindRawValue = newValue?.rawValue
        }
    }
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

    var hasPrimaryMedia: Bool {
        isPhysicalMedia
            || primaryMediaIdentity != nil
            || primaryMediaSourceURL != nil
            || primaryMediaKindRawValue != nil
            || primaryMediaDuration != nil
            || primaryMediaLastPlaybackTime != nil
            || offlineMediaID != nil
    }

    var canBookmark: Bool {
        !url.isNativeReaderView && url.absoluteString != "about:blank"
    }

    var contentSubtitleURL: URL? {
        audioSubtitlesRole == .media ? nil : audioSubtitlesURL
    }

    var mediaSubtitleURL: URL? {
        audioSubtitlesRole == .media ? audioSubtitlesURL : nil
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
        destination.readerContentKind = readerContentKind
        destination.feedEntryCollectionKey = feedEntryCollectionKey
        destination.feedEntryCollectionScheme = feedEntryCollectionScheme
        destination.feedEntryCollectionTerm = feedEntryCollectionTerm
        destination.feedEntryCollectionTitle = feedEntryCollectionTitle
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
    func asyncWrite(_ block: @escaping @RealmBackgroundActor (Realm, any ReaderContentProtocol) -> Void) async throws {
        guard !isInvalidated, !isDeleted else { return }
        let owningRealm = realm
        let config = owningRealm?.configuration ?? .defaultConfiguration
        let compoundKey = compoundKey
        let cls = type(of: self)
        try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: config)
            try await realm.asyncWritePreservingOwnership {
                guard let content = realm.object(ofType: cls, forPrimaryKey: compoundKey),
                      !content.isDeleted else { return }
                block(realm, content)
            }
        }()
        await owningRealm?.asyncRefresh()
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
            if let contentFilePrimaryKey = try? await ReaderFileManager.contentFilePrimaryKey(for: url),
               let mimeType = try? await ReaderFileManager.mimeType(forContentFilePrimaryKey: contentFilePrimaryKey) {
                return ReaderContentLoader.normalizeIngestedText(
                    text,
                    mimeType: mimeType,
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
        let readerContentKind = readerContentKind
        let feedEntryCollectionKey = feedEntryCollectionKey
        let feedEntryCollectionScheme = feedEntryCollectionScheme
        let feedEntryCollectionTerm = feedEntryCollectionTerm
        let feedEntryCollectionTitle = feedEntryCollectionTitle
        try await { @RealmBackgroundActor in
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
                readerContentKind: readerContentKind,
                feedEntryCollectionKey: feedEntryCollectionKey,
                feedEntryCollectionScheme: feedEntryCollectionScheme,
                feedEntryCollectionTerm: feedEntryCollectionTerm,
                feedEntryCollectionTitle: feedEntryCollectionTitle,
                realmConfiguration: realmConfiguration
            )
            let realm = try await Realm(configuration: realmConfiguration, actor: RealmBackgroundActor.shared)
            let managedBookmark: Bookmark
            if let existingBookmark = realm.object(ofType: Bookmark.self, forPrimaryKey: bookmark.compoundKey) {
                managedBookmark = existingBookmark
            } else {
                let fallbackBookmark = Bookmark()
                fallbackBookmark.url = url
                fallbackBookmark.title = title
                fallbackBookmark.imageUrl = imageURL
                fallbackBookmark.sourceIconURL = sourceIconURL
                fallbackBookmark.html = html
                fallbackBookmark.content = content
                fallbackBookmark.publicationDate = publicationDate
                fallbackBookmark.isFromClipboard = isFromClipboard
                fallbackBookmark.isTitlePrefixOfContent = isTitlePrefixOfContent
                fallbackBookmark.rssContainsFullContent = rssContainsFullContent
                fallbackBookmark.isReaderModeByDefault = isReaderModeByDefault
                fallbackBookmark.isReaderModeAvailable = isReaderModeAvailable
                fallbackBookmark.isReaderModeOfferHidden = isReaderModeOfferHidden
                fallbackBookmark.autoOpenMediaPlayer = autoOpenMediaPlayer
                fallbackBookmark.updateCompoundKey()
                try realm.writeIfNeeded {
                    realm.add(fallbackBookmark, update: .modified)
                    fallbackBookmark.refreshChangeMetadata(explicitlyModified: true)
                }
                managedBookmark = fallbackBookmark
            }
            try realm.writeIfNeeded {
                let canResolveOriginalType = realm.configuration.objectTypes?.contains(where: { $0 == Self.self }) ?? true
                if canResolveOriginalType, let content = realm.object(ofType: Self.self, forPrimaryKey: compoundKey) {
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
                    managedBookmark.readerContentKind = readerContentKind
                    managedBookmark.feedEntryCollectionKey = feedEntryCollectionKey
                    managedBookmark.feedEntryCollectionScheme = feedEntryCollectionScheme
                    managedBookmark.feedEntryCollectionTerm = feedEntryCollectionTerm
                    managedBookmark.feedEntryCollectionTitle = feedEntryCollectionTitle
                }
                managedBookmark.refreshChangeMetadata(explicitlyModified: true)
            }

            if let historyRecord = HistoryRecord.getOpenedRecord(forURL: url, in: realm),
               historyRecord.isDemoted != false {
                try historyRecord.realm?.writeIfNeeded {
                    historyRecord.isDemoted = false
                    historyRecord.refreshChangeMetadata(explicitlyModified: true)
                }
            }
        }()
        if let html {
            await ReaderContentBackgroundAnalysisLoader.inlineHTMLAnalysisEnqueuer?(url, imageURL, title, html)
        }
    }

    /// Returns whether a matching bookmark was found and deleted.
    @MainActor
    func removeBookmark(realmConfiguration: Realm.Configuration) async throws -> Bool {
        let url = url
        let html = html
        return try await { @RealmBackgroundActor in
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
            let deleted = try await realm.asyncWritePreservingOwnership {
                guard let bookmark = realm.object(ofType: Bookmark.self,
                    forPrimaryKey: Bookmark.makePrimaryKey(url: url, html: html)), !bookmark.isDeleted else { return false }
                bookmark.isDeleted = true
                bookmark.refreshChangeMetadata(explicitlyModified: true)
                return true
            }
            if deleted { ReaderContentLoader.invalidateCachedContent(for: url) }
            return deleted
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
    func addHistoryRecord(
        realmConfiguration: Realm.Configuration,
        pageURL: URL,
        bookmarkRealmConfiguration: Realm.Configuration? = nil
    ) async throws -> HistoryRecord {
        guard !isInvalidated, !isDeleted else { throw CancellationError() }
        let bookmarkRealmConfiguration = bookmarkRealmConfiguration ?? ReaderContentLoader.bookmarkRealmConfiguration
        let sourceReference = ReaderContentLoader.ContentReference(content: self)
        let snapshot = ReaderHistorySourceSnapshot(source: self)
        let historyURL = HistoryRecord.canonicalHistoryURL(for: pageURL)
        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
        let sourceRealm: Realm?
        if let sourceReference {
            sourceRealm = try await RealmBackgroundActor.shared.cachedRealm(for: sourceReference.realmConfiguration)
        } else {
            sourceRealm = nil
        }
        let bookmarkRealm = try await RealmBackgroundActor.shared.cachedRealm(for: bookmarkRealmConfiguration)
        await ReaderContentLoader.contentWriteGateForTesting?(.historyCreation)
        var createdRecord = false
        let recordKey = try await realm.asyncWritePreservingOwnership { () throws -> String in
            try Task.checkCancellation()
            // A visit may revive its history row, but deleting the discovered
            // source while admission suspends cancels this copy operation.
            if let sourceReference, let sourceRealm {
                if sourceRealm != realm { sourceRealm.refresh() }
                guard let source = sourceRealm.object(ofType: sourceReference.contentType,
                    forPrimaryKey: sourceReference.contentKey) as? any ReaderContentProtocol,
                    !source.isDeleted else { throw CancellationError() }
            }
            if bookmarkRealm != realm && bookmarkRealm != sourceRealm { bookmarkRealm.refresh() }
            let timestamp = Date()
            let matchingRecords = HistoryRecord.records(matching: historyURL, in: realm)
            let canonical = HistoryRecord.makePrimaryKey(url: historyURL, html: snapshot.html)
                .flatMap { realm.object(ofType: HistoryRecord.self, forPrimaryKey: $0) }
            let sort = [SortDescriptor(keyPath: "lastVisitedAt", ascending: false),
                        SortDescriptor(keyPath: "compoundKey", ascending: true)]
            let record = matchingRecords.where({ !$0.isDeleted }).sorted(by: sort).first
                ?? canonical ?? matchingRecords.where({ $0.isDeleted }).sorted(by: sort).first
                ?? HistoryRecord()
            let isNew = record.realm == nil
            if isNew { record.url = historyURL }
            snapshot.apply(to: record, isNew: isNew)
            record.lastVisitedAt = timestamp
            // addHistoryRecord is an explicit visit, so an existing tombstone
            // with this content identity can intentionally become live again.
            record.isDeleted = false
            if isNew {
                record.updateCompoundKey()
                realm.add(record, update: .modified)
            }
            if let bookmarkID = snapshot.bookmarkID {
                let deletedIDs = Set(bookmarkRealm.objects(Bookmark.self).where { $0.isDeleted }.map(\.compoundKey))
                for linked in HistoryRecord.openedRecords(matching: snapshot.url, in: realm)
                    .where({ $0.bookmarkID == nil || $0.bookmarkID.in(deletedIDs) }) {
                    linked.bookmarkID = bookmarkID
                    if linked !== record { linked.refreshChangeMetadata(explicitlyModified: true, at: timestamp) }
                }
            }
            createdRecord = isNew
            record.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
            return record.compoundKey
        }
        guard let record = realm.object(ofType: HistoryRecord.self, forPrimaryKey: recordKey), !record.isDeleted else {
            throw CancellationError()
        }
        if createdRecord {
            try await record.refreshDemotedStatus(bookmarkRealmConfiguration: bookmarkRealmConfiguration)
        }
        ReaderContentLoader.invalidateCachedContent(for: historyURL)
        if let html = snapshot.html {
            await ReaderContentBackgroundAnalysisLoader.inlineHTMLAnalysisEnqueuer?(
                snapshot.url, snapshot.imageUrl, snapshot.title, html
            )
        }
        guard let liveRecord = realm.object(ofType: HistoryRecord.self, forPrimaryKey: recordKey), !liveRecord.isDeleted else {
            throw CancellationError()
        }
        return liveRecord
    }
}

/// Detached values captured before a visit waits for its destination writer.
/// Source identity is validated again there; no managed source survives an await.
@RealmBackgroundActor
private struct ReaderHistorySourceSnapshot {
    let url: URL
    let html: String?
    let title: String
    let isTitlePrefixOfContent: Bool
    let imageUrl: URL?
    let sourceIconURL: URL?
    let isFromClipboard: Bool
    let rssContainsFullContent: Bool
    let content: Data?
    let voiceFrameUrl: URL?
    let audioSubtitlesURL: URL?
    let audioSubtitlesRoleRawValue: String?
    let autoOpenMediaPlayer: Bool
    let injectEntryImageIntoHeader: Bool
    let publicationDate: Date?
    let readerContentKind: ReaderContentKind
    let feedEntryCollectionKey: String?
    let feedEntryCollectionScheme: String?
    let feedEntryCollectionTerm: String?
    let feedEntryCollectionTitle: String?
    let isReaderModeByDefault: Bool
    let isReaderModeAvailable: Bool
    let isReaderModeOfferHidden: Bool
    let displayPublicationDate: Bool
    let audioURLs: [URL]
    let bookmarkID: String?
    let rssURLs: [URL]
    let rssTitles: [String]
    let meaningfulContentMinLength: Int?
    let feedContainsFullContent: Bool
    let feedInjectEntryImageIntoHeader: Bool?
    let feedDisplayPublicationDate: Bool?
    let isFeedEntry: Bool
    let redditTranslationsUrl: URL?
    let redditTranslationsTitle: String?

    init(source: any ReaderContentProtocol) {
        url = source.url
        html = source.html
        title = source.title
        isTitlePrefixOfContent = source.isTitlePrefixOfContent
        imageUrl = source.imageUrl ?? (source as? FeedEntry)?.importImageURLWithoutCaching()
        sourceIconURL = source.sourceIconURL
        isFromClipboard = source.isFromClipboard
        rssContainsFullContent = source.rssContainsFullContent
        content = source.content
        voiceFrameUrl = source.voiceFrameUrl
        audioSubtitlesURL = source.audioSubtitlesURL
        audioSubtitlesRoleRawValue = source.audioSubtitlesRoleRawValue ?? (source.audioSubtitlesURL != nil ? AudioSubtitlesRole.content.rawValue : nil)
        autoOpenMediaPlayer = source.autoOpenMediaPlayer
        injectEntryImageIntoHeader = source.injectEntryImageIntoHeader
        publicationDate = source.publicationDate
        readerContentKind = source.readerContentKind
        feedEntryCollectionKey = source.feedEntryCollectionKey
        feedEntryCollectionScheme = source.feedEntryCollectionScheme
        feedEntryCollectionTerm = source.feedEntryCollectionTerm
        feedEntryCollectionTitle = source.feedEntryCollectionTitle
        isReaderModeByDefault = source.isReaderModeByDefault
        isReaderModeAvailable = source.isReaderModeAvailable
        isReaderModeOfferHidden = source.isReaderModeOfferHidden
        displayPublicationDate = source.displayPublicationDate
        audioURLs = source.resolvedVoiceAudioURLs
        isFeedEntry = source is FeedEntry
        redditTranslationsUrl = source.redditTranslationsUrl
        redditTranslationsTitle = source.redditTranslationsTitle
        bookmarkID = source.objectSchema.objectClass == Bookmark.self ? source.compoundKey : nil
        if let feed = (source as? FeedEntry)?.getFeed() {
            rssURLs = [feed.rssUrl]
            rssTitles = [feed.title]
            meaningfulContentMinLength = feed.meaningfulContentMinLength
            feedContainsFullContent = feed.rssContainsFullContent
            feedInjectEntryImageIntoHeader = feed.injectEntryImageIntoHeader
            feedDisplayPublicationDate = feed.displayPublicationDate
        } else {
            rssURLs = []
            rssTitles = []
            meaningfulContentMinLength = nil
            feedContainsFullContent = false
            feedInjectEntryImageIntoHeader = nil
            feedDisplayPublicationDate = nil
        }
    }

    func apply(to record: HistoryRecord, isNew: Bool) {
        record.title = title
        record.isTitlePrefixOfContent = isTitlePrefixOfContent
        record.imageUrl = imageUrl
        record.sourceIconURL = sourceIconURL
        record.isFromClipboard = isFromClipboard
        record.rssContainsFullContent = rssContainsFullContent
        record.voiceFrameUrl = voiceFrameUrl
        record.audioSubtitlesURL = audioSubtitlesURL
        record.audioSubtitlesRoleRawValue = audioSubtitlesRoleRawValue
        record.redditTranslationsUrl = redditTranslationsUrl
        record.redditTranslationsTitle = redditTranslationsTitle
        record.autoOpenMediaPlayer = autoOpenMediaPlayer
        record.injectEntryImageIntoHeader = injectEntryImageIntoHeader
        record.publicationDate = publicationDate
        record.readerContentKind = readerContentKind
        record.feedEntryCollectionKey = feedEntryCollectionKey
        record.feedEntryCollectionScheme = feedEntryCollectionScheme
        record.feedEntryCollectionTerm = feedEntryCollectionTerm
        record.feedEntryCollectionTitle = feedEntryCollectionTitle
        record.isReaderModeByDefault = isReaderModeByDefault
        record.isReaderModeAvailable = isReaderModeAvailable
        record.isReaderModeOfferHidden = isReaderModeOfferHidden
        record.displayPublicationDate = displayPublicationDate
        if rssContainsFullContent { record.content = content }
        record.voiceAudioURL = audioURLs.first
        record.voiceAudioURLs.removeAll()
        record.voiceAudioURLs.append(objectsIn: audioURLs)
        if isNew && isFeedEntry {
            if meaningfulContentMinLength != nil { record.rssContainsFullContent = feedContainsFullContent }
            if record.rssContainsFullContent { record.content = content }
            if let meaningfulContentMinLength { record.meaningfulContentMinLength = meaningfulContentMinLength }
            if let feedInjectEntryImageIntoHeader { record.injectEntryImageIntoHeader = feedInjectEntryImageIntoHeader }
            if let feedDisplayPublicationDate { record.displayPublicationDate = feedDisplayPublicationDate }
            record.redditTranslationsUrl = redditTranslationsUrl
            record.redditTranslationsTitle = redditTranslationsTitle
            // Feed configureBookmark used the content subtitle role even when
            // no subtitle URL existed; preserve that import default.
            record.audioSubtitlesRoleRawValue = audioSubtitlesRoleRawValue ?? AudioSubtitlesRole.content.rawValue
            record.rssURLs.removeAll()
            record.rssURLs.append(objectsIn: rssURLs)
            record.rssTitles.removeAll()
            record.rssTitles.append(objectsIn: rssTitles)
            record.isRSSAvailable = !rssURLs.isEmpty
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
