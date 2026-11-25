import Foundation
import LakeOfFireContent

struct ReaderFileDocumentPayload: Sendable {
    let data: Data
    let mimeType: String
    let textEncodingName: String?
}

/// This is the ordinary-file response path called by ReaderFileURLSchemeHandler.
enum ReaderFileDocumentLoader {
    private enum TextEncoding {
        case utf8
        case utf16(littleEndian: Bool)
        case utf32(littleEndian: Bool)
    }

    private static let byteOrderMarks: [(bytes: [UInt8], encoding: TextEncoding)] = [
        ([0x00, 0x00, 0xfe, 0xff], .utf32(littleEndian: false)),
        ([0xff, 0xfe, 0x00, 0x00], .utf32(littleEndian: true)),
        ([0xef, 0xbb, 0xbf], .utf8),
        ([0xfe, 0xff], .utf16(littleEndian: false)),
        ([0xff, 0xfe], .utf16(littleEndian: true)),
    ]

    @ReaderFileURLSchemeActor
    static func load(
        url: URL,
        metadata: @MainActor () async throws -> ContentFile?,
        read: @ReaderFileURLSchemeActor () async throws -> Data?
    ) async throws -> ReaderFileDocumentPayload? {
        // Resolve and read the managed object only on its owning main actor.
        // A missing record is different from an empty metadata value.
        let sourceMIME: String? = try? await { @MainActor in
            guard let file = try await metadata(), !file.isInvalidated else { return nil }
            return file.mimeType
        }()
        try Task.checkCancellation()
        let bytes = try? await read()
        try Task.checkCancellation()
        guard let sourceMIME, var data = bytes else { return nil }
        var mimeType = sourceMIME
        var textEncodingName: String?
        if ReaderContentLoader.supportsReaderContent(mimeType: sourceMIME, pathExtension: url.pathExtension),
           let text = decodeText(data),
           let converted = ReaderContentLoader.normalizeIngestedText(
               text, mimeType: sourceMIME, pathExtension: url.pathExtension, source: .file
           ).html.data(using: .utf8) {
            data = converted
            mimeType = "text/html"
            textEncodingName = "UTF-8"
        }
        return ReaderFileDocumentPayload(data: data, mimeType: mimeType, textEncodingName: textEncodingName)
    }

    private static func decodeText(_ data: Data) -> String? {
        // UTF-32LE and UTF-16LE share a prefix, so the longer mark comes first.
        let mark = byteOrderMarks.first { data.starts(with: $0.bytes) }
        let payload = data.dropFirst(mark?.bytes.count ?? 0)

        // The Unicode decoders keep literal U+FEFF. Exact round trips reject
        // repaired input without rejecting an authored replacement character.
        switch mark?.encoding ?? .utf8 {
        case .utf8:
            let text = String(decoding: payload, as: UTF8.self)
            return text.utf8.elementsEqual(payload) ? text : nil
        case let .utf16(littleEndian):
            guard let units = codeUnits(in: payload, as: UInt16.self, littleEndian: littleEndian) else { return nil }
            let text = String(decoding: units, as: UTF16.self)
            return text.utf16.elementsEqual(units) ? text : nil
        case let .utf32(littleEndian):
            guard let units = codeUnits(in: payload, as: UInt32.self, littleEndian: littleEndian) else { return nil }
            let text = String(decoding: units, as: UTF32.self)
            return text.unicodeScalars.lazy.map(\.value).elementsEqual(units) ? text : nil
        }
    }

    private static func codeUnits<Unit: FixedWidthInteger>(
        in payload: Data,
        as _: Unit.Type,
        littleEndian: Bool
    ) -> [Unit]? {
        let width = Unit.bitWidth / UInt8.bitWidth
        guard payload.count.isMultiple(of: width) else { return nil }
        return stride(from: payload.startIndex, to: payload.endIndex, by: width).map { start in
            var unit: Unit = 0
            for offset in 0..<width {
                let bytePosition = littleEndian ? offset : width - 1 - offset
                unit |= Unit(payload[start + offset]) << (bytePosition * UInt8.bitWidth)
            }
            return unit
        }
    }
}
