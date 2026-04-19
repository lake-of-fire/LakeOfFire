import Foundation
import WebKit
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent
import LakeOfFireFiles

@inline(__always)
private func readerLoadSchemeLog(_ stage: String, _ metadata: [String: String] = [:]) {
    let payload = metadata
        .sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }
        .joined(separator: " ")
    if payload.isEmpty {
        Swift.debugPrint("# READERLOAD stage=\(stage)")
    } else {
        Swift.debugPrint("# READERLOAD stage=\(stage) \(payload)")
    }
}

public final class InternalURLSchemeHandler: NSObject, WKURLSchemeHandler {
    public var sharedReaderFontAsset: SharedReaderFontAsset?
    private static let readerLoaderStartedAtKeyPrefix = "InternalURLSchemeHandler.readerLoader.startedAt."
    private static let readerLoaderResponseAtKeyPrefix = "InternalURLSchemeHandler.readerLoader.responseAt."
    private static let readerLoaderDataAtKeyPrefix = "InternalURLSchemeHandler.readerLoader.dataAt."
    private static let readerLoaderFinishedAtKeyPrefix = "InternalURLSchemeHandler.readerLoader.finishedAt."

    enum CustomSchemeHandlerError: Error {
        case notFound
        case missingKey
    }

    private var pendingTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let taskQueue = DispatchQueue(label: "InternalURLSchemeHandler.tasks")
    private let readerLoaderPath = "/load/reader"
    private let snippetPath = "/snippet"

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let startedAt = Date()
        guard let url = urlSchemeTask.request.url, url.host == "local" else {
            readerLoadSchemeLog(
                "internalScheme.startFailed",
                [
                    "reason": "notLocalHost",
                    "url": urlSchemeTask.request.url?.absoluteString ?? "nil"
                ]
            )
            urlSchemeTask.didFailWithError(CustomSchemeHandlerError.notFound)
            return
        }
        readerLoadSchemeLog(
            "internalScheme.start",
            [
                "mainDocumentURL": urlSchemeTask.request.mainDocumentURL?.absoluteString ?? "nil",
                "url": url.absoluteString,
                "webViewURL": webView.url?.absoluteString ?? "nil"
            ]
        )

        if let fontResponse = sharedReaderFontResponse(
            for: url,
            asset: sharedReaderFontAsset
        ) {
            urlSchemeTask.didReceive(fontResponse.response)
            urlSchemeTask.didReceive(fontResponse.data)
            urlSchemeTask.didFinish()
            readerLoadSchemeLog(
                "internalScheme.sharedReaderFont.finish",
                [
                    "bytes": String(fontResponse.data.count),
                    "elapsed": String(format: "%.3fs", Date().timeIntervalSince(startedAt)),
                    "status": String(fontResponse.response.statusCode),
                    "url": url.absoluteString
                ]
            )
            return
        }

        if url.path == snippetPath {
            handleSnippetRequest(url: url, task: urlSchemeTask)
            return
        }

        if url.path == readerLoaderPath {
            handleReaderLoaderRequest(url: url, webView: webView, task: urlSchemeTask)
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
        readerLoadSchemeLog(
            "internalScheme.didReceiveResponse",
            [
                "elapsed": String(format: "%.3fs", Date().timeIntervalSince(startedAt)),
                "url": url.absoluteString
            ]
        )
        readerLoadSchemeLog(
            "internalScheme.didReceiveData",
            [
                "elapsed": String(format: "%.3fs", Date().timeIntervalSince(startedAt)),
                "url": url.absoluteString
            ]
        )
        readerLoadSchemeLog(
            "internalScheme.didFinish",
            [
                "elapsed": String(format: "%.3fs", Date().timeIntervalSince(startedAt)),
                "url": url.absoluteString
            ]
        )
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        readerLoadSchemeLog(
            "internalScheme.stop",
            [
                "url": urlSchemeTask.request.url?.absoluteString ?? "nil",
                "webViewURL": webView.url?.absoluteString ?? "nil"
            ]
        )
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

    private func handleReaderLoaderRequest(url: URL, webView: WKWebView, task urlSchemeTask: WKURLSchemeTask) {
        let requestStartedAt = Date()
        UserDefaults.standard.set(
            requestStartedAt.timeIntervalSince1970,
            forKey: Self.readerLoaderStartedAtKeyPrefix + url.absoluteString
        )
        readerLoadSchemeLog(
            "internalScheme.readerLoader.begin",
            [
                "mainDocumentURL": urlSchemeTask.request.mainDocumentURL?.absoluteString ?? "nil",
                "url": url.absoluteString,
                "webViewURL": webView.url?.absoluteString ?? "nil"
            ]
        )
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
        let responseAt = Date()
        UserDefaults.standard.set(
            responseAt.timeIntervalSince1970,
            forKey: Self.readerLoaderResponseAtKeyPrefix + url.absoluteString
        )
        urlSchemeTask.didReceive(response)
        readerLoadSchemeLog(
            "internalScheme.readerLoader.didReceiveResponse",
            [
                "elapsed": String(format: "%.3fs", responseAt.timeIntervalSince(requestStartedAt)),
                "url": url.absoluteString
            ]
        )
        readerLoadSchemeLog(
            "internalScheme.didReceiveResponse",
            [
                "elapsed": String(format: "%.3fs", responseAt.timeIntervalSince(requestStartedAt)),
                "url": url.absoluteString
            ]
        )
        let dataAt = Date()
        UserDefaults.standard.set(
            dataAt.timeIntervalSince1970,
            forKey: Self.readerLoaderDataAtKeyPrefix + url.absoluteString
        )
        urlSchemeTask.didReceive(data)
        readerLoadSchemeLog(
            "internalScheme.readerLoader.didReceiveData",
            [
                "elapsed": String(format: "%.3fs", dataAt.timeIntervalSince(requestStartedAt)),
                "url": url.absoluteString
            ]
        )
        readerLoadSchemeLog(
            "internalScheme.didReceiveData",
            [
                "elapsed": String(format: "%.3fs", dataAt.timeIntervalSince(requestStartedAt)),
                "url": url.absoluteString
            ]
        )
        let finishAt = Date()
        urlSchemeTask.didFinish()
        UserDefaults.standard.set(
            finishAt.timeIntervalSince1970,
            forKey: Self.readerLoaderFinishedAtKeyPrefix + url.absoluteString
        )
        readerLoadSchemeLog(
            "internalScheme.readerLoader.didFinish",
            [
                "elapsed": String(format: "%.3fs", finishAt.timeIntervalSince(requestStartedAt)),
                "url": url.absoluteString
            ]
        )
        readerLoadSchemeLog(
            "internalScheme.didFinish",
            [
                "elapsed": String(format: "%.3fs", finishAt.timeIntervalSince(requestStartedAt)),
                "url": url.absoluteString
            ]
        )
    }

}
