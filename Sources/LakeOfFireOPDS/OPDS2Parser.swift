//
//  Copyright 2024 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum OPDS2ParserError: Error {
    case invalidJSON
    case metadataNotFound
    case invalidLink
    case missingTitle
    case invalidFacet
    case invalidGroup
    case invalidPublication
    case invalidNavigation
}

enum OPDS2Parser {
    static func parseURL(url: URL, session: URLSession = .shared, completion: @escaping (ParseData?, Error?) -> Void) {
        OPDSParser.loadDocument(url: url, session: session) { data, response, error in
            guard let data, let response else {
                completion(nil, error ?? OPDSParserError.documentNotFound)
                return
            }

            do {
                completion(try parse(jsonData: data, url: url, response: response), nil)
            } catch {
                completion(nil, error)
            }
        }
    }

    static func parse(jsonData: Data, url: URL, response: URLResponse) throws -> ParseData {
        var parseData = ParseData(url: url, response: response, version: .OPDS2)
        let baseURL = response.url ?? url

        guard let root = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw OPDS2ParserError.invalidJSON
        }

        if root["navigation"] == nil,
           root["groups"] == nil,
           root["publications"] == nil,
           root["facets"] == nil
        {
            parseData.publication = try Publication(json: root, normalizeHREF: hrefNormalizer(baseURL))
        } else {
            parseData.feed = try parse(jsonDict: root, baseURL: baseURL)
        }

        return parseData
    }

    static func parse(jsonDict: [String: Any], baseURL: URL? = nil) throws -> Feed {
        guard let metadataDict = jsonDict["metadata"] as? [String: Any] else {
            throw OPDS2ParserError.metadataNotFound
        }
        guard let title = OPDS2LocalizedText.resolve(metadataDict["title"]) else {
            throw OPDS2ParserError.missingTitle
        }

        let feed = Feed(title: title)
        parseMetadata(into: feed.metadata, metadataDict: metadataDict)

        for (key, value) in jsonDict {
            switch key {
            case "@context":
                if let context = value as? String {
                    feed.context.append(context)
                } else if let context = value as? [String] {
                    feed.context.append(contentsOf: context)
                }
            case "metadata":
                continue
            case "links":
                guard let links = value as? [[String: Any]] else {
                    throw OPDS2ParserError.invalidLink
                }
                feed.links.append(contentsOf: try links.map { try Link(json: $0, normalizeHREF: hrefNormalizer(baseURL)) })
            case "facets":
                guard let facets = value as? [[String: Any]] else {
                    throw OPDS2ParserError.invalidFacet
                }
                try parseFacets(into: feed, facets: facets, baseURL: baseURL)
            case "publications":
                guard let publications = value as? [[String: Any]] else {
                    throw OPDS2ParserError.invalidPublication
                }
                feed.publications.append(contentsOf: try publications.map { try Publication(json: $0, normalizeHREF: hrefNormalizer(baseURL)) })
            case "navigation":
                guard let navigation = value as? [[String: Any]] else {
                    throw OPDS2ParserError.invalidNavigation
                }
                feed.navigation.append(contentsOf: try navigation.map { try Link(json: $0, normalizeHREF: hrefNormalizer(baseURL)) })
            case "groups":
                guard let groups = value as? [[String: Any]] else {
                    throw OPDS2ParserError.invalidGroup
                }
                try parseGroups(into: feed, groups: groups, baseURL: baseURL)
            default:
                continue
            }
        }

        return feed
    }

    static func parseMetadata(into metadata: OpdsMetadata, metadataDict: [String: Any]) {
        metadata.numberOfItem = metadataDict["numberOfItems"] as? Int
        metadata.itemsPerPage = metadataDict["itemsPerPage"] as? Int
        metadata.modified = (metadataDict["modified"] as? String)?.dateFromISO8601
        metadata.rdfType = metadataDict["@type"] as? String
        metadata.currentPage = metadataDict["currentPage"] as? Int
    }

    private static func parseFacets(into feed: Feed, facets: [[String: Any]], baseURL: URL?) throws {
        for facetDict in facets {
            guard let metadataDict = facetDict["metadata"] as? [String: Any],
                  let title = OPDS2LocalizedText.resolve(metadataDict["title"])
            else {
                throw OPDS2ParserError.invalidFacet
            }

            let facet = Facet(title: title)
            parseMetadata(into: facet.metadata, metadataDict: metadataDict)
            facet.links.append(contentsOf: try Link.links(from: facetDict["links"], normalizeHREF: hrefNormalizer(baseURL)))
            feed.facets.append(facet)
        }
    }

    private static func parseGroups(into feed: Feed, groups: [[String: Any]], baseURL: URL?) throws {
        for groupDict in groups {
            guard let metadataDict = groupDict["metadata"] as? [String: Any],
                  let title = OPDS2LocalizedText.resolve(metadataDict["title"])
            else {
                throw OPDS2ParserError.invalidGroup
            }

            let group = Group(title: title)
            parseMetadata(into: group.metadata, metadataDict: metadataDict)
            group.links.append(contentsOf: try Link.links(from: groupDict["links"], normalizeHREF: hrefNormalizer(baseURL)))
            group.navigation.append(contentsOf: try Link.links(from: groupDict["navigation"], normalizeHREF: hrefNormalizer(baseURL)))

            guard let publications = groupDict["publications"] else {
                feed.groups.append(group)
                continue
            }

            guard let publicationArray = publications as? [[String: Any]] else {
                throw OPDS2ParserError.invalidPublication
            }
            group.publications.append(contentsOf: try publicationArray.map { try Publication(json: $0, normalizeHREF: hrefNormalizer(baseURL)) })
            feed.groups.append(group)
        }
    }
}

private func hrefNormalizer(_ baseURL: URL?) -> (String) -> String {
    { href in URLHelper.getAbsolute(href: href, base: baseURL) ?? href }
}

enum OPDS2LocalizedText {
    // Check the tag's basic shape without validating its registered subtags.
    // Single-letter i- and x- prefixes allow grandfathered and private-use tags.
    private static let languageTagShape = try! NSRegularExpression(
        pattern: #"\A(?:[A-Za-z]{2,8}|[iIxX](?=-))(?:-[A-Za-z0-9]{1,8})*\z"#
    )

    static func resolve(_ value: Any?, preferredLanguages: [String]? = nil) -> String? {
        if let text = value as? String { return text }
        guard let variants = value as? [String: String], !variants.isEmpty else { return nil }

        var translations: [String: String] = [:]
        for (tag, text) in variants {
            let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
            guard languageTagShape.firstMatch(in: tag, range: range) != nil,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  translations.updateValue(text, forKey: tag.lowercased()) == nil else { return nil }
        }

        let lookups = (preferredLanguages ?? Locale.preferredLanguages).map { lookupRanges(for: $0) }
        // Exhaust RFC 4647 lookup across all preferred languages before defaulting.
        for range in lookups.joined() {
            if let text = translations[range] { return text }
        }

        // OPDS display fallback can pick a different region when the tag
        // does not explicitly conflict with the preferred script.
        let tags = translations.keys.sorted()
        for ranges in lookups {
            let preferredScript = ranges.first.flatMap { explicitScript(in: $0) }
            for range in ranges {
                if let tag = tags.first(where: { tag in
                    guard tag.hasPrefix(range + "-") else { return false }
                    guard let preferredScript, let script = explicitScript(in: tag) else { return true }
                    return preferredScript == script
                }) {
                    return translations[tag]
                }
            }
        }
        return translations["und"] ?? tags.first.flatMap { translations[$0] }
    }

    private static func explicitScript(in tag: String) -> Substring? {
        // An explicit script follows the primary language and optional extlangs.
        let scriptPrefix = tag.range(of: #"\A[a-z]{2,8}(?:-[a-z]{3}){0,3}-[a-z]{4}(?=-|\z)"#,
                                     options: .regularExpression)
        return scriptPrefix.map { tag[$0].suffix(4) }
    }

    private static func lookupRanges(for language: String) -> [String] {
        let tag = language.replacingOccurrences(of: "_", with: "-").lowercased()
        var subtags = tag.split(separator: "-")
        var ranges: [String] = []
        while !subtags.isEmpty {
            ranges.append(subtags.joined(separator: "-"))
            subtags.removeLast()
            // Removing the last subtag also removes a now-terminal singleton.
            while subtags.last?.count == 1 { subtags.removeLast() }
        }
        return ranges
    }
}
