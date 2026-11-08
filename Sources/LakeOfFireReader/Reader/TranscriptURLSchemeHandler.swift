import Foundation
@preconcurrency import WebKit
import LakeOfFireCore
import LakeOfFireContent

@MainActor
public final class TranscriptURLSchemeHandler: NSObject, WKURLSchemeHandler {
    enum TranscriptSchemeError: Error {
        case notFound
        case invalidRoute
    }

    private final class Pending {
        var task: Task<Void, Never>?
    }

    private var pendingTasks: [ObjectIdentifier: Pending] = [:]
    private let responseResolver: @MainActor (URL) async throws -> (String, Data)

    public nonisolated override init() {
        responseResolver = { url in
            try await Self.resolveResponse(for: url)
        }
        super.init()
    }

    init(responseResolver: @escaping @MainActor (URL) async throws -> (String, Data)) {
        self.responseResolver = responseResolver
        super.init()
    }

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask)
        // A repeated start replaces this object's previous attempt, even if the new URL is invalid.
        pendingTasks.removeValue(forKey: identifier)?.task?.cancel()
        guard let url = urlSchemeTask.request.url, url.isTranscriptURL else {
            urlSchemeTask.didFailWithError(TranscriptSchemeError.notFound)
            return
        }

        let pending = Pending()
        // Register ownership before launching work, including a resolver that completes immediately.
        pendingTasks[identifier] = pending
        pending.task = Task { @MainActor [weak self, weak pending] in
            guard let self, let pending else { return }
            do {
                let (mimeType, data) = try await self.responseResolver(url)
                guard !Task.isCancelled, self.pendingTasks[identifier] === pending else { return }
                let response = URLResponse(
                    url: url,
                    mimeType: mimeType,
                    expectedContentLength: data.count,
                    textEncodingName: "utf-8"
                )

                urlSchemeTask.didReceive(response)
                // WebKit callbacks can synchronously stop or replace this attempt.
                guard self.pendingTasks[identifier] === pending else { return }
                urlSchemeTask.didReceive(data)
                guard self.pendingTasks[identifier] === pending else { return }
                // Retire before the terminal callback so its reentrant successor survives.
                self.pendingTasks.removeValue(forKey: identifier)
                urlSchemeTask.didFinish()
            } catch {
                guard !Task.isCancelled, self.pendingTasks[identifier] === pending else { return }
                self.pendingTasks.removeValue(forKey: identifier)
                urlSchemeTask.didFailWithError(error)
            }
        }
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        pendingTasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.task?.cancel()
    }

    // Internal observation lets lifecycle tests await the exact attempt, including after replacement.
    func pendingTask(for urlSchemeTask: WKURLSchemeTask) -> Task<Void, Never>? {
        pendingTasks[ObjectIdentifier(urlSchemeTask)]?.task
    }

    private static func resolveResponse(for url: URL) async throws -> (String, Data) {
        if url.isTranscriptPageURL,
           let data = await TranscriptPageRegistry.shared.htmlData(for: url) {
            return ("text/html", data)
        }

        if url.isTranscriptVTTURL,
           let data = await TranscriptPageRegistry.shared.webVTTData(for: url) {
            return ("text/vtt", data)
        }

        throw url.isTranscriptURL ? TranscriptSchemeError.invalidRoute : TranscriptSchemeError.notFound
    }
}
