import Foundation
import LakeOfFireCore
import RealmSwift
import RealmSwiftGaps
import SwiftSoup

/// Semantic image metadata travels with existing HTML, not presentation URLs or
/// additional synchronized fields. Dimensions always belong to this exact URL.
public struct ReaderImageGeometry: Sendable, Equatable {
    public let url: URL
    public let width: Int
    public let height: Int
    public static let metadataName = "mnb-reader-image"

    public static func validDimensions(width: Int, height: Int) -> Bool {
        (1...65_535).contains(width) && (1...65_535).contains(height)
            && width * height <= 100_000_000
    }

    public init?(url: URL, width: Int?, height: Int?) {
        guard url.isHTTP, url.host?.isEmpty == false, url.user == nil, url.password == nil,
              let width, let height, Self.validDimensions(width: width, height: height) else { return nil }
        self.url = url
        self.width = width
        self.height = height
    }

    public func metadataHTML() throws -> String {
        let node = try SwiftSoup.Element(Tag.valueOf("meta"), "")
        try node.attr("name", Self.metadataName)
        try node.attr("content", url.absoluteString)
        try node.attr("data-width", String(width))
        try node.attr("data-height", String(height))
        return try node.outerHtml()
    }

    public static func metadata(in document: SwiftSoup.Document, matchingURL: URL? = nil,
                                sourceURL: URL) -> Self? {
        guard let nodes = try? document.head()?.select("meta[name=\(metadataName)]") else { return nil }
        for node in nodes {
            guard let raw = try? node.attr("content"),
                  let url = URL(string: raw, relativeTo: sourceURL)?.absoluteURL,
                  matchingURL == nil || matchingURL == url,
                  let width = try? node.attr("data-width"), let height = try? node.attr("data-height"),
                  let geometry = Self(url: url, width: Int(width), height: Int(height)) else { continue }
            return geometry
        }
        return nil
    }

    public static func metadata(inHTML html: String?, matchingURL: URL? = nil,
                                sourceURL: URL) -> Self? {
        guard let html else { return nil }
        // Import and canonical generation put metadata at the start of head.
        // Reading it must not parse the article body a second time.
        let prefix = String(html.prefix(65_536))
        guard prefix.contains(metadataName),
              let end = prefix.range(of: "</head>", options: .caseInsensitive),
              let document = try? SwiftSoup.parse(String(prefix[..<end.upperBound])) else { return nil }
        return metadata(in: document, matchingURL: matchingURL, sourceURL: sourceURL)
    }

    /// Store semantic metadata only. Final resource preparation associates it
    /// with images after effective bases and lazy sources have been resolved.
    public func addingToFeedHTML(_ html: String?, sourceURL: URL) -> String? {
        guard let document = try? SwiftSoup.parse(html ?? "", sourceURL.absoluteString) else { return html }
        document.outputSettings().prettyPrint(pretty: false)
        do {
            try document.select("meta[name=\(Self.metadataName)]").remove()
            try document.head()?.prepend(metadataHTML())
            return try document.outerHtml()
        } catch { return html }
    }

    /// Enrich an existing document without parsing or serializing its body.
    /// Captures and generated reader documents share this metadata operation.
    public func mergingIntoDocumentHead(_ html: String, sourceURL: URL) -> String {
        guard Self.metadata(inHTML: html, sourceURL: sourceURL) != self else { return html }
        let prefix = String(html.prefix(65_536))
        guard let start = prefix.range(of: "<head>", options: .caseInsensitive),
              let end = prefix.range(of: "</head>", options: .caseInsensitive),
              start.upperBound <= end.lowerBound,
              let document = try? SwiftSoup.parse(String(prefix[start.lowerBound..<end.upperBound])),
              let head = document.head() else { return html }
        document.outputSettings().prettyPrint(pretty: false)
        do {
            try head.select("meta[name=\(Self.metadataName)]").remove()
            try head.prepend(metadataHTML())
            var result = html
            // Translate indices from the bounded head back to its source.
            let lower = html.index(html.startIndex,
                offsetBy: prefix.distance(from: prefix.startIndex, to: start.lowerBound))
            let upper = html.index(html.startIndex,
                offsetBy: prefix.distance(from: prefix.startIndex, to: end.upperBound))
            result.replaceSubrange(lower..<upper, with: try head.outerHtml())
            return result
        } catch { return html }
    }
}

public extension ReaderContentProtocol {
    @MainActor
    public var locationShortName: String? {
        if url.absoluteString == "about:blank" {
            return "Home"
        } else if url.isNativeReaderView {
            return nil
        } else if ["http", "https"].contains(url.scheme?.lowercased()) {
            return url.host
        } else {
            return titleForDisplay
        }
    }

    func isHome(categorySelection: String?) -> Bool {
        return url.absoluteString == "about:blank" && (categorySelection ?? "home") == "home"
    }

    @MainActor
    func writeAllRelatedAsync(_ block: @escaping (Realm, any ReaderContentProtocol) -> Void) async throws {
        let targetURL = url

        try await { @RealmBackgroundActor in
            try await ReaderContentLoader.updateContent(url: targetURL) { object in
                guard let realm = object.realm else { return false }
                block(realm, object)
                return true
            }
        }()
    }
}
