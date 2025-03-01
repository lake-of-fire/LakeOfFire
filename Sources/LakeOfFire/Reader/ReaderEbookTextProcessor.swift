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

public let ebookProcessorCache = LRUFileCache<EbookProcessorCacheKey, [UInt8]>(namespace: "ReaderEbookTextProcessor", totalBytesLimit: 30_000_000, countLimit: 2_000)

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
                // Create a String from the slice and add it.
                blobUrls.append(bytes[urlStart..<j])
                i = j
                continue
            }
        }
        i += charLen
    }
    return blobUrls
}

@inlinable
internal func range(of subArray: ArraySlice<UInt8>, in array: [UInt8], startingAt start: Int) -> Range<Int>? {
    guard !subArray.isEmpty, start < array.count else { return nil }
    
    for i in start...(array.count - subArray.count) {
        if array[i..<i+subArray.count] == subArray[0..<subArray.count] {
            return i..<i+subArray.count
        }
    }
    return nil
}

fileprivate func replaceBlobUrls(in htmlBytes: [UInt8], with blobUrls: [ArraySlice<UInt8>]) -> [UInt8] {
    let extractedBlobUrlStrings = extractBlobUrls(from: htmlBytes)
    
    // Only replace as many as the lesser of the two counts.
    let minCount = min(blobUrls.count, extractedBlobUrlStrings.count)
    
    var newBytes: [UInt8] = []
    var currentIndex = 0
    var workingBytes = htmlBytes
    
    // For each replacement, search for the extracted blob URL bytes in the workingBytes starting from currentIndex.
    for i in 0..<minCount {
        if let rangeFound = range(of: extractedBlobUrlStrings[i], in: workingBytes, startingAt: currentIndex) {
            // Append everything before the found range.
            newBytes.append(contentsOf: workingBytes[currentIndex..<rangeFound.lowerBound])
            // Append the replacement blob URL bytes.
            newBytes.append(contentsOf: blobUrls[i])
            // Move currentIndex past the found blob URL.
            currentIndex = rangeFound.upperBound
        }
    }
    
    // Append the remainder of the bytes if any exists.
    if currentIndex < workingBytes.count {
        newBytes.append(contentsOf: workingBytes[currentIndex...])
    }
    
    return newBytes
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
    let readerFontSize = (UserDefaults.standard.object(forKey: "readerFontSize") as? Double) ?? 16
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
        ebookProcessorCache.setValue(html.utf8Array, forKey: cacheKey)
        return html
    } catch {
        debugPrint("Error processing readability content for ebook", error)
    }
    return content
}
