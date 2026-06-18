import Foundation
import LakeOfFireWeb
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireContent
import LakeOfFireCore
import SwiftSoup

private let ebookTextProcessorReplaceTextDetailedLoggingEnabled =
    ProcessInfo.processInfo.environment["MANABI_REPLACETEXT_DETAILED_LOGS"] == "1"
private let ebookTextProcessorBypassReaderModeProcessor = false
private let ebookTextProcessorSlowLogThresholdMs = 1000

@inline(__always)
private func ebookProcessorElapsedMilliseconds(since startedAt: Date?) -> Int {
    guard let startedAt else { return 0 }
    return Int(Date().timeIntervalSince(startedAt) * 1000)
}

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
        if ebookTextProcessorReplaceTextDetailedLoggingEnabled {
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
    contentFingerprint: String?,
    isCacheWarmer: Bool,
    processReadabilityContent: ((String, URL, URL?, Bool, Bool, String?, ((SwiftSoup.Document) async -> SwiftSoup.Document)) async throws -> SwiftSoup.Document)?,
    processHTMLBytes: (([UInt8], Bool) async -> [UInt8])?,
    processHTML: ((String, Bool) async -> String)?
) async throws -> String {
    //    print("# ebookTextProcessor", isCacheWarmer, contentURL, sectionLocation)
    let collectTiming = !isCacheWarmer || ebookTextProcessorReplaceTextDetailedLoggingEnabled
    let totalStartedAt = collectTiming ? Date() : nil
    var readabilityProcessElapsedMs = 0
    var fallbackParseElapsedMs = 0
    var readerModeProcessElapsedMs = 0
    var preprocessEbookElapsedMs = 0
    var serializeElapsedMs = 0
    var processHTMLBytesElapsedMs = 0
    var processHTMLElapsedMs = 0
    var responseDecodeElapsedMs = 0
    var sectionLocationComponents = URLComponents(url: contentURL, resolvingAgainstBaseURL: false)
    var sectionLocationQueryItems = sectionLocationComponents?.queryItems ?? []
    sectionLocationQueryItems.removeAll { $0.name == "subpath" }
    sectionLocationQueryItems.append(URLQueryItem(name: "subpath", value: sectionLocation))
    sectionLocationComponents?.queryItems = sectionLocationQueryItems
    let sectionLocationURL = sectionLocationComponents?.url ?? contentURL
    
    do {
        var doc: SwiftSoup.Document?
        
        if let processReadabilityContent, !ebookTextProcessorBypassReaderModeProcessor {
            let readabilityProcessStartedAt = collectTiming ? Date() : nil
            doc = try await processReadabilityContent(
                content,
                contentURL,
                sectionLocationURL,
                isCacheWarmer,
                true,
                contentFingerprint,
                { $0 }
            )
            readabilityProcessElapsedMs = ebookProcessorElapsedMilliseconds(since: readabilityProcessStartedAt)
        } else if ebookTextProcessorBypassReaderModeProcessor {
            if ebookTextProcessorReplaceTextDetailedLoggingEnabled {
            }
        }
        
        if doc == nil {
            let fallbackParseStartedAt = collectTiming ? Date() : nil
            // TODO: Consolidate our parsing boilerplate
            let isXML = content.hasPrefix("<?xml") || content.hasPrefix("<?XML") // TODO: Case insensitive
            let parser = isXML ? SwiftSoup.Parser.xmlParser() : SwiftSoup.Parser.htmlParser()
            doc = try SwiftSoup.parse(content, sectionLocationURL.absoluteString, parser)
            doc?.outputSettings().prettyPrint(pretty: false).syntax(syntax: isXML ? .xml : .html)
            doc?.outputSettings().charset(.utf8)
            if isXML {
                doc?.outputSettings().escapeMode(.xhtml)
            }
            fallbackParseElapsedMs = ebookProcessorElapsedMilliseconds(since: fallbackParseStartedAt)
        }
        
        guard var doc else {
            print("Error: Unexpectedly failed to receive doc")
            return content
        }
        
        let readerModeProcessStartedAt = collectTiming ? Date() : nil
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
        readerModeProcessElapsedMs = ebookProcessorElapsedMilliseconds(since: readerModeProcessStartedAt)
        let preprocessEbookStartedAt = collectTiming ? Date() : nil
        doc = preprocessEbookContent(doc: doc)
        preprocessEbookElapsedMs = ebookProcessorElapsedMilliseconds(since: preprocessEbookStartedAt)
        
        let serializeStartedAt = collectTiming ? Date() : nil
        var htmlBytes = try doc.outerHtmlUTF8()
        serializeElapsedMs = ebookProcessorElapsedMilliseconds(since: serializeStartedAt)
        if ebookTextProcessorReplaceTextDetailedLoggingEnabled {
        }

        if let processHTMLBytes {
            let processHTMLBytesStartedAt = collectTiming ? Date() : nil
            htmlBytes = await EbookHTMLProcessingContext.$isEbookHTML.withValue(true) {
                await processHTMLBytes(
                    htmlBytes,
                    isCacheWarmer
                )
            }
            processHTMLBytesElapsedMs = ebookProcessorElapsedMilliseconds(since: processHTMLBytesStartedAt)
        }

        if let processHTML {
            let processHTMLStartedAt = collectTiming ? Date() : nil
            let html = await EbookHTMLProcessingContext.$isEbookHTML.withValue(true) {
                await processHTML(
                    String(decoding: htmlBytes, as: UTF8.self),
                    isCacheWarmer
                )
            }
            htmlBytes = Array(html.utf8)
            processHTMLElapsedMs = ebookProcessorElapsedMilliseconds(since: processHTMLStartedAt)
        }

        let responseDecodeStartedAt = collectTiming ? Date() : nil
        let response = String(decoding: htmlBytes, as: UTF8.self)
        responseDecodeElapsedMs = ebookProcessorElapsedMilliseconds(since: responseDecodeStartedAt)
        let elapsedMs = ebookProcessorElapsedMilliseconds(since: totalStartedAt)
        if ebookTextProcessorReplaceTextDetailedLoggingEnabled
            || (!isCacheWarmer && elapsedMs >= ebookTextProcessorSlowLogThresholdMs) {
            debugPrint(
                "# READERLOAD stage=ebookTextProcessor.slow",
                "contentURL=\(contentURL.absoluteString)",
                "sectionLocation=\(sectionLocation)",
                "isCacheWarmer=\(isCacheWarmer)",
                "requestBytes=\(content.utf8.count)",
                "responseBytes=\(htmlBytes.count)",
                "elapsedMs=\(elapsedMs)",
                "readabilityProcessElapsedMs=\(readabilityProcessElapsedMs)",
                "fallbackParseElapsedMs=\(fallbackParseElapsedMs)",
                "readerModeProcessElapsedMs=\(readerModeProcessElapsedMs)",
                "preprocessEbookElapsedMs=\(preprocessEbookElapsedMs)",
                "serializeElapsedMs=\(serializeElapsedMs)",
                "processHTMLBytesElapsedMs=\(processHTMLBytesElapsedMs)",
                "processHTMLElapsedMs=\(processHTMLElapsedMs)",
                "responseDecodeElapsedMs=\(responseDecodeElapsedMs)"
            )
        }
        return response
    } catch {
        if ebookTextProcessorReplaceTextDetailedLoggingEnabled {
            debugPrint("Error processing readability content for ebook", error)
        }
    }
    return content
}
