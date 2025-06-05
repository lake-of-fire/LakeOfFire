import Foundation
import SwiftSoup
import LRUCache
import LakeKit

fileprivate extension URL {
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

internal func ebookTextProcessor(
    contentURL: URL,
    sectionLocation: String,
    content: String,
    isCacheWarmer: Bool,
    processReadabilityContent: ((SwiftSoup.Document, URL, Bool) async -> SwiftSoup.Document)?,
    processHTML: ((String, Bool) async -> String)?
) async throws -> String {
//    print("# ebookTextProcessor", isCacheWarmer, contentURL, sectionLocation)
    let sectionLocationURL = contentURL.appending(queryItems: [.init(name: "subpath", value: sectionLocation)])
    
    do {
        let isXML = content.hasPrefix("<?xml") || content.hasPrefix("<?XML") // TODO: Case insensitive
        let parser = isXML ? SwiftSoup.Parser.xmlParser() : SwiftSoup.Parser.htmlParser()
        var doc = try SwiftSoup.parse(content, sectionLocationURL.absoluteString, parser)
        doc.outputSettings().prettyPrint(pretty: false).syntax(syntax: isXML ? .xml : .html)
        
        if let processReadabilityContent {
            doc = await processReadabilityContent(
                doc,
                contentURL,
                isCacheWarmer
            )
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
            defaultFontSize: 18 // TODO: Pass this in from ReaderViewModel...
        )
        
        doc.outputSettings().charset(.utf8)
        if isXML {
            doc.outputSettings().escapeMode(.xhtml)
        }
        var html = try doc.outerHtml()
        
        if let processHTML {
            html = await processHTML(
                html,
                isCacheWarmer
            )
        }
        
        return html
    } catch {
        debugPrint("Error processing readability content for ebook", error)
    }
    return content
}
