import Foundation

public extension URL {
    var isSnippetURL: Bool {
        return absoluteString.hasPrefix("internal://local/snippet?key=")
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
}
