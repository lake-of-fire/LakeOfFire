import Foundation

public extension URL {
    var isSnippetURL: Bool {
        return absoluteString.hasPrefix("internal://local/snippet?key=")
    }

    /// Only the exact reader-loader endpoint is a transport URL. A similarly
    /// named path or an authority containing a port/userinfo is ordinary input.
    var isReaderLoaderTransportURL: Bool {
        scheme?.lowercased() == "internal"
            && host?.lowercased() == "local"
            && port == nil
            && user == nil
            && password == nil
            && path == "/load/reader"
    }

    var readerLoaderContentURL: URL? {
        guard isReaderLoaderTransportURL,
              let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              items.count == 1,
              items[0].name == "reader-url",
              let encodedReaderURL = items[0].value,
              !encodedReaderURL.isEmpty else {
            return nil
        }

        // URLComponents already removes the transport's one encoding layer.
        // An older writer encoded that value twice, so permit one more decode
        // only when it does not yet parse as an allowed absolute content URL.
        var candidate = encodedReaderURL
        for _ in 0..<2 {
            if let contentURL = URL(string: candidate),
               let contentScheme = contentURL.scheme?.lowercased(),
               !contentURL.isReaderLoaderTransportURL {
                let isWebURL = (contentScheme == "http" || contentScheme == "https")
                    && contentURL.host?.isEmpty == false
                let isLocalContent = contentURL.isSnippetURL
                    || contentScheme == "reader-file"
                if isWebURL || isLocalContent {
                    // A same-document fragment on the loader belongs to the
                    // visible source, never to the private transport URL.
                    guard let fragment = components.fragment else { return contentURL }
                    var source = URLComponents(url: contentURL, resolvingAgainstBaseURL: false)
                    source?.fragment = fragment
                    return source?.url
                }
            }
            guard let decoded = candidate.removingPercentEncoding,
                  decoded != candidate else { break }
            candidate = decoded
        }
        return nil
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

