import Foundation
import Combine
import CoreGraphics
import SwiftUIWebView

/// Per-Reader acknowledgement of native inset delivery. SwiftUI's .task owns
/// the operation; this helper starts no parallel task or retry loop.
@MainActor
final class ReaderEBookChromeInsetSynchronization: ObservableObject {
    struct Key: Hashable {
        let pageURL: URL
        let renderedURL: URL
        let cachedContentURL: URL?
        let binding: WebViewScriptCaller.JavaScriptBindingToken
        let top: CGFloat
        let toolbarBottom: CGFloat
        let bottom: CGFloat
        let resyncID: UInt64
    }

    typealias Check = @MainActor @Sendable () -> Bool
    private static var revision = 0
    private var requestID: UUID?
    // Retains entry ordering even when a synchronous callback retires an idle
    // owner or starts and finishes another delivery before returning.
    private var entryEpoch = UUID()
    private var acknowledged: Key?

    func deliver(
        key: Key,
        isCurrent: @escaping Check,
        evaluate: @MainActor (_ revision: Int, _ continueWhile: @escaping Check) async throws -> Void
    ) async -> Bool {
        // A cancelled SwiftUI predecessor may not begin until its successor
        // is already running. It must not retire that successor's request.
        let originalEpoch = entryEpoch
        guard !Task.isCancelled, isCurrent(), !Task.isCancelled,
              entryEpoch == originalEpoch else { return false }
        let id = UUID()
        entryEpoch = id
        requestID = id
        defer { if requestID == id { requestID = nil } }
        let current: Check = { [weak self] in
            guard !Task.isCancelled, self?.requestID == id, isCurrent(), !Task.isCancelled else { return false }
            return self?.requestID == id
        }
        guard current() else { return false }
        if acknowledged == key { return current() }
        // A different fanout may change an earlier target before a later one
        // fails. Its predecessor's acknowledged value is no longer a safe
        // dedupe basis, even when this delivery never receives an ACK.
        acknowledged = nil
        Self.revision += 1
        let revision = Self.revision
        do {
            try await evaluate(revision, current)
            guard current() else { return false }
            acknowledged = key
            return true
        } catch {
            return false
        }
    }

    func retire() {
        entryEpoch = UUID()
        requestID = nil
        acknowledged = nil
    }
}

struct ReaderEBookChromeInsetsTaskID: Hashable {
    let key: ReaderEBookChromeInsetSynchronization.Key?
    let nativePageURL: URL
    let additionalLeadingInset: CGFloat
    let hasAsyncCaller: Bool
    let renderReady: Bool
    let provisionallyNavigating: Bool
}
