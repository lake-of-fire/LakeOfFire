import Foundation

public extension URL {
    var isSnippetURL: Bool {
        return absoluteString.hasPrefix("internal://local/snippet?key=")
    }

    /// Extracts the snippet key embedded in either a snippet URL or a snippet loader URL.
    var snippetKey: String? {
        let absolute = absoluteString
        if absolute.hasPrefix("internal://local/load/reader") {
            if let components = URLComponents(string: absolute),
               let readerURLString = components.queryItems?.first(where: { $0.name == "reader-url" })?.value {
                let decodedReaderURL = readerURLString.removingPercentEncoding ?? readerURLString
                if let readerURL = URL(string: decodedReaderURL),
                   let key = readerURL.snippetKey {
                    return key
                }
            }
            if let range = absolute.range(of: "reader-url=") {
                let rawURL = String(absolute[range.upperBound...]).removingPercentEncoding ?? ""
                if let readerURL = URL(string: rawURL),
                   let key = readerURL.snippetKey {
                    return key
                }
            }
            return nil
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
