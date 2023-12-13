import Foundation
import WebKit

public final class InternalURLSchemeHandler: NSObject, WKURLSchemeHandler {
    enum CustomSchemeHandlerError: Error {
        case notFound
    }
    
    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "local" else {
            urlSchemeTask.didFailWithError(CustomSchemeHandlerError.notFound)
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
