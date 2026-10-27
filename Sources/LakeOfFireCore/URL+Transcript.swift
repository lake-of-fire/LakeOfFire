import Foundation

public extension URL {
    static func transcriptPageURL(key: String, contentURL: URL? = nil, backingContentURL: URL? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = TranscriptReaderProtocol.urlScheme
        components.host = "local"
        components.path = "/page/\(key)"
        if let contentURL {
            components.queryItems = [
                URLQueryItem(name: "content-url", value: contentURL.absoluteString)
            ]
        }
        if let backingContentURL {
            guard backingContentURL.isTranscriptContentURL else { return nil }
            components.queryItems = (components.queryItems ?? []) + [
                URLQueryItem(name: "transcript-content-url", value: backingContentURL.absoluteString)
            ]
        }
        return components.url
    }

    static func transcriptVTTURL(key: String, contentURL: URL? = nil, backingContentURL: URL? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = TranscriptReaderProtocol.urlScheme
        components.host = "local"
        components.path = "/vtt/\(key)"
        if let contentURL {
            components.queryItems = [
                URLQueryItem(name: "content-url", value: contentURL.absoluteString)
            ]
        }
        if let backingContentURL {
            guard backingContentURL.isTranscriptContentURL else { return nil }
            components.queryItems = (components.queryItems ?? []) + [
                URLQueryItem(name: "transcript-content-url", value: backingContentURL.absoluteString)
            ]
        }
        return components.url
    }

    var isTranscriptURL: Bool {
        scheme == TranscriptReaderProtocol.urlScheme && host == "local"
    }

    /// A stable derived-content identity, never a serving route or source URL.
    static func transcriptContentIdentityURL(key: String) -> URL? {
        guard key.utf8.count == 64,
              key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return URL(string: "transcript://local/content/\(key)")
    }

    var isTranscriptContentURL: Bool {
        guard isTranscriptURL,
              let key = path.split(separator: "/").last,
              let expected = URL.transcriptContentIdentityURL(key: String(key)) else { return false }
        return absoluteString == expected.absoluteString
    }

    /// Only native transcript identities may participate in Reader matching.
    /// The original `content-url` query remains provenance, not mutation identity.
    var transcriptBackingContentURL: URL? {
        guard isTranscriptPageURL,
              let components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems?.filter { $0.name == "transcript-content-url" } ?? []
        guard items.count == 1, let value = items[0].value,
              let url = URL(string: value), url.isTranscriptContentURL else { return nil }
        return url
    }

    var isTranscriptPageURL: Bool {
        isTranscriptURL && path.hasPrefix("/page/")
    }

    var isTranscriptVTTURL: Bool {
        isTranscriptURL && path.hasPrefix("/vtt/")
    }

    var transcriptAssetKey: String? {
        guard isTranscriptPageURL || isTranscriptVTTURL else { return nil }
        let component = path.split(separator: "/").last.map(String.init)
        return component?.isEmpty == false ? component : nil
    }

    /// Original source provenance. This URL is never the derived Reader identity.
    var transcriptContentURL: URL? {
        guard isTranscriptURL,
              let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "content-url" })?.value
        else {
            return nil
        }
        return URL(string: value)
    }
}
