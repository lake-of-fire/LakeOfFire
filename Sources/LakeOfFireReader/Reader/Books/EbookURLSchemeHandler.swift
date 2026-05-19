import SwiftUI
@preconcurrency import WebKit
import UniformTypeIdentifiers
import SwiftSoup
import SwiftUtilities
import LakeKit
import LakeOfFireCore
import LakeOfFireContent
import LakeOfFireFiles

fileprivate func ebookRequestBodyData(_ request: URLRequest) -> Data? {
    if let body = request.httpBody, !body.isEmpty {
        return body
    }
    guard let stream = request.httpBodyStream else {
        return nil
    }
    stream.open()
    defer { stream.close() }
    let chunkSize = 64 * 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
    defer { buffer.deallocate() }
    var result = Data()
    while stream.hasBytesAvailable {
        let readCount = stream.read(buffer, maxLength: chunkSize)
        if readCount < 0 {
            return nil
        }
        if readCount == 0 {
            break
        }
        result.append(buffer, count: readCount)
    }
    return result.isEmpty ? nil : result
}

fileprivate func logEbookAsset(_ line: String) {
    Logger.shared.logger.info("\(line)")
}

fileprivate func ebookProcessTextSample(_ value: String, limit: Int = 80) -> String {
    guard value.count > limit else { return value }
    return String(value.prefix(limit))
}

@inline(__always)
fileprivate func ebookLoadElapsedMs(since startedAt: Date) -> Int {
    Int(Date().timeIntervalSince(startedAt) * 1000)
}

fileprivate let ebookReplaceTextDetailedLoggingEnabled =
    ProcessInfo.processInfo.environment["MANABI_REPLACETEXT_DETAILED_LOGS"] == "1"
fileprivate let ebookReplaceTextSlowSummaryThresholdMs = 5_000

@inline(__always)
fileprivate func shouldEmitEbookReplaceTextLifecycleLog(elapsedMs: Int? = nil, didCoalesce: Bool = false) -> Bool {
    if ebookReplaceTextDetailedLoggingEnabled || didCoalesce {
        return true
    }
    guard let elapsedMs else { return false }
    return elapsedMs >= ebookReplaceTextSlowSummaryThresholdMs
}

struct EBookProcessTextRequestKey: Hashable {
    let contentURLString: String
    let location: String
    let isCacheWarmer: Bool
    let textFingerprint: String

    init(contentURL: URL, location: String, isCacheWarmer: Bool, text: String) {
        contentURLString = contentURL.absoluteString
        self.location = location
        self.isCacheWarmer = isCacheWarmer
        textFingerprint = "\(text.utf8.count)-\(stableHash(text))"
    }
}

enum EBookProcessTextRequestDeduperError: Error, Sendable, Equatable, LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

actor EBookProcessTextRequestDeduper {
    private enum ProcessTextOutcome: Sendable {
        case success(String)
        case cancelled
        case failure(String)
    }

    private var inFlightWaitersByKey: [EBookProcessTextRequestKey: [CheckedContinuation<ProcessTextOutcome, Never>]] = [:]

    private func resolve(_ outcome: ProcessTextOutcome) throws -> String {
        switch outcome {
        case .success(let responseText):
            return responseText
        case .cancelled:
            throw CancellationError()
        case .failure(let message):
            throw EBookProcessTextRequestDeduperError.failed(message)
        }
    }

#if DEBUG
    func inFlightWaiterCountForTesting(key: EBookProcessTextRequestKey) -> Int {
        inFlightWaitersByKey[key]?.count ?? 0
    }
#endif

    func process(
        key: EBookProcessTextRequestKey,
        operation: @Sendable () async throws -> String
    ) async throws -> (responseText: String, didCoalesce: Bool) {
        let startedAt = Date()
        if inFlightWaitersByKey[key] != nil {
            let waiterCountBeforeAppend = inFlightWaitersByKey[key]?.count ?? 0
            debugPrint(
                "# EPUBLOAD",
                "stage=processText.deduper.join",
                "location=\(key.location)",
                "isCacheWarmer=\(key.isCacheWarmer)",
                "waiterCountBeforeAppend=\(waiterCountBeforeAppend)",
                "textFingerprint=\(key.textFingerprint)",
                "contentURL=\(ebookProcessTextSample(key.contentURLString))"
            )
            if ebookReplaceTextDetailedLoggingEnabled {
            }
            let response = await withCheckedContinuation { continuation in
                inFlightWaitersByKey[key, default: []].append(continuation)
            }
            let joinElapsedMs = ebookLoadElapsedMs(since: startedAt)
            debugPrint(
                "# EPUBLOAD",
                "stage=processText.deduper.join.resumed",
                "location=\(key.location)",
                "isCacheWarmer=\(key.isCacheWarmer)",
                "elapsedMs=\(joinElapsedMs)",
                "textFingerprint=\(key.textFingerprint)",
                "contentURL=\(ebookProcessTextSample(key.contentURLString))"
            )
            if shouldEmitEbookReplaceTextLifecycleLog(elapsedMs: joinElapsedMs, didCoalesce: true) {
            }
            return (try resolve(response), true)
        }

        inFlightWaitersByKey[key] = []
        debugPrint(
            "# EPUBLOAD",
            "stage=processText.deduper.leader",
            "location=\(key.location)",
            "isCacheWarmer=\(key.isCacheWarmer)",
            "textFingerprint=\(key.textFingerprint)",
            "contentURL=\(ebookProcessTextSample(key.contentURLString))"
        )
        if ebookReplaceTextDetailedLoggingEnabled {
        }
        let response: ProcessTextOutcome
        do {
            response = .success(try await operation())
        } catch is CancellationError {
            response = .cancelled
        } catch {
            response = .failure(error.localizedDescription)
        }
        let waiters = inFlightWaitersByKey.removeValue(forKey: key) ?? []
        let resolveElapsedMs = ebookLoadElapsedMs(since: startedAt)
        debugPrint(
            "# EPUBLOAD",
            "stage=processText.deduper.resolve",
            "location=\(key.location)",
            "isCacheWarmer=\(key.isCacheWarmer)",
            "waiterCount=\(waiters.count)",
            "elapsedMs=\(resolveElapsedMs)",
            "textFingerprint=\(key.textFingerprint)",
            "contentURL=\(ebookProcessTextSample(key.contentURLString))"
        )
        if shouldEmitEbookReplaceTextLifecycleLog(elapsedMs: resolveElapsedMs, didCoalesce: !waiters.isEmpty) {
        }
        for waiter in waiters {
            waiter.resume(returning: response)
        }
        return (try resolve(response), false)
    }
}

actor EBookProcessingActor {
    let ebookTextProcessorCacheHits: EbookTextProcessorCacheHitsHandler?
    let ebookTextProcessor: EbookTextProcessor?
    let processReadabilityContent: EbookReadabilityContentProcessor?
    let processHTMLBytes: EbookHTMLBytesProcessor?
    let processHTML: EbookHTMLProcessor?

    init(
        ebookTextProcessorCacheHits: EbookTextProcessorCacheHitsHandler?,
        ebookTextProcessor: EbookTextProcessor?,
        processReadabilityContent: EbookReadabilityContentProcessor?,
        processHTMLBytes: EbookHTMLBytesProcessor?,
        processHTML: EbookHTMLProcessor?
    ) {
        self.ebookTextProcessorCacheHits = ebookTextProcessorCacheHits
        self.ebookTextProcessor = ebookTextProcessor
        self.processReadabilityContent = processReadabilityContent
        self.processHTMLBytes = processHTMLBytes
        self.processHTML = processHTML
    }

    func process(
        contentURL: URL,
        location: String,
        text: String,
        isCacheWarmer: Bool
    ) async throws -> String {
        let startedAt = Date()
        debugPrint(
            "# EPUBLOAD",
            "stage=processText.actor.start",
            "location=\(location)",
            "isCacheWarmer=\(isCacheWarmer)",
            "textBytes=\(text.utf8.count)",
            "contentURL=\(ebookProcessTextSample(contentURL.absoluteString))"
        )
        if ebookReplaceTextDetailedLoggingEnabled {
        }
        guard let ebookTextProcessor else {
            debugPrint(
                "# EPUBLOAD",
                "stage=processText.actor.noProcessor",
                "location=\(location)",
                "isCacheWarmer=\(isCacheWarmer)",
                "elapsedMs=\(ebookLoadElapsedMs(since: startedAt))",
                "contentURL=\(ebookProcessTextSample(contentURL.absoluteString))"
            )
            return text
        }

        let result = try await ebookTextProcessor(
            contentURL,
            location,
            text,
            isCacheWarmer,
            processReadabilityContent,
            processHTMLBytes,
            processHTML
        )
        let elapsedMs = ebookLoadElapsedMs(since: startedAt)
        debugPrint(
            "# EPUBLOAD",
            "stage=processText.actor.end",
            "location=\(location)",
            "isCacheWarmer=\(isCacheWarmer)",
            "textBytes=\(text.utf8.count)",
            "responseBytes=\(result.utf8.count)",
            "elapsedMs=\(elapsedMs)",
            "contentURL=\(ebookProcessTextSample(contentURL.absoluteString))"
        )
        return result
    }
}

fileprivate actor EBookLoadingActor {
    enum EbookLoadingError: Error {
        case fileNotFound
    }
    /// Returns an `HTTPURLResponse` and data for a bundled viewer HTML file at the given path.
    func loadViewerFile(
        at viewerHtmlPath: String,
        originalURL: URL,
        sharedFontCSSBase64: String?,
        sharedFontCSSBase64Provider: SharedFontCSSBase64Provider?
    ) async throws -> (HTTPURLResponse, Data) {
        var html = try String(contentsOfFile: viewerHtmlPath)
        let shouldEnablePageTurnInteractionDiagnostic =
            ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1"

        var base64 = sharedFontCSSBase64
        if (base64 == nil || base64?.isEmpty == true), let sharedFontCSSBase64Provider {
            base64 = await sharedFontCSSBase64Provider()
        }

        if shouldEnablePageTurnInteractionDiagnostic {
            let diagnosticPayload = """
            <script>
            (function() {
                try {
                    globalThis.manabiPageTurnInteractionDiagnostic = true;
                } catch (err) {
                    console.error('Failed to enable page-turn interaction diagnostic flag', err);
                }
            })();
            </script>
            """
            if let range = html.range(of: "</body>", options: .caseInsensitive) {
                html.replaceSubrange(range, with: diagnosticPayload + "</body>")
            } else {
                html.append(diagnosticPayload)
            }
        }

        if let base64, !base64.isEmpty {
            let payload = """
            <script id="mnb-font-css-base64" type="application/json">\(base64)</script>
            <script>
            (function() {
                try {
                    globalThis.manabiFontCSSBase64 = "\(base64)";
                } catch (err) {
                    console.error('Failed to expose shared font css payload', err);
                }
            })();
            </script>
            """
            if let range = html.range(of: "</body>", options: .caseInsensitive) {
                html.replaceSubrange(range, with: payload + "</body>")
            } else {
                html.append(payload)
            }
        }

        guard let data = html.data(using: .utf8) else {
            throw EbookLoadingError.fileNotFound
        }
        let mimeType = "text/html"
        let response = HTTPURLResponse(
            url: originalURL,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: "utf-8"
        )
        return (response, data)
    }
}

fileprivate struct EBookEntriesResponse: Codable, Sendable {
    let entries: [ReaderPackageEntryMetadata]
}

@globalActor
public actor EbookURLSchemeActor {
    public static let shared = EbookURLSchemeActor()

    public init() { }
}

public typealias EbookDocumentTransform = @Sendable (SwiftSoup.Document) async -> SwiftSoup.Document
public typealias EbookReadabilityContentProcessor = @Sendable (String, URL, URL?, Bool, EbookDocumentTransform) async throws -> SwiftSoup.Document
public typealias EbookHTMLBytesProcessor = @Sendable ([UInt8], Bool) async -> [UInt8]
public typealias EbookHTMLProcessor = @Sendable (String, Bool) async -> String
public typealias EbookTextProcessor = @Sendable (URL, String, String, Bool, EbookReadabilityContentProcessor?, EbookHTMLBytesProcessor?, EbookHTMLProcessor?) async throws -> String
public typealias EbookTextProcessorCacheHitsHandler = @Sendable (URL, String) async throws -> Bool
public typealias SharedFontCSSBase64Provider = @Sendable () async -> String?

public final class EbookURLSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated(unsafe) var ebookTextProcessorCacheHits: EbookTextProcessorCacheHitsHandler?
    nonisolated(unsafe) var ebookTextProcessor: EbookTextProcessor?
    public var readerFileManager: ReaderFileManager?
    nonisolated(unsafe) var processReadabilityContent: EbookReadabilityContentProcessor?
    nonisolated(unsafe) var processHTMLBytes: EbookHTMLBytesProcessor?
    nonisolated(unsafe) var processHTML: EbookHTMLProcessor?
    nonisolated(unsafe) public var sharedFontCSSBase64: String?
    nonisolated(unsafe) var sharedFontCSSBase64Provider: SharedFontCSSBase64Provider?
    nonisolated(unsafe) public var sharedReaderFontAsset: SharedReaderFontAsset?

    private var schemeHandlers: [Int: WKURLSchemeTask] = [:]
    private let processTextRequestDeduper = EBookProcessTextRequestDeduper()
    private var hasLoggedValidatedMainDocumentURL = false

    enum CustomSchemeHandlerError: Error {
        case fileNotFound
    }

    public override init() {
        super.init()
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
    }

    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let urlRequestStartedAt = Date()
        schemeHandlers[urlSchemeTask.hash] = urlSchemeTask

        guard let url = urlSchemeTask.request.url else { return }
        let mainDocumentURL = urlSchemeTask.request.mainDocumentURL?.absoluteString ?? "nil"
        debugPrint(
            "# EPUBLOAD",
            "stage=urlScheme.start",
            "url=\(ebookProcessTextSample(url.absoluteString))",
            "mainDocumentURL=\(ebookProcessTextSample(mainDocumentURL))",
            "method=\(urlSchemeTask.request.httpMethod ?? "nil")"
        )
        if ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" {
            logEbookAsset("# EBOOKASSET start url=\(url.absoluteString) mainDocument=\(mainDocumentURL)")
        }
        let sharedReaderFontAsset = self.sharedReaderFontAsset
        if let fontResponse = sharedReaderFontResponse(
            for: url,
            asset: sharedReaderFontAsset
        ) {
            urlSchemeTask.didReceive(fontResponse.response)
            urlSchemeTask.didReceive(fontResponse.data)
            urlSchemeTask.didFinish()
            schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
            debugPrint(
                "# EPUBLOAD",
                "stage=urlScheme.finish",
                "route=font",
                "bytes=\(fontResponse.data.count)",
                "elapsedMs=\(ebookLoadElapsedMs(since: urlRequestStartedAt))",
                "url=\(ebookProcessTextSample(url.absoluteString))"
            )
            return
        }
        guard let readerFileManager else {
            print("Error: Missing ReaderFileManager in EbookURLSchemeHandler")
            urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
            debugPrint(
                "# EPUBLOAD",
                "stage=urlScheme.error",
                "route=missingReaderFileManager",
                "elapsedMs=\(ebookLoadElapsedMs(since: urlRequestStartedAt))",
                "url=\(ebookProcessTextSample(url.absoluteString))"
            )
            return
        }
        let ebookTextProcessorCacheHits = self.ebookTextProcessorCacheHits
        let ebookTextProcessor = self.ebookTextProcessor
        let processReadabilityContent = self.processReadabilityContent
        let processHTMLBytes = self.processHTMLBytes
        let processHTML = self.processHTML
        let sharedFontCSSBase64 = self.sharedFontCSSBase64
        let sharedFontCSSBase64Provider = self.sharedFontCSSBase64Provider

        Task.detached(priority: .utility) { @EbookURLSchemeActor [weak self] in
            guard let self else { return }
            if url.path == "/process-text" {
                if urlSchemeTask.request.httpMethod == "POST", let payload = ebookRequestBodyData(urlSchemeTask.request), let text = String(data: payload, encoding: .utf8), let replacedTextLocation = urlSchemeTask.request.value(forHTTPHeaderField: "X-REPLACED-TEXT-LOCATION"), let contentURLRaw = urlSchemeTask.request.value(forHTTPHeaderField: "X-CONTENT-LOCATION"), let contentURL = URL(string: contentURLRaw) {
                    if let ebookTextProcessor {
                        let requestStartedAt = Date()
                        let isCacheWarmer = urlSchemeTask.request.value(forHTTPHeaderField: "X-IS-CACHE-WARMER") == "true"
                        let processRequestKey = EBookProcessTextRequestKey(
                            contentURL: contentURL,
                            location: replacedTextLocation,
                            isCacheWarmer: isCacheWarmer,
                            text: text
                        )
                        debugPrint(
                            "# EPUBLOAD",
                            "stage=processText.request.start",
                            "location=\(replacedTextLocation)",
                            "isCacheWarmer=\(isCacheWarmer)",
                            "textBytes=\(text.utf8.count)",
                            "textFingerprint=\(processRequestKey.textFingerprint)",
                            "contentURL=\(ebookProcessTextSample(contentURL.absoluteString))",
                            "urlElapsedMs=\(ebookLoadElapsedMs(since: urlRequestStartedAt))"
                        )
                        if ebookReplaceTextDetailedLoggingEnabled {
                        }
                        let respText: String
                        let didCoalesce: Bool
                        do {
                            (respText, didCoalesce) = try await self.processTextRequestDeduper.process(
                                key: processRequestKey
                            ) {
                                let processingActor = EBookProcessingActor(
                                    ebookTextProcessorCacheHits: ebookTextProcessorCacheHits,
                                    ebookTextProcessor: ebookTextProcessor,
                                    processReadabilityContent: processReadabilityContent,
                                    processHTMLBytes: processHTMLBytes,
                                    processHTML: processHTML
                                )
                                return try await processingActor.process(
                                    contentURL: contentURL,
                                    location: replacedTextLocation,
                                    text: text,
                                    isCacheWarmer: isCacheWarmer
                                )
                            }
                        } catch {
                            await { @MainActor in
                                if self.schemeHandlers[urlSchemeTask.hash] != nil {
                                    urlSchemeTask.didFailWithError(error)
                                    self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                                }
                            }()
                            return
                        }
                        let responseDataEncodeStartedAt = Date()
                        if let respData = respText.data(using: .utf8) {
                            let responseDataEncodeElapsedMs = Int(Date().timeIntervalSince(responseDataEncodeStartedAt) * 1000)
                            let responseReadyElapsedMs = ebookLoadElapsedMs(since: requestStartedAt)
                            if shouldEmitEbookReplaceTextLifecycleLog(elapsedMs: responseReadyElapsedMs, didCoalesce: didCoalesce) {
                            }
                            let httpResponseBuildStartedAt = Date()
                            let resp = HTTPURLResponse(
                                url: url,
                                mimeType: nil,
                                expectedContentLength: respData.count,
                                textEncodingName: "utf-8"
                            )
                            let httpResponseBuildElapsedMs = Int(Date().timeIntervalSince(httpResponseBuildStartedAt) * 1000)
                            if httpResponseBuildElapsedMs > 0 {
                            }
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
                            debugPrint(
                                "# EPUBLOAD",
                                "stage=processText.request.finish",
                                "location=\(replacedTextLocation)",
                                "isCacheWarmer=\(isCacheWarmer)",
                                "didCoalesce=\(didCoalesce)",
                                "textBytes=\(text.utf8.count)",
                                "responseBytes=\(respData.count)",
                                "responseDataEncodeMs=\(responseDataEncodeElapsedMs)",
                                "requestElapsedMs=\(responseReadyElapsedMs)",
                                "urlElapsedMs=\(ebookLoadElapsedMs(since: urlRequestStartedAt))",
                                "contentURL=\(ebookProcessTextSample(contentURL.absoluteString))"
                            )
                        }
                    } else if let respData = text.data(using: .utf8) {
                        let resp = HTTPURLResponse(
                            url: url,
                            mimeType: nil,
                            expectedContentLength: respData.count,
                            textEncodingName: "utf-8"
                        )
                        await { @MainActor in
                            if self.schemeHandlers[urlSchemeTask.hash] != nil {
                                urlSchemeTask.didReceive(resp)
                                urlSchemeTask.didReceive(respData)
                                urlSchemeTask.didFinish()
                                self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                            }
                        }()
                        debugPrint(
                            "# EPUBLOAD",
                            "stage=processText.request.finish",
                            "mode=passthrough",
                            "bytes=\(respData.count)",
                            "urlElapsedMs=\(ebookLoadElapsedMs(since: urlRequestStartedAt))",
                            "url=\(ebookProcessTextSample(url.absoluteString))"
                        )
                    } else {
                        await { @MainActor in
                            if self.schemeHandlers[urlSchemeTask.hash] != nil {
                                urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                                self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                            }
                        }()
                        debugPrint(
                            "# EPUBLOAD",
                            "stage=processText.request.error",
                            "reason=utf8EncodeFailed",
                            "urlElapsedMs=\(ebookLoadElapsedMs(since: urlRequestStartedAt))",
                            "url=\(ebookProcessTextSample(url.absoluteString))"
                        )
                    }
                } else {
                    await { @MainActor in
                        if self.schemeHandlers[urlSchemeTask.hash] != nil {
                            urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                            self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                        }
                    }()
                    debugPrint(
                        "# EPUBLOAD",
                        "stage=processText.request.error",
                        "reason=invalidRequest",
                        "urlElapsedMs=\(ebookLoadElapsedMs(since: urlRequestStartedAt))",
                        "url=\(ebookProcessTextSample(url.absoluteString))"
                    )
                }
            } else if url.path == "/entries" {
                guard let mainDocumentURL = self.validatedMainDocumentURL(for: urlSchemeTask.request, route: "/entries") else {
                    await { @MainActor in
                        urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                    }()
                    debugPrint(
                        "# EPUBLOAD",
                        "stage=urlScheme.error",
                        "route=entries",
                        "reason=missingMainDocumentURL",
                        "elapsedMs=\(ebookLoadElapsedMs(since: urlRequestStartedAt))",
                        "url=\(ebookProcessTextSample(url.absoluteString))"
                    )
                    return
                }

                do {
                    let routeStartedAt = Date()
                    let cachedSource = try await ReaderPackageEntrySourceCache.shared.cachedSource(
                        forPackageURL: mainDocumentURL,
                        readerFileManager: readerFileManager
                    )
                    let responseBody = EBookEntriesResponse(entries: cachedSource.entries)
                    let data = try JSONEncoder().encode(responseBody)
                    let response = HTTPURLResponse(
                        url: url,
                        mimeType: "application/json",
                        expectedContentLength: data.count,
                        textEncodingName: "utf-8"
                    )
                    await { @MainActor in
                        if self.schemeHandlers[urlSchemeTask.hash] != nil {
                            urlSchemeTask.didReceive(response)
                            urlSchemeTask.didReceive(data)
                            urlSchemeTask.didFinish()
                            self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                        }
                    }()
                    debugPrint(
                        "# EPUBLOAD",
                        "stage=urlScheme.finish",
                        "route=entries",
                        "entryCount=\(cachedSource.entries.count)",
                        "bytes=\(data.count)",
                        "routeElapsedMs=\(ebookLoadElapsedMs(since: routeStartedAt))",
                        "elapsedMs=\(ebookLoadElapsedMs(since: urlRequestStartedAt))",
                        "mainDocumentURL=\(ebookProcessTextSample(mainDocumentURL.absoluteString))"
                    )
                } catch {
                    await { @MainActor in
                        urlSchemeTask.didFailWithError(error)
                        self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                    }()
                    debugPrint(
                        "# EPUBLOAD",
                        "stage=urlScheme.error",
                        "route=entries",
                        "elapsedMs=\(ebookLoadElapsedMs(since: urlRequestStartedAt))",
                        "error=\(String(describing: error))"
                    )
                }
            } else if url.path == "/entry" {
                guard let mainDocumentURL = self.validatedMainDocumentURL(for: urlSchemeTask.request, route: "/entry"),
                      let subpath = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?
                        .first(where: { $0.name == "subpath" })?
                        .value else {
                    await { @MainActor in
                        urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                    }()
                    debugPrint(
                        "# EPUBLOAD",
                        "stage=urlScheme.error",
                        "route=entry",
                        "reason=missingSubpath",
                        "elapsedMs=\(ebookLoadElapsedMs(since: urlRequestStartedAt))",
                        "url=\(ebookProcessTextSample(url.absoluteString))"
                    )
                    return
                }

                do {
                    let routeStartedAt = Date()
                    let cachedSource = try await ReaderPackageEntrySourceCache.shared.cachedSource(
                        forPackageURL: mainDocumentURL,
                        readerFileManager: readerFileManager
                    )
                    let data = try cachedSource.source.readEntry(subpath: subpath)
                    let metadata = try cachedSource.source.mimeType(subpath: subpath)
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
                        }
                    }()
                    debugPrint(
                        "# EPUBLOAD",
                        "stage=urlScheme.finish",
                        "route=entry",
                        "subpath=\(ebookProcessTextSample(subpath))",
                        "mime=\(metadata.mimeType)",
                        "bytes=\(data.count)",
                        "routeElapsedMs=\(ebookLoadElapsedMs(since: routeStartedAt))",
                        "elapsedMs=\(ebookLoadElapsedMs(since: urlRequestStartedAt))",
                        "mainDocumentURL=\(ebookProcessTextSample(mainDocumentURL.absoluteString))"
                    )
                } catch {
                    if let sourceError = error as? ReaderPackageEntrySourceError,
                       case .entryNotFound = sourceError {
                        let response = HTTPURLResponse(
                            url: url,
                            statusCode: 404,
                            httpVersion: nil,
                            headerFields: nil
                        )!
                        await { @MainActor in
                            if self.schemeHandlers[urlSchemeTask.hash] != nil {
                                urlSchemeTask.didReceive(response)
                                urlSchemeTask.didFinish()
                                self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                            }
                        }()
                        debugPrint(
                            "# EPUBLOAD",
                            "stage=urlScheme.finish",
                            "route=entry",
                            "status=404",
                            "subpath=\(ebookProcessTextSample(subpath))",
                            "elapsedMs=\(ebookLoadElapsedMs(since: urlRequestStartedAt))",
                            "mainDocumentURL=\(ebookProcessTextSample(mainDocumentURL.absoluteString))"
                        )
                        return
                    }
                    await { @MainActor in
                        urlSchemeTask.didFailWithError(error)
                        self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                    }()
                    debugPrint(
                        "# EPUBLOAD",
                        "stage=urlScheme.error",
                        "route=entry",
                        "subpath=\(ebookProcessTextSample(subpath))",
                        "elapsedMs=\(ebookLoadElapsedMs(since: urlRequestStartedAt))",
                        "error=\(String(describing: error))"
                    )
                }
            } else if url.pathComponents.starts(with: ["/", "load"]) {
                // Bundle file.
                if let fileUrl = Self.bundleURLFromWebURL(url),
                   let mimeType = Self.mimeType(ofFileAtUrl: fileUrl),
                   let data = try? Data(contentsOf: fileUrl) {
                    if ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" {
                        logEbookAsset("# EBOOKASSET hit url=\(url.absoluteString) fileURL=\(fileUrl.absoluteString) mime=\(mimeType) bytes=\(data.count)")
                    }
                    let response = HTTPURLResponse(
                        url: url,
                        mimeType: mimeType,
                        expectedContentLength: data.count, textEncodingName: nil)
                    await { @MainActor in
                        if self.schemeHandlers[urlSchemeTask.hash] != nil {
                            urlSchemeTask.didReceive(response)
                            urlSchemeTask.didReceive(data)
                            urlSchemeTask.didFinish()
                            self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                        }
                    }()
                    debugPrint(
                        "# EPUBLOAD",
                        "stage=urlScheme.finish",
                        "route=bundleAsset",
                        "mime=\(mimeType)",
                        "bytes=\(data.count)",
                        "elapsedMs=\(ebookLoadElapsedMs(since: urlRequestStartedAt))",
                        "url=\(ebookProcessTextSample(url.absoluteString))"
                    )
                } else if let viewerHtmlPath = Bundle.module.path(forResource: "ebook-viewer", ofType: "html", inDirectory: "foliate-js") {
                    // File viewer bundle file.
                        if ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" {
                            logEbookAsset("# EBOOKASSET fallbackViewerHTML url=\(url.absoluteString) path=\(viewerHtmlPath)")
                        }
                        do {
                            let routeStartedAt = Date()
                            let (response, data) = try await EBookLoadingActor().loadViewerFile(
                                at: viewerHtmlPath,
                                originalURL: url,
                                sharedFontCSSBase64: sharedFontCSSBase64,
                                sharedFontCSSBase64Provider: sharedFontCSSBase64Provider
                            )
                            await { @MainActor in
                                if self.schemeHandlers[urlSchemeTask.hash] != nil {
                                    urlSchemeTask.didReceive(response)
                                    urlSchemeTask.didReceive(data)
                                    urlSchemeTask.didFinish()
                                    self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                                }
                            }()
                            debugPrint(
                                "# EPUBLOAD",
                                "stage=urlScheme.finish",
                                "route=viewerHTML",
                                "bytes=\(data.count)",
                                "routeElapsedMs=\(ebookLoadElapsedMs(since: routeStartedAt))",
                                "elapsedMs=\(ebookLoadElapsedMs(since: urlRequestStartedAt))",
                                "url=\(ebookProcessTextSample(url.absoluteString))"
                            )
                        } catch {
                            print(error)
                            await { @MainActor in
                                urlSchemeTask.didFailWithError(error)
                                self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                            }()
                            debugPrint(
                                "# EPUBLOAD",
                                "stage=urlScheme.error",
                                "route=viewerHTML",
                                "elapsedMs=\(ebookLoadElapsedMs(since: urlRequestStartedAt))",
                                "error=\(String(describing: error))"
                            )
                        }
                } else {
                    if ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" {
                        logEbookAsset("# EBOOKASSET missing url=\(url.absoluteString)")
                    }
                    await { @MainActor in
                        urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                    }()
                    debugPrint(
                        "# EPUBLOAD",
                        "stage=urlScheme.error",
                        "route=load",
                        "reason=missingAsset",
                        "elapsedMs=\(ebookLoadElapsedMs(since: urlRequestStartedAt))",
                        "url=\(ebookProcessTextSample(url.absoluteString))"
                    )
                }
            }
        }
    }

    nonisolated private static func bundleURLFromWebURL(_ url: URL) -> URL? {
        guard url.path.hasPrefix("/load/viewer-assets/") else { return nil }
        let assetName = url.deletingPathExtension().lastPathComponent
        let assetExtension = url.lakePathExtension
        let assetDirectory = url.deletingLastPathComponent().path.deletingPrefix("/load/viewer-assets/")
        let resolvedURL = Bundle.module.url(forResource: assetName, withExtension: assetExtension, subdirectory: assetDirectory)
        if resolvedURL == nil, ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" {
            logEbookAsset("# EBOOKASSET resolveMiss url=\(url.absoluteString) assetName=\(assetName) ext=\(assetExtension) dir=\(assetDirectory)")
        }
        return resolvedURL
    }

    @EbookURLSchemeActor
    private func validatedMainDocumentURL(for request: URLRequest, route: String) -> URL? {
        let requestedSourceURL = request.value(forHTTPHeaderField: "X-Ebook-Source-URL")
        let requestSourceURL = URLComponents(url: request.url ?? URL(fileURLWithPath: "/"), resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "sourceURL" })?
            .value

        let candidateStrings = [
            requestedSourceURL,
            requestSourceURL,
            request.mainDocumentURL?.absoluteString,
        ].compactMap { $0 }

        guard let resolvedSourceURLString = candidateStrings.first,
              let mainDocumentURL = URL(string: resolvedSourceURLString) else {
            print(
                "# EBOOKFIX1 missing source URL for \(route)",
                "requestURL:",
                request.url?.absoluteString ?? "nil",
                "requestedSourceURL:",
                requestedSourceURL ?? "nil",
                "querySourceURL:",
                requestSourceURL ?? "nil"
            )
            return nil
        }
        guard mainDocumentURL.scheme == "ebook",
              mainDocumentURL.host == "ebook",
              mainDocumentURL.pathComponents.starts(with: ["/", "load"]) else {
            print(
                "# EBOOKFIX1 unexpected source URL for \(route)",
                "mainDocumentURL:",
                mainDocumentURL.absoluteString
            )
            return nil
        }
        if !hasLoggedValidatedMainDocumentURL {
            hasLoggedValidatedMainDocumentURL = true
            print(
                "# EBOOKFIX1 validated ebook source",
                "route:",
                route,
                "mainDocumentURL:",
                mainDocumentURL.absoluteString
            )
        }
        return mainDocumentURL
    }

    nonisolated private static func mimeType(ofFileAtUrl url: URL) -> String? {
        return UTType(filenameExtension: url.lakePathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}

fileprivate extension String {
    func deletingPrefix(_ prefix: String) -> String {
        guard self.hasPrefix(prefix) else { return self }
        return String(self.dropFirst(prefix.count))
    }
}
