import Foundation
import LakeKit

public struct EbookProcessorCacheKey: Encodable {
    public let contentURL: URL
    public let sectionLocation: String
    
    public enum CodingKeys: String, CodingKey {
        case contentURL
        case sectionLocation
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contentURL, forKey: .contentURL)
        try container.encode(sectionLocation, forKey: .sectionLocation)
    }
}

public let ebookProcessorCache = LRUFileCache<EbookProcessorCacheKey, String>(namespace: "ReaderEbookTextProcessor", totalBytesLimit: 30_000_000, countLimit: 2_000)

fileprivate func extractBlobUrls(from html: String) -> [String] {
    let prefix = "blob:"
    let quotes: Set<Character> = ["'", "\""]
    
    var blobUrls: [String] = []
//    var index = html.startIndex
//    while let startIndex = html.range(of: "\(prefix)", range: index..<html.endIndex)?.upperBound {
//        let endIndex = html[startIndex...].firstIndex(where: { quotes.contains($0) })
//        if let endIndex = endIndex {
//            blobUrls.append(String(html[startIndex..<endIndex]))
//            index = html.index(after: endIndex)
//        } else {
//            break
//        }
//    }
    
    // TODO: Faster but maybe not working yet?
    var searchRange = html.startIndex..<html.endIndex
    
    while let prefixRange = html.range(of: prefix, options: [], range: searchRange) {
        let startIndex = prefixRange.upperBound
        let endIndex = html[startIndex...].firstIndex(where: { quotes.contains($0) }) ?? html.endIndex
        let blobUrl = String(html[startIndex..<endIndex])
        blobUrls.append(blobUrl)
        
        // Move the search range past the current blob URL
        searchRange = endIndex..<html.endIndex
    }
    
    return blobUrls
}

fileprivate func replaceBlobUrls(in html: String, with blobUrls: [String]) -> String {
    let htmlData = Data(html.utf8)
    let extractedBlobUrls = extractBlobUrls(from: html).map { Data($0.utf8) }
    let replacementBlobUrls = blobUrls.map { Data($0.utf8) }
    let minCount = min(replacementBlobUrls.count, extractedBlobUrls.count)
    
    var newHtmlData = Data()
    var currentIndex = 0
    
    for i in 0..<minCount {
        if let range = htmlData[currentIndex...].range(of: extractedBlobUrls[i]) {
            // Append everything before the found range
            newHtmlData.append(htmlData[currentIndex..<range.lowerBound])
            // Append the replacement URL
            newHtmlData.append(replacementBlobUrls[i])
            // Move the current index past the end of the found range
            currentIndex = range.upperBound
        }
    }
    
    // Append the remainder of the HTML if any exists beyond the last replacement
    if currentIndex < htmlData.count {
        newHtmlData.append(htmlData[currentIndex...])
    }
    
    return String(data: newHtmlData, encoding: .utf8) ?? html
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
            let doc = try processForReaderMode(
                content: content,
                url: nil,
                isEBook: true,
                defaultTitle: nil,
                imageURL: nil,
                injectEntryImageIntoHeader: false,
                fontSize: readerFontSize ?? readerModeViewModel.defaultFontSize ?? 16,
                lightModeTheme: lightModeTheme,
                darkModeTheme: darkModeTheme
            )
            doc.outputSettings().charset(.utf8).escapeMode(.xhtml)
            let html: String
            if let processReadabilityContent = readerModeViewModel.processReadabilityContent {
                html = await processReadabilityContent(doc)
            } else {
                html = try doc.outerHtml()
            }
            ebookProcessorCache.setValue(html, forKey: cacheKey)
            return html
        } catch {
            debugPrint("Error processing readability content for ebook", error)
        }
        return content
    }
}
