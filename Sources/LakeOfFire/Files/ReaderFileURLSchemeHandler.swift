import Foundation
import WebKit

final class ReaderFileURLSchemeHandler: NSObject, WKURLSchemeHandler {
    @MainActor var readerFileManager: ReaderFileManager? = nil
    
    enum CustomSchemeHandlerError: Error {
        case fileNotFound
    }
    
    override init() {
        super.init()
    }
    
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
    }
    
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        Task { @MainActor in
            guard let readerFileManager = readerFileManager, let contentFile = try? await ReaderFileManager.get(fileURL: url), var data = try? await readerFileManager.read(fileURL: url) else {
                urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                return
            }
            
            var mimeType = contentFile.mimeType
            var textEncodingName: String?
            if contentFile.mimeType == "text/plain", let text = String(data: data, encoding: .utf8), let convertedData = ReaderContentLoader.textToHTML(text, forceRaw: true).data(using: .utf8) {
                mimeType = "text/html"
                textEncodingName = "UTF-8"
                data = convertedData
            }
            
            let response = HTTPURLResponse(
                url: url,
                mimeType: mimeType,
                expectedContentLength: data.count,
                textEncodingName: textEncodingName)
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        }
    }
}
