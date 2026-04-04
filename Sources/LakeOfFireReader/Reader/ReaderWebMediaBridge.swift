import Foundation
import SwiftUIWebView
import LakeOfFireContent

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
        self.tagId = try container.decodeIfPresent(String.self, forKey: .tagId) ?? UUID().uuidString
        self.isInvisible = try container.decodeIfPresent(Bool.self, forKey: .isInvisible) ?? false
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
    }

    var effectiveSource: String {
        currentSrc.isEmpty ? src : currentSrc
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let pageSrc = try container.decode(String.self, forKey: .pageSrc)
        let src = try container.decodeIfPresent(String.self, forKey: .src) ?? ""
        let currentSrc = try container.decodeIfPresent(String.self, forKey: .currentSrc) ?? ""

        self.tagId = try container.decodeIfPresent(String.self, forKey: .tagId) ?? UUID().uuidString
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

    public init(
        canonicalContentURL: URL,
        pageURL: URL,
        pageTitle: String,
        tagID: String,
        sourceURL: URL?,
        mimeType: String,
        duration: TimeInterval,
        isInvisible: Bool,
        playbackKindRawValue: String
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
        ended: Bool
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
    }
}

public struct ReaderExternalMediaSubtitlesUpdate: Sendable {
    public let canonicalContentURL: URL
    public let pageURL: URL
    public let providerVideoID: String?
    public let subtitleURL: URL
    public let languageCode: String
    public let isAutoGenerated: Bool

    public init(
        canonicalContentURL: URL,
        pageURL: URL,
        providerVideoID: String?,
        subtitleURL: URL,
        languageCode: String,
        isAutoGenerated: Bool
    ) {
        self.canonicalContentURL = canonicalContentURL
        self.pageURL = pageURL
        self.providerVideoID = providerVideoID
        self.subtitleURL = subtitleURL
        self.languageCode = languageCode
        self.isAutoGenerated = isAutoGenerated
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
        [
            ReaderYoutubeCaptionsUserScript.userScript,
            WebViewUserScript(source: swizzlerScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page),
            WebViewUserScript(source: mediaBridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page),
        ]
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

    static func postCandidateUpdate(_ info: ReaderWebMediaInfo) {
        guard let pageURL = URL(string: info.pageSrc) else { return }

        let canonicalContentURL = MediaTranscript.canonicalContentURL(from: pageURL)
        let update = ReaderWebMediaCandidateUpdate(
            canonicalContentURL: canonicalContentURL,
            pageURL: pageURL,
            pageTitle: info.pageTitle,
            tagID: info.tagId,
            sourceURL: URL(string: info.src),
            mimeType: info.mimeType,
            duration: info.duration,
            isInvisible: info.isInvisible,
            playbackKindRawValue: info.playbackKind.rawValue
        )

        NotificationCenter.default.post(
            name: .readerWebMediaCandidateDidUpdate,
            object: nil,
            userInfo: ["update": update]
        )
    }

    static func postPlaybackUpdate(_ event: ReaderWebPlaybackEvent) {
        guard let pageURL = URL(string: event.snapshot.pageSrc) else { return }

        let canonicalContentURL = MediaTranscript.canonicalContentURL(from: pageURL)
        let update = ReaderWebMediaPlaybackUpdate(
            canonicalContentURL: canonicalContentURL,
            pageURL: pageURL,
            pageTitle: event.snapshot.pageTitle,
            tagID: event.snapshot.tagId,
            sourceURL: URL(string: event.snapshot.effectiveSource),
            eventNameRawValue: event.eventName.rawValue,
            currentTime: event.snapshot.currentTime,
            duration: event.snapshot.duration,
            isPlaying: !event.snapshot.paused && !event.snapshot.ended,
            ended: event.snapshot.ended
        )

        NotificationCenter.default.post(
            name: .readerWebMediaPlaybackDidUpdate,
            object: nil,
            userInfo: ["update": update]
        )
    }

    public static func postExternalSubtitlesUpdate(_ update: ReaderExternalMediaSubtitlesUpdate) {
        NotificationCenter.default.post(
            name: .readerExternalMediaSubtitlesDidUpdate,
            object: nil,
            userInfo: ["update": update]
        )
    }

    private static func decode<T: Decodable>(_ type: T.Type, from payload: [String: Any]) -> T? {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed])
        else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static let swizzlerScript = #"""
    (function() {
      delete window.MediaSource;
      delete window.WebKitMediaSource;
      delete window.ManagedMediaSource;
    })();
    """#

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
          return Number.MAX_VALUE;
        }
        return value;
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
        if (!node || node[telemetryAttachedKey]) return;
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
        }).observe(document.documentElement || document, { childList: true, subtree: true });
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

      post({ state: "ready" });
      scanDocument(false);
      observeMutations();
      installHistoryHooks();
    })();
    """#
}

private struct ReaderYoutubeCaptionsUserScript {
    static let userScript = WebViewUserScript(
        source: script,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false,
        in: .page,
        allowedDomains: Set(["youtube.com", "m.youtube.com", "www.youtube.com"])
    )

    static let script = #"""
    (function() {
      'use strict';

      function extractCaptionsFromPlayerResponse(playerResponse) {
        if (!playerResponse || !playerResponse.captions) {
          return [];
        }

        const tracks = playerResponse.captions.playerCaptionsTracklistRenderer.captionTracks || [];
        return tracks.map(track => ({
          label: track.name.simpleText,
          languageCode: track.languageCode,
          kind: track.kind || 'standard',
          isAutoGenerated: track.kind === 'asr',
          baseURL: track.baseUrl
        }));
      }

      function parseResponse() {
        const scripts = Array.from(document.getElementsByTagName('script'));
        const playerScript = scripts.find(script => script.textContent.includes('ytInitialPlayerResponse = '));
        if (!playerScript) {
          return null;
        }

        const match = playerScript.textContent.match(/ytInitialPlayerResponse\s*=\s*(\{.*?\});/s);
        if (!match) {
          return null;
        }

        return JSON.parse(match[1]);
      }

      function sendCaptions() {
        if (!["youtube.com", "m.youtube.com", "www.youtube.com"].includes(window.location.host)) {
          return;
        }

        const playerResponse = parseResponse();
        if (!playerResponse) {
          setTimeout(sendCaptions, 500);
          return;
        }

        const payload = {
          windowURL: window.top.location.href,
          pageURL: document.location.href,
          providerVideoID: new URL(location.href).searchParams.get('v'),
          captionsOptions: extractCaptionsFromPlayerResponse(playerResponse),
        };

        const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.videoStatus;
        if (handler && handler.postMessage) {
          handler.postMessage(payload);
        }
      }

      let lastUrl = location.href;
      new MutationObserver(() => {
        const currentUrl = location.href;
        if (currentUrl !== lastUrl) {
          lastUrl = currentUrl;
          sendCaptions();
        }
      }).observe(document, { subtree: true, childList: true });

      sendCaptions();
    })();
    """#
}
