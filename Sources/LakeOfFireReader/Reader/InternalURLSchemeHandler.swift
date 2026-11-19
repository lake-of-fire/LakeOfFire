import Foundation
import LakeOfFireWeb
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireContent
import LakeOfFireCore
import WebKit

public final class InternalURLSchemeHandler: NSObject, WKURLSchemeHandler {
    public var sharedReaderFontAsset: SharedReaderFontAsset?
    private let schemeTaskCompletionOwnership = URLSchemeTaskCompletionOwnership()
    enum CustomSchemeHandlerError: Error {
        case notFound
    }

    private func finishActiveTask(
        _ urlSchemeTask: WKURLSchemeTask,
        response: URLResponse,
        data: Data
    ) {
        guard schemeTaskCompletionOwnership.isActive(urlSchemeTask as AnyObject) else { return }
        urlSchemeTask.didReceive(response)
        guard schemeTaskCompletionOwnership.isActive(urlSchemeTask as AnyObject) else { return }
        urlSchemeTask.didReceive(data)
        guard schemeTaskCompletionOwnership.claimCompletion(urlSchemeTask as AnyObject) else { return }
        urlSchemeTask.didFinish()
    }

    private func failActiveTask(_ urlSchemeTask: WKURLSchemeTask) {
        guard schemeTaskCompletionOwnership.claimCompletion(urlSchemeTask as AnyObject) else { return }
        urlSchemeTask.didFailWithError(CustomSchemeHandlerError.notFound)
    }
    
    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        schemeTaskCompletionOwnership.begin(urlSchemeTask as AnyObject)
        guard let url = urlSchemeTask.request.url,
              url.scheme?.lowercased() == "internal",
              url.host?.lowercased() == "local",
              url.user == nil, url.password == nil, url.port == nil else {
            failActiveTask(urlSchemeTask)
            return
        }
        if let fontResponse = sharedReaderFontResponse(
            for: url,
            asset: sharedReaderFontAsset
        ) {
            finishActiveTask(urlSchemeTask, response: fontResponse.response, data: fontResponse.data)
            return
        }
        if url.path.hasPrefix(ReaderExternalSegmentSidecarScheme.internalReader.endpointPathPrefix) {
            guard let sidecar = readerExternalSegmentSidecarResponse(
                for: url,
                scheme: .internalReader
            ) else {
                failActiveTask(urlSchemeTask)
                return
            }
            finishActiveTask(urlSchemeTask, response: sidecar.response, data: sidecar.data)
            return
        }
        // Only known document bootstraps may return an empty HTML shell.
        // Unknown internal paths must not look like successful navigations.
        let isValidReaderDocument = url.isSnippetURL
            || (url.isReaderURLLoaderURL && url.readerContentURL != nil)
        guard isValidReaderDocument else {
            failActiveTask(urlSchemeTask)
            return
        }
        let response = URLResponse(
            url: url,
            mimeType: "text/html",
            expectedContentLength: 0,
            textEncodingName: nil)
        finishActiveTask(urlSchemeTask, response: response, data: Data())
    }
    
    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        schemeTaskCompletionOwnership.cancel(urlSchemeTask as AnyObject)
    }
}
