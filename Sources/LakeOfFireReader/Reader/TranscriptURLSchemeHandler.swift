import Foundation
import WebKit
import LakeOfFireCore
import LakeOfFireContent

public final class TranscriptURLSchemeHandler: NSObject, WKURLSchemeHandler {
    enum TranscriptSchemeError: Error {
        case notFound
        case invalidRoute
    }

    private var pendingTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let taskQueue = DispatchQueue(label: "TranscriptURLSchemeHandler.tasks")

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.isTranscriptURL else {
            urlSchemeTask.didFailWithError(TranscriptSchemeError.notFound)
            return
        }

        let identifier = ObjectIdentifier(urlSchemeTask)
        let task = Task {
            do {
                let (mimeType, data) = try await self.resolveResponse(for: url)
                let response = URLResponse(
                    url: url,
                    mimeType: mimeType,
                    expectedContentLength: data.count,
                    textEncodingName: "utf-8"
                )

                self.taskQueue.sync {
                    guard self.pendingTasks[identifier] != nil else { return }
                    urlSchemeTask.didReceive(response)
                    urlSchemeTask.didReceive(data)
                    urlSchemeTask.didFinish()
                    self.pendingTasks.removeValue(forKey: identifier)
                }
            } catch {
                self.taskQueue.sync {
                    guard self.pendingTasks[identifier] != nil else { return }
                    urlSchemeTask.didFailWithError(error)
                    self.pendingTasks.removeValue(forKey: identifier)
                }
            }
        }

        taskQueue.sync {
            pendingTasks[identifier] = task
        }
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask)
        taskQueue.sync {
            pendingTasks[identifier]?.cancel()
            pendingTasks.removeValue(forKey: identifier)
        }
    }

    private func resolveResponse(for url: URL) async throws -> (String, Data) {
        if url.isTranscriptPageURL,
           let data = await TranscriptPageRegistry.shared.htmlData(for: url) {
            return ("text/html", data)
        }

        if url.isTranscriptVTTURL,
           let data = await TranscriptPageRegistry.shared.webVTTData(for: url) {
            return ("text/vtt", data)
        }

        throw url.isTranscriptURL ? TranscriptSchemeError.invalidRoute : TranscriptSchemeError.notFound
    }
}
