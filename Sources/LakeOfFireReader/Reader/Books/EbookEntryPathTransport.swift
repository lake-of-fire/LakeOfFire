import Foundation

private enum EbookBase64URLByte {
    static let plus = UInt8(ascii: "+")
    static let hyphen = UInt8(ascii: "-")
    static let slash = UInt8(ascii: "/")
    static let underscore = UInt8(ascii: "_")
    static let equals = UInt8(ascii: "=")
}

private let ebookEntryPathComponentAllowedCharacters = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
)

func ebookBase64URLToken(for string: String) -> String {
    var bytes = Array(Data(string.utf8).base64EncodedData())
    for index in bytes.indices {
        if bytes[index] == EbookBase64URLByte.plus {
            bytes[index] = EbookBase64URLByte.hyphen
        } else if bytes[index] == EbookBase64URLByte.slash {
            bytes[index] = EbookBase64URLByte.underscore
        }
    }
    while bytes.last == EbookBase64URLByte.equals {
        bytes.removeLast()
    }
    return String(decoding: bytes, as: UTF8.self)
}

func ebookString(fromBase64URLToken token: String) -> String? {
    var bytes = Array(token.utf8)
    for index in bytes.indices {
        if bytes[index] == EbookBase64URLByte.hyphen {
            bytes[index] = EbookBase64URLByte.plus
        } else if bytes[index] == EbookBase64URLByte.underscore {
            bytes[index] = EbookBase64URLByte.slash
        }
    }
    bytes.append(contentsOf: repeatElement(
        EbookBase64URLByte.equals,
        count: (4 - bytes.count % 4) % 4
    ))
    guard let data = Data(base64Encoded: Data(bytes)) else { return nil }
    return String(data: data, encoding: .utf8)
}

func normalizedEbookEntrySubpath(_ rawSubpath: String) -> String? {
    guard !rawSubpath.isEmpty,
          !rawSubpath.hasPrefix("/"),
          !rawSubpath.contains("\\"),
          !rawSubpath.contains("\0") else {
        return nil
    }
    let components = rawSubpath.split(
        separator: "/",
        omittingEmptySubsequences: false
    )
    guard components.allSatisfy({
        !$0.isEmpty && $0 != "." && $0 != ".."
    }) else {
        return nil
    }
    return components.joined(separator: "/")
}

/// Decode URL transport exactly once, one path component at a time. A literal
/// "%2F" EPUB filename reaches this function as "%252F" and remains the literal
/// five-byte spelling after one decode. A transport "%2F" would become a slash
/// inside one component and is rejected instead of changing the package path.
func decodedEbookEntrySubpath(
    fromPercentEncodedPath percentEncodedSubpath: String
) -> String? {
    guard !percentEncodedSubpath.isEmpty,
          !percentEncodedSubpath.hasPrefix("/") else {
        return nil
    }
    let encodedComponents = percentEncodedSubpath.split(
        separator: "/",
        omittingEmptySubsequences: false
    )
    var decodedComponents = [String]()
    decodedComponents.reserveCapacity(encodedComponents.count)
    for encodedComponent in encodedComponents {
        guard !encodedComponent.isEmpty,
              let component = String(encodedComponent).removingPercentEncoding,
              !component.isEmpty,
              component != ".",
              component != "..",
              !component.contains("/"),
              !component.contains("\\"),
              !component.contains("\0") else {
            return nil
        }
        decodedComponents.append(component)
    }
    return normalizedEbookEntrySubpath(decodedComponents.joined(separator: "/"))
}

/// Encode each EPUB path component with only RFC 3986 unreserved bytes left
/// literal. In particular "%" is always "%25", so package names that themselves
/// contain percent-looking text cannot be decoded twice by URL transport.
func percentEncodedEbookEntrySubpath(_ path: String) -> String {
    path.split(separator: "/", omittingEmptySubsequences: false)
        .map {
            String($0).addingPercentEncoding(
                withAllowedCharacters: ebookEntryPathComponentAllowedCharacters
            )!
        }
        .joined(separator: "/")
}

enum EbookEntryRequestIdentityError: Error { case invalidIdentity }

/// Missing and malformed capabilities must remain different outcomes. In
/// particular a valueless/duplicate query must not disappear through compactMap.
func ebookPackageSessionID(in url: URL, header: String? = nil) throws -> String? {
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
        .filter { $0.name == "packageSessionID" } ?? []
    guard query.count <= 1, query.first.map({ $0.value != nil }) != false else {
        throw EbookEntryRequestIdentityError.invalidIdentity
    }
    let value = query.first?.value
    for candidate in [value, header].compactMap({ $0 }) {
        guard candidate.utf8.count == 36, let uuid = UUID(uuidString: candidate),
              candidate.utf8.elementsEqual(uuid.uuidString.lowercased().utf8) else {
            throw EbookEntryRequestIdentityError.invalidIdentity
        }
    }
    if let value, let header, !value.utf8.elementsEqual(header.utf8) {
        throw EbookEntryRequestIdentityError.invalidIdentity
    }
    return value ?? header
}

struct EbookDirectSectionRequest: Equatable, Sendable {
    let sourceURL: URL
    let subpath: String
    let packageSessionID: String?
    init(sourceURL: URL, subpath: String, packageSessionID: String? = nil) {
        self.sourceURL = sourceURL
        self.subpath = subpath
        self.packageSessionID = packageSessionID
    }
}

func ebookDirectSectionRequest(from url: URL) -> EbookDirectSectionRequest? {
    guard url.scheme == "ebook", url.host == "ebook",
          url.path == "/processed-section",
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    let sources = components.queryItems?.filter { $0.name == "sourceURL" } ?? []
    let subpaths = components.queryItems?.filter { $0.name == "subpath" } ?? []
    guard sources.count == 1, subpaths.count == 1,
          let rawSource = sources[0].value, let rawSubpath = subpaths[0].value,
          let sourceURL = URL(string: rawSource),
          sourceURL.scheme == "ebook", sourceURL.host == "ebook",
          sourceURL.pathComponents.starts(with: ["/", "load"]),
          let subpath = normalizedEbookEntrySubpath(rawSubpath) else { return nil }
    do {
        return .init(sourceURL: sourceURL, subpath: subpath,
                     packageSessionID: try ebookPackageSessionID(in: url))
    } catch { return nil }
}

struct EbookPathBackedEntryRequest: Equatable, Sendable {
    let sourceURL: URL
    let generationID: String?
    let subpath: String
    let packageSessionID: String?
    init(sourceURL: URL, generationID: String?, subpath: String, packageSessionID: String? = nil) {
        self.sourceURL = sourceURL
        self.generationID = generationID
        self.subpath = subpath
        self.packageSessionID = packageSessionID
    }
}

func ebookPathBackedEntryRequest(from url: URL, mainDocumentURL: URL?) -> EbookPathBackedEntryRequest? {
    guard url.scheme == "ebook", url.host == "ebook",
          let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath else { return nil }
    let sessionBound = encodedPath.hasPrefix("/entry-session/")
    let prefix = sessionBound ? "/entry-session/" : "/entry-source/"
    guard encodedPath.hasPrefix(prefix) else { return nil }
    let path = String(encodedPath.dropFirst(prefix.count))
    let pieces = path.split(separator: "/", maxSplits: sessionBound ? 3 : 2, omittingEmptySubsequences: false)
    guard pieces.count == (sessionBound ? 4 : 3) else { return nil }
    let token = String(pieces[0]), generationID = String(pieces[1])
    let sessionID = sessionBound ? String(pieces[2]) : nil
    let rawSubpath = String(pieces[sessionBound ? 3 : 2])
    let generationDigest = generationID.dropFirst(3)
    guard let sourceURLString = ebookString(fromBase64URLToken: token),
          let sourceURL = URL(string: sourceURLString),
          sourceURL.scheme == "ebook", sourceURL.host == "ebook",
          sourceURL.pathComponents.starts(with: ["/", "load"]),
          generationID.hasPrefix("g1-"), generationDigest.utf8.count == 64,
          generationDigest.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }),
          let subpath = decodedEbookEntrySubpath(fromPercentEncodedPath: rawSubpath),
          let mainDocumentURL, let owner = ebookDirectSectionRequest(from: mainDocumentURL),
          owner.sourceURL.absoluteString.utf8.elementsEqual(sourceURL.absoluteString.utf8),
          owner.packageSessionID == sessionID else { return nil }
    // The owner parser validates canonical spelling. Legacy path routes cannot
    // strip the session from a bound document, even with a valid generation.
    if let sessionID {
        guard sessionID.utf8.count == 36, let uuid = UUID(uuidString: sessionID),
              sessionID.utf8.elementsEqual(uuid.uuidString.lowercased().utf8) else { return nil }
    }
    return .init(sourceURL: sourceURL, generationID: generationID, subpath: subpath,
                 packageSessionID: sessionID)
}

/// Resolve the same source in each supplied channel. Do not let an explicit
/// header override another source in the query or its owning processed frame.
func ebookPackageSourceURL(requestURL: URL, mainDocumentURL: URL?, header: String?) -> URL? {
    let sources = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.queryItems?
        .filter { $0.name == "sourceURL" } ?? []
    guard sources.count <= 1, sources.first.map({ $0.value != nil }) != false else { return nil }
    let ownerURL = mainDocumentURL.flatMap { ebookDirectSectionRequest(from: $0)?.sourceURL ?? $0 }
    let values = [header, sources.first?.value, ownerURL?.absoluteString].compactMap { $0 }
    guard let first = values.first, values.allSatisfy({ $0.utf8.elementsEqual(first.utf8) }),
          let source = URL(string: first), source.baseURL == nil,
          source.scheme == "ebook", source.host == "ebook",
          source.user == nil, source.password == nil, source.port == nil,
          source.pathComponents.starts(with: ["/", "load"]) else { return nil }
    return source
}

private func ebookDirectorySubpath(for sectionHref: String) -> String {
    guard let slashIndex = sectionHref.lastIndex(of: "/") else { return "" }
    return String(sectionHref[..<sectionHref.index(after: slashIndex)])
}

func ebookProcessedSectionBaseURL(sourceURL: URL, sectionHref: String, generationID: String,
                                 packageSessionID: String? = nil) -> String {
    let token = ebookBase64URLToken(for: sourceURL.absoluteString)
    let prefix = packageSessionID == nil ? "ebook://ebook/entry-source/" : "ebook://ebook/entry-session/"
    return prefix + token + "/" + generationID + "/"
        + (packageSessionID.map { $0 + "/" } ?? "")
        + percentEncodedEbookEntrySubpath(ebookDirectorySubpath(for: sectionHref))
}

/// URLComponents already decodes query values once. Duplicate or valueless
/// selectors remain invalid instead of disappearing through compactMap/first.
func ebookEntryQuerySubpath(in url: URL) -> String? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    let selectors = components.queryItems?.filter { $0.name == "subpath" } ?? []
    guard selectors.count == 1, let value = selectors[0].value else { return nil }
    return normalizedEbookEntrySubpath(value)
}
