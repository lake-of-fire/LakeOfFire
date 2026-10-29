import Foundation

public extension URL {
    var isSnippetURL: Bool {
        return absoluteString.hasPrefix("internal://local/snippet?key=")
    }

    var readerContentSourceURL: URL? {
        guard scheme?.lowercased() == "internal",
              host?.lowercased() == "local",
              (path == "/load/reader" || path == "/reader") else {
            return nil
        }

        func absoluteURL(from value: String) -> URL? {
            URL(string: value).flatMap { $0.scheme == nil ? nil : $0 }
        }

        if let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
           let readerURLString = components.queryItems?.first(where: { $0.name == "reader-url" })?.value {
            if let readerURL = absoluteURL(from: readerURLString) {
                return applyingReaderDocumentFragment(to: readerURL)
            }
            if let decodedReaderURL = readerURLString.removingPercentEncoding,
               let readerURL = absoluteURL(from: decodedReaderURL) {
                return applyingReaderDocumentFragment(to: readerURL)
            }
        }

        guard let range = absoluteString.range(of: "reader-url=") else {
            return nil
        }
        let rawReaderURL = String(absoluteString[range.upperBound...])
        if let decodedReaderURL = rawReaderURL.removingPercentEncoding,
           let readerURL = absoluteURL(from: decodedReaderURL) {
            return applyingReaderDocumentFragment(to: readerURL)
        }
        return absoluteURL(from: rawReaderURL).map { applyingReaderDocumentFragment(to: $0) }
    }

    /// The generated document has its own origin; semantic identity remains the source.
    var isReaderDocumentURL: Bool {
        scheme?.lowercased() == "internal" && host?.lowercased() == "local"
            && path == "/reader" && readerContentSourceURL != nil
    }

    private func applyingReaderDocumentFragment(to sourceURL: URL) -> URL {
        guard let fragment = URLComponents(url: self, resolvingAgainstBaseURL: false)?.percentEncodedFragment,
              var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false) else {
            return sourceURL
        }
        components.percentEncodedFragment = fragment
        return components.url ?? sourceURL
    }

    var snippetKey: String? {
        let absolute = absoluteString
        if readerContentSourceURL != nil {
            return readerContentSourceURL?.snippetKey
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
