import Foundation
import MarkdownKit
import SwiftSoup
import UniformTypeIdentifiers
import LakeOfFireCore
import LakeOfFireAdblock

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

extension ReaderContentLoader {
    public enum IngestedTextFormat: Equatable {
        case html
        case markdown
        case plainText
    }

    public enum IngestionSourceContext {
        case paste
        case file
    }

    public struct IngestionResult: Equatable {
        public let format: IngestedTextFormat
        public let html: String
    }

    private static let markdownMimeType = "text/markdown"
    private static let markdownUTTypeIdentifier = "net.daringfireball.markdown"
    private static let htmlMimeType = "text/html"
    private static let plainTextMimeType = "text/plain"
    private static let htmlExtensions: Set<String> = ["html", "htm"]
    private static let markdownExtensions: Set<String> = ["md", "markdown"]
    private static let plainTextExtensions: Set<String> = ["txt", "text"]

    public static func normalizeIngestedText(
        _ text: String,
        explicitHTML: Bool = false,
        mimeType: String? = nil,
        typeIdentifier: String? = nil,
        pathExtension: String? = nil,
        source: IngestionSourceContext
    ) -> IngestionResult {
        let detectedFormat: IngestedTextFormat

        switch source {
        case .paste:
            if explicitHTML {
                detectedFormat = .html
            } else if looksLikeHTML(text) {
                detectedFormat = .html
            } else {
                detectedFormat = .markdown
            }
        case .file:
            detectedFormat = detectFileFormat(
                mimeType: mimeType,
                typeIdentifier: typeIdentifier,
                pathExtension: pathExtension
            )
        }

        switch detectedFormat {
        case .html:
            return IngestionResult(format: .html, html: text)
        case .markdown:
            return IngestionResult(format: .markdown, html: markdownToHTML(text))
        case .plainText:
            return IngestionResult(format: .plainText, html: textToHTML(text, forceRaw: true))
        }
    }

    static func detectFileFormat(
        mimeType: String? = nil,
        typeIdentifier: String? = nil,
        pathExtension: String? = nil
    ) -> IngestedTextFormat {
        let normalizedMimeType = mimeType?.lowercased()
        let normalizedTypeIdentifier = typeIdentifier?.lowercased()
        let normalizedExtension = pathExtension?.lowercased()

        if normalizedMimeType == htmlMimeType || normalizedTypeIdentifier == UTType.html.identifier.lowercased() {
            return .html
        }
        if normalizedMimeType == markdownMimeType || normalizedTypeIdentifier == markdownUTTypeIdentifier {
            return .markdown
        }
        if normalizedMimeType == plainTextMimeType || normalizedTypeIdentifier == UTType.plainText.identifier.lowercased() {
            return .plainText
        }

        if let normalizedExtension {
            if htmlExtensions.contains(normalizedExtension) {
                return .html
            }
            if markdownExtensions.contains(normalizedExtension) {
                return .markdown
            }
            if plainTextExtensions.contains(normalizedExtension) {
                return .plainText
            }
        }

        return .plainText
    }

    static func canonicalMimeType(
        mimeType: String? = nil,
        typeIdentifier: String? = nil,
        pathExtension: String? = nil
    ) -> String {
        let normalizedMimeType = mimeType?.lowercased()
        let normalizedTypeIdentifier = typeIdentifier?.lowercased()
        let normalizedExtension = pathExtension?.lowercased()

        if markdownExtensions.contains(normalizedExtension ?? ""),
           (
            normalizedMimeType == markdownMimeType
                || normalizedTypeIdentifier == markdownUTTypeIdentifier
                || ((normalizedMimeType == plainTextMimeType || normalizedMimeType == nil)
                    && (normalizedTypeIdentifier == UTType.plainText.identifier.lowercased() || normalizedTypeIdentifier == nil))
           ) {
            return markdownMimeType
        }

        switch detectFileFormat(mimeType: mimeType, typeIdentifier: typeIdentifier, pathExtension: pathExtension) {
        case .html:
            return htmlMimeType
        case .markdown:
            return markdownMimeType
        case .plainText:
            return plainTextMimeType
        }
    }

    public static func supportsReaderContent(
        mimeType: String? = nil,
        pathExtension: String? = nil
    ) -> Bool {
        switch detectFileFormat(mimeType: mimeType, pathExtension: pathExtension) {
        case .html, .markdown, .plainText:
            return true
        }
    }

    private static func looksLikeHTML(_ text: String) -> Bool {
        guard let doc = try? SwiftSoup.parse(text) else {
            return false
        }
        return !docIsPlainText(doc: doc)
    }

    private static func markdownToHTML(_ text: String) -> String {
        let parser = MarkdownParser()
        let generator = PasteboardHTMLGenerator()
        let parsed = parser.parse(text)
        let htmlBody = generator.generate(doc: parsed)
        return "<html><body>\(htmlBody)</body></html>"
    }
}
