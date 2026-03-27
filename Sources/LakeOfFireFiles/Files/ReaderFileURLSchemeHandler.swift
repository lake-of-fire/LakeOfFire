import Foundation
import WebKit
import RealmSwift
import LakeOfFireContent
import LakeOfFireCore
import LakeOfFireAdblock

fileprivate extension URL {
    var deletingQuery: URL? {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.query = nil
        return components?.url
    }
}

@globalActor
public actor ReaderFileURLSchemeActor {
    public static var shared = ReaderFileURLSchemeActor()
    
    public init() { }
}


public final class ReaderFileURLSchemeHandler: NSObject, WKURLSchemeHandler {
    @ReaderFileURLSchemeActor public var readerFileManager: ReaderFileManager? = nil
    
    private var schemeHandlers: [Int: WKURLSchemeTask] = [:]
    
    public override init() {
        super.init()
    }
    
    enum CustomSchemeHandlerError: Error {
        case fileNotFound
    }
    
    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
    }
    
    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
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
                    if let readerFileURL = url.deletingQuery {
                        let cachedSource = try await ReaderPackageEntrySourceCache.shared.cachedSource(
                            forPackageURL: readerFileURL,
                            readerFileManager: readerFileManager
                        )
                        let data = try cachedSource.source.readEntry(subpath: subpathValue)
                        let metadata = try cachedSource.source.mimeType(subpath: subpathValue)
                        let response = HTTPURLResponse(
                            url: url,
                            mimeType: metadata.mimeType,
                            expectedContentLength: data.count,
                            textEncodingName: metadata.textEncodingName
                        )
                        await { @MainActor in
                            if self.schemeHandlers[urlSchemeTask.hash] != nil {
                                urlSchemeTask.didReceive(response)
                                urlSchemeTask.didReceive(data)
                                urlSchemeTask.didFinish()
                                self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                                return
                            } else {
                                urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                            }
                        }()
                    } else {
                        await { @MainActor in
                            urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                        }()
                    }
                } else if
                    let contentFilePrimaryKey = try? await ReaderFileManager.contentFilePrimaryKey(for: url),
                    var data = try? await readerFileManager.read(fileURL: url)
                {
                    // File
                    var mimeType = (try? await ReaderFileManager.mimeType(forContentFilePrimaryKey: contentFilePrimaryKey)) ?? "application/octet-stream"
                    var textEncodingName: String?
                    if let text = String(data: data, encoding: .utf8),
                       ReaderContentLoader.supportsReaderContent(mimeType: mimeType, pathExtension: url.pathExtension),
                       let convertedData = ReaderContentLoader.normalizeIngestedText(
                        text,
                        mimeType: mimeType,
                        pathExtension: url.pathExtension,
                        source: .file
                       ).html.data(using: .utf8) {
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
