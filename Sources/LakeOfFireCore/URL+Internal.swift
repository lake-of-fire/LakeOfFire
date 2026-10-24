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

    /// The endpoint and authority required for a valid loader transport.
    var isReaderLoaderTransportURL: Bool {
        isReaderURLLoaderURL && user == nil && password == nil && port == nil
    }

    /// The content identity carried by one reader-loader transport URL.
    /// URLComponents has already decoded the query value once; only legacy
    /// double-encoded values without an absolute URL need another decoding pass.
    var readerLoaderContentURL: URL? {
        guard isReaderLoaderTransportURL,
              let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let items = components.queryItems, items.count == 1 else {
            return nil
        }

        let contentItems = items.filter { $0.name == "reader-url" }
        guard contentItems.count == 1,
              let value = contentItems.first?.value,
              !value.isEmpty else {
            return nil
        }

        func absoluteURL(from value: String) -> URL? {
            URL(string: value).flatMap { $0.isSupportedReaderLoaderTarget ? $0 : nil }
        }

        let contentURL: URL?
        if let parsed = URL(string: value), parsed.scheme != nil {
            contentURL = parsed.isSupportedReaderLoaderTarget ? parsed : nil
        } else {
            contentURL = value.removingPercentEncoding.flatMap(absoluteURL(from:))
        }
        guard let contentURL else { return nil }
        guard let fragment = components.percentEncodedFragment else { return contentURL }
        var source = URLComponents(url: contentURL, resolvingAgainstBaseURL: false)
        source?.percentEncodedFragment = fragment
        return source?.url
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
    var isSupportedReaderLoaderTarget: Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        switch scheme {
        case "http", "https":
            return host?.isEmpty == false
        case "reader-file":
            guard let parts = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return false }
            return parts.host?.lowercased() == "file"
                && parts.user == nil && parts.password == nil && parts.port == nil
                && (parts.percentEncodedPath.hasPrefix("/load/local/")
                    || parts.percentEncodedPath.hasPrefix("/load/icloud/"))
        case "ebook", "ebook-url", "epub", "pdf", "pdf-url":
            // Older local-content transports include ebook chapters. Keep
            // their original source identity while excluding script, data and
            // file URLs from the privileged internal reader wrapper.
            return true
        case "internal", "about":
            if isReaderURLLoaderURL { return true } // Resolve legacy nested wrappers below.
            guard let parts = URLComponents(url: self, resolvingAgainstBaseURL: false),
                  parts.user == nil, parts.password == nil, parts.port == nil,
                  let items = parts.queryItems, items.count == 1,
                  items[0].name == "key", items[0].value?.isEmpty == false else { return false }
            return scheme == "about" ? parts.path == "snippet"
                : parts.host?.lowercased() == "local" && parts.path == "/snippet"
        default:
            return false
        }
    }

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
