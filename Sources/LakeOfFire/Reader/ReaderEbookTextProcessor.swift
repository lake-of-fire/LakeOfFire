import Foundation
import SwiftUtilities
import LRUCache

fileprivate struct EbookProcessorCacheKey: Hashable {
    let contentHash: UInt64
    
    init(content: String) {
        contentHash = stableHash(content)
    }
}
fileprivate let ebookProcessorCache = LRUCache<EbookProcessorCacheKey, String>(totalCostLimit: 30_000_000)

internal extension Reader {
    func ebookTextProcessor(content: String) async throws -> String {
        print("!! ebookt ext proc \(content.prefix(50))")
        let cacheKey = EbookProcessorCacheKey(content: content)
        if let cached = ebookProcessorCache.value(forKey: cacheKey) {
            return cached
        }
        
        do {
            let doc = try processForReaderMode(content: content, url: nil, isEBook: true, defaultTitle: nil, imageURL: nil, injectEntryImageIntoHeader: false, fontSize: readerFontSize ?? defaultFontSize)
            doc.outputSettings().charset(.utf8).escapeMode(.xhtml)
            if let processReadabilityContent = readerViewModel.processReadabilityContent {
                return await processReadabilityContent(doc)
            } else {
                let html = try doc.outerHtml()
                ebookProcessorCache.setValue(html, forKey: cacheKey, cost: html.utf8.count)
                return html
            }
        } catch {
            print("Error processing readability content")
        }
        return content
    }
}
