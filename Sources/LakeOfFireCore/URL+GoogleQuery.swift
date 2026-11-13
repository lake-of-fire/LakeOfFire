import Foundation

public extension URL {
    /// Returns the unencoded Google search query parameter "q" if the URL is a Google search URL.
    var googleSearchQuery: String? {
        // Ensure host contains "google."
        guard let host = self.host, host.starts(with: "www.google.") || host.starts(with: "google.") else {
            return nil
        }
        // Decode form parameter names and values once. Keeping the encoded
        // value until after '+' replacement preserves literal %2B characters.
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let percentEncodedQuery = components.percentEncodedQuery else {
            return nil
        }
        for pair in percentEncodedQuery.split(separator: "&", omittingEmptySubsequences: false) {
            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawName = pieces.first else { continue }
            let nameWithSpaces = rawName.replacingOccurrences(of: "+", with: " ")
            guard nameWithSpaces.removingPercentEncoding == "q" else { continue }

            let rawValue = pieces.count > 1 ? String(pieces[1]) : ""
            let withSpaces = rawValue.replacingOccurrences(of: "+", with: " ")
            return withSpaces.removingPercentEncoding ?? withSpaces
        }
        return nil
    }
}
