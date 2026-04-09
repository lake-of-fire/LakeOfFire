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

private func logReaderLoad(_ message: String) {
    debugPrint("# READERLOAD \(message)")
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
        if pageURL.isReaderURLLoaderURL,
           let components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false),
           let readerURLItem = components.queryItems?.first(where: { $0.name == "reader-url" }),
           let readerURLValue = readerURLItem.value,
           let contentURL = URL(string: readerURLValue) {
            logReaderLoad(
                "stage=loaderURL.resolve source=components pageURL=\(pageURL.absoluteString) contentURL=\(contentURL.absoluteString)"
            )
            return contentURL
        }
        if pageURL.absoluteString.hasPrefix("internal://local/load/reader?reader-url="), let range = pageURL.absoluteString.range(of: "?reader-url=", options: []), let rawURL = String(pageURL.absoluteString[range.upperBound...]).removingPercentEncoding, let contentURL = URL(string: rawURL) {
            logReaderLoad(
                "stage=loaderURL.resolve source=stringPrefix pageURL=\(pageURL.absoluteString) contentURL=\(contentURL.absoluteString)"
            )
            return contentURL
        }
        return nil
    }
    
    @RealmBackgroundActor
    public static func loadAll(url: URL, skipContentFiles: Bool = false, skipFeedEntries: Bool = false) async throws -> [(any ReaderContentProtocol)] {
        logReaderLoad(
            "stage=contentLoader.loadAll.begin url=\(url.absoluteString) skipContentFiles=\(skipContentFiles) skipFeedEntries=\(skipFeedEntries)"
        )
        let bookmarkRealm = try await RealmBackgroundActor.shared.cachedRealm(for: bookmarkRealmConfiguration)
        let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(for: historyRealmConfiguration)
        try Task.checkCancellation()
 
        var contentFile: ContentFile?
        if !skipContentFiles {
            contentFile = try await ContentFile.get(forURL: url)
        }
        let history = try await HistoryRecord.get(forURL: url)
        let bookmark = try await Bookmark.get(forURL: url)
        
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
        logReaderLoad(
            "stage=contentLoader.loadAll.finish url=\(url.absoluteString) candidates=\(candidates.map { String(describing: type(of: $0)) }.joined(separator: ",")) count=\(candidates.count)"
        )
        return candidates
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
    public static func getContent(forURL pageURL: URL, countsAsHistoryVisit: Bool = false) async throws -> (any ReaderContentProtocol)? {
        let resolvedURL = ReaderContentLoader.getContentURL(fromLoaderURL: pageURL) ?? pageURL
        let taskKey = "\(resolvedURL.absoluteString)|history:\(countsAsHistoryVisit)"
        if let existingTask = inFlightGetContentTasks[taskKey] {
            logReaderLoad(
                "stage=contentLoader.getContent.coalesced pageURL=\(pageURL.absoluteString) countsAsHistoryVisit=\(countsAsHistoryVisit)"
            )
            return try await existingTask.value
        }
        if countsAsHistoryVisit {
            let nonHistoryTaskKey = "\(resolvedURL.absoluteString)|history:false"
            if let existingTask = inFlightGetContentTasks[nonHistoryTaskKey] {
                logReaderLoad(
                    "stage=contentLoader.getContent.reuseNonHistoryTask pageURL=\(pageURL.absoluteString) countsAsHistoryVisit=\(countsAsHistoryVisit)"
                )
                let existingContent = try await existingTask.value
                if existingContent == nil || existingContent is HistoryRecord {
                    return existingContent
                }
            }
        } else {
            let historyTaskKey = "\(resolvedURL.absoluteString)|history:true"
            if let existingTask = inFlightGetContentTasks[historyTaskKey] {
                logReaderLoad(
                    "stage=contentLoader.getContent.reuseHistoryTask pageURL=\(pageURL.absoluteString)"
                )
                return try await existingTask.value
            }
        }

        let task = Task<(any ReaderContentProtocol)?, Error> { @MainActor in
            logReaderLoad(
                "stage=contentLoader.getContent.begin pageURL=\(pageURL.absoluteString) countsAsHistoryVisit=\(countsAsHistoryVisit)"
            )
            if let contentURL = ReaderContentLoader.getContentURL(fromLoaderURL: pageURL),
               let content = try await ReaderContentLoader.load(url: contentURL, countsAsHistoryVisit: countsAsHistoryVisit) {
                try Task.checkCancellation()
                logReaderLoad(
                    "stage=contentLoader.getContent.loaderResolved pageURL=\(pageURL.absoluteString) contentURL=\(content.url.absoluteString) contentType=\(String(describing: type(of: content)))"
                )
                return content
            } else if let content = try await ReaderContentLoader.load(url: pageURL, persist: !pageURL.isNativeReaderView, countsAsHistoryVisit: true) {
                try Task.checkCancellation()
                logReaderLoad(
                    "stage=contentLoader.getContent.directResolved pageURL=\(pageURL.absoluteString) contentURL=\(content.url.absoluteString) contentType=\(String(describing: type(of: content)))"
                )
                return content
            }
            try Task.checkCancellation()
            logReaderLoad(
                "stage=contentLoader.getContent.missing pageURL=\(pageURL.absoluteString)"
            )
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
        logReaderLoad(
            "stage=contentLoader.load.begin url=\(url.absoluteString) persist=\(persist) countsAsHistoryVisit=\(countsAsHistoryVisit)"
        )
        let contentRef = try await { @RealmBackgroundActor () -> ReaderContentLoader.ContentReference? in
            try Task.checkCancellation()
            
            if url.scheme == "internal" && url.absoluteString.hasPrefix("internal://local/load/") {
                // Don't persist about:load
                // TODO: Perhaps return an empty history record to avoid catching the wrong content in this interim, though.
                logReaderLoad("stage=contentLoader.load.skip reason=internalLoader url=\(url.absoluteString)")
                return nil
            } else if url.absoluteString == "about:blank" { //}&& !persist {
                let historyRecord = HistoryRecord()
                historyRecord.url = url
                historyRecord.isDemoted = true
                historyRecord.updateCompoundKey()
                logReaderLoad("stage=contentLoader.load.aboutBlank url=\(url.absoluteString)")
                return ReaderContentLoader.ContentReference(content: historyRecord)
            }
            
            var match: (any ReaderContentProtocol)?
            let candidates = try await loadAll(url: url)
            match = candidates.max(by: {
                ($0 as? HistoryRecord)?.lastVisitedAt ?? $0.createdAt < ($1 as? HistoryRecord)?.lastVisitedAt ?? $1.createdAt
            })
            
            if let nonHistoryMatch = match, countsAsHistoryVisit && persist, nonHistoryMatch.objectSchema.objectClass != HistoryRecord.self {
                logReaderLoad(
                    "stage=contentLoader.load.addHistoryVisit url=\(url.absoluteString) contentType=\(String(describing: type(of: nonHistoryMatch))) key=\(nonHistoryMatch.compoundKey)"
                )
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
                logReaderLoad(
                    "stage=contentLoader.load.createdHistory url=\(url.absoluteString) persist=\(persist)"
                )
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
        let content = try await contentRef?.resolveOnMainActor()
        if let content {
            logReaderLoad(
                "stage=contentLoader.load.finish url=\(url.absoluteString) contentURL=\(content.url.absoluteString) contentType=\(String(describing: type(of: content))) key=\(content.compoundKey) readerDefault=\(content.isReaderModeByDefault) hasHTML=\(content.hasHTML)"
            )
        } else {
            logReaderLoad("stage=contentLoader.load.finish url=\(url.absoluteString) content=nil")
        }
        return content
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
            
            let normalizedHTML = normalizeSnippetSourceHTML(html)
            let data = normalizedHTML.readerContentData
            
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
        logReaderLoad(
            "stage=contentLoader.loadContent.begin contentURL=\(contentURL.absoluteString) contentType=\(String(describing: type(of: content))) readerDefault=\(content.isReaderModeByDefault) readerAvailable=\(content.isReaderModeAvailable) hasHTML=\(content.hasHTML)"
        )
        let contentHasLocallyRetrievableHTML = try await hasLocallyRetrievableHTML(
            for: content,
            readerFileManager: readerFileManager
        )

        if contentURL.isSnippetURL {
            if contentHasLocallyRetrievableHTML, let loaderURL = readerLoaderURL(for: contentURL) {
                logReaderLoad(
                    "stage=contentLoader.loadContent.finish contentURL=\(contentURL.absoluteString) targetURL=\(loaderURL.absoluteString) reason=snippetLoader"
                )
                return loaderURL
            }
            logReaderLoad(
                "stage=contentLoader.loadContent.finish contentURL=\(contentURL.absoluteString) targetURL=\(content.url.absoluteString) reason=snippetDirect"
            )
            return content.url
        }

        if ["http", "https"].contains(contentURL.scheme?.lowercased()) {
            if content.isReaderModeByDefault,
               contentHasLocallyRetrievableHTML,
               let loaderURL = readerLoaderURL(for: contentURL) {
                logReaderLoad(
                    "stage=contentLoader.loadContent.finish contentURL=\(contentURL.absoluteString) targetURL=\(loaderURL.absoluteString) reason=contentReaderDefault"
                )
                return loaderURL
            }

            if let matchingContent = try await lookupStoredContent(url: contentURL),
               matchingContent.isReaderModeByDefault,
               (try? await hasLocallyRetrievableHTML(
                    for: matchingContent,
                    readerFileManager: readerFileManager
               )) == true,
               let matchingURL = readerLoaderURL(for: matchingContent.url) {
                logReaderLoad(
                    "stage=contentLoader.loadContent.finish contentURL=\(contentURL.absoluteString) targetURL=\(matchingURL.absoluteString) reason=matchingContentReaderDefault matchingContentURL=\(matchingContent.url.absoluteString)"
                )
                return matchingURL
            }
            logReaderLoad(
                "stage=contentLoader.loadContent.finish contentURL=\(contentURL.absoluteString) targetURL=\(content.url.absoluteString) reason=httpDirect"
            )
            return content.url
        }

        if contentURL.isReaderFileURL,
           contentHasLocallyRetrievableHTML,
           let loaderURL = readerLoaderURL(for: contentURL) {
            logReaderLoad(
                "stage=contentLoader.loadContent.finish contentURL=\(contentURL.absoluteString) targetURL=\(loaderURL.absoluteString) reason=fileLoader"
            )
            return loaderURL
        }
        
        logReaderLoad(
            "stage=contentLoader.loadContent.finish contentURL=\(contentURL.absoluteString) targetURL=\(content.url.absoluteString) reason=directFallback"
        )
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
            logReaderLoad("stage=contentLoader.readerLoaderURL.failed contentURL=\(contentURL.absoluteString)")
            return nil
        }
        let loaderURL = URL(string: "internal://local/load/reader?reader-url=\(encodedURL)")
        logReaderLoad(
            "stage=contentLoader.readerLoaderURL contentURL=\(contentURL.absoluteString) loaderURL=\(loaderURL?.absoluteString ?? "nil")"
        )
        return loaderURL
    }
    
    @MainActor
    public static func load(text: String) async throws -> (any ReaderContentProtocol)? {
        let html = snippetHTML(fromRawText: text)
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
        let html = htmlFromData ?? htmlFromValue
        let text = pasteboard.string
#endif
        
        if let text, let url = URL(string: text), url.absoluteString == text, url.scheme != nil, url.host != nil {
            match = try await load(url: url, countsAsHistoryVisit: true)
        } else if let payload = preferredPasteboardPayload(html: html, text: text) {
            let normalized = normalizeIngestedText(payload.text, explicitHTML: payload.explicitHTML, source: .paste)
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

    public static func snippetHTML(fromRawText text: String) -> String {
        normalizeSnippetSourceHTML(textToHTML(text, forceRaw: true))
    }

    public static func snippetHTML(fromHTML html: String) -> String {
        normalizeSnippetSourceHTML(html)
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

    @MainActor
    public static func appendSnippetHTML(
        _ appendedHTML: String,
        to content: any ReaderContentProtocol
    ) async throws -> (any ReaderContentProtocol)? {
        guard content.url.isSnippetURL, let contentRef = ContentReference(content: content) else {
            return nil
        }

        let normalizedAppendedHTML = normalizeSnippetSourceHTML(appendedHTML)

        try await { @RealmBackgroundActor in
            guard let backgroundContent = try await contentRef.resolveOnBackgroundActor(),
                  let realm = backgroundContent.realm else {
                return
            }

            let mergedHTML = try appendSnippetHTML(
                normalizedAppendedHTML,
                toExistingHTML: backgroundContent.html
            )

            try await realm.asyncWrite {
                backgroundContent.html = mergedHTML
                backgroundContent.rssContainsFullContent = true
                backgroundContent.isReaderModeByDefault = true
                backgroundContent.refreshChangeMetadata(explicitlyModified: true)
            }
        }()

        return try await contentRef.resolveOnMainActor()
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
                guard existingHTML != normalizedHTML else { return false }
                object.html = normalizedHTML
                didChange = true
                return true
            }
            return didChange
        }()
    }

    @MainActor
    public static func updateSnippetContent(
        contentURL: URL,
        title: String,
        html: String
    ) async throws -> Bool {
        let normalizedHTML = snippetHTML(fromHTML: html)
        return try await { @RealmBackgroundActor in
            var didChange = false
            try await updateContent(url: contentURL) { object in
                let currentHTML = snippetHTML(fromHTML: object.html ?? "<html><body></body></html>")
                let currentTitle = object.title
                var objectDidChange = false

                if currentTitle != title {
                    object.title = title
                    objectDidChange = true
                }
                if currentHTML != normalizedHTML {
                    object.html = normalizedHTML
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

    static func preferredPasteboardPayload(html: String?, text: String?) -> (text: String, explicitHTML: Bool)? {
        if let html {
            return (html, true)
        }
        if let text {
            return (text, false)
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

    private static let snippetWrapperClass = "manabi-snippet"

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
