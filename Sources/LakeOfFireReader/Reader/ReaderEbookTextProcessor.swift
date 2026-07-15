import Foundation
import SwiftSoup

private let ebookTextProcessorDetailedLoggingEnabled =
    ProcessInfo.processInfo.environment["MANABI_REPLACETEXT_DETAILED_LOGS"] == "1"
private let ebookTextProcessorSegmentOpenTagBytes = Array("<mnb-seg".utf8)
private let ebookTextProcessorSentenceOpenTagBytes = Array("<mnb-sen".utf8)

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
) async throws -> String {
    var sectionLocationComponents = URLComponents(url: contentURL, resolvingAgainstBaseURL: false)
    var sectionLocationQueryItems = sectionLocationComponents?.queryItems ?? []
    sectionLocationQueryItems.removeAll { $0.name == "subpath" }
    sectionLocationQueryItems.append(URLQueryItem(name: "subpath", value: sectionLocation))
    sectionLocationComponents?.queryItems = sectionLocationQueryItems
    let sectionLocationURL = sectionLocationComponents?.url ?? contentURL

    do {
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
            return content
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

        let usedDocumentPostprocessor = processHTMLDocument != nil
        var htmlBytes: [UInt8]
        if let processHTMLDocument {
            let payload = try await EbookHTMLProcessingContext.$isEbookHTML.withValue(true) {
                try await processHTMLDocument(doc, isCacheWarmer)
            }
            if let canonicalSegmentSidecar = payload.canonicalSegmentSidecar {
                htmlBytes = externalizingReaderSegmentSidecar(
                    documentHTML: payload.documentHTML,
                    canonicalSidecar: canonicalSegmentSidecar,
                    scheme: .ebook
                ).documentHTML.map { $0 }
            } else {
                htmlBytes = payload.documentHTML
            }
        } else {
            htmlBytes = try doc.outerHtmlUTF8FromCurrentTreeSplicingBody()
        }
        if ebookTextProcessorDetailedLoggingEnabled {
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

        if !usedDocumentPostprocessor, let processHTMLBytes {
            htmlBytes = await EbookHTMLProcessingContext.$isEbookHTML.withValue(true) {
                await processHTMLBytes(
                    htmlBytes,
                    isCacheWarmer
                )
            }
        }

        if let processHTML {
            let html = await EbookHTMLProcessingContext.$isEbookHTML.withValue(true) {
                await processHTML(
                    String(decoding: htmlBytes, as: UTF8.self),
                    isCacheWarmer
                )
            }
            htmlBytes = Array(html.utf8)
        }

        return String(decoding: htmlBytes, as: UTF8.self)
    } catch {
        if ebookTextProcessorDetailedLoggingEnabled {
            debugPrint("Error processing readability content for ebook", error)
        }
    }
    return content
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
