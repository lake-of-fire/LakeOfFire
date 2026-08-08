import Foundation
import SwiftSoup

private let ebookTextProcessorDetailedLoggingEnabled: Bool = {
#if DEBUG
    ProcessInfo.processInfo.environment["MANABI_REPLACETEXT_DETAILED_LOGS"] == "1"
#else
    false
#endif
}()
private let ebookTextProcessorSegmentOpenTagBytes = Array("<m-m".utf8)
private let ebookTextProcessorSentenceOpenTagBytes = Array("<m-s".utf8)

@inline(__always)
private func bodyStartsWithReaderSentinel(_ body: Element) -> Bool {
    for index in 0..<body.childNodeSize() {
        let node = body.childNode(index)
        if let textNode = node as? TextNode, textNode.isBlank() {
            continue
        }
        guard let element = node as? Element else {
            return false
        }
        return element.tagName() == "reader-sentinel"
    }
    return false
}

internal extension URL {
    /// Backport of iOS 16+ `appending(queryItems:)` for iOS 15
    func appending(queryItems items: [URLQueryItem]) -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: true) else {
            return self
        }
        var existingItems = components.queryItems ?? []
        existingItems.append(contentsOf: items)
        components.queryItems = existingItems
        return components.url ?? self
    }
}

internal func preprocessEbookContent(doc: SwiftSoup.Document) -> SwiftSoup.Document {
    // Apply visibility sentinels. In the ebook pipeline this must run after
    // reader tags are injected, so sentinels never split text before MeCab sees it.
    guard let body = doc.body() else { return doc }
    if bodyStartsWithReaderSentinel(body) {
        try? body.getElementsByTag("reader-sentinel").remove()
    }
    do {
        let startSentinel = Element(Tag("reader-sentinel"), "")
        try startSentinel.attr("id", "reader-sentinel-0")
        _ = try? body.prependChild(startSentinel)

        let endSentinel = Element(Tag("reader-sentinel"), "")
        try endSentinel.attr("id", "reader-sentinel-1")
        _ = try? body.appendChild(endSentinel)
        return doc
    } catch {
        if ebookTextProcessorDetailedLoggingEnabled {
            print("# VISIBLERANGE sentinelPreprocess.minimal.error \(error)")
        }
        return doc
    }
}

public enum EbookHTMLProcessingContext {
    @TaskLocal public static var isEbookHTML: Bool = false
}

public struct EbookProcessingVariant: Hashable, Sendable {
    public let availableDictionaryIDs: [String]
    public let yomitanResolvedDictionaryID: Int64?
    public let yomitanJMDictGenerationKey: String?
    public let yomitanJMnedictGenerationKey: String?
    public let includeJLPTClasses: Bool
    public let romajiModeEnabled: Bool

    public init(
        availableDictionaryIDs: [String],
        yomitanResolvedDictionaryID: Int64? = nil,
        yomitanJMDictGenerationKey: String? = nil,
        yomitanJMnedictGenerationKey: String? = nil,
        includeJLPTClasses: Bool,
        romajiModeEnabled: Bool
    ) {
        self.availableDictionaryIDs = Array(Set(availableDictionaryIDs)).sorted()
        self.yomitanResolvedDictionaryID = yomitanResolvedDictionaryID
        self.yomitanJMDictGenerationKey = yomitanJMDictGenerationKey
        self.yomitanJMnedictGenerationKey = yomitanJMnedictGenerationKey
        self.includeJLPTClasses = includeJLPTClasses
        self.romajiModeEnabled = romajiModeEnabled
    }

    public static let unspecified = EbookProcessingVariant(
        availableDictionaryIDs: [],
        includeJLPTClasses: false,
        romajiModeEnabled: false
    )
}

public enum EbookProcessingVariantContext {
    @TaskLocal public static var current: EbookProcessingVariant?
}

public typealias EbookProcessingVariantProvider = @Sendable () async -> EbookProcessingVariant

public func withEbookProcessingVariant<Result>(
    _ variant: EbookProcessingVariant?,
    isolation: isolated (any Actor)? = #isolation,
    operation: () async throws -> Result
) async rethrows -> Result {
    _ = isolation
    guard let variant else {
        return try await operation()
    }
    return try await EbookProcessingVariantContext.$current.withValue(
        variant,
        operation: operation
    )
}

public func ebookTextProcessor(
    contentURL: URL,
    sectionLocation: String,
    content: String,
    contentFingerprint: String? = nil,
    isCacheWarmer: Bool,
    processReadabilityContent: EbookReadabilityContentProcessor?,
    processHTMLDocument: EbookHTMLDocumentProcessor?,
    processHTMLBytes: EbookHTMLBytesProcessor?,
    processHTML: EbookHTMLProcessor?
) async throws -> EbookProcessedSectionPayload {
    var sectionLocationComponents = URLComponents(url: contentURL, resolvingAgainstBaseURL: false)
    var sectionLocationQueryItems = sectionLocationComponents?.queryItems ?? []
    sectionLocationQueryItems.removeAll { $0.name == "subpath" }
    sectionLocationQueryItems.append(URLQueryItem(name: "subpath", value: sectionLocation))
    sectionLocationComponents?.queryItems = sectionLocationQueryItems
    let sectionLocationURL = sectionLocationComponents?.url ?? contentURL

    do {
        try Task.checkCancellation()
        var doc: SwiftSoup.Document?

        if let processReadabilityContent {
            doc = try await processReadabilityContent(
                content,
                contentURL,
                sectionLocationURL,
                isCacheWarmer,
                true,
                contentFingerprint,
                { $0 }
            )
            try Task.checkCancellation()
        }

        if doc == nil {
            // TODO: Consolidate our parsing boilerplate
            let isXML = content.hasPrefix("<?xml") || content.hasPrefix("<?XML") // TODO: Case insensitive
            let parser = isXML ? SwiftSoup.Parser.xmlParser() : SwiftSoup.Parser.htmlParser()
            doc = try SwiftSoup.parse(content, sectionLocationURL.absoluteString, parser)
            doc?.outputSettings().prettyPrint(pretty: false).syntax(syntax: isXML ? .xml : .html)
            doc?.outputSettings().charset(.utf8)
            if isXML {
                doc?.outputSettings().escapeMode(.xhtml)
            }
        }

        guard var doc else {
            print("Error: Unexpectedly failed to receive doc")
            return EbookProcessedSectionPayload(
                documentHTML: Data(content.utf8),
                segmentSidecar: Data(),
                isAuthoritativelyProcessed: false
            )
        }

        try processForReaderMode(
            doc: doc,
            url: sectionLocationURL, //nil,
            contentSectionLocationIdentifier: sectionLocation,
            isEBook: true,
            isCacheWarmer: isCacheWarmer,
            defaultTitle: nil,
            imageURL: nil,
            injectEntryImageIntoHeader: false,
            defaultFontSize: 20 // TODO: Pass this in from ReaderViewModel...
        )
        doc = preprocessEbookContent(doc: doc)

        var payload: EbookProcessedSectionPayload
        if let processHTMLDocument {
            let processed = try await EbookHTMLProcessingContext.$isEbookHTML.withValue(true) {
                try await processHTMLDocument(doc, isCacheWarmer)
            }
            try Task.checkCancellation()
            payload = EbookProcessedSectionPayload(
                documentHTML: Data(processed.documentHTML),
                segmentSidecar: processed.canonicalSegmentSidecar ?? Data()
            )
        } else {
            var htmlBytes = try doc.outerHtmlUTF8FromCurrentTreeSplicingBody()
            if let processHTMLBytes {
                htmlBytes = await EbookHTMLProcessingContext.$isEbookHTML.withValue(true) {
                    await processHTMLBytes(
                        htmlBytes,
                        isCacheWarmer
                    )
                }
                try Task.checkCancellation()
            }
            payload = splitCanonicalReaderSegmentSidecar(from: htmlBytes)
                ?? EbookProcessedSectionPayload(
                    documentHTML: Data(htmlBytes),
                    segmentSidecar: Data()
                )
        }

        if let processHTML {
            let html = await EbookHTMLProcessingContext.$isEbookHTML.withValue(true) {
                await processHTML(
                    String(decoding: payload.documentHTML, as: UTF8.self),
                    isCacheWarmer
                )
            }
            try Task.checkCancellation()
            payload = EbookProcessedSectionPayload(
                documentHTML: Data(html.utf8),
                segmentSidecar: payload.segmentSidecar,
                isAuthoritativelyProcessed: payload.isAuthoritativelyProcessed
            )
        }

        if ebookTextProcessorDetailedLoggingEnabled {
            let htmlBytes = Array(payload.documentHTML)
            print(
                "# EPUB",
                "ebookTextProcessor.output",
                "contentURL=\(contentURL.absoluteString)",
                "sectionLocation=\(sectionLocation)",
                "isCacheWarmer=\(isCacheWarmer)",
                "segmentCount=\(bytePatternCount(ebookTextProcessorSegmentOpenTagBytes, in: htmlBytes))",
                "sentenceCount=\(bytePatternCount(ebookTextProcessorSentenceOpenTagBytes, in: htmlBytes))"
            )
        }

        try Task.checkCancellation()
        return payload
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        if Task.isCancelled {
            throw CancellationError()
        }
        if ebookTextProcessorDetailedLoggingEnabled {
            debugPrint("Error processing readability content for ebook", error)
        }
    }
    return EbookProcessedSectionPayload(
        documentHTML: Data(content.utf8),
        segmentSidecar: Data(),
        isAuthoritativelyProcessed: false
    )
}

private func bytePatternCount(_ needle: [UInt8], in haystack: [UInt8]) -> Int {
    guard !needle.isEmpty, haystack.count >= needle.count else { return 0 }
    var count = 0
    var index = 0
    while index <= haystack.count - needle.count {
        var matched = true
        for offset in needle.indices where haystack[index + offset] != needle[offset] {
            matched = false
            break
        }
        if matched {
            count += 1
            index += needle.count
        } else {
            index += 1
        }
    }
    return count
}
