import Foundation
import LakeOfFireWeb
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireContent
import LakeOfFireCore
import WebKit

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
            urlSchemeTask.didFailWithError(CustomSchemeHandlerError.notFound)
            return
        }
        if url.path == "/load/reader" {
            UserDefaults.standard.set(
                startedAt.timeIntervalSince1970,
                forKey: Self.readerLoaderStartedAtKeyPrefix + url.absoluteString
            )
        }
        if let fontResponse = sharedReaderFontResponse(
            for: url,
            asset: sharedReaderFontAsset
        ) {
            urlSchemeTask.didReceive(fontResponse.response)
            urlSchemeTask.didReceive(fontResponse.data)
            urlSchemeTask.didFinish()
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
    }
}
