//
//  Copyright 2024 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation

public class Feed {
    public var metadata: OpdsMetadata
    public var links: [Link]
    public var facets: [Facet]
    public var groups: [Group]
    public var publications: [Publication]
    public var navigation: [Link]
    public var context: [String]

    public init(title: String) {
        metadata = OpdsMetadata(title: title)
        links = []
        facets = []
        groups = []
        publications = []
        navigation = []
        context = []
    }
}

public class Facet {
    public var metadata: OpdsMetadata
    public var links: [Link]

    public init(title: String) {
        metadata = OpdsMetadata(title: title)
        links = []
    }
}

public class Group {
    public var metadata: OpdsMetadata
    public var links: [Link]
    public var publications: [Publication]
    public var navigation: [Link]

    public init(title: String) {
        metadata = OpdsMetadata(title: title)
        links = []
        publications = []
        navigation = []
    }
}

public class OpdsMetadata {
    public var title: String
    public var numberOfItem: Int?
    public var itemsPerPage: Int?
    public var modified: Date?
    public var rdfType: String?
    public var currentPage: Int?

    public init(title: String) {
        self.title = title
    }
}

public struct Publication: Hashable {
    public let metadata: Metadata
    public let links: [Link]
    public let images: [Link]

    public init(metadata: Metadata, links: [Link] = [], images: [Link] = []) {
        self.metadata = metadata
        self.links = links
        self.images = images
    }

    init(json: [String: Any], normalizeHREF: (String) -> String = { $0 }) throws {
        guard let metadataDict = json["metadata"] as? [String: Any] else {
            throw OPDS2ParserError.invalidPublication
        }

        metadata = try Metadata(json: metadataDict, normalizeHREF: normalizeHREF)
        links = try Link.links(from: json["links"], normalizeHREF: normalizeHREF)
        images = try Link.links(from: json["images"], normalizeHREF: normalizeHREF)
    }
}

public struct Metadata: Hashable {
    public let identifier: String?
    public let title: String
    public let subtitle: String?
    public let modified: Date?
    public let published: Date?
    public let languages: [String]
    public let subjects: [Subject]
    public let authors: [Contributor]
    public let publishers: [Contributor]
    public let description: String?

    public init(
        identifier: String? = nil,
        title: String,
        subtitle: String? = nil,
        modified: Date? = nil,
        published: Date? = nil,
        languages: [String] = [],
        subjects: [Subject] = [],
        authors: [Contributor] = [],
        publishers: [Contributor] = [],
        description: String? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.subtitle = subtitle
        self.modified = modified
        self.published = published
        self.languages = languages
        self.subjects = subjects
        self.authors = authors
        self.publishers = publishers
        self.description = description
    }

    init(json: [String: Any], normalizeHREF: (String) -> String = { $0 }) throws {
        guard let title = json["title"] as? String else {
            throw OPDS2ParserError.missingTitle
        }

        self.init(
            identifier: json["identifier"] as? String,
            title: title,
            subtitle: json["subtitle"] as? String,
            modified: (json["modified"] as? String)?.dateFromISO8601,
            published: (json["published"] as? String)?.dateFromISO8601,
            languages: String.array(from: json["language"]),
            subjects: try Subject.array(from: json["subject"]),
            authors: try Contributor.array(from: json["author"], normalizeHREF: normalizeHREF),
            publishers: try Contributor.array(from: json["publisher"], normalizeHREF: normalizeHREF),
            description: json["description"] as? String
        )
    }
}

public struct Contributor: Hashable {
    public let name: String
    public let identifier: String?
    public let sortAs: String?
    public let roles: [String]
    public let position: Double?
    public let links: [Link]

    public init(
        name: String,
        identifier: String? = nil,
        sortAs: String? = nil,
        roles: [String] = [],
        position: Double? = nil,
        links: [Link] = []
    ) {
        self.name = name
        self.identifier = identifier
        self.sortAs = sortAs
        self.roles = roles
        self.position = position
        self.links = links
    }

    static func array(from json: Any?, normalizeHREF: (String) -> String = { $0 }) throws -> [Contributor] {
        guard let json else {
            return []
        }
        if let array = json as? [Any] {
            return try array.compactMap { try Contributor(json: $0, normalizeHREF: normalizeHREF) }
        }
        if let contributor = try Contributor(json: json, normalizeHREF: normalizeHREF) {
            return [contributor]
        }
        return []
    }

    init?(json: Any, normalizeHREF: (String) -> String = { $0 }) throws {
        if let name = json as? String {
            self.init(name: name)
            return
        }

        guard let dict = json as? [String: Any], let name = dict["name"] as? String else {
            return nil
        }

        self.init(
            name: name,
            identifier: dict["identifier"] as? String,
            sortAs: dict["sortAs"] as? String,
            roles: String.array(from: dict["role"]),
            position: Double.value(from: dict["position"]),
            links: try Link.links(from: dict["links"], normalizeHREF: normalizeHREF)
        )
    }
}

public struct Subject: Hashable {
    public let name: String
    public let sortAs: String?
    public let scheme: String?
    public let code: String?
    public let links: [Link]

    public init(name: String, sortAs: String? = nil, scheme: String? = nil, code: String? = nil, links: [Link] = []) {
        self.name = name
        self.sortAs = sortAs
        self.scheme = scheme
        self.code = code
        self.links = links
    }

    static func array(from json: Any?) throws -> [Subject] {
        guard let json else {
            return []
        }
        if let array = json as? [Any] {
            return try array.compactMap(Subject.init(json:))
        }
        if let subject = try Subject(json: json) {
            return [subject]
        }
        return []
    }

    init?(json: Any) throws {
        if let name = json as? String {
            self.init(name: name)
            return
        }

        guard let dict = json as? [String: Any], let name = dict["name"] as? String else {
            return nil
        }

        self.init(
            name: name,
            sortAs: dict["sortAs"] as? String,
            scheme: dict["scheme"] as? String,
            code: dict["code"] as? String,
            links: try Link.links(from: dict["links"])
        )
    }
}

public struct Link: Hashable {
    public let href: String
    public let type: String?
    public let title: String?
    public let rels: [LinkRelation]

    public init(href: String, type: String? = nil, title: String? = nil, rels: [LinkRelation] = [], rel: LinkRelation? = nil) {
        var rels = rels
        if let rel {
            rels.append(rel)
        }
        self.href = href
        self.type = type
        self.title = title
        self.rels = rels
    }

    init(json: [String: Any], normalizeHREF: (String) -> String = { $0 }) throws {
        guard let href = json["href"] as? String else {
            throw OPDS2ParserError.invalidLink
        }
        self.init(
            href: normalizeHREF(href),
            type: json["type"] as? String,
            title: json["title"] as? String,
            rels: LinkRelation.array(from: json["rel"])
        )
    }

    public func url(relativeTo baseURL: URL?) -> URL? {
        if let absolute = URL(string: href), absolute.scheme != nil {
            return absolute
        }
        guard let baseURL else {
            return nil
        }
        let safeHref = (href.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? href).removingPrefix("/")
        return URL(string: safeHref, relativeTo: baseURL)?.absoluteURL
    }

    static func links(from json: Any?, normalizeHREF: (String) -> String = { $0 }) throws -> [Link] {
        guard let array = json as? [[String: Any]] else {
            return []
        }
        return try array.map { try Link(json: $0, normalizeHREF: normalizeHREF) }
    }
}

public extension Array where Element == Link {
    func first(withRel rel: LinkRelation) -> Link? {
        first { $0.rels.contains(rel) }
    }
}

public struct LinkRelation: Hashable, ExpressibleByStringLiteral {
    public let string: String

    public init(_ string: String) {
        self.string = string.lowercased()
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public func hasPrefix(_ prefix: String) -> Bool {
        string.hasPrefix(prefix.lowercased())
    }

    public var isSample: Bool {
        self == .preview || self == .opdsAcquisitionSample
    }

    public var isImage: Bool {
        hasPrefix("http://opds-spec.org/image")
    }

    public var isOPDSAcquisition: Bool {
        hasPrefix("http://opds-spec.org/acquisition")
    }

    public static let alternate = LinkRelation("alternate")
    public static let contents = LinkRelation("contents")
    public static let cover = LinkRelation("cover")
    public static let manifest = LinkRelation("manifest")
    public static let search = LinkRelation("search")
    public static let `self` = LinkRelation("self")
    public static let publication = LinkRelation("publication")
    public static let collection = LinkRelation("collection")
    public static let previous = LinkRelation("previous")
    public static let next = LinkRelation("next")
    public static let preview = LinkRelation("preview")
    public static let opdsAcquisition = LinkRelation("http://opds-spec.org/acquisition")
    public static let opdsAcquisitionOpenAccess = LinkRelation("http://opds-spec.org/acquisition/open-access")
    public static let opdsAcquisitionBorrow = LinkRelation("http://opds-spec.org/acquisition/borrow")
    public static let opdsAcquisitionBuy = LinkRelation("http://opds-spec.org/acquisition/buy")
    public static let opdsAcquisitionSample = LinkRelation("http://opds-spec.org/acquisition/sample")
    public static let opdsAcquisitionSubscribe = LinkRelation("http://opds-spec.org/acquisition/subscribe")
    public static let opdsImage = LinkRelation("http://opds-spec.org/image")
    public static let opdsImageThumbnail = LinkRelation("http://opds-spec.org/image/thumbnail")
    public static let opdsShelf = LinkRelation("http://opds-spec.org/shelf")
    public static let opdsSubscriptions = LinkRelation("http://opds-spec.org/subscriptions")
    public static let opdsFacet = LinkRelation("http://opds-spec.org/facet")
    public static let opdsFeatured = LinkRelation("http://opds-spec.org/featured")
    public static let opdsRecommended = LinkRelation("http://opds-spec.org/recommended")
    public static let opdsSortNew = LinkRelation("http://opds-spec.org/sort/new")
    public static let opdsSortPopular = LinkRelation("http://opds-spec.org/sort/popular")
    public static let opdsAuthenticate = LinkRelation("authenticate")
    public static let opdsRefresh = LinkRelation("refresh")
    public static let opdsLogo = LinkRelation("logo")
    public static let opdsRegister = LinkRelation("register")
    public static let opdsHelp = LinkRelation("help")

    static func array(from json: Any?) -> [LinkRelation] {
        if let relation = json as? String {
            return [LinkRelation(relation)]
        }
        if let relations = json as? [String] {
            return relations.map { LinkRelation($0) }
        }
        return []
    }
}

extension Array where Element == LinkRelation {
    func contains(_ relation: String) -> Bool {
        contains(LinkRelation(relation))
    }
}

private extension String {
    static func array(from json: Any?) -> [String] {
        if let value = json as? String {
            return [value]
        }
        if let values = json as? [String] {
            return values
        }
        return []
    }

    func removingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}

private extension Double {
    static func value(from json: Any?) -> Double? {
        switch json {
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        default:
            return nil
        }
    }
}
