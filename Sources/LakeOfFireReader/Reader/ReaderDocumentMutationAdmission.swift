import Foundation
import LakeOfFireCore
import SwiftUIWebView

/// Captured before suspension, checked again inside the destination Realm write.
/// URL provenance chooses the record; the binding fence revokes document authority.
struct ReaderDocumentMutationAdmission: Sendable {
    let targetURL: URL
    let bindingToken: WebViewScriptCaller.JavaScriptBindingToken?
    private let bindingIsCurrent: @Sendable () -> Bool

    init(
        targetURL: URL,
        bindingToken: WebViewScriptCaller.JavaScriptBindingToken?,
        bindingIsCurrent: @escaping @Sendable () -> Bool
    ) {
        self.targetURL = targetURL
        self.bindingToken = bindingToken
        self.bindingIsCurrent = bindingIsCurrent
    }

    var permitsMutation: Bool { !Task.isCancelled && bindingIsCurrent() }

    static func acceptsTopLevelDocument(
        claimedURL: URL?,
        frameMainDocumentURL: URL?,
        currentPageURL: URL,
        requiresMainFrame: Bool,
        isMainFrame: Bool
    ) -> Bool {
        guard !requiresMainFrame || isMainFrame,
              let claimedURL, let frameMainDocumentURL,
              !claimedURL.isNativeReaderView,
              urlsMatchWithoutHash(claimedURL, frameMainDocumentURL),
              urlsMatchWithoutHash(frameMainDocumentURL, currentPageURL) else { return false }
        return true
    }

    @MainActor
    static func capture(
        targetURL: URL,
        requiring token: WebViewScriptCaller.JavaScriptBindingToken?,
        scriptCaller: WebViewScriptCaller
    ) -> Self? {
        guard let token,
              let fence = scriptCaller.makeJavaScriptBindingCommitFence(requiring: token) else { return nil }
        return Self(targetURL: targetURL, bindingToken: token, bindingIsCurrent: fence)
    }
}
