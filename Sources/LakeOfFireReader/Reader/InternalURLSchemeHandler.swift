import Foundation
import WebKit
import LakeOfFireFiles

public final class InternalURLSchemeHandler: NSObject, WKURLSchemeHandler {
    public var sharedReaderFontAsset: SharedReaderFontAsset?
    var externalSegmentSidecarStore: ReaderExternalSegmentSidecarStore = .shared

    enum CustomSchemeHandlerError: Error {
        case notFound
    }

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "local" else {
            urlSchemeTask.didFailWithError(CustomSchemeHandlerError.notFound)
            return
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
        if url.path.hasPrefix(
            ReaderExternalSegmentSidecarScheme.internalReader.endpointPathPrefix
        ) {
            guard let sidecar = readerExternalSegmentSidecarResponse(
                for: url,
                scheme: .internalReader,
                store: externalSegmentSidecarStore
            ) else {
                urlSchemeTask.didFailWithError(CustomSchemeHandlerError.notFound)
                return
            }
            urlSchemeTask.didReceive(sidecar.response)
            urlSchemeTask.didReceive(sidecar.data)
            urlSchemeTask.didFinish()
            return
        }
        let response = URLResponse(
            url: url,
            mimeType: "text/html",
            expectedContentLength: 0,
            textEncodingName: nil)
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(Data())
        urlSchemeTask.didFinish()
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
    }
}
