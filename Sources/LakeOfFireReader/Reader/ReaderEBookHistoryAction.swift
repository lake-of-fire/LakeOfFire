import Foundation
import SwiftUIWebView
import WebKit
import LakeOfFireCore

/// A native tap retains the document and JavaScript load that published its HUD.
/// This is presentation authority; it does not authorize a persistence operation.
@MainActor
public final class ReaderEBookHistoryAction {
    public enum Direction: String, Sendable {
        case back
        case forward
    }

    public struct Context: Codable, Equatable, Sendable {
        public let kind: String
        public let loadToken: String
        public let loadURL: String

        private enum CodingKeys: String, CodingKey { case kind, loadToken, loadURL }

        init?(kind: String, loadToken: String, loadURL: String) {
            guard kind == "ebook-history-action-v1", !loadURL.isEmpty,
                  let number = UInt64(loadToken), number > 0,
                  number <= 9_007_199_254_740_991, String(number) == loadToken else { return nil }
            self.kind = kind
            self.loadToken = loadToken
            self.loadURL = loadURL
        }

        init?(payload: Any?) {
            guard let payload = payload as? [String: Any],
                  let kind = payload["kind"] as? String,
                  let loadToken = payload["loadToken"] as? String,
                  let loadURL = payload["loadURL"] as? String else { return nil }
            self.init(kind: kind, loadToken: loadToken, loadURL: loadURL)
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try values.decode(String.self, forKey: .kind)
            let loadToken = try values.decode(String.self, forKey: .loadToken)
            let loadURL = try values.decode(String.self, forKey: .loadURL)
            guard let context = Self(kind: kind, loadToken: loadToken, loadURL: loadURL) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .loadToken, in: values, debugDescription: "Invalid ebook history action context"
                )
            }
            self = context
        }
    }

    public let context: Context
    public let receiptSequence: UInt64
    private let owner: ReaderEBookHistoryNativeOwner
    private let frame: WKFrameInfo
    private weak var caller: WebViewScriptCaller?
    private let callerIsCurrent: @MainActor () -> Bool
    private var retired = false

    init(context: Context, owner: ReaderEBookHistoryNativeOwner,
         message: WebViewMessage, caller: WebViewScriptCaller,
         receiptSequence: UInt64, callerIsCurrent: @escaping @MainActor () -> Bool) {
        self.context = context
        self.owner = owner
        self.frame = message.frameInfo
        self.caller = caller
        self.receiptSequence = receiptSequence
        self.callerIsCurrent = callerIsCurrent
    }

    public var isCurrent: Bool {
        guard !retired, let caller, callerIsCurrent() else { return false }
        return !retired && caller.currentJavaScriptBindingToken == owner.binding
    }

    func matches(owner: ReaderEBookHistoryNativeOwner, context: Context) -> Bool {
        !retired && self.owner == owner && self.context == context && isCurrent
    }

    func retire() { retired = true }

    /// The caller supplies its captured account/page/presentation lifetime.
    /// The required native binding and JS context independently fence dispatch.
    @discardableResult
    public func perform(
        direction: Direction, shouldPerform: @escaping @MainActor () -> Bool
    ) async throws -> Bool {
        func validate() throws {
            try Task.checkCancellation()
            guard isCurrent, shouldPerform(), isCurrent else { throw CancellationError() }
            try Task.checkCancellation()
        }
        try validate()
        guard let caller else { throw CancellationError() }
        let contextJSON = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
        let result = try await caller.evaluateJavaScript(
            """
            if (typeof window.manabiTriggerReaderRelocateJump !== 'function') return false;
            return await window.manabiTriggerReaderRelocateJump(direction, JSON.parse(historyActionContextJSON));
            """,
            arguments: ["direction": direction.rawValue, "historyActionContextJSON": contextJSON],
            in: frame,
            duplicateInMultiTargetFrames: false,
            requiring: owner.binding
        )
        try validate()
        return result as? Bool ?? false
    }
}

struct ReaderEBookHistoryNativeOwner: Equatable {
    let caller: ObjectIdentifier
    let binding: WebViewScriptCaller.JavaScriptBindingToken
    let contentURL: URL
    let frameURL: URL
}

/// The existing overlay decoder, shared by native receipt publication and clears.
/// Context validation is separate so malformed context cannot retain an old action.
struct ReaderEBookNativeOverlayState {
    let percentLabel: String
    let navigationHidden: Bool
    let titleLocationLabel: String
    let titleLocationVisible: Bool
    let bookTitleLabel: String
    let pagesLeftLabel: String
    let source: String
    let relocateBackEnabled: Bool
    let relocateForwardEnabled: Bool
    let currentPageNumber: Int?
    let totalPages: Int?

    init?(payload: Any) {
        guard let payload = payload as? [String: Any] else { return nil }
        percentLabel = (payload["percentLabel"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        navigationHidden = payload["hideNavigationDueToScroll"] as? Bool
            ?? payload["navigationHidden"] as? Bool
            ?? false
        titleLocationLabel = (payload["titleLocationLabel"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        titleLocationVisible = payload["titleLocationVisible"] as? Bool ?? false
        bookTitleLabel = (payload["bookTitleLabel"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        pagesLeftLabel = (payload["pagesLeftLabel"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        source = (payload["source"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        relocateBackEnabled = payload["relocateBackEnabled"] as? Bool ?? false
        relocateForwardEnabled = payload["relocateForwardEnabled"] as? Bool ?? false
        currentPageNumber = (payload["currentPageNumber"] as? NSNumber)?.intValue
            ?? payload["currentPageNumber"] as? Int
        totalPages = (payload["totalPages"] as? NSNumber)?.intValue
            ?? payload["totalPages"] as? Int
    }
}

/// Actual receiver state used by ReaderViewModel. Publication stays synchronous;
/// a reentrant receipt or clear retires the old action before notifying observers.
@MainActor
final class ReaderEBookNativeHistoryState {
    typealias Publication = @MainActor (
        ReaderEBookHistoryAction?, ReaderEBookNativeOverlayState?, @MainActor () -> Bool
    ) -> Void

    private(set) var action: ReaderEBookHistoryAction?
    private var latestReceipt: (caller: ObjectIdentifier, binding: WebViewScriptCaller.JavaScriptBindingToken, sequence: UInt64)?
    private var revision: UInt64 = 0

    func receive(
        message: WebViewMessage, caller: WebViewScriptCaller, loaderURL: URL,
        callerIsCurrent: @escaping @MainActor () -> Bool,
        publish: Publication
    ) {
        guard callerIsCurrent(), message.isMainFrame,
              let binding = message.javaScriptBindingToken,
              caller.currentJavaScriptBindingToken == binding,
              let sequence = message.receiptSequence, sequence > 0,
              let frameURL = message.requestURL ?? message.mainDocumentURL else { return }
        let contentURL = ReaderViewModel.restoreContentURL(loaderURL)
        guard contentURL.isEBookURL,
              ReaderViewModel.restoreContentURL(frameURL) == contentURL else { return }
        let owner = ReaderEBookHistoryNativeOwner(
            caller: ObjectIdentifier(caller), binding: binding, contentURL: contentURL, frameURL: frameURL
        )
        if let previous = latestReceipt, previous.caller == owner.caller,
           previous.binding == binding, sequence <= previous.sequence { return }
        latestReceipt = (owner.caller, binding, sequence)

        let payload = message.body as? [String: Any]
        let context = ReaderEBookHistoryAction.Context(payload: payload?["historyActionContext"])
        let nextAction: ReaderEBookHistoryAction?
        if let context, let loadURL = URL(string: context.loadURL),
           ReaderViewModel.restoreContentURL(loadURL) == contentURL {
            if let action, action.matches(owner: owner, context: context) {
                nextAction = action
            } else {
                nextAction = ReaderEBookHistoryAction(
                    context: context, owner: owner, message: message, caller: caller,
                    receiptSequence: sequence, callerIsCurrent: callerIsCurrent
                )
            }
        } else {
            nextAction = nil
        }
        self.publish(nextAction: nextAction, overlay: ReaderEBookNativeOverlayState(payload: message.body), using: publish)
    }

    func clear(source: String, publish: Publication) {
        // Preserve receipt ordering: a queued older message cannot undo a clear.
        self.publish(nextAction: nil, overlay: ReaderEBookNativeOverlayState(payload: ["source": source]), using: publish)
    }

    private func publish(
        nextAction: ReaderEBookHistoryAction?, overlay: ReaderEBookNativeOverlayState?, using publish: Publication
    ) {
        revision &+= 1
        let publicationRevision = revision
        if action !== nextAction { action?.retire() }
        action = nextAction
        publish(action, overlay, { [weak self] in self?.revision == publicationRevision })
    }
}
