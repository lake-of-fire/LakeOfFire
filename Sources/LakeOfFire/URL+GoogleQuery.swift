import Foundation

public extension URL {
    var googleSearchQuery: String? {
        guard let host = host,
              host.starts(with: "www.google.") || host.starts(with: "google.") else {
            return nil
        }
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              let rawValue = queryItems.first(where: { $0.name == "q" })?.value else {
            return nil
        }
        let withSpaces = rawValue.replacingOccurrences(of: "+", with: " ")
        return withSpaces.removingPercentEncoding ?? withSpaces
    }
}
