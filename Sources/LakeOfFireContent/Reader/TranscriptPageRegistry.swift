import Foundation
import LakeOfFireCore

public struct TranscriptPageAsset: Sendable, Hashable {
    public struct Cue: Sendable, Hashable {
        public let identifier: String?
        public let startTimestamp: String
        public let endTimestamp: String
        public let text: String

        public init(
            identifier: String? = nil,
            startTimestamp: String,
            endTimestamp: String,
            text: String
        ) {
            self.identifier = identifier
            self.startTimestamp = startTimestamp
            self.endTimestamp = endTimestamp
            self.text = text
        }
    }

    public let key: String
    public let canonicalContentURL: URL
    public let title: String
    public let html: String
    public let webVTT: String?
    public let createdAt: Date
    public let languageIdentifier: String
    public let playbackOwner: ReaderMediaPlaybackOwner?
    public let mediaSourceURL: URL?

    public init(
        key: String,
        canonicalContentURL: URL,
        title: String,
        html: String,
        webVTT: String? = nil,
        createdAt: Date = .now,
        languageIdentifier: String = "und",
        playbackOwner: ReaderMediaPlaybackOwner? = nil,
        mediaSourceURL: URL? = nil
    ) {
        self.key = key
        self.canonicalContentURL = canonicalContentURL
        self.title = title
        self.html = html
        self.webVTT = webVTT
        self.createdAt = createdAt
        self.languageIdentifier = ReaderTranscriptLanguage.normalizedIdentifier(languageIdentifier)
        self.playbackOwner = playbackOwner
        self.mediaSourceURL = mediaSourceURL
    }

    public var pageURL: URL? {
        .transcriptPageURL(key: key, contentURL: canonicalContentURL)
    }

    public var webVTTURL: URL? {
        .transcriptVTTURL(key: key, contentURL: canonicalContentURL)
    }

    public static func makeHTML(
        title: String,
        canonicalContentURL: URL,
        cues: [Cue],
        languageIdentifier: String = "und"
    ) -> String {
        let cueMarkup = cues.enumerated().map { index, cue -> String in
            let identifierAttribute = cue.identifier.map {
                #" data-transcript-cue-id="\#(escapeHTML($0))""#
            } ?? ""
            return """
            <p class="reader-transcript-cue" data-transcript-cue-index="\(index)" data-transcript-start="\(escapeHTML(cue.startTimestamp))" data-transcript-end="\(escapeHTML(cue.endTimestamp))"\(identifierAttribute)>\(escapeHTML(cue.text))</p>
            """
        }.joined(separator: "\n")

        return """
        <!doctype html>
        <html lang="\(escapeHTML(ReaderTranscriptLanguage.normalizedIdentifier(languageIdentifier)))">
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(escapeHTML(title))</title>
            <style>
                body {
                    margin: 0;
                    font: -apple-system-body;
                    line-height: 1.6;
                }
                main#reader-content {
                    max-width: 44rem;
                    margin: 0 auto;
                    padding: 1.5rem 1.25rem 4rem;
                }
                .reader-transcript-eyebrow {
                    margin: 0 0 0.75rem;
                    font-size: 0.875rem;
                    color: rgba(120, 120, 128, 1);
                    text-transform: uppercase;
                    letter-spacing: 0.08em;
                }
                h1.reader-transcript-title {
                    margin: 0 0 1rem;
                    font-size: 1.8rem;
                    line-height: 1.2;
                }
                p.reader-transcript-source {
                    margin: 0 0 2rem;
                    color: rgba(120, 120, 128, 1);
                    word-break: break-all;
                }
                p.reader-transcript-cue {
                    margin: 0 0 1rem;
                    white-space: pre-wrap;
                }
            </style>
        </head>
        <body data-mnb-transcript-page="true">
            <main id="reader-content" class="reader-transcript-content">
                <p class="reader-transcript-eyebrow">Transcript</p>
                <h1 class="reader-transcript-title">\(escapeHTML(title))</h1>
                <p class="reader-transcript-source">\(escapeHTML(canonicalContentURL.absoluteString))</p>
                \(cueMarkup)
            </main>
        </body>
        </html>
        """
    }

    public static func cues(fromWebVTT webVTT: String) -> [Cue] {
        guard let document = try? ReaderTranscriptDocument(webVTT: webVTT) else { return [] }
        return document.cues.map { cue in
            Cue(identifier: cue.identifier, startTimestamp: ReaderTranscriptDocument.timestamp(cue.start), endTimestamp: ReaderTranscriptDocument.timestamp(cue.end), text: cue.text)
        }
    }

    public static func fromWebVTT(
        key: String,
        canonicalContentURL: URL,
        title: String,
        webVTT: String,
        createdAt: Date = .now,
        languageIdentifier: String = "und",
        playbackOwner: ReaderMediaPlaybackOwner? = nil,
        mediaSourceURL: URL? = nil
    ) -> TranscriptPageAsset {
        let admitted = try? ReaderTranscriptDocument(webVTT: webVTT)
        let cues = admitted?.cues.map { cue in
            Cue(identifier: cue.identifier, startTimestamp: ReaderTranscriptDocument.timestamp(cue.start), endTimestamp: ReaderTranscriptDocument.timestamp(cue.end), text: cue.text)
        } ?? []
        let html = makeHTML(
            title: title,
            canonicalContentURL: canonicalContentURL,
            cues: cues,
            languageIdentifier: languageIdentifier
        )
        return TranscriptPageAsset(
            key: key,
            canonicalContentURL: canonicalContentURL,
            title: title,
            html: html,
            webVTT: admitted?.webVTT,
            createdAt: createdAt,
            languageIdentifier: languageIdentifier,
            playbackOwner: playbackOwner,
            mediaSourceURL: mediaSourceURL
        )
    }

    private static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

public actor TranscriptPageRegistry {
    public static let shared = TranscriptPageRegistry()

    private struct Entry {
        let asset: TranscriptPageAsset
        let byteCount: Int
        var lastUsed: Date
    }
    private var assetsByKey: [String: Entry] = [:]
    private var retainedKeysByDocument: [String: Set<String>] = [:]
    private let maximumAssetCount: Int
    private let maximumBytes: Int

    public init(maximumAssetCount: Int = 12, maximumBytes: Int = 48 * 1024 * 1024) {
        self.maximumAssetCount = max(1, maximumAssetCount)
        self.maximumBytes = max(1, maximumBytes)
    }

    /// Returns false before replacing anything when an asset cannot be admitted.
    @discardableResult
    public func register(_ asset: TranscriptPageAsset) -> Bool {
        guard let webVTT = asset.webVTT,
              let document = try? ReaderTranscriptDocument(webVTT: webVTT),
              document.webVTT == webVTT,
              asset.pageURL != nil,
              asset.playbackOwner.map({ $0.canonicalContentURL == MediaTranscript.canonicalContentURL(from: asset.canonicalContentURL) }) ?? true else { return false }
        let byteCount = asset.html.utf8.count + webVTT.utf8.count
        guard byteCount <= maximumBytes else { return false }
        let retainedKeys = Set(retainedKeysByDocument.values.flatMap { $0 })
        var replacements = assetsByKey
        replacements[asset.key] = Entry(asset: asset, byteCount: byteCount, lastUsed: .now)
        if let documentID = asset.playbackOwner?.documentID {
            while replacements.values.filter({ $0.asset.playbackOwner?.documentID == documentID }).count > 4 {
                guard let victim = replacements.filter({ $0.key != asset.key && $0.value.asset.playbackOwner?.documentID == documentID && !retainedKeys.contains($0.key) }).min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key else { return false }
                replacements.removeValue(forKey: victim)
            }
        }
        while replacements.count > maximumAssetCount || replacements.values.reduce(0, { $0 + $1.byteCount }) > maximumBytes {
            guard let victim = replacements.filter({ $0.key != asset.key && !retainedKeys.contains($0.key) }).min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key else { return false }
            replacements.removeValue(forKey: victim)
        }
        assetsByKey = replacements
        return true
    }

    public func retain(key: String, forDocumentID documentID: String) {
        guard let entry = assetsByKey[key], entry.asset.playbackOwner?.documentID == documentID else { return }
        retainedKeysByDocument[documentID, default: []].insert(key)
    }

    public func release(documentID: String) {
        let retained = retainedKeysByDocument.removeValue(forKey: documentID) ?? []
        for key in retained { assetsByKey.removeValue(forKey: key) }
        // Also remove an admitted asset whose registration finished immediately
        // before this presentation retired and had not yet retained its key.
        assetsByKey = assetsByKey.filter { $0.value.asset.playbackOwner?.documentID != documentID }
    }

    public func remove(documentID: String) { release(documentID: documentID) }

    public func remove(key: String) {
        for documentID in Array(retainedKeysByDocument.keys) {
            retainedKeysByDocument[documentID]?.remove(key)
            if retainedKeysByDocument[documentID]?.isEmpty == true { retainedKeysByDocument.removeValue(forKey: documentID) }
        }
        assetsByKey.removeValue(forKey: key)
    }

    public func removeAll() {
        retainedKeysByDocument.removeAll()
        assetsByKey.removeAll()
    }

    public func asset(forKey key: String) -> TranscriptPageAsset? {
        guard var entry = assetsByKey[key] else { return nil }
        entry.lastUsed = .now
        assetsByKey[key] = entry
        return entry.asset
    }

    private func asset(forRoute url: URL) -> TranscriptPageAsset? {
        guard let key = url.transcriptAssetKey, let asset = asset(forKey: key) else { return nil }
        let expected = url.isTranscriptPageURL ? asset.pageURL : asset.webVTTURL
        guard expected == url else { return nil }
        return asset
    }

    public func htmlData(for url: URL) -> Data? {
        guard url.isTranscriptPageURL, let asset = asset(forRoute: url) else { return nil }
        return Data(asset.html.utf8)
    }

    public func webVTTData(for url: URL) -> Data? {
        guard url.isTranscriptVTTURL, let webVTT = asset(forRoute: url)?.webVTT else { return nil }
        return Data(webVTT.utf8)
    }

    /// Realm objects are constructed on the caller's UI lane, never handed out
    /// from this asset actor and later used from another thread.
    @MainActor
    public func makeReaderContent(for url: URL) async -> (any ReaderContentProtocol)? {
        guard url.isTranscriptPageURL, let asset = await asset(forRoute: url),
              let expectedURL = asset.pageURL else { return nil }
        let record = HistoryRecord()
        record.url = expectedURL
        record.title = asset.title
        record.sourceDownloadURL = asset.canonicalContentURL
        record.audioSubtitlesURL = asset.webVTTURL
        record.audioSubtitlesRole = .media
        record.primaryMediaIdentity = asset.playbackOwner?.resourceIdentity
        record.primaryMediaSourceURL = asset.mediaSourceURL
        record.rssContainsFullContent = true
        record.isReaderModeByDefault = true
        record.isDemoted = true
        record.html = asset.html
        record.updateCompoundKey()
        return record
    }
}
