import Foundation
import WebKit
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent

public final class InternalURLSchemeHandler: NSObject, WKURLSchemeHandler {
    enum CustomSchemeHandlerError: Error {
        case notFound
        case missingKey
    }

    private var pendingTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let taskQueue = DispatchQueue(label: "InternalURLSchemeHandler.tasks")
    private let readerLoaderPath = "/load/reader"
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

        if url.path == readerLoaderPath {
            handleReaderLoaderRequest(url: url, task: urlSchemeTask)
            return
        }

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
        let identifier = ObjectIdentifier(urlSchemeTask)
        let task = Task { @MainActor in
            do {
                guard let content = try await ReaderContentLoader.getContent(forURL: url),
                      let html = ReaderContentLoader.extractHTML(from: content) ?? content.html,
                      !html.isEmpty,
                      let data = html.data(using: .utf8)
                else {
                    debugPrint("# READER snippetScheme.error", "reason=missingHTML", "url=\(url.absoluteString)")
                    self.taskQueue.sync {
                        guard self.pendingTasks.removeValue(forKey: identifier) != nil else { return }
                        urlSchemeTask.didFailWithError(CustomSchemeHandlerError.notFound)
                    }
                    return
                }

                let response = URLResponse(
                    url: url,
                    mimeType: "text/html",
                    expectedContentLength: data.count,
                    textEncodingName: "utf-8"
                )

                self.taskQueue.sync {
                    guard self.pendingTasks[identifier] != nil else { return }
                    urlSchemeTask.didReceive(response)
                    urlSchemeTask.didReceive(data)
                    urlSchemeTask.didFinish()
                    self.pendingTasks.removeValue(forKey: identifier)
                }
            } catch {
                debugPrint("# READER snippetScheme.error", "reason=loadFailed", "url=\(url.absoluteString)", "error=\(error.localizedDescription)")
                self.taskQueue.sync {
                    guard self.pendingTasks[identifier] != nil else { return }
                    urlSchemeTask.didFailWithError(error)
                    self.pendingTasks.removeValue(forKey: identifier)
                }
            }
        }

        taskQueue.sync {
            pendingTasks[identifier] = task
        }
    }

    private func handleReaderLoaderRequest(url: URL, task urlSchemeTask: WKURLSchemeTask) {
        let html = """
        <!doctype html>
        <html>
            <head>
                <meta charset="utf-8">
                <meta name="viewport" content="width=device-width, user-scalable=no, minimum-scale=1.0, maximum-scale=1.0, initial-scale=1.0">
                <style>
                    html, body {
                        margin: 0;
                        padding: 0;
                        width: 100%;
                        min-height: 100%;
                        background: transparent;
                        overflow-x: hidden;
                    }
                </style>
            </head>
            <body></body>
        </html>
        """

        let data = Data(html.utf8)
        let response = URLResponse(
            url: url,
            mimeType: "text/html",
            expectedContentLength: data.count,
            textEncodingName: "utf-8"
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

}
