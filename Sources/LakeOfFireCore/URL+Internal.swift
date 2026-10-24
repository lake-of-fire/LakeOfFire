import Foundation

public extension URL {
    var isSnippetURL: Bool {
        return absoluteString.hasPrefix("internal://local/snippet?key=")
    }

    var readerLoaderContentURL: URL? {
        guard scheme?.lowercased() == "internal",
              host?.lowercased() == "local",
              path == "/load/reader",
              let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let readerURLValues = components.queryItems?.filter({ $0.name == "reader-url" }),
              readerURLValues.count == 1,
              let readerURLValue = readerURLValues.first?.value else {
            return nil
        }

        func supportedContentURL(from value: String) -> URL? {
            guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else {
                return nil
            }
            switch scheme {
            case "http", "https":
                guard url.host != nil else { return nil }
            case "reader-file":
                break
            case "internal":
                guard url.isSnippetURL else { return nil }
            default:
                return nil
            }

            // A same-document #fragment belongs to the loader document in
            // WebKit. Publish it against the original URL for reader history,
            // lookup scopes and location-bar links.
            guard let fragment = components.fragment,
                  var contentComponents = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return url
            }
            contentComponents.fragment = fragment
            return contentComponents.url
        }

        // URLComponents decodes the query item exactly once. Do not decode an
        // already valid URL again: its literal %2F, %23 and %26 are content.
        if let readerURL = supportedContentURL(from: readerURLValue) {
            return readerURL
        }
        // Preserve historical loader links that encoded the entire source URL
        // twice, but never treat an arbitrary scheme as an article URL.
        return readerURLValue.removingPercentEncoding.flatMap(supportedContentURL(from:))
    }

    var snippetKey: String? {
        let absolute = absoluteString
        if absolute.hasPrefix("internal://local/load/reader") {
            return readerLoaderContentURL?.snippetKey
        }

        let eligiblePrefix = absolute.hasPrefix("internal://local/snippet")
            || absolute.hasPrefix("about:snippet")
        guard eligiblePrefix else { return nil }

        if let components = URLComponents(string: absolute),
           let key = components.queryItems?.first(where: { $0.name == "key" })?.value,
           !key.isEmpty {
            return key
        }

        if let range = absolute.range(of: "key=") {
            let key = String(absolute[range.upperBound...])
            return key.isEmpty ? nil : key
        }

        return nil
    }

    func removingFragmentIfNeeded() -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              components.fragment != nil else {
            return self
        }
        components.fragment = nil
        return components.url ?? self
    }
}

public func urlsMatchWithoutHash(_ lhs: URL?, _ rhs: URL?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
        return true
    case let (.some(lhsURL), .some(rhsURL)):
        if lhsURL == rhsURL {
            return true
        }
        return lhsURL.removingFragmentIfNeeded() == rhsURL.removingFragmentIfNeeded()
    default:
        return false
    }
}

