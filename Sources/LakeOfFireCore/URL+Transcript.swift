import Foundation

public extension URL {
    static func transcriptPageURL(key: String, contentURL: URL? = nil) -> URL? {
        guard isValidTranscriptAssetKey(key) else { return nil }
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
        guard isValidTranscriptAssetKey(key) else { return nil }
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
        scheme == TranscriptReaderProtocol.urlScheme && host == "local" && user == nil && password == nil && port == nil && fragment == nil
    }

    var isTranscriptPageURL: Bool {
        isTranscriptURL && path.split(separator: "/").count == 2 && path.hasPrefix("/page/")
    }

    var isTranscriptVTTURL: Bool {
        isTranscriptURL && path.split(separator: "/").count == 2 && path.hasPrefix("/vtt/")
    }

    var transcriptAssetKey: String? {
        guard isTranscriptPageURL || isTranscriptVTTURL else { return nil }
        let component = path.split(separator: "/").last.map(String.init)
        guard let component, Self.isValidTranscriptAssetKey(component) else { return nil }
        return component
    }

    private static func isValidTranscriptAssetKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 256 && key.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }
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

