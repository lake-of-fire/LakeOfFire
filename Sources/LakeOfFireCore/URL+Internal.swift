import Foundation

public extension URL {
    var isSnippetURL: Bool {
        return absoluteString.hasPrefix("internal://local/snippet?key=")
    }

    /// Identifies the transport route even when its content query is malformed.
    /// Do not use this URL as a user-facing address or a stored content identity.
    var isReaderURLLoaderURL: Bool {
        scheme?.lowercased() == "internal"
            && host?.lowercased() == "local"
            && path == "/load/reader"
    }

    /// The content identity carried by one reader-loader transport URL.
    /// URLComponents has already decoded the query value once; only legacy
    /// double-encoded values without an absolute URL need another decoding pass.
    var readerLoaderContentURL: URL? {
        guard isReaderURLLoaderURL,
              let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              components.user == nil,
              components.password == nil,
              components.port == nil else {
            return nil
        }

        let contentItems = components.queryItems?.filter { $0.name == "reader-url" } ?? []
        guard contentItems.count == 1,
              let value = contentItems.first?.value,
              !value.isEmpty else {
            return nil
        }

        func absoluteURL(from value: String) -> URL? {
            URL(string: value).flatMap { $0.isAbsoluteReaderContentURL ? $0 : nil }
        }

        if let contentURL = URL(string: value), contentURL.scheme != nil {
            return contentURL.isAbsoluteReaderContentURL ? contentURL : nil
        }
        guard let decodedValue = value.removingPercentEncoding else { return nil }
        return absoluteURL(from: decodedValue)
    }

    /// Resolves transport wrappers at content and presentation boundaries.
    /// Physical WebKit document/frame identity must continue to use the original
    /// URL. Invalid wrappers have no content URL and must not escape as addresses.
    var readerContentURL: URL? {
        var contentURL = self
        var visited = Set<URL>()
        while contentURL.isReaderURLLoaderURL {
            guard visited.insert(contentURL).inserted,
                  let nextURL = contentURL.readerLoaderContentURL else {
                return nil
            }
            contentURL = nextURL
        }
        return contentURL.isAbsoluteReaderContentURL ? contentURL : nil
    }

    var snippetKey: String? {
        let absolute = absoluteString
        if isReaderURLLoaderURL {
            return readerContentURL?.snippetKey
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

private extension URL {
    var isAbsoluteReaderContentURL: Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        if scheme == "http" || scheme == "https" {
            return host?.isEmpty == false
        }
        return true
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
