import Foundation
import SwiftSoup
import SwiftUtilities

public enum ReaderShareUtilities {
    public static func snippetURL(forKey key: String) -> URL? {
        URL(string: "internal://local/snippet?key=\(key)")
    }

    public static func textToHTML(_ text: String, forceRaw: Bool = false) -> String {
        var convertedText = text
        if forceRaw {
            convertedText = escapeHTML(convertedText)
        } else if let document = try? SwiftSoup.parse(text) {
            if docIsPlainText(document: document) {
                convertedText = makeHTMLBody(fromPlainText: text)
            }
        } else {
            convertedText = makeHTMLBody(fromPlainText: text)
        }
        return convertedText
    }

    public static func makeCompoundKey(url: URL?, html: String?) -> String? {
        guard url != nil || html != nil else {
            return nil
        }
        var key = ""
        if let url,
           !(url.absoluteString.hasPrefix("about:") || url.absoluteString.hasPrefix("internal://local")) || html == nil {
            key.append(String(format: "%02X", stableHash(url.absoluteString)))
        } else if let html {
            key.append(String(format: "%02X", stableHash(html)))
        }
        return key
    }

    private static func docIsPlainText(document: SwiftSoup.Document) -> Bool {
        (document.body()?.children().isEmpty() ?? true)
        || ((document.body()?.children().first()?.tagNameNormal() ?? "") == "pre" && document.body()?.children().count == 1)
    }

    private static func makeHTMLBody(fromPlainText text: String) -> String {
        "<html><body>\(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "<br>"))</body></html>"
    }

    private static func escapeHTML(_ text: String) -> String {
        var escaped = text
        let mappings: [(String, String)] = [
            ("&", "&amp;"),
            ("\"", "&quot;"),
            ("'", "&#39;"),
            ("<", "&lt;"),
            (">", "&gt;")
        ]
        for (source, replacement) in mappings {
            escaped = escaped.replacingOccurrences(of: source, with: replacement)
        }
        return escaped
    }
}
