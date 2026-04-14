import Foundation
import WebKit

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
    enum CustomSchemeHandlerError: Error {
        case notFound
    }
    
    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let startedAt = Date()
        guard let url = urlSchemeTask.request.url, url.host == "local" else {
            readerLoadSchemeLog(
                "internalScheme.startFailed",
                [
                    "url": urlSchemeTask.request.url?.absoluteString ?? "nil",
                    "reason": "notLocalHost"
                ]
            )
            urlSchemeTask.didFailWithError(CustomSchemeHandlerError.notFound)
            return
        }
        readerLoadSchemeLog(
            "internalScheme.start",
            [
                "url": url.absoluteString,
                "mainDocumentURL": urlSchemeTask.request.mainDocumentURL?.absoluteString ?? "nil",
                "webViewURL": webView.url?.absoluteString ?? "nil"
            ]
        )
        let response = URLResponse(
            url: url,
            mimeType: "text/html",
            expectedContentLength: 0,
            textEncodingName: nil)
        urlSchemeTask.didReceive(response)
        readerLoadSchemeLog(
            "internalScheme.didReceiveResponse",
            [
                "elapsed": String(format: "%.3fs", Date().timeIntervalSince(startedAt)),
                "url": url.absoluteString
            ]
        )
        urlSchemeTask.didReceive(Data())
        readerLoadSchemeLog(
            "internalScheme.didReceiveData",
            [
                "elapsed": String(format: "%.3fs", Date().timeIntervalSince(startedAt)),
                "url": url.absoluteString
            ]
        )
        urlSchemeTask.didFinish()
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
    }
}
