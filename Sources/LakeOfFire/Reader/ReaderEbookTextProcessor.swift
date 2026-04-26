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

private let apr20SpacingProbeCharacters: Set<Character> = ["「", "」", "。", "．"]

private func apr20Visible(_ text: String) -> String {
    text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
}

private func apr20CharacterDescription(_ character: Character?) -> String {
    guard let character else { return "<nil>" }
    let scalarDescription = character.unicodeScalars
        .map { String(format: "U+%04X", $0.value) }
        .joined(separator: "+")
    return "\(apr20Visible(String(character)))(\(scalarDescription))"
}

private func apr20ContainsSpacingProbe(_ text: String) -> Bool {
    text.contains { apr20SpacingProbeCharacters.contains($0) }
}

private func apr20IsASCIILetterOrNumber(_ character: Character) -> Bool {
    character.unicodeScalars.allSatisfy {
        $0.isASCII && CharacterSet.alphanumerics.contains($0)
    }
}

private func apr20SpacingContexts(_ text: String, limit: Int = 8) -> String {
    let characters = Array(text)
    let matches = characters.enumerated().filter { apr20SpacingProbeCharacters.contains($0.element) }
    guard !matches.isEmpty else { return "<none>" }
    return matches.prefix(limit).map { index, character in
        let start = max(0, index - 4)
        let end = min(characters.count, index + 5)
        let window = String(characters[start..<end])
        let previousCharacter = index > 0 ? characters[index - 1] : nil
        let nextCharacter = index + 1 < characters.count ? characters[index + 1] : nil
        return [
            "idx=\(index)",
            "char=\(apr20CharacterDescription(character))",
            "prev=\(apr20CharacterDescription(previousCharacter))",
            "next=\(apr20CharacterDescription(nextCharacter))",
            "window=\(apr20Visible(window))"
        ].joined(separator: "|")
    }.joined(separator: ";")
}

private func apr20Snippet(_ text: String, limit: Int = 240) -> String {
    apr20Visible(String(text.prefix(limit)))
}

private func apr20Payload(_ text: String, limit: Int = 1600) -> String {
    let visible = apr20Visible(text)
    if visible.count <= limit {
        return visible
    }
    return String(visible.prefix(limit)) + "...<truncated>"
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
                if apr20IsASCIILetterOrNumber(curr) && apr20IsASCIILetterOrNumber(prev) {
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

            if apr20ContainsSpacingProbe(node.text()) {
                print(
                    "# APR20",
                    "ebook.preprocess.node",
                    "nodeIndex=\(nodeIdx)",
                    "charCount=\(node.text().count)",
                    "utf8Count=\(node.text().utf8.count)",
                    "text=\(apr20Snippet(node.text()))",
                    "contexts=\(apr20SpacingContexts(node.text()))"
                )
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

                if apr20ContainsSpacingProbe(nodeText) {
                    let characters = Array(nodeText)
                    let safeSplitIndex = min(max(splitIndex, 0), characters.count)
                    let beforeText = String(characters.prefix(safeSplitIndex))
                    let afterText = String(characters.suffix(characters.count - safeSplitIndex))
                    let splitPreviousCharacter = safeSplitIndex > 0 ? characters[safeSplitIndex - 1] : nil
                    let splitNextCharacter = safeSplitIndex < characters.count ? characters[safeSplitIndex] : nil
                    print(
                        "# APR20",
                        "ebook.preprocess.split",
                        "nodeIndex=\(nodeIdx)",
                        "charCount=\(nodeText.count)",
                        "utf8Count=\(nodeText.utf8.count)",
                        "desiredOffset=\(desiredOffset)",
                        "splitOffset=\(splitOffset)",
                        "splitIndex=\(splitIndex)",
                        "splitPrev=\(apr20CharacterDescription(splitPreviousCharacter))",
                        "splitNext=\(apr20CharacterDescription(splitNextCharacter))",
                        "before=\(apr20Snippet(beforeText, limit: 120))",
                        "after=\(apr20Snippet(afterText, limit: 120))",
                        "nodeText=\(apr20Payload(nodeText))",
                        "contexts=\(apr20SpacingContexts(nodeText))"
                    )
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
        if let bodyHtml = try? body.html(), apr20ContainsSpacingProbe(bodyHtml) {
            print(
                "# APR20",
                "ebook.preprocess.output",
                "sentinelCount=\(idx == 0 ? 1 : idx)",
                "html=\(apr20Snippet(bodyHtml))",
                "contexts=\(apr20SpacingContexts(bodyHtml))"
            )
        }
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
    processHTML: ((String, Bool) async -> String)?
) async throws -> String {
    //    print("# ebookTextProcessor", isCacheWarmer, contentURL, sectionLocation)
    let sectionLocationURL = contentURL.appending(queryItems: [.init(name: "subpath", value: sectionLocation)])
    
    do {
        if apr20ContainsSpacingProbe(content) {
            print(
                "# APR20",
                "ebook.input",
                "contentURL=\(contentURL.absoluteString)",
                "sectionLocation=\(sectionLocation)",
                "charCount=\(content.count)",
                "utf8Count=\(content.utf8.count)",
                "content=\(apr20Payload(content))",
                "contexts=\(apr20SpacingContexts(content))"
            )
        }
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
        
        var html = try doc.outerHtml()
        if apr20ContainsSpacingProbe(html) {
            print(
                "# APR20",
                "ebook.output.beforeProcessHTML",
                "contentURL=\(contentURL.absoluteString)",
                "sectionLocation=\(sectionLocation)",
                "charCount=\(html.count)",
                "utf8Count=\(html.utf8.count)",
                "html=\(apr20Payload(html))",
                "contexts=\(apr20SpacingContexts(html))"
            )
        }
        print(
            "# EPUB",
            "ebookTextProcessor.output",
            "contentURL=\(contentURL.absoluteString)",
            "sectionLocation=\(sectionLocation)",
            "isCacheWarmer=\(isCacheWarmer)",
            "segmentCount=\(html.components(separatedBy: "<manabi-segment").count - 1)",
            "sentenceCount=\(html.components(separatedBy: "<manabi-sentence").count - 1)"
        )
        
        if let processHTML {
            html = await EbookHTMLProcessingContext.$isEbookHTML.withValue(true) {
                await processHTML(
                    html,
                    isCacheWarmer
                )
            }
        }

        if apr20ContainsSpacingProbe(html) {
            print(
                "# APR20",
                "ebook.output.final",
                "contentURL=\(contentURL.absoluteString)",
                "sectionLocation=\(sectionLocation)",
                "charCount=\(html.count)",
                "utf8Count=\(html.utf8.count)",
                "html=\(apr20Payload(html))",
                "contexts=\(apr20SpacingContexts(html))"
            )
        }
        
        return html
    } catch {
        debugPrint("Error processing readability content for ebook", error)
    }
    return content
}
