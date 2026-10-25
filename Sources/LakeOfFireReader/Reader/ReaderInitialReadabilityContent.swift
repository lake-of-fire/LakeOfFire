import Foundation
import SwiftSoup

/// Exclude inert HTML fragments before extraction can copy their descendants
/// into live content. Keep the full document so metadata and base URLs survive.
internal func readerInitialReadabilityInput(_ html: String, contentURL: URL) -> String? {
    // XML permits a namespace prefix before template, so this inexpensive
    // admission check must not require the literal HTML opening tag.
    guard html.range(of: "<template", options: .caseInsensitive) != nil
            || html.range(of: ":template", options: .caseInsensitive) != nil else {
        return html
    }

    do {
        let document = try SwiftSoup.parse(html, contentURL.absoluteString)
        guard ReaderDocumentTree.containsInertHTMLTemplate(in: document) else {
            return html
        }
        guard let input = try ReaderDocumentTree.copyExcludingInertHTMLTemplates(document) as? Document else {
            return nil
        }
        input.outputSettings().prettyPrint(pretty: false)
        return try input.outerHtml()
    } catch {
        // Nil enters the caller's existing extraction-failure path. Passing the
        // original source here would allow a producer to promote draft content.
        return nil
    }
}

/// Initial SwiftReadability output is HTML. Remove whole inert template trees
/// before canonical construction; metadata values have a separate text policy.
internal func readerInitialReadabilityContent(_ html: String) -> String? {
    guard html.range(of: "<template", options: .caseInsensitive) != nil else {
        return html
    }

    do {
        let document = try SwiftSoup.parseBodyFragment(html)
        guard let body = ReaderDocumentTree.firstElement(named: "body", in: document) else {
            return nil
        }
        // Foreign template elements, comments, and attribute values do not
        // require a rewrite. Retain their original serialization in that case.
        guard ReaderDocumentTree.containsInertHTMLTemplate(in: body) else {
            return html
        }
        guard let content = try ReaderDocumentTree.copyExcludingInertHTMLTemplates(body) else {
            return nil
        }
        // Attach the pruned copy so serialization uses this HTML document's
        // settings rather than a detached node's default formatting.
        try body.replaceWith(content)
        document.outputSettings().prettyPrint(pretty: false)
        return try content.html()
    } catch {
        // The caller returns its existing extraction failure outcome. Returning
        // the original fragment here would bypass the initial template policy.
        return nil
    }
}
