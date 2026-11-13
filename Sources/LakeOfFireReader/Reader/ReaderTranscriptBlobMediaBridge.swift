import Foundation

/// Transfers only the selected page-owned Blob. The native consumer owns its
/// transfer ID and private file; the page continues to own its object URL.
public enum ReaderTranscriptBlobMediaBridge {
    public static let maximumByteCount = 512 * 1_024 * 1_024
    public static let chunkByteCount = 256 * 1_024

    public struct Header: Sendable {
        public let transferID: String
        public let mimeType: String
        public let byteLength: Int?

        public init(transferID: String, mimeType: String, byteLength: Int?) {
            self.transferID = transferID
            self.mimeType = mimeType
            self.byteLength = byteLength
        }
    }

    public struct Chunk: Sendable {
        public let transferID: String
        public let offset: Int
        public let data: Data
        public let done: Bool

        public init(transferID: String, offset: Int, data: Data, done: Bool) {
            self.transferID = transferID
            self.offset = offset
            self.data = data
            self.done = done
        }
    }

    public enum Failure: String, LocalizedError, Sendable {
        case invalidRequest
        case invalidResponse
        case staleSelection
        case unsupportedSource
        case unreadableMedia
        case emptyMedia
        case tooLarge
        case incompleteMedia
        case cancelled
        case busy

        public var errorDescription: String? {
            switch self {
            case .staleSelection:
                return String(localized: "The selected media changed. Try Transcript again.")
            case .unsupportedSource, .unreadableMedia:
                return String(localized: "This page's media could not be read for transcription. Live media streams may not expose a downloadable file.")
            case .emptyMedia:
                return String(localized: "The page returned an empty media file.")
            case .tooLarge:
                return String(localized: "This page's media exceeds the 512 MB transcription transfer limit.")
            case .incompleteMedia:
                return String(localized: "The page's media transfer was incomplete. Try Transcript again.")
            case .cancelled:
                return String(localized: "The media transfer was cancelled.")
            case .busy:
                return String(localized: "A media transfer is still finishing. Try Transcript again.")
            case .invalidRequest, .invalidResponse:
                return String(localized: "The page returned an invalid media transfer response.")
            }
        }
    }

    /// Evaluate in the same captured frame and binding as snapshotJavaScript.
    /// The script's open/read/close operations never revoke a page object URL.
    public static let javaScript: String = {
        guard let url = Bundle.module.url(forResource: "reader-transcript-blob-media",
                                         withExtension: "js", subdirectory: "Resources/Transcript"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("Missing transcript Blob media resource")
        }
        return source
    }()

    public static func decodeOpen(_ json: String) throws -> Header {
        let envelope = try decode(json, maximumJSONBytes: 4_096)
        let transferID = try requireTransferID(envelope)
        guard let mimeType = envelope.mimeType, mimeType.utf8.count <= 256 else {
            throw Failure.invalidResponse
        }
        if let count = envelope.byteLength {
            guard count > 0 else { throw Failure.emptyMedia }
            guard count <= maximumByteCount else { throw Failure.tooLarge }
        }
        return Header(transferID: transferID, mimeType: mimeType, byteLength: envelope.byteLength)
    }

    public static func decodeRead(_ json: String) throws -> Chunk {
        let maximumBase64Bytes = ((chunkByteCount + 2) / 3) * 4
        let envelope = try decode(json, maximumJSONBytes: maximumBase64Bytes + 4_096)
        let transferID = try requireTransferID(envelope)
        guard let offset = envelope.offset, offset >= 0, offset <= maximumByteCount,
              let done = envelope.done, let base64 = envelope.base64,
              base64.utf8.count <= maximumBase64Bytes,
              let data = Data(base64Encoded: base64), data.count <= chunkByteCount,
              data.count <= maximumByteCount - offset,
              done || !data.isEmpty else { throw Failure.invalidResponse }
        return Chunk(transferID: transferID, offset: offset, data: data, done: done)
    }

    public static func decodeClose(_ json: String, transferID: String) throws {
        let envelope = try decode(json, maximumJSONBytes: 4_096)
        guard try requireTransferID(envelope) == transferID else { throw Failure.invalidResponse }
    }

    private struct Envelope: Decodable {
        let status: String
        let error: String?
        let transferID: String?
        let mimeType: String?
        let byteLength: Int?
        let offset: Int?
        let base64: String?
        let done: Bool?
    }

    private static func decode(_ json: String, maximumJSONBytes: Int) throws -> Envelope {
        // Bound the bridge response before decoding base64 into another buffer.
        guard json.utf8.count <= maximumJSONBytes,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(json.utf8)) else {
            throw Failure.invalidResponse
        }
        if envelope.status == "error" {
            let failure = envelope.error.flatMap(Failure.init(rawValue:)) ?? .invalidResponse
            if failure == .cancelled { throw CancellationError() }
            throw failure
        }
        guard envelope.status == "ok", envelope.error == nil else { throw Failure.invalidResponse }
        return envelope
    }

    private static func requireTransferID(_ envelope: Envelope) throws -> String {
        guard let transferID = envelope.transferID, !transferID.isEmpty,
              transferID.utf8.count <= 128 else { throw Failure.invalidResponse }
        return transferID
    }
}
