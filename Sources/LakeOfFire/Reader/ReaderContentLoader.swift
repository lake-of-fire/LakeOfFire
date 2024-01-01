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

/// Loads from any source by URL.
public struct ReaderContentLoader {
    public struct ContentReference {
        let contentType: RealmSwift.Object.Type
        let contentKey: String
        let realmConfiguration: Realm.Configuration
        
        init?(content: any ReaderContentModel) {
            guard let contentType = content.objectSchema.objectClass as? RealmSwift.Object.Type, let config = content.realm?.configuration else { return nil }
            self.contentType = contentType
            contentKey = content.compoundKey
            realmConfiguration = config
        }
    }
    
    public static var bookmarkRealmConfiguration: Realm.Configuration = .defaultConfiguration
    public static var historyRealmConfiguration: Realm.Configuration = .defaultConfiguration
    public static var feedEntryRealmConfiguration: Realm.Configuration = .defaultConfiguration
 
    public static var unsavedHome: (any ReaderContentModel) {
//        return try await Self.load(url: URL(string: "about:blank")!, persist: false)!
        let historyRecord = HistoryRecord()
        historyRecord.url = URL(string: "about:blank")!
        historyRecord.updateCompoundKey()
        return historyRecord
    }
    
    @MainActor
    public static var home: (any ReaderContentModel) {
        get async throws {
            return try await Self.load(url: URL(string: "about:blank")!, persist: true)!
        }
    }
    
    @MainActor
    public static func fromBackgroundActor(content: any ReaderContentModel) async throws -> (any ReaderContentModel)? {
        guard let ref = await Task(operation: { @RealmBackgroundActor in
            return ContentReference(content: content)
        }).value else { return nil }
        let realm = try await Realm(configuration: ref.realmConfiguration, actor: MainActor.shared)
        return realm.object(ofType: ref.contentType, forPrimaryKey: ref.contentKey) as? any ReaderContentModel
    }
    
    @RealmBackgroundActor
    public static func fromMainActor(content: any ReaderContentModel) async throws -> (any ReaderContentModel)? {
        guard let ref = await Task(operation: { @MainActor in
            return ContentReference(content: content)
        }).value else { return nil }
        let realm = try await Realm(configuration: ref.realmConfiguration, actor: RealmBackgroundActor.shared)
        return realm.object(ofType: ref.contentType, forPrimaryKey: ref.contentKey) as? any ReaderContentModel
    }
    
    @MainActor
    public static func fromBackgroundActor(contents: [any ReaderContentModel]) async throws -> [any ReaderContentModel] {
        var mapped: [any ReaderContentModel] = []
        for content in contents {
            if let newMapped = try await fromBackgroundActor(content: content) {
                mapped.append(newMapped)
            }
        }
        return mapped
    }
    
    @RealmBackgroundActor
    public static func fromMainActor(contents: [any ReaderContentModel]) async throws -> [any ReaderContentModel] {
        var mapped: [any ReaderContentModel] = []
        for content in contents {
            if let newMapped = try await fromMainActor(content: content) {
                mapped.append(newMapped)
            }
        }
        return mapped
    }
    
    @MainActor
    public static func load(url: URL, persist: Bool = true, countsAsHistoryVisit: Bool = false) async throws -> (any ReaderContentModel)? {
        print("!! load \(url)")
        let content = try await Task.detached { @RealmBackgroundActor () -> (any ReaderContentModel)? in
            if url.scheme == "internal" && url.absoluteString.hasPrefix("internal://local/load/") {
                // Don't persist about:load
                // TODO: Perhaps return an empty history record to avoid catching the wrong content in this interim, though.
                return nil
            } else if url.absoluteString == "about:blank" && !persist {
                let historyRecord = HistoryRecord()
                historyRecord.url = url
                historyRecord.updateCompoundKey()
                return historyRecord
            }
            
            var url = url
            if url.isFileURL, url.isEBookURL {
                url = URL(string: "ebook://ebook/load" + url.path) ?? url
            }
            
            let bookmarkRealm = try await Realm(configuration: bookmarkRealmConfiguration, actor: RealmBackgroundActor.shared)
            let historyRealm = try await Realm(configuration: historyRealmConfiguration, actor: RealmBackgroundActor.shared)
            let feedRealm = try await Realm(configuration: feedEntryRealmConfiguration, actor: RealmBackgroundActor.shared)
            
            var match: (any ReaderContentModel)?
            let contentFile = historyRealm.objects(ContentFile.self)
                .where { !$0.isDeleted }
                .sorted(by: \.createdAt, ascending: false)
                .filter(NSPredicate(format: "url == %@", url.absoluteString as CVarArg))
                .first
            let history = historyRealm.objects(HistoryRecord.self)
                .where { !$0.isDeleted }
                .sorted(by: \.createdAt, ascending: false)
                .filter(NSPredicate(format: "url == %@", url.absoluteString as CVarArg))
                .first
            let bookmark = bookmarkRealm.objects(Bookmark.self)
                .where { !$0.isDeleted }
                .sorted(by: \.createdAt, ascending: false)
                .filter(NSPredicate(format: "url == %@", url.absoluteString as CVarArg))
                .first
            let feeds = feedRealm.objects(FeedEntry.self)
                .where { !$0.isDeleted }
                .sorted(by: \.createdAt, ascending: false)
            
            var feed: FeedEntry?
            if url.scheme == "https" {
                feed = feeds.filter("url == %@ || url == %@", url.absoluteString, url.settingScheme("http").absoluteString).first
                feed = feeds.filter(NSPredicate(format: "url == %@ OR url == %@", url.absoluteString as CVarArg, url.settingScheme("http").absoluteString as CVarArg)).first
            } else if !url.isReaderFileURL {
                feed = feeds.filter(NSPredicate(format: "url == %@", url.absoluteString as CVarArg)).first
            }
            
            let candidates: [any ReaderContentModel] = [contentFile, bookmark, history, feed].compactMap { $0 }
            match = candidates.max(by: {
                ($0 as? HistoryRecord)?.lastVisitedAt ?? $0.createdAt < ($1 as? HistoryRecord)?.lastVisitedAt ?? $1.createdAt
            })
            
            if let nonHistoryMatch = match, countsAsHistoryVisit && persist, nonHistoryMatch.objectSchema.objectClass != HistoryRecord.self {
                print("!! make history rec for \(url) from non hist \(nonHistoryMatch.url) \(nonHistoryMatch.className)")
                match = try await nonHistoryMatch.addHistoryRecord(realmConfiguration: historyRealmConfiguration, pageURL: url)
            } else if match == nil {
                print("!! make history rec for \(url) no match...")
                let historyRecord = HistoryRecord()
                historyRecord.url = url
                //        historyRecord.isReaderModeByDefault
                historyRecord.updateCompoundKey()
                if persist {
                    try await historyRealm.asyncWrite {
                        historyRealm.add(historyRecord, update: .modified)
                    }
                }
                match = historyRecord
            }
            print("!! load found match \(match?.className) \(match?.url)")
            print("!! load match \(url.isReaderFileURL) \(url.contains(.plainText)) \(try? String(contentsOf: url))")
            if persist, let match = match, url.isReaderFileURL, url.contains(.plainText),  let realm = match.realm {
                print("!! load match is file, plain text")
                try await realm.asyncWrite {
                    match.isReaderModeByDefault = true
                }
            } else if persist, let match = match, url.isEBookURL, !match.isReaderModeByDefault, let realm = match.realm {
                try await realm.asyncWrite {
                    match.isReaderModeByDefault = true
                }
            }
            return match
        }.value
        if let content = content {
            return try await fromBackgroundActor(content: content)
        }
        return nil
    }
    
    @MainActor
    public static func load(urlString: String) async throws -> (any ReaderContentModel)? {
        guard let url = URL(string: urlString) else { return nil }
        return try await load(url: url)
    }
    
    @MainActor
    public static func load(html: String) async throws -> (any ReaderContentModel)? {
        let content = try await Task.detached { @RealmBackgroundActor () -> (any ReaderContentModel)? in
            let bookmarkRealm = try await Realm(configuration: bookmarkRealmConfiguration, actor: RealmBackgroundActor.shared)
            let historyRealm = try await Realm(configuration: historyRealmConfiguration, actor: RealmBackgroundActor.shared)
            let feedRealm = try await Realm(configuration: feedEntryRealmConfiguration, actor: RealmBackgroundActor.shared)
            
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
            let candidates: [any ReaderContentModel] = [bookmark, history, feed].compactMap { $0 }
            
            if let match = candidates.max(by: { $0.createdAt < $1.createdAt }) {
                return match
            }
            
            let historyRecord = HistoryRecord()
            historyRecord.publicationDate = Date()
            historyRecord.content = data
            // isReaderModeByDefault used to be commented out... why?
            historyRecord.isReaderModeByDefault = true
            historyRecord.updateCompoundKey()
            historyRecord.url = snippetURL(key: historyRecord.compoundKey) ?? historyRecord.url
            try await historyRealm.asyncWrite {
                historyRealm.add(historyRecord, update: .modified)
            }
            return historyRecord
        }.value
        if let content = content {
            return try await fromBackgroundActor(content: content)
        }
        return nil
    }
    
    private static func docIsPlainText(doc: SwiftSoup.Document) -> Bool {
        return (
            ((doc.body()?.children().isEmpty()) ?? true)
            || ((doc.body()?.children().first()?.tagNameNormal() ?? "") == "pre" && doc.body()?.children().count == 1) )
    }
    
    static func textToHTML(_ text: String, forceRaw: Bool = false) -> String {
        var convertedText = text
        if forceRaw {
            convertedText = convertedText.escapeHtml()
        } else if let doc = try? SwiftSoup.parse(text) {
            if docIsPlainText(doc: doc) {
                return "<html><body>\(text)</body></html>"
            } else {
                return text // HTML content
            }
        }
        convertedText = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "<br>")
        return convertedText
    }
    
    public static func snippetURL(key: String) -> URL? {
        return URL(string: "internal://local/snippet?key=\(key)")
    }
    
    @MainActor
    public static func load(text: String) async throws -> (any ReaderContentModel)? {
        return try await load(html: textToHTML(text, forceRaw: true))
    }
    
    @MainActor
    public static func loadPasteboard(bookmarkRealmConfiguration: Realm.Configuration = .defaultConfiguration, historyRealmConfiguration: Realm.Configuration = .defaultConfiguration, feedEntryRealmConfiguration: Realm.Configuration = .defaultConfiguration) async throws -> (any ReaderContentModel)? {
        var match: (any ReaderContentModel)?
        
#if os(macOS)
        let html = NSPasteboard.general.string(forType: .html)
        let text = NSPasteboard.general.string(forType: .string)
#else
        let html = UIPasteboard.general.string
        let text: String? = html
#endif
        
        if let html = html {
            if let doc = try? SwiftSoup.parse(html) {
                if docIsPlainText(doc: doc), let text = text {
                    match = try await load(html: textToHTML(text))
                } else {
                    match = try await load(html: html)
                }
                //                match = load(html: html)
            } else {
                match = try await load(html: textToHTML(html))
            }
        } else if let text = text {
            match = try await load(html: textToHTML(text))
        }
        
        if let match = match, let realm = match.realm {
            let url = snippetURL(key: match.compoundKey) ?? match.url
            try await realm.asyncWrite {
                match.isFromClipboard = true
                match.rssContainsFullContent = true
                match.url = url
            }
        }
        return match
    }
    
    @RealmBackgroundActor
    public static func saveBookmark(text: String?, title: String?, url: URL, isFromClipboard: Bool, isReaderModeByDefault: Bool) async throws {
        if let text = text {
            try await _ = Bookmark.add(url: url, title: title ?? "", html: textToHTML(text), isFromClipboard: isFromClipboard, isReaderModeByDefault: isReaderModeByDefault, realmConfiguration: bookmarkRealmConfiguration)
        } else {
            try await _ = Bookmark.add(url: url, title: title ?? "", isFromClipboard: isFromClipboard, isReaderModeByDefault: isReaderModeByDefault, realmConfiguration: bookmarkRealmConfiguration)
        }
    }
    
    @RealmBackgroundActor
    public static func saveBookmark(text: String, title: String?, url: URL?, isFromClipboard: Bool, isReaderModeByDefault: Bool) async throws {
        let html = Self.textToHTML(text)
        try await _ = Bookmark.add(url: url, title: title ?? "", html: html, isFromClipboard: isFromClipboard, isReaderModeByDefault: isReaderModeByDefault, realmConfiguration: bookmarkRealmConfiguration)
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
