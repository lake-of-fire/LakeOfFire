import Foundation

private let ebookEntryPathComponentAllowedCharacters = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
)

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

/// URLComponents already decodes query values once. Duplicate or valueless
/// selectors remain invalid instead of disappearing through compactMap/first.
func ebookEntryQuerySubpath(in url: URL) -> String? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    let selectors = components.queryItems?.filter { $0.name == "subpath" } ?? []
    guard selectors.count == 1, let value = selectors[0].value else { return nil }
    return normalizedEbookEntrySubpath(value)
}
