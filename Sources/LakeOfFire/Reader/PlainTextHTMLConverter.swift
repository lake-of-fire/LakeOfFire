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
        let paragraphHTML = makeParagraphHTML(fromPlainText: text) { $0 }
        return "<html><body>\(paragraphHTML)</body></html>"
    }

    private static func makeEscapedHTMLBody(
        fromPlainText text: String,
        escape: (String) -> String
    ) -> String {
        let paragraphHTML = makeParagraphHTML(fromPlainText: text, escape: escape)
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
        var paragraphs: [String] = []
        var currentLines: [String] = []

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
