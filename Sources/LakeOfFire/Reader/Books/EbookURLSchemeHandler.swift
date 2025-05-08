import SwiftUI
import WebKit
import UniformTypeIdentifiers
import SwiftSoup

fileprivate actor EBookProcessingActor {
    let ebookTextProcessor: ((URL, String, String, ((SwiftSoup.Document) async -> String)?) async throws -> String)?
    let processReadabilityContent: ((SwiftSoup.Document) async -> String)?
    
    init(
        ebookTextProcessor: ((URL, String, String, ((SwiftSoup.Document) async -> String)?) async throws -> String)?,
        processReadabilityContent: ((SwiftSoup.Document) async -> String)?
    ) {
        self.ebookTextProcessor = ebookTextProcessor
        self.processReadabilityContent = processReadabilityContent
    }
    
    func process(
        contentURL: URL,
        location: String,
        text: String
    ) async -> String {
        var respText = text
        if let processor = ebookTextProcessor {
            do {
                respText = try await processor(
                    contentURL,
                    location,
                    text,
                    processReadabilityContent
                )
            } catch {
                print("Error processing Ebook text: \(error)")
            }
        }
        return respText
    }
}

public extension URL {
    var isEBookURL: Bool {
        return (isFileURL || scheme == "https" || scheme == "http" || scheme == "ebook" || scheme == "ebook-url") && pathExtension.lowercased() == "epub"
    }
}

final class EbookURLSchemeHandler: NSObject, WKURLSchemeHandler {
    var ebookTextProcessor: ((URL, String, String, ((SwiftSoup.Document) async -> String)?) async throws -> String)? = nil
    var readerFileManager: ReaderFileManager? = nil
    var processReadabilityContent: ((SwiftSoup.Document) async -> String)?
    
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
            debugPrint("# / process text")
            if urlSchemeTask.request.httpMethod == "POST", let payload = urlSchemeTask.request.httpBody, let text = String(data: payload, encoding: .utf8), let replacedTextLocation = urlSchemeTask.request.value(forHTTPHeaderField: "X-REPLACED-TEXT-LOCATION"), let contentURLRaw = urlSchemeTask.request.value(forHTTPHeaderField: "X-CONTENT-LOCATION"), let contentURL = URL(string: contentURLRaw) {
                if let ebookTextProcessor, let processReadabilityContent {
                    let processingActor = EBookProcessingActor(
                        ebookTextProcessor: ebookTextProcessor,
                        processReadabilityContent: processReadabilityContent
                    )
                    Task.detached(priority: .utility) {
                        let respText = await processingActor.process(
                            contentURL: contentURL,
                            location: replacedTextLocation,
                            text: text
                        )
                        if let respData = respText.data(using: .utf8) {
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
                                guard let epubData = EPub.zipToEPub(directoryURL: localFileURL) else {
                                    print("Failed to ZIP epub \(fileURL) for loading.")
                                    // TODO: Canceling/failed tasks
                                    return
                                }
                                await Task { @MainActor in
                                    let response = HTTPURLResponse(
                                        url: fileURL,
                                        mimeType: "application/epub+zip",
                                        expectedContentLength: epubData.count, textEncodingName: nil)
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
