import Foundation
import SwiftUIWebView
import LakeOfFireContent

/// Immutable native issuance. The wire ID only correlates a result; the exact
/// caller binding and pending native request retain document authority.
public struct ReaderEBookRestoreRequest: Equatable, Sendable {
    public let requestID: String
    public let cfi: String
    public let fractionalCompletion: Double?
    public let requestedLocator: String
    public let contentURL: URL
    fileprivate let callerID: String
    fileprivate let binding: WebViewScriptCaller.JavaScriptBindingToken

    var javaScriptArgument: [String: any Sendable] {
        var value: [String: any Sendable] = [
            "requestID": requestID, "requestedLocator": requestedLocator, "cfi": cfi,
        ]
        if let fractionalCompletion { value["fractionalCompletion"] = fractionalCompletion }
        return value
    }
}

public extension ReaderViewModel {
    static func restoreContentURL(_ url: URL) -> URL {
        let resolved = ReaderContentLoader.getContentURL(fromLoaderURL: url) ?? url
        guard var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else { return resolved }
        components.fragment = nil
        return components.url ?? resolved
    }

    func captureEBookRestore(
        result: ReaderContentEbookInitialRestoreResult, message: WebViewMessage,
        caller: WebViewScriptCaller, loaderURL: URL
    ) -> ReaderEBookRestoreRequest? {
        guard !Task.isCancelled, message.isMainFrame,
              let request = pendingEBookRestore,
              isCurrentEBookRestore(request, caller: caller, loaderURL: loaderURL),
              message.javaScriptBindingToken == request.binding,
              let receiptURL = message.requestURL ?? message.mainDocumentURL,
              Self.restoreContentURL(receiptURL) == request.contentURL,
              result.requestID == request.requestID,
              result.requestedLocator == request.requestedLocator,
              (result.terminalState == .noTarget) == (request.requestedLocator == "none") else { return nil }
        return request
    }

    func isCurrentEBookRestore(
        _ request: ReaderEBookRestoreRequest, caller: WebViewScriptCaller, loaderURL: URL
    ) -> Bool {
        !Task.isCancelled && pendingEBookRestore == request
            && caller.id == request.callerID
            && caller.currentJavaScriptBindingToken == request.binding
            && Self.restoreContentURL(loaderURL) == request.contentURL
    }

    @discardableResult
    func settleEBookRestore(
        _ request: ReaderEBookRestoreRequest, caller: WebViewScriptCaller, loaderURL: URL
    ) -> Bool {
        guard isCurrentEBookRestore(request, caller: caller, loaderURL: loaderURL) else { return false }
        pendingEBookRestore = nil
        return true
    }
}

extension ReaderViewModel {
    /// Receipt admission revokes an earlier restore before any saved-position
    /// read can suspend, including a successor in the same WebKit document.
    func beginEBookRestoreInitialization(
        caller: WebViewScriptCaller, binding: WebViewScriptCaller.JavaScriptBindingToken
    ) throws -> UUID {
        try Task.checkCancellation()
        guard caller.currentJavaScriptBindingToken == binding else { throw CancellationError() }
        let id = UUID()
        eBookRestoreInitializationID = id
        pendingEBookRestore = nil
        return id
    }

    func isCurrentEBookRestoreInitialization(_ id: UUID) -> Bool {
        !Task.isCancelled && eBookRestoreInitializationID == id
    }

    /// Cleanup also runs in a cancelled dispatch task. Matching the immutable
    /// issuance prevents that task from discarding a reentrant successor.
    func discardEBookRestore(_ request: ReaderEBookRestoreRequest) {
        guard pendingEBookRestore == request else { return }
        pendingEBookRestore = nil
    }

    /// Called immediately before the bound load dispatch, with no suspension.
    func issueEBookRestore(
        _ restore: ReaderEBookInitialRestoreBridgeRequest?, caller: WebViewScriptCaller,
        binding: WebViewScriptCaller.JavaScriptBindingToken, loaderURL: URL, initializationID: UUID
    ) throws -> ReaderEBookRestoreRequest {
        try Task.checkCancellation()
        guard isCurrentEBookRestoreInitialization(initializationID),
              caller.currentJavaScriptBindingToken == binding else { throw CancellationError() }
        let request = ReaderEBookRestoreRequest(
            requestID: restore?.requestID ?? UUID().uuidString,
            cfi: restore?.cfi ?? "", fractionalCompletion: restore?.fractionalCompletion,
            requestedLocator: restore?.requestedLocator ?? "none",
            contentURL: Self.restoreContentURL(loaderURL), callerID: caller.id, binding: binding
        )
        pendingEBookRestore = request
        return request
    }
}
