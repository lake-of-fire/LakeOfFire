import Foundation

/// Resource identity is durable; document and instance identity belong only to
/// the current presentation. Never persist a DOM tag as an offline cache key.
public struct ReaderMediaPlaybackOwner: Hashable, Codable, Sendable {
    public let canonicalContentURL: URL
    public let resourceIdentity: String
    public let documentID: String
    public let playbackInstanceID: String

    public init(canonicalContentURL: URL, resourceIdentity: String, documentID: String, playbackInstanceID: String) {
        self.canonicalContentURL = ReaderMediaResourceIdentity.canonicalURL(canonicalContentURL)
        self.resourceIdentity = resourceIdentity
        self.documentID = documentID
        self.playbackInstanceID = playbackInstanceID
    }
}

/// A transport candidate resolved from one admitted live media element. Its URL
/// may be short-lived; it must not replace the durable provider/resource key.
public struct ReaderMediaSourceCandidate: Sendable, Hashable {
    public let url: URL
    public var sourceURL: URL { url }
    public let mimeType: String?
    public let requestHeaders: [String: String]
    public let providerDocumentURL: URL?

    public init(url: URL, mimeType: String? = nil, requestHeaders: [String: String] = [:], providerDocumentURL: URL? = nil) {
        self.url = url
        self.mimeType = mimeType
        self.requestHeaders = requestHeaders
        self.providerDocumentURL = providerDocumentURL
    }
}

public enum ReaderMediaResourceIdentity {
    public static func canonicalURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "https" && components.port == 443)
            || (components.scheme == "http" && components.port == 80) { components.port = nil }
        return components.url ?? url
    }

    public static func direct(_ url: URL) -> String {
        "url:\(canonicalURL(url).absoluteString)"
    }

    public static func youtube(_ resourceID: String) -> String {
        "provider:youtube:\(resourceID)"
    }

    public static func youtubeResourceID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return nil }
        let parts = url.path.split(separator: "/")
        let value: String?
        if host == "youtu.be" {
            value = parts.count == 1 ? String(parts[0]) : nil
        } else if ["youtube.com", "www.youtube.com", "m.youtube.com", "youtube-nocookie.com", "www.youtube-nocookie.com"].contains(host) {
            if url.path == "/watch" {
                let ids = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "v" } ?? []
                value = ids.count == 1 ? ids[0].value : nil
            } else if parts.count == 2, ["embed", "shorts", "live"].contains(String(parts[0])) {
                value = String(parts[1])
            } else { value = nil }
        } else { value = nil }
        guard let value, value.count == 11,
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0) }) else { return nil }
        return value
    }
}

public enum ReaderTranscriptLanguage {
    /// One spelling is used before acquisition, Realm lookup, and persistence.
    /// Device/UI language is deliberately not an implicit content-language hint.
    public static func normalizedIdentifier(_ value: String?) -> String {
        guard let value else { return "und" }
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-")
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard !raw.isEmpty, raw.count <= 64, let language = parts.first,
              (2...8).contains(language.count), language.allSatisfy({ $0.isASCII && $0.isLetter }),
              parts.dropFirst().allSatisfy({ !$0.isEmpty && $0.count <= 8 && $0.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) }) else { return "und" }
        return Locale.canonicalLanguageIdentifier(from: raw).replacingOccurrences(of: "_", with: "-").lowercased()
    }

    public static func languageSubtag(_ value: String?) -> String {
        normalizedIdentifier(value).split(separator: "-").first.map(String.init) ?? "und"
    }
}
