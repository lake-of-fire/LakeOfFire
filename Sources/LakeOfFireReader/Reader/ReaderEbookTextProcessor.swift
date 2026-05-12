import Foundation
import LakeOfFireWeb
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireContent
import LakeOfFireCore
import SwiftSoup
import LRUCache
import LakeKit
import JapaneseLanguageTools

private let ebookTextProcessorReplaceTextDetailedLoggingEnabled =
    ProcessInfo.processInfo.environment["MANABI_REPLACETEXT_DETAILED_LOGS"] == "1"
private let ebookTextProcessorUseMinimalSentinels = true
private let ebookTextProcessorBypassReaderModeProcessor = true

// Precomputed punctuation set for splitting
private let splitPunctuation = ParsingStrings([
    "、","。","．","，","？","！","：","；","…","‥","ー","－",
    "「","」","『","』","【","】","〔","〕","（","）","［","］",
    "｛","｝","〈","〉","《","》","“","”","‘","’","·","・","／",
    "＼","—","〜","～","〃","々","〆","ゝ","ゞ"
])

private func isASCIILetterOrNumber(_ character: Character) -> Bool {
    character.unicodeScalars.allSatisfy {
        $0.isASCII && CharacterSet.alphanumerics.contains($0)
    }
}

private func isJapaneseWordCharacter(_ character: Character) -> Bool {
    let text = String(character)
    return text.isKana || text.isKanji || text == "々" || text == "〻"
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
    try? body.getElementsByTag("reader-sentinel").remove()
    if ebookTextProcessorUseMinimalSentinels {
        do {
            let startSentinel = Element(Tag("reader-sentinel"), "")
            try startSentinel.attr("id", "reader-sentinel-0")
            _ = try? body.prependChild(startSentinel)

            let endSentinel = Element(Tag("reader-sentinel"), "")
            try endSentinel.attr("id", "reader-sentinel-1")
            _ = try? body.appendChild(endSentinel)
            print(
                "# VISIBLERANGE",
                "sentinelPreprocess.minimal",
                "sentinelCount=2"
            )
        } catch {
            print("# VISIBLERANGE sentinelPreprocess.minimal.error \(error)")
        }
        return doc
    }
    let interval = 16
    var charCount = 0
    var nextThreshold = interval
    var idx = 0
    
    func findSplitOffset(_ text: String, desiredOffset: Int, maxDistance: Int) -> Int {
        let characters = Array(text)
        let len = characters.count
        guard desiredOffset > 0 && desiredOffset < len else {
            return desiredOffset
        }
        var bestOffset: Int?
        var bestScore = Int.min
        for dist in 0...maxDistance {
            for offset in [desiredOffset - dist, desiredOffset + dist] {
                if offset <= 0 || offset >= len { continue }
                let curr = characters[offset]
                let prev = characters[offset - 1]
                if isJapaneseWordCharacter(curr) && isJapaneseWordCharacter(prev) {
                    continue
                }
                var score = 0
                // Prefer splitting at ASCII whitespace
                if curr.isWhitespace || prev.isWhitespace {
                    score += 3
                }
                // Treat punctuation via precomputed splitPunctuation set
                if splitPunctuation.contains(Array(String(curr).utf8)) || splitPunctuation.contains(Array(String(prev).utf8)) {
                    score += 3
                }
                // Avoid splitting in the middle of ASCII alphanumeric words
                if isASCIILetterOrNumber(curr) && isASCIILetterOrNumber(prev) {
                    score -= 4
                }
                // Avoid splitting at very start or end
                if offset == 0 || offset == len {
                    score -= 5
                }
                // Distance penalty
                score -= abs(offset - desiredOffset) / 2
                if score > bestScore {
                    bestScore = score
                    bestOffset = offset
                }
                if bestScore >= 3 { break }
            }
            if bestScore >= 3 { break }
        }
        return bestOffset ?? 0
    }
    
    do {
        func closestAncestor(from node: Node, where predicate: (Element) -> Bool) -> Element? {
            var current = node.parent()
            while let ancestor = current {
                if let element = ancestor as? Element, predicate(element) {
                    return element
                }
                current = ancestor.parent()
            }
            return nil
        }

        func hasAncestorTag(_ tagNames: Set<String>, from node: Node) -> Bool {
            closestAncestor(from: node) { tagNames.contains($0.tagNameNormal()) } != nil
        }

        func sentinelAnchor(for node: Node) -> Element? {
            closestAncestor(from: node) { $0.tagNameNormal() == "mnb-seg" }
        }

        func sentinelAnchorKey(for anchor: Element) -> String {
            if let id = try? anchor.attr("id"), !id.isEmpty {
                return "id:\(id)"
            }
            if let selector = try? anchor.cssSelector(), !selector.isEmpty {
                return "selector:\(selector)"
            }
            return "html:\((try? anchor.outerHtml()) ?? "")"
        }

        let ignoredTextAncestorTags: Set<String> = ["reader-sentinel", "script", "style", "rt", "rp"]
        func bodyTextNodesInDocumentOrder() -> [TextNode] {
            ((try? body.getAllElements().flatMap { $0.textNodes() }) ?? [])
                .filter { !hasAncestorTag(ignoredTextAncestorTags, from: $0) }
        }

        var textNodes = bodyTextNodesInDocumentOrder()
        let initialTextNodeCount = textNodes.count
        let initialTextCharacterCount = textNodes.reduce(0) { $0 + $1.text().count }
        var splitAttemptCount = 0
        var splitRejectedCount = 0
        var splitFailedCount = 0
        print(
            "# VISIBLERANGE",
            "sentinelPreprocess.start",
            "textNodeCount=\(initialTextNodeCount)",
            "textCharacterCount=\(initialTextCharacterCount)",
            "interval=\(interval)"
        )
        var nodeIdx = 0
        var anchoredSentinelKeys = Set<String>()
        while nodeIdx < textNodes.count {
            var node = textNodes[nodeIdx]
            var offsetInNode = 0
            if let anchor = sentinelAnchor(for: node) {
                let nodeTextLength = node.text().count
                let anchorKey = sentinelAnchorKey(for: anchor)
                while charCount + nodeTextLength >= nextThreshold {
                    if !anchoredSentinelKeys.contains(anchorKey) {
                        let sentinel = Element(Tag("reader-sentinel"), "")
                        try sentinel.attr("id", "reader-sentinel-\(idx)")
                        idx += 1
                        _ = try? anchor.after(sentinel)
                        anchoredSentinelKeys.insert(anchorKey)
                    } else {
                        splitRejectedCount += 1
                    }
                    nextThreshold += interval
                }
                charCount += nodeTextLength
                nodeIdx += 1
                continue
            }

            // Attempt to insert as many sentinels as needed inside this node
            while charCount + (node.text().count - offsetInNode) >= nextThreshold {
                let nodeText = node.text()
                let desiredOffset = nextThreshold - charCount
                let splitOffset = findSplitOffset(
                    nodeText,
                    desiredOffset: desiredOffset,
                    maxDistance: interval * 2
                )
                let splitIndex = splitOffset
                splitAttemptCount += 1
                // Sanity check
                if splitIndex <= 0 {
                    splitRejectedCount += 1
                    nextThreshold += interval
                    continue
                }
                if splitIndex >= nodeText.count {
                    let sentinel = Element(Tag("reader-sentinel"), "")
                    try sentinel.attr("id", "reader-sentinel-\(idx)")
                    idx += 1
                    _ = try? node.after(sentinel)
                    charCount = nextThreshold
                    nextThreshold += interval
                    offsetInNode = nodeText.count
                    break
                }

                // Split the text node
                let newTextNode = try? node.splitText(splitIndex)
                
                // Insert sentinel between the two halves
                let sentinel = Element(Tag("reader-sentinel"), "")
                try sentinel.attr("id", "reader-sentinel-\(idx)")
                idx += 1
                _ = try? node.after(sentinel)
                
                if let newTextNode = newTextNode {
                    _ = try? sentinel.after(newTextNode)
                    // Re-fetch text nodes to include the split part
                    textNodes = bodyTextNodesInDocumentOrder()
                    // Advance counters for next threshold
                    charCount = nextThreshold
                    nextThreshold += interval
                    // Reset offset and stay on the new node
                    node = newTextNode
                    offsetInNode = 0
                    continue  // re‑enter inner while with updated node
                } else {
                    splitFailedCount += 1
                    break
                }
            }
            
            // No more splits needed in this node; account for its remaining characters
            charCount += node.text().count - offsetInNode
            nodeIdx += 1
        }
        
        if idx == 0 {
            let sentinel = Element(Tag("reader-sentinel"), "")
            try sentinel.attr("id", "reader-sentinel-0")
            _ = try? body.prependChild(sentinel)
        }
        print(
            "# VISIBLERANGE",
            "sentinelPreprocess.end",
            "initialTextNodeCount=\(initialTextNodeCount)",
            "initialTextCharacterCount=\(initialTextCharacterCount)",
            "sentinelCount=\(idx == 0 ? 1 : idx)",
            "usedFallbackSentinel=\(idx == 0)",
            "splitAttemptCount=\(splitAttemptCount)",
            "splitRejectedCount=\(splitRejectedCount)",
            "splitFailedCount=\(splitFailedCount)"
        )
        return doc
    } catch {
        print(error)
        return doc
    }
}

public enum EbookHTMLProcessingContext {
    @TaskLocal public static var isEbookHTML: Bool = false
}

internal func ebookTextProcessor(
    contentURL: URL,
    sectionLocation: String,
    content: String,
    isCacheWarmer: Bool,
    processReadabilityContent: ((String, URL, URL?, Bool, ((SwiftSoup.Document) async -> SwiftSoup.Document)) async throws -> SwiftSoup.Document)?,
    processHTMLBytes: (([UInt8], Bool) async -> [UInt8])?,
    processHTML: ((String, Bool) async -> String)?
) async throws -> String {
    //    print("# ebookTextProcessor", isCacheWarmer, contentURL, sectionLocation)
    let totalStartedAt = Date()
    var readabilityProcessElapsedMs = 0
    var fallbackParseElapsedMs = 0
    var readerModeProcessElapsedMs = 0
    var preprocessEbookElapsedMs = 0
    var serializeElapsedMs = 0
    var processHTMLBytesElapsedMs = 0
    var processHTMLElapsedMs = 0
    var responseDecodeElapsedMs = 0
    let sectionLocationURL = contentURL.appending(queryItems: [.init(name: "subpath", value: sectionLocation)])
    
    do {
        var doc: SwiftSoup.Document?
        
        if let processReadabilityContent, !ebookTextProcessorBypassReaderModeProcessor {
            let readabilityProcessStartedAt = Date()
            doc = try await processReadabilityContent(
                content,
                contentURL,
                sectionLocationURL,
                isCacheWarmer,
                { $0 }
            )
            readabilityProcessElapsedMs = Int(Date().timeIntervalSince(readabilityProcessStartedAt) * 1000)
        } else if ebookTextProcessorBypassReaderModeProcessor {
            print(
                "# EPUB",
                "ebookTextProcessor.readerModeProcessor.bypass",
                "contentURL=\(contentURL.absoluteString)",
                "sectionLocation=\(sectionLocation)",
                "isCacheWarmer=\(isCacheWarmer)"
            )
        }
        
        if doc == nil {
            let fallbackParseStartedAt = Date()
            // TODO: Consolidate our parsing boilerplate
            let isXML = content.hasPrefix("<?xml") || content.hasPrefix("<?XML") // TODO: Case insensitive
            let parser = isXML ? SwiftSoup.Parser.xmlParser() : SwiftSoup.Parser.htmlParser()
            doc = try SwiftSoup.parse(content, sectionLocationURL.absoluteString, parser)
            doc?.outputSettings().prettyPrint(pretty: false).syntax(syntax: isXML ? .xml : .html)
            doc?.outputSettings().charset(.utf8)
            if isXML {
                doc?.outputSettings().escapeMode(.xhtml)
            }
            fallbackParseElapsedMs = Int(Date().timeIntervalSince(fallbackParseStartedAt) * 1000)
        }
        
        guard var doc else {
            print("Error: Unexpectedly failed to receive doc")
            return content
        }
        
        let readerModeProcessStartedAt = Date()
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
        readerModeProcessElapsedMs = Int(Date().timeIntervalSince(readerModeProcessStartedAt) * 1000)
        let preprocessEbookStartedAt = Date()
        doc = preprocessEbookContent(doc: doc)
        preprocessEbookElapsedMs = Int(Date().timeIntervalSince(preprocessEbookStartedAt) * 1000)
        
        let serializeStartedAt = Date()
        var htmlBytes = try doc.outerHtmlUTF8()
        serializeElapsedMs = Int(Date().timeIntervalSince(serializeStartedAt) * 1000)
        if ebookTextProcessorReplaceTextDetailedLoggingEnabled {
            print(
                "# EPUB",
                "ebookTextProcessor.output",
                "contentURL=\(contentURL.absoluteString)",
                "sectionLocation=\(sectionLocation)",
                "isCacheWarmer=\(isCacheWarmer)"
            )
        }

        if let processHTMLBytes {
            let processHTMLBytesStartedAt = Date()
            htmlBytes = await EbookHTMLProcessingContext.$isEbookHTML.withValue(true) {
                await processHTMLBytes(
                    htmlBytes,
                    isCacheWarmer
                )
            }
            processHTMLBytesElapsedMs = Int(Date().timeIntervalSince(processHTMLBytesStartedAt) * 1000)
        }

        if let processHTML {
            let processHTMLStartedAt = Date()
            let html = await EbookHTMLProcessingContext.$isEbookHTML.withValue(true) {
                await processHTML(
                    String(decoding: htmlBytes, as: UTF8.self),
                    isCacheWarmer
                )
            }
            htmlBytes = Array(html.utf8)
            processHTMLElapsedMs = Int(Date().timeIntervalSince(processHTMLStartedAt) * 1000)
        }

        let responseDecodeStartedAt = Date()
        let response = String(decoding: htmlBytes, as: UTF8.self)
        responseDecodeElapsedMs = Int(Date().timeIntervalSince(responseDecodeStartedAt) * 1000)
        let elapsedMs = Int(Date().timeIntervalSince(totalStartedAt) * 1000)
        if ebookTextProcessorReplaceTextDetailedLoggingEnabled || elapsedMs >= 1_000 {
            debugPrint(
                "# REPLACETEXT",
                "native.ebookTextProcessor.responseSummary",
                [
                    "contentURL": String(contentURL.absoluteString.prefix(80)),
                    "sectionLocation": sectionLocation,
                    "isCacheWarmer": isCacheWarmer,
                    "inputBytes": content.utf8.count,
                    "responseBytes": htmlBytes.count,
                    "readabilityProcessMs": readabilityProcessElapsedMs,
                    "fallbackParseMs": fallbackParseElapsedMs,
                    "readerModeProcessMs": readerModeProcessElapsedMs,
                    "preprocessEbookMs": preprocessEbookElapsedMs,
                    "serializeMs": serializeElapsedMs,
                    "processHTMLBytesMs": processHTMLBytesElapsedMs,
                    "processHTMLMs": processHTMLElapsedMs,
                    "responseDecodeMs": responseDecodeElapsedMs,
                    "elapsedMs": elapsedMs
                ] as [String: Any]
            )
        }
        return response
    } catch {
        debugPrint("Error processing readability content for ebook", error)
    }
    return content
}
