import Foundation
import LRUCache

fileprivate struct EbookProcessorCacheKey: Hashable {
    let contentURL: URL
    let sectionLocation: String
}
fileprivate let ebookProcessorCache = LRUCache<EbookProcessorCacheKey, String>(totalCostLimit: 30_000_000)

fileprivate func extractBlobUrls(from html: String) -> [String] {
    let prefix = "blob:"
    let quotes: Set<Character> = ["'", "\""]
    
    var blobUrls: [String] = []
    var index = html.startIndex
    
    while let startIndex = html.range(of: "\(prefix)", range: index..<html.endIndex)?.upperBound {
        let endIndex = html[startIndex...].firstIndex(where: { quotes.contains($0) })
        if let endIndex = endIndex {
            blobUrls.append(String(html[startIndex..<endIndex]))
            index = html.index(after: endIndex)
        } else {
            break
        }
    }
    
    return blobUrls
}

fileprivate func replaceBlobUrls(in html: String, with blobUrls: [String]) -> String {
    var updatedHtml = html
    let extractedBlobUrls = extractBlobUrls(from: html)
    let minCount = min(blobUrls.count, extractedBlobUrls.count)
    
    var currentIndex = html.startIndex
    
    for i in 0..<minCount {
        if let range = updatedHtml.range(of: extractedBlobUrls[i], range: currentIndex ..< updatedHtml.endIndex) {
            updatedHtml.replaceSubrange(range, with: blobUrls[i])
            currentIndex = range.upperBound
        }
    }
    
    return updatedHtml
}

internal extension Reader {
    func ebookTextProcessor(contentURL: URL, sectionLocation: String, content: String) async throws -> String {
        let cacheKey = EbookProcessorCacheKey(contentURL: contentURL, sectionLocation: sectionLocation)
        if let cached = ebookProcessorCache.value(forKey: cacheKey) {
            let blobs = extractBlobUrls(from: content)
            let updatedCache = replaceBlobUrls(in: cached, with: blobs)
            return updatedCache
        }
        
        do {
            let doc = try processForReaderMode(content: content, url: nil, isEBook: true, defaultTitle: nil, imageURL: nil, injectEntryImageIntoHeader: false, fontSize: readerFontSize ?? defaultFontSize)
            doc.outputSettings().charset(.utf8).escapeMode(.xhtml)
            let html: String
            if let processReadabilityContent = readerViewModel.processReadabilityContent {
                html = await processReadabilityContent(doc)
            } else {
                html = try doc.outerHtml()
            }
            ebookProcessorCache.setValue(html, forKey: cacheKey, cost: html.utf8.count)
            return html
        } catch {
            print("Error processing readability content")
        }
        return content
    }
}
