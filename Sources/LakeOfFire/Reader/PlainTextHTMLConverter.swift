import Foundation
import SwiftSoup

public enum PlainTextHTMLConverter {
    public static func convert(
        _ text: String,
        forceRaw: Bool,
        escape: (String) -> String
    ) -> String {
        if forceRaw {
            return makeEscapedHTMLBody(fromPlainText: text, escape: escape)
        }

        if let document = try? SwiftSoup.parse(text), isPlainText(document: document) {
            return makeHTMLBody(fromPlainText: text)
        }

        return makeHTMLBody(fromPlainText: text)
    }

    public static func isPlainText(document: SwiftSoup.Document) -> Bool {
        (document.body()?.children().isEmpty() ?? true)
        || ((document.body()?.children().first()?.tagNameNormal() ?? "") == "pre"
            && document.body()?.children().count == 1)
    }

    public static func makeHTMLBody(fromPlainText text: String) -> String {
        "<html><body>\(normalizeLineBreaks(text))</body></html>"
    }

    private static func makeEscapedHTMLBody(
        fromPlainText text: String,
        escape: (String) -> String
    ) -> String {
        var mutableText = text
        if !mutableText.hasSuffix("\n") {
            mutableText.append("\n")
        }
        let escaped = escape(mutableText)
        let withLineBreaks = normalizeLineBreaks(escaped)
        return "<html><body>\(withLineBreaks)</body></html>"
    }

    private static func normalizeLineBreaks(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}
