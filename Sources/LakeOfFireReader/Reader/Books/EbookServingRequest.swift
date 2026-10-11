import Foundation
import LakeOfFireContent

/// Captures one document capability before queueing package IO. Relative entry
/// requests inherit only their owning section document's immutable capability.
enum EbookServingRequest {
    static func sessionID(in url: URL, header: String? = nil) throws -> String? {
        let tokens = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .filter { $0.name == "packageSessionID" } ?? []
        guard tokens.count <= 1, tokens.first.map({ $0.value != nil }) != false else {
            throw ReaderEBookServingError.unavailableSession
        }
        let query = tokens.first?.value
        guard query == nil || header == nil || query == header else {
            throw ReaderEBookServingError.unavailableSession
        }
        let value = query ?? header
        if let value, !ReaderEBookServingSessionStore.isCanonicalSessionID(value) {
            throw ReaderEBookServingError.unavailableSession
        }
        return value
    }

    static func capture(
        _ request: URLRequest, binding: ReaderEBookServingSessionBinding
    ) throws -> ReaderEBookServingAccess? {
        guard let url = request.url else { throw ReaderEBookServingError.invalidSource }
        let sourceURL: URL?
        let generationID: String?
        switch url.path {
        case "/process-text":
            sourceURL = ebookProcessTextContentURL(for: request)
            generationID = nil
        case "/processed-section":
            let parsed = ebookDirectSectionRequest(from: url)
            sourceURL = parsed.flatMap {
                ebookPackageCapabilitySourceURL(
                    for: request, route: "/processed-section",
                    expectedSourceURL: $0.sourceURL, allowsMissingMainDocument: true
                )
            }
            generationID = nil
        case "/entries", "/entry":
            sourceURL = ebookPackageCapabilitySourceURL(for: request, route: url.path)
            generationID = nil
        default:
            guard url.path.hasPrefix("/entry-source/") else { return nil }
            let parsed = ebookPathBackedEntryRequest(from: url, mainDocumentURL: request.mainDocumentURL)
            sourceURL = parsed.flatMap {
                ebookPackageCapabilitySourceURL(
                    for: request, route: "/entry-source", expectedSourceURL: $0.sourceURL
                )
            }
            generationID = parsed?.generationID
        }
        guard let sourceURL else { throw ReaderEBookServingError.invalidSource }
        let supplied = try sessionID(
            in: url, header: request.value(forHTTPHeaderField: "X-Ebook-Package-Session")
        )
        var session = supplied
        if let documentURL = request.mainDocumentURL, documentURL.path == "/processed-section" {
            let owner = try sessionID(in: documentURL)
            if url.path.hasPrefix("/entry-source/") {
                guard supplied == nil || supplied == owner else {
                    throw ReaderEBookServingError.unavailableSession
                }
                session = owner
            } else {
                guard supplied == owner else { throw ReaderEBookServingError.unavailableSession }
            }
        }
        // The capability must survive in the section URL for its relative assets.
        if url.path == "/processed-section", session != (try sessionID(in: url)) {
            throw ReaderEBookServingError.unavailableSession
        }
        return try binding.capture(sourceURL: sourceURL, sessionID: session, generationID: generationID)
    }
}
