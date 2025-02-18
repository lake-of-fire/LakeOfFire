import Foundation
import SwiftSoup
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
    let bytes = ArraySlice(html.utf8)
    let prefixBytes = UTF8Arrays.blobColon
    let prefixBytesCount = prefixBytes.count
    let quote1: UInt8 = 0x22 // '
    let quote2: UInt8 = 0x27 // "
    let bytesCount = bytes.count
    var blobUrls: [String] = []
    var i = 0
    while i < bytesCount {
        // Skip continuation bytes
        if (bytes[i] & 0b11000000) == 0b10000000 {
            i += 1
            continue
        }
        
        // Determine length of current UTF-8 character
        let charLen = bytes[i] < 0x80 ? 1 : bytes[i] < 0xE0 ? 2 : bytes[i] < 0xF0 ? 3 : 4
        
        // Check for prefix match
        if i + prefixBytesCount <= bytesCount {
            var match = true
            for k in 0..<prefixBytesCount {
                if bytes[i + k] != prefixBytes[k] {
                    match = false
                    break
                }
            }
            if match {
                let urlStart = i + prefixBytesCount
                var j = urlStart
                while j < bytesCount {
                    // Ensure we're at a character boundary
                    if bytes[j] & 0b11000000 == 0b10000000 {
                        j += 1
                        continue
                    }
                    if bytes[j] == 0x22 || bytes[j] == 0x27 { break } // " or '
                    j += bytes[j] < 0x80 ? 1 : bytes[j] < 0xE0 ? 2 : bytes[j] < 0xF0 ? 3 : 4
                }
                blobUrls.append(String(decoding: bytes[urlStart..<j], as: UTF8.self))
                i = j
                continue
            }
        }
        i += charLen
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

fileprivate let readerFontSizeStylePattern = #"(?i)(<body[^>]*\bstyle="[^"]*)font-size:\s*[\d.]+px"#
fileprivate let readerFontSizeStyleRegex = try! NSRegularExpression(pattern: readerFontSizeStylePattern, options: .caseInsensitive)

fileprivate let bodyStylePattern = #"(?i)(<body[^>]*\bstyle=")([^"]*)(")"#
fileprivate let bodyStyleRegex = try! NSRegularExpression(pattern: bodyStylePattern, options: .caseInsensitive)

fileprivate func rewriteManabiReaderFontSizeStyle(in html: String, newFontSize: Double) -> String {
    let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
    let nsHTML = html as NSString
    // If a font-size exists in the style, replace it.
    if let firstMatch = readerFontSizeStyleRegex.firstMatch(in: html, options: [], range: nsRange) {
        let replacement = readerFontSizeStyleRegex.replacementString(
            for: firstMatch,
            in: html,
            offset: 0,
            template: "$1font-size: \(newFontSize)px"
        )
        return nsHTML.replacingCharacters(in: firstMatch.range, with: replacement)
    }
    // Otherwise, if a <body ... style="..."> exists, insert the font-size.
    if let styleMatch = bodyStyleRegex.firstMatch(in: html, options: [], range: nsRange) {
        let prefix = nsHTML.substring(with: styleMatch.range(at: 1))
        let content = nsHTML.substring(with: styleMatch.range(at: 2))
        let suffix = nsHTML.substring(with: styleMatch.range(at: 3))
        let newContent = "font-size: \(newFontSize)px; " + content
        let replacement = prefix + newContent + suffix
        return nsHTML.replacingCharacters(in: styleMatch.range, with: replacement)
    }
    return html
}

internal func ebookTextProcessor(contentURL: URL, sectionLocation: String, content: String, processReadabilityContent: ((SwiftSoup.Document) async -> String)?) async throws -> String {
    let readerFontSize = (UserDefaults.standard.object(forKey: "readerFontSize") as? Double) ?? 16
    let lightModeTheme = (UserDefaults.standard.object(forKey: "lightModeTheme") as? LightModeTheme) ?? .white
    let darkModeTheme = (UserDefaults.standard.object(forKey: "darkModeTheme") as? DarkModeTheme) ?? .black

    let cacheKey = EbookProcessorCacheKey(contentURL: contentURL, sectionLocation: sectionLocation)
    if let cached = ebookProcessorCache.value(forKey: cacheKey) {
        let blobs = extractBlobUrls(from: content)
        var updatedCache = replaceBlobUrls(in: cached, with: blobs)
        // TODO: Also overwrite the theme here
        updatedCache = rewriteManabiReaderFontSizeStyle(
            in: updatedCache,
            newFontSize: readerFontSize
        )
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
            fontSize: readerFontSize,
            lightModeTheme: lightModeTheme,
            darkModeTheme: darkModeTheme
        )
        doc.outputSettings().charset(.utf8).escapeMode(.xhtml)
        let html: String
        if let processReadabilityContent {
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
