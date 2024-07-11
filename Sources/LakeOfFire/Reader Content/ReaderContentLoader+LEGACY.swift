//import Foundation
//import RealmSwift
//import ManabiCommon
//import LakeKit
//import MarkdownKit
//import SwiftSoup
//#if os(macOS)
//import AppKit
//#else
//import UIKit
//#endif
//
///// Loads from any source by URL.
//struct ReaderContentLoader {
//    static func load(url: URL) -> (any ReaderContentProtocol)? {
//        guard let realm = try? Realm(), let sharedRealm = try? Realm(configuration: SharedRealmConfigurer.configuration) else { return nil }
//
//        let bookmark = realm.objects(Bookmark.self)
//            .sorted(by: \.createdAt, ascending: false)
//            .first(where: { $0.url == url })
//        let history = realm.objects(HistoryRecord.self)
//            .sorted(by: \.createdAt, ascending: false)
//            .first(where: { $0.url == url })
//        let feed = sharedRealm.objects(FeedEntry.self)
//            .sorted(by: \.createdAt, ascending: false)
//            .first(where: { $0.url == url })
//        let candidates: [any ReaderContentProtocol] = [bookmark, history, feed].compactMap { $0 }
//
//        if let match = candidates.max(by: { $0.createdAt < $1.createdAt }) {
//            return match
//        }
//
//        let historyRecord = HistoryRecord()
//        historyRecord.url = url
//        historyRecord.updateCompoundKey()
//        try! realm.write {
//            realm.add(historyRecord, update: .modified)
//        }
//        return historyRecord
//    }
//
//    static func load(urlString: String) -> (any ReaderContentProtocol)? {
//        guard let url = URL(string: urlString) else { return nil }
//        return load(url: url)
//    }
//
//    static func load(html: String) -> (any ReaderContentProtocol)? {
//        guard let realm = try? Realm(), let sharedRealm = try? Realm(configuration: SharedRealmConfigurer.configuration) else { return nil }
//
//        let data = html.readerContentData
//
//        let bookmark = realm.objects(Bookmark.self)
//            .sorted(by: \.createdAt, ascending: false)
//            .first(where: { $0.content == data })
//        let history = realm.objects(HistoryRecord.self)
//            .sorted(by: \.createdAt, ascending: false)
//            .first(where: { $0.content == data })
//        let feed = sharedRealm.objects(FeedEntry.self)
//            .sorted(by: \.createdAt, ascending: false)
//            .first(where: { $0.content == data })
//        let candidates: [any ReaderContentProtocol] = [bookmark, history, feed].compactMap { $0 }
//
//        if let match = candidates.max(by: { $0.createdAt < $1.createdAt }) {
//            return match
//        }
//
//        let historyRecord = HistoryRecord()
//        historyRecord.publicationDate = Date()
//        historyRecord.content = data
//        historyRecord.updateCompoundKey()
//        try! realm.write {
//            realm.add(historyRecord, update: .modified)
//        }
//        return historyRecord
//    }
//
//    private static func textToHTML(_ text: String) -> String {
//        let markdown = MarkdownParser.standard.parse(text.trimmingCharacters(in: .whitespacesAndNewlines))
//        print(markdown)
//        let html = PasteboardHTMLGenerator().generate(doc: markdown)
//        return "<html><body>\(html)</body></html>"
//    }
//
//    static func loadPasteboard() -> (any ReaderContentProtocol)? {
//        var match: (any ReaderContentProtocol)?
//
//        #if os(macOS)
//        let html = NSPasteboard.general.string(forType: .html)
//        let text = NSPasteboard.general.string(forType: .string)
//        #else
//        let html = UIPasteboard.general.string
//        let text: String? = html
//        #endif
//
//        if let html = html {
//            if let doc = try? SwiftSoup.parse(html) {
//                if !((doc.body()?.children().isEmpty()) ?? true) || ((doc.body()?.children().first()?.tagNameNormal() ?? "") == "pre" && doc.body()?.children().count == 1), let text = text {
//                    match = load(html: textToHTML(text))
//                } else {
//                    match = load(html: html)
//                }
//            } else {
//                match = load(html: textToHTML(html))
//            }
//        } else if let text = text {
//                match = load(html: textToHTML(text))
//        }
//        if let match = match, let url = URL(string: "about:snippet?key=\(match.compoundKey)") {
//            safeWrite(match) { _, match in
//                match.isFromClipboard = true
//                match.url = url
//            }
//        }
//        return match
//    }
//}
//
///// Forked from: https://github.com/objecthub/swift-markdownkit/issues/6
//open class PasteboardHTMLGenerator: HtmlGenerator {
//    override open func generate(text: Text) -> String {
//        var res = ""
//        for (idx, fragment) in text.enumerated() {
//            if (idx + 1) < text.count {
//                let next = text[idx + 1]
//                switch (fragment as TextFragment, next as TextFragment) {
//                case (.softLineBreak, .text(let text)):
//                    if text.starts(with: "　") || text.starts(with: "    ") {
//                        res += "<br/><br/>" // TODO: Morph to paragraph
//                        continue
//                    }
//                case (.softLineBreak, .softLineBreak):
//                    res += "<br/><br/>" // TODO: Morph to paragraph
//                    continue
//                default:
//                    break
//                }
//            }
//
//            res += generate(textFragment: fragment)
//        }
//        return res
//    }
//
////    override open func generate(textFragment fragment: TextFragment) -> String {
////        switch fragment {
////        case .softLineBreak:
////            return "<br/>"
////        default:
////            return super.generate(textFragment: fragment)
////        }
////    }
//}
