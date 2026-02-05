import Foundation
import SwiftSoup
import LRUCache
import LakeKit
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent

private let defaultRubyFontCSSStack = "'Hiragino Kaku Gothic ProN', 'Hiragino Sans', system-ui'"

private func ensureRubyFontCustomProperty(in doc: SwiftSoup.Document) {
    do {
        if let head = doc.head() {
            let styleID = "manabi-ruby-font-vars"
            if try head.getElementById(styleID) == nil {
                let css = ":root{--manabi-ruby-font:\(defaultRubyFontCSSStack);}"
                try head.append("<style type=\"text/css\" id=\"\(styleID)\">\(css)</style>")
            }
        }
    } catch {
        print("Failed to append ruby font style: \(error)")
    }
}

// Precomputed punctuation set for splitting
private let splitPunctuation = ParsingStrings([
    "、","。","．","，","？","！","：","；","…","‥","ー","－",
    "「","」","『","』","【","】","〔","〕","（","）","［","］",
    "｛","｝","〈","〉","《","》","“","”","‘","’","·","・","／",
    "＼","—","〜","～","〃","々","〆","ゝ","ゞ"
])

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
        let utf8view = text.utf8
        let len = utf8view.count
        guard desiredOffset > 0 && desiredOffset < len else {
            return desiredOffset
        }
        // Access a byte in the UTF-8 view by index
        func byte(at offset: Int) -> UInt8 {
            return utf8view[utf8view.index(utf8view.startIndex, offsetBy: offset)]
        }
        var bestOffset = desiredOffset
        var bestScore = Int.min
        for dist in 0...maxDistance {
            for offset in [desiredOffset - dist, desiredOffset + dist] {
                if offset <= 0 || offset >= len { continue }
                let curr = byte(at: offset)
                let prev = byte(at: offset - 1)
                var score = 0
                // Prefer splitting at ASCII whitespace
                if curr == 0x20 || curr == 0x09 || curr == 0x0A || curr == 0x0C || curr == 0x0D ||
                    prev == 0x20 || prev == 0x09 || prev == 0x0A || prev == 0x0C || prev == 0x0D {
                    score += 3
                }
                // Treat punctuation via precomputed splitPunctuation set
                if splitPunctuation.contains(curr) || splitPunctuation.contains(prev) {
                    score += 3
                }
                // Avoid splitting in the middle of ASCII alphanumeric words
                if ((curr >= 0x30 && curr <= 0x39) || (curr >= 0x41 && curr <= 0x5A) || (curr >= 0x61 && curr <= 0x7A)) &&
                    ((prev >= 0x30 && prev <= 0x39) || (prev >= 0x41 && prev <= 0x5A) || (prev >= 0x61 && prev <= 0x7A)) {
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
        var textNodes = body.textNodes()
        var nodeIdx = 0
        while nodeIdx < textNodes.count {
            var node = textNodes[nodeIdx]
            var offsetInNode = 0
            
            let nodeTextPreview = String(node.text().prefix(30))
            // Attempt to insert as many sentinels as needed inside this node
            while charCount + (node.text().count - offsetInNode) >= nextThreshold {
                let nodeText = node.text()
                let desiredOffset = nextThreshold - charCount - offsetInNode
                let splitOffset = findSplitOffset(
                    nodeText,
                    desiredOffset: desiredOffset,
                    maxDistance: interval * 2
                )
                let splitIndex = offsetInNode + splitOffset
                // Sanity check
                if splitIndex <= 0 || splitIndex >= nodeText.count { break }
                
                // Split the text node
                let newTextNode = try? node.splitText(splitIndex)
                
                // Insert sentinel between the two halves
                let sentinel = Element(Tag("reader-sentinel"), "")
                try sentinel.attr("id", "reader-sentinel-\(idx)")
                idx += 1
                _ = try? node.after(sentinel)
                
                if let newTextNode = newTextNode {
                    _ = try? sentinel.after(newTextNode)
                    // Debug new node
                    let newPreview = String(newTextNode.text().prefix(30))
                    // Re-fetch text nodes to include the split part
                    textNodes = body.textNodes()
                    // Advance counters for next threshold
                    charCount = nextThreshold
                    nextThreshold += interval
                    // Reset offset and stay on the new node
                    node = newTextNode
                    offsetInNode = 0
                    continue  // re‑enter inner while with updated node
                } else {
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
        return doc
    } catch {
        print(error)
        return doc
    }
}

public enum EbookHTMLProcessingContext {
    @TaskLocal public static var isEbookHTML: Bool = false
}

@ReaderViewModelActor
internal func ebookTextProcessor(
    contentURL: URL,
    sectionLocation: String,
    content: String,
    isCacheWarmer: Bool,
    processReadabilityContent: ((String, URL, URL?, Bool, ((SwiftSoup.Document) async -> SwiftSoup.Document)) async -> SwiftSoup.Document)?,
    processHTML: ((String, Bool) async -> String)?
) async throws -> String {
    //    print("# ebookTextProcessor", isCacheWarmer, contentURL, sectionLocation)
    let sectionLocationURL = contentURL.appending(queryItems: [.init(name: "subpath", value: sectionLocation)])
    
    do {
        var doc: SwiftSoup.Document?

        if let processReadabilityContent {
            doc = await processReadabilityContent(
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

        ensureRubyFontCustomProperty(in: doc)

        var html = try doc.outerHtml()

        if let processHTML {
            html = await EbookHTMLProcessingContext.$isEbookHTML.withValue(true) {
                await processHTML(
                    html,
                    isCacheWarmer
                )
            }
        }

        return html
    } catch {
        debugPrint("Error processing readability content for ebook", error)
    }
    return content
}
