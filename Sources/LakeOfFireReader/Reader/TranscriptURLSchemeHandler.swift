import Foundation
import WebKit
import LakeOfFireCore
import LakeOfFireContent

/// WebKit calls and response delivery share the main actor. Stop retires the
/// request before cancellation, including a stop reentered from didReceive.
@MainActor
public final class TranscriptURLSchemeHandler: NSObject, WKURLSchemeHandler {
    enum TranscriptSchemeError: Error { case notFound }

    private var pendingTasks: [ObjectIdentifier: (UUID, Task<Void, Never>)] = [:]

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.isTranscriptURL else {
            urlSchemeTask.didFailWithError(TranscriptSchemeError.notFound)
            return
        }
        let identifier = ObjectIdentifier(urlSchemeTask)
        let token = UUID()
        let task = Task { @MainActor in
            let data: Data?
            let mimeType: String
            if url.isTranscriptPageURL {
                data = await TranscriptPageRegistry.shared.htmlData(for: url)
                mimeType = "text/html"
            } else {
                data = await TranscriptPageRegistry.shared.webVTTData(for: url)
                mimeType = "text/vtt"
            }
            guard pendingTasks[identifier]?.0 == token, !Task.isCancelled else { return }
            guard let data else {
                pendingTasks.removeValue(forKey: identifier)
                urlSchemeTask.didFailWithError(TranscriptSchemeError.notFound)
                return
            }
            let response = URLResponse(url: url, mimeType: mimeType,
                expectedContentLength: data.count, textEncodingName: "utf-8")
            urlSchemeTask.didReceive(response)
            guard pendingTasks[identifier]?.0 == token, !Task.isCancelled else { return }
            urlSchemeTask.didReceive(data)
            guard pendingTasks[identifier]?.0 == token, !Task.isCancelled else { return }
            pendingTasks.removeValue(forKey: identifier)
            urlSchemeTask.didFinish()
        }
        pendingTasks.removeValue(forKey: identifier)?.1.cancel()
        pendingTasks[identifier] = (token, task)
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        pendingTasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.1.cancel()
    }
}
