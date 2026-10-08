import Foundation
import LakeOfFireCore

/// Admission rules for JavaScript messages which can durably mutate reader data.
///
/// Payload URLs are untrusted. A mutation is admitted only when the claimed top-level
/// document agrees with WebKit's frame provenance and with the document currently
/// owned by the reader.
enum ReaderDocumentMutationAdmission {
    static func acceptsTopLevelDocument(
        claimedURL: URL?,
        frameMainDocumentURL: URL?,
        currentPageURL: URL,
        requiresMainFrame: Bool,
        isMainFrame: Bool
    ) -> Bool {
        guard !requiresMainFrame || isMainFrame,
              let claimedURL,
              let frameMainDocumentURL,
              !claimedURL.isNativeReaderView,
              urlsMatchWithoutHash(claimedURL, frameMainDocumentURL),
              urlsMatchWithoutHash(frameMainDocumentURL, currentPageURL) else {
            return false
        }
        return true
    }

    static func acceptsFrameTarget(
        claimedFrameURL: URL?,
        frameRequestURL: URL?
    ) -> Bool {
        guard let claimedFrameURL, let frameRequestURL else { return false }
        return urlsMatchWithoutHash(claimedFrameURL, frameRequestURL)
    }
}
