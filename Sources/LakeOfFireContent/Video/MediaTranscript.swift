import Foundation
import RealmSwift
import RealmSwiftGaps
import BigSyncKit
import SwiftUtilities
import LakeOfFireCore
import libzstd

public enum MediaTranscriptFormat: String, Sendable {
    case webvtt
}

public enum MediaTranscriptCompression: String, Sendable {
    case zstd
}

public enum MediaTranscriptCodecError: Error {
    case invalidFrame
    case unknownFrameSize
    case decompressionFailed(String)
    case compressionFailed(String)
    case contentTooLarge
}

private extension URL {
    func removingFragmentForTranscriptIdentity() -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: true) else {
            return self
        }
        components.fragment = nil
        return components.url ?? self
    }
}

public final class MediaTranscript: Object, UnownedSyncableObject, ChangeMetadataRecordable {
    public static let currentGeneratorVersion = 1
    public static let zstdCompressionLevel: Int32 = 6
    private static let keySeparator = "\u{1F}"

    @Persisted(primaryKey: true) public var compoundKey = ""
    @Persisted public var contentURL = URL(string: "about:blank")!
    @Persisted public var stableMediaIdentity = ""
    @Persisted public var languageCode = "und"
    @Persisted public var formatRawValue = MediaTranscriptFormat.webvtt.rawValue
    @Persisted public var compressionRawValue = MediaTranscriptCompression.zstd.rawValue
    @Persisted public var content: Data?
    @Persisted public var isGenerated = false
    @Persisted public var generatorVersion = currentGeneratorVersion
    @Persisted public var transcriptLocale = "und"
    @Persisted public var sourceDuration: Double?
    @Persisted public var mediaFingerprint: String?

    @Persisted public var explicitlyModifiedAt: Date?
    @Persisted public var createdAt = Date()
    @Persisted public var modifiedAt = Date()
    @Persisted public var isDeleted = false

    public var needsSyncToAppServer: Bool {
        false
    }

    public var format: MediaTranscriptFormat {
        get { MediaTranscriptFormat(rawValue: formatRawValue) ?? .webvtt }
        set { formatRawValue = newValue.rawValue }
    }

    public var compression: MediaTranscriptCompression {
        get { MediaTranscriptCompression(rawValue: compressionRawValue) ?? .zstd }
        set { compressionRawValue = newValue.rawValue }
    }

    public static func canonicalContentURL(from url: URL) -> URL {
        (ReaderContentLoader.getContentURL(fromLoaderURL: url) ?? url).removingFragmentForTranscriptIdentity()
    }

    public static func stableMediaIdentity(url: URL) -> String {
        "url:\(url.removingFragmentForTranscriptIdentity().absoluteString)"
    }

    public static func stableMediaIdentity(offlineMediaID: String) -> String {
        "offline:\(offlineMediaID)"
    }

    public static func makeCompoundKey(
        contentURL: URL,
        stableMediaIdentity: String,
        languageCode: String
    ) -> String {
        [
            canonicalContentURL(from: contentURL).absoluteString,
            stableMediaIdentity,
            languageCode.lowercased()
        ].joined(separator: keySeparator)
    }

    public func updateCompoundKey() {
        compoundKey = Self.makeCompoundKey(
            contentURL: contentURL,
            stableMediaIdentity: stableMediaIdentity,
            languageCode: languageCode
        )
    }

    public func matchesReuse(
        stableMediaIdentity: String,
        languageCode: String,
        generatorVersion: Int = MediaTranscript.currentGeneratorVersion,
        transcriptLocale: String,
        sourceDuration: Double?,
        mediaFingerprint: String?
    ) -> Bool {
        guard !isDeleted else { return false }
        guard self.stableMediaIdentity == stableMediaIdentity else { return false }
        guard self.languageCode.lowercased() == languageCode.lowercased() else { return false }
        guard self.generatorVersion == generatorVersion else { return false }
        guard self.transcriptLocale.lowercased() == transcriptLocale.lowercased() else { return false }

        if let sourceDuration, let existingSourceDuration = self.sourceDuration {
            guard abs(existingSourceDuration - sourceDuration) <= 1 else {
                return false
            }
        }

        if let mediaFingerprint {
            guard self.mediaFingerprint == mediaFingerprint else { return false }
        }

        return true
    }

    public func setWebVTT(
        _ webVTT: String,
        isGenerated: Bool,
        transcriptLocale: String,
        sourceDuration: Double?,
        mediaFingerprint: String? = nil,
        generatorVersion: Int = MediaTranscript.currentGeneratorVersion
    ) throws {
        content = try Self.encodeWebVTT(webVTT)
        format = .webvtt
        compression = .zstd
        self.isGenerated = isGenerated
        self.transcriptLocale = transcriptLocale
        self.sourceDuration = sourceDuration
        self.mediaFingerprint = mediaFingerprint
        self.generatorVersion = generatorVersion
        updateCompoundKey()
    }

    public func webVTTString() throws -> String? {
        guard let content else { return nil }
        return try Self.decodeWebVTT(content)
    }

    public static func encodeWebVTT(_ value: String) throws -> Data {
        try encodeWebVTTData(Data(value.utf8))
    }

    public static func decodeWebVTT(_ value: Data) throws -> String {
        let data = try decodeWebVTTData(value)
        return String(decoding: data, as: UTF8.self)
    }

    public static func encodeWebVTTData(_ data: Data) throws -> Data {
        let maxCompressedSize = ZSTD_compressBound(data.count)
        guard maxCompressedSize > 0 else {
            throw MediaTranscriptCodecError.contentTooLarge
        }

        var output = Data(count: Int(maxCompressedSize))
        let compressedSize = output.withUnsafeMutableBytes { outputBuffer in
            data.withUnsafeBytes { inputBuffer in
                ZSTD_compress(
                    outputBuffer.baseAddress,
                    outputBuffer.count,
                    inputBuffer.baseAddress,
                    data.count,
                    zstdCompressionLevel
                )
            }
        }

        guard ZSTD_isError(compressedSize) == 0 else {
            throw MediaTranscriptCodecError.compressionFailed(
                String(cString: ZSTD_getErrorName(compressedSize))
            )
        }

        output.count = Int(compressedSize)
        return output
    }

    public static func decodeWebVTTData(_ payload: Data) throws -> Data {
        let frameContentSize = payload.withUnsafeBytes { rawBuffer in
            ZSTD_getFrameContentSize(rawBuffer.baseAddress, payload.count)
        }

        guard frameContentSize != ZSTD_CONTENTSIZE_ERROR else {
            throw MediaTranscriptCodecError.invalidFrame
        }

        guard frameContentSize != ZSTD_CONTENTSIZE_UNKNOWN else {
            throw MediaTranscriptCodecError.unknownFrameSize
        }

        guard frameContentSize <= UInt64(Int.max) else {
            throw MediaTranscriptCodecError.contentTooLarge
        }

        var output = Data(count: Int(frameContentSize))
        let decompressedSize = output.withUnsafeMutableBytes { outputBuffer in
            payload.withUnsafeBytes { inputBuffer in
                ZSTD_decompress(
                    outputBuffer.baseAddress,
                    outputBuffer.count,
                    inputBuffer.baseAddress,
                    payload.count
                )
            }
        }

        guard ZSTD_isError(decompressedSize) == 0 else {
            throw MediaTranscriptCodecError.decompressionFailed(
                String(cString: ZSTD_getErrorName(decompressedSize))
            )
        }

        output.count = Int(decompressedSize)
        return output
    }
}
