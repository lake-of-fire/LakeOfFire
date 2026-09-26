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

struct EbookDirectSectionRequest: Equatable, Sendable {
    let sourceURL: URL
    let subpath: String
}

func ebookDirectSectionRequest(from url: URL) -> EbookDirectSectionRequest? {
    guard url.path == "/processed-section",
          let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
          ) else {
        return nil
    }
    let sourceValues = components.queryItems?
        .filter { $0.name == "sourceURL" }
        .compactMap(\.value) ?? []
    let subpathValues = components.queryItems?
        .filter { $0.name == "subpath" }
        .compactMap(\.value) ?? []
    guard sourceValues.count == 1,
          subpathValues.count == 1,
          let sourceURL = URL(string: sourceValues[0]),
          sourceURL.scheme == "ebook",
          sourceURL.host == "ebook",
          sourceURL.pathComponents.starts(with: ["/", "load"]),
          let subpath = normalizedEbookEntrySubpath(subpathValues[0]) else {
        return nil
    }
    return EbookDirectSectionRequest(
        sourceURL: sourceURL,
        subpath: subpath
    )
}

struct EbookPathBackedEntryRequest: Equatable, Sendable {
    let sourceURL: URL
    let generationID: String?
    let subpath: String
}

func ebookPathBackedEntryRequest(
    from url: URL,
    mainDocumentURL: URL?
) -> EbookPathBackedEntryRequest? {
    let prefix = "/entry-source/"
    guard let encodedPath = URLComponents(
        url: url,
        resolvingAgainstBaseURL: false
    )?.percentEncodedPath,
          encodedPath.hasPrefix(prefix) else {
        return nil
    }
    let path = String(encodedPath.dropFirst(prefix.count))
    guard let separator = path.firstIndex(of: "/") else { return nil }
    let token = String(path[..<separator])
    let generationAndSubpath = String(
        path[path.index(after: separator)...]
    )
    guard let generationSeparator = generationAndSubpath.firstIndex(of: "/")
    else {
        return nil
    }
    let generationID = String(
        generationAndSubpath[..<generationSeparator]
    )
    let percentEncodedSubpath = String(
        generationAndSubpath[
            generationAndSubpath.index(after: generationSeparator)...
        ]
    )
    let generationDigest = generationID.dropFirst(3)
    guard let sourceURLString = ebookString(fromBase64URLToken: token),
          let sourceURL = URL(string: sourceURLString),
          sourceURL.scheme == "ebook",
          sourceURL.host == "ebook",
          sourceURL.pathComponents.starts(with: ["/", "load"]),
          generationID.hasPrefix("g1-"),
          generationDigest.utf8.count == 64,
          generationDigest.allSatisfy({
              $0.isASCII && ($0.isNumber || ("a"..."f").contains($0))
          }),
          let subpath = decodedEbookEntrySubpath(
            fromPercentEncodedPath: percentEncodedSubpath
          ) else {
        return nil
    }
    guard let mainDocumentURL,
          let owner = ebookDirectSectionRequest(from: mainDocumentURL),
          owner.sourceURL == sourceURL else {
        return nil
    }
    return EbookPathBackedEntryRequest(
        sourceURL: sourceURL,
        generationID: generationID,
        subpath: subpath
    )
}

private func ebookDirectorySubpath(for sectionHref: String) -> String {
    guard let slashIndex = sectionHref.lastIndex(of: "/") else { return "" }
    return String(sectionHref[..<sectionHref.index(after: slashIndex)])
}

func ebookProcessedSectionBaseURL(
    sourceURL: URL,
    sectionHref: String,
    generationID: String
) -> String {
    let token = ebookBase64URLToken(for: sourceURL.absoluteString)
    return [
        "ebook://ebook/entry-source/",
        token,
        "/",
        generationID,
        "/",
        percentEncodedEbookEntrySubpath(
            ebookDirectorySubpath(for: sectionHref)
        ),
    ].joined()
}
