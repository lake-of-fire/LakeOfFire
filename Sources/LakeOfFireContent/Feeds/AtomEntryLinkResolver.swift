import Foundation
import FeedKit

/// FeedKit 9.1.2 retains href attributes verbatim and discards xml:base.
/// Match its direct entry/link order while retaining the XML base at each link.
enum AtomEntryLinkResolver {
    static func resolve(_ entries: [AtomFeedEntry], in data: Data, documentURL: URL) throws {
        let delegate = BaseParser(documentURL: documentURL)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let parsed = parser.parse()
        try Task.checkCancellation()
        guard parsed, delegate.entryLinks.count == entries.count,
              zip(delegate.entryLinks, entries).allSatisfy({
                  $0.0.count == ($0.1.links?.count ?? 0)
              }) else {
            throw FeedError.parserFailed
        }
        // Validate correspondence for the whole document before changing any
        // parsed model. A source/extension link must never shift another entry.
        for (hrefs, entry) in zip(delegate.entryLinks, entries) {
            for (href, link) in zip(hrefs, entry.links ?? []) {
                link.attributes?.href = href
            }
        }
    }

    private static func reference(_ raw: String, relativeTo base: URL?) -> URL? {
        let reference = URL(string: raw)
            ?? raw.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
                .flatMap(URL.init(string:))
        guard let reference else { return nil }
        if reference.scheme != nil { return reference }
        guard let base else { return nil }
        return URL(string: reference.absoluteString, relativeTo: base)?.absoluteURL
    }

    private final class BaseParser: NSObject, XMLParserDelegate {
        let documentURL: URL
        private var path: [String] = []
        private var bases: [URL?] = []
        private(set) var entryLinks: [[String?]] = []

        init(documentURL: URL) {
            self.documentURL = documentURL
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            if Task.isCancelled {
                parser.abortParsing()
                return
            }
            let parentBase: URL? = bases.isEmpty ? documentURL : bases[bases.count - 1]
            // An invalid base removes authority to resolve relative references.
            // A later absolute xml:base or href can establish its own authority.
            let base: URL?
            if let rawBase = attributeDict["xml:base"] {
                base = AtomEntryLinkResolver.reference(rawBase, relativeTo: parentBase)
            } else {
                base = parentBase
            }
            bases.append(base)
            path.append(elementName)
            if path == ["feed", "entry"] {
                entryLinks.append([])
            } else if path == ["feed", "entry", "link"] {
                let href = attributeDict["href"].flatMap {
                    AtomEntryLinkResolver.reference($0, relativeTo: base)?.absoluteString
                }
                entryLinks[entryLinks.count - 1].append(href)
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            path.removeLast()
            bases.removeLast()
        }
    }
}

