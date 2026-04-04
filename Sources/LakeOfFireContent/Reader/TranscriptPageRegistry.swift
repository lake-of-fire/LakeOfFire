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

    public init(
        key: String,
        canonicalContentURL: URL,
        title: String,
        html: String,
        webVTT: String? = nil,
        createdAt: Date = .now
    ) {
        self.key = key
        self.canonicalContentURL = canonicalContentURL
        self.title = title
        self.html = html
        self.webVTT = webVTT
        self.createdAt = createdAt
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
        cues: [Cue]
    ) -> String {
        let cueMarkup = cues.enumerated().map { index, cue in
            let identifierAttribute = cue.identifier.map {
                #" data-transcript-cue-id="\#(escapeHTML($0))""#
            } ?? ""
            return """
            <p class="reader-transcript-cue" data-transcript-cue-index="\(index)" data-transcript-start="\(escapeHTML(cue.startTimestamp))" data-transcript-end="\(escapeHTML(cue.endTimestamp))"\(identifierAttribute)>\(escapeHTML(cue.text))</p>
            """
        }.joined(separator: "\n")

        return """
        <!doctype html>
        <html lang="en">
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
        <body data-manabi-transcript-page="true">
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
        let normalized = webVTT.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")

        func parseCueBlock(_ block: String) -> Cue? {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.hasPrefix("WEBVTT") || trimmed.hasPrefix("STYLE") || trimmed.hasPrefix("NOTE") {
                return nil
            }

            let lines = trimmed.components(separatedBy: .newlines).filter { !$0.isEmpty }
            guard !lines.isEmpty else { return nil }

            let timingIndex: Int?
            if lines.first?.contains("-->") == true {
                timingIndex = 0
            } else {
                timingIndex = lines.dropFirst().firstIndex(where: { $0.contains("-->") })
            }
            guard let timingIndex else { return nil }

            let identifier = timingIndex > 0 ? lines[0] : nil
            let timingLine = lines[timingIndex]
            let timingParts = timingLine.components(separatedBy: "-->")
            guard timingParts.count == 2 else { return nil }

            let start = timingParts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let end = timingParts[1]
                .components(separatedBy: .whitespacesAndNewlines)
                .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !start.isEmpty, !end.isEmpty else { return nil }

            let textLines = Array(lines.dropFirst(timingIndex + 1))
            let text = textLines
                .joined(separator: "\n")
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            return Cue(
                identifier: identifier,
                startTimestamp: start,
                endTimestamp: end,
                text: text
            )
        }

        return blocks.compactMap(parseCueBlock)
    }

    public static func fromWebVTT(
        key: String,
        canonicalContentURL: URL,
        title: String,
        webVTT: String,
        createdAt: Date = .now
    ) -> TranscriptPageAsset {
        let cues = cues(fromWebVTT: webVTT)
        let html = makeHTML(
            title: title,
            canonicalContentURL: canonicalContentURL,
            cues: cues
        )
        return TranscriptPageAsset(
            key: key,
            canonicalContentURL: canonicalContentURL,
            title: title,
            html: html,
            webVTT: webVTT,
            createdAt: createdAt
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

    private var assetsByKey: [String: TranscriptPageAsset] = [:]

    public init() {}

    public func register(_ asset: TranscriptPageAsset) {
        assetsByKey[asset.key] = asset
    }

    public func remove(key: String) {
        assetsByKey.removeValue(forKey: key)
    }

    public func removeAll() {
        assetsByKey.removeAll()
    }

    public func asset(forKey key: String) -> TranscriptPageAsset? {
        assetsByKey[key]
    }

    public func htmlData(for url: URL) -> Data? {
        guard let key = url.transcriptAssetKey,
              let asset = assetsByKey[key]
        else {
            return nil
        }
        return Data(asset.html.utf8)
    }

    public func webVTTData(for url: URL) -> Data? {
        guard let key = url.transcriptAssetKey,
              let asset = assetsByKey[key],
              let webVTT = asset.webVTT
        else {
            return nil
        }
        return Data(webVTT.utf8)
    }

    public func makeReaderContent(for url: URL) -> (any ReaderContentProtocol)? {
        guard url.isTranscriptPageURL,
              let key = url.transcriptAssetKey,
              let asset = assetsByKey[key],
              let expectedURL = asset.pageURL,
              url.absoluteString == expectedURL.absoluteString
        else {
            return nil
        }

        let record = HistoryRecord()
        record.url = expectedURL
        record.title = asset.title
        record.sourceDownloadURL = asset.canonicalContentURL
        record.rssContainsFullContent = true
        record.isReaderModeByDefault = true
        record.isDemoted = true
        record.html = asset.html
        record.updateCompoundKey()
        return record
    }
}
