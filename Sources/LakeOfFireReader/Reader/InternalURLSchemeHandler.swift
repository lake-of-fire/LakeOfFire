import Foundation
import LakeOfFireWeb
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireContent
import LakeOfFireCore
import WebKit

// Paint the document canvas even while the article body is hidden by its
// font gate. Both loader and final reader HTML must agree before scripts run.
func readerDocumentCanvasCSS() -> String {
    let lightBackground = UserDefaults.standard.string(forKey: "lightModeTheme") == "beige"
        ? "#f7f0d8" : "#ffffff"
    let darkBackground = UserDefaults.standard.string(forKey: "darkModeTheme") == "gray"
        ? "#313234" : "#000000"
    return """
    html { color-scheme: light dark; background: \(lightBackground); }
    @media (prefers-color-scheme: dark) { html { background: \(darkBackground); } }
    html:has(body[data-mnb-color-scheme="light"][data-mnb-light-theme="white"]) { background: #ffffff; }
    html:has(body[data-mnb-color-scheme="light"][data-mnb-light-theme="beige"]) { background: #f7f0d8; }
    html:has(body[data-mnb-color-scheme="dark"][data-mnb-dark-theme="black"]) { background: #000000; }
    html:has(body[data-mnb-color-scheme="dark"][data-mnb-dark-theme="gray"]) { background: #313234; }
    """
}

public final class InternalURLSchemeHandler: NSObject, WKURLSchemeHandler {
    public var sharedReaderFontAsset: SharedReaderFontAsset?
    var assetService = ReaderAssetService.shared
    private let completionOwnership = URLSchemeTaskCompletionOwnership()
    enum CustomSchemeHandlerError: Error {
        case notFound
    }
    
    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        completionOwnership.begin(urlSchemeTask as AnyObject)
        guard let url = urlSchemeTask.request.url, url.host == "local" else {
            fail(urlSchemeTask, error: CustomSchemeHandlerError.notFound)
            return
        }
        if url.isReaderDocumentURL, let document = ReaderDocumentResourceRegistry.shared.takeDocument(at: url) {
            ReaderLoadTrace.$operationID.withValue(document.generation) {
                // Distinguish WebKit reaching the handler from native delivery
                // and the later commit. Never log the presentation URL/token.
                let delivery = ReaderLoadTrace.begin("reader.documentDelivery")
                defer { delivery?.end("bytes=\(document.data.count)") }
                document.cookieContext.bind(webView.configuration.websiteDataStore, userAgent: urlSchemeTask.request.value(forHTTPHeaderField: "User-Agent") ?? webView.customUserAgent)
                finish(urlSchemeTask, response: internalReaderResponse(url: url, mimeType: "text/html; charset=utf-8", length: document.data.count), data: document.data)
            }
            return
        }
        if url.isReaderDocumentURL {
            ReaderLoadTrace.event("reader.documentReconstructionRequested")
        }
        if url.path == "/reader-components.js", let data = readerBundledComponent("reader-components", extension: "js") {
            finish(urlSchemeTask, response: URLResponse(url: url, mimeType: "text/javascript", expectedContentLength: data.count, textEncodingName: "utf-8"), data: data)
            return
        }
        if let id = readerRegistrationID(in: url, prefix: "reader-asset", allowsFragment: true) ?? readerRegistrationID(in: url, prefix: "reader-embed") {
            guard let entry = ReaderDocumentResourceRegistry.shared.entry(for: id) else {
                fail(urlSchemeTask, error: CustomSchemeHandlerError.notFound); return
            }
            let requestID = UUID()
            let work = Task { @MainActor in
                defer { ReaderDocumentResourceRegistry.shared.finish(id: id, request: requestID) }
                do {
                    let data: Data
                    let mime: String
                    if url.path.hasPrefix("/reader-embed/") {
                        switch entry.resource {
                        case .remoteHTML, .inlineHTML, .mediaFile: break
                        default: throw CustomSchemeHandlerError.notFound
                        }
                        let localURL = try await ReaderLoopbackServer.shared.url(for: id)
                        data = try JSONSerialization.data(withJSONObject: ["url": localURL.absoluteString])
                        mime = "application/json"
                    } else {
                        switch entry.resource {
                        case .image, .caption, .svgSymbol: break
                        default: throw CustomSchemeHandlerError.notFound
                        }
                        entry.cookieContext.bind(webView.configuration.websiteDataStore, userAgent: urlSchemeTask.request.value(forHTTPHeaderField: "User-Agent") ?? webView.customUserAgent)
                        let cookies = entry.allowsCookies ? await entry.cookieContext.cookies() : []
                        let asset = try await assetService.load(entry: entry, cookies: cookies)
                        data = asset.data; mime = asset.mimeType
                    }
                    try Task.checkCancellation()
                    guard ReaderDocumentResourceRegistry.shared.entry(for: id) != nil else { throw CancellationError() }
                    self.finish(urlSchemeTask, response: internalReaderResponse(url: url, mimeType: mime, length: data.count), data: data)
                } catch {
                    self.fail(urlSchemeTask, error: error)
                }
            }
            completionOwnership.attachCancellation(urlSchemeTask as AnyObject) { work.cancel() }
            ReaderDocumentResourceRegistry.shared.attach(id: id, request: requestID) { work.cancel() }
            return
        }
        if let fontResponse = sharedReaderFontResponse(
            for: url,
            asset: sharedReaderFontAsset
        ) {
            finish(urlSchemeTask, response: fontResponse.response, data: fontResponse.data)
            return
        }
        if url.path.hasPrefix(ReaderExternalSegmentSidecarScheme.internalReader.endpointPathPrefix) {
            guard let sidecar = readerExternalSegmentSidecarResponse(
                for: url,
                scheme: .internalReader
            ) else {
                fail(urlSchemeTask, error: CustomSchemeHandlerError.notFound)
                return
            }
            finish(urlSchemeTask, response: sidecar.response, data: sidecar.data)
            return
        }
        // The loader commits before native article processing completes. An
        // empty HTML response uses WebKit's light canvas even in dark mode.
        // Give that first document its theme before its first paint.
        let data: Data
        if url.isReaderURLLoaderURL || url.isReaderDocumentURL {
            data = Data("""
            <!doctype html><html><head>
            <meta name="color-scheme" content="light dark">
            <style>
            \(readerDocumentCanvasCSS())
            </style></head><body data-mnb-reader-shell="1"></body></html>
            """.utf8)
        } else { fail(urlSchemeTask, error: CustomSchemeHandlerError.notFound); return }
        let response = URLResponse(
            url: url,
            mimeType: "text/html",
            expectedContentLength: data.count,
            textEncodingName: data.isEmpty ? nil : "utf-8")
        finish(urlSchemeTask, response: response, data: data)
    }
    
    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        completionOwnership.cancel(urlSchemeTask as AnyObject)
        ReaderLoadTrace.event("reader.resourceCancelled")
    }

    private func finish(_ task: WKURLSchemeTask, response: URLResponse, data: Data) {
        guard completionOwnership.claimCompletion(task as AnyObject) else { return }
        task.didReceive(response); task.didReceive(data); task.didFinish()
    }

    private func fail(_ task: WKURLSchemeTask, error: Error) {
        guard completionOwnership.claimCompletion(task as AnyObject) else { return }
        task.didFailWithError(error)
    }
}

private func internalReaderResponse(url: URL, mimeType: String, length: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
        "Content-Type": mimeType, "Content-Length": String(length), "Cache-Control": "no-store",
        "X-Content-Type-Options": "nosniff"
    ])!
}
