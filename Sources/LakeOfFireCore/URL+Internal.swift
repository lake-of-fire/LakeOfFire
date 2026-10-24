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

        guard let items = components.queryItems,
              items.count == 1,
              items[0].name == "reader-url",
              let value = items[0].value,
              !value.isEmpty else {
            return nil
        }

        func contentURL(from candidate: String) -> URL? {
            guard let sourceURL = URL(string: candidate),
                  sourceURL.scheme != nil,
                  sourceURL.isReaderLoaderSourceURL else {
                return nil
            }
            // A fragment navigation on the transport belongs to its source.
            guard let fragment = components.fragment else { return sourceURL }
            var sourceComponents = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)
            sourceComponents?.fragment = fragment
            return sourceComponents?.url
        }

        if let directURL = URL(string: value), directURL.scheme != nil {
            return contentURL(from: value)
        }
        guard let decodedValue = value.removingPercentEncoding,
              decodedValue != value else { return nil }
        return contentURL(from: decodedValue)
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
    /// Loader documents can represent web articles, snippets or local reader
    /// files. Nested legacy loaders are resolved and validated by readerContentURL.
    var isReaderLoaderSourceURL: Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        if isReaderURLLoaderURL { return true }
        if scheme == "http" || scheme == "https" {
            return host?.isEmpty == false
        }
        if scheme == "internal" {
            return isSnippetURL && snippetKey != nil
        }
        if scheme == "about" {
            return absoluteString.hasPrefix("about:snippet?key=") && snippetKey != nil
        }
        if scheme == "reader-file" {
            let path = URLComponents(url: self, resolvingAgainstBaseURL: false)?.percentEncodedPath
            return host?.lowercased() == "file"
                && user == nil
                && password == nil
                && port == nil
                && (path?.hasPrefix("/load/local/") == true
                    || path?.hasPrefix("/load/icloud/") == true)
        }
        return false
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
