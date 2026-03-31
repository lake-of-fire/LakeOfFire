import Foundation
import WebKit
import SwiftUIWebView
import BravePlaylist
import LakeOfFireCore
import LakeOfFireAdblock

public struct BravePlaylistWebScriptSet: Sendable {
    public let playlistScripts: PlaylistBuiltScriptSet
    public let userScripts: [WebViewUserScript]

    public var securityToken: String {
        playlistScripts.configuration.securityToken
    }

    public var processDocumentLoadJavaScript: String {
        playlistScripts.processDocumentLoadJavaScript
    }
}

public enum BravePlaylistWebScripts {
    public static func make(
        messageHandlerName: String,
        allowedDomains: Set<String> = [],
        configuration: PlaylistScriptConfiguration? = nil
    ) throws -> BravePlaylistWebScriptSet {
        let configuration = configuration ?? PlaylistScriptConfiguration(messageHandlerName: messageHandlerName)
        let playlistScripts = try PlaylistScriptEngine.makeScriptSet(configuration: configuration)
        let userScripts = [
            WebViewUserScript(
                source: playlistScripts.firefoxShimSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: .page,
                allowedDomains: allowedDomains
            ),
            WebViewUserScript(
                source: playlistScripts.mediaSourceOverrideSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: .page,
                allowedDomains: allowedDomains
            ),
            WebViewUserScript(
                source: playlistScripts.detectorSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: .page,
                allowedDomains: allowedDomains
            ),
        ]
        return BravePlaylistWebScriptSet(
            playlistScripts: playlistScripts,
            userScripts: userScripts
        )
    }
}

public enum BravePlaylistWebMessageDecoder {
    public static func decode(
        message: WebViewMessage,
        scriptSet: BravePlaylistWebScriptSet
    ) -> PlaylistScriptMessage? {
        PlaylistScriptMessageDecoder.decode(
            body: message.body,
            expectingSecurityToken: scriptSet.securityToken
        )
    }

    public static func decode(
        body: Any,
        scriptSet: BravePlaylistWebScriptSet
    ) -> PlaylistScriptMessage? {
        PlaylistScriptMessageDecoder.decode(
            body: body,
            expectingSecurityToken: scriptSet.securityToken
        )
    }
}

public enum BravePlaylistCandidateSelector {
    public static func preferredCandidate(
        from candidates: [PlaylistInfo],
        preferringAudio: Bool = true
    ) -> PlaylistInfo? {
        candidates.max { lhs, rhs in
            compare(lhs, rhs, preferringAudio: preferringAudio) == .orderedAscending
        }
    }

    private static func compare(
        _ lhs: PlaylistInfo,
        _ rhs: PlaylistInfo,
        preferringAudio: Bool
    ) -> ComparisonResult {
        let lhsScore = score(lhs, preferringAudio: preferringAudio)
        let rhsScore = score(rhs, preferringAudio: preferringAudio)
        if lhsScore != rhsScore {
            return lhsScore < rhsScore ? .orderedAscending : .orderedDescending
        }
        if lhs.duration != rhs.duration {
            return lhs.duration < rhs.duration ? .orderedAscending : .orderedDescending
        }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name)
    }

    private static func score(_ candidate: PlaylistInfo, preferringAudio: Bool) -> Int {
        var score = 0
        if !candidate.isInvisible {
            score += 8
        }
        if candidate.isHTTPSource {
            score += 8
        } else if !candidate.isBlobSource && !candidate.isDataSource {
            score += 4
        }
        if candidate.detected {
            score += 4
        }
        if candidate.duration > 0 {
            score += 2
        }
        if preferringAudio {
            switch candidate.kind {
            case .audio:
                score += 6
            case .video:
                score += 3
            case .unknown:
                break
            }
        } else if candidate.kind == .video {
            score += 6
        }
        return score
    }
}

public enum BravePlaylistRequestContextBuilder {
    public static func make(
        userAgent: String? = nil,
        referer: URL? = nil,
        cookies: [HTTPCookie] = []
    ) -> PlaylistMediaRequestContext {
        PlaylistMediaRequestContext(
            userAgent: userAgent,
            referer: referer,
            cookieHeader: cookieHeader(for: cookies)
        )
    }

    @MainActor
    public static func make(
        webView: WKWebView,
        referer: URL? = nil
    ) async -> PlaylistMediaRequestContext {
        let cookies = await cookies(from: webView.configuration.websiteDataStore.httpCookieStore)
        let userAgent = await resolveUserAgent(for: webView)
        return make(
            userAgent: userAgent,
            referer: referer ?? webView.url,
            cookies: cookies
        )
    }

    public static func cookieHeader(for cookies: [HTTPCookie]) -> String? {
        guard !cookies.isEmpty else {
            return nil
        }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    @MainActor
    private static func resolveUserAgent(for webView: WKWebView) async -> String? {
        if let customUserAgent = webView.customUserAgent, !customUserAgent.isEmpty {
            return customUserAgent
        }

        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("navigator.userAgent") { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
    }

    private static func cookies(from store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }
}

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
