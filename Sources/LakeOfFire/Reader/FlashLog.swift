import Foundation

internal func flashURLDescription(_ url: URL?) -> String {
    guard let url else { return "<nil>" }
    if url.absoluteString == "about:blank" { return "about:blank" }
    if let scheme = url.scheme?.lowercased(), scheme == "internal" {
        // Avoid logging query/path for internal loader/snippet URLs.
        let host = url.host ?? "<nil>"
        return "internal://\(host)"
    }
    if let scheme = url.scheme?.lowercased(), let host = url.host, !scheme.isEmpty, !host.isEmpty {
        return "\(scheme)://\(host)"
    }
    if let scheme = url.scheme?.lowercased(), !scheme.isEmpty {
        return "\(scheme):"
    }
    return url.absoluteString
}

