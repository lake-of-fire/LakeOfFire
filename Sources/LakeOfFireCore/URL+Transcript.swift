import Foundation

public extension URL {
    static func transcriptPageURL(key: String, contentURL: URL? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = TranscriptReaderProtocol.urlScheme
        components.host = "local"
        components.path = "/page/\(key)"
        if let contentURL {
            components.queryItems = [
                URLQueryItem(name: "content-url", value: contentURL.absoluteString)
            ]
        }
        return components.url
    }

    static func transcriptVTTURL(key: String, contentURL: URL? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = TranscriptReaderProtocol.urlScheme
        components.host = "local"
        components.path = "/vtt/\(key)"
        if let contentURL {
            components.queryItems = [
                URLQueryItem(name: "content-url", value: contentURL.absoluteString)
            ]
        }
        return components.url
    }

    var isTranscriptURL: Bool {
        scheme == TranscriptReaderProtocol.urlScheme && host == "local"
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
