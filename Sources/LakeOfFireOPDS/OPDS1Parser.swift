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
    static func parseURL(url: URL, completion: @escaping (ParseData?, Error?) -> Void) {
        URLSession.shared.dataTask(with: url) { data, response, error in
            guard let data, let response else {
                completion(nil, error ?? OPDSParserError.documentNotFound)
                return
            }

            do {
                completion(try parse(xmlData: data, url: url, response: response), nil)
            } catch {
                completion(nil, error)
            }
        }.resume()
    }

    static func parse(xmlData: Data, url: URL, response: URLResponse) throws -> ParseData {
        let builder = OPDS1XMLParser(baseURL: url)
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

    static func fetchOpenSearchTemplate(feed: Feed, completion: @escaping (String?, Error?) -> Void) {
        guard let href = feed.links.first(withRel: .search)?.href,
              let url = URL(string: href)
        else {
            completion(nil, OPDSParserOpenSearchHelperError.searchLinkNotFound)
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, error in
            guard let data else {
                completion(nil, error ?? OPDSParserOpenSearchHelperError.searchDocumentIsInvalid)
                return
            }

            do {
                let parser = try OpenSearchXMLParser(data: data)
                let template = parser.bestTemplate(
                    for: feed.links.first(withRel: .self)?.type,
                    relativeTo: url
                )
                guard let template else {
                    completion(nil, OPDSParserOpenSearchHelperError.searchDocumentIsInvalid)
                    return
                }
                completion(template, nil)
            } catch {
                completion(nil, OPDSParserOpenSearchHelperError.searchDocumentIsInvalid)
            }
        }.resume()
    }

    fileprivate static func parseMimeType(mimeTypeString: String) -> MimeTypeParameters {
        let parts = mimeTypeString.split(separator: ";")
        let type = String(parts[0]).trimmingCharacters(in: .whitespaces)
        var parameters: [String: String] = [:]
        for part in parts.dropFirst() {
            let halves = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard halves.count == 2 else {
                continue
            }
            parameters[halves[0].trimmingCharacters(in: .whitespaces)] = halves[1].trimmingCharacters(in: .whitespaces)
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
    private var stack: [String] = []
    private var textBuffer = ""

    private var feedTitle: String?
    private var feedUpdated: Date?
    private var feedTotalResults: Int?
    private var feedItemsPerPage: Int?
    private var feedLinks: [LinkRecord] = []
    private var entryRecords: [EntryRecord] = []
    private var currentEntry: EntryRecord?
    private var currentAuthorName: String?
    private var currentAuthorURI: String?
    private var currentCategoryAttributes: [String: String]?

    init(baseURL: URL?) {
        self.baseURL = baseURL
    }

    func parse(data: Data) throws {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        guard parser.parse() else {
            throw parser.parserError ?? OPDS1ParserError.rootNotFound
        }
        if let parserError {
            throw parserError
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

            let isNavigation = !entry.links.contains { ($0.rel?.lowercased() ?? "").contains(LinkRelation.opdsAcquisition.string) }
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
            if link.rels.contains(LinkRelation.cover) || link.rels.contains(LinkRelation.opdsImage) || link.rels.contains(LinkRelation.opdsImageThumbnail) {
                images.append(link)
            } else {
                links.append(link)
            }
        }

        return Publication(metadata: metadata, links: links, images: images)
    }

    private func makeNavigationLink(from entry: EntryRecord) -> Link? {
        guard let record = entry.links.first,
              let href = URLHelper.getAbsolute(href: record.href, base: baseURL)
        else {
            return nil
        }
        return Link(
            href: href,
            type: record.type,
            title: entry.title,
            rel: record.rel.map { LinkRelation($0) }
        )
    }

    private func makeLink(from record: LinkRecord) -> Link? {
        guard let href = URLHelper.getAbsolute(href: record.href, base: baseURL) else {
            return nil
        }
        return Link(
            href: href,
            type: record.type,
            title: record.title,
            rel: record.rel.map { LinkRelation($0) }
        )
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

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = localName(from: qName ?? elementName)
        stack.append(name)
        textBuffer = ""

        switch name {
        case "feed":
            rootKind = .feed
        case "entry":
            if rootKind == .unknown {
                rootKind = .entry
            }
            currentEntry = EntryRecord()
        case "author":
            currentAuthorName = nil
            currentAuthorURI = nil
        case "category":
            currentCategoryAttributes = attributeDict
        case "link":
            let record = LinkRecord(
                href: attributeDict["href"],
                type: attributeDict["type"],
                title: attributeDict["title"],
                rel: attributeDict["rel"],
                facetGroup: attributeDict["facetGroup"]
            )
            if currentEntry != nil {
                currentEntry?.links.append(record)
            } else if rootKind == .feed {
                feedLinks.append(record)
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = localName(from: qName ?? elementName)
        let text = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = stack.dropLast().last

        if let currentEntry {
            switch (parent, name) {
            case ("entry", "title"):
                self.currentEntry?.title = text.nilIfEmpty
            case ("entry", "updated"):
                self.currentEntry?.modified = text.dateFromISO8601
            case ("entry", "id"), ("entry", "identifier"):
                self.currentEntry?.identifier = text.nilIfEmpty
            case ("entry", "published"), ("entry", "issued"):
                self.currentEntry?.published = text.dateFromISO8601
            case ("entry", "summary"), ("entry", "content"):
                if self.currentEntry?.description == nil {
                    self.currentEntry?.description = text.nilIfEmpty
                }
            case ("entry", "language"):
                if let value = text.nilIfEmpty {
                    self.currentEntry?.languages.append(value)
                }
            case ("entry", "publisher"):
                if let value = text.nilIfEmpty {
                    self.currentEntry?.publishers.append(Contributor(name: value))
                }
            case ("author", "name"):
                currentAuthorName = text.nilIfEmpty
            case ("author", "uri"):
                currentAuthorURI = text.nilIfEmpty
            default:
                break
            }

            if name == "author", parent == "entry", let currentAuthorName {
                self.currentEntry?.authors.append(Contributor(name: currentAuthorName, identifier: currentAuthorURI))
                self.currentAuthorName = nil
                self.currentAuthorURI = nil
            } else if name == "category", parent == "entry", let attributes = currentCategoryAttributes, let label = attributes["label"] {
                self.currentEntry?.subjects.append(Subject(name: label, scheme: attributes["scheme"], code: attributes["term"]))
                currentCategoryAttributes = nil
            } else if name == "entry" {
                entryRecords.append(currentEntry)
                self.currentEntry = nil
            }
        } else if rootKind == .feed {
            switch (parent, name) {
            case ("feed", "title"):
                feedTitle = text.nilIfEmpty
            case ("feed", "updated"):
                feedUpdated = text.dateFromISO8601
            case ("feed", "TotalResults"):
                feedTotalResults = Int(text)
            case ("feed", "ItemsPerPage"):
                feedItemsPerPage = Int(text)
            default:
                break
            }
        }

        _ = stack.popLast()
        textBuffer = ""
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        let error = parseError as NSError
        if error.domain == XMLParser.errorDomain && error.code == XMLParser.ErrorCode.delegateAbortedParseError.rawValue {
            return
        }
        parserError = parseError
    }

    private func localName(from qualifiedName: String) -> String {
        qualifiedName.split(separator: ":").last.map(String.init) ?? qualifiedName
    }
}

private final class OpenSearchXMLParser: NSObject, XMLParserDelegate {
    struct URLRecord {
        let type: String
        let template: String
    }

    private(set) var urls: [URLRecord] = []
    private var parserError: Error?

    init(data: Data) throws {
        super.init()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        guard parser.parse() else {
            throw parser.parserError ?? OPDSParserOpenSearchHelperError.searchDocumentIsInvalid
        }
        if let parserError {
            throw parserError
        }
    }

    func bestTemplate(for selfType: String?, relativeTo baseURL: URL?) -> String? {
        guard !urls.isEmpty else {
            return nil
        }

        func resolvedTemplate(_ template: String) -> String? {
            if let absolute = URL(string: template), absolute.scheme != nil {
                return template
            }
            guard let baseURL else {
                return template
            }
            let resolved = URL(string: template, relativeTo: baseURL)?.absoluteURL.absoluteString ?? template
            return resolved
                .replacingOccurrences(of: "%7B", with: "{")
                .replacingOccurrences(of: "%7D", with: "}")
        }

        guard let selfType else {
            return urls.first.flatMap { resolvedTemplate($0.template) }
        }

        let selfMime = OPDS1Parser.parseMimeType(mimeTypeString: selfType)
        var typeAndProfileMatch: URLRecord?
        var typeMatch: URLRecord?

        for url in urls {
            let other = OPDS1Parser.parseMimeType(mimeTypeString: url.type)
            guard selfMime.type == other.type else {
                continue
            }
            if typeMatch == nil {
                typeMatch = url
            }
            if selfMime.parameters["profile"] == other.parameters["profile"] {
                typeAndProfileMatch = url
                break
            }
        }

        let bestMatch = typeAndProfileMatch?.template ?? typeMatch?.template ?? urls.first?.template
        return bestMatch.flatMap(resolvedTemplate)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = (qName ?? elementName).split(separator: ":").last.map(String.init) ?? elementName
        guard name == "Url",
              let type = attributeDict["type"],
              let template = attributeDict["template"]
        else {
            return
        }
        urls.append(URLRecord(type: type, template: template))
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        let error = parseError as NSError
        if error.domain == XMLParser.errorDomain && error.code == XMLParser.ErrorCode.delegateAbortedParseError.rawValue {
            return
        }
        parserError = parseError
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
