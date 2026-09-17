import Foundation
import LakeOfFireContent

struct ReaderFileDocumentPayload: Sendable {
    let data: Data
    let mimeType: String
    let textEncodingName: String?
}

/// This is the ordinary-file response path called by ReaderFileURLSchemeHandler.
enum ReaderFileDocumentLoader {
    @ReaderFileURLSchemeActor
    static func load(
        url: URL,
        metadata: @MainActor () async throws -> ContentFile?,
        read: @ReaderFileURLSchemeActor () async throws -> Data?
    ) async throws -> ReaderFileDocumentPayload? {
        let contentFile = try? await metadata()
        try Task.checkCancellation()
        let bytes = try? await read()
        try Task.checkCancellation()
        guard let contentFile, var data = bytes else { return nil }
        var mimeType = contentFile.mimeType
        var textEncodingName: String?
        if let text = String(data: data, encoding: .utf8),
           ReaderContentLoader.supportsReaderContent(mimeType: contentFile.mimeType, pathExtension: url.pathExtension),
           let converted = ReaderContentLoader.normalizeIngestedText(
               text, mimeType: contentFile.mimeType, pathExtension: url.pathExtension, source: .file
           ).html.data(using: .utf8) {
            data = converted
            mimeType = "text/html"
            textEncodingName = "UTF-8"
        }
        return ReaderFileDocumentPayload(data: data, mimeType: mimeType, textEncodingName: textEncodingName)
    }
}
