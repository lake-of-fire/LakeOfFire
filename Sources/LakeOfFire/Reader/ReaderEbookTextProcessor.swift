import Foundation
import SwiftSoup
import LRUCache
import LakeKit

public struct EbookProcessorCacheKey: Encodable, Hashable {
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

public let ebookProcessorCache = LRUFileCache<EbookProcessorCacheKey, [UInt8]>(
//public let ebookProcessorCache = LRUCache<EbookProcessorCacheKey, [UInt8]>(
    namespace: "ReaderEbookTextProcessor",
//    totalCostLimit: 30_000_000,
    totalBytesLimit: 30_000_000,
    countLimit: 2_000
)

@inlinable
internal func range(of subArray: ArraySlice<UInt8>, in arraySlice: ArraySlice<UInt8>, startingAt start: ArraySlice<UInt8>.Index) -> Range<ArraySlice<UInt8>.Index>? {
    guard !subArray.isEmpty, start < arraySlice.endIndex else { return nil }
    let subCount = subArray.count
    // Ensure that we iterate within bounds.
    for i in start...(arraySlice.endIndex - subCount) {
        if arraySlice[i..<i+subCount] == subArray {
            return i..<i+subCount
        }
    }
    return nil
}

fileprivate func extractBlobUrls(from bytes: [UInt8]) -> [ArraySlice<UInt8>] {
    let prefixBytes = UTF8Arrays.blobColon
    let prefixBytesCount = prefixBytes.count
    let quote1: UInt8 = 0x22 // "
    let quote2: UInt8 = 0x27 // '
    let bytesCount = bytes.count
    var blobUrls: [ArraySlice<UInt8>] = []
    var i = 0
    
    while i < bytesCount {
        // Skip continuation bytes (i.e. bytes that are not the start of a new UTF-8 scalar)
        if (bytes[i] & 0b11000000) == 0b10000000 {
            i += 1
            continue
        }
        
        // Determine length of current UTF-8 character
        let charLen: Int
        if bytes[i] < 0x80 {
            charLen = 1
        } else if bytes[i] < 0xE0 {
            charLen = 2
        } else if bytes[i] < 0xF0 {
            charLen = 3
        } else {
            charLen = 4
        }
        
        // Check for prefix match.
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
                // Scan until we hit a quote or the end of the bytes.
                while j < bytesCount {
                    // Make sure we are at a character boundary
                    if (bytes[j] & 0b11000000) == 0b10000000 {
                        j += 1
                        continue
                    }
                    // Break if we hit a quote character.
                    if bytes[j] == quote1 || bytes[j] == quote2 {
                        break
                    }
                    // Move j by the character length at this position.
                    let len: Int
                    if bytes[j] < 0x80 {
                        len = 1
                    } else if bytes[j] < 0xE0 {
                        len = 2
                    } else if bytes[j] < 0xF0 {
                        len = 3
                    } else {
                        len = 4
                    }
                    j += len
                }
                blobUrls.append(bytes[urlStart..<j])
                i = j
                continue
            }
        }
        i += charLen
    }
    return blobUrls
}

fileprivate func replaceBlobUrls(in htmlBytes: [UInt8], with blobUrls: [ArraySlice<UInt8>]) -> [UInt8] {
    let extractedBlobUrlSlices = extractBlobUrls(from: htmlBytes)
    
    // Only replace as many as the lesser of the two counts.
    let minCount = min(blobUrls.count, extractedBlobUrlSlices.count)
    
    // Work with an ArraySlice for performance.
    let workingSlice = htmlBytes[htmlBytes.startIndex..<htmlBytes.endIndex]
    var result = [UInt8]()
    var currentIndex = workingSlice.startIndex
    
    // For each replacement, search for the extracted blob URL slice in workingSlice starting from currentIndex.
    for i in 0..<minCount {
        if let rangeFound = range(of: extractedBlobUrlSlices[i], in: workingSlice, startingAt: currentIndex) {
            // Append everything before the found range.
            result.append(contentsOf: workingSlice[currentIndex..<rangeFound.lowerBound])
            // Append the replacement blob URL bytes.
            result.append(contentsOf: blobUrls[i])
            // Move currentIndex past the found blob URL.
            currentIndex = rangeFound.upperBound
        }
    }
    
    // Append the remainder of the bytes if any exists.
    if currentIndex < workingSlice.endIndex {
        result.append(contentsOf: workingSlice[currentIndex..<workingSlice.endIndex])
    }
    
    return result
}

fileprivate let readerFontSizeStylePattern = #"(?i)(<body[^>]*\bstyle="[^"]*)font-size:\s*[\d.]+px"#
fileprivate let readerFontSizeStyleRegex = try! NSRegularExpression(pattern: readerFontSizeStylePattern, options: .caseInsensitive)

fileprivate let bodyStylePattern = #"(?i)(<body[^>]*\bstyle=")([^"]*)(")"#
fileprivate let bodyStyleRegex = try! NSRegularExpression(pattern: bodyStylePattern, options: .caseInsensitive)

fileprivate func rewriteManabiReaderFontSizeStyle(in htmlBytes: [UInt8], newFontSize: Double) -> [UInt8] {
    // Convert the UTF8 bytes to a String.
    guard let html = String(bytes: htmlBytes, encoding: .utf8) else {
        return htmlBytes
    }
    
    let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
    let nsHTML = html as NSString
    var updatedHtml: String
    let newFontSizeStr = "font-size: " + String(newFontSize) + "px"
    // If a font-size exists in the style, replace it.
    if let firstMatch = readerFontSizeStyleRegex.firstMatch(in: html, options: [], range: nsRange) {
        let replacement = readerFontSizeStyleRegex.replacementString(
            for: firstMatch,
            in: html,
            offset: 0,
            template: "$1" + newFontSizeStr
        )
        updatedHtml = nsHTML.replacingCharacters(in: firstMatch.range, with: replacement)
    }
    // Otherwise, if a <body ... style="..."> exists, insert the font-size.
    else if let styleMatch = bodyStyleRegex.firstMatch(in: html, options: [], range: nsRange) {
        let prefix = nsHTML.substring(with: styleMatch.range(at: 1))
        let content = nsHTML.substring(with: styleMatch.range(at: 2))
        let suffix = nsHTML.substring(with: styleMatch.range(at: 3))
        let newContent = newFontSizeStr + "; " + content
        let replacement = prefix + newContent + suffix
        updatedHtml = nsHTML.replacingCharacters(in: styleMatch.range, with: replacement)
    }
    else {
        updatedHtml = html
    }
    
    // Convert the updated HTML string back to UTF8 bytes.
    return Array(updatedHtml.utf8)
}

internal func ebookTextProcessor(contentURL: URL, sectionLocation: String, content: String, processReadabilityContent: ((SwiftSoup.Document) async -> String)?) async throws -> String {
    let readerFontSize = (UserDefaults.standard.object(forKey: "readerFontSize") as? Double) ?? 18
    let lightModeTheme = (UserDefaults.standard.object(forKey: "lightModeTheme") as? LightModeTheme) ?? .white
    let darkModeTheme = (UserDefaults.standard.object(forKey: "darkModeTheme") as? DarkModeTheme) ?? .black
    
    let cacheKey = EbookProcessorCacheKey(contentURL: contentURL, sectionLocation: sectionLocation)
    if let cached = ebookProcessorCache.value(forKey: cacheKey) {
        let blobs = extractBlobUrls(from: content.utf8Array)
        var updatedCache = replaceBlobUrls(in: cached, with: blobs)
        // TODO: Also overwrite the theme here
        updatedCache = rewriteManabiReaderFontSizeStyle(
            in: updatedCache,
            newFontSize: readerFontSize
        )
        return String(decoding: updatedCache, as: UTF8.self)
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
        let value = html.utf8Array
        ebookProcessorCache.setValue(value, forKey: cacheKey)//, cost: value.count)
        return html
    } catch {
        debugPrint("Error processing readability content for ebook", error)
    }
    return content
}
