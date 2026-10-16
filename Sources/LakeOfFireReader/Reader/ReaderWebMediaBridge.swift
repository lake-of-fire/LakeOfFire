import Foundation
import SwiftUIWebView
import LakeOfFireContent
import LakeOfFireCore
import WebKit

enum ReaderWebMediaKind: String, Codable, Sendable {
    case video
    case audio
    case unknown
}

enum ReaderWebMediaPlaybackKind: String, Sendable {
    case audioOnly
    case video
    case unknown
}

enum ReaderWebPlaybackEventName: String, Codable, Sendable {
    case play
    case pause
    case seeking
    case seeked
    case timeupdate
    case ratechange
    case volumechange
    case waiting
    case playing
    case stalled
    case ended
    case loadedmetadata
    case durationchange
    case emptied
    case error
    case enterpictureinpicture
    case leavepictureinpicture
    case presentationmodechanged
    case heartbeat
}

struct ReaderWebReadyState: Decodable, Sendable {
    let state: String
}

struct ReaderWebMediaInfo: Decodable, Sendable {
    let name: String
    let src: String
    let pageSrc: String
    let pageTitle: String
    let mimeType: String
    let duration: TimeInterval
    let detected: Bool
    let tagId: String
    let isInvisible: Bool
    let scriptDocumentID: String
    let contentLanguageIdentifier: String?
    let providerResourceID: String?

    enum CodingKeys: String, CodingKey {
        case name
        case src
        case pageSrc
        case pageTitle
        case mimeType
        case duration
        case detected
        case tagId
        case isInvisible = "invisible"
        case scriptDocumentID, contentLanguageIdentifier, providerResourceID
    }

    var sourceURL: URL? {
        URL(string: src)
    }

    var mediaKind: ReaderWebMediaKind {
        let normalized = mimeType.lowercased()
        if normalized.hasPrefix("audio/") {
            return .audio
        }
        if normalized.hasPrefix("video/") {
            return .video
        }

        switch sourceURL?.pathExtension.lowercased() {
        case "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus":
            return .audio
        case "mp4", "m4v", "mov", "webm":
            return .video
        default:
            return .unknown
        }
    }

    var playbackKind: ReaderWebMediaPlaybackKind {
        switch mediaKind {
        case .audio:
            return .audioOnly
        case .video:
            return .video
        case .unknown:
            return .unknown
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let pageSrc = try container.decode(String.self, forKey: .pageSrc)
        let rawSrc = try container.decodeIfPresent(String.self, forKey: .src) ?? ""

        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.src = Self.fixSchemelessURLs(src: rawSrc, pageSrc: pageSrc)
        self.pageSrc = pageSrc
        self.pageTitle = try container.decodeIfPresent(String.self, forKey: .pageTitle) ?? ""
        self.mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType) ?? ""
        self.duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        self.detected = try container.decodeIfPresent(Bool.self, forKey: .detected) ?? false
        self.tagId = try container.decode(String.self, forKey: .tagId)
        self.isInvisible = try container.decodeIfPresent(Bool.self, forKey: .isInvisible) ?? false
        self.scriptDocumentID = try container.decode(String.self, forKey: .scriptDocumentID)
        self.contentLanguageIdentifier = try container.decodeIfPresent(String.self, forKey: .contentLanguageIdentifier)
        self.providerResourceID = try container.decodeIfPresent(String.self, forKey: .providerResourceID)
    }

    static func fixSchemelessURLs(src: String, pageSrc: String) -> String {
        if src.hasPrefix("//") {
            return "\(URL(string: pageSrc)?.scheme ?? "https"):\(src)"
        }
        if src.hasPrefix("/"),
           let url = URL(string: src, relativeTo: URL(string: pageSrc))?.absoluteString {
            return url
        }
        return src
    }
}

struct ReaderWebPlaybackSnapshot: Decodable, Sendable {
    let tagId: String
    let pageSrc: String
    let pageTitle: String
    let src: String
    let currentSrc: String
    let mimeType: String
    let mediaType: ReaderWebMediaKind
    let currentTime: TimeInterval
    let duration: TimeInterval
    let paused: Bool
    let ended: Bool
    let scriptDocumentID: String
    let contentLanguageIdentifier: String?
    let providerResourceID: String?

    enum CodingKeys: String, CodingKey {
        case tagId
        case pageSrc
        case pageTitle
        case src
        case currentSrc
        case mimeType
        case mediaType
        case currentTime
        case duration
        case paused
        case ended
        case scriptDocumentID, contentLanguageIdentifier, providerResourceID
    }

    var effectiveSource: String {
        currentSrc.isEmpty ? src : currentSrc
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let pageSrc = try container.decode(String.self, forKey: .pageSrc)
        let src = try container.decodeIfPresent(String.self, forKey: .src) ?? ""
        let currentSrc = try container.decodeIfPresent(String.self, forKey: .currentSrc) ?? ""

        self.tagId = try container.decode(String.self, forKey: .tagId)
        self.pageSrc = pageSrc
        self.pageTitle = try container.decodeIfPresent(String.self, forKey: .pageTitle) ?? ""
        self.src = ReaderWebMediaInfo.fixSchemelessURLs(src: src, pageSrc: pageSrc)
        self.currentSrc = ReaderWebMediaInfo.fixSchemelessURLs(src: currentSrc, pageSrc: pageSrc)
        self.mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType) ?? ""
        self.mediaType = ReaderWebMediaKind(rawValue: try container.decodeIfPresent(String.self, forKey: .mediaType) ?? "") ?? .unknown
        self.currentTime = try container.decodeIfPresent(TimeInterval.self, forKey: .currentTime) ?? 0
        self.duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        self.paused = try container.decodeIfPresent(Bool.self, forKey: .paused) ?? true
        self.ended = try container.decodeIfPresent(Bool.self, forKey: .ended) ?? false
        self.scriptDocumentID = try container.decode(String.self, forKey: .scriptDocumentID)
        self.contentLanguageIdentifier = try container.decodeIfPresent(String.self, forKey: .contentLanguageIdentifier)
        self.providerResourceID = try container.decodeIfPresent(String.self, forKey: .providerResourceID)
    }
}

struct ReaderWebPlaybackEvent: Decodable, Sendable {
    let eventName: ReaderWebPlaybackEventName
    let snapshot: ReaderWebPlaybackSnapshot

    enum CodingKeys: String, CodingKey {
        case eventName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.eventName = try container.decode(ReaderWebPlaybackEventName.self, forKey: .eventName)
        self.snapshot = try ReaderWebPlaybackSnapshot(from: decoder)
    }
}

public struct ReaderWebMediaCandidateUpdate: Sendable {
    public let canonicalContentURL: URL
    public let pageURL: URL
    public let pageTitle: String
    public let tagID: String
    public let sourceURL: URL?
    public let mimeType: String
    public let duration: TimeInterval
    public let isInvisible: Bool
    public let playbackKindRawValue: String
    public let requestHeaders: [String: String]
    public let playbackOwner: ReaderMediaPlaybackOwner
    public let contentLanguageIdentifier: String?

    public init(
        canonicalContentURL: URL,
        pageURL: URL,
        pageTitle: String,
        tagID: String,
        sourceURL: URL?,
        mimeType: String,
        duration: TimeInterval,
        isInvisible: Bool,
        playbackKindRawValue: String,
        requestHeaders: [String: String] = [:],
        playbackOwner: ReaderMediaPlaybackOwner,
        contentLanguageIdentifier: String? = nil
    ) {
        self.canonicalContentURL = canonicalContentURL
        self.pageURL = pageURL
        self.pageTitle = pageTitle
        self.tagID = tagID
        self.sourceURL = sourceURL
        self.mimeType = mimeType
        self.duration = duration
        self.isInvisible = isInvisible
        self.playbackKindRawValue = playbackKindRawValue
        self.requestHeaders = requestHeaders
        self.playbackOwner = playbackOwner
        self.contentLanguageIdentifier = contentLanguageIdentifier
    }
}

public struct ReaderWebMediaPlaybackUpdate: Sendable {
    public let canonicalContentURL: URL
    public let pageURL: URL
    public let pageTitle: String
    public let tagID: String
    public let sourceURL: URL?
    public let eventNameRawValue: String
    public let currentTime: TimeInterval
    public let duration: TimeInterval
    public let isPlaying: Bool
    public let ended: Bool
    public let requestHeaders: [String: String]
    public let playbackOwner: ReaderMediaPlaybackOwner
    public let contentLanguageIdentifier: String?

    public init(
        canonicalContentURL: URL,
        pageURL: URL,
        pageTitle: String,
        tagID: String,
        sourceURL: URL?,
        eventNameRawValue: String,
        currentTime: TimeInterval,
        duration: TimeInterval,
        isPlaying: Bool,
        ended: Bool,
        requestHeaders: [String: String] = [:],
        playbackOwner: ReaderMediaPlaybackOwner,
        contentLanguageIdentifier: String? = nil
    ) {
        self.canonicalContentURL = canonicalContentURL
        self.pageURL = pageURL
        self.pageTitle = pageTitle
        self.tagID = tagID
        self.sourceURL = sourceURL
        self.eventNameRawValue = eventNameRawValue
        self.currentTime = currentTime
        self.duration = duration
        self.isPlaying = isPlaying
        self.ended = ended
        self.requestHeaders = requestHeaders
        self.playbackOwner = playbackOwner
        self.contentLanguageIdentifier = contentLanguageIdentifier
    }
}

public struct ReaderExternalMediaSubtitlesUpdate: Sendable {
    public let canonicalContentURL: URL
    public let pageURL: URL
    public let playbackOwner: ReaderMediaPlaybackOwner
    public let contentLanguageIdentifier: String?
    public let validatedRequest: ReaderValidatedCaptionRequest
    public let captionRequests: [ReaderValidatedCaptionRequest]

    public var providerVideoID: String? { validatedRequest.providerResourceID }
    public var subtitleURL: URL { validatedRequest.subtitleURL }
    public var languageCode: String { validatedRequest.languageIdentifier }
    public var isAutoGenerated: Bool { validatedRequest.isAutoGenerated }
    public var requestHeaders: [String: String] { [:] }

    init(canonicalContentURL: URL, pageURL: URL, playbackOwner: ReaderMediaPlaybackOwner, contentLanguageIdentifier: String?, requests: [ReaderValidatedCaptionRequest]) {
        precondition(!requests.isEmpty)
        self.canonicalContentURL = canonicalContentURL
        self.pageURL = pageURL
        self.playbackOwner = playbackOwner
        self.contentLanguageIdentifier = contentLanguageIdentifier
        self.captionRequests = requests
        self.validatedRequest = requests[0]
    }

    public func preferredCaption(for languageIdentifier: String?) -> ReaderValidatedCaptionRequest? {
        let preferred = ReaderTranscriptLanguage.normalizedIdentifier(languageIdentifier ?? contentLanguageIdentifier)
        let language = ReaderTranscriptLanguage.languageSubtag(preferred)
        let candidates = captionRequests.filter {
            preferred == "und" || ReaderTranscriptLanguage.languageSubtag($0.languageIdentifier) == language
        }
        return candidates.enumerated().min { lhs, rhs in
            func rank(_ request: ReaderValidatedCaptionRequest) -> Int {
                let exact = request.languageIdentifier == preferred
                return (request.isAutoGenerated ? 2 : 0) + (exact ? 0 : 1)
            }
            let left = rank(lhs.element), right = rank(rhs.element)
            return left == right ? lhs.offset < rhs.offset : left < right
        }?.element
    }
}

public extension Notification.Name {
    static let readerWebMediaCandidateDidUpdate = Notification.Name("ReaderWebMediaCandidateDidUpdate")
    static let readerWebMediaPlaybackDidUpdate = Notification.Name("ReaderWebMediaPlaybackDidUpdate")
    static let readerExternalMediaSubtitlesDidUpdate = Notification.Name("ReaderExternalMediaSubtitlesDidUpdate")
}

enum ReaderWebMediaBridgeMessage: Sendable {
    case readyState(ReaderWebReadyState)
    case media(ReaderWebMediaInfo)
    case playback(ReaderWebPlaybackEvent)
}

public enum ReaderWebMediaBridge {
    public static let messageHandlerName = "mediaHandler"

    public static var userScripts: [WebViewUserScript] {
        MainActor.assumeIsolated {
            [
                WebViewUserScript(source: mediaBridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page),
                ReaderYoutubeCaptionsUserScript.userScript,
            ]
        }
    }

    static func decode(message: WebViewMessage) -> ReaderWebMediaBridgeMessage? {
        guard let payload = message.body as? [String: Any] else {
            return nil
        }

        if payload["state"] != nil {
            return decode(ReaderWebReadyState.self, from: payload).map(ReaderWebMediaBridgeMessage.readyState)
        }

        if payload["messageKind"] as? String == "playback" {
            return decode(ReaderWebPlaybackEvent.self, from: payload).map(ReaderWebMediaBridgeMessage.playback)
        }

        return decode(ReaderWebMediaInfo.self, from: payload).map(ReaderWebMediaBridgeMessage.media)
    }

    @MainActor
    static func postCandidateUpdate(_ info: ReaderWebMediaInfo, message: WebViewMessage, scriptCaller: WebViewScriptCaller, currentPageURL: URL, contentLanguageIdentifier: String? = nil) {
        guard let context = admittedContext(message: message, scriptCaller: scriptCaller, currentPageURL: currentPageURL),
              let owner = ReaderWebMediaPlaybackRouter.shared.register(message: message, scriptCaller: scriptCaller, canonicalContentURL: context.canonicalURL, sourceURL: info.sourceURL, tagID: info.tagId, scriptDocumentID: info.scriptDocumentID, providerResourceID: info.providerResourceID, isVideo: info.playbackKind != .audioOnly) else { return }
        let update = ReaderWebMediaCandidateUpdate(canonicalContentURL: context.canonicalURL, pageURL: context.pageURL, pageTitle: info.pageTitle, tagID: info.tagId, sourceURL: info.sourceURL, mimeType: info.mimeType, duration: finiteNonnegative(info.duration), isInvisible: info.isInvisible, playbackKindRawValue: info.playbackKind.rawValue, requestHeaders: mediaRequestHeaders(from: message, pageURL: context.pageURL), playbackOwner: owner, contentLanguageIdentifier: contentLanguage(for: owner, native: contentLanguageIdentifier, observed: info.contentLanguageIdentifier))
        NotificationCenter.default.post(name: .readerWebMediaCandidateDidUpdate, object: nil, userInfo: ["update": update])
    }

    @MainActor
    static func postPlaybackUpdate(_ event: ReaderWebPlaybackEvent, message: WebViewMessage, scriptCaller: WebViewScriptCaller, currentPageURL: URL, contentLanguageIdentifier: String? = nil) {
        guard let context = admittedContext(message: message, scriptCaller: scriptCaller, currentPageURL: currentPageURL),
              let owner = ReaderWebMediaPlaybackRouter.shared.register(message: message, scriptCaller: scriptCaller, canonicalContentURL: context.canonicalURL, sourceURL: URL(string: event.snapshot.effectiveSource), tagID: event.snapshot.tagId, scriptDocumentID: event.snapshot.scriptDocumentID, providerResourceID: event.snapshot.providerResourceID, isVideo: event.snapshot.mediaType == .video) else { return }
        let update = ReaderWebMediaPlaybackUpdate(canonicalContentURL: context.canonicalURL, pageURL: context.pageURL, pageTitle: event.snapshot.pageTitle, tagID: event.snapshot.tagId, sourceURL: URL(string: event.snapshot.effectiveSource), eventNameRawValue: event.eventName.rawValue, currentTime: finiteNonnegative(event.snapshot.currentTime), duration: finiteNonnegative(event.snapshot.duration), isPlaying: !event.snapshot.paused && !event.snapshot.ended, ended: event.snapshot.ended, requestHeaders: mediaRequestHeaders(from: message, pageURL: context.pageURL), playbackOwner: owner, contentLanguageIdentifier: contentLanguage(for: owner, native: contentLanguageIdentifier, observed: event.snapshot.contentLanguageIdentifier))
        NotificationCenter.default.post(name: .readerWebMediaPlaybackDidUpdate, object: nil, userInfo: ["update": update])
    }

    @discardableResult
    @MainActor
    public static func postExternalSubtitlesUpdate(from message: WebViewMessage, scriptCaller: WebViewScriptCaller, currentPageURL: URL, contentLanguageIdentifier: String? = nil) -> Bool {
        guard let context = admittedContext(message: message, scriptCaller: scriptCaller, currentPageURL: currentPageURL),
              let status = VideoStatusMessage(fromMessage: message), let frameURL = message.requestURL,
              message.frameInfo.securityOrigin.protocol.lowercased() == "https",
              message.frameInfo.securityOrigin.host.lowercased() == frameURL.host?.lowercased(),
              let claimedFrameURL = status.pageURL,
              ReaderMediaResourceIdentity.canonicalURL(frameURL) == ReaderMediaResourceIdentity.canonicalURL(claimedFrameURL),
              let providerID = ReaderMediaResourceIdentity.youtubeResourceID(from: frameURL), providerID == status.providerVideoID,
              let owner = ReaderWebMediaPlaybackRouter.shared.captionOwner(message: message, scriptCaller: scriptCaller, resourceIdentity: ReaderMediaResourceIdentity.youtube(providerID), tagID: status.playbackInstanceID, scriptDocumentID: status.scriptDocumentID) else { return false }
        let requests = status.captionsOptions.prefix(64).compactMap { caption in
            ReaderValidatedCaptionRequest.youtube(playbackOwner: owner, providerFrameURL: frameURL, claimedResourceID: status.providerVideoID, subtitleURL: caption.baseURL, languageIdentifier: caption.languageCode, isAutoGenerated: caption.isAutoGenerated)
        }
        guard !requests.isEmpty else { return false }
        let update = ReaderExternalMediaSubtitlesUpdate(canonicalContentURL: context.canonicalURL, pageURL: context.pageURL, playbackOwner: owner, contentLanguageIdentifier: contentLanguage(for: owner, native: contentLanguageIdentifier, observed: status.contentLanguageIdentifier), requests: requests)
        NotificationCenter.default.post(name: .readerExternalMediaSubtitlesDidUpdate, object: nil, userInfo: ["update": update])
        return true
    }

    static func preferredCaptionOption(from options: [VideoStatusMessage.CaptionsOption], localeIdentifier: String = "und") -> VideoStatusMessage.CaptionsOption? {
        let language = ReaderTranscriptLanguage.normalizedIdentifier(localeIdentifier)
        return options.filter { language == "und" || ReaderTranscriptLanguage.languageSubtag($0.languageCode) == ReaderTranscriptLanguage.languageSubtag(language) }.min {
            let left = ($0.isAutoGenerated ? 2 : 0) + (ReaderTranscriptLanguage.normalizedIdentifier($0.languageCode) == language ? 0 : 1)
            let right = ($1.isAutoGenerated ? 2 : 0) + (ReaderTranscriptLanguage.normalizedIdentifier($1.languageCode) == language ? 0 : 1)
            return left < right
        }
    }

    @MainActor
    private static func admittedContext(message: WebViewMessage, scriptCaller: WebViewScriptCaller, currentPageURL: URL) -> (canonicalURL: URL, pageURL: URL)? {
        guard let token = message.javaScriptBindingToken, scriptCaller.currentJavaScriptBindingToken == token,
              let frameURL = message.requestURL, let frameScheme = frameURL.scheme?.lowercased(), ["https", "http", "file", "reader-file"].contains(frameScheme),
              !currentPageURL.isTranscriptURL,
              let topURL = message.mainDocumentURL ?? (message.isMainFrame ? frameURL : nil),
              ReaderMediaResourceIdentity.canonicalURL(topURL) == ReaderMediaResourceIdentity.canonicalURL(currentPageURL) else { return nil }
        return (MediaTranscript.canonicalContentURL(from: topURL), topURL)
    }

    @MainActor
    static func mediaRequestHeaders(from message: WebViewMessage, pageURL: URL) -> [String: String] {
        // Frame credentials belong to that frame, not to a page-supplied media
        // or caption endpoint. Only benign negotiation context crosses here.
        var headers = ["Accept": "video/*,audio/*,application/vnd.apple.mpegurl"]
        if let url = message.requestURL, ["http", "https"].contains(url.scheme ?? ""),
           let host = url.host, let scheme = url.scheme {
            headers["Referer"] = "\(scheme)://\(host)/"
        }
        return headers
    }

    private static func contentLanguage(for owner: ReaderMediaPlaybackOwner, native: String?, observed: String?) -> String? {
        let nativeLanguage = normalizedLanguage(native)
        let observedLanguage = normalizedLanguage(observed)
        // A provider's original/audio language describes the admitted media,
        // which can differ from the embedding article. Generic HTML language
        // remains a fallback behind the reader's content-language metadata.
        if owner.resourceIdentity.hasPrefix("provider:") {
            return observedLanguage ?? nativeLanguage
        }
        return nativeLanguage ?? observedLanguage
    }

    private static func normalizedLanguage(_ value: String?) -> String? {
        let normalized = ReaderTranscriptLanguage.normalizedIdentifier(value)
        return normalized == "und" ? nil : normalized
    }

    private static func finiteNonnegative(_ value: Double) -> Double { value.isFinite && value >= 0 ? value : 0 }

    private static func decode<T: Decodable>(_ type: T.Type, from payload: [String: Any]) -> T? {
        guard payload.count <= 48,
              payload.values.allSatisfy({ value in
                  guard let string = value as? String else { return value is NSNumber || value is NSNull }
                  return string.utf8.count <= 16_384
              }),
              JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed])
        else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static let mediaBridgeScript = #"""
    (function() {
      if (window.__manabiReaderMediaInstalled) {
        return;
      }
      window.__manabiReaderMediaInstalled = true;

      const handlerName = "mediaHandler";
      const telemetryHeartbeatKey = "__manabiReaderMediaHeartbeat";
      const telemetryAttachedKey = "__manabiReaderMediaAttached";
      const tagKey = "__manabiReaderMediaTagID";
      const scriptDocumentID = uuid();
      window.__manabiReaderMediaDocumentID = scriptDocumentID;
      const observedNodes = new Set();

      function providerResourceID(node) {
        if (!node || node.tagName !== 'VIDEO') return null;
        const player = node.closest && node.closest('.html5-video-player');
        if (!player || !['youtube.com', 'www.youtube.com', 'm.youtube.com', 'www.youtube-nocookie.com', 'youtube-nocookie.com'].includes(location.hostname)) return null;
        try { return player.getVideoData ? player.getVideoData().video_id || null : null; } catch (_) { return null; }
      }

      function contentLanguage(node) {
        const resourceID = providerResourceID(node);
        if (resourceID) {
          const hint = window.__manabiReaderMediaLanguage;
          return hint?.resourceID === resourceID ? hint.languageIdentifier || null : null;
        }
        return document.documentElement?.lang || null;
      }

      function post(payload) {
        try {
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[handlerName];
          if (handler && handler.postMessage) {
            handler.postMessage(payload);
          }
        } catch (error) {}
      }

      function context() {
        try {
          return {
            location: window.top.location.href,
            pageTitle: window.top.document.title || document.title || ""
          };
        } catch (error) {
          return {
            location: window.location.href,
            pageTitle: document.title || ""
          };
        }
      }

      function uuid() {
        if (window.crypto && window.crypto.randomUUID) {
          return window.crypto.randomUUID();
        }
        return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, function(c) {
          const r = Math.random() * 16 | 0;
          const v = c === "x" ? r : (r & 0x3 | 0x8);
          return v.toString(16);
        });
      }

      function clampDuration(value) {
        if (typeof value !== "number" || Number.isNaN(value)) {
          return 0;
        }
        if (!Number.isFinite(value)) {
          return 0;
        }
        return Math.max(0, value);
      }

      function clampUnitInterval(value) {
        if (typeof value !== "number" || Number.isNaN(value) || !Number.isFinite(value)) {
          return 0;
        }
        return Math.max(0, Math.min(1, value));
      }

      function mediaType(node) {
        if (!node) return "unknown";
        if (node.tagName === "AUDIO") return "audio";
        if (node.tagName === "VIDEO") return "video";
        return "unknown";
      }

      function tagNode(node) {
        if (!node) return;
        if (!node[tagKey]) {
          node[tagKey] = uuid();
        }
      }

      function effectiveSource(node) {
        if (!node) return "";
        const source = node.currentSrc || node.src || node.getAttribute("src") || "";
        if (source) return source;
        const childSource = node.querySelector && node.querySelector("source[src]");
        return childSource ? (childSource.src || childSource.getAttribute("src") || "") : "";
      }

      function mimeType(node) {
        if (!node) return "";
        const childSource = node.querySelector && node.querySelector("source[type]");
        return node.getAttribute("type") || (childSource ? (childSource.getAttribute("type") || "") : "");
      }

      function candidateName(node, ctx) {
        const name = (node && node.title) || "";
        return name.length > 0 ? name : (ctx.pageTitle || "");
      }

      function sendCandidate(node, detected) {
        if (!node) return;
        tagNode(node);
        const ctx = context();
        post({
          name: candidateName(node, ctx),
          src: effectiveSource(node),
          pageSrc: ctx.location,
          pageTitle: ctx.pageTitle,
          mimeType: mimeType(node),
          duration: clampDuration(node.duration),
          detected: !!detected,
          tagId: node[tagKey],
          scriptDocumentID: scriptDocumentID,
          contentLanguageIdentifier: contentLanguage(node),
          providerResourceID: providerResourceID(node),
          invisible: !node.parentNode
        });
      }

      function presentationMode(node) {
        try {
          if (document.pictureInPictureElement === node) {
            return "picture-in-picture";
          }
        } catch (error) {}
        if (node && typeof node.webkitPresentationMode === "string" && node.webkitPresentationMode !== "") {
          return node.webkitPresentationMode;
        }
        return "inline";
      }

      function shouldHeartbeat(node) {
        return !!node && !node.paused && !node.ended && node.readyState >= 2;
      }

      function stopHeartbeat(node) {
        if (node && node[telemetryHeartbeatKey]) {
          clearInterval(node[telemetryHeartbeatKey]);
          node[telemetryHeartbeatKey] = null;
        }
      }

      function sendPlayback(node, eventName) {
        if (!node) return;
        tagNode(node);
        const ctx = context();
        post({
          messageKind: "playback",
          eventName: eventName,
          scriptDocumentID: scriptDocumentID,
          contentLanguageIdentifier: contentLanguage(node),
          providerResourceID: providerResourceID(node),
          tagId: node[tagKey],
          pageSrc: ctx.location,
          pageTitle: ctx.pageTitle,
          src: node.src || "",
          currentSrc: effectiveSource(node),
          mimeType: mimeType(node),
          mediaType: mediaType(node),
          currentTime: clampDuration(node.currentTime),
          duration: clampDuration(node.duration),
          paused: !!node.paused,
          ended: !!node.ended,
          playbackRate: Number.isFinite(node.playbackRate) ? node.playbackRate : 1,
          muted: !!node.muted,
          volume: clampUnitInterval(node.volume),
          readyState: node.readyState || 0,
          networkState: node.networkState || 0,
          presentationMode: presentationMode(node),
          isInvisible: !node.parentNode
        });
      }

      function updateHeartbeat(node) {
        if (!shouldHeartbeat(node)) {
          stopHeartbeat(node);
          return;
        }
        if (node[telemetryHeartbeatKey]) {
          return;
        }
        node[telemetryHeartbeatKey] = setInterval(function() {
          if (!shouldHeartbeat(node)) {
            stopHeartbeat(node);
            return;
          }
          sendPlayback(node, "heartbeat");
        }, 750);
      }

      function attachTelemetry(node) {
        if (!node) return;
        observedNodes.add(node);
        if (node[telemetryAttachedKey]) return;
        node[telemetryAttachedKey] = true;

        [
          "play", "pause", "seeking", "seeked", "timeupdate", "ratechange",
          "volumechange", "waiting", "playing", "stalled", "ended",
          "loadedmetadata", "durationchange", "emptied", "error",
          "enterpictureinpicture", "leavepictureinpicture", "webkitpresentationmodechanged"
        ].forEach(function(name) {
          node.addEventListener(name, function() {
            const normalized = name === "webkitpresentationmodechanged" ? "presentationmodechanged" : name;
            sendPlayback(node, normalized);
            updateHeartbeat(node);
          }, true);
        });
      }

      function handleNode(node, detected) {
        if (!node) return;
        if (node.tagName === "SOURCE" && node.parentElement && (node.parentElement.tagName === "VIDEO" || node.parentElement.tagName === "AUDIO")) {
          node = node.parentElement;
        }
        if (!(node.tagName === "VIDEO" || node.tagName === "AUDIO")) {
          return;
        }
        tagNode(node);
        attachTelemetry(node);
        sendCandidate(node, detected);
      }

      function scanDocument(detected) {
        document.querySelectorAll("video, audio, source").forEach(function(node) {
          handleNode(node, detected);
        });
      }

      function observeMutations() {
        new MutationObserver(function(mutations) {
          mutations.forEach(function(mutation) {
            if (mutation.type === 'attributes') handleNode(mutation.target, true);
            mutation.removedNodes.forEach(function(node) {
              observedNodes.forEach(function(media) {
                if (!media.isConnected) { stopHeartbeat(media); observedNodes.delete(media); }
              });
            });
            mutation.addedNodes.forEach(function(node) {
              if (!(node instanceof HTMLElement)) return;
              handleNode(node, true);
              if (node.querySelectorAll) {
                node.querySelectorAll("video, audio, source").forEach(function(child) {
                  handleNode(child, true);
                });
              }
            });
          });
        }).observe(document.documentElement || document, { childList: true, subtree: true, attributes: true, attributeFilter: ['src', 'type'] });
      }

      function installHistoryHooks() {
        const pushState = history.pushState;
        history.pushState = function() {
          const result = pushState.apply(this, arguments);
          setTimeout(function() { scanDocument(true); }, 100);
          return result;
        };

        const replaceState = history.replaceState;
        history.replaceState = function() {
          const result = replaceState.apply(this, arguments);
          setTimeout(function() { scanDocument(true); }, 100);
          return result;
        };

        window.addEventListener("popstate", function() {
          setTimeout(function() { scanDocument(true); }, 100);
        }, true);
      }

      window.__manabiReaderMediaScan = function() { scanDocument(true); };
      window.addEventListener('pagehide', function() {
        observedNodes.forEach(function(node) {
          stopHeartbeat(node);
          if (node.__manabiReaderTranscriptSegment) node.__manabiReaderTranscriptSegment.cleanup();
        });
      });
      window.addEventListener('pageshow', function() {
        scanDocument(true);
        observedNodes.forEach(updateHeartbeat);
      });
      post({ state: "ready" });
      scanDocument(false);
      observeMutations();
      installHistoryHooks();
    })();
    """#
}

private struct ReaderYoutubeCaptionsUserScript {
    @MainActor
    static var userScript: WebViewUserScript {
        WebViewUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page, allowedDomains: Set(["youtube.com", "m.youtube.com", "www.youtube.com", "youtube-nocookie.com", "www.youtube-nocookie.com"]))
    }

    static let script = #"""
    (function() {
      'use strict';
      if (window.__manabiReaderCaptionsInstalled) return;
      window.__manabiReaderCaptionsInstalled = true;
      const allowedHosts = new Set(['youtube.com', 'm.youtube.com', 'www.youtube.com', 'youtube-nocookie.com', 'www.youtube-nocookie.com']);
      if (!allowedHosts.has(location.hostname) || location.protocol !== 'https:') return;
      let timer;
      let retries = 0;
      let route = location.href;
      let lastSent;
      let deliveryCount = 0;

      function resourceID() {
        const url = new URL(location.href);
        if (url.pathname === '/watch') return url.searchParams.get('v');
        const parts = url.pathname.split('/').filter(Boolean);
        return parts.length === 2 && ['embed', 'shorts', 'live'].includes(parts[0]) ? parts[1] : null;
      }
      function responseFor(player, id) {
        let response;
        try { response = player?.getPlayerResponse?.(); } catch (_) {}
        if (response?.videoDetails?.videoId === id) return response;
        if (window.ytInitialPlayerResponse?.videoDetails?.videoId === id) return window.ytInitialPlayerResponse;
        const scripts = Array.from(document.scripts).slice(0, 100);
        for (const script of scripts) {
          const text = script.textContent || '';
          if (text.length > 4 * 1024 * 1024 || !text.includes('ytInitialPlayerResponse')) continue;
          const match = text.match(/ytInitialPlayerResponse\s*=\s*(\{.*?\});/s);
          if (!match) continue;
          try { response = JSON.parse(match[1]); } catch (_) { continue; }
          if (response?.videoDetails?.videoId === id) return response;
        }
        return null;
      }
      function schedule(isDeliveryRetry) {
        if (timer || (!isDeliveryRetry && retries >= 30)) return;
        timer = setTimeout(function() { timer = undefined; retries++; send(); }, 500);
      }
      function send() {
        const id = resourceID();
        if (!id || !/^[A-Za-z0-9_-]{11}$/.test(id)) return;
        const player = document.getElementById('movie_player') || document.querySelector('.html5-video-player');
        const response = responseFor(player, id);
        const video = player?.querySelector('video');
        if (!response || !video) { schedule(); return; }
        let activeID;
        try { activeID = player.getVideoData?.().video_id; } catch (_) {}
        if (activeID !== id) { schedule(); return; }
        const renderer = response.captions?.playerCaptionsTracklistRenderer;
        const tracks = renderer?.captionTracks || [];
        const audioIndex = renderer?.defaultAudioTrackIndex || 0;
        const defaultCaptionIndex = renderer?.audioTracks?.[audioIndex]?.defaultCaptionTrackIndex;
        const originalLanguage = response.videoDetails?.defaultAudioLanguage || (typeof defaultCaptionIndex === 'number' ? tracks[defaultCaptionIndex]?.languageCode : null);
        window.__manabiReaderMediaLanguage = { resourceID: id, languageIdentifier: originalLanguage || null };
        window.__manabiReaderMediaScan?.();
        const tag = video.__manabiReaderMediaTagID;
        const documentID = window.__manabiReaderMediaDocumentID;
        if (!tag || !documentID) { schedule(); return; }
        const ordered = tracks.map((track, index) => ({ track, index })).sort((a, b) => Number(b.index === defaultCaptionIndex) - Number(a.index === defaultCaptionIndex));
        const captionsOptions = ordered.slice(0, 64).map(({track}) => ({
          label: track.name?.simpleText || track.name?.runs?.map(run => run.text || '').join('') || track.languageCode || '',
          languageCode: track.languageCode || '',
          kind: track.kind || 'standard',
          isAutoGenerated: track.kind === 'asr',
          baseURL: track.baseUrl || ''
        }));
        const signature = JSON.stringify([id, tag, documentID, originalLanguage, captionsOptions]);
        // Repeat a newly discovered track a few times: the media candidate and
        // caption notifications may be scheduled independently by WebKit.
        if (signature !== lastSent) { lastSent = signature; deliveryCount = 0; }
        if (deliveryCount >= 3) return;
        let topURL;
        try { topURL = window.top.location.href; } catch (_) { topURL = document.referrer || location.href; }
        const handler = window.webkit?.messageHandlers?.videoStatus;
        handler?.postMessage({ windowURL: topURL, pageURL: location.href, providerVideoID: id, playbackInstanceID: tag, scriptDocumentID: documentID, contentLanguageIdentifier: originalLanguage, captionsOptions });
        deliveryCount++;
        if (deliveryCount < 3) schedule(true);
      }
      const observer = new MutationObserver(function() {
        if (route !== location.href) {
          route = location.href; retries = 0; lastSent = undefined; deliveryCount = 0;
          if (timer) clearTimeout(timer);
          timer = undefined;
          send();
        }
      });
      observer.observe(document, {subtree: true, childList: true});
      window.addEventListener('yt-navigate-finish', function() { retries = 0; lastSent = undefined; deliveryCount = 0; send(); });
      window.addEventListener('pagehide', function() { observer.disconnect(); if (timer) clearTimeout(timer); });
      send();
    })();
    """#
}
