import SwiftUI
import WebKit
import UniformTypeIdentifiers

public extension URL {
    var isEBookURL: Bool {
        return (isFileURL || scheme == "https" || scheme == "http" || scheme == "ebook" || scheme == "ebook-url") && pathExtension.lowercased() == "epub"
    }
}

final class EbookURLSchemeHandler: NSObject, WKURLSchemeHandler {
    var ebookTextProcessor: ((String) async throws -> String)? = nil
    var readerFileManager: ReaderFileManager? = nil
    
    enum CustomSchemeHandlerError: Error {
        case fileNotFound
    }
    
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) { }
    
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
//        print("!! ebook handler for url \(url)")
        //            guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == scheme else { continue }
        
        if url.path == "/process-text" {
//            print("!! process-text")
            if urlSchemeTask.request.httpMethod == "POST", let payload = urlSchemeTask.request.httpBody, let text = String(data: payload, encoding: .utf8) {
                let ebookTextProcessor = ebookTextProcessor
                Task.detached {
                    var respText = text
                    if let ebookTextProcessor = ebookTextProcessor {
                        do {
                            respText = try await ebookTextProcessor(text)
                        } catch {
                            print("Error processing Ebook text: \(error)")
                        }
                    }
                    if let respData = respText.data(using: .utf8) {
                        Task { @MainActor in
                            let resp = HTTPURLResponse(
                                url: url, mimeType: nil, expectedContentLength: respData.count, textEncodingName: "utf-8")
                            urlSchemeTask.didReceive(resp)
                            urlSchemeTask.didReceive(respData)
                            urlSchemeTask.didFinish()
                        }
                    }
                }
                return
            }
        } else if url.pathComponents.starts(with: ["/", "load"]) {
//            print("!! /load ...")
            // Bundle file.
//            let loadPath = "/" + url.pathComponents.dropFirst(2).joined(separator: "/") + (url.hasDirectoryPath ? "/" : "")
            let loadPath = "/" + url.pathComponents.dropFirst(2).joined(separator: "/") + (url.hasDirectoryPath ? "/" : "")
            if let fileUrl = bundleURLFromWebURL(url),
               let mimeType = mimeType(ofFileAtUrl: fileUrl),
               let data = try? Data(contentsOf: fileUrl) {
//                print("!! bundle file")
                let response = HTTPURLResponse(
                    url: url,
                    mimeType: mimeType,
                    expectedContentLength: data.count, textEncodingName: nil)
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
                return
            } else if urlSchemeTask.request.value(forHTTPHeaderField: "IS-SWIFTUIWEBVIEW-VIEWER-FILE-REQUEST")?.lowercased() != "true",
                      let viewerHtmlPath = Bundle.module.path(forResource: "ebook-viewer", ofType: "html", inDirectory: "foliate-js"), let mimeType = mimeType(ofFileAtUrl: url) {
//                print("!! file viewer bundle file")
                // File viewer bundle file.
                do {
                    let html = try String(contentsOfFile: viewerHtmlPath)
                    if let data = html.data(using: .utf8) {
                        let response = HTTPURLResponse(
                            url: url,
                            mimeType: mimeType,
                            expectedContentLength: data.count, textEncodingName: nil)
//                        print("!! foliate viewer data ret.. \(html)")
                        urlSchemeTask.didReceive(response)
                        urlSchemeTask.didReceive(data)
                        urlSchemeTask.didFinish()
                        return
                    }
                } catch { }
            }/* else if url.absoluteString.hasPrefix("\(scheme)-url://"),
              let remoteURL = URL(string: "https://\(url.absoluteString.dropFirst("\(scheme)-url://".count))"),
              urlSchemeTask.request.mainDocumentURL == url,
              let mimeType = mimeType(ofFileAtUrl: remoteURL) {
              do {
              let data = try Data(contentsOf: remoteURL)
              let response = HTTPURLResponse(
              url: url,
              mimeType: mimeType,
              expectedContentLength: data.count, textEncodingName: nil)
              urlSchemeTask.didReceive(response)
              urlSchemeTask.didReceive(data)
              urlSchemeTask.didFinish()
              } catch { }
              }*/ else if
                let path = loadPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                let fileURL = URL(string: "ebook://ebook/load\(path)"),
//                let currentURL = URL(string: "ebook://ebook/load\(path)"),
                let readerFileManager = readerFileManager,
                // Security check.
                urlSchemeTask.request.mainDocumentURL == fileURL {
                  Task { @MainActor in
                      do {
                          // User file.
                          if try await readerFileManager.directoryExists(directoryURL: fileURL) {
                              //                            if fileURL.hasDirectoryPath || fileURL.isFilePackage() {
                              let localFileURL = try await readerFileManager.localDirectoryURL(forReaderFileURL: fileURL)
                              await Task.detached {
                                  //                                        let path = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                                  guard let epubData = EPub.zipToEPub(directoryURL: localFileURL)/*, let zippedFileURL = URL(string: "ebook://ebook/\(path)")*/ else {
                                      print("Failed to ZIP epub \(fileURL) for loading.")
                                      // TODO: Canceling/failed tasks
                                      return
                                  }
                                  await Task { @MainActor in
                                      let response = HTTPURLResponse(
                                        url: fileURL,
                                        mimeType: "application/epub+zip",
                                        expectedContentLength: epubData.count, textEncodingName: nil)
                                      urlSchemeTask.didReceive(response)
                                      urlSchemeTask.didReceive(epubData)
                                      urlSchemeTask.didFinish()
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
                                  urlSchemeTask.didReceive(response)
                                  urlSchemeTask.didReceive(data)
                                  urlSchemeTask.didFinish()
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
              }/* else if webView.url?.scheme == scheme, let webURL = webView.url, let epubURL = URL(string: "file://" + webURL.path), let archive = Archive(url: epubURL, accessMode: .read), let entry = archive[String(url.path.dropFirst())] {
                var data = Data()
                do {
                let _ = try archive.extract(entry) { chunk in
                data.append(chunk)
                }
                let mimeType = mimeType(ofFileAtUrl: url)
                let response = HTTPURLResponse(
                url: url,
                mimeType: mimeType,
                expectedContentLength: data.count, textEncodingName: nil)
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
                } catch { print("Failed to extract: \(error.localizedDescription)") }
                }*/
        }
//                print("!! file not found \(url)")
        urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
    }
    
    private func bundleURLFromWebURL(_ url: URL) -> URL? {
        guard url.path.hasPrefix("/load/viewer-assets/") else { return nil }
        let assetName = url.deletingPathExtension().lastPathComponent
        let assetExtension = url.pathExtension
        let assetDirectory = url.deletingLastPathComponent().path.deletingPrefix("/load/viewer-assets/")
        return Bundle.module.url(forResource: assetName, withExtension: assetExtension, subdirectory: assetDirectory)
//        return Bundle.module.url(
//            forResource: assetName,
//            withExtension: assetExtension,
//            subdirectory: "Resources")
    }

    private func mimeType(ofFileAtUrl url: URL) -> String? {
        return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}

//public extension URL {
//    var fileURLFromCustomSchemeLoaderURL: URL? {
//        guard scheme == "ebook", pathComponents.starts(with: ["/", "load"]) else { return nil }
//        let loadPath = "/" + pathComponents.dropFirst(2).joined(separator: "/")
//        guard let path = loadPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
//        return URL(string: "file://\(path)")
//    }
//}

fileprivate extension String {
    func deletingPrefix(_ prefix: String) -> String {
        guard self.hasPrefix(prefix) else { return self }
        return String(self.dropFirst(prefix.count))
    }
}
