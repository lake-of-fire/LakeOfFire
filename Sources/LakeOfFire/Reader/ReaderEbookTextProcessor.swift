import Foundation
import SwiftSoup
import LRUCache
import LakeKit

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
    // Apply visibility sentinels
    guard let body = doc.body() else { return doc }
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
        var bestOffset = desiredOffset
        var bestScore = Int.min
        for dist in 0...maxDistance {
            for offset in [desiredOffset - dist, desiredOffset + dist] {
                if offset <= 0 || offset >= len { continue }
                let curr = characters[offset]
                let prev = characters[offset - 1]
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
        return bestOffset
    }
    
    do {
        func bodyTextNodesInDocumentOrder() -> [TextNode] {
            (try? body.getAllElements().flatMap { $0.textNodes() }) ?? []
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
        while nodeIdx < textNodes.count {
            var node = textNodes[nodeIdx]
            var offsetInNode = 0

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
    let sectionLocationURL = contentURL.appending(queryItems: [.init(name: "subpath", value: sectionLocation)])
    
    do {
        var doc: SwiftSoup.Document?
        
        if let processReadabilityContent {
            doc = try await processReadabilityContent(
                content,
                contentURL,
                sectionLocationURL,
                isCacheWarmer,
                preprocessEbookContent(doc:)
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
        
        guard let doc else {
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
        
        var htmlBytes = try doc.outerHtmlUTF8()
        print(
            "# EPUB",
            "ebookTextProcessor.output",
            "contentURL=\(contentURL.absoluteString)",
            "sectionLocation=\(sectionLocation)",
            "isCacheWarmer=\(isCacheWarmer)",
            "segmentCount=\(bytePatternCount(Array("<mnb-seg".utf8), in: htmlBytes))",
            "sentenceCount=\(bytePatternCount(Array("<mnb-sen".utf8), in: htmlBytes))"
        )

        if let processHTMLBytes {
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
        debugPrint("Error processing readability content for ebook", error)
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
