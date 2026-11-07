import Foundation
import SwiftSoup

public enum ReaderTranscriptDocumentError: Error, Sendable {
    case tooLarge
    case invalidEncoding
    case invalidHeader
    case invalidCue
    case noUsableCues
}

/// The single admission representation used by network acquisition, generated
/// transcripts, synchronized cache reads/writes, and the transcript renderer.
public struct ReaderTranscriptDocument: Sendable {
    public static let maximumBytes = 8 * 1024 * 1024
    public static let maximumCueCount = 100_000

    public struct Cue: Sendable, Hashable {
        public let identifier: String?
        public let start: TimeInterval
        public let end: TimeInterval
        public let text: String
    }

    public let cues: [Cue]
    public let webVTT: String

    public init(data: Data) throws {
        guard data.count <= Self.maximumBytes else { throw ReaderTranscriptDocumentError.tooLarge }
        guard let value = String(data: data, encoding: .utf8) else { throw ReaderTranscriptDocumentError.invalidEncoding }
        try self.init(webVTT: value)
    }

    public init(webVTT value: String) throws {
        guard value.utf8.count <= Self.maximumBytes else { throw ReaderTranscriptDocumentError.tooLarge }
        var normalized = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if normalized.hasPrefix("\u{feff}") { normalized.removeFirst() }
        guard !normalized.contains("\0") else { throw ReaderTranscriptDocumentError.invalidEncoding }
        let lines = normalized.components(separatedBy: "\n")
        guard let header = lines.first, header == "WEBVTT" || header.hasPrefix("WEBVTT ") || header.hasPrefix("WEBVTT\t"), !header.contains("-->") else { throw ReaderTranscriptDocumentError.invalidHeader }

        var cursor = 1
        // Header metadata ends at the mandatory blank separator.
        while cursor < lines.count && !lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty {
            guard !lines[cursor].contains("-->") else { throw ReaderTranscriptDocumentError.invalidHeader }
            cursor += 1
        }
        var parsed: [Cue] = []
        var previousStart: TimeInterval = -1
        while cursor < lines.count {
            while cursor < lines.count && lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty { cursor += 1 }
            let beginning = cursor
            while cursor < lines.count && !lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty { cursor += 1 }
            guard beginning < cursor else { continue }
            let block = Array(lines[beginning..<cursor])
            let first = block[0]
            if first == "NOTE" || first.hasPrefix("NOTE ") || first.hasPrefix("NOTE\t") || first == "STYLE" || first == "REGION" { continue }
            let timingIndex = first.contains("-->") ? 0 : 1
            guard block.count > timingIndex + 1 else { throw ReaderTranscriptDocumentError.invalidCue }
            let timingParts = block[timingIndex].components(separatedBy: "-->")
            guard timingParts.count == 2,
                  let start = Self.seconds(timingParts[0].trimmingCharacters(in: .whitespaces)),
                  let endText = timingParts[1].split(whereSeparator: { $0 == " " || $0 == "\t" }).first,
                  let end = Self.seconds(String(endText)), end > start, start >= previousStart else { throw ReaderTranscriptDocumentError.invalidCue }
            let plainText = try block.dropFirst(timingIndex + 1).map { line in
                // Strip WebVTT timestamp/voice/class tags before entity decoding.
                let markup = line.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
                return try SwiftSoup.parseBodyFragment(markup).text()
            }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard plainText.utf8.count <= 32_768 else { throw ReaderTranscriptDocumentError.tooLarge }
            previousStart = start
            guard !plainText.isEmpty else { continue }
            guard parsed.count < Self.maximumCueCount else { throw ReaderTranscriptDocumentError.tooLarge }
            parsed.append(Cue(identifier: timingIndex == 1 ? first : nil, start: start, end: end, text: plainText))
        }
        guard !parsed.isEmpty else { throw ReaderTranscriptDocumentError.noUsableCues }
        cues = parsed
        webVTT = "WEBVTT\n\n" + parsed.enumerated().map { index, cue in
            "\(index + 1)\n\(Self.timestamp(cue.start)) --> \(Self.timestamp(cue.end))\n\(Self.escape(cue.text))\n"
        }.joined(separator: "\n")
        guard webVTT.utf8.count <= Self.maximumBytes else { throw ReaderTranscriptDocumentError.tooLarge }
    }

    public static func timestamp(_ seconds: TimeInterval) -> String {
        let milliseconds = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", milliseconds / 3_600_000, (milliseconds / 60_000) % 60, (milliseconds / 1000) % 60, milliseconds % 1000)
    }

    private static func seconds(_ timestamp: String) -> TimeInterval? {
        let parts = timestamp.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let secondParts = parts.last!.split(separator: ".", omittingEmptySubsequences: false)
        guard secondParts.count == 2, secondParts[0].count == 2, secondParts[1].count == 3,
              secondParts.allSatisfy({ $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              let seconds = Int(secondParts[0]), seconds < 60, let milliseconds = Int(secondParts[1]) else { return nil }
        let minutePart = parts[parts.count - 2]
        guard minutePart.count == 2, minutePart.allSatisfy({ $0.isASCII && $0.isNumber }), let minutes = Int(minutePart), minutes < 60 else { return nil }
        var hours = 0
        if parts.count == 3 {
            guard parts[0].count >= 2, parts[0].count <= 3, parts[0].allSatisfy({ $0.isASCII && $0.isNumber }), let parsedHours = Int(parts[0]), parsedHours <= 168 else { return nil }
            hours = parsedHours
        }
        return Double(hours * 3600 + minutes * 60 + seconds) + Double(milliseconds) / 1000
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
