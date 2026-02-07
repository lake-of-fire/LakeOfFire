import Foundation
import SwiftUtilities

public enum ReaderShareUtilities {
    public static func snippetURL(forKey key: String) -> URL? {
        URL(string: "internal://local/snippet?key=\(key)")
    }

    public static func textToHTML(_ text: String, forceRaw: Bool = false) -> String {
        if forceRaw {
            return makeEscapedHTMLBody(fromPlainText: text)
        }
        return makeHTMLBody(fromPlainText: text)
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

    private static func makeHTMLBody(fromPlainText text: String) -> String {
        let paragraphHTML = makeParagraphHTML(fromPlainText: text) { $0 }
        return "<html><body>\(paragraphHTML)</body></html>"
    }

    private static func makeEscapedHTMLBody(fromPlainText text: String) -> String {
        let paragraphHTML = makeParagraphHTML(fromPlainText: text, escape: escapeHTML)
        return "<html><body>\(paragraphHTML)</body></html>"
    }

    private static func normalizeLineBreaks(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func makeParagraphHTML(
        fromPlainText text: String,
        escape: (String) -> String
    ) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: .newlines)
        var paragraphs = [String]()
        var currentLines = [String]()

        func flushParagraph() {
            guard !currentLines.isEmpty else { return }
            let joined = currentLines.joined(separator: "<br>")
            paragraphs.append(joined)
            currentLines.removeAll(keepingCapacity: true)
        }

        for line in lines {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                flushParagraph()
            } else {
                currentLines.append(escape(line))
            }
        }
        flushParagraph()

        if paragraphs.isEmpty {
            let escaped = escape(normalized)
            return normalizeLineBreaks(escaped)
        }

        return paragraphs.map { "<p>\($0)</p>" }.joined()
    }
}
