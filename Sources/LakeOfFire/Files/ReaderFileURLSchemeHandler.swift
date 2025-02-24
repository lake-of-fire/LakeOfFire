import Foundation
import WebKit
import ZIPFoundation

fileprivate extension URL {
    var deletingQuery: URL? {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.query = nil
        return components?.url
    }
}

final class ReaderFileURLSchemeHandler: NSObject, WKURLSchemeHandler {
    @MainActor var readerFileManager: ReaderFileManager? = nil
    
    private var schemeHandlers: [Int: WKURLSchemeTask] = [:]
    
    override init() {
        super.init()
    }
    
    enum CustomSchemeHandlerError: Error {
        case fileNotFound
    }
    
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
    }
    
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        schemeHandlers[urlSchemeTask.hash] = urlSchemeTask
        
        guard let url = urlSchemeTask.request.url else { return }
        
        Task { @MainActor in
            guard let readerFileManager = readerFileManager else {
                urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                return
            }
            
            do {
                // Package (eg ZIP) subpath file
                if let urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let subpathValue = urlComponents.queryItems?.first(where: { $0.name == "subpath" })?.value {
                    if url.pathExtension.lowercased() == "zip", let readerFileURL = url.deletingQuery, let archive = Archive(url: readerFileURL, accessMode: .read), let entry = archive[subpathValue], entry.type == .file {
                        var imageData = Data()
                        try archive.extract(entry, consumer: { imageData.append($0) })
                        
                        let subpathExtension = (subpathValue as NSString).pathExtension.lowercased()
                        let response = HTTPURLResponse(
                            url: url,
                            mimeType: "image/\(subpathExtension)",
                            expectedContentLength: imageData.count,
                            textEncodingName: nil
                        )
                        if self.schemeHandlers[urlSchemeTask.hash] != nil {
                            urlSchemeTask.didReceive(response)
                            urlSchemeTask.didReceive(imageData)
                            urlSchemeTask.didFinish()
                            self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                            return
                        }
                    }
                }
                
                // File
                if let contentFile = try? await ReaderFileManager.get(fileURL: url), var data = try? await readerFileManager.read(fileURL: url) {
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
                    if self.schemeHandlers[urlSchemeTask.hash] != nil {
                        urlSchemeTask.didReceive(response)
                        urlSchemeTask.didReceive(data)
                        urlSchemeTask.didFinish()
                        self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                        return
                    }
                }
                
                urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
            } catch {
                urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
            }
        }
    }
}
