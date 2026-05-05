import Foundation
import LakeOfFireCore
import MarkdownKit
import SwiftSoup
import UniformTypeIdentifiers

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

    private static func detectedSupportedFileFormat(
        mimeType: String? = nil,
        typeIdentifier: String? = nil,
        pathExtension: String? = nil
    ) -> IngestedTextFormat? {
        let normalizedMimeType = mimeType?.lowercased()
        let normalizedTypeIdentifier = typeIdentifier?.lowercased()
        let normalizedExtension = pathExtension?.lowercased()

        let isPlainTextLikeMetadata =
            (normalizedMimeType == nil || normalizedMimeType == plainTextMimeType)
            && (normalizedTypeIdentifier == nil || normalizedTypeIdentifier == UTType.plainText.identifier.lowercased())

        if normalizedMimeType == htmlMimeType || normalizedTypeIdentifier == UTType.html.identifier.lowercased() {
            return .html
        }
        if normalizedMimeType == markdownMimeType || normalizedTypeIdentifier == markdownUTTypeIdentifier {
            return .markdown
        }
        if markdownExtensions.contains(normalizedExtension ?? ""), isPlainTextLikeMetadata {
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

        return nil
    }

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
            debugPrint(
                "# SNIPPETS",
                "normalizeIngestedText",
                "source=\(source)",
                "explicitHTML=\(explicitHTML)",
                "format=html",
                "textPreview=\(text.truncate(80))"
            )
            return IngestionResult(format: .html, html: text)
        case .markdown:
            debugPrint(
                "# SNIPPETS",
                "normalizeIngestedText",
                "source=\(source)",
                "explicitHTML=\(explicitHTML)",
                "format=markdown",
                "textPreview=\(text.truncate(80))"
            )
            return IngestionResult(format: .markdown, html: markdownToHTML(text))
        case .plainText:
            debugPrint(
                "# SNIPPETS",
                "normalizeIngestedText",
                "source=\(source)",
                "explicitHTML=\(explicitHTML)",
                "format=plainText",
                "textPreview=\(text.truncate(80))"
            )
            return IngestionResult(format: .plainText, html: textToHTML(text, forceRaw: true))
        }
    }

    static func detectFileFormat(
        mimeType: String? = nil,
        typeIdentifier: String? = nil,
        pathExtension: String? = nil
    ) -> IngestedTextFormat {
        detectedSupportedFileFormat(
            mimeType: mimeType,
            typeIdentifier: typeIdentifier,
            pathExtension: pathExtension
        ) ?? .plainText
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

        if let detectedFormat = detectedSupportedFileFormat(
            mimeType: mimeType,
            typeIdentifier: typeIdentifier,
            pathExtension: pathExtension
        ) {
            switch detectedFormat {
            case .html:
                return htmlMimeType
            case .markdown:
                return markdownMimeType
            case .plainText:
                return plainTextMimeType
            }
        }

        if let normalizedMimeType, !normalizedMimeType.isEmpty {
            return normalizedMimeType
        }
        if let normalizedExtension,
           let inferredMimeType = UTType(filenameExtension: normalizedExtension)?.preferredMIMEType?.lowercased() {
            return inferredMimeType
        }
        return "application/octet-stream"
    }

    public static func supportsReaderContent(
        mimeType: String? = nil,
        pathExtension: String? = nil
    ) -> Bool {
        detectedSupportedFileFormat(
            mimeType: mimeType,
            pathExtension: pathExtension
        ) != nil
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
