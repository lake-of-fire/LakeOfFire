import Foundation
import LakeOfFireWeb
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireContent
import LakeOfFireCore
import SwiftSoup

private let ebookTextProcessorReplaceTextDetailedLoggingEnabled =
    ProcessInfo.processInfo.environment["MANABI_REPLACETEXT_DETAILED_LOGS"] == "1"

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
        _ = try? body.getElementsByTag("reader-sentinel").remove()
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
    contentFingerprint: String?,
    isCacheWarmer: Bool,
    processReadabilityContent: ((String, URL, URL?, Bool, Bool, String?, ((SwiftSoup.Document) async -> SwiftSoup.Document)) async throws -> SwiftSoup.Document)?,
    processHTMLDocument: EbookHTMLDocumentProcessor?,
    processHTMLBytes: (([UInt8], Bool) async -> [UInt8])?,
    processHTML: ((String, Bool) async -> String)?
) async throws -> EbookProcessedSectionPayload {
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
            return EbookProcessedSectionPayload(
                documentHTML: Data(content.utf8),
                segmentSidecar: Data()
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
            let processedPayload: EbookProcessedSectionPayload = try await EbookHTMLProcessingContext.$isEbookHTML.withValue(true) {
                try await processHTMLDocument(doc, isCacheWarmer)
            }
            payload = processedPayload
        } else {
            var htmlBytes = try doc.outerHtmlUTF8FromCurrentTreeSplicingBody()
            if let processHTMLBytes {
                htmlBytes = await EbookHTMLProcessingContext.$isEbookHTML.withValue(true) {
                    await processHTMLBytes(
                        htmlBytes,
                        isCacheWarmer
                    )
                }
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
            payload = EbookProcessedSectionPayload(
                documentHTML: Data(html.utf8),
                segmentSidecar: payload.segmentSidecar
            )
        }

        return payload
    } catch {
        if ebookTextProcessorReplaceTextDetailedLoggingEnabled {
            debugPrint("Error processing readability content for ebook", error)
        }
    }
    return EbookProcessedSectionPayload(
        documentHTML: Data(content.utf8),
        segmentSidecar: Data()
    )
}
