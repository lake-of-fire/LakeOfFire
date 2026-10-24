import Foundation
import SwiftUIWebView
import LakeOfFireContent

/// Transient presentation correlation only; this does not authorize the saved storage read.
public struct ReaderEBookRestoreRequest: Sendable, Equatable {
    public let loadRequestID: String
    public let contentURL: URL
    public let cfi: String
    public let fractionalCompletion: Double?
    public let requestedLocator: String
    public let layoutMode: String

    init(loadRequestID: String, contentURL: URL, cfi: String, fractionalCompletion: Double?,
         requestedLocator: String, layoutMode: String = "paginated") {
        self.loadRequestID = loadRequestID
        self.contentURL = contentURL
        self.cfi = cfi
        self.fractionalCompletion = fractionalCompletion
        self.requestedLocator = requestedLocator
        self.layoutMode = layoutMode
    }
}

/// One slot, with receipt-order admission even after settlement. Tests use scalar owner fixtures;
/// the real owner includes the native binding, caller identity and admitted URLs.
@MainActor
struct ReaderEBookRestoreAttemptState<Owner: Equatable> {
    private var owner: Owner?
    private var sequence: UInt64?
    private var identifier: String?
    private var request: ReaderEBookRestoreRequest?
    private var settled = false
    private var terminalClaimed = false
    private var lifetimeIsCurrent: (@MainActor () -> Bool)?

    mutating func reserve(
        owner: Owner, sequence: UInt64,
        sharesReceiptOrder: (Owner, Owner) -> Bool = { $0 == $1 },
        lifetimeIsCurrent: @escaping @MainActor () -> Bool = { true }
    ) -> String? {
        guard lifetimeIsCurrent() else { return nil }
        if let previousOwner = self.owner, sharesReceiptOrder(previousOwner, owner),
           let previous = self.sequence, sequence <= previous { return nil }
        let identifier = UUID().uuidString
        self.owner = owner
        self.sequence = sequence
        self.identifier = identifier
        request = nil
        settled = false
        terminalClaimed = false
        self.lifetimeIsCurrent = lifetimeIsCurrent
        return identifier
    }

    func isCurrent(_ identifier: String, owner: Owner) -> Bool {
        self.identifier == identifier && self.owner == owner && !settled
            && lifetimeIsCurrent?() != false
    }

    mutating func dispatch(_ request: ReaderEBookRestoreRequest, owner: Owner) -> Bool {
        guard isCurrent(request.loadRequestID, owner: owner), self.request == nil else { return false }
        self.request = request
        return true
    }

    mutating func capture(result: ReaderContentEbookInitialRestoreResult, owner: Owner) -> ReaderEBookRestoreRequest? {
        guard !terminalClaimed, let request, isCurrent(request.loadRequestID, owner: owner),
              result.loadRequestID == request.loadRequestID,
              result.requestedLocator == request.requestedLocator else { return nil }
        if request.requestedLocator == "none" {
            guard result.requestID == nil, result.terminalState != .satisfied else { return nil }
        } else {
            guard result.requestID == request.loadRequestID, result.terminalState != .noTarget else { return nil }
        }
        terminalClaimed = true
        return request
    }

    mutating func settle(_ identifier: String, owner: Owner) -> Bool {
        guard isCurrent(identifier, owner: owner) else { return false }
        return retire(identifier, owner: owner)
    }

    /// Obsolete matching work can release its slot, without authorizing publication
    /// or retiring a successor. Receipt ordering remains even after retirement.
    @discardableResult
    mutating func retire(_ identifier: String, owner: Owner) -> Bool {
        guard self.identifier == identifier, self.owner == owner, !settled else { return false }
        settled = true
        lifetimeIsCurrent = nil
        return true
    }
}

struct ReaderEBookRestoreNativeOwner: Equatable {
    let caller: ObjectIdentifier
    let binding: WebViewScriptCaller.JavaScriptBindingToken
    let loaderURL: URL
    let frameURL: URL
}

extension ReaderViewModel {
    public static func restoreContentURL(_ url: URL) -> URL {
        let contentURL = ReaderContentLoader.getContentURL(fromLoaderURL: url) ?? url
        var components = URLComponents(url: contentURL, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url ?? contentURL
    }

    func reserveEBookRestore(
        sequence: UInt64, binding: WebViewScriptCaller.JavaScriptBindingToken,
        caller: WebViewScriptCaller, loaderURL: URL, frameURL: URL
    ) -> String? {
        guard scriptCaller === caller, caller.currentJavaScriptBindingToken == binding,
              Self.restoreContentURL(frameURL) == Self.restoreContentURL(loaderURL) else { return nil }
        let lifetimeIsCurrent: @MainActor () -> Bool
        if let provider = ebookRestoreLifetimeCheckProvider {
            // The consumer captures account/session authority here, before any
            // acknowledgment or saved-position read can suspend initialization.
            guard let capturedCheck = provider() else { return nil }
            lifetimeIsCurrent = capturedCheck
        } else {
            lifetimeIsCurrent = { true }
        }
        let owner = ReaderEBookRestoreNativeOwner(
            caller: ObjectIdentifier(caller), binding: binding, loaderURL: loaderURL, frameURL: frameURL
        )
        guard let identifier = ebookRestoreAttempt.reserve(
            owner: owner, sequence: sequence,
            sharesReceiptOrder: { $0.caller == $1.caller && $0.binding == $1.binding },
            lifetimeIsCurrent: lifetimeIsCurrent
        ) else { return nil }
        ebookRestoreCaller = caller
        ebookRestoreOwner = owner
        return identifier
    }

    func isCurrentEBookRestore(_ identifier: String, caller: WebViewScriptCaller, loaderURL: URL) -> Bool {
        guard scriptCaller === caller, let owner = ebookRestoreOwner, ebookRestoreCaller === caller,
              owner.caller == ObjectIdentifier(caller), caller.currentJavaScriptBindingToken == owner.binding,
              Self.restoreContentURL(loaderURL) == Self.restoreContentURL(owner.loaderURL) else { return false }
        return ebookRestoreAttempt.isCurrent(identifier, owner: owner)
    }

    func dispatchEBookRestore(
        _ request: ReaderEBookRestoreRequest, caller: WebViewScriptCaller, loaderURL: URL
    ) -> Bool {
        guard isCurrentEBookRestore(request.loadRequestID, caller: caller, loaderURL: loaderURL),
              let owner = ebookRestoreOwner else { return false }
        return ebookRestoreAttempt.dispatch(request, owner: owner)
    }

    /// Capture before any content-resolution suspension. Missing/mismatched results cannot retire a successor.
    public func captureEBookRestore(
        result: ReaderContentEbookInitialRestoreResult, message: WebViewMessage,
        caller: WebViewScriptCaller, loaderURL: URL
    ) -> ReaderEBookRestoreRequest? {
        guard message.isMainFrame, let owner = ebookRestoreOwner,
              message.javaScriptBindingToken == owner.binding,
              let frameURL = message.requestURL ?? message.mainDocumentURL,
              frameURL == owner.frameURL,
              let identifier = result.loadRequestID,
              isCurrentEBookRestore(identifier, caller: caller, loaderURL: loaderURL) else { return nil }
        return ebookRestoreAttempt.capture(result: result, owner: owner)
    }

    public func isCurrentEBookRestore(
        _ request: ReaderEBookRestoreRequest, caller: WebViewScriptCaller, loaderURL: URL
    ) -> Bool {
        isCurrentEBookRestore(request.loadRequestID, caller: caller, loaderURL: loaderURL)
    }

    @discardableResult
    public func settleEBookRestore(
        _ request: ReaderEBookRestoreRequest, caller: WebViewScriptCaller, loaderURL: URL
    ) -> Bool {
        guard isCurrentEBookRestore(request, caller: caller, loaderURL: loaderURL),
              let owner = ebookRestoreOwner else { return false }
        return ebookRestoreAttempt.settle(request.loadRequestID, owner: owner)
    }

    /// Cleanup after a captured terminal is abandoned or cancelled. Unlike
    /// settlement this grants no authority to publish; the exact native owner
    /// and request identifier still prevent old cleanup from retiring a retry.
    public func retireEBookRestore(
        _ request: ReaderEBookRestoreRequest, caller: WebViewScriptCaller, loaderURL: URL
    ) {
        guard let owner = ebookRestoreOwner, ebookRestoreCaller === caller,
              owner.caller == ObjectIdentifier(caller),
              Self.restoreContentURL(loaderURL) == Self.restoreContentURL(owner.loaderURL) else { return }
        _ = ebookRestoreAttempt.retire(request.loadRequestID, owner: owner)
    }

    func retireEBookRestore(_ identifier: String) {
        guard let owner = ebookRestoreOwner else { return }
        _ = ebookRestoreAttempt.retire(identifier, owner: owner)
    }
}
