import Foundation
import BravePlaylist

public typealias BraveMediaWebScriptSet = PlaylistWebScriptSet
public typealias BraveMediaWebScripts = PlaylistWebScripts
public typealias BraveMediaWebMessageDecoder = PlaylistWebMessageDecoder
public typealias BraveMediaCandidateSelector = PlaylistCandidateSelector
public typealias BraveMediaRequestContextBuilder = PlaylistRequestContextBuilder
public typealias BraveMediaPlaybackEvent = PlaylistPlaybackEvent
public typealias BraveMediaPlaybackEventName = PlaylistPlaybackEventName
public typealias BraveMediaPlaybackSnapshot = PlaylistPlaybackSnapshot
public typealias BraveMediaPlaybackPresentationMode = PlaylistPlaybackPresentationMode
public typealias BraveMediaPlaybackKind = PlaylistPlaybackKind

public struct BraveOfflineMediaItem: Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let pageURL: URL?
    public let resolvedMediaURL: URL
    public let localThumbnailURL: URL?
    public let byteCount: Int64?
    public let mimeType: String?
    public let playbackKind: PlaylistPlaybackKind
    public let downloadedAt: Date

    init(storedMedia: PlaylistStoredMedia) {
        self.id = storedMedia.id
        self.displayName = storedMedia.playlistInfo.preferredDisplayName
        self.pageURL = storedMedia.pageURL
        self.resolvedMediaURL = storedMedia.resolvedMediaURL
        self.localThumbnailURL = storedMedia.localThumbnailURL
        self.byteCount = storedMedia.byteCount
        self.mimeType = storedMedia.mimeType
        self.playbackKind = storedMedia.playlistInfo.playbackKind
        self.downloadedAt = storedMedia.downloadedAt
    }
}

public actor BraveOfflineMediaLibrary {
    private let library: PlaylistLibrary

    public init(library: PlaylistLibrary = PlaylistLibrary()) {
        self.library = library
    }

    public func allPersistentMedia() async throws -> [BraveOfflineMediaItem] {
        let stored = try await library.allStoredMedia(scope: .persistent)
        let sorted = stored.sorted {
            if $0.downloadedAt != $1.downloadedAt {
                return $0.downloadedAt > $1.downloadedAt
            }
            return $0.playlistInfo.preferredDisplayName.localizedCaseInsensitiveCompare($1.playlistInfo.preferredDisplayName) == .orderedAscending
        }

        var hydrated = [BraveOfflineMediaItem]()
        hydrated.reserveCapacity(sorted.count)
        for item in sorted {
            if let refreshed = try await library.ensureThumbnail(id: item.id) {
                hydrated.append(.init(storedMedia: refreshed))
            } else {
                hydrated.append(.init(storedMedia: item))
            }
        }
        return hydrated
    }

    public func deletePersistentMedia(id: String) async throws {
        try await library.deleteStoredMedia(id: id)
    }

    public func deleteAllPersistentMedia() async throws {
        try await library.deleteAllStoredMedia(scope: .persistent)
    }
}

public struct BraveDownloadedMedia: Sendable {
    public let fileURL: URL
    public let response: URLResponse
}

public enum BraveMediaDownloader {
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
    ) async throws -> BraveDownloadedMedia {
        let request = makeRequest(for: media)
        let (data, response) = try await session.data(for: request)
        let fileURL = temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(media.url.pathExtension.isEmpty ? "bin" : media.url.pathExtension)
        try data.write(to: fileURL, options: .atomic)
        return BraveDownloadedMedia(fileURL: fileURL, response: response)
    }
}
