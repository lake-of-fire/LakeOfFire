import Foundation

public extension URL {
    var googleSearchQuery: String? {
        guard let host = host,
              host.starts(with: "www.google.") || host.starts(with: "google.") else {
            return nil
        }
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let percentEncodedQuery = components.percentEncodedQuery else {
            return nil
        }

        for pair in percentEncodedQuery.split(separator: "&", omittingEmptySubsequences: false) {
            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawName = pieces.first else { continue }
            let name = rawName.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(rawName)
            guard name == "q" else { continue }

            let rawValue = pieces.count > 1 ? String(pieces[1]) : ""
            let withSpaces = rawValue.replacingOccurrences(of: "+", with: " ")
            return withSpaces.removingPercentEncoding ?? withSpaces
        }

        return nil
    }
}
