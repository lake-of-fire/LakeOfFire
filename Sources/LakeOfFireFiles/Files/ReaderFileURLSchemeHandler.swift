import Foundation
@preconcurrency import WebKit
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
        guard let activeTask = remove(task) else { return false }
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
    private func failActiveTask(_ urlSchemeTask: WKURLSchemeTask, error: Error) -> Bool {
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
                    if let readerFileURL = url.deletingQuery {
                        let cachedSource = try await ReaderPackageEntrySourceCache.shared.cachedSource(
                            forPackageURL: readerFileURL,
                            readerFileManager: readerFileManager
                        )
                        try Task.checkCancellation()
                        let data = try cachedSource.source.readEntry(subpath: subpathValue)
                        let metadata = try cachedSource.source.mimeType(
                            subpath: subpathValue,
                            data: data
                        )
                        try Task.checkCancellation()
                        let response = HTTPURLResponse(
                            url: url,
                            mimeType: metadata.mimeType,
                            expectedContentLength: data.count,
                            textEncodingName: metadata.textEncodingName
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
                } else if
                    let contentFilePrimaryKey = try? await ReaderFileManager.contentFilePrimaryKey(for: url),
                    var data = try? await readerFileManager.read(fileURL: url)
                {
                    try Task.checkCancellation()
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
