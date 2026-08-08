import Foundation
import LakeOfFireContent
import LakeOfFireCore
import WebKit

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

/// Owns the single terminal callback right for class-backed URL-scheme tasks.
/// Cancellation and completion race through one exact object-identity claim.
public final class URLSchemeTaskCompletionOwnership: @unchecked Sendable {
    private struct ActiveTask {
        let task: AnyObject
        var workCancellations: [@Sendable () -> Void] = []
    }

    private let lock = NSLock()
    private var activeTasks: [ObjectIdentifier: ActiveTask] = [:]

    public init() {}

    public func begin(_ task: AnyObject) {
        lock.lock()
        defer { lock.unlock() }
        activeTasks[ObjectIdentifier(task)] = ActiveTask(task: task)
    }

    /// Attaches cancellation for asynchronous work owned by an active scheme task.
    /// If WebKit already stopped or completed the task, the work is cancelled
    /// immediately rather than being allowed to run without a terminal owner.
    @discardableResult
    public func attachCancellation(
        _ task: AnyObject,
        cancellation: @escaping @Sendable () -> Void
    ) -> Bool {
        lock.lock()
        let identifier = ObjectIdentifier(task)
        guard var activeTask = activeTasks[identifier], activeTask.task === task else {
            lock.unlock()
            cancellation()
            return false
        }
        activeTask.workCancellations.append(cancellation)
        activeTasks[identifier] = activeTask
        lock.unlock()
        return true
    }

    @discardableResult
    public func cancel(_ task: AnyObject) -> Bool {
        guard let activeTask = remove(task) else {
            return false
        }
        for cancellation in activeTask.workCancellations {
            cancellation()
        }
        return true
    }

    @discardableResult
    public func claimCompletion(_ task: AnyObject) -> Bool {
        remove(task) != nil
    }

    private func remove(_ task: AnyObject) -> ActiveTask? {
        lock.lock()
        defer { lock.unlock() }
        let identifier = ObjectIdentifier(task)
        guard let activeTask = activeTasks[identifier], activeTask.task === task else {
            return nil
        }
        activeTasks.removeValue(forKey: identifier)
        return activeTask
    }
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
                        let source = try ReaderPackageEntrySource(localURL: localArchiveURL)
                        let packageData = try source.readEntry(subpath: subpathValue)
                        try Task.checkCancellation()
                        let responseMetadata = try source.mimeType(
                            subpath: subpathValue,
                            data: packageData
                        )
                        let response = HTTPURLResponse(
                            url: url,
                            mimeType: responseMetadata.mimeType,
                            expectedContentLength: packageData.count,
                            textEncodingName: responseMetadata.textEncodingName
                        )
                        await { @MainActor in
                            self.finishActiveTask(
                                urlSchemeTask,
                                response: response,
                                data: packageData
                            )
                        }()
                        return
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
