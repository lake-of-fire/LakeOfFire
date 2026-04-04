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
import LakeOfFireCore
import LakeOfFireAdblock

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
    private static let diagnosticLocalFilePathQueryItemName = "diagnosticLocalFilePath"

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

    private static func diagnosticStartupEbookLocalPath(for url: URL) -> String? {
        guard url.isEBookURL,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        return components.queryItems?
            .first(where: { $0.name == diagnosticLocalFilePathQueryItemName })?
            .value
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

    // Shared content lookup used by ReaderContent and ReaderViewModel.
    @MainActor
    public static func getContent(forURL pageURL: URL, countsAsHistoryVisit: Bool = false) async throws -> (any ReaderContentProtocol)? {
        debugPrint("# FLASH ReaderContentLoader.getContent start", "page=\(flashURLDescription(pageURL))")
        if pageURL.isSnippetURL || pageURL.isReaderURLLoaderURL {
            debugPrint(
                "# SNIPPETLOAD getContent.start",
                "pageURL=\(pageURL.absoluteString)",
                "countsAsHistoryVisit=\(countsAsHistoryVisit)"
            )
        }
        if let contentURL = ReaderContentLoader.getContentURL(fromLoaderURL: pageURL) {
            debugPrint(
                "# FLASH ReaderContentLoader.getContent loaderRedirect",
                "page=\(flashURLDescription(pageURL))",
                "->",
                flashURLDescription(contentURL)
            )
            if contentURL.isSnippetURL {
                debugPrint(
                    "# SNIPPETLOAD getContent.loaderRedirect",
                    "pageURL=\(pageURL.absoluteString)",
                    "contentURL=\(contentURL.absoluteString)"
                )
            }
            if let content = try await ReaderContentLoader.load(url: contentURL, countsAsHistoryVisit: countsAsHistoryVisit) {
                try Task.checkCancellation()
                debugPrint("# FLASH ReaderContentLoader.getContent resolved via loader", "content=\(flashURLDescription(contentURL))")
                if content.url.isSnippetURL {
                    debugPrint(
                        "# SNIPPETLOAD getContent.resolved",
                        "pageURL=\(pageURL.absoluteString)",
                        "contentURL=\(content.url.absoluteString)",
                        "hasHTML=\(content.hasHTML)",
                        "rssFull=\(content.rssContainsFullContent)",
                        "clipboard=\(content.isFromClipboard)"
                    )
                }
                return content
            } else {
                debugPrint("# FLASH ReaderContentLoader.getContent loaderRedirectFailed", "content=\(flashURLDescription(contentURL))")
                debugPrint(
                    "# SNIPPETLOAD getContent.loaderRedirectFailed",
                    "pageURL=\(pageURL.absoluteString)",
                    "contentURL=\(contentURL.absoluteString)"
                )
            }
        }
        if pageURL.isSnippetURL {
            debugPrint("# FLASH ReaderContentLoader.getContent snippetNoLoader", "page=\(flashURLDescription(pageURL))")
        }
        if let content = try await ReaderContentLoader.load(url: pageURL, persist: !pageURL.isNativeReaderView, countsAsHistoryVisit: true) {
            try Task.checkCancellation()
            debugPrint("# FLASH ReaderContentLoader.getContent resolved direct", "page=\(flashURLDescription(pageURL))")
            if content.url.isSnippetURL {
                debugPrint(
                    "# SNIPPETLOAD getContent.resolvedDirect",
                    "pageURL=\(pageURL.absoluteString)",
                    "contentURL=\(content.url.absoluteString)",
                    "hasHTML=\(content.hasHTML)",
                    "rssFull=\(content.rssContainsFullContent)",
                    "clipboard=\(content.isFromClipboard)"
                )
            }
            return content
        } else if let content = try await ReaderContentLoader.load(url: pageURL, persist: !pageURL.isNativeReaderView, countsAsHistoryVisit: true) {
            try Task.checkCancellation()
            debugPrint("# FLASH ReaderContentLoader.getContent resolved direct", "page=\(flashURLDescription(pageURL))")
            if content.url.isSnippetURL {
                debugPrint(
                    "# SNIPPETLOAD getContent.resolvedDirect",
                    "pageURL=\(pageURL.absoluteString)",
                    "contentURL=\(content.url.absoluteString)",
                    "hasHTML=\(content.hasHTML)",
                    "rssFull=\(content.rssContainsFullContent)",
                    "clipboard=\(content.isFromClipboard)"
                )
            }
            return content
        }
        try Task.checkCancellation()
        debugPrint("# FLASH ReaderContentLoader.getContent no match", "page=\(flashURLDescription(pageURL))")
        debugPrint("# SNIPPETLOAD getContent.noMatch", "pageURL=\(pageURL.absoluteString)")
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
        
        return [contentFile, bookmark, history, feed].compactMap { $0 }
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

    @RealmBackgroundActor
    public static func softDeleteTranscriptsIfNoRemainingOwners(contentURL url: URL) async throws {
        try await softDeleteTranscriptsIfNoRemainingOwners(contentURLs: [url])
    }

    @RealmBackgroundActor
    public static func softDeleteTranscriptsIfNoRemainingOwners(contentURLs urls: [URL]) async throws {
        let canonicalURLs = Set(urls.map { MediaTranscript.canonicalContentURL(from: $0) })
        guard !canonicalURLs.isEmpty else { return }

        for canonicalURL in canonicalURLs {
            let remainingOwners = try await loadAll(url: canonicalURL)
            guard remainingOwners.isEmpty else { continue }

            let sharedRealm = try await RealmBackgroundActor.shared.cachedRealm(for: feedEntryRealmConfiguration)
            let transcripts = sharedRealm.objects(MediaTranscript.self)
                .where { !$0.isDeleted }
                .filter(NSPredicate(format: "contentURL == %@", canonicalURL.absoluteString))
            guard !transcripts.isEmpty else { continue }

            try await sharedRealm.asyncWrite {
                for transcript in transcripts {
                    transcript.isDeleted = true
                    transcript.refreshChangeMetadata(explicitlyModified: true)
                }
            }
        }
    }
    
    @MainActor
    public static func load(url: URL, persist: Bool = true, countsAsHistoryVisit: Bool = false) async throws -> (any ReaderContentProtocol)? {
        if let diagnosticLocalPath = diagnosticStartupEbookLocalPath(for: url) {
            let historyRecord = HistoryRecord()
            historyRecord.url = url
            historyRecord.title = URL(fileURLWithPath: diagnosticLocalPath)
                .deletingPathExtension()
                .lastPathComponent
            historyRecord.isReaderModeByDefault = true
            historyRecord.rssContainsFullContent = false
            historyRecord.isDemoted = false
            historyRecord.updateCompoundKey()
            debugPrint(
                "# READERLOAD contentLoader.diagnosticStartupEbook",
                "url=\(url.absoluteString)",
                "localPath=\(diagnosticLocalPath)"
            )
            return historyRecord
        }

        if url.isTranscriptURL {
            try Task.checkCancellation()
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
                let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(for: historyRealmConfiguration)
                try await historyRealm.asyncWrite {
                    historyRealm.add(historyRecord, update: .modified)
                }
                return ReaderContentLoader.ContentReference(content: historyRecord)
            }

            if url.isSnippetURL, let key = url.snippetKey {
                let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(for: historyRealmConfiguration)
                if let record = historyRealm.object(ofType: HistoryRecord.self, forPrimaryKey: key), !record.isDeleted {
                    let canonicalSnippetURL = snippetURL(key: record.compoundKey) ?? record.url
                    let shouldNormalize =
                        !record.url.matchesReaderURL(canonicalSnippetURL)
                        || !record.isReaderModeByDefault
                        || !record.rssContainsFullContent
                    if shouldNormalize {
                        try await historyRealm.asyncWrite {
                            record.url = canonicalSnippetURL
                            record.isReaderModeByDefault = true
                            record.rssContainsFullContent = true
                            record.refreshChangeMetadata(explicitlyModified: true)
                        }
                    }
                    debugPrint("# READER snippet.keyLookup", "key=\(key)", "hit=history")
                    debugPrint("# SNIPPETLOAD snippet.keyLookup", "key=\(key)", "hit=history")
                    return ReaderContentLoader.ContentReference(content: record)
                }
                let bookmarkRealm = try await RealmBackgroundActor.shared.cachedRealm(for: bookmarkRealmConfiguration)
                if let bookmark = bookmarkRealm.object(ofType: Bookmark.self, forPrimaryKey: key), !bookmark.isDeleted {
                    let canonicalSnippetURL = snippetURL(key: bookmark.compoundKey) ?? bookmark.url
                    let shouldNormalize =
                        !bookmark.url.matchesReaderURL(canonicalSnippetURL)
                        || !bookmark.isReaderModeByDefault
                        || !bookmark.rssContainsFullContent
                    if shouldNormalize {
                        try await bookmarkRealm.asyncWrite {
                            bookmark.url = canonicalSnippetURL
                            bookmark.isReaderModeByDefault = true
                            bookmark.rssContainsFullContent = true
                            bookmark.refreshChangeMetadata(explicitlyModified: true)
                        }
                    }
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
            }
            try Task.checkCancellation()
            if persist, let match = match, url.isReaderFileURL, url.contains(.plainText), let realm = match.realm {
//                await realm.asyncRefresh()
                try await realm.asyncWrite {
                    match.isReaderModeByDefault = true
                    match.refreshChangeMetadata(explicitlyModified: true)
                }
            } else if persist, let match = match, url.isEBookURL, !match.isReaderModeByDefault, let realm = match.realm {
//                await realm.asyncRefresh()
                try await realm.asyncWrite {
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
        if let resolved = try await contentRef?.resolveOnMainActor() {
            if resolved.url.isSnippetURL, let realm = resolved.realm {
                let canonicalSnippetURL = snippetURL(key: resolved.compoundKey) ?? resolved.url
                let shouldNormalize =
                    !resolved.url.matchesReaderURL(canonicalSnippetURL)
                    || !resolved.isReaderModeByDefault
                    || !resolved.rssContainsFullContent
                if shouldNormalize {
                    try await realm.asyncWrite {
                        resolved.url = canonicalSnippetURL
                        resolved.isReaderModeByDefault = true
                        resolved.rssContainsFullContent = true
                        resolved.refreshChangeMetadata(explicitlyModified: true)
                    }
                }
            }
            try await repairPersistedSnippetHTMLIfNeeded(content: resolved)
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
        let contentHasLocallyRetrievableHTML = try await hasLocallyRetrievableHTML(
            for: content,
            readerFileManager: readerFileManager
        )
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
            if contentHasLocallyRetrievableHTML, let loaderURL = readerLoaderURL(for: contentURL) {
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
                    "hasHTML=\(content.hasHTML)",
                    "hasLocallyRetrievableHTML=\(contentHasLocallyRetrievableHTML)"
                )
                return content.url
            }
        }

        if ["http", "https"].contains(contentURL.scheme?.lowercased()) {
            if content.isReaderModeByDefault,
               contentHasLocallyRetrievableHTML,
               let loaderURL = readerLoaderURL(for: contentURL) {
                return loaderURL
            }

            let matchingContentURL = try await Task { @RealmBackgroundActor () -> URL? in
                let allContents = try await loadAll(url: contentURL)
                return allContents.first(where: { $0.isReaderModeByDefault })?.url
            }.value
            if let matchingContentURL,
               let matchingContent = try await load(
                    url: matchingContentURL,
                    persist: false,
                    countsAsHistoryVisit: false
               ),
               (try? await hasLocallyRetrievableHTML(
                    for: matchingContent,
                    readerFileManager: readerFileManager
               )) == true,
               let matchingURL = readerLoaderURL(for: matchingContent.url) {
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
            if contentHasLocallyRetrievableHTML, let loaderURL = readerLoaderURL(for: contentURL) {
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
                    "contentURL=\(contentURL.absoluteString)",
                    "hasLocallyRetrievableHTML=\(contentHasLocallyRetrievableHTML)"
                )
            }
        }

        return content.url
    }

    static func docIsPlainText(doc: SwiftSoup.Document) -> Bool {
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
        let pasteboard = UIPasteboard.general
        let htmlData = pasteboard.data(forPasteboardType: UTType.html.identifier)
        let htmlFromData = htmlData.flatMap {
            String(data: $0, encoding: .utf8)
                ?? String(data: $0, encoding: .unicode)
                ?? String(data: $0, encoding: .utf16LittleEndian)
                ?? String(data: $0, encoding: .utf16BigEndian)
        }
        let htmlFromValue = pasteboard.value(forPasteboardType: UTType.html.identifier) as? String
        let html = htmlFromData ?? htmlFromValue ?? pasteboard.string
        let text = pasteboard.string
#endif
        
        if let text, let url = URL(string: text), url.absoluteString == text, url.scheme != nil, url.host != nil {
            match = try await load(url: url, countsAsHistoryVisit: true)
        } else if let text {
            let normalized = normalizeIngestedText(text, explicitHTML: html != nil, source: .paste)
            match = try await load(html: normalized.html)
        } else if let html {
            let normalized = normalizeIngestedText(html, explicitHTML: true, source: .paste)
            match = try await load(html: normalized.html)
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

@MainActor
private func repairPersistedSnippetHTMLIfNeeded(content: any ReaderContentProtocol) async throws {
    guard content.url.isSnippetURL else { return }
    guard let storedHTML = content.html, !storedHTML.isEmpty else { return }
    guard let repairedHTML = repairedSnippetSourceHTML(from: storedHTML) else { return }
    guard repairedHTML != storedHTML else { return }

    debugPrint(
        "# READER snippetRepair.persistedSource",
        "url=\(content.url.absoluteString)",
        "oldBytes=\(storedHTML.utf8.count)",
        "newBytes=\(repairedHTML.utf8.count)"
    )

    if content.realm != nil {
        try await content.asyncWrite { _, record in
            record.html = repairedHTML
            record.rssContainsFullContent = true
            record.isReaderModeByDefault = true
            record.refreshChangeMetadata(explicitlyModified: true)
        }
    } else {
        content.html = repairedHTML
    }
}

private func repairedSnippetSourceHTML(from html: String) -> String? {
    guard snippetStoredHTMLIsCanonicalReaderHTML(html) else {
        return nil
    }
    guard snippetReaderMarkupNeedsRepair(html) else {
        return nil
    }
    guard html.range(of: #"id=['"]reader-content['"]"#, options: .regularExpression) != nil else {
        return nil
    }
    guard let document = try? SwiftSoup.parse(html),
          let readerContentHTML = try? document.getElementById("reader-content")?.html()
    else {
        return nil
    }

    let trimmedReaderContentHTML = readerContentHTML.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedReaderContentHTML.isEmpty else { return nil }

    let unwrappedSegments = trimmedReaderContentHTML.replacingOccurrences(
        of: #"(?is)</?manabi-segment\b[^>]*>"#,
        with: "",
        options: .regularExpression
    )

    let repairedHTML = unwrappedSegments.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !repairedHTML.isEmpty else { return nil }
    return repairedHTML
}

private func snippetStoredHTMLIsCanonicalReaderHTML(_ html: String) -> Bool {
    let hasReaderContent = html.range(of: #"id=['"]reader-content['"]"#, options: .regularExpression) != nil
    let hasReadabilityBody = html.range(
        of: #"(?is)<body\b[^>]*class=['"][^'"]*\breadability-mode\b[^'"]*['"]"#,
        options: .regularExpression
    ) != nil
    return hasReaderContent && hasReadabilityBody
}

private func snippetReaderMarkupNeedsRepair(_ html: String) -> Bool {
    let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
    let readerContentRegex = try! NSRegularExpression(pattern: #"id=['"]reader-content['"]"#)
    let readerTitleRegex = try! NSRegularExpression(pattern: #"id=['"]reader-title['"]"#)
    let readerContentMatches = readerContentRegex.matches(in: html, options: [], range: nsRange)
    let readerTitleMatches = readerTitleRegex.matches(in: html, options: [], range: nsRange)
    return readerContentMatches.count > 1 || readerTitleMatches.count > 1
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
