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
    processReadabilityContent: ((SwiftSoup.Document) async -> String)?
) async throws -> String {
    let sectionLocationURL = contentURL.appending(queryItems: [.init(name: "subpath", value: sectionLocation)])
    
    do {
        let doc = try processForReaderMode(
            content: content,
            url: sectionLocationURL, //nil,
            contentSectionLocationIdentifier: sectionLocation,
            isEBook: true,
            defaultTitle: nil,
            imageURL: nil,
            injectEntryImageIntoHeader: false,
            defaultFontSize: 18 // TODO: Pass this in from ReaderViewModel...
        )
        doc.outputSettings().charset(.utf8).escapeMode(.xhtml)
        let html: String
        if let processReadabilityContent {
            html = await processReadabilityContent(doc)
        } else {
            html = try doc.outerHtml()
        }
        return html
    } catch {
        debugPrint("Error processing readability content for ebook", error)
    }
    return content
}
