import SwiftUI
import WebKit
import UniformTypeIdentifiers
import SwiftSoup

fileprivate actor EBookProcessingActor {
    let ebookTextProcessorCacheHits: ((URL, String) async throws -> Bool)?
    let ebookTextProcessor: ((URL, String, String, Bool, ((SwiftSoup.Document, URL, Bool) async -> SwiftSoup.Document)?, ((String, Bool) async -> String)?) async throws -> String)?
    let processReadabilityContent: ((SwiftSoup.Document, URL, Bool) async -> SwiftSoup.Document)?
    let processHTML: ((String, Bool) async -> String)?
    
    init(
        ebookTextProcessorCacheHits: ((URL, String) async throws -> Bool)?,
        ebookTextProcessor: ((URL, String, String, Bool, ((SwiftSoup.Document, URL, Bool) async -> SwiftSoup.Document)?, ((String, Bool) async -> String)?) async throws -> String)?,
        processReadabilityContent: ((SwiftSoup.Document, URL, Bool) async -> SwiftSoup.Document)?,
        processHTML: ((String, Bool) async -> String)?
    ) {
        self.ebookTextProcessorCacheHits = ebookTextProcessorCacheHits
        self.ebookTextProcessor = ebookTextProcessor
        self.processReadabilityContent = processReadabilityContent
        self.processHTML = processHTML
    }
    
    func process(
        contentURL: URL,
        location: String,
        text: String,
        isCacheWarmer: Bool
    ) async -> String {
        if isCacheWarmer, let ebookTextProcessorCacheHits, (try? await ebookTextProcessorCacheHits(contentURL, location)) ?? false {
            // Bail early if we are already cached
            return ""
        }
        
        var respText = text
        if let ebookTextProcessor {
            do {
                respText = try await ebookTextProcessor(
                    contentURL,
                    location,
                    text,
                    isCacheWarmer,
                    processReadabilityContent,
                    processHTML
                )
            } catch {
                print("Error processing Ebook text: \(error)")
            }
        }
        //        debugPrint("# from: ", text.prefix(1000), "to:", respText)
        return respText
    }
}
    
fileprivate actor ZIPToEbookActor {
    static let shared = ZIPToEbookActor()
    
    func zipToEPub(directoryURL: URL) -> Data? {
        return EPub.zipToEPub(directoryURL: directoryURL)
    }
}

public extension URL {
    var isEBookURL: Bool {
        return (isFileURL || scheme == "https" || scheme == "http" || scheme == "ebook" || scheme == "ebook-url") && pathExtension.lowercased() == "epub"
    }
}

final class EbookURLSchemeHandler: NSObject, WKURLSchemeHandler {
    var ebookTextProcessorCacheHits: ((URL, String) async throws -> Bool)? = nil
    var ebookTextProcessor: ((URL, String, String, Bool, ((SwiftSoup.Document, URL, Bool) async -> SwiftSoup.Document)?, ((String, Bool) async -> String)?) async throws -> String)? = nil
    var readerFileManager: ReaderFileManager? = nil
    var processReadabilityContent: ((SwiftSoup.Document, URL, Bool) async -> SwiftSoup.Document)?
    var processHTML: ((String, Bool) async -> String)?

    private var schemeHandlers: [Int: WKURLSchemeTask] = [:]
    
    enum CustomSchemeHandlerError: Error {
        case fileNotFound
    }
    
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
    }
    
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        schemeHandlers[urlSchemeTask.hash] = urlSchemeTask
        
        guard let url = urlSchemeTask.request.url else { return }
        
        if url.path == "/process-text" {
            if urlSchemeTask.request.httpMethod == "POST", let payload = urlSchemeTask.request.httpBody, let text = String(data: payload, encoding: .utf8), let replacedTextLocation = urlSchemeTask.request.value(forHTTPHeaderField: "X-REPLACED-TEXT-LOCATION"), let contentURLRaw = urlSchemeTask.request.value(forHTTPHeaderField: "X-CONTENT-LOCATION"), let contentURL = URL(string: contentURLRaw) {
                if let ebookTextProcessor, let processReadabilityContent, let processHTML {
                   let isCacheWarmer = urlSchemeTask.request.value(forHTTPHeaderField: "X-IS-CACHE-WARMER") == "true"
                    let processingActor = EBookProcessingActor(
                        ebookTextProcessorCacheHits: ebookTextProcessorCacheHits,
                        ebookTextProcessor: ebookTextProcessor,
                        processReadabilityContent: processReadabilityContent,
                        processHTML: processHTML
                    )
                    
                    Task.detached(priority: .utility) {
//                        print("# ebook proc text endpoint", replacedTextLocation)
//                        if !isCacheWarmer {
//                            print("# ebook proc", replacedTextLocation, text)
//                        }
                        let respText = await processingActor.process(
                            contentURL: contentURL,
                            location: replacedTextLocation,
                            text: text,
                            isCacheWarmer: isCacheWarmer
                        )
                        if let respData = respText.data(using: .utf8) {
                            let resp = HTTPURLResponse(
                                url: url,
                                mimeType: nil,
                                expectedContentLength: respData.count,
                                textEncodingName: "utf-8"
                            )
                            await { @MainActor in
                                if self.schemeHandlers[urlSchemeTask.hash] != nil {
//                                    if !isCacheWarmer {
//                                        print("# ebook proc text endpoint", replacedTextLocation, "receive...", respText)
//                                    }
                                    urlSchemeTask.didReceive(resp)
                                    urlSchemeTask.didReceive(respData)
                                    urlSchemeTask.didFinish()
                                    self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                                }
                            }()
                        }
                    }
                } else if let respData = text.data(using: .utf8) {
                    let resp = HTTPURLResponse(
                        url: url,
                        mimeType: nil,
                        expectedContentLength: respData.count,
                        textEncodingName: "utf-8"
                    )
                    if self.schemeHandlers[urlSchemeTask.hash] != nil {
                        urlSchemeTask.didReceive(resp)
                        urlSchemeTask.didReceive(respData)
                        urlSchemeTask.didFinish()
                        self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                    }
                }
                return
            }
        } else if url.pathComponents.starts(with: ["/", "load"]) {
            // Bundle file.
            let loadPath = "/" + url.pathComponents.dropFirst(2).joined(separator: "/") + (url.hasDirectoryPath ? "/" : "")
            if let fileUrl = bundleURLFromWebURL(url),
               let mimeType = mimeType(ofFileAtUrl: fileUrl),
               let data = try? Data(contentsOf: fileUrl) {
                let response = HTTPURLResponse(
                    url: url,
                    mimeType: mimeType,
                    expectedContentLength: data.count, textEncodingName: nil)
                if self.schemeHandlers[urlSchemeTask.hash] != nil {
                    urlSchemeTask.didReceive(response)
                    urlSchemeTask.didReceive(data)
                    urlSchemeTask.didFinish()
                    self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                }
                return
            } else if urlSchemeTask.request.value(forHTTPHeaderField: "IS-SWIFTUIWEBVIEW-VIEWER-FILE-REQUEST")?.lowercased() != "true",
                      let viewerHtmlPath = Bundle.module.path(forResource: "ebook-viewer", ofType: "html", inDirectory: "foliate-js"), let mimeType = mimeType(ofFileAtUrl: url) {
                // File viewer bundle file.
                do {
                    let html = try String(contentsOfFile: viewerHtmlPath)
                    if let data = html.data(using: .utf8) {
                        let response = HTTPURLResponse(
                            url: url,
                            mimeType: mimeType,
                            expectedContentLength: data.count, textEncodingName: nil)
                        if self.schemeHandlers[urlSchemeTask.hash] != nil {
                            urlSchemeTask.didReceive(response)
                            urlSchemeTask.didReceive(data)
                            urlSchemeTask.didFinish()
                            self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                        }
                        return
                    }
                } catch { }
            } else if
                let path = loadPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                let fileURL = URL(string: "ebook://ebook/load\(path)"),
                let readerFileManager = readerFileManager,
                // Security check.
                urlSchemeTask.request.mainDocumentURL == fileURL {
                Task { @MainActor in
                    do {
                        // User file.
                        if try await readerFileManager.directoryExists(directoryURL: fileURL) {
                            let localFileURL = try await readerFileManager.localDirectoryURL(forReaderFileURL: fileURL)
                            await Task.detached {
                                guard let epubData = await ZIPToEbookActor.shared.zipToEPub(directoryURL: localFileURL) else {
                                    print("Failed to ZIP epub \(fileURL) for loading.")
                                    // TODO: Canceling/failed tasks
                                    return
                                }
                                let response = HTTPURLResponse(
                                    url: fileURL,
                                    mimeType: "application/epub+zip",
                                    expectedContentLength: epubData.count, textEncodingName: nil)
                                await Task { @MainActor in
                                    if self.schemeHandlers[urlSchemeTask.hash] != nil {
                                        urlSchemeTask.didReceive(response)
                                        urlSchemeTask.didReceive(epubData)
                                        urlSchemeTask.didFinish()
                                        self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                                    }
                                }.value
                            }.value
                        } else if try await readerFileManager.fileExists(fileURL: fileURL) {
                            let localFileURL = try await readerFileManager.localFileURL(forReaderFileURL: fileURL)
                            if let mimeType = mimeType(ofFileAtUrl: localFileURL),
                               let data = try? Data(contentsOf: localFileURL) {
                                let response = HTTPURLResponse(
                                    url: url,
                                    mimeType: mimeType,
                                    expectedContentLength: data.count, textEncodingName: nil)
                                if self.schemeHandlers[urlSchemeTask.hash] != nil {
                                    urlSchemeTask.didReceive(response)
                                    urlSchemeTask.didReceive(data)
                                    urlSchemeTask.didFinish()
                                    self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                                }
                            }
                        } else {
                            // TODO: Raise and display 404 error
                            print("File not found for \(fileURL)")
                        }
                    } catch {
                        print("Error: \(error)")
                        // TODO: Error here
                    }
                }
                return
            }
        }
        
        urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
    }
    
    private func bundleURLFromWebURL(_ url: URL) -> URL? {
        guard url.path.hasPrefix("/load/viewer-assets/") else { return nil }
        let assetName = url.deletingPathExtension().lastPathComponent
        let assetExtension = url.pathExtension
        let assetDirectory = url.deletingLastPathComponent().path.deletingPrefix("/load/viewer-assets/")
        return Bundle.module.url(forResource: assetName, withExtension: assetExtension, subdirectory: assetDirectory)
    }
    
    private func mimeType(ofFileAtUrl url: URL) -> String? {
        return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}

fileprivate extension String {
    func deletingPrefix(_ prefix: String) -> String {
        guard self.hasPrefix(prefix) else { return self }
        return String(self.dropFirst(prefix.count))
    }
}
