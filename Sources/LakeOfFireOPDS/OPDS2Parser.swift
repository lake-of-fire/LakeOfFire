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
    static func parseURL(url: URL, completion: @escaping (ParseData?, Error?) -> Void) {
        URLSession.shared.dataTask(with: url) { data, response, error in
            guard let data, let response else {
                completion(nil, error ?? OPDSParserError.documentNotFound)
                return
            }

            do {
                completion(try parse(jsonData: data, url: url, response: response), nil)
            } catch {
                completion(nil, error)
            }
        }.resume()
    }

    static func parse(jsonData: Data, url: URL, response: URLResponse) throws -> ParseData {
        var parseData = ParseData(url: url, response: response, version: .OPDS2)

        guard let root = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw OPDS2ParserError.invalidJSON
        }

        if root["navigation"] == nil,
           root["groups"] == nil,
           root["publications"] == nil,
           root["facets"] == nil
        {
            parseData.publication = try Publication(json: root)
        } else {
            parseData.feed = try parse(jsonDict: root, baseURL: url)
        }

        return parseData
    }

    static func parse(jsonDict: [String: Any], baseURL: URL? = nil) throws -> Feed {
        guard let metadataDict = jsonDict["metadata"] as? [String: Any] else {
            throw OPDS2ParserError.metadataNotFound
        }
        guard let title = metadataDict["title"] as? String else {
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
        metadata.title = (metadataDict["title"] as? String) ?? metadata.title
        metadata.numberOfItem = metadataDict["numberOfItems"] as? Int
        metadata.itemsPerPage = metadataDict["itemsPerPage"] as? Int
        metadata.modified = (metadataDict["modified"] as? String)?.dateFromISO8601
        metadata.rdfType = metadataDict["@type"] as? String
        metadata.currentPage = metadataDict["currentPage"] as? Int
    }

    private static func parseFacets(into feed: Feed, facets: [[String: Any]], baseURL: URL?) throws {
        for facetDict in facets {
            guard let metadataDict = facetDict["metadata"] as? [String: Any],
                  let title = metadataDict["title"] as? String
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
                  let title = metadataDict["title"] as? String
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
