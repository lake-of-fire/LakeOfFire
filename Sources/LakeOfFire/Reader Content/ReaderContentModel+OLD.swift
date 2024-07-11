//import Foundation
//import RealmSwift
//import ManabiCommon
//import LakeKit
//
//protocol ReaderContentProtocol: RealmSwift.Object, ObjectKeyIdentifiable, Equatable {
//    var compoundKey: String { get set }
//    var keyPrefix: String? { get }
//
//    var url: URL { get set }
//    var title: String { get set }
//    var imageUrl: URL? { get set }
//    var content: Data? { get set }
//    var publicationDate: Date? { get set }
//    var isFromClipboard: Bool { get set }
//
//    // Feed entry metadata.
//    var voiceFrameUrl: URL? { get set }
//    var voiceAudioUrl: URL? { get set }
//    var redditTranslationsUrl: URL? { get set }
//    var redditTranslationsTitle: String? { get set }
//
//    // Feed options.
//    /// Whether the content be viewed directly instead of loading the URL.
//    var rssContainsFullContent: Bool? { get set }
//    var meaningfulContentMinLength: Int? { get set }
//    var injectEntryImageIntoHeader: Bool? { get set }
//    var displayPublicationDate: Bool? { get set }
//
//    var createdAt: Date { get }
//    var isDeleted: Bool { get }
//
//    func configureBookmark(_ bookmark: Bookmark)
//}
//
//extension ReaderContentProtocol {
//    var keyPrefix: String? {
//        return nil
//    }
//
////    var rawEntryThumbnailContentMode: Int = UIView.ContentMode.scaleAspectFill.rawValue
//    /*var entryThumbnailContentMode: UIView.ContentMode {
//        get {
//            return UIView.ContentMode(rawValue: rawEntryThumbnailContentMode)!
//        }
//        set {
//            rawEntryThumbnailContentMode = newValue.rawValue
//        }
//    }*/
//
//    var isReaderModeByDefault: Bool {
//        if isFromClipboard || self is FeedEntry {
//            return true
//        }
//        guard let bareHostURL = URL(string: "\(url.scheme ?? "https")://\(url.host ?? "")") else { return false }
//        let realm = try! Realm(configuration: SharedRealmConfigurer.configuration)
//        return !realm.objects(FeedEntry.self).filter { $0.url.absoluteString.starts(with: bareHostURL.absoluteString) }.isEmpty
//    }
//
//    // TODO: Finish this old logic..?
//    var isNHKEasyNews: Bool {
//        return ["www.reddit.com", "old.reddit.com", "i.reddit.com"].contains(url.host ?? "") && url.path.contains("NHKEasyNews")
//    }
//
//    /// Deprecated, use `content`.
//    var htmlContent: String? {
//        get {
//            return nil
//        }
//        set { }
//    }
//}
//
//extension String {
//    var readerContentData: Data? {
//        guard let newData = data(using: .utf8) else {
//            return nil
//        }
//        return try? (newData as NSData).compressed(using: .lzfse) as Data
//    }
//}
//
//extension ReaderContentProtocol {
//    var humanReadablePublicationDate: String? {
//        guard let publicationDate = publicationDate else { return nil}
//
//        let interval = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .nanosecond], from: publicationDate, to: Date())
//        let intervalText: String
//        if let year = interval.year, year > 0 {
//            intervalText = "\(year) year\(year != 1 ? "s" : "")"
//        } else if let month = interval.month, month > 0 {
//            intervalText = "\(month) month\(month != 1 ? "s" : "")"
//        } else if let day = interval.day, day > 0 {
//            intervalText = "\(day) day\(day != 1 ? "s" : "")"
//        } else if let hour = interval.hour, hour > 0 {
//            intervalText = "\(hour) hour\(hour != 1 ? "s" : "")"
//        } else if let minute = interval.minute, minute > 0 {
//            intervalText = "\(minute) minute\(minute != 1 ? "s" : "")"
//        } else if let nanosecond = interval.nanosecond, nanosecond > 0 {
//            intervalText = "\(nanosecond / 1000000000) second\(nanosecond != 1000000000 ? "s" : "")"
//        } else {
//            return nil
//        }
//        return "\(intervalText) ago"
//    }
//
//    static func contentToHTML(legacyHTMLContent: String?, content: Data?) -> String? {
//            if let legacyHtml = legacyHTMLContent {
//                return legacyHtml
//            }
//            guard let content = content else { return nil }
//            let nsContent: NSData = content as NSData
//            guard let data = try? nsContent.decompressed(using: .lzfse) as Data? else {
//                return nil
//            }
//            return String(decoding: data, as: UTF8.self)
//    }
//
//    var html: String? {
//        get { Self.contentToHTML(legacyHTMLContent: htmlContent, content: content) }
//        set {
//            htmlContent = nil
//            content = newValue?.readerContentData
//        }
//    }
//
//    var titleForDisplay: String {
//        get {
//            if !title.isEmpty {
//                return title
//            }
//
//            guard let htmlData = html?.data(using: .utf8) else { return "" }
//            let attributedStringContent: NSAttributedString
//            do {
//                attributedStringContent = try NSAttributedString(data: htmlData, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
//            } catch {
//                print("Unexpected error:", error)
//                return ""
//            }
//            var titleForDisplay = "\((attributedStringContent.string.components(separatedBy: "\n").first ?? attributedStringContent.string).truncate(36, trailing: "…"))"
//            if isFromClipboard {
//                titleForDisplay = "📎 " + titleForDisplay
//            }
//            return titleForDisplay
//        }
//    }
//
//    static func makePrimaryKey(keyPrefix: String? = nil, url: URL? = nil, html: String? = nil) -> String? {
//        return makeReaderContentCompoundKey(keyPrefix: keyPrefix, url: url, html: html)
//    }
//
//    func updateCompoundKey() {
//        compoundKey = makeReaderContentCompoundKey(keyPrefix: keyPrefix, url: url, html: html) ?? compoundKey
//    }
//}
//
//func makeReaderContentCompoundKey(keyPrefix: String?, url: URL?, html: String?) -> String? {
//    guard url != nil || html != nil else {
////        fatalError("Needs either url or htmlContent.")
//        return nil
//    }
//    var key = ""
//    if let keyPrefix = keyPrefix {
//        key.append(keyPrefix + "-")
//    }
//    if let url = url {
//        key.append(String(format: "%02X", stableHash(url.absoluteString)))
//    } else if let html = html {
//        key.append((String(format: "%02X", stableHash(html))))
//    }
//    return key
//}
