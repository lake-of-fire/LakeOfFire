import Foundation
import WebKit
import ZIPFoundation
import RealmSwift

fileprivate extension URL {
    var deletingQuery: URL? {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.query = nil
        return components?.url
    }
}

fileprivate let zipArchiveExtensions = ["zip", "epub"]

@globalActor
public actor ReaderFileURLSchemeActor {
    public static var shared = ReaderFileURLSchemeActor()
    
    public init() { }
}


final class ReaderFileURLSchemeHandler: NSObject, WKURLSchemeHandler {
    @ReaderFileURLSchemeActor var readerFileManager: ReaderFileManager? = nil
    
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
        
        Task { @ReaderFileURLSchemeActor in
            guard let readerFileManager else {
                urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                return
            }
            
            do {
                // Package (eg ZIP) subpath file
                if let urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let subpathValue = urlComponents.queryItems?.first(where: { $0.name == "subpath" })?.value {
                    if zipArchiveExtensions.contains(url.pathExtension.lowercased()), let readerFileURL = url.deletingQuery, let archive = Archive(url: readerFileURL, accessMode: .read), let entry = archive[subpathValue], entry.type == .file {
                        var imageData = Data()
                        try archive.extract(entry, consumer: { imageData.append($0) })
                        
                        let subpathExtension = (subpathValue as NSString).pathExtension.lowercased()
                        let response = HTTPURLResponse(
                            url: url,
                            mimeType: "image/\(subpathExtension)",
                            expectedContentLength: imageData.count,
                            textEncodingName: nil
                        )
                        await { @MainActor in
                            if self.schemeHandlers[urlSchemeTask.hash] != nil {
                                urlSchemeTask.didReceive(response)
                                urlSchemeTask.didReceive(imageData)
                                urlSchemeTask.didFinish()
                                self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                                return
                            } else {
                                urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                            }
                        }()
                    }
                } else if
                    let contentFilePrimaryKey = try? await ReaderFileManager.contentFilePrimaryKey(for: url),
                    var data = try? await readerFileManager.read(fileURL: url)
                {
                    // File
                    var mimeType = (try? await ReaderFileManager.mimeType(forContentFilePrimaryKey: contentFilePrimaryKey)) ?? "application/octet-stream"
                    var textEncodingName: String?
                    if mimeType == "text/plain", let text = String(data: data, encoding: .utf8), let convertedData = ReaderContentLoader.textToHTML(text, forceRaw: true).data(using: .utf8) {
                        mimeType = "text/html"
                        textEncodingName = "UTF-8"
                        data = convertedData
                    }
                    
                    let response = HTTPURLResponse(
                        url: url,
                        mimeType: mimeType,
                        expectedContentLength: data.count,
                        textEncodingName: textEncodingName)
                    
                    await { @MainActor in
                        if self.schemeHandlers[urlSchemeTask.hash] != nil {
                            urlSchemeTask.didReceive(response)
                            urlSchemeTask.didReceive(data)
                            urlSchemeTask.didFinish()
                            self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                        } else {
                            urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                        }
                    }()
                } else {
                    await { @MainActor in
                        urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                    }()
                }
            } catch {
                await { @MainActor in
                    urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                }()
            }
        }
    }
}
