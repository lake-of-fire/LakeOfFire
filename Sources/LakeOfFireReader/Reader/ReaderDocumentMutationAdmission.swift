import Foundation
import LakeOfFireCore

/// Admission rules for JavaScript messages which can durably mutate reader data.
///
/// Payload URLs are untrusted. A mutation is admitted only when the claimed top-level
/// document agrees with WebKit's frame provenance and with the document currently
/// owned by the reader.
enum ReaderDocumentMutationAdmission {
    static func acceptsEBookReadiness<Binding: Equatable>(
        claimedURL: URL,
        frameMainDocumentURL: URL?,
        currentPageURL: URL,
        selectedContentURL: URL,
        isMainFrame: Bool,
        receiptBinding: Binding?,
        currentBinding: Binding?
    ) -> Bool {
        guard claimedURL.isEBookURL,
              let receiptBinding, receiptBinding == currentBinding,
              urlsMatchWithoutHash(claimedURL, selectedContentURL) else { return false }
        return acceptsTopLevelDocument(
            claimedURL: claimedURL,
            frameMainDocumentURL: frameMainDocumentURL,
            currentPageURL: currentPageURL,
            requiresMainFrame: true,
            isMainFrame: isMainFrame
        )
    }

    static func acceptsTopLevelDocument(
        claimedURL: URL?,
        frameMainDocumentURL: URL?,
        frameRequestURL: URL? = nil,
        currentPageURL: URL,
        requiresMainFrame: Bool,
        isMainFrame: Bool
    ) -> Bool {
        // WebKit can omit mainDocumentURL on a main-frame navigation. Only that
        // frame's native request can supply the missing top-level provenance;
        // neither a child-frame request nor the payload may stand in for it.
        let topLevelDocumentURL = frameMainDocumentURL ?? (isMainFrame ? frameRequestURL : nil)
        guard !requiresMainFrame || isMainFrame,
              let claimedURL,
              let topLevelDocumentURL,
              !claimedURL.isNativeReaderView,
              urlsMatchWithoutHash(claimedURL, topLevelDocumentURL),
              urlsMatchWithoutHash(topLevelDocumentURL, currentPageURL) else {
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
