import Foundation
import BravePlaylist

public typealias BravePlaylistWebScriptSet = PlaylistWebScriptSet
public typealias BravePlaylistWebScripts = PlaylistWebScripts
public typealias BravePlaylistWebMessageDecoder = PlaylistWebMessageDecoder
public typealias BravePlaylistCandidateSelector = PlaylistCandidateSelector
public typealias BravePlaylistRequestContextBuilder = PlaylistRequestContextBuilder

public struct BravePlaylistDownloadedMedia: Sendable {
    public let fileURL: URL
    public let response: URLResponse
}

public enum BravePlaylistMediaDownloader {
    public static func makeRequest(for media: PlaylistResolvedMedia) -> URLRequest {
        var request = URLRequest(url: media.url)
        for (name, value) in media.requestHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    public static func download(
        _ media: PlaylistResolvedMedia,
        using session: URLSession = .shared,
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) async throws -> BravePlaylistDownloadedMedia {
        let request = makeRequest(for: media)
        let (data, response) = try await session.data(for: request)
        let fileURL = temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(media.url.pathExtension.isEmpty ? "bin" : media.url.pathExtension)
        try data.write(to: fileURL, options: .atomic)
        return BravePlaylistDownloadedMedia(fileURL: fileURL, response: response)
    }
}
