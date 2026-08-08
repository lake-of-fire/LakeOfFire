import Foundation
import LakeOfFireContent
import LakeOfFireCore
import WebKit
import ZIPFoundation

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
    public static let shared = ReaderFileURLSchemeActor()
    
    public init() { }
}

public final class ReaderFileURLSchemeHandler: NSObject, WKURLSchemeHandler {
    @ReaderFileURLSchemeActor public var readerFileManager: ReaderFileManager? = nil
    public var sharedReaderFontAsset: SharedReaderFontAsset?
    
    private let schemeTaskCompletionOwnership = URLSchemeTaskCompletionOwnership()
    
    public override init() {
        super.init()
    }
    
    enum CustomSchemeHandlerError: Error {
        case fileNotFound
    }

    @discardableResult
    private func finishActiveTask(
        _ urlSchemeTask: WKURLSchemeTask,
        response: URLResponse,
        data: Data? = nil
    ) -> Bool {
        guard schemeTaskCompletionOwnership.claimCompletion(urlSchemeTask as AnyObject) else {
            return false
        }
        urlSchemeTask.didReceive(response)
        if let data {
            urlSchemeTask.didReceive(data)
        }
        urlSchemeTask.didFinish()
        return true
    }

    @discardableResult
    private func failActiveTask(
        _ urlSchemeTask: WKURLSchemeTask,
        error: Error
    ) -> Bool {
        guard schemeTaskCompletionOwnership.claimCompletion(urlSchemeTask as AnyObject) else {
            return false
        }
        urlSchemeTask.didFailWithError(error)
        return true
    }
    
    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        schemeTaskCompletionOwnership.cancel(urlSchemeTask as AnyObject)
    }
    
    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        schemeTaskCompletionOwnership.begin(urlSchemeTask as AnyObject)
        guard let url = urlSchemeTask.request.url else {
            failActiveTask(urlSchemeTask, error: CustomSchemeHandlerError.fileNotFound)
            return
        }
        let sharedReaderFontAsset = self.sharedReaderFontAsset
        
        let workTask = Task { @ReaderFileURLSchemeActor in
            guard !Task.isCancelled else { return }
            if let fontResponse = sharedReaderFontResponse(
                for: url,
                asset: sharedReaderFontAsset
            ) {
                await { @MainActor in
                    self.finishActiveTask(
                        urlSchemeTask,
                        response: fontResponse.response,
                        data: fontResponse.data
                    )
                }()
                return
            }
            guard let readerFileManager else {
                await { @MainActor in
                    self.failActiveTask(
                        urlSchemeTask,
                        error: CustomSchemeHandlerError.fileNotFound
                    )
                }()
                return
            }
            
            do {
                try Task.checkCancellation()
                // Package (eg ZIP) subpath file
                if let urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let subpathValue = urlComponents.queryItems?.first(where: { $0.name == "subpath" })?.value {
                    if zipArchiveExtensions.contains(url.pathExtension.lowercased()),
                       let readerFileURL = url.deletingQuery,
                       let readerBackingURL = readerFileManager.canonicalReaderBackingURL(for: readerFileURL) {
                        let localArchiveURL = try await readerFileManager.resolveReadableLocalURL(
                            forReaderBackingURL: readerBackingURL
                        )
                        try Task.checkCancellation()
                        if let archive = Archive(url: localArchiveURL, accessMode: .read),
                           let entry = archive[subpathValue],
                           entry.type == .file {
                            var imageData = Data()
                            try archive.extract(entry, consumer: { imageData.append($0) })
                            try Task.checkCancellation()

                            let subpathExtension = (subpathValue as NSString).pathExtension.lowercased()
                            let response = HTTPURLResponse(
                                url: url,
                                mimeType: "image/\(subpathExtension)",
                                expectedContentLength: imageData.count,
                                textEncodingName: nil
                            )
                            await { @MainActor in
                                self.finishActiveTask(
                                    urlSchemeTask,
                                    response: response,
                                    data: imageData
                                )
                            }()
                            return
                        }
                    }
                    await { @MainActor in
                        self.failActiveTask(
                            urlSchemeTask,
                            error: CustomSchemeHandlerError.fileNotFound
                        )
                    }()
                    return
                }
                let contentFile = try? await ReaderFileManager.get(fileURL: url)
                try Task.checkCancellation()
                let fileData = try? await readerFileManager.read(fileURL: url)
                try Task.checkCancellation()
                if let contentFile,
                   var data = fileData {
                    // File
                    var mimeType = contentFile.mimeType
                    var textEncodingName: String?
                    if let text = String(data: data, encoding: .utf8),
                       ReaderContentLoader.supportsReaderContent(
                        mimeType: contentFile.mimeType,
                        pathExtension: url.pathExtension
                       ),
                       let convertedData = ReaderContentLoader.normalizeIngestedText(
                        text,
                        mimeType: contentFile.mimeType,
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
                        textEncodingName: textEncodingName
                    )
                    
                    await { @MainActor in
                        self.finishActiveTask(
                            urlSchemeTask,
                            response: response,
                            data: data
                        )
                    }()
                } else {
                    await { @MainActor in
                        self.failActiveTask(
                            urlSchemeTask,
                            error: CustomSchemeHandlerError.fileNotFound
                        )
                    }()
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                await { @MainActor in
                    self.failActiveTask(
                        urlSchemeTask,
                        error: CustomSchemeHandlerError.fileNotFound
                    )
                }()
            }
        }
        schemeTaskCompletionOwnership.attachCancellation(
            urlSchemeTask as AnyObject,
            cancellation: { workTask.cancel() }
        )
    }
}
