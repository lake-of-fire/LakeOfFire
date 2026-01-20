import Foundation
import SwiftUI
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
        if pageURL.isSnippetURL {
            if let key = pageURL.snippetKey,
               let canonical = snippetURL(key: key) {
                return canonical
            }
            return pageURL
        }
        if pageURL.isReaderURLLoaderURL,
           let components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false),
           let readerURLItem = components.queryItems?.first(where: { $0.name == "reader-url" }),
           let readerURLValue = readerURLItem.value,
           let contentURL = URL(string: readerURLValue) {
            return contentURL
        }
        if pageURL.absoluteString.hasPrefix("internal://local/load/reader?reader-url="),
           let range = pageURL.absoluteString.range(of: "?reader-url=", options: []),
           let rawURL = String(pageURL.absoluteString[range.upperBound...]).removingPercentEncoding,
           let contentURL = URL(string: rawURL) {
            return contentURL
        }
        return nil
    }
    
    @RealmBackgroundActor
    public static func loadAll(url: URL, skipContentFiles: Bool = false, skipFeedEntries: Bool = false) async throws -> [(any ReaderContentProtocol)] {
        let bookmarkRealm = try await RealmBackgroundActor.shared.cachedRealm(for: bookmarkRealmConfiguration)
        let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(for: historyRealmConfiguration)
        try Task.checkCancellation()
        
        var contentFile: ContentFile?
        if !skipContentFiles {
            contentFile = ContentFile.get(forURL: url, realm: bookmarkRealm)
        }
        let history = HistoryRecord.get(forURL: url, realm: historyRealm)
        let bookmark = Bookmark.get(forURL: url, realm: bookmarkRealm)
        
        var feed: FeedEntry?
        if !skipFeedEntries {
            let feedRealm = try await RealmBackgroundActor.shared.cachedRealm(for: feedEntryRealmConfiguration)
            let feeds = feedRealm.objects(FeedEntry.self)
                .where { !$0.isDeleted }
                .sorted(by: \.createdAt, ascending: false)
            
            if url.scheme == "https" {
                feed = feeds.filter("url == %@ || url == %@", url.absoluteString, url.settingScheme("http").absoluteString).first
                feed = feeds.filter(NSPredicate(format: "url == %@ OR url == %@", url.absoluteString as CVarArg, url.settingScheme("http").absoluteString as CVarArg)).first
            } else if !url.isReaderFileURL {
                feed = feeds.filter(NSPredicate(format: "url == %@", url.absoluteString as CVarArg)).first
            }
        }
        
        let candidates: [any ReaderContentProtocol] = [contentFile, bookmark, history, feed].compactMap { $0 }
        return candidates
    }

    /// Update all reader-content objects that share the given URL. The updater returns true if it mutated the object.
    @RealmBackgroundActor
    public static func updateContent(
        url: URL,
        skipContentFiles: Bool = false,
        skipFeedEntries: Bool = false,
        mutate: (Object & ReaderContentProtocol) -> Bool
    ) async throws {
        let objects = try await loadAll(url: url, skipContentFiles: skipContentFiles, skipFeedEntries: skipFeedEntries)
        for case let object as (Object & ReaderContentProtocol) in objects {
            guard let realm = object.realm else { continue }
            try await realm.asyncWrite {
                if mutate(object) {
                    object.refreshChangeMetadata(explicitlyModified: true)
                }
            }
        }
    }
    
    @MainActor
    public static func load(url: URL, persist: Bool = true, countsAsHistoryVisit: Bool = false) async throws -> (any ReaderContentProtocol)? {
        debugPrint(
            "# NOREADERMODE contentLoader.load.start",
            "url=\(url.absoluteString)",
            "persist=\(persist)",
            "countsAsHistoryVisit=\(countsAsHistoryVisit)"
        )
        let contentRef = try await { @RealmBackgroundActor () -> ReaderContentLoader.ContentReference? in
            try Task.checkCancellation()

            if url.scheme == "internal" && url.absoluteString.hasPrefix("internal://local/load/") {
                // Don't persist about:load
                // TODO: Perhaps return an empty history record to avoid catching the wrong content in this interim, though.
                debugPrint(
                    "# NOREADERMODE contentLoader.load.skipInternal",
                    "url=\(url.absoluteString)"
                )
                return nil
            } else if url.absoluteString == "about:blank" { //}&& !persist {
                let historyRecord = HistoryRecord()
                historyRecord.url = url
                historyRecord.isDemoted = true
                historyRecord.updateCompoundKey()
                let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(for: historyRealmConfiguration)
                try await historyRealm.asyncWrite {
                    historyRealm.add(historyRecord, update: .modified)
                }
                debugPrint(
                    "# NOREADERMODE contentLoader.load.aboutBlank",
                    "url=\(url.absoluteString)"
                )
                return ReaderContentLoader.ContentReference(content: historyRecord)
            }

            if url.isSnippetURL, let key = url.snippetKey {
                let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(for: historyRealmConfiguration)
                if let record = historyRealm.object(ofType: HistoryRecord.self, forPrimaryKey: key), !record.isDeleted {
                    debugPrint("# READER snippet.keyLookup", "key=\(key)", "hit=history")
                    debugPrint("# SNIPPETLOAD snippet.keyLookup", "key=\(key)", "hit=history")
                    return ReaderContentLoader.ContentReference(content: record)
                }
                let bookmarkRealm = try await RealmBackgroundActor.shared.cachedRealm(for: bookmarkRealmConfiguration)
                if let bookmark = bookmarkRealm.object(ofType: Bookmark.self, forPrimaryKey: key), !bookmark.isDeleted {
                    debugPrint("# READER snippet.keyLookup", "key=\(key)", "hit=bookmark")
                    debugPrint("# SNIPPETLOAD snippet.keyLookup", "key=\(key)", "hit=bookmark")
                    return ReaderContentLoader.ContentReference(content: bookmark)
                }
                debugPrint("# SNIPPETLOAD snippet.keyLookup", "key=\(key)", "hit=miss")
            }
            
            var match: (any ReaderContentProtocol)?
            let candidates = try await loadAll(url: url)
            match = candidates.max(by: {
                ($0 as? HistoryRecord)?.lastVisitedAt ?? $0.createdAt < ($1 as? HistoryRecord)?.lastVisitedAt ?? $1.createdAt
            })
            debugPrint(
                "# NOREADERMODE contentLoader.load.candidates",
                "url=\(url.absoluteString)",
                "count=\(candidates.count)",
                "matched=\(match?.url.absoluteString ?? "nil")"
            )
            if let match {
                debugPrint(
                    "# NOREADERMODE contentLoader.load.matchDetails",
                    "url=\(url.absoluteString)",
                    "type=\(String(describing: type(of: match)))",
                    "compoundKey=\(match.compoundKey)",
                    "readerDefault=\(match.isReaderModeByDefault)",
                    "readerAvailable=\(match.isReaderModeAvailable)",
                    "hasHTML=\(match.hasHTML)",
                    "rssFull=\(match.rssContainsFullContent)"
                )
            }
            
            if let nonHistoryMatch = match, countsAsHistoryVisit && persist, nonHistoryMatch.objectSchema.objectClass != HistoryRecord.self {
                match = try await nonHistoryMatch.addHistoryRecord(realmConfiguration: historyRealmConfiguration, pageURL: url)
            } else if match == nil, !url.isEBookURL {
                let historyRecord = HistoryRecord()
                historyRecord.url = url
                //        historyRecord.isReaderModeByDefault
                historyRecord.updateCompoundKey()
                if persist {
                    let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(for: historyRealmConfiguration)
//                    await historyRealm.asyncRefresh()
                    try await historyRealm.asyncWrite {
                        historyRealm.add(historyRecord, update: .modified)
                    }
                }
                match = historyRecord
                debugPrint(
                    "# NOREADERMODE contentLoader.load.historyCreated",
                    "url=\(url.absoluteString)",
                    "compoundKey=\(historyRecord.compoundKey)",
                    "readerDefault=\(historyRecord.isReaderModeByDefault)",
                    "readerAvailable=\(historyRecord.isReaderModeAvailable)"
                )
            }
            if match == nil {
                debugPrint(
                    "# NOREADERMODE contentLoader.load.noMatch",
                    "url=\(url.absoluteString)",
                    "isEBook=\(url.isEBookURL)"
                )
            }
            
            try Task.checkCancellation()
            if persist, let match = match, url.isReaderFileURL, url.contains(.plainText), let realm = match.realm {
//                await realm.asyncRefresh()
                try await realm.asyncWrite {
                    match.isReaderModeByDefault = true
                    match.refreshChangeMetadata(explicitlyModified: true)
                }
                debugPrint(
                    "# NOREADERMODE defaultEnabled",
                    "reason=readerFileURL",
                    "url=\(url.absoluteString)",
                    "recordURL=\(match.url.absoluteString)",
                    "type=\(String(describing: type(of: match)))",
                    "compoundKey=\(match.compoundKey)"
                )
            } else if persist, let match = match, url.isEBookURL, !match.isReaderModeByDefault, let realm = match.realm {
//                await realm.asyncRefresh()
                try await realm.asyncWrite {
                    match.isReaderModeByDefault = true
                    match.refreshChangeMetadata(explicitlyModified: true)
                }
                debugPrint(
                    "# NOREADERMODE defaultEnabled",
                    "reason=ebookURL",
                    "url=\(url.absoluteString)",
                    "recordURL=\(match.url.absoluteString)",
                    "type=\(String(describing: type(of: match)))",
                    "compoundKey=\(match.compoundKey)"
                )
            }
            guard let match else { return nil }
            
            if let historyRecord = match as? HistoryRecord {
                try await historyRecord.refreshDemotedStatus()
            }
            if match.isReaderModeByDefault {
                debugPrint(
                    "# NOREADERMODE defaultState",
                    "reason=matchedRecord",
                    "url=\(url.absoluteString)",
                    "recordURL=\(match.url.absoluteString)",
                    "type=\(String(describing: type(of: match)))",
                    "compoundKey=\(match.compoundKey)",
                    "hasHTML=\(match.hasHTML)",
                    "rssFull=\(match.rssContainsFullContent)"
                )
            }

            return ReaderContentLoader.ContentReference(content: match)
        }()
        try Task.checkCancellation()
        if let resolved = try await contentRef?.resolveOnMainActor() {
            debugPrint(
                "# NOREADERMODE contentLoader.load.resolved",
                "url=\(url.absoluteString)",
                "resolved=\(resolved.url.absoluteString)"
            )
            debugPrint(
                "# FLASH ReaderContentLoader.load directResult",
                resolved.url.absoluteString,
                "isSnippet=", resolved.url.isSnippetURL,
                "hasHTML=", resolved.hasHTML,
                "rssContainsFullContent=", resolved.rssContainsFullContent,
                "isReaderModeByDefault=", resolved.isReaderModeByDefault,
                "isFromClipboard=", resolved.isFromClipboard
            )
            return resolved
        }
        debugPrint(
            "# NOREADERMODE contentLoader.load.resolveNil",
            "url=\(url.absoluteString)"
        )
        return nil
    }
    
    @MainActor
    public static func load(urlString: String, countsAsHistoryVisit: Bool = false) async throws -> (any ReaderContentProtocol)? {
        guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme ?? ""), url.host != nil else { return nil }
        return try await load(url: url, countsAsHistoryVisit: countsAsHistoryVisit)
    }
    
    @MainActor
    public static func load(html: String) async throws -> (any ReaderContentProtocol)? {
        let contentRef = try await { @RealmBackgroundActor () -> ReaderContentLoader.ContentReference? in
            let bookmarkRealm = try await RealmBackgroundActor.shared.cachedRealm(for: bookmarkRealmConfiguration)
            let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(for: historyRealmConfiguration)
            let feedRealm = try await RealmBackgroundActor.shared.cachedRealm(for: feedEntryRealmConfiguration)
            
            let htmlPreview = snippetDebugPreview(html)
            debugPrint(
                "# READER snippetCreate.html",
                "length=\(html.utf8.count)",
                "preview=\(htmlPreview)"
            )

            let data = html.readerContentData
            let htmlBytes = html.utf8.count
            let compressedBytes = data?.count ?? 0
            debugPrint(
                "# READER snippetCreate.compress",
                "htmlBytes=\(htmlBytes)",
                "compressedBytes=\(compressedBytes)"
            )
            
            let bookmark = bookmarkRealm.objects(Bookmark.self)
                .sorted(by: \.createdAt, ascending: false)
                .where { $0.content == data }
                .first
            //            .first(where: { $0.content == data })
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
                debugPrint(
                    "# READER snippetCreate.reuse",
                    "url=\(match.url.absoluteString)",
                    "htmlBytes=\(htmlBytes)",
                    "compressedBytes=\(compressedBytes)",
                    "preview=\(htmlPreview)"
                )
                return ReaderContentLoader.ContentReference(content: match)
            }
            
            let historyRecord = HistoryRecord()
            historyRecord.publicationDate = Date()
            historyRecord.content = data
            // isReaderModeByDefault used to be commented out... why?
            historyRecord.isReaderModeByDefault = true
            historyRecord.isDemoted = false
            historyRecord.updateCompoundKey()
            historyRecord.rssContainsFullContent = true
            historyRecord.url = snippetURL(key: historyRecord.compoundKey) ?? historyRecord.url
//            await historyRealm.asyncRefresh()
            try await historyRealm.asyncWrite {
                historyRealm.add(historyRecord, update: .modified)
            }
            debugPrint(
                "# READER snippetCreate.persisted",
                "key=\(historyRecord.compoundKey)",
                "url=\(historyRecord.url.absoluteString)",
                "htmlBytes=\(htmlBytes)",
                "compressedBytes=\(compressedBytes)",
                "preview=\(htmlPreview)"
            )
            debugPrint(
                "# NOREADERMODE defaultEnabled",
                "reason=snippetCreate",
                "url=\(historyRecord.url.absoluteString)",
                "compoundKey=\(historyRecord.compoundKey)"
            )
            
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
        debugPrint(
            "# FLASH ReaderContentLoader.load invoked",
            contentURL.absoluteString,
            "isSnippet=", contentURL.isSnippetURL,
            "hasHTML=", content.hasHTML,
            "isReaderModeByDefault=", content.isReaderModeByDefault
        )
        if contentURL.isSnippetURL {
            debugPrint(
                "# READER snippet.loaderRequest",
                "contentURL=\(contentURL.absoluteString)",
                "hasHTML=\(content.hasHTML)",
                "pendingPageURL=\(content.url.absoluteString)"
            )
            debugPrint(
                "# SNIPPETLOAD snippet.loaderRequest",
                "contentURL=\(contentURL.absoluteString)",
                "hasHTML=\(content.hasHTML)",
                "rssFull=\(content.rssContainsFullContent)",
                "clipboard=\(content.isFromClipboard)",
                "readerDefault=\(content.isReaderModeByDefault)"
            )
            if let loaderURL = readerLoaderURL(for: contentURL) {
                debugPrint(
                    "# READER snippetLoader.redirect",
                    "snippetURL=\(contentURL.absoluteString)",
                    "loaderURL=\(loaderURL.absoluteString)",
                    "hasHTML=\(content.hasHTML)"
                )
                return loaderURL
            } else {
                debugPrint(
                    "# READER snippetLoader.fallback",
                    "snippetURL=\(contentURL.absoluteString)",
                    "hasHTML=\(content.hasHTML)"
                )
                return content.url
            }
        }

        if ["http", "https"].contains(contentURL.scheme?.lowercased()) {
            let matchingURL = try await Task { @RealmBackgroundActor () -> URL? in
                let allContents = try await loadAll(url: contentURL)
                for candidateContent in allContents {
                    guard candidateContent.isReaderModeByDefault else {
                        continue
                    }
                    if !candidateContent.url.isReaderFileURL, candidateContent.hasHTML {
                        guard let historyURL = readerLoaderURL(for: candidateContent.url) else {
                            return nil
                        }
                        //                                debugPrint("!! load(content isREaderModebydefault", historyURL)
                        return historyURL
                    }
                }
                return nil
            }.value

            if let matchingURL {
                return matchingURL
            }
            if content.isReaderModeByDefault {
                debugPrint(
                    "# READER readerLoader.matchingURL.missing",
                    "contentURL=\(contentURL.absoluteString)",
                    "hasHTML=\(content.hasHTML)",
                    "rssFull=\(content.rssContainsFullContent)",
                    "compressedBytes=\(content.content?.count ?? 0)"
                )
            }
            return content.url
        }

        if contentURL.isReaderFileURL {
            if let loaderURL = readerLoaderURL(for: contentURL) {
                debugPrint(
                    "# READER readerLoader.redirect",
                    "contentURL=\(contentURL.absoluteString)",
                    "loaderURL=\(loaderURL.absoluteString)",
                    "hasHTML=\(content.hasHTML)",
                    "rssFull=\(content.rssContainsFullContent)"
                )
                return loaderURL
            } else {
                debugPrint(
                    "# READER readerLoader.redirect.missing",
                    "contentURL=\(contentURL.absoluteString)"
                )
            }
        }

        return content.url
    }

    private static func docIsPlainText(doc: SwiftSoup.Document) -> Bool {
        PlainTextHTMLConverter.isPlainText(document: doc)
    }
    
    public static func textToHTMLDoc(_ text: String) throws -> SwiftSoup.Document {
        let html = textToHTML(text)
        return try SwiftSoup.parse(html)
    }
    
    public static func textToHTML(_ text: String, forceRaw: Bool = false) -> String {
        PlainTextHTMLConverter.convert(text, forceRaw: forceRaw) { $0.escapeHtml() }
    }
    
    public static func snippetURL(key: String) -> URL? {
        return URL(string: "internal://local/snippet?key=\(key)")
    }

    public static func extractHTML(from content: any ReaderContentProtocol) -> String? {
        guard let data = content.content else { return nil }
        let nsData = data as NSData
        guard let decompressed = try? nsData.decompressed(using: .lzfse) as Data else { return nil }
        return String(decoding: decompressed, as: UTF8.self)
    }

    public static func readerLoaderURL(for contentURL: URL) -> URL? {
        guard let encodedURL = contentURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            return nil
        }
        return URL(string: "internal://local/load/reader?reader-url=\(encodedURL)")
    }
    
    @MainActor
    public static func load(text: String) async throws -> (any ReaderContentProtocol)? {
        let html = textToHTML(text, forceRaw: true)
        return try await load(html: html)
    }
    
    @MainActor
    public static func loadPasteboard(bookmarkRealmConfiguration: Realm.Configuration = .defaultConfiguration, historyRealmConfiguration: Realm.Configuration = .defaultConfiguration, feedEntryRealmConfiguration: Realm.Configuration = .defaultConfiguration) async throws -> (any ReaderContentProtocol)? {
        var match: (any ReaderContentProtocol)?
        
#if os(macOS)
        let html = NSPasteboard.general.string(forType: .html)
        let text = NSPasteboard.general.string(forType: .string)
#else
        let html = UIPasteboard.general.string
        let text: String? = html
#endif
        
        if let text, let url = URL(string: text), url.absoluteString == text, url.scheme != nil, url.host != nil {
            match = try await load(url: url, countsAsHistoryVisit: true)
        } else if let html {
            if let doc = try? SwiftSoup.parse(html) {
                if docIsPlainText(doc: doc), let text = text {
                    match = try await load(html: PlainTextHTMLConverter.makeHTMLBody(fromPlainText: text))
                } else {
                    match = try await load(html: html)
                }
                //                match = load(html: html)
            } else {
                match = try await load(html: textToHTML(html))
            }
        } else if let text {
            match = try await load(html: textToHTML(text))
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
                        try await realm.asyncWrite {
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
    
    @RealmBackgroundActor
    public static func saveBookmark(text: String?, title: String?, url: URL, isFromClipboard: Bool, isReaderModeByDefault: Bool) async throws {
        if let text = text {
            try await _ = Bookmark.add(url: url, title: title ?? "", html: textToHTML(text), isFromClipboard: isFromClipboard, rssContainsFullContent: isFromClipboard, isReaderModeByDefault: isReaderModeByDefault, isReaderModeAvailable: false, realmConfiguration: bookmarkRealmConfiguration)
        } else {
            try await _ = Bookmark.add(url: url, title: title ?? "", isFromClipboard: isFromClipboard, rssContainsFullContent: isFromClipboard, isReaderModeByDefault: isReaderModeByDefault, isReaderModeAvailable: false, realmConfiguration: bookmarkRealmConfiguration)
        }
    }
    
    @RealmBackgroundActor
    public static func saveBookmark(text: String, title: String?, url: URL?, isFromClipboard: Bool, isReaderModeByDefault: Bool) async throws {
        let html = Self.textToHTML(text)
        var resolvedURL = url
        if resolvedURL == nil {
            let realm = try await RealmBackgroundActor.shared.cachedRealm(for: bookmarkRealmConfiguration)
            if let data = html.readerContentData,
               let existingSnippet = realm.objects(Bookmark.self)
                   .sorted(by: \.createdAt, ascending: false)
                   .where({ $0.content == data })
                   .first(where: { !$0.isDeleted && $0.url.isSnippetURL }) {
                resolvedURL = existingSnippet.url
            } else {
                let key = UUID().uuidString
                resolvedURL = ReaderContentLoader.snippetURL(key: key) ?? URL(string: "internal://local/snippet?key=\(key)")
            }
        }

        try await _ = Bookmark.add(url: resolvedURL, title: title ?? "", html: html, isFromClipboard: isFromClipboard, rssContainsFullContent: isFromClipboard, isReaderModeByDefault: isReaderModeByDefault, isReaderModeAvailable: false, realmConfiguration: bookmarkRealmConfiguration)
    }
}

@inline(__always)
private func snippetDebugPreview(_ html: String, maxLength: Int = 360) -> String {
    if html.count <= maxLength {
        return html
    }
    let idx = html.index(html.startIndex, offsetBy: maxLength)
    return String(html[..<idx]) + "…"
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
