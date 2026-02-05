import Foundation

public extension URL {
    /// Returns the unencoded Google search query parameter "q" if the URL is a Google search URL.
    var googleSearchQuery: String? {
        // Ensure host contains "google."
        guard let host = self.host, host.starts(with: "www.google.") || host.starts(with: "google.") else {
            return nil
        }
        // Parse components and find "q" parameter
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              let rawValue = queryItems.first(where: { $0.name == "q" })?.value else {
            return nil
        }
        // Convert '+' signs to spaces and decode percent escapes
        let withSpaces = rawValue.replacingOccurrences(of: "+", with: " ")
        return withSpaces.removingPercentEncoding ?? withSpaces
    }
}
