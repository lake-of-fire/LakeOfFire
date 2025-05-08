import Foundation
import SwiftSoup
import LRUCache
import LakeKit

internal func ebookTextProcessor(
    contentURL: URL,
    sectionLocation: String,
    content: String,
    processReadabilityContent: ((SwiftSoup.Document) async -> String)?
) async throws -> String {
    do {
        let doc = try processForReaderMode(
            content: content,
            url: contentURL, //nil,
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
