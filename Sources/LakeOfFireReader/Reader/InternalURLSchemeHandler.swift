import Foundation
import LakeOfFireWeb
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireContent
import LakeOfFireCore
import WebKit

@inline(__always)
private func readerLoadSchemeLog(_ stage: String, _ metadata: [String: String] = [:]) {
#if DEBUG
    let payload = metadata
        .sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value)" }
        .joined(separator: " ")
    if payload.isEmpty {
        Swift.debugPrint("# READERLOAD stage=\(stage)")
    } else {
        Swift.debugPrint("# READERLOAD stage=\(stage) \(payload)")
    }
#endif
}

public final class InternalURLSchemeHandler: NSObject, WKURLSchemeHandler {
    public var sharedReaderFontAsset: SharedReaderFontAsset?
    private static let readerLoaderStartedAtKeyPrefix = "InternalURLSchemeHandler.readerLoader.startedAt."
    private static let readerLoaderResponseAtKeyPrefix = "InternalURLSchemeHandler.readerLoader.responseAt."
    private static let readerLoaderDataAtKeyPrefix = "InternalURLSchemeHandler.readerLoader.dataAt."
    private static let readerLoaderFinishedAtKeyPrefix = "InternalURLSchemeHandler.readerLoader.finishedAt."

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
        if url.path == "/load/reader" {
            UserDefaults.standard.set(
                startedAt.timeIntervalSince1970,
                forKey: Self.readerLoaderStartedAtKeyPrefix + url.absoluteString
            )
            readerLoadSchemeLog(
                "internalScheme.readerLoader.begin",
                [
                    "url": url.absoluteString,
                    "mainDocumentURL": urlSchemeTask.request.mainDocumentURL?.absoluteString ?? "nil",
                    "webViewURL": webView.url?.absoluteString ?? "nil"
                ]
            )
        }
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
                    "elapsed": String(format: "%.3fs", Date().timeIntervalSince(startedAt)),
                    "url": url.absoluteString,
                    "bytes": String(fontResponse.data.count),
                    "status": String(fontResponse.response.statusCode)
                ]
            )
            return
        }
        let response = URLResponse(
            url: url,
            mimeType: "text/html",
            expectedContentLength: 0,
            textEncodingName: nil)
        urlSchemeTask.didReceive(response)
        if url.path == "/load/reader" {
            UserDefaults.standard.set(
                Date().timeIntervalSince1970,
                forKey: Self.readerLoaderResponseAtKeyPrefix + url.absoluteString
            )
        }
        urlSchemeTask.didReceive(Data())
        if url.path == "/load/reader" {
            UserDefaults.standard.set(
                Date().timeIntervalSince1970,
                forKey: Self.readerLoaderDataAtKeyPrefix + url.absoluteString
            )
        }
        urlSchemeTask.didFinish()
        if url.path == "/load/reader" {
            UserDefaults.standard.set(
                Date().timeIntervalSince1970,
                forKey: Self.readerLoaderFinishedAtKeyPrefix + url.absoluteString
            )
        }
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
