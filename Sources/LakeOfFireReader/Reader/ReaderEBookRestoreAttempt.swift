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
struct ReaderEBookRestoreAttemptState<Owner: Equatable> {
    private var owner: Owner?
    private var sequence: UInt64?
    private var identifier: String?
    private var request: ReaderEBookRestoreRequest?
    private var settled = false
    private var terminalClaimed = false

    mutating func reserve(
        owner: Owner, sequence: UInt64,
        sharesReceiptOrder: (Owner, Owner) -> Bool = { $0 == $1 }
    ) -> String? {
        if let previousOwner = self.owner, sharesReceiptOrder(previousOwner, owner),
           let previous = self.sequence, sequence <= previous { return nil }
        let identifier = UUID().uuidString
        self.owner = owner
        self.sequence = sequence
        self.identifier = identifier
        request = nil
        settled = false
        terminalClaimed = false
        return identifier
    }

    func isCurrent(_ identifier: String, owner: Owner) -> Bool {
        self.identifier == identifier && self.owner == owner && !settled
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
        settled = true
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
        let owner = ReaderEBookRestoreNativeOwner(
            caller: ObjectIdentifier(caller), binding: binding, loaderURL: loaderURL, frameURL: frameURL
        )
        guard let identifier = ebookRestoreAttempt.reserve(
            owner: owner, sequence: sequence,
            sharesReceiptOrder: { $0.caller == $1.caller && $0.binding == $1.binding }
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

    func retireEBookRestore(_ identifier: String) {
        guard let owner = ebookRestoreOwner else { return }
        _ = ebookRestoreAttempt.settle(identifier, owner: owner)
    }
}
