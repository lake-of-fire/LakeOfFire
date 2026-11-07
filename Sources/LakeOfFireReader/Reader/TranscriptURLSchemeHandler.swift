import Foundation
@preconcurrency import WebKit
import LakeOfFireCore
import LakeOfFireContent

@MainActor
public final class TranscriptURLSchemeHandler: NSObject, WKURLSchemeHandler {
    enum TranscriptSchemeError: Error { case notFound, invalidRoute }

    private final class Pending {
        var task: Task<Void, Never>?
    }
    private var pendingTasks: [ObjectIdentifier: Pending] = [:]

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.isTranscriptURL else {
            urlSchemeTask.didFailWithError(TranscriptSchemeError.invalidRoute)
            return
        }
        let identifier = ObjectIdentifier(urlSchemeTask)
        let pending = Pending()
        pendingTasks[identifier]?.task?.cancel()
        // Install ownership before the asynchronous task can finish.
        pendingTasks[identifier] = pending
        pending.task = Task { @MainActor [weak self, weak pending] in
            guard let self, let pending else { return }
            let mimeType: String
            let data: Data?
            if url.isTranscriptPageURL {
                mimeType = "text/html"
                data = await TranscriptPageRegistry.shared.htmlData(for: url)
            } else if url.isTranscriptVTTURL {
                mimeType = "text/vtt"
                data = await TranscriptPageRegistry.shared.webVTTData(for: url)
            } else {
                mimeType = "text/plain"
                data = nil
            }
            guard !Task.isCancelled, self.pendingTasks[identifier] === pending else { return }
            guard let data else {
                self.pendingTasks.removeValue(forKey: identifier)
                urlSchemeTask.didFailWithError(TranscriptSchemeError.notFound)
                return
            }
            let response = URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: "utf-8")
            urlSchemeTask.didReceive(response)
            guard self.pendingTasks[identifier] === pending else { return }
            urlSchemeTask.didReceive(data)
            guard self.pendingTasks[identifier] === pending else { return }
            self.pendingTasks.removeValue(forKey: identifier)
            urlSchemeTask.didFinish()
        }
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        pendingTasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.task?.cancel()
    }
}
