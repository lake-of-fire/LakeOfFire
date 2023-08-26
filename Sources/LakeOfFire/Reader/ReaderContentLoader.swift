import Foundation
import RealmSwift
import MarkdownKit
import SwiftSoup
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import RealmSwiftGaps

fileprivate extension URL {
    func settingScheme(_ value: String) -> URL {
        let components = NSURLComponents.init(url: self, resolvingAgainstBaseURL: true)
        components?.scheme = value
        return (components?.url!)!
    }
}
    
/// Loads from any source by URL.
public struct ReaderContentLoader {
    public static var bookmarkRealmConfiguration: Realm.Configuration = .defaultConfiguration
    public static var historyRealmConfiguration: Realm.Configuration = .defaultConfiguration
    public static var feedEntryRealmConfiguration: Realm.Configuration = .defaultConfiguration
    
    public static var unsavedHome: (any ReaderContentModel) {
        return Self.load(url: URL(string: "about:blank")!, persist: false)!
    }
    public static var home: (any ReaderContentModel) {
        return Self.load(url: URL(string: "about:blank")!, persist: true)!
    }
    
    public static func load(url: URL, persist: Bool = true, countsAsHistoryVisit: Bool = false) -> (any ReaderContentModel)? {
        let lowerURL = url.absoluteString.lowercased()
        if url.scheme == "about" && lowerURL.starts(with: "about:load") {
            // Don't persist about:load
            // TODO: Perhaps return an empty history record to avoid catching the wrong content in this interim, though.
            return nil
        } else if url.scheme == "about" && lowerURL.starts(with: "about:blank") && !persist {
            let historyRecord = HistoryRecord()
            historyRecord.url = url
            historyRecord.updateCompoundKey()
            return historyRecord
        }
        
        var url = url
        if url.isEBookURL, url.isFileURL {
            url = URL(string: "ebook://ebook/load" + url.path) ?? url
        }
        
        guard let bookmarkRealm = try? Realm(configuration: bookmarkRealmConfiguration), let historyRealm = try? Realm(configuration: historyRealmConfiguration), let feedRealm = try? Realm(configuration: feedEntryRealmConfiguration) else { return nil }
        
        var match: (any ReaderContentModel)?
        let history = historyRealm.objects(HistoryRecord.self)
            .where { !$0.isDeleted }
            .sorted(by: \.createdAt, ascending: false)
            .filter("url == %@", url.absoluteString)
            .first
        let bookmark = bookmarkRealm.objects(Bookmark.self)
            .where { !$0.isDeleted }
            .sorted(by: \.createdAt, ascending: false)
            .filter("url == %@", url.absoluteString)
            .first
        let feeds = feedRealm.objects(FeedEntry.self)
            .where { !$0.isDeleted }
            .sorted(by: \.createdAt, ascending: false)
        
        var feed: FeedEntry?
        if url.scheme == "https" {
            feed = feeds.filter("url == %@ || url == %@", url.absoluteString, url.settingScheme("http").absoluteString).first
        } else {
            feed = feeds.filter("url == %@", url.absoluteString).first
        }
        
        let candidates: [any ReaderContentModel] = [bookmark, history, feed].compactMap { $0 }
        match = candidates.max(by: {
            ($0 as? HistoryRecord)?.lastVisitedAt ?? $0.createdAt < ($1 as? HistoryRecord)?.lastVisitedAt ?? $1.createdAt
        })
        
        if !url.isFileURL, let nonHistoryMatch = match, countsAsHistoryVisit && persist, nonHistoryMatch.objectSchema.objectClass != HistoryRecord.self {
            match = nonHistoryMatch.addHistoryRecord(realmConfiguration: historyRealmConfiguration, pageURL: url)
        } else if match == nil {
            let historyRecord = HistoryRecord()
            historyRecord.url = url
            //        historyRecord.isReaderModeByDefault
            historyRecord.updateCompoundKey()
            if persist {
                try! historyRealm.write {
                    historyRealm.add(historyRecord, update: .modified)
                }
            }
            match = historyRecord
        }
        if persist, let match = match, url.isFileURL, url.contains(.plainText), let contents = try? String(contentsOf: url), let data = textToHTML(contents, forceRaw: true).readerContentData {
            safeWrite(match) { _, match in
                match.content = data
            }
        }
        if persist, let match = match, url.isEBookURL, !match.isReaderModeByDefault {
            safeWrite(match) { _, match in
                match.isReaderModeByDefault = true
            }
        }
        return match
    }
    
    public static func load(urlString: String) -> (any ReaderContentModel)? {
        guard let url = URL(string: urlString) else { return nil }
        return load(url: url)
    }
    
    public static func load(html: String) -> (any ReaderContentModel)? {
        guard let bookmarkRealm = try? Realm(configuration: bookmarkRealmConfiguration), let historyRealm = try? Realm(configuration: historyRealmConfiguration), let feedRealm = try? Realm(configuration: feedEntryRealmConfiguration) else { return nil }
        
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
        try! historyRealm.write {
            historyRealm.add(historyRecord, update: .modified)
        }
        return historyRecord
    }
    
    private static func docIsPlainText(doc: SwiftSoup.Document) -> Bool {
        return (
            ((doc.body()?.children().isEmpty()) ?? true)
            || ((doc.body()?.children().first()?.tagNameNormal() ?? "") == "pre" && doc.body()?.children().count == 1) )
    }
    
    private static func textToHTML(_ text: String, forceRaw: Bool = false) -> String {
        if forceRaw {
            return "<html><body>\(text.escapeHtml())</body></html>"
        } else if let doc = try? SwiftSoup.parse(text) {
            if docIsPlainText(doc: doc) {
                return "<html><body>\(text)</body></html>"
            } else {
                return text // HTML content
            }
        } else {
            let markdown = MarkdownParser.standard.parse(text.trimmingCharacters(in: .whitespacesAndNewlines))
            let html = PasteboardHTMLGenerator().generate(doc: markdown)
            return "<html><body>\(html)</body></html>"
        }
    }
    
    public static func snippetURL(key: String) -> URL? {
        return URL(string: "about:snippet?key=\(key)")
    }
    
    public static func load(text: String) -> (any ReaderContentModel)? {
        return load(html: textToHTML(text, forceRaw: true))
    }
    
    public static func loadPasteboard(bookmarkRealmConfiguration: Realm.Configuration = .defaultConfiguration, historyRealmConfiguration: Realm.Configuration = .defaultConfiguration, feedEntryRealmConfiguration: Realm.Configuration = .defaultConfiguration) -> (any ReaderContentModel)? {
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
                    match = load(html: textToHTML(text))
                } else {
                    match = load(html: html)
                }
//                match = load(html: html)
            } else {
                match = load(html: textToHTML(html))
            }
        } else if let text = text {
            match = load(html: textToHTML(text))
        }
        if let match = match {
            let url = snippetURL(key: match.compoundKey) ?? match.url
            safeWrite(match) { _, match in
                match.isFromClipboard = true
                match.rssContainsFullContent = true
                match.url = url
            }
        }
        return match
    }
    
    public static func saveBookmark(text: String?, title: String?, url: URL, isFromClipboard: Bool, isReaderModeByDefault: Bool) {
        if let text = text {
            _ = Bookmark.add(url: url, title: title ?? "", html: textToHTML(text), isFromClipboard: isFromClipboard, isReaderModeByDefault: isReaderModeByDefault, realmConfiguration: bookmarkRealmConfiguration)
        } else {
            _ = Bookmark.add(url: url, title: title ?? "", isFromClipboard: isFromClipboard, isReaderModeByDefault: isReaderModeByDefault, realmConfiguration: bookmarkRealmConfiguration)
        }
    }
    
    public static func saveBookmark(text: String, title: String?, url: URL?, isFromClipboard: Bool, isReaderModeByDefault: Bool) {
        let html = Self.textToHTML(text)
        _ = Bookmark.add(url: url, title: title ?? "", html: html, isFromClipboard: isFromClipboard, isReaderModeByDefault: isReaderModeByDefault, realmConfiguration: bookmarkRealmConfiguration)
    }
}

/// Forked from: https://github.com/objecthub/swift-markdownkit/issues/6
open class PasteboardHTMLGenerator: HtmlGenerator {
    override open func generate(text: Text) -> String {
        var res = ""
        for (idx, fragment) in text.enumerated() {
            if (idx + 1) < text.count {
                let next = text[idx + 1]
                switch (fragment as TextFragment, next as TextFragment) {
                case (.softLineBreak, .text(let text)):
                    if text.starts(with: "　") || text.starts(with: "    ") {
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
