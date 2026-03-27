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
            return contentURL
        }
        if pageURL.absoluteString.hasPrefix("internal://local/load/reader?reader-url="), let range = pageURL.absoluteString.range(of: "?reader-url=", options: []), let rawURL = String(pageURL.absoluteString[range.upperBound...]).removingPercentEncoding, let contentURL = URL(string: rawURL) {
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
        return candidates
    }
    
    @MainActor
    public static func load(url: URL, persist: Bool = true, countsAsHistoryVisit: Bool = false) async throws -> (any ReaderContentProtocol)? {
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
        return try await contentRef?.resolveOnMainActor()
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
            
            let data = html.readerContentData
            
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
            return content.url
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
