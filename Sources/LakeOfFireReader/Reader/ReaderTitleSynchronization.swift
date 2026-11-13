import Foundation
import Combine
import LakeOfFireContent
import SwiftUIWebView

/// Latest title projection owned by a mounted Reader; SwiftUI owns its task.
@MainActor
final class ReaderTitleSynchronization: ObservableObject {
    typealias Check = @MainActor @Sendable () -> Bool
    private struct Key: Equatable {
        let source: ReaderContentTitleSnapshot.Identity
        let binding: WebViewScriptCaller.JavaScriptBindingToken
        let renderReady: Bool
    }
    private var epoch = UUID()
    private var acknowledged: Key?

    func deliver(
        snapshot: ReaderContentTitleSnapshot,
        binding: WebViewScriptCaller.JavaScriptBindingToken,
        renderReady: Bool = false,
        isCurrent: @escaping Check,
        evaluate: @MainActor (_ script: String, _ arguments: [String: any Sendable],
                             _ continueWhile: @escaping Check) async throws -> Void
    ) async -> Bool {
        let originalEpoch = epoch
        guard !Task.isCancelled, snapshot.isCurrent, isCurrent(), !Task.isCancelled,
              epoch == originalEpoch else { return false }
        let id = UUID()
        epoch = id
        let current: Check = { [weak self] in
            guard !Task.isCancelled, self?.epoch == id, snapshot.isCurrent,
                  isCurrent(), !Task.isCancelled else { return false }
            guard self?.epoch == id, snapshot.isCurrent else { return false }
            return self?.epoch == id && !Task.isCancelled
        }
        guard current() else { return false }
        let key = Key(source: snapshot.identity, binding: binding, renderReady: renderReady)
        if acknowledged == key { return current() }
        // A failed fanout may already have updated an earlier target.
        acknowledged = nil
        let title = ReaderContentLoader.resolvedDisplayTitle(snapshot.rawTitle,
            needsClipboardIndicator: snapshot.needsClipboardIndicator)
        do {
            try await evaluate("""
                (function() {
                  const el = document.getElementById('reader-title');
                  const body = document.body;
                  if (el && el.textContent !== title) { el.textContent = title; }
                  if (body) { body.classList.toggle(bodyClassName, !!hideReaderTitle); }
                })();
                """, [
                    "title": title,
                    "bodyClassName": ReaderContentLoader.snippetReaderTitleSuppressionBodyClass,
                    "hideReaderTitle": snapshot.hidesReaderTitle
                ], current)
            guard current() else { return false }
            acknowledged = key
            return true
        } catch { return false }
    }

    func retire() {
        epoch = UUID()
        acknowledged = nil
    }
}

struct ReaderTitleSynchronizationTaskID: Hashable {
    let source: ReaderContentTitleSnapshot.Identity?
    let binding: WebViewScriptCaller.JavaScriptBindingToken?
    let nativePageURL: URL
    let renderedURL: URL
    let renderReady: Bool
    let provisionallyNavigating: Bool
    let eventRevision: UInt64
}
