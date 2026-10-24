import Foundation

public extension URL {
    var isSnippetURL: Bool {
        scheme?.lowercased() == "internal"
            && host?.lowercased() == "local"
            && path == "/snippet"
            && snippetKey != nil
    }

    var readerLoaderContentURL: URL? {
        guard scheme?.lowercased() == "internal",
              host?.lowercased() == "local",
              path == "/load/reader" else {
            return nil
        }

        func absoluteURL(from value: String) -> URL? {
            URL(string: value).flatMap { $0.scheme == nil ? nil : $0 }
        }

        if let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
           let readerURLString = components.queryItems?.first(where: { $0.name == "reader-url" })?.value {
            if let readerURL = absoluteURL(from: readerURLString) {
                return readerURL
            }
            if let decodedReaderURL = readerURLString.removingPercentEncoding,
               let readerURL = absoluteURL(from: decodedReaderURL) {
                return readerURL
            }
        }

        guard let range = absoluteString.range(of: "reader-url=") else {
            return nil
        }
        let rawReaderURL = String(absoluteString[range.upperBound...])
        if let decodedReaderURL = rawReaderURL.removingPercentEncoding,
           let readerURL = absoluteURL(from: decodedReaderURL) {
            return readerURL
        }
        return absoluteURL(from: rawReaderURL)
    }

    /// Extracts the snippet key embedded in either a snippet URL or a snippet loader URL.
    var snippetKey: String? {
        let absolute = absoluteString
        if absolute.hasPrefix("internal://local/load/reader") {
            return readerLoaderContentURL?.snippetKey
        }

        guard let scheme = scheme?.lowercased(),
              let parts = URLComponents(url: self, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil,
              let items = parts.queryItems, items.count == 1,
              items[0].name == "key", let key = items[0].value, !key.isEmpty else {
            return nil
        }
        switch scheme {
        case "internal":
            guard parts.host?.lowercased() == "local", parts.path == "/snippet" else { return nil }
        case "about":
            guard parts.host == nil, parts.path == "snippet" else { return nil }
        default:
            return nil
        }
        return key
    }
}
