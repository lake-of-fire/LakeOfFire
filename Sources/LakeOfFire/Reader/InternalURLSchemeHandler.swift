import Foundation
import WebKit

public final class InternalURLSchemeHandler: NSObject, WKURLSchemeHandler {
    enum CustomSchemeHandlerError: Error {
        case notFound
        case missingKey
    }

    private var pendingTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let taskQueue = DispatchQueue(label: "InternalURLSchemeHandler.tasks")
    private let snippetPath = "/snippet"

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "local" else {
            urlSchemeTask.didFailWithError(CustomSchemeHandlerError.notFound)
            return
        }

        if url.path == snippetPath {
            handleSnippetRequest(url: url, task: urlSchemeTask)
            return
        }

        // Default: return empty body; reader mode will inject content later.
        let response = URLResponse(
            url: url,
            mimeType: "text/html",
            expectedContentLength: 0,
            textEncodingName: nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(Data())
        urlSchemeTask.didFinish()
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask)
        taskQueue.sync {
            pendingTasks[identifier]?.cancel()
            pendingTasks.removeValue(forKey: identifier)
        }
    }

    private func handleSnippetRequest(url: URL, task urlSchemeTask: WKURLSchemeTask) {
        guard let key = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "key" })?.value,
              !key.isEmpty else {
            debugPrint("# READER snippetScheme.error", "reason=missingKey", "url=\(url.absoluteString)")
            urlSchemeTask.didFailWithError(CustomSchemeHandlerError.missingKey)
            return
        }
        debugPrint("# READER snippetScheme.start", "key=\(key)", "url=\(url.absoluteString)")
        debugPrint("# SNIPPETLOAD snippetScheme.shell", "key=\(key)")
        let response = URLResponse(
            url: url,
            mimeType: "text/html",
            expectedContentLength: 0,
            textEncodingName: nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(Data())
        urlSchemeTask.didFinish()
        return

    }

}
