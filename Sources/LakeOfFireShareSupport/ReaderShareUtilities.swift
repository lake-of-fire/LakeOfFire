import Foundation
import SwiftSoup
import SwiftUtilities
import LakeOfFireContent

public enum ReaderShareUtilities {
    public static func snippetURL(forKey key: String) -> URL? {
        URL(string: "internal://local/snippet?key=\(key)")
    }

    public static func textToHTML(_ text: String, forceRaw: Bool = false) -> String {
        PlainTextHTMLConverter.convert(text, forceRaw: forceRaw, escape: escapeHTML)
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
