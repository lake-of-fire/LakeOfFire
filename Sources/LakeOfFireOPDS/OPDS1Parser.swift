//
//  Copyright 2024 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(FoundationXML)
import FoundationXML
#endif

enum OPDS1ParserError: Error {
    case missingTitle
    case rootNotFound
    case invalidBaseURL
}

enum OPDSParserOpenSearchHelperError: Error {
    case searchLinkNotFound
    case searchDocumentIsInvalid
}

private struct MimeTypeParameters {
    var type: String
    var parameters: [String: String] = [:]
}

enum OPDS1Parser {
    static func parseURL(url: URL, session: URLSession = .shared, completion: @escaping @Sendable (sending ParseData?, Error?) -> Void) {
        OPDSParser.loadDocument(url: url, session: session) { data, response, error in
            guard let data, let response else {
                completion(nil, error ?? OPDSParserError.documentNotFound)
                return
            }

            do {
                completion(try parse(xmlData: data, url: url, response: response), nil)
            } catch {
                completion(nil, error)
            }
        }
    }

    static func parse(xmlData: Data, url: URL, response: URLResponse) throws -> ParseData {
        let builder = OPDS1XMLParser(baseURL: response.url ?? url)
        try builder.parse(data: xmlData)

        var parseData = ParseData(url: url, response: response, version: .OPDS1)
        switch builder.rootKind {
        case .feed:
            parseData.feed = try builder.makeFeed()
        case .entry:
            parseData.publication = try builder.makePublication()
        case .unknown:
            throw OPDS1ParserError.rootNotFound
        }
        return parseData
    }

    static func fetchOpenSearchTemplate(feed: Feed, session: URLSession = .shared, completion: @escaping @Sendable (String?, Error?) -> Void) {
        guard let href = feed.links.first(withRel: .search)?.href else {
            completion(nil, OPDSParserOpenSearchHelperError.searchLinkNotFound)
            return
        }
        let feedBaseURL = feed.links.first(withRel: .self).flatMap { URL(string: $0.href) }
        guard let url = URLHelper.resolve(href: href, base: feedBaseURL)
        else {
            completion(nil, OPDSParserOpenSearchHelperError.searchLinkNotFound)
            return
        }

        // Snapshot caller-owned mutable metadata before crossing the network boundary.
        let selfType = feed.links.first(withRel: .self)?.type
        OPDSParser.loadDocument(url: url, session: session) { data, response, error in
            guard let data else {
                completion(nil, error ?? OPDSParserOpenSearchHelperError.searchDocumentIsInvalid)
                return
            }

            do {
                completion(try parseOpenSearchTemplate(
                    data: data,
                    selfType: selfType,
                    baseURL: response?.url ?? url
                ), nil)
            } catch {
                completion(nil, OPDSParserOpenSearchHelperError.searchDocumentIsInvalid)
            }
        }
    }

    static func parseOpenSearchTemplate(data: Data, selfType: String?, baseURL: URL?) throws -> String {
        let parser = try OpenSearchXMLParser(data: data, baseURL: baseURL)
        guard let template = parser.bestTemplate(for: selfType) else {
            throw OPDSParserOpenSearchHelperError.searchDocumentIsInvalid
        }
        return template
    }

    fileprivate static func parseMimeType(mimeTypeString: String) -> MimeTypeParameters {
        // A parameter value can contain a quoted semicolon. Empty and malformed
        // media types remain nonmatches rather than indexing an empty array.
        var parts = [String]()
        var part = ""
        var quoted = false
        var escaped = false
        for character in mimeTypeString {
            if escaped {
                part.append(character)
                escaped = false
            } else if character == "\\", quoted {
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
            } else if character == ";", !quoted {
                parts.append(part)
                part = ""
            } else {
                part.append(character)
            }
        }
        guard !quoted, !escaped else { return MimeTypeParameters(type: "") }
        parts.append(part)
        let type = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var parameters: [String: String] = [:]
        for part in parts.dropFirst() {
            let halves = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard halves.count == 2 else { continue }
            let key = halves[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            parameters[key] = halves[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return MimeTypeParameters(type: type, parameters: parameters)
    }

}

private final class OPDS1XMLParser: NSObject, XMLParserDelegate {
    enum RootKind {
        case unknown
        case feed
        case entry
    }

    struct LinkRecord {
        var href: String?
        var type: String?
        var title: String?
        var rel: String?
        var facetGroup: String?
    }

    struct EntryRecord {
        var title: String?
        var identifier: String?
        var modified: Date?
        var published: Date?
        var languages: [String] = []
        var subjects: [Subject] = []
        var authors: [Contributor] = []
        var publishers: [Contributor] = []
        var description: String?
        var links: [LinkRecord] = []
    }

    private let baseURL: URL?
    private var parserError: Error?

    var rootKind: RootKind = .unknown
    private enum Role { case feed, entry, author, other }
    private struct Element {
        let name: String
        let namespace: String
        let role: Role
        let baseURL: URL?
        var text = ""
    }
    private var stack: [Element] = []
    private var legacyNamespaceLessDocument = false
    private var namespaceBindings: [String: [String]] = [:]
    private static let atomNamespace = "http://www.w3.org/2005/Atom"
    private static let dcNamespaces: Set<String> = [
        "http://purl.org/dc/elements/1.1/", "http://purl.org/dc/terms/",
    ]
    private static let searchNamespaces: Set<String> = [
        "http://a9.com/-/spec/opensearch/1.1/",
        "http://a9.com/-/spec/opensearch/1.0/",
        "http://a9.com/-/spec/opensearchrss/1.0/",
    ]

    private var feedTitle: String?
    private var feedUpdated: Date?
    private var feedTotalResults: Int?
    private var feedItemsPerPage: Int?
    private var feedLinks: [LinkRecord] = []
    private var entryRecords: [EntryRecord] = []
    private var currentEntry: EntryRecord?
    private var currentAuthorName: String?
    private var currentAuthorURI: String?

    init(baseURL: URL?) {
        self.baseURL = baseURL
    }

    func parse(data: Data) throws {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.delegate = self
        let succeeded = parser.parse()
        if let parserError { throw parserError }
        guard succeeded else {
            throw parser.parserError ?? OPDS1ParserError.rootNotFound
        }
    }

    func makeFeed() throws -> Feed {
        guard let feedTitle else {
            throw OPDS1ParserError.missingTitle
        }

        let feed = Feed(title: feedTitle)
        feed.metadata.modified = feedUpdated
        feed.metadata.numberOfItem = feedTotalResults
        feed.metadata.itemsPerPage = feedItemsPerPage

        for rootLink in feedLinks {
            guard let link = makeLink(from: rootLink) else {
                continue
            }
            if link.rels.contains(LinkRelation.opdsFacet), let facetGroup = rootLink.facetGroup {
                addFacet(feed: feed, link: link, title: facetGroup)
            } else {
                feed.links.append(link)
            }
        }

        for entry in entryRecords {
            guard let publication = makePublication(from: entry) else {
                continue
            }

            let collectionLink = entry.links
                .first { record in
                    let rel = record.rel?.lowercased()
                    return rel == LinkRelation.collection.string || rel == "http://opds-spec.org/group"
                }
                .flatMap(makeLink(from:))

            let isNavigation = !entry.links.contains {
                $0.rel.map { LinkRelation($0).isOPDSAcquisition } == true
            }
            if isNavigation, let navigation = makeNavigationLink(from: entry) {
                if let collectionLink {
                    addNavigation(in: feed, link: navigation, collectionLink: collectionLink)
                } else {
                    feed.navigation.append(navigation)
                }
            } else if let collectionLink {
                addPublication(in: feed, publication: publication, collectionLink: collectionLink)
            } else {
                feed.publications.append(publication)
            }
        }

        return feed
    }

    func makePublication() throws -> Publication? {
        guard let entry = currentEntry ?? entryRecords.first else {
            return nil
        }
        return makePublication(from: entry)
    }

    private func makePublication(from entry: EntryRecord) -> Publication? {
        guard let title = entry.title else {
            return nil
        }

        let metadata = Metadata(
            identifier: entry.identifier,
            title: title,
            modified: entry.modified,
            published: entry.published,
            languages: Array(Set(entry.languages)).sorted(),
            subjects: entry.subjects,
            authors: entry.authors,
            publishers: entry.publishers,
            description: entry.description
        )

        var links: [Link] = []
        var images: [Link] = []
        for record in entry.links {
            guard let link = makeLink(from: record) else {
                continue
            }
            if link.rels.contains(LinkRelation.collection) || link.rels.contains("http://opds-spec.org/group") {
                continue
            }
            if link.rels.contains(LinkRelation.cover) || link.rels.contains(where: \.isImage) {
                images.append(link)
            } else {
                links.append(link)
            }
        }

        return Publication(metadata: metadata, links: links, images: images)
    }

    private func makeNavigationLink(from entry: EntryRecord) -> Link? {
        let candidates = entry.links.compactMap(makeLink(from:)).filter { link in
            let isAuxiliary = link.rels.contains { relation in
                relation.isImage || relation == .cover || relation == .collection
                    || relation == "http://opds-spec.org/group"
                    || relation == .self || relation == .search
            }
            let mediaType = OPDS1Parser.parseMimeType(mimeTypeString: link.type ?? "").type
            return !isAuxiliary && !mediaType.hasPrefix("image/")
        }
        // Prefer a catalog representation, not whichever artwork/HTML link the
        // publisher happened to serialize first. Keep other-resource navigation.
        let catalog = candidates.first { link in
            let type = OPDS1Parser.parseMimeType(mimeTypeString: link.type ?? "").type
            return type == "application/atom+xml" || type == "application/opds+json"
        }
        guard let link = catalog ?? candidates.first else { return nil }
        return Link(href: link.href, type: link.type, title: entry.title, rels: link.rels)
    }

    private func makeLink(from record: LinkRecord) -> Link? {
        // Hrefs were resolved in their lexical XML scope while parsing.
        guard let href = record.href else { return nil }
        return Link(href: href, type: record.type, title: record.title,
                    rel: record.rel.map { LinkRelation($0) })
    }

    private func addFacet(feed: Feed, link: Link, title: String) {
        if let facet = feed.facets.first(where: { $0.metadata.title == title }) {
            facet.links.append(link)
            return
        }
        let facet = Facet(title: title)
        facet.links.append(link)
        feed.facets.append(facet)
    }

    private func addPublication(in feed: Feed, publication: Publication, collectionLink: Link) {
        if let group = feed.groups.first(where: { $0.links.contains(where: { $0.href == collectionLink.href }) }) {
            group.publications.append(publication)
            return
        }
        guard let title = collectionLink.title else {
            feed.publications.append(publication)
            return
        }
        let group = Group(title: title)
        group.links.append(Link(href: collectionLink.href, title: collectionLink.title, rel: .self))
        group.publications.append(publication)
        feed.groups.append(group)
    }

    private func addNavigation(in feed: Feed, link: Link, collectionLink: Link) {
        if let group = feed.groups.first(where: { $0.links.contains(where: { $0.href == collectionLink.href }) }) {
            group.navigation.append(link)
            return
        }
        guard let title = collectionLink.title else {
            feed.navigation.append(link)
            return
        }
        let group = Group(title: title)
        group.links.append(Link(href: collectionLink.href, title: collectionLink.title, rel: .self))
        group.navigation.append(link)
        feed.groups.append(group)
    }

    private func isAtom(_ namespace: String) -> Bool {
        namespace == Self.atomNamespace || (legacyNamespaceLessDocument && namespace.isEmpty)
    }

    private func attribute(_ name: String, namespace: String, in attributes: [String: String]) -> String? {
        for (key, value) in attributes {
            let parts = key.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[1] == name,
               namespaceBindings[String(parts[0])]?.last == namespace {
                return value
            }
        }
        return nil
    }

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        namespaceBindings[prefix, default: []].append(namespaceURI)
    }

    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
        _ = namespaceBindings[prefix]?.popLast()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let namespace = namespaceURI ?? ""
        let parent = stack.last
        if stack.isEmpty {
            legacyNamespaceLessDocument = namespace.isEmpty
            guard isAtom(namespace), elementName == "feed" || elementName == "entry" else {
                parserError = OPDS1ParserError.rootNotFound
                parser.abortParsing()
                return
            }
            rootKind = elementName == "feed" ? .feed : .entry
        }

        let inheritedBase = parent?.baseURL ?? baseURL
        let effectiveBase: URL?
        if let declaredBase = attributeDict["xml:base"] {
            guard let resolved = URLHelper.resolve(href: declaredBase, base: inheritedBase) else {
                parserError = OPDS1ParserError.invalidBaseURL
                parser.abortParsing()
                return
            }
            effectiveBase = resolved
        } else {
            effectiveBase = inheritedBase
        }

        let role: Role
        if isAtom(namespace), stack.isEmpty, elementName == "feed" {
            role = .feed
        } else if isAtom(namespace), elementName == "entry",
                  stack.isEmpty || parent?.role == .feed {
            role = .entry
            currentEntry = EntryRecord()
        } else if isAtom(namespace), elementName == "author", parent?.role == .entry {
            role = .author
            currentAuthorName = nil
            currentAuthorURI = nil
        } else {
            role = .other
        }
        stack.append(Element(name: elementName, namespace: namespace, role: role, baseURL: effectiveBase))

        guard isAtom(namespace) else { return }
        if elementName == "link", parent?.role == .entry || parent?.role == .feed {
            let record = LinkRecord(
                href: URLHelper.getAbsolute(href: attributeDict["href"], base: effectiveBase),
                type: attributeDict["type"], title: attributeDict["title"], rel: attributeDict["rel"],
                facetGroup: attribute("facetGroup", namespace: "http://opds-spec.org/2010/catalog", in: attributeDict)
                    ?? attributeDict["facetGroup"]
            )
            if parent?.role == .entry { currentEntry?.links.append(record) }
            else { feedLinks.append(record) }
        } else if elementName == "category", parent?.role == .entry,
                  let label = attributeDict["label"] ?? attributeDict["term"] {
            currentEntry?.subjects.append(Subject(name: label, scheme: attributeDict["scheme"], code: attributeDict["term"]))
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else { return }
        self.parser(parser, foundCharacters: text)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard let element = stack.popLast() else { return }
        let parent = stack.last
        let text = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let atom = isAtom(element.namespace)
        let dc = Self.dcNamespaces.contains(element.namespace)
            || (legacyNamespaceLessDocument && element.namespace.isEmpty)

        if parent?.role == .entry {
            switch element.name {
            case "title" where atom:
                currentEntry?.title = text.nilIfEmpty
            case "updated" where atom:
                currentEntry?.modified = text.dateFromISO8601
            case "id" where atom:
                currentEntry?.identifier = text.nilIfEmpty
            case "identifier" where dc:
                if currentEntry?.identifier == nil { currentEntry?.identifier = text.nilIfEmpty }
            case "published" where atom, "issued" where dc:
                currentEntry?.published = text.dateFromISO8601
            case "summary" where atom, "content" where atom:
                if currentEntry?.description == nil { currentEntry?.description = text.nilIfEmpty }
            case "language" where dc:
                if let value = text.nilIfEmpty { currentEntry?.languages.append(value) }
            case "publisher" where dc:
                if let value = text.nilIfEmpty { currentEntry?.publishers.append(Contributor(name: value)) }
            default:
                break
            }
        } else if parent?.role == .author, atom {
            if element.name == "name" { currentAuthorName = text.nilIfEmpty }
            if element.name == "uri" {
                currentAuthorURI = text.nilIfEmpty.flatMap {
                    URLHelper.getAbsolute(href: $0, base: element.baseURL)
                }
            }
        } else if parent?.role == .feed {
            if atom, element.name == "title" { feedTitle = text.nilIfEmpty }
            if atom, element.name == "updated" { feedUpdated = text.dateFromISO8601 }
            let search = Self.searchNamespaces.contains(element.namespace)
                || (legacyNamespaceLessDocument && element.namespace.isEmpty)
            if search {
                switch element.name {
                case "totalResults", "TotalResults": feedTotalResults = Int(text)
                case "itemsPerPage", "ItemsPerPage": feedItemsPerPage = Int(text)
                default: break
                }
            }
        }

        if element.role == .author {
            if let name = currentAuthorName {
                currentEntry?.authors.append(Contributor(name: name, identifier: currentAuthorURI))
            }
            currentAuthorName = nil
            currentAuthorURI = nil
        } else if element.role == .entry, let currentEntry {
            entryRecords.append(currentEntry)
            self.currentEntry = nil
        }

        if !stack.isEmpty { stack[stack.count - 1].text += element.text }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if parserError == nil { parserError = parseError }
    }
}

private final class OpenSearchXMLParser: NSObject, XMLParserDelegate {
    private struct URLRecord {
        let type: String
        let template: String
    }

    private struct Element {
        let baseURL: URL?
    }
    private var urls: [URLRecord] = []
    private var stack: [Element] = []
    private let documentURL: URL?
    private var documentNamespace = ""
    private var parserError: Error?

    init(data: Data, baseURL: URL?) throws {
        documentURL = baseURL
        super.init()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        let succeeded = parser.parse()
        if let parserError { throw parserError }
        guard succeeded else {
            throw parser.parserError ?? OPDSParserOpenSearchHelperError.searchDocumentIsInvalid
        }
    }

    func bestTemplate(for selfType: String?) -> String? {
        guard let selfType else { return urls.first?.template }
        let selfMime = OPDS1Parser.parseMimeType(mimeTypeString: selfType)
        var typeMatch: URLRecord?
        for url in urls {
            let other = OPDS1Parser.parseMimeType(mimeTypeString: url.type)
            guard !selfMime.type.isEmpty, selfMime.type == other.type else { continue }
            if typeMatch == nil { typeMatch = url }
            if selfMime.parameters["profile"] == other.parameters["profile"] {
                return url.template
            }
        }
        return typeMatch?.template ?? urls.first?.template
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let namespace = namespaceURI ?? ""
        if stack.isEmpty {
            guard elementName == "OpenSearchDescription",
                  namespace.isEmpty || namespace == "http://a9.com/-/spec/opensearch/1.1/"
                    || namespace == "http://a9.com/-/spec/opensearch/1.0/" else {
                parserError = OPDSParserOpenSearchHelperError.searchDocumentIsInvalid
                parser.abortParsing()
                return
            }
            documentNamespace = namespace
        }
        let inheritedBase = stack.last?.baseURL ?? documentURL
        let effectiveBase: URL?
        if let declared = attributeDict["xml:base"] {
            guard let resolved = URLHelper.resolve(href: declared, base: inheritedBase) else {
                parserError = OPDSParserOpenSearchHelperError.searchDocumentIsInvalid
                parser.abortParsing()
                return
            }
            effectiveBase = resolved
        } else {
            effectiveBase = inheritedBase
        }
        let isDirectChild = stack.count == 1
        stack.append(Element(baseURL: effectiveBase))
        guard isDirectChild, namespace == documentNamespace, elementName == "Url",
              let type = attributeDict["type"],
              !OPDS1Parser.parseMimeType(mimeTypeString: type).type.isEmpty,
              let template = attributeDict["template"] else { return }
        if let resolved = URLHelper.resolveTemplate(template, base: effectiveBase) {
            urls.append(URLRecord(type: type, template: resolved))
        } else if effectiveBase == nil {
            urls.append(URLRecord(type: type, template: template))
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if parserError == nil { parserError = parseError }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}