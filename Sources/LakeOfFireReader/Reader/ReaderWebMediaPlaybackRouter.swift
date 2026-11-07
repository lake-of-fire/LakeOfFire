import Foundation
import LakeOfFireCore
import SwiftUIWebView
@preconcurrency import WebKit

/// Owns the connection from a transcript to one exact live media element.
/// Neither URL equality nor the globally shared player grants playback rights.
@MainActor
public final class ReaderWebMediaPlaybackRouter {
    public static let shared = ReaderWebMediaPlaybackRouter()

    @MainActor
    private final class Document {
        weak var caller: WebViewScriptCaller?
        let token: WebViewScriptCaller.JavaScriptBindingToken
        let id = UUID().uuidString
        init(caller: WebViewScriptCaller, token: WebViewScriptCaller.JavaScriptBindingToken) { self.caller = caller; self.token = token }
        var isCurrent: Bool { caller?.currentJavaScriptBindingToken == token }
    }
    @MainActor
    private final class Entry {
        let owner: ReaderMediaPlaybackOwner
        let document: Document
        var frame: WKFrameInfo?
        var sourceURL: URL?
        let tagID: String?
        let scriptDocumentID: String?
        var lastUsed = Date()
        var commandGeneration: UInt64 = 0
        init(owner: ReaderMediaPlaybackOwner, document: Document, frame: WKFrameInfo?, sourceURL: URL?, tagID: String?, scriptDocumentID: String?) {
            self.owner = owner; self.document = document; self.frame = frame; self.sourceURL = sourceURL; self.tagID = tagID; self.scriptDocumentID = scriptDocumentID
        }
    }
    private var documents: [WebViewScriptCaller.JavaScriptBindingToken: Document] = [:]
    private var entries: [ReaderMediaPlaybackOwner: Entry] = [:]

    public func documentID(for scriptCaller: WebViewScriptCaller) -> String? {
        prune()
        guard let token = scriptCaller.currentJavaScriptBindingToken else { return nil }
        return document(for: scriptCaller, token: token).id
    }

    public func isCurrent(owner: ReaderMediaPlaybackOwner) -> Bool {
        prune()
        return entries[owner]?.document.isCurrent == true
    }

    public func isAvailable(owner: ReaderMediaPlaybackOwner) -> Bool {
        isCurrent(owner: owner) && entries[owner]?.frame != nil
    }

    /// Runtime admission for a suspended acquisition. A child frame can replace
    /// its document without replacing the top-level WebView binding token.
    public func validate(owner: ReaderMediaPlaybackOwner) async -> Bool {
        guard isCurrent(owner: owner), let entry = entries[owner], let caller = entry.document.caller else { return false }
        guard let frame = entry.frame else { return true }
        guard let tagID = entry.tagID, let scriptDocumentID = entry.scriptDocumentID else { return false }
        let expectedSource = entry.sourceURL?.absoluteString ?? ""
        do {
            let result = try await caller.evaluateJavaScript(
                #"""
                if (window.__manabiReaderMediaDocumentID !== scriptDocumentID) return false;
                const matches = Array.from(document.querySelectorAll('video,audio')).filter(node => node.__manabiReaderMediaTagID === tagID);
                if (matches.length !== 1) return false;
                const media = matches[0];
                return media.isConnected && (media.currentSrc || media.src || media.querySelector('source[src]')?.src || '') === expectedSource;
                """#,
                arguments: ["tagID": tagID, "scriptDocumentID": scriptDocumentID, "expectedSource": expectedSource],
                in: frame,
                in: .page,
                requiring: entry.document.token
            )
            guard !Task.isCancelled, entries[owner] === entry, entry.document.isCurrent else { return false }
            if result as? Bool == true { return true }
        } catch { }
        if entries[owner] === entry { entries.removeValue(forKey: owner) }
        return false
    }

    public func belongs(owner: ReaderMediaPlaybackOwner, to scriptCaller: WebViewScriptCaller) -> Bool {
        isCurrent(owner: owner) && entries[owner]?.document.caller === scriptCaller
    }

    /// Resolves transport URLs from the element that owns this resource. A
    /// native restored selection may borrow one matching DOM source, but it may
    /// never adopt a generic page candidate or the shared player's current item.
    public func sourceCandidates(owner: ReaderMediaPlaybackOwner) async -> [ReaderMediaSourceCandidate] {
        guard isCurrent(owner: owner), let original = entries[owner] else { return [] }
        let sourceEntry: Entry
        if original.frame != nil {
            sourceEntry = original
        } else {
            let matches = entries.values.filter {
                $0.frame != nil && $0.document.isCurrent
                    && $0.owner.documentID == owner.documentID
                    && $0.owner.resourceIdentity == owner.resourceIdentity
            }
            // A replaced iframe can still share the main binding token. Prove
            // the concrete DOM documents before deciding there is one source.
            guard matches.count <= 8 else { return [] }
            var live: [Entry] = []
            for candidate in matches {
                if await validate(owner: candidate.owner) { live.append(candidate) }
                guard !Task.isCancelled, entries[owner] === original, original.document.isCurrent, live.count <= 1 else { return [] }
            }
            guard live.count == 1 else { return [] }
            sourceEntry = live[0]
        }
        guard let caller = sourceEntry.document.caller, let frame = sourceEntry.frame,
              let frameURL = frame.request.url, let tagID = sourceEntry.tagID,
              let scriptDocumentID = sourceEntry.scriptDocumentID else { return [] }
        let prefix = "provider:youtube:"
        let providerID: String
        if owner.resourceIdentity.hasPrefix(prefix) {
            providerID = String(owner.resourceIdentity.dropFirst(prefix.count))
            guard ReaderMediaResourceIdentity.youtubeResourceID(from: frameURL) == providerID,
                  frame.securityOrigin.protocol.lowercased() == "https",
                  frame.securityOrigin.host.lowercased() == frameURL.host?.lowercased() else { return [] }
        } else {
            providerID = ""
        }
        do {
            let value = try await caller.evaluateJavaScript(Self.sourceCandidateScript,
                arguments: ["tagID": tagID, "scriptDocumentID": scriptDocumentID,
                    "expectedSource": sourceEntry.sourceURL?.absoluteString ?? "", "providerID": providerID],
                in: frame, in: .page, requiring: sourceEntry.document.token)
            guard !Task.isCancelled, entries[owner] === original, entries[sourceEntry.owner] === sourceEntry,
                  original.document.isCurrent, sourceEntry.document.isCurrent,
                  let values = value as? [[String: Any]], values.count <= 12 else { return [] }
            var seen = Set<URL>()
            return values.compactMap { value in
                guard let raw = value["url"] as? String, raw.utf8.count <= 16_384,
                      let url = URL(string: raw), url.user == nil, url.password == nil,
                      ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                      seen.insert(url).inserted else { return nil }
                if providerID.isEmpty {
                    guard ReaderMediaResourceIdentity.direct(url) == sourceEntry.owner.resourceIdentity else { return nil }
                } else {
                    guard Self.isProviderStreamURL(url) else { return nil }
                }
                let mime = (value["mimeType"] as? String).flatMap { raw in
                    raw.utf8.count <= 256 && !raw.contains("\r") && !raw.contains("\n") ? raw : nil
                }
                var headers = ["Accept": mime ?? "video/*,audio/*,application/vnd.apple.mpegurl"]
                if !providerID.isEmpty { headers["Referer"] = "https://www.youtube.com/watch?v=\(providerID)" }
                else if var origin = URLComponents(url: frameURL, resolvingAgainstBaseURL: false), ["http", "https"].contains(origin.scheme ?? "") {
                    origin.user = nil; origin.password = nil; origin.path = "/"; origin.query = nil; origin.fragment = nil
                    headers["Referer"] = origin.url?.absoluteString
                }
                return ReaderMediaSourceCandidate(url: url, mimeType: mime, requestHeaders: headers,
                    providerDocumentURL: providerID.isEmpty ? nil : frameURL)
            }
        } catch { return [] }
    }

    private static func isProviderStreamURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.port == nil || url.port == 443,
              let host = url.host?.lowercased(), url.user == nil, url.password == nil else { return false }
        if host == "googlevideo.com" || host.hasSuffix(".googlevideo.com") {
            return url.path == "/videoplayback" || url.path.hasPrefix("/api/manifest/")
        }
        return ["youtube.com", "www.youtube.com", "m.youtube.com"].contains(host)
            && (url.path == "/videoplayback" || url.path.hasPrefix("/api/manifest/"))
    }

    /// Native/offline playback still belongs to the reader document that opened
    /// it. Core owns the native player; the router supplies only document fencing.
    @discardableResult
    public func register(owner: ReaderMediaPlaybackOwner, scriptCaller: WebViewScriptCaller) -> Bool {
        guard let token = scriptCaller.currentJavaScriptBindingToken else { return false }
        let document = document(for: scriptCaller, token: token)
        guard owner.documentID == document.id else { return false }
        entries[owner] = Entry(owner: owner, document: document, frame: nil, sourceURL: nil, tagID: nil, scriptDocumentID: nil)
        prune()
        return true
    }

    public func retire(owner: ReaderMediaPlaybackOwner) {
        entries.removeValue(forKey: owner)
    }

    public func retire(documentID: String) {
        entries = entries.filter { $0.key.documentID != documentID }
        documents = documents.filter { $0.value.id != documentID }
    }

    public func retire(for scriptCaller: WebViewScriptCaller) {
        let retired = Set(documents.values.filter { $0.caller === scriptCaller }.map(\.id))
        entries = entries.filter { !retired.contains($0.key.documentID) }
        documents = documents.filter { !retired.contains($0.value.id) }
    }

    func register(message: WebViewMessage, scriptCaller: WebViewScriptCaller, canonicalContentURL: URL, sourceURL: URL?, tagID: String, scriptDocumentID: String, providerResourceID: String?, isVideo: Bool) -> ReaderMediaPlaybackOwner? {
        guard let token = message.javaScriptBindingToken, scriptCaller.currentJavaScriptBindingToken == token,
              UUID(uuidString: scriptDocumentID) != nil, UUID(uuidString: tagID) != nil,
              let frameURL = message.requestURL else { return nil }
        let resourceIdentity: String
        if isVideo, let providerID = ReaderMediaResourceIdentity.youtubeResourceID(from: frameURL), providerID == providerResourceID {
            resourceIdentity = ReaderMediaResourceIdentity.youtube(providerID)
        } else if let sourceURL, ["https", "http", "file", "reader-file", "blob"].contains(sourceURL.scheme?.lowercased() ?? "") {
            resourceIdentity = ReaderMediaResourceIdentity.direct(sourceURL)
        } else { return nil }
        let document = document(for: scriptCaller, token: token)
        let owner = ReaderMediaPlaybackOwner(canonicalContentURL: canonicalContentURL, resourceIdentity: resourceIdentity, documentID: document.id, playbackInstanceID: scriptDocumentID + ":" + tagID)
        // A source replacement in the same DOM element retires its predecessor.
        entries = entries.filter { key, value in
            key == owner || key.documentID != owner.documentID || value.tagID != tagID || value.scriptDocumentID != scriptDocumentID
        }
        if let existing = entries[owner], existing.document.token == token {
            existing.frame = message.frameInfo
            existing.sourceURL = sourceURL
            existing.lastUsed = .now
        } else {
            entries[owner] = Entry(owner: owner, document: document, frame: message.frameInfo, sourceURL: sourceURL, tagID: tagID, scriptDocumentID: scriptDocumentID)
        }
        prune()
        return owner
    }

    func captionOwner(message: WebViewMessage, scriptCaller: WebViewScriptCaller, resourceIdentity: String, tagID: String?, scriptDocumentID: String?) -> ReaderMediaPlaybackOwner? {
        guard let token = message.javaScriptBindingToken, scriptCaller.currentJavaScriptBindingToken == token,
              let document = documents[token], let tagID, let scriptDocumentID, let frameURL = message.requestURL else { return nil }
        let matches = entries.values.filter { entry in
            entry.document === document && entry.owner.resourceIdentity == resourceIdentity && entry.tagID == tagID && entry.scriptDocumentID == scriptDocumentID
                && (entry.frame?.request.url).map(ReaderMediaResourceIdentity.canonicalURL) == ReaderMediaResourceIdentity.canonicalURL(frameURL)
        }
        return matches.count == 1 ? matches[0].owner : nil
    }

    @discardableResult
    public func seek(owner: ReaderMediaPlaybackOwner, to time: TimeInterval, play: Bool) async -> Bool {
        guard time.isFinite, time >= 0 else { return false }
        return await command(owner: owner, operation: "seek", start: time, end: nil, rewindTo: nil, play: play)
    }

    @discardableResult
    public func pause(owner: ReaderMediaPlaybackOwner) async -> Bool {
        await command(owner: owner, operation: "pause", start: nil, end: nil, rewindTo: nil, play: false)
    }

    @discardableResult
    public func playSegment(owner: ReaderMediaPlaybackOwner, start: TimeInterval, end: TimeInterval, rewindTo: TimeInterval? = nil) async -> Bool {
        guard start.isFinite, end.isFinite, start >= 0, end > start,
              rewindTo.map({ $0.isFinite && $0 >= 0 }) ?? true else { return false }
        return await command(owner: owner, operation: "segment", start: start, end: end, rewindTo: rewindTo, play: true)
    }

    private func command(owner: ReaderMediaPlaybackOwner, operation: String, start: TimeInterval?, end: TimeInterval?, rewindTo: TimeInterval?, play: Bool) async -> Bool {
        guard isAvailable(owner: owner), let entry = entries[owner], let caller = entry.document.caller,
              let frame = entry.frame, let scriptDocumentID = entry.scriptDocumentID, let tagID = entry.tagID else { return false }
        entry.commandGeneration &+= 1
        let generation = entry.commandGeneration
        let expectedSource = entry.sourceURL?.absoluteString ?? ""
        var arguments: [String: any Sendable] = ["operation": operation, "scriptDocumentID": scriptDocumentID, "tagID": tagID, "expectedSource": expectedSource, "play": play, "commandID": UUID().uuidString]
        if let start { arguments["start"] = start }
        if let end { arguments["end"] = end }
        if let rewindTo { arguments["rewindTo"] = rewindTo }
        do {
            let result = try await caller.evaluateJavaScript(Self.commandScript, arguments: arguments, in: frame, in: .page, requiring: entry.document.token)
            guard !Task.isCancelled, entries[owner] === entry, entry.document.isCurrent, entry.commandGeneration == generation else { return false }
            return result as? Bool == true
        } catch { return false }
    }

    private func document(for caller: WebViewScriptCaller, token: WebViewScriptCaller.JavaScriptBindingToken) -> Document {
        if let existing = documents[token], existing.caller === caller { return existing }
        let document = Document(caller: caller, token: token)
        documents[token] = document
        return document
    }

    private func prune() {
        documents = documents.filter { $0.value.isCurrent }
        entries = entries.filter { $0.value.document.isCurrent }
        while entries.count > 128, let victim = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key { entries.removeValue(forKey: victim) }
        let usedDocuments = Set(entries.keys.map(\.documentID))
        if documents.count > 32 {
            documents = documents.filter { usedDocuments.contains($0.value.id) }
        }
    }

    private static let commandScript = #"""
    if (window.__manabiReaderMediaDocumentID !== scriptDocumentID) return false;
    const nodes = Array.from(document.querySelectorAll('video,audio'));
    const matches = nodes.filter(node => node.__manabiReaderMediaTagID === tagID);
    if (matches.length !== 1) return false;
    const media = matches[0];
    const source = () => media.currentSrc || media.src || media.querySelector('source[src]')?.src || '';
    if (source() !== expectedSource) return false;
    const previous = media.__manabiReaderTranscriptSegment;
    if (previous) previous.cleanup();
    media.__manabiReaderTranscriptCommand = commandID;
    const isCurrent = () => window.__manabiReaderMediaDocumentID === scriptDocumentID && media.isConnected && media.__manabiReaderMediaTagID === tagID && media.__manabiReaderTranscriptCommand === commandID && source() === expectedSource;
    if (operation === 'pause') { media.pause(); return true; }
    if (!isCurrent()) return false;
    const startTime = Number(start);
    if (!Number.isFinite(startTime) || startTime < 0) return false;
    media.currentTime = Number.isFinite(media.duration) ? Math.min(startTime, media.duration) : startTime;
    if (operation === 'segment') {
      const endTime = Number(end);
      if (!Number.isFinite(endTime) || endTime <= startTime) return false;
      let timer;
      const segment = {
        cleanup() {
          media.removeEventListener('timeupdate', advance);
          media.removeEventListener('ended', finish);
          media.removeEventListener('emptied', cancel);
          media.removeEventListener('error', cancel);
          media.removeEventListener('pause', cancel);
          window.removeEventListener('pagehide', cancel);
          if (timer) clearInterval(timer);
          if (media.__manabiReaderTranscriptSegment === segment) delete media.__manabiReaderTranscriptSegment;
        }
      };
      function cancel() { segment.cleanup(); }
      function finish() {
        segment.cleanup();
        if (!isCurrent()) return;
        media.pause();
        if (typeof rewindTo !== 'undefined' && Number.isFinite(Number(rewindTo))) media.currentTime = Math.max(0, Number(rewindTo));
      }
      function advance() { if (!isCurrent()) { cancel(); return; } if (media.currentTime >= endTime) finish(); }
      media.__manabiReaderTranscriptSegment = segment;
      media.addEventListener('timeupdate', advance);
      media.addEventListener('ended', finish);
      media.addEventListener('emptied', cancel);
      media.addEventListener('error', cancel);
      media.addEventListener('pause', cancel);
      window.addEventListener('pagehide', cancel);
      timer = setInterval(advance, 80);
    }
    if (play) {
      try { await media.play(); }
      catch (_) {
        // A rejected older play promise cannot remove a successor's segment.
        if (media.__manabiReaderTranscriptCommand === commandID) {
          media.__manabiReaderTranscriptSegment?.cleanup();
        }
        return false;
      }
    }
    return isCurrent();
    """#

    private static let sourceCandidateScript = #"""
    if (window.__manabiReaderMediaDocumentID !== scriptDocumentID) return [];
    const matches = Array.from(document.querySelectorAll('video,audio')).filter(node => node.__manabiReaderMediaTagID === tagID);
    if (matches.length !== 1) return [];
    const media = matches[0];
    if (!media.isConnected) return [];
    const source = media.currentSrc || media.src || media.querySelector('source[src]')?.src || '';
    if (source !== expectedSource) return [];
    function urlFor(raw, provider) {
      if (typeof raw !== 'string' || raw.length > 16384) return null;
      let url;
      try { url = new URL(raw); } catch (_) { return null; }
      if (url.username || url.password) return null;
      if (!provider) return ['https:', 'http:'].includes(url.protocol) ? url.href : null;
      if (url.protocol !== 'https:' || (url.port && url.port !== '443')) return null;
      const host = url.hostname.toLowerCase();
      const ownedHost = host === 'googlevideo.com' || host.endsWith('.googlevideo.com') || ['youtube.com', 'www.youtube.com', 'm.youtube.com'].includes(host);
      if (!ownedHost || !(url.pathname === '/videoplayback' || url.pathname.startsWith('/api/manifest/'))) return null;
      return url.href;
    }
    if (!providerID) {
      const url = urlFor(source, false);
      return url ? [{url, mimeType: media.getAttribute('type') || media.querySelector('source[type]')?.type || null}] : [];
    }
    const player = media.closest('.html5-video-player');
    if (!player || player.classList.contains('ad-showing') || player.classList.contains('ad-interrupting')) return [];
    let current, response;
    try { current = player.getVideoData?.(); response = player.getPlayerResponse?.(); } catch (_) { return []; }
    if (current?.video_id !== providerID || response?.videoDetails?.videoId !== providerID || response?.playabilityStatus?.status !== 'OK') return [];
    const stream = response.streamingData;
    if (!stream || (Array.isArray(stream.licenseInfos) && stream.licenseInfos.length)) return [];
    const results = [];
    const seen = new Set();
    function add(raw, mimeType) {
      if (results.length >= 12) return;
      const url = urlFor(raw, true);
      if (!url || seen.has(url)) return;
      seen.add(url);
      results.push({url, mimeType: typeof mimeType === 'string' && mimeType.length <= 256 ? mimeType : null});
    }
    add(stream.hlsManifestUrl, 'application/vnd.apple.mpegurl');
    const formats = Array.isArray(stream.formats) ? stream.formats.slice(0, 64) : [];
    for (const format of formats) {
      if (!format || format.signatureCipher || format.cipher || format.drmTrackType || format.drmFamily || (Array.isArray(format.drmFamilies) && format.drmFamilies.length)) continue;
      const mime = typeof format.mimeType === 'string' ? format.mimeType.split(';', 1)[0].trim().toLowerCase() : '';
      if (!['video/mp4', 'video/webm', 'audio/mp4', 'audio/webm', 'audio/mpeg'].includes(mime)) continue;
      add(format.url, mime);
    }
    return results;
    """#
}
