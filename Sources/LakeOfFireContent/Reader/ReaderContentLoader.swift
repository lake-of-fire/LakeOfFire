import SwiftUI
import LakeOfFireCore
import RealmSwift
import MarkdownKit
import SwiftSoup
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import RealmSwiftGaps
import UniformTypeIdentifiers

public struct ReaderContentMutationOutcome: Sendable {
    public let matchedObjectCount: Int
    /// Successfully committed or already-applied object representations.
    public let committedObjectCount: Int
    public let mutatedObjectCount: Int
    public let cancelledBeforeCommit: Bool
    public let errorMessage: String?

    public init(matchedObjectCount: Int, committedObjectCount: Int, mutatedObjectCount: Int = 0, cancelledBeforeCommit: Bool, errorMessage: String?) {
        self.matchedObjectCount = matchedObjectCount
        self.committedObjectCount = committedObjectCount
        self.mutatedObjectCount = mutatedObjectCount
        self.cancelledBeforeCommit = cancelledBeforeCommit
        self.errorMessage = errorMessage
    }
}



fileprivate extension URL {
    func settingScheme(_ value: String) -> URL {
        let components = NSURLComponents.init(url: self, resolvingAgainstBaseURL: true)
        components?.scheme = value
        return (components?.url!)!
    }
}

public extension URL {
    var isReaderURLLoaderURL: Bool {
        return scheme == "internal" && host == "local" && path == "/load/reader"
    }
}

/// Loads from any source by URL.
public struct ReaderContentLoader {
    @MainActor
    private static var inFlightGetContentTasks: [String: Task<(any ReaderContentProtocol)?, Error>] = [:]
    @RealmBackgroundActor
    private static var inFlightLoadAllTasks: [String: Task<[ContentReference], Error>] = [:]

    public struct ContentReference {
        public let contentType: RealmSwift.Object.Type
        public let contentKey: String
        public let realmConfiguration: Realm.Configuration
        
        public init?(content: any ReaderContentProtocol) {
            guard let contentType = content.objectSchema.objectClass as? RealmSwift.Object.Type, let config = content.realm?.configuration else { return nil }
            self.contentType = contentType
            contentKey = content.compoundKey
            realmConfiguration = config
        }
        
        @RealmBackgroundActor
        public func resolveOnBackgroundActor() async throws -> (any ReaderContentProtocol)? {
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration)
            try await realm.asyncRefresh()
            return realm.object(ofType: contentType, forPrimaryKey: contentKey) as? any ReaderContentProtocol
        }
        
        @MainActor
        public func resolveOnMainActor() async throws -> (any ReaderContentProtocol)? {
            let realm = try await Realm.open(configuration: realmConfiguration)
            try await realm.asyncRefresh()
            return realm.object(ofType: contentType, forPrimaryKey: contentKey) as? any ReaderContentProtocol
        }
    }
    
    public static var bookmarkRealmConfiguration: Realm.Configuration = .defaultConfiguration
    public static var historyRealmConfiguration: Realm.Configuration = .defaultConfiguration
    public static var feedEntryRealmConfiguration: Realm.Configuration = .defaultConfiguration

    /// The storage selected when a snippet edit began. A delayed save must not
    /// follow mutable global configurations into another account's Realm.
    public struct SnippetStorage {
        public let bookmarkConfiguration: Realm.Configuration
        public let historyConfiguration: Realm.Configuration

        private init(
            bookmarkConfiguration: Realm.Configuration,
            historyConfiguration: Realm.Configuration
        ) {
            self.bookmarkConfiguration = bookmarkConfiguration
            self.historyConfiguration = historyConfiguration
        }

        /// The app stores both snippet representations in the selected
        /// content's Reader Realm. Its owning Realm outranks mutable globals.
        @MainActor
        public init?(content: any ReaderContentProtocol) {
            guard let configuration = content.realm?.configuration else { return nil }
            bookmarkConfiguration = configuration
            historyConfiguration = configuration
        }

        /// Legacy storage can span two Realms. Its edits are atomic per Realm,
        /// not across stores; a later failure may follow an earlier commit.
        @MainActor
        public static func capture() -> Self {
            Self(
                bookmarkConfiguration: ReaderContentLoader.bookmarkRealmConfiguration,
                historyConfiguration: ReaderContentLoader.historyRealmConfiguration
            )
        }
    }

    public static func resetTransientCachesForTesting() async {
        await MainActor.run {
            inFlightGetContentTasks.removeAll()
        }
        await { @RealmBackgroundActor in
            inFlightLoadAllTasks.removeAll()
        }()
    }

    @MainActor
    public static func hasLocallyRetrievableHTML(
        for content: any ReaderContentProtocol,
        readerFileManager: ReaderFileManager
    ) async throws -> Bool {
        let html = try await content.htmlToDisplay(readerFileManager: readerFileManager)
        return html?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
 
    public static var unsavedHome: (any ReaderContentProtocol) {
//        return try await Self.load(url: URL(string: "about:blank")!, persist: false)!
        let historyRecord = HistoryRecord()
        historyRecord.url = URL(string: "about:blank")!
        historyRecord.updateCompoundKey()
        return historyRecord
    }
    
    @MainActor
    public static var home: (any ReaderContentProtocol) {
        get async throws {
            return try await Self.load(url: URL(string: "about:blank")!, persist: true)!
        }
    }
    
    public static func getContentURL(fromLoaderURL pageURL: URL) -> URL? {
        pageURL.readerLoaderContentURL
    }

    private static func loadAllTaskKey(url: URL, skipContentFiles: Bool, skipFeedEntries: Bool) -> String {
        "\(url.absoluteString)|contentFiles:\(!skipContentFiles)|feedEntries:\(!skipFeedEntries)"
    }

    @RealmBackgroundActor
    private static func resolveContentReferences(
        _ references: [ContentReference]
    ) async throws -> [(any ReaderContentProtocol)] {
        var resolvedContents = [(any ReaderContentProtocol)]()
        resolvedContents.reserveCapacity(references.count)
        for reference in references {
            if let content = try await reference.resolveOnBackgroundActor() {
                resolvedContents.append(content)
            }
        }
        return resolvedContents
    }
    
    @RealmBackgroundActor
    public static func loadAll(url: URL, skipContentFiles: Bool = false, skipFeedEntries: Bool = false) async throws -> [(any ReaderContentProtocol)] {
        let taskKey = loadAllTaskKey(url: url, skipContentFiles: skipContentFiles, skipFeedEntries: skipFeedEntries)
        // Coalesce only overlapping queries. Completed membership can become
        // obsolete as soon as load() creates a history record or a bookmark is
        // added, so authoritative reads and writes must query it again.
        if let existingTask = inFlightLoadAllTasks[taskKey] {
            return try await resolveContentReferences(existingTask.value)
        }

        let task = Task<[ContentReference], Error> { @RealmBackgroundActor in
            try Task.checkCancellation()

            var contentFile: ContentFile?
            if !skipContentFiles {
                contentFile = try await ContentFile.get(forURL: url)
            }
            let history = try await HistoryRecord.getOpenedRecord(forURL: url)
            let bookmark = try await Bookmark.get(forURL: url)

            var feed: FeedEntry?
            if !skipFeedEntries {
                let feedRealm = try await RealmBackgroundActor.shared.cachedRealm(for: feedEntryRealmConfiguration)
                let feeds = feedRealm.objects(FeedEntry.self)
                    .where { !$0.isDeleted }
                    .sorted(by: \.createdAt, ascending: false)

                if url.scheme == "https" {
                    feed = feeds.filter(NSPredicate(format: "url == %@ OR url == %@", url.absoluteString as CVarArg, url.settingScheme("http").absoluteString as CVarArg)).first
                } else if !url.isReaderFileURL {
                    feed = feeds.filter(NSPredicate(format: "url == %@", url.absoluteString as CVarArg)).first
                }
            }

            let candidates: [any ReaderContentProtocol] = [contentFile, bookmark, history, feed].compactMap { $0 }
            return candidates.compactMap(ContentReference.init(content:))
        }

        inFlightLoadAllTasks[taskKey] = task
        defer { inFlightLoadAllTasks[taskKey] = nil }
        let references = try await task.value
        return try await resolveContentReferences(references)
    }

    @RealmBackgroundActor
    private static func storedContentReference(for url: URL) async throws -> ReaderContentLoader.ContentReference? {
        try Task.checkCancellation()
        guard !(url.scheme == "internal" && url.absoluteString.hasPrefix("internal://local/load/")) else {
            return nil
        }
        guard url.absoluteString != "about:blank" else {
            return nil
        }

        let candidates = try await loadAll(url: url)
        let match = candidates.max(by: {
            ($0 as? HistoryRecord)?.lastVisitedAt ?? $0.createdAt < ($1 as? HistoryRecord)?.lastVisitedAt ?? $1.createdAt
        })
        guard let match else {
            return nil
        }
        return ReaderContentLoader.ContentReference(content: match)
    }

    @MainActor
    public static func lookupStoredContent(url: URL) async throws -> (any ReaderContentProtocol)? {
        let resolvedURL = getContentURL(fromLoaderURL: url) ?? url
        let contentRef = try await { @RealmBackgroundActor () -> ReaderContentLoader.ContentReference? in
            try await storedContentReference(for: resolvedURL)
        }()
        try Task.checkCancellation()
        return try await contentRef?.resolveOnMainActor()
    }

    @MainActor
    public static func recordHistoryVisit(
        for content: any ReaderContentProtocol,
        source: String = "ReaderContentLoader.recordHistoryVisit"
    ) async throws {
        let pageURL = content.url
        let targetHistoryRealmConfiguration = historyRealmConfiguration
        if let contentReference = ContentReference(content: content) {
            let didRecordVisit = try await { @RealmBackgroundActor in
                guard let resolvedContent =
                    try await contentReference.resolveOnBackgroundActor() else {
                    return false
                }
                _ = try await resolvedContent.addHistoryRecord(
                    realmConfiguration: targetHistoryRealmConfiguration,
                    pageURL: pageURL
                )
                return true
            }()
            if didRecordVisit {
                return
            }
        }

        _ = try await load(
            url: pageURL,
            countsAsHistoryVisit: true,
            source: source
        )
    }

    @MainActor
    public static func getContent(
        forURL pageURL: URL,
        countsAsHistoryVisit: Bool = false,
        source: String = "ReaderContentLoader.getContent"
    ) async throws -> (any ReaderContentProtocol)? {
        let resolvedURL = ReaderContentLoader.getContentURL(fromLoaderURL: pageURL) ?? pageURL
        let taskKey = "\(resolvedURL.absoluteString)|history:\(countsAsHistoryVisit)"
        if let existingTask = inFlightGetContentTasks[taskKey] {
            return try await existingTask.value
        }

        let task = Task<(any ReaderContentProtocol)?, Error> { @MainActor in
            if let contentURL = ReaderContentLoader.getContentURL(fromLoaderURL: pageURL),
               let content = try await ReaderContentLoader.load(
                url: contentURL,
                countsAsHistoryVisit: countsAsHistoryVisit,
                source: "\(source).loaderRedirect"
               ) {
                try Task.checkCancellation()
                return content
            } else if let content = try await ReaderContentLoader.load(
                url: pageURL,
                persist: !pageURL.isNativeReaderView,
                countsAsHistoryVisit: countsAsHistoryVisit,
                source: "\(source).directLoad"
            ) {
                try Task.checkCancellation()
                return content
            }
            try Task.checkCancellation()
            return nil
        }

        inFlightGetContentTasks[taskKey] = task
        defer { inFlightGetContentTasks[taskKey] = nil }
        return try await task.value
    }

    /// Update all reader-content objects that share the given URL. The updater returns true if it mutated the object.
    @RealmBackgroundActor
    public static func updateContent(
        url: URL,
        skipContentFiles: Bool = false,
        skipFeedEntries: Bool = false,
        mutate: (Object & ReaderContentProtocol) -> Bool
    ) async throws {
        let result = await performContentMutation(url: url, skipContentFiles: skipContentFiles, skipFeedEntries: skipFeedEntries, mutate: mutate)
        if let error = result.error { throw error }
    }

    /// Reports durable outcomes even if cancellation or a later Realm failure
    /// prevents updating every representation of this content.
    @RealmBackgroundActor
    public static func updateContentWithOutcome(
        url: URL,
        skipContentFiles: Bool = false,
        skipFeedEntries: Bool = false,
        mutate: (Object & ReaderContentProtocol) -> Bool
    ) async -> ReaderContentMutationOutcome {
        await performContentMutation(url: url, skipContentFiles: skipContentFiles, skipFeedEntries: skipFeedEntries, mutate: mutate).outcome
    }

    @RealmBackgroundActor
    private static func performContentMutation(
        url: URL,
        skipContentFiles: Bool,
        skipFeedEntries: Bool,
        mutate: (Object & ReaderContentProtocol) -> Bool
    ) async -> (outcome: ReaderContentMutationOutcome, error: Error?) {
        var matched = 0
        var committed = 0
        var mutated = 0
        var cancelledBeforeCommit = false
        do {
            let objects = try await loadAll(url: url, skipContentFiles: skipContentFiles, skipFeedEntries: skipFeedEntries)
            matched = objects.count
            let timestamp = Date()
            for case let object as (Object & ReaderContentProtocol) in objects {
                guard !Task.isCancelled else { cancelledBeforeCommit = true; break }
                guard let realm = object.realm, !object.isInvalidated else { continue }
                let change: Bool? = try await realm.asyncWritePreservingOwnership {
                    // Fence admission at the existing Realm write lane. Once a
                    // transaction returns, cancellation cannot revoke its result.
                    guard !Task.isCancelled, !object.isInvalidated else { return nil }
                    let changed = mutate(object)
                    if changed { object.refreshChangeMetadata(explicitlyModified: true, at: timestamp) }
                    return changed
                }
                guard let change else { cancelledBeforeCommit = Task.isCancelled; continue }
                // Includes already-applied no-op selections, without refreshing
                // metadata or creating another upload generation for them.
                committed += 1
                if change { mutated += 1 }
            }
            return (ReaderContentMutationOutcome(matchedObjectCount: matched, committedObjectCount: committed, mutatedObjectCount: mutated, cancelledBeforeCommit: cancelledBeforeCommit, errorMessage: nil), nil)
        } catch {
            cancelledBeforeCommit = cancelledBeforeCommit || error is CancellationError || Task.isCancelled
            return (ReaderContentMutationOutcome(matchedObjectCount: matched, committedObjectCount: committed, mutatedObjectCount: mutated, cancelledBeforeCommit: cancelledBeforeCommit, errorMessage: error.localizedDescription), error)
        }
    }

    @MainActor
    public static func load(
        url: URL,
        persist: Bool = true,
        countsAsHistoryVisit: Bool = false,
        source: String = "ReaderContentLoader.load"
    ) async throws -> (any ReaderContentProtocol)? {
        if url.isTranscriptPageURL {
            // These are registered, source-bound derived pages. A missing asset
            // must not create a persisted empty history record for its local URL.
            return await TranscriptPageRegistry.shared.makeReaderContent(for: url)
        }
        let contentRef = try await { @RealmBackgroundActor () -> ReaderContentLoader.ContentReference? in
            try Task.checkCancellation()
            
            if url.scheme == "internal" && url.absoluteString.hasPrefix("internal://local/load/") {
                // Don't persist about:load
                // TODO: Perhaps return an empty history record to avoid catching the wrong content in this interim, though.
                return nil
            } else if url.absoluteString == "about:blank" { //}&& !persist {
                let historyRecord = HistoryRecord()
                historyRecord.url = url
                historyRecord.isDemoted = true
                historyRecord.updateCompoundKey()
                return ReaderContentLoader.ContentReference(content: historyRecord)
            }
            
            var match: (any ReaderContentProtocol)?
            let candidates = try await loadAll(url: url)
            match = candidates.max(by: {
                ($0 as? HistoryRecord)?.lastVisitedAt ?? $0.createdAt < ($1 as? HistoryRecord)?.lastVisitedAt ?? $1.createdAt
            })
            if let nonHistoryMatch = match, countsAsHistoryVisit && persist, nonHistoryMatch.objectSchema.objectClass != HistoryRecord.self {
                match = try await nonHistoryMatch.addHistoryRecord(realmConfiguration: historyRealmConfiguration, pageURL: url)
            } else if let historyMatch = match as? HistoryRecord,
                      countsAsHistoryVisit,
                      persist,
                      let historyRealm = historyMatch.realm {
                try await historyRealm.asyncWritePreservingOwnership {
                    historyMatch.lastVisitedAt = Date()
                    historyMatch.isDeleted = false
                    historyMatch.refreshChangeMetadata(explicitlyModified: true)
                }
            } else if match == nil, !url.isEBookURL {
                let historyRecord = HistoryRecord()
                historyRecord.url = url
                //        historyRecord.isReaderModeByDefault
                historyRecord.updateCompoundKey()
                if persist {
                    let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(for: historyRealmConfiguration)
                    // Another load/capture may have committed while this query
                    // was suspended. Never replace that row with new defaults.
                    match = try await historyRealm.asyncWritePreservingOwnership {
                        let timestamp = Date()
                        if let existing = historyRealm.object(ofType: HistoryRecord.self, forPrimaryKey: historyRecord.compoundKey) {
                            if countsAsHistoryVisit || existing.isDeleted {
                                if countsAsHistoryVisit { existing.lastVisitedAt = timestamp }
                                existing.isDeleted = false
                                existing.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                            }
                            return existing
                        }
                        historyRealm.add(historyRecord)
                        historyRecord.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                        return historyRecord
                    }
                } else {
                    match = historyRecord
                }
            }
            
            try Task.checkCancellation()
            if persist, let match = match, url.isReaderFileURL, url.contains(.plainText), let realm = match.realm {
//                await realm.asyncRefresh()
                try await realm.asyncWritePreservingOwnership {
                    match.isReaderModeByDefault = true
                    match.refreshChangeMetadata(explicitlyModified: true)
                }
            } else if persist, let match = match, url.isEBookURL, !match.isReaderModeByDefault, let realm = match.realm {
//                await realm.asyncRefresh()
                try await realm.asyncWritePreservingOwnership {
                    match.isReaderModeByDefault = true
                    match.refreshChangeMetadata(explicitlyModified: true)
                }
            }
            guard let match else { return nil }
            
            if let historyRecord = match as? HistoryRecord {
                try await historyRecord.refreshDemotedStatus()
            }

            return ReaderContentLoader.ContentReference(content: match)
        }()
        try Task.checkCancellation()
        return try await contentRef?.resolveOnMainActor()
    }
    
    @MainActor
    public static func load(urlString: String, countsAsHistoryVisit: Bool = false) async throws -> (any ReaderContentProtocol)? {
        guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme ?? ""), url.host != nil else { return nil }
        return try await load(
            url: url,
            countsAsHistoryVisit: countsAsHistoryVisit,
            source: "ReaderContentLoader.load.urlString"
        )
    }
    
    @MainActor
    public static func load(
        html: String,
        allowContentMatch: Bool = true
    ) async throws -> (any ReaderContentProtocol)? {
        let contentRef = try await { @RealmBackgroundActor () -> ReaderContentLoader.ContentReference? in
            let bookmarkRealm = try await RealmBackgroundActor.shared.cachedRealm(for: bookmarkRealmConfiguration)
            let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(for: historyRealmConfiguration)
            let feedRealm = try await RealmBackgroundActor.shared.cachedRealm(for: feedEntryRealmConfiguration)
            
            let normalizedHTML = normalizeSnippetSourceHTML(html)
            let data = normalizedHTML.readerContentData
            let generatedTitle = generatedSnippetTitle(fromSourceHTML: normalizedHTML) ?? ""

            if allowContentMatch {
                let bookmark = bookmarkRealm.objects(Bookmark.self)
                    .sorted(by: \.createdAt, ascending: false)
                    .where { $0.content == data }
                    .first
                let history = historyRealm.objects(HistoryRecord.self)
                    .sorted(by: \.createdAt, ascending: false)
                    .where { $0.content == data }
                    .first
                let feed = feedRealm.objects(FeedEntry.self)
                    .sorted(by: \.createdAt, ascending: false)
                    .where { $0.content == data }
                    .first
                let candidates: [any ReaderContentProtocol] = [bookmark, history, feed].compactMap { $0 }

                if let match = candidates.max(by: { $0.createdAt < $1.createdAt }) {
                    return ReaderContentLoader.ContentReference(content: match)
                }
            }
            
            let historyRecord = HistoryRecord()
            if !allowContentMatch {
                let freshSnippetKey = UUID().uuidString.uppercased()
                historyRecord.compoundKey = freshSnippetKey
                historyRecord.url = snippetURL(key: freshSnippetKey) ?? historyRecord.url
            }
            historyRecord.publicationDate = Date()
            historyRecord.content = data
            historyRecord.title = generatedTitle
            historyRecord.isTitlePrefixOfContent = !generatedTitle.isEmpty
            // isReaderModeByDefault used to be commented out... why?
            historyRecord.isReaderModeByDefault = true
            historyRecord.isDemoted = false
            if allowContentMatch {
                historyRecord.updateCompoundKey()
                historyRecord.url = snippetURL(key: historyRecord.compoundKey) ?? historyRecord.url
            }
            historyRecord.rssContainsFullContent = true
//            await historyRealm.asyncRefresh()
            // The cached actor-bound Realm may still be committing an earlier
            // async write when another startup load enters this actor. Queue
            // this transaction instead of synchronously beginning a second one.
            try await historyRealm.asyncWritePreservingOwnership {
                historyRealm.add(historyRecord, update: .modified)
                historyRecord.refreshChangeMetadata(explicitlyModified: true)
            }

            
            return ReaderContentLoader.ContentReference(content: historyRecord)
        }()
        
        return try await contentRef?.resolveOnMainActor()
    }
    
    /// Returns a URL to load for the given content into a Reader instance. The URL is either a resource (like a web location),
    /// or an internal "local" URL for loading HTML content in Reader Mode.
    @MainActor
    public static func load(
        content: any ReaderContentProtocol,
        readerFileManager: ReaderFileManager
    ) async throws -> URL? {
        let contentURL = content.url
        let canonicalReaderBackingURL = readerFileManager.canonicalReaderBackingURL(for: contentURL)
        let contentHasLocallyRetrievableHTML = try await hasLocallyRetrievableHTML(
            for: content,
            readerFileManager: readerFileManager
        )

        if contentURL.isSnippetURL {
            if contentHasLocallyRetrievableHTML, let loaderURL = readerLoaderURL(for: contentURL) {
                return loaderURL
            }
            return content.url
        }

        if ["http", "https"].contains(contentURL.scheme?.lowercased()) {
            if content.isReaderModeByDefault,
               contentHasLocallyRetrievableHTML,
               let loaderURL = readerLoaderURL(for: contentURL) {
                return loaderURL
            }

            if let matchingContent = try await lookupStoredContent(url: contentURL),
               matchingContent.isReaderModeByDefault,
               (try? await hasLocallyRetrievableHTML(
                    for: matchingContent,
                    readerFileManager: readerFileManager
               )) == true,
               let matchingURL = readerLoaderURL(for: matchingContent.url) {
                return matchingURL
            }
            return content.url
        }

        if let canonicalReaderBackingURL,
           !contentURL.isReaderFileURL {
            _ = try await readerFileManager.resolveReadableLocalURL(
                forReaderBackingURL: canonicalReaderBackingURL
            )
        }

        if contentURL.isReaderFileURL,
           contentHasLocallyRetrievableHTML,
           let loaderURL = readerLoaderURL(for: contentURL) {
            return loaderURL
        }
        
        return content.url
    }

    static func docIsPlainText(doc: SwiftSoup.Document) -> Bool {
        return (
            ((doc.body()?.children().isEmpty()) ?? true)
            || ((doc.body()?.children().first()?.tagNameNormal() ?? "") == "pre" && doc.body()?.children().count == 1) )
    }
    
    public static func textToHTMLDoc(_ text: String) throws -> SwiftSoup.Document {
        let html = textToHTML(text)
        return try SwiftSoup.parse(html)
    }

    private static func rawPlainTextToHTML(_ text: String) -> String {
        let normalizedText = text.replacingOccurrences(of: "\r\n", with: "\n")
        var paragraphs = [String]()
        var currentParagraphLines = [String]()

        let flushParagraph = {
            guard !currentParagraphLines.isEmpty else { return }
            paragraphs.append("<p>\(currentParagraphLines.joined(separator: "<br>"))</p>")
            currentParagraphLines.removeAll()
        }

        for line in normalizedText.components(separatedBy: "\n") {
            if line.isEmpty {
                flushParagraph()
            } else {
                currentParagraphLines.append(line.escapeHtml())
            }
        }
        flushParagraph()

        return "<html><body>\(paragraphs.joined())</body></html>"
    }
    
    public static func textToHTML(_ text: String, forceRaw: Bool = false) -> String {
        var convertedText = text
        if forceRaw {
            convertedText = rawPlainTextToHTML(text)
        } else if let doc = try? SwiftSoup.parse(text) {
            if docIsPlainText(doc: doc) {
                convertedText = "<html><body>\(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "<br>"))</body></html>"
            }
        } else {
            convertedText = "<html><body>\(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "<br>"))</body></html>"
        }
        return convertedText
    }
    
    public static func snippetURL(key: String) -> URL? {
        return URL(string: "internal://local/snippet?key=\(key)")
    }

    public static func readerLoaderURL(for contentURL: URL) -> URL? {
        guard let encodedURL = contentURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            return nil
        }
        return URL(string: "internal://local/load/reader?reader-url=\(encodedURL)")
    }
    
    @MainActor
    public static func load(
        text: String,
        allowContentMatch: Bool = true
    ) async throws -> (any ReaderContentProtocol)? {
        let html = snippetHTML(fromRawText: text)
        return try await load(html: html, allowContentMatch: allowContentMatch)
    }
    
    @MainActor
    public static func loadPasteboard(
        bookmarkRealmConfiguration: Realm.Configuration = .defaultConfiguration,
        historyRealmConfiguration: Realm.Configuration = .defaultConfiguration,
        feedEntryRealmConfiguration: Realm.Configuration = .defaultConfiguration,
        allowContentMatch: Bool = true
    ) async throws -> (any ReaderContentProtocol)? {
        var match: (any ReaderContentProtocol)?
        let (html, text) = pasteboardImportStrings()
        
        if let text, let url = URL(string: text), url.absoluteString == text, url.scheme != nil, url.host != nil {
            match = try await load(url: url, countsAsHistoryVisit: true)
        } else if let payload = preferredPasteboardPayload(html: html, text: text) {
            let normalized = normalizeIngestedText(payload.text, explicitHTML: payload.explicitHTML, source: .paste)
            match = try await load(html: normalized.html, allowContentMatch: allowContentMatch)
        }

        if let match, let realmConfiguration = match.realm?.configuration {
            if match.url.isSnippetURL {
                let type = type(of: match)
                let pk = match.primaryKeyValue
                guard let url = URL(string: match.url.absoluteString) else { return nil }
                try await { @RealmBackgroundActor in
                    let realm = try await RealmBackgroundActor.shared.cachedRealm(for: realmConfiguration) 
                    if let pk = pk, let content = realm.object(ofType: type, forPrimaryKey: pk), let content = content as? (any ReaderContentProtocol) {
                        let url = snippetURL(key: content.compoundKey) ?? content.url
//                        await realm.asyncRefresh()
                        try await realm.asyncWritePreservingOwnership {
                            content.isFromClipboard = true
                            content.rssContainsFullContent = true
                            content.isReaderModeByDefault = true
                            content.url = url
                            content.refreshChangeMetadata(explicitlyModified: true)
                        }
                    }
                }()
                return match.realm?.object(ofType: type, forPrimaryKey: pk) as? (any ReaderContentProtocol)? ?? nil
            } else {
                return match
            }
        }
        return nil
    }

    @MainActor
    private static func pasteboardImportStrings() -> (html: String?, text: String?) {

#if os(macOS)
        let html = NSPasteboard.general.string(forType: .html)
        let text = NSPasteboard.general.string(forType: .string)
#else
        let pasteboard = UIPasteboard.general
        let htmlData = pasteboard.data(forPasteboardType: UTType.html.identifier)
        let htmlFromData = htmlData.flatMap {
            String(data: $0, encoding: .utf8)
                ?? String(data: $0, encoding: .unicode)
                ?? String(data: $0, encoding: .utf16LittleEndian)
                ?? String(data: $0, encoding: .utf16BigEndian)
        }
        let htmlFromValue = pasteboard.value(forPasteboardType: UTType.html.identifier) as? String
        let html = htmlFromData ?? htmlFromValue
        let text = pasteboard.string
#endif
        return (html, text)
    }

    public static func snippetHTML(fromRawText text: String) -> String {
        normalizeSnippetSourceHTML(textToHTML(text, forceRaw: true))
    }

    public static func snippetHTMLFromPasteText(_ text: String) -> String {
        let normalized = normalizeIngestedText(text, explicitHTML: false, source: .paste)
        return normalizeSnippetSourceHTML(normalized.html)
    }

    public static func snippetHTML(fromHTML html: String) -> String {
        normalizeSnippetSourceHTML(html)
    }

    public static let snippetReaderTitleSuppressionBodyClass = "mnb-hide-redundant-snippet-reader-title"

    public static func normalizedDisplayTitle(
        _ rawTitle: String,
        needsClipboardIndicator: Bool
    ) -> String {
        var displayTitle = rawTitle.removingClipboardIndicatorIfNeeded(needsClipboardIndicator)
        // Preserve one-layer decoding: entity-encoded angle brackets are display text, not markup.
        displayTitle = displayTitle.removingHTMLTags() ?? displayTitle
        if displayTitle.contains("&") {
            displayTitle = (try? Entities.unescape(displayTitle)) ?? displayTitle
        }
        return displayTitle
    }

    public static func resolvedDisplayTitle(
        _ rawTitle: String,
        needsClipboardIndicator: Bool,
        addClipboardIndicator: Bool = false
    ) -> String {
        var displayTitle = normalizedDisplayTitle(
            rawTitle,
            needsClipboardIndicator: needsClipboardIndicator
        )
        if displayTitle.isEmpty {
            displayTitle = "Untitled"
        }
        if addClipboardIndicator {
            return "📎 " + displayTitle
        }
        return displayTitle
    }

    public static func resolvedSnippetLocationBarTitle(
        title: String,
        createdAt: Date,
        needsClipboardIndicator: Bool,
        isTitlePrefixOfContent: Bool
    ) -> String {
        let fallbackTitle = "Snippet — \(createdAt.readerSnippetChromeDateString)"
        if isTitlePrefixOfContent {
            return fallbackTitle
        }
        let cleanedTitle = resolvedDisplayTitle(
            title,
            needsClipboardIndicator: needsClipboardIndicator
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanedTitle.isEmpty ? fallbackTitle : cleanedTitle
    }

    private static func snippetAutoTitleCompactComparisonValue(_ raw: String?) -> String? {
        canonicalSnippetAutoTitleComparisonValue(raw)?
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
    }

    private static func canonicalSnippetAutoTitleComparisonValue(_ raw: String?) -> String? {
        normalizedSnippetAutoTitle(raw)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "…").union(.whitespacesAndNewlines))
    }

    public static func normalizedSnippetAutoTitle(_ raw: String?) -> String? {
        let rawValue = raw ?? ""
        let sanitized = rawValue.removingHTMLTags() ?? rawValue
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.truncate(36)
    }

    public static func generatedSnippetTitle(fromSourceHTML html: String) -> String? {
        titleFromReadabilityHTML(normalizeSnippetSourceHTML(html))
            .flatMap { normalizedSnippetAutoTitle($0) }
    }

    private static func titleFromReadabilityHTML(_ html: String) -> String? {
        if let doc = try? SwiftSoup.parse(html) {
            if let readerTitleText = try? doc.getElementById("reader-title")?.text(),
               let title = normalizedSnippetAutoTitle(readerTitleText) {
                return title
            }
            if let headingText = try? doc.getElementsByTag("h1").first()?.text(),
               let title = normalizedSnippetAutoTitle(headingText) {
                return title
            }
            if let headTitle = try? doc.title(),
               let title = normalizedSnippetAutoTitle(headTitle) {
                return title
            }
            if let bodyText = try? doc.body()?.text(),
               let title = normalizedSnippetAutoTitle(bodyText) {
                return title
            }
        }
        let stripped = html.removingHTMLTags() ?? html
        return normalizedSnippetAutoTitle(stripped.components(separatedBy: "\n").first ?? stripped)
    }

    public static func snippetTitleMatchesGeneratedPrefix(
        _ title: String,
        sourceHTML: String?
    ) -> Bool {
        let generatedTitle = sourceHTML.flatMap { generatedSnippetTitle(fromSourceHTML: $0) }
        let canonicalTitle = canonicalSnippetAutoTitleComparisonValue(title)
        let canonicalGeneratedTitle = canonicalSnippetAutoTitleComparisonValue(generatedTitle)
        let compactTitle = snippetAutoTitleCompactComparisonValue(title)
        let compactGeneratedTitle = snippetAutoTitleCompactComparisonValue(generatedTitle)
        let matches = {
            let canonicalMatch = {
                guard let canonicalTitle, let canonicalGeneratedTitle else { return false }
                return canonicalTitle == canonicalGeneratedTitle
                || canonicalGeneratedTitle.hasPrefix(canonicalTitle)
                || canonicalTitle.hasPrefix(canonicalGeneratedTitle)
            }()
            let compactMatch = {
                guard let compactTitle, let compactGeneratedTitle else { return false }
                return compactTitle == compactGeneratedTitle
                    || compactGeneratedTitle.hasPrefix(compactTitle)
                    || compactTitle.hasPrefix(compactGeneratedTitle)
            }()
            return canonicalMatch || compactMatch
        }()
        return matches
    }

    private static func resolvedSnippetTitleAfterHTMLUpdate(
        currentTitle: String,
        currentHTML: String?,
        updatedHTML: String,
        requestedTitle: String? = nil,
        currentIsTitlePrefixOfContent: Bool? = nil
    ) -> (title: String, isTitlePrefixOfContent: Bool) {
        let desiredTitle = requestedTitle ?? currentTitle
        let shouldAutoRetitle =
            desiredTitle == currentTitle &&
            (currentIsTitlePrefixOfContent
                ?? snippetTitleMatchesGeneratedPrefix(currentTitle, sourceHTML: currentHTML))
        let resolvedTitle: String
        if shouldAutoRetitle,
           let generatedTitle = generatedSnippetTitle(fromSourceHTML: updatedHTML) {
            resolvedTitle = generatedTitle
        } else {
            resolvedTitle = desiredTitle
        }
        return (
            resolvedTitle,
            snippetTitleMatchesGeneratedPrefix(resolvedTitle, sourceHTML: updatedHTML)
        )
    }

    @MainActor
    public static func snippetEditorHTML(
        for content: any ReaderContentProtocol,
        readerFileManager: ReaderFileManager = .shared
    ) async throws -> String {
        if let html = try await content.htmlToDisplay(readerFileManager: readerFileManager),
           !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return normalizeSnippetSourceHTML(html)
        }
        return normalizeSnippetSourceHTML("<html><body></body></html>")
    }

    public static func loadPasteboardSnippetHTML() -> String? {
#if os(macOS)
        let html = NSPasteboard.general.string(forType: .html)
        let text = NSPasteboard.general.string(forType: .string)
#else
        let pasteboard = UIPasteboard.general
        let htmlData = pasteboard.data(forPasteboardType: UTType.html.identifier)
        let htmlFromData = htmlData.flatMap {
            String(data: $0, encoding: .utf8)
                ?? String(data: $0, encoding: .unicode)
                ?? String(data: $0, encoding: .utf16LittleEndian)
                ?? String(data: $0, encoding: .utf16BigEndian)
        }
        let htmlFromValue = pasteboard.value(forPasteboardType: UTType.html.identifier) as? String
        let html = htmlFromData ?? htmlFromValue
        let text = pasteboard.string
#endif

        guard let payload = preferredPasteboardPayload(html: html, text: text) else {
            return nil
        }
        let normalized = normalizeIngestedText(payload.text, explicitHTML: payload.explicitHTML, source: .paste)
   return normalizeSnippetSourceHTML(normalized.html)
    }

#if DEBUG
    public static let debugSnippetFallbackRawText = """
# Updated via Snippet Helper

This snippet loads when the pasteboard is empty in a debug build.

- First line borrowed from snippet loader tests.
- Second line is plain Markdown for quick UI checks.
- Third line makes the preview a little less bare.
"""
#endif

    @MainActor
    public static func appendSnippetHTML(
        _ appendedHTML: String,
        to content: any ReaderContentProtocol
    ) async throws -> (any ReaderContentProtocol)? {
        try await appendSnippetHTML(appendedHTML, toContentURL: content.url)
    }

    /// A delayed import keeps its original destination across recognition and UI navigation.
    @MainActor
    public static func appendSnippetHTML(
        _ appendedHTML: String,
        toContentURL contentURL: URL
    ) async throws -> (any ReaderContentProtocol)? {
        guard contentURL.isSnippetURL else { return nil }
        let normalizedAppendedHTML = normalizeSnippetSourceHTML(appendedHTML)
    try await { @RealmBackgroundActor in
            try await updateContent(url: contentURL) { object in
                let currentHTML = object.html
                guard let mergedHTML = try? appendSnippetHTML(
                    normalizedAppendedHTML,
                    toExistingHTML: currentHTML
                ) else {
                    return false
                }

                let normalizedCurrentHTML = snippetHTML(fromHTML: currentHTML ?? "<html><body></body></html>")
                let normalizedMergedHTML = snippetHTML(fromHTML: mergedHTML)
                let resolvedTitleUpdate = resolvedSnippetTitleAfterHTMLUpdate(
                    currentTitle: object.title,
                    currentHTML: currentHTML,
                    updatedHTML: mergedHTML,
                    currentIsTitlePrefixOfContent: object.isTitlePrefixOfContent
                )
                var objectDidChange = false

                if normalizedCurrentHTML != normalizedMergedHTML {
                    object.html = mergedHTML
                    objectDidChange = true
                }
                if object.title != resolvedTitleUpdate.title {
                    object.title = resolvedTitleUpdate.title
                    objectDidChange = true
                }
                if object.isTitlePrefixOfContent != resolvedTitleUpdate.isTitlePrefixOfContent {
                    object.isTitlePrefixOfContent = resolvedTitleUpdate.isTitlePrefixOfContent
                    objectDidChange = true
                }
                if object.rssContainsFullContent == false {
                    object.rssContainsFullContent = true
                    objectDidChange = true
                }
                if object.isReaderModeByDefault == false {
                    object.isReaderModeByDefault = true
                    objectDidChange = true
                }

            return objectDidChange
            }
        }()

   return try await load(
            url: contentURL,
            persist: false,
            countsAsHistoryVisit: false,
            source: "ReaderContentLoader.appendSnippetHTML.reload"
        )
    }

    @MainActor
    public static func appendSnippetHTML(
        _ appendedHTML: String,
        toContentURL contentURL: URL,
        storage: SnippetStorage,
        permitsCommit: @escaping @Sendable () -> Bool
    ) async throws -> Bool {
        guard contentURL.isSnippetURL, permitsCommit() else { return false }
        let normalizedAppendedHTML = normalizeSnippetSourceHTML(appendedHTML)
        return try await { @RealmBackgroundActor in
            try await updateCapturedSnippetRecords(
                contentURL: contentURL, storage: storage, permitsCommit: permitsCommit
            ) { object in
                let currentHTML = object.html
                guard let mergedHTML = try? appendSnippetHTML(
                    normalizedAppendedHTML, toExistingHTML: currentHTML
                ) else { return false }
                let normalizedCurrentHTML = snippetHTML(
                    fromHTML: currentHTML ?? "<html><body></body></html>"
                )
                let normalizedMergedHTML = snippetHTML(fromHTML: mergedHTML)
                let resolvedTitleUpdate = resolvedSnippetTitleAfterHTMLUpdate(
                    currentTitle: object.title,
                    currentHTML: currentHTML,
                    updatedHTML: mergedHTML,
                    currentIsTitlePrefixOfContent: object.isTitlePrefixOfContent
                )
                let objectDidChange = normalizedCurrentHTML != normalizedMergedHTML
                    || object.title != resolvedTitleUpdate.title
                    || object.isTitlePrefixOfContent != resolvedTitleUpdate.isTitlePrefixOfContent
                    || !object.rssContainsFullContent
                    || !object.isReaderModeByDefault
                guard objectDidChange else { return false }
                if normalizedCurrentHTML != normalizedMergedHTML {
                    object.html = mergedHTML
                }
                object.title = resolvedTitleUpdate.title
                object.isTitlePrefixOfContent = resolvedTitleUpdate.isTitlePrefixOfContent
                object.rssContainsFullContent = true
                object.isReaderModeByDefault = true
                return true
            }
        }()
    }

    @MainActor
    public static func updateSnippetHTML(
        contentURL: URL,
        html: String
    ) async throws -> Bool {
        let normalizedHTML = snippetHTML(fromHTML: html)
        return try await { @RealmBackgroundActor in
            var didChange = false
            try await updateContent(url: contentURL) { object in
                let existingHTML = snippetHTML(fromHTML: object.html ?? "<html><body></body></html>")
                let resolvedTitleUpdate = resolvedSnippetTitleAfterHTMLUpdate(
                    currentTitle: object.title,
                    currentHTML: object.html,
                    updatedHTML: normalizedHTML,
                    currentIsTitlePrefixOfContent: object.isTitlePrefixOfContent
                )
                var objectDidChange = false

                if existingHTML != normalizedHTML {
                    object.html = normalizedHTML
                    objectDidChange = true
                }
                if object.title != resolvedTitleUpdate.title {
                    object.title = resolvedTitleUpdate.title
                    objectDidChange = true
                }
                if object.isTitlePrefixOfContent != resolvedTitleUpdate.isTitlePrefixOfContent {
                    object.isTitlePrefixOfContent = resolvedTitleUpdate.isTitlePrefixOfContent
                    objectDidChange = true
                }

                if objectDidChange {
                    didChange = true
                }
                return objectDidChange
            }
            return didChange
        }()
    }

    @MainActor
    public static func updateSnippetTitle(
        contentURL: URL,
        title: String
    ) async throws -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard contentURL.isSnippetURL, !trimmedTitle.isEmpty else { return false }
        return try await { @RealmBackgroundActor in
            var didChange = false
            try await updateContent(url: contentURL) { object in
                let isTitlePrefixOfContent = snippetTitleMatchesGeneratedPrefix(
                    trimmedTitle,
                    sourceHTML: object.html
                )
                guard object.title != trimmedTitle
                    || object.isTitlePrefixOfContent != isTitlePrefixOfContent else {
                    return false
                }
                object.title = trimmedTitle
                object.isTitlePrefixOfContent = isTitlePrefixOfContent
                didChange = true
                return true
            }
            return didChange
        }()
    }

    @MainActor
    public static func updateSnippetTitle(
        contentURL: URL,
        title: String,
        storage: SnippetStorage,
        permitsCommit: @escaping @Sendable () -> Bool
    ) async throws -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard contentURL.isSnippetURL, !trimmedTitle.isEmpty, permitsCommit() else { return false }
        return try await { @RealmBackgroundActor in
            try await updateCapturedSnippetRecords(
                contentURL: contentURL, storage: storage, permitsCommit: permitsCommit
            ) { object in
                let isTitlePrefixOfContent = snippetTitleMatchesGeneratedPrefix(
                    trimmedTitle, sourceHTML: object.html
                )
                guard object.title != trimmedTitle
                    || object.isTitlePrefixOfContent != isTitlePrefixOfContent else { return false }
                object.title = trimmedTitle
                object.isTitlePrefixOfContent = isTitlePrefixOfContent
                return true
            }
        }()
    }

    @MainActor
    public static func updateSnippetContent(
        contentURL: URL,
        title: String,
        html: String
    ) async throws -> Bool {
        try await updateSnippetContent(
            contentURL: contentURL,
            title: title,
            html: html,
            storage: .capture(),
            permitsCommit: { !Task.isCancelled }
        )
    }

    /// Update every live bookmark and history representation in the original
    /// storage. Check admission inside the transaction, after any Realm wait.
    @MainActor
    public static func updateSnippetContent(
        contentURL: URL,
        title: String,
        html: String,
        originalEditorHTML: String? = nil,
        storage: SnippetStorage,
        permitsCommit: @escaping @Sendable () -> Bool
    ) async throws -> Bool {
        guard contentURL.isSnippetURL, permitsCommit() else { return false }
        let normalizedHTML = snippetHTML(fromHTML: html)
        return try await { @RealmBackgroundActor in
            try await updateCapturedSnippetRecords(
                contentURL: contentURL, storage: storage, permitsCommit: permitsCommit
            ) { object in
                // The unchanged draft is the exact source supplied to the
                // editor. Do not reserialize its body, even if current storage
                // has since received a newer body from another writer.
                let bodyIsUnchanged = html == object.html
                    || originalEditorHTML.map { $0 == html } == true
                let currentHTML = snippetHTML(fromHTML: object.html ?? "<html><body></body></html>")
                let updatedHTML = bodyIsUnchanged ? currentHTML : normalizedHTML
                let resolvedTitleUpdate = resolvedSnippetTitleAfterHTMLUpdate(
                    currentTitle: object.title,
                    currentHTML: object.html,
                    updatedHTML: updatedHTML,
                    requestedTitle: title,
                    currentIsTitlePrefixOfContent: object.isTitlePrefixOfContent
                )
                let objectDidChange = object.title != resolvedTitleUpdate.title
                    || object.isTitlePrefixOfContent != resolvedTitleUpdate.isTitlePrefixOfContent
                    || (!bodyIsUnchanged && currentHTML != normalizedHTML)
                guard objectDidChange else { return false }
                object.title = resolvedTitleUpdate.title
                object.isTitlePrefixOfContent = resolvedTitleUpdate.isTitlePrefixOfContent
                if !bodyIsUnchanged && currentHTML != normalizedHTML {
                    object.html = normalizedHTML
                }
                return true
            }
        }()
    }

    @RealmBackgroundActor
    // Shared transaction boundary for append, rename and editor saves. Internal
    // visibility allows deterministic tests of real writer interleavings.
    // Separate-store compatibility remains atomic per Realm only: a thrown
    // error can follow a prior store's commit and must not imply total rollback.
    static func updateCapturedSnippetRecords(
        contentURL: URL,
        storage: SnippetStorage,
        permitsCommit: @escaping @Sendable () -> Bool,
        mutate: (any ReaderContentProtocol) -> Bool
    ) async throws -> Bool {
        let bookmarkRealm = try await RealmBackgroundActor.shared.cachedRealm(
            for: storage.bookmarkConfiguration
        )
        let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(
            for: storage.historyConfiguration
        )
        // App-owned snippets put both representations in the same Realm.
        // Group before writing so an account/cancellation change cannot commit
        // one representation and roll back the other in that same store.
        let groups: [(realm: Realm, bookmarks: Bool, histories: Bool)] = bookmarkRealm == historyRealm
            ? [(bookmarkRealm, true, true)]
            : [(bookmarkRealm, true, false), (historyRealm, false, true)]
        var didChange = false
        for group in groups {
            let groupDidChange = try await group.realm.asyncWritePreservingOwnership { () throws -> Bool in
                guard !Task.isCancelled, permitsCommit() else { throw CancellationError() }
                // Query live records only after acquiring the write. No
                // managed object selected before an await can be revived or
                // mutated after another writer deletes/replaces it.
                var objects = [any ReaderContentProtocol]()
                if group.bookmarks {
                    objects += group.realm.objects(Bookmark.self)
                        .filter(NSPredicate(format: "isDeleted == false AND url == %@", contentURL.absoluteString))
                        .map { $0 as any ReaderContentProtocol }
                }
                if group.histories {
                    objects += HistoryRecord.openedRecords(matching: contentURL, in: group.realm)
                        .map { $0 as any ReaderContentProtocol }
                }
                let timestamp = Date()
                var changed = false
                for object in objects {
                    if mutate(object) {
                        object.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                        changed = true
                    }
                }
                guard !Task.isCancelled, permitsCommit() else { throw CancellationError() }
                return changed
            }
            didChange = didChange || groupDidChange
        }
        return didChange
    }

    static func preferredPasteboardPayload(html: String?, text: String?) -> (text: String, explicitHTML: Bool)? {
        func normalizedClipboardText(_ raw: String?) -> String? {
            guard let raw else { return nil }
            let stripped = (raw.removingHTMLTags() ?? raw)
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stripped.isEmpty else { return nil }
            return stripped
        }

        let normalizedHTMLText = normalizedClipboardText(html)
        let normalizedPlainText = normalizedClipboardText(text)

        if let normalizedHTMLText, let normalizedPlainText, normalizedHTMLText == normalizedPlainText {
       return (normalizedPlainText, false)
        }

        if let html {
            if normalizeIngestedText(html, explicitHTML: false, source: .paste).format == .html {
           return (html, true)
            }
        }
        if let text {
       return (text, false)
        }
        if let html {
       return (html, false)
        }
        return nil
    }
    
    @RealmBackgroundActor
    public static func saveBookmark(text: String?, title: String?, url: URL, isFromClipboard: Bool, isReaderModeByDefault: Bool) async throws {
        if let text = text {
            try await _ = Bookmark.add(url: url, title: title ?? "", html: textToHTML(text), isFromClipboard: isFromClipboard, rssContainsFullContent: isFromClipboard, isReaderModeByDefault: isReaderModeByDefault, isReaderModeAvailable: false, isReaderModeOfferHidden: false, realmConfiguration: bookmarkRealmConfiguration)
        } else {
            try await _ = Bookmark.add(url: url, title: title ?? "", isFromClipboard: isFromClipboard, rssContainsFullContent: isFromClipboard, isReaderModeByDefault: isReaderModeByDefault, isReaderModeAvailable: false, isReaderModeOfferHidden: false, realmConfiguration: bookmarkRealmConfiguration)
        }
    }
    
    @RealmBackgroundActor
    public static func saveBookmark(text: String, title: String?, url: URL?, isFromClipboard: Bool, isReaderModeByDefault: Bool) async throws {
        let html = Self.textToHTML(text)
        try await _ = Bookmark.add(url: url, title: title ?? "", html: html, isFromClipboard: isFromClipboard, rssContainsFullContent: isFromClipboard, isReaderModeByDefault: isReaderModeByDefault, isReaderModeAvailable: false, isReaderModeOfferHidden: false, realmConfiguration: bookmarkRealmConfiguration)
    }

    private static let snippetWrapperClass = "mnb-snippet"

    static func normalizeSnippetSourceHTML(_ html: String) -> String {
        guard let doc = try? SwiftSoup.parse(html),
              let body = doc.body() else {
            return html
        }

        let bodyHTML = (try? body.html())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !bodyHTML.isEmpty else {
            return html
        }

        let bodyChildren = body.children()
        let isAlreadyWrapped = !bodyChildren.isEmpty && bodyChildren.allSatisfy {
            $0.hasClass(snippetWrapperClass)
        }

        guard !isAlreadyWrapped else {
            return (try? doc.outerHtml()) ?? html
        }

        try? body.html(#"<div class="\#(snippetWrapperClass)">\#(bodyHTML)</div>"#)
        return (try? doc.outerHtml()) ?? html
    }

    private static func appendSnippetHTML(_ appendedHTML: String, toExistingHTML existingHTML: String?) throws -> String {
        let baseHTML = normalizeSnippetSourceHTML(existingHTML ?? "<html><body></body></html>")
        let baseDoc = try SwiftSoup.parse(baseHTML)
        let appendedDoc = try SwiftSoup.parse(normalizeSnippetSourceHTML(appendedHTML))

        let existingBody = try baseDoc.body()
        let appendedBody = try appendedDoc.body()
        let appendedBodyHTML = try appendedBody?.html().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if appendedBodyHTML.isEmpty {
            return try baseDoc.outerHtml()
        }

        try existingBody?.append(appendedBodyHTML)
        return try baseDoc.outerHtml()
    }
}

/// Forked from: https://github.com/objecthub/swift-markdownkit/issues/6
open class PasteboardHTMLGenerator: HtmlGenerator {
    override open func generate(text: MarkdownKit.Text) -> String {
        var res = ""
        for (idx, fragment) in text.enumerated() {
            if (idx + 1) < text.count {
                let next = text[idx + 1]
                switch (fragment as TextFragment, next as TextFragment) {
                case (.softLineBreak, .text(let text)):
                    if text.hasPrefix("　") || text.hasPrefix("    ") {
                        res += "<br/><br/>" // TODO: Morph to paragraph
                        continue
                    }
                case (.softLineBreak, .softLineBreak):
                    res += "<br/><br/>" // TODO: Morph to paragraph
                    continue
                default:
                    break
                }
            }
            
            res += generate(textFragment: fragment)
        }
        return res
    }
    
//    override open func generate(textFragment fragment: TextFragment) -> String {
//        switch fragment {
//        case .softLineBreak:
//            return "<br/>"
//        default:
//            return super.generate(textFragment: fragment)
//        }
//    }
}

fileprivate extension URL {
    var contentType: UTType {
        return UTType(filenameExtension: self.pathExtension) ?? .data
    }
}

// MARK: - User-owned Home imports

public extension ReaderContentLoader {
    enum ImportPayload: Sendable {
        case url(URL, fromClipboard: Bool = false)
        case html(String, fromClipboard: Bool)
    }

    /// Capture alongside the logical account admission, before permissions,
    /// transferable loading, OCR, or an actor hop can suspend the user action.
    struct ImportStorage {
        let bookmarks: Realm.Configuration
        let history: Realm.Configuration
        let feeds: Realm.Configuration

        @MainActor
        public static func capture() -> Self {
            Self(bookmarks: bookmarkRealmConfiguration,
                 history: historyRealmConfiguration,
                 feeds: feedEntryRealmConfiguration)
        }
    }

    static func importPayload(fromText text: String) -> ImportPayload? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), ["http", "https"].contains(url.scheme ?? ""), url.host != nil {
            return .url(url)
        }
        return .html(snippetHTML(fromRawText: text), fromClipboard: false)
    }

    /// Snapshot the pasteboard at the user action, not in a later Task.
    @MainActor
    static func capturePasteboardImportPayload() -> ImportPayload? {
        let (html, text) = pasteboardImportStrings()
        if let text, let url = URL(string: text), url.absoluteString == text,
           url.scheme != nil, url.host != nil {
            return .url(url, fromClipboard: true)
        }
        guard let payload = preferredPasteboardPayload(html: html, text: text) else { return nil }
        let normalized = normalizeIngestedText(payload.text, explicitHTML: payload.explicitHTML, source: .paste)
        return .html(normalized.html, fromClipboard: true)
    }

    /// Creates a fresh snippet or records an explicit URL visit in one owned
    /// History transaction. Generic readers keep their existing load semantics.
    /// A returned reference is a durable result; resolving/displaying it is a
    /// separate operation and must never turn a later cancellation into rollback.
    @RealmBackgroundActor
    static func importContent(
        _ payload: ImportPayload,
        storage: ImportStorage,
        permitsCommit: @escaping @Sendable () -> Bool
    ) async throws -> ContentReference? {
        guard !Task.isCancelled, permitsCommit(), !Task.isCancelled else { throw CancellationError() }
        let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(for: storage.history)
        switch payload {
        case let .html(html, fromClipboard):
            let normalizedHTML = normalizeSnippetSourceHTML(html)
            let data = normalizedHTML.readerContentData
            let title = generatedSnippetTitle(fromSourceHTML: normalizedHTML) ?? ""
            return try await historyRealm.asyncWritePreservingOwnership { () throws -> ContentReference? in
                guard !Task.isCancelled, permitsCommit(), !Task.isCancelled else { throw CancellationError() }
                let timestamp = Date()
                let record = HistoryRecord()
                let key = UUID().uuidString.uppercased()
                record.compoundKey = key
                record.createdAt = timestamp
                record.lastVisitedAt = timestamp
                record.url = snippetURL(key: key) ?? record.url
                record.publicationDate = timestamp
                record.content = data
                record.title = title
                record.isTitlePrefixOfContent = !title.isEmpty
                record.isReaderModeByDefault = true
                record.isDemoted = false
                record.rssContainsFullContent = true
                record.isFromClipboard = fromClipboard
                historyRealm.add(record)
                record.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                guard !Task.isCancelled, permitsCommit(), !Task.isCancelled else { throw CancellationError() }
                return ContentReference(content: record)
            }

        case let .url(url, fromClipboard):
            guard url.absoluteString != "about:blank",
                  !(url.scheme == "internal" && url.absoluteString.hasPrefix("internal://local/load/")) else {
                return nil
            }
            let bookmarkRealm = try await RealmBackgroundActor.shared.cachedRealm(for: storage.bookmarks)
            let feedRealm = try await RealmBackgroundActor.shared.cachedRealm(for: storage.feeds)
            return try await historyRealm.asyncWritePreservingOwnership { () throws -> ContentReference? in
                guard !Task.isCancelled, permitsCommit(), !Task.isCancelled else { throw CancellationError() }
                // These are read-only source stores. All import writes, including
                // bookmark links and demotion metadata, stay in captured History.
                if bookmarkRealm != historyRealm { bookmarkRealm.refresh() }
                if feedRealm != historyRealm && feedRealm != bookmarkRealm { feedRealm.refresh() }
                let timestamp = Date()
                let source = importSource(for: url, bookmarks: bookmarkRealm,
                                          history: historyRealm, feeds: feedRealm)
                let record: HistoryRecord
                if let history = source as? HistoryRecord {
                    record = history
                } else if let source {
                    let historyURL = HistoryRecord.canonicalHistoryURL(for: url)
                    let records = HistoryRecord.records(matching: historyURL, in: historyRealm)
                    let canonical = HistoryRecord.makePrimaryKey(url: historyURL, html: source.html)
                        .flatMap { historyRealm.object(ofType: HistoryRecord.self, forPrimaryKey: $0) }
                    let sort = [SortDescriptor(keyPath: "lastVisitedAt", ascending: false),
                                SortDescriptor(keyPath: "compoundKey", ascending: true)]
                    if let existing = records.where({ !$0.isDeleted }).sorted(by: sort).first
                        ?? canonical ?? records.where({ $0.isDeleted }).sorted(by: sort).first {
                        record = existing
                    } else {
                        record = HistoryRecord()
                        record.url = historyURL
                    }
                    configureImportHistory(record, from: source)
                    record.isDeleted = false
                    if record.realm == nil {
                        record.createdAt = timestamp
                        record.updateCompoundKey()
                        historyRealm.add(record)
                    }
                    // Do not invoke configureBookmark: its legacy implementation
                    // schedules an unfenced Task after this transaction returns.
                    if source.objectSchema.objectClass == Bookmark.self {
                        let deletedIDs = Set(bookmarkRealm.objects(Bookmark.self)
                            .where { $0.isDeleted }.map(\.compoundKey))
                        for linked in HistoryRecord.openedRecords(matching: source.url, in: historyRealm)
                            .where({ $0.bookmarkID == nil || $0.bookmarkID.in(deletedIDs) }) {
                            linked.bookmarkID = source.compoundKey
                            if linked !== record {
                                linked.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                            }
                        }
                    }
                } else {
                    guard !url.isEBookURL else { return nil }
                    let candidate = HistoryRecord()
                    candidate.url = url
                    candidate.updateCompoundKey()
                    if let existing = historyRealm.object(ofType: HistoryRecord.self, forPrimaryKey: candidate.compoundKey) {
                        record = existing
                    } else {
                        record = candidate
                        record.createdAt = timestamp
                        historyRealm.add(record)
                    }
                }
                record.lastVisitedAt = timestamp
                record.isDeleted = false
                if fromClipboard && record.url.isSnippetURL {
                    record.isFromClipboard = true
                    record.rssContainsFullContent = true
                    record.isReaderModeByDefault = true
                    record.url = snippetURL(key: record.compoundKey) ?? record.url
                }
                if (url.isReaderFileURL && url.contains(.plainText)) || url.isEBookURL {
                    record.isReaderModeByDefault = true
                }
                if record.isDemoted != false {
                    let bookmarked = bookmarkRealm.objects(Bookmark.self)
                        .filter(NSPredicate(format: "isDeleted == false AND url == %@", record.url.absoluteString))
                        .first != nil
                    record.isDemoted = !(record.isReaderModeByDefault || record.isReaderModeAvailable
                        || record.rssContainsFullContent || record.isFromClipboard
                        || record.isPhysicalMedia || bookmarked)
                }
                record.refreshChangeMetadata(explicitlyModified: true, at: timestamp)
                guard !Task.isCancelled, permitsCommit(), !Task.isCancelled else { throw CancellationError() }
                return ContentReference(content: record)
            }
        }
    }
}

private extension ReaderContentLoader {
    @RealmBackgroundActor
    static func importSource(for url: URL, bookmarks: Realm, history: Realm, feeds: Realm) -> (any ReaderContentProtocol)? {
        let exactURL = NSPredicate(format: "isDeleted == false AND url == %@", url.absoluteString)
        let file = bookmarks.objects(ContentFile.self).filter(exactURL).sorted(byKeyPath: "createdAt", ascending: false).first
        let bookmark = bookmarks.objects(Bookmark.self).filter(exactURL).sorted(byKeyPath: "createdAt", ascending: false).first
        let opened = HistoryRecord.openedRecords(matching: url, in: history)
            .sorted(by: [SortDescriptor(keyPath: "lastVisitedAt", ascending: false),
                         SortDescriptor(keyPath: "compoundKey", ascending: true)]).first
        var feed: FeedEntry?
        if url.scheme == "https" {
            feed = feeds.objects(FeedEntry.self)
                .filter(NSPredicate(format: "isDeleted == false AND (url == %@ OR url == %@)",
                                    url.absoluteString, url.settingScheme("http").absoluteString))
                .sorted(byKeyPath: "createdAt", ascending: false).first
        } else if !url.isReaderFileURL {
            feed = feeds.objects(FeedEntry.self).filter(exactURL).sorted(byKeyPath: "createdAt", ascending: false).first
        }
        let candidates: [any ReaderContentProtocol] = [file, bookmark, opened, feed].compactMap { $0 }
        return candidates.max {
            (($0 as? HistoryRecord)?.lastVisitedAt ?? $0.createdAt)
                < (($1 as? HistoryRecord)?.lastVisitedAt ?? $1.createdAt)
        }
    }

    @RealmBackgroundActor
    static func configureImportHistory(_ record: HistoryRecord, from source: any ReaderContentProtocol) {
        record.title = source.title
        record.isTitlePrefixOfContent = source.isTitlePrefixOfContent
        record.imageUrl = source.imageUrl
        if record.imageUrl == nil, let feed = source as? FeedEntry {
            record.imageUrl = feed.importImageURLWithoutCaching()
        }
        record.sourceIconURL = source.sourceIconURL
        record.isFromClipboard = source.isFromClipboard
        record.rssContainsFullContent = source.rssContainsFullContent
        if source.rssContainsFullContent { record.content = source.content }
        record.voiceFrameUrl = source.voiceFrameUrl
        let audio = source.resolvedVoiceAudioURLs
        record.voiceAudioURL = audio.first
        record.voiceAudioURLs.removeAll()
        record.voiceAudioURLs.append(objectsIn: audio)
        record.audioSubtitlesURL = source.audioSubtitlesURL
        record.audioSubtitlesRoleRawValue = source.audioSubtitlesRoleRawValue
            ?? (source.audioSubtitlesURL != nil ? AudioSubtitlesRole.content.rawValue : nil)
        record.autoOpenMediaPlayer = source.autoOpenMediaPlayer
        record.injectEntryImageIntoHeader = source.injectEntryImageIntoHeader
        record.publicationDate = source.publicationDate
        record.readerContentKind = source.readerContentKind
        record.feedEntryCollectionKey = source.feedEntryCollectionKey
        record.feedEntryCollectionScheme = source.feedEntryCollectionScheme
        record.feedEntryCollectionTerm = source.feedEntryCollectionTerm
        record.feedEntryCollectionTitle = source.feedEntryCollectionTitle
        record.isReaderModeByDefault = source.isReaderModeByDefault
        record.isReaderModeAvailable = source.isReaderModeAvailable
        record.isReaderModeOfferHidden = source.isReaderModeOfferHidden
        record.displayPublicationDate = source.displayPublicationDate
    }
}

