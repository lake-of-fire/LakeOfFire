import SwiftUI
@preconcurrency import WebKit
import UniformTypeIdentifiers
import SwiftSoup
import SwiftUtilities
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent
import LakeOfFireFiles
import LakeKit

fileprivate let ebookHTMLDebugMarker = "芥川賞"
fileprivate let ebookHTMLTargetSectionFragments = [
    "item/xhtml/title.xhtml",
    "item/xhtml/0001.xhtml",
]

fileprivate func shouldLogEbookHTMLPayload(_ html: String, location: String? = nil) -> Bool {
    if html.contains(ebookHTMLDebugMarker) {
        return true
    }
    if let location {
        return ebookHTMLTargetSectionFragments.contains(where: { location.contains($0) })
    }
    return false
}

fileprivate func logEbookHTML(
    stage: String,
    location: String,
    contentURL: URL,
    isCacheWarmer: Bool,
    html: String
) {
    let segmentCount = html.components(separatedBy: "<mnb-seg").count - 1
    let hasTrackingFlag = html.contains("data-manabi-tracking-enabled")
    print("# EBOOKHTML stage=\(stage) cacheWarmer=\(isCacheWarmer) contentURL=\(contentURL.absoluteString) location=\(location) length=\(html.utf8.count) segmentCount=\(max(segmentCount, 0)) hasTrackingFlag=\(hasTrackingFlag)")
}

fileprivate func logEbookAsset(_ line: String) {
    Logger.shared.logger.info("\(line)")
}

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

struct EBookProcessTextRequestKey: Hashable {
    let contentURLString: String
    let location: String
    let isCacheWarmer: Bool
    let textFingerprint: String

    init(contentURL: URL, location: String, isCacheWarmer: Bool, text: String) {
        contentURLString = contentURL.absoluteString
        self.location = location
        self.isCacheWarmer = isCacheWarmer
        // Keep the key compact while still distinguishing different request bodies.
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
        if inFlightWaitersByKey[key] != nil {
            let response = await withCheckedContinuation { continuation in
                inFlightWaitersByKey[key, default: []].append(continuation)
            }
            return (try resolve(response), true)
        }

        inFlightWaitersByKey[key] = []
        let response: ProcessTextOutcome
        do {
            response = .success(try await operation())
        } catch is CancellationError {
            response = .cancelled
        } catch {
            response = .failure(error.localizedDescription)
        }
        let waiters = inFlightWaitersByKey.removeValue(forKey: key) ?? []
        for waiter in waiters {
            waiter.resume(returning: response)
        }
        return (try resolve(response), false)
    }
}

fileprivate actor EBookProcessingActor {
    let ebookTextProcessorCacheHits: EbookTextProcessorCacheHitsHandler?
    let ebookTextProcessor: EbookTextProcessor?
    let processReadabilityContent: EbookReadabilityContentProcessor?
    let processHTML: EbookHTMLProcessor?

    init(
        ebookTextProcessorCacheHits: EbookTextProcessorCacheHitsHandler?,
        ebookTextProcessor: EbookTextProcessor?,
        processReadabilityContent: EbookReadabilityContentProcessor?,
        processHTML: EbookHTMLProcessor?
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
    ) async throws -> String {
        // TODO: Consolidate sectionLocationURL creation with ebookTextProcessor's
        let sectionLocationURL = contentURL.appending(queryItems: [.init(name: "subpath", value: location)])
        if isCacheWarmer,
           let ebookTextProcessorCacheHits,
           (try? await ebookTextProcessorCacheHits(sectionLocationURL, text)) ?? false {
            // Bail early if we are already cached
            return ""
        }

        guard let ebookTextProcessor else {
            return text
        }

        //        debugPrint("# from: ", text.prefix(1000), "to:", respText)
        return try await ebookTextProcessor(
            contentURL,
            location,
            text,
            isCacheWarmer,
            processReadabilityContent,
            processHTML
        )
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
        // Load HTML content from bundle path
        var html = try String(contentsOfFile: viewerHtmlPath)

        let shouldEnablePageTurnInteractionDiagnostic =
            ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1"

        // Inject shared font CSS payload as a single blob URL for all sections.
        var base64 = sharedFontCSSBase64
        if (base64 == nil || base64?.isEmpty == true), let provider = sharedFontCSSBase64Provider {
            base64 = await provider()
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
            <script id="manabi-font-css-base64" type="application/json">\(base64)</script>
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

typealias EbookDocumentTransform = @Sendable (SwiftSoup.Document) async -> SwiftSoup.Document
typealias EbookReadabilityContentProcessor = @Sendable (String, URL, URL?, Bool, EbookDocumentTransform) async throws -> SwiftSoup.Document
typealias EbookHTMLProcessor = @Sendable (String, Bool) async -> String
typealias EbookTextProcessor = @Sendable (URL, String, String, Bool, EbookReadabilityContentProcessor?, EbookHTMLProcessor?) async throws -> String
typealias EbookTextProcessorCacheHitsHandler = @Sendable (URL, String?) async throws -> Bool
typealias SharedFontCSSBase64Provider = @Sendable () async -> String?

public final class EbookURLSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated(unsafe) var ebookTextProcessorCacheHits: EbookTextProcessorCacheHitsHandler?
    nonisolated(unsafe) var ebookTextProcessor: EbookTextProcessor?
    public var readerFileManager: ReaderFileManager?
    nonisolated(unsafe) var processReadabilityContent: EbookReadabilityContentProcessor?
    nonisolated(unsafe) var processHTML: EbookHTMLProcessor?
    /// Optional base64-encoded shared font CSS supplied by the host app to avoid adding a dependency here.
    nonisolated(unsafe) public var sharedFontCSSBase64: String?
    /// Optional provider to lazily supply the base64 CSS when not yet set.
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
        schemeHandlers[urlSchemeTask.hash] = urlSchemeTask

        guard let url = urlSchemeTask.request.url else { return }
        if ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" {
            let mainDocumentURL = urlSchemeTask.request.mainDocumentURL?.absoluteString ?? "nil"
            print("# EBOOKASSET start url=\(url.absoluteString) mainDocument=\(mainDocumentURL)")
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
            return
        }
        guard let readerFileManager else {
            print("Error: Missing ReaderFileManager in EbookURLSchemeHandler")
            urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
            return
        }
        let ebookTextProcessorCacheHits = self.ebookTextProcessorCacheHits
        let ebookTextProcessor = self.ebookTextProcessor
        let processReadabilityContent = self.processReadabilityContent
        let processHTML = self.processHTML
        let sharedFontCSSBase64 = self.sharedFontCSSBase64
        let sharedFontCSSBase64Provider = self.sharedFontCSSBase64Provider

        Task.detached(priority: .utility) { @EbookURLSchemeActor [weak self] in
            guard let self else { return }
            let taskHash = urlSchemeTask.hash
            if url.path == "/process-text" {
                print("# EBOOKPERF process-text.enter task=\(taskHash) url=\(url.absoluteString)")
                let request = urlSchemeTask.request
                if request.httpMethod == "POST",
                   let payload = ebookRequestBodyData(request),
                   let text = String(data: payload, encoding: .utf8),
                   let replacedTextLocation = request.value(forHTTPHeaderField: "X-REPLACED-TEXT-LOCATION"),
                   let contentURLRaw = request.value(forHTTPHeaderField: "X-CONTENT-LOCATION"),
                   let contentURL = URL(string: contentURLRaw) {
                    if let ebookTextProcessor, let processReadabilityContent, let processHTML {
                        let isCacheWarmer = urlSchemeTask.request.value(forHTTPHeaderField: "X-IS-CACHE-WARMER") == "true"
                        let shouldLogRequest = shouldLogEbookHTMLPayload(text, location: replacedTextLocation)
                        if shouldLogRequest {
                            logEbookHTML(
                                stage: "swift.scheme.processText.requestRaw",
                                location: replacedTextLocation,
                                contentURL: contentURL,
                                isCacheWarmer: isCacheWarmer,
                                html: text
                            )
                        }
                        let processRequestKey = EBookProcessTextRequestKey(
                            contentURL: contentURL,
                            location: replacedTextLocation,
                            isCacheWarmer: isCacheWarmer,
                            text: text
                        )
                        debugPrint("# EBOOKPERF process-text.recv", replacedTextLocation, "cacheWarmer:", isCacheWarmer, "task:", taskHash, "payloadLen:", payload.count)

                        //                        print("# ebook proc text endpoint", replacedTextLocation)
                        //                        if !isCacheWarmer {
                        //                            print("# ebook proc", replacedTextLocation, text)
                        //                        }
                        let cacheHitsHandler = ebookTextProcessorCacheHits
                        let processor = ebookTextProcessor
                        let readabilityProcessor = processReadabilityContent
                        let htmlProcessor = processHTML
                        var respText = text
                        var didCoalesce = false
                        do {
                            (respText, didCoalesce) = try await self.processTextRequestDeduper.process(
                                key: processRequestKey
                            ) {
                                let processingActor = EBookProcessingActor(
                                    ebookTextProcessorCacheHits: cacheHitsHandler,
                                    ebookTextProcessor: processor,
                                    processReadabilityContent: readabilityProcessor,
                                    processHTML: htmlProcessor
                                )
                                return try await processingActor.process(
                                    contentURL: contentURL,
                                    location: replacedTextLocation,
                                    text: text,
                                    isCacheWarmer: isCacheWarmer
                                )
                            }
                        } catch {
                            if error is CancellationError {
                                let cancellationError = CancellationError()
                                debugPrint(
                                    "# EBOOKPERF process-text.cancelled",
                                    replacedTextLocation,
                                    "cacheWarmer:",
                                    isCacheWarmer,
                                    "task:",
                                    taskHash
                                )
                                await { @MainActor in
                                    if self.schemeHandlers[urlSchemeTask.hash] != nil {
                                        urlSchemeTask.didFailWithError(cancellationError)
                                        self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                                    }
                                }()
                                return
                            }
                            debugPrint(
                                "# EBOOKPERF process-text.failed",
                                replacedTextLocation,
                                "cacheWarmer:",
                                isCacheWarmer,
                                "task:",
                                taskHash,
                                "error:",
                                error.localizedDescription
                            )
                            print("Error processing Ebook text: \(error)")
                        }
                        if didCoalesce {
                            debugPrint(
                                "# EBOOKPERF process-text.coalesced",
                                replacedTextLocation,
                                "cacheWarmer:",
                                isCacheWarmer,
                                "task:",
                                taskHash
                            )
                        }
                        if shouldLogRequest || shouldLogEbookHTMLPayload(respText, location: replacedTextLocation) {
                            logEbookHTML(
                                stage: "swift.scheme.processText.responseToViewer",
                                location: replacedTextLocation,
                                contentURL: contentURL,
                                isCacheWarmer: isCacheWarmer,
                                html: respText
                            )
                        }
                        debugPrint("# EBOOKPERF process-text.processed", replacedTextLocation, "cacheWarmer:", isCacheWarmer, "task:", taskHash, "respLen:", respText.count)
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
                    } else if let respData = text.data(using: .utf8) {
                        let isCacheWarmer = urlSchemeTask.request.value(forHTTPHeaderField: "X-IS-CACHE-WARMER") == "true"
                        if shouldLogEbookHTMLPayload(text, location: replacedTextLocation) {
                            logEbookHTML(
                                stage: "swift.scheme.processText.passthroughResponse",
                                location: replacedTextLocation,
                                contentURL: contentURL,
                                isCacheWarmer: isCacheWarmer,
                                html: text
                            )
                        }
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
                    } else {
                        await { @MainActor in
                            urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                        }()
                    }
                } else {
                    print(
                        "# EBOOKPERF process-text.invalid-request",
                        "task:",
                        taskHash,
                        "method:",
                        request.httpMethod ?? "nil",
                        "hasHTTPBody:",
                        request.httpBody != nil,
                        "hasHTTPBodyStream:",
                        request.httpBodyStream != nil,
                        "replacedTextLocation:",
                        request.value(forHTTPHeaderField: "X-REPLACED-TEXT-LOCATION") ?? "nil",
                        "contentLocation:",
                        request.value(forHTTPHeaderField: "X-CONTENT-LOCATION") ?? "nil"
                    )
                    await { @MainActor in
                        if self.schemeHandlers[urlSchemeTask.hash] != nil {
                            urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                            self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                        }
                    }()
                }
            } else if url.path == "/entries" {
                guard let mainDocumentURL = self.validatedMainDocumentURL(for: urlSchemeTask.request, route: "/entries") else {
                    await { @MainActor in
                        urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                    }()
                    return
                }

                do {
                    let cachedSource = try await ReaderPackageEntrySourceCache.shared.cachedSource(
                        forPackageURL: mainDocumentURL,
                        readerFileManager: readerFileManager
                    )
                    debugPrint(
                        "# EBOOKPERF entries.success",
                        "sourceURL:",
                        mainDocumentURL.absoluteString,
                        "count:",
                        cachedSource.entries.count
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
                } catch {
                    debugPrint(
                        "# EBOOKPERF entries.error",
                        "sourceURL:",
                        mainDocumentURL.absoluteString,
                        "error:",
                        error.localizedDescription
                    )
                    await { @MainActor in
                        urlSchemeTask.didFailWithError(error)
                        self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                    }()
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
                    return
                }

                do {
                    let entryStart = Date()
                    print(
                        "# EBOOKPERF entry.begin",
                        "sourceURL:",
                        mainDocumentURL.absoluteString,
                        "subpath:",
                        subpath
                    )
                    let cachedSource = try await ReaderPackageEntrySourceCache.shared.cachedSource(
                        forPackageURL: mainDocumentURL,
                        readerFileManager: readerFileManager
                    )
                    print(
                        "# EBOOKPERF entry.cachedSource",
                        "sourceURL:",
                        mainDocumentURL.absoluteString,
                        "subpath:",
                        subpath,
                        "elapsedMs:",
                        Int(Date().timeIntervalSince(entryStart) * 1000)
                    )
                    let readStart = Date()
                    let data = try cachedSource.source.readEntry(subpath: subpath)
                    print(
                        "# EBOOKPERF entry.read",
                        "sourceURL:",
                        mainDocumentURL.absoluteString,
                        "subpath:",
                        subpath,
                        "bytes:",
                        data.count,
                        "elapsedMs:",
                        Int(Date().timeIntervalSince(readStart) * 1000)
                    )
                    let metadataStart = Date()
                    let metadata = try cachedSource.source.mimeType(subpath: subpath)
                    print(
                        "# EBOOKPERF entry.success",
                        "sourceURL:",
                        mainDocumentURL.absoluteString,
                        "subpath:",
                        subpath,
                        "bytes:",
                        data.count,
                        "mimeType:",
                        metadata.mimeType,
                        "metadataElapsedMs:",
                        Int(Date().timeIntervalSince(metadataStart) * 1000),
                        "totalElapsedMs:",
                        Int(Date().timeIntervalSince(entryStart) * 1000)
                    )
                    let response = HTTPURLResponse(
                        url: url,
                        mimeType: metadata.mimeType,
                        expectedContentLength: data.count,
                        textEncodingName: metadata.textEncodingName
                    )
                    await { @MainActor in
                        if self.schemeHandlers[urlSchemeTask.hash] != nil {
                            print(
                                "# EBOOKPERF entry.respond",
                                "sourceURL:",
                                mainDocumentURL.absoluteString,
                                "subpath:",
                                subpath,
                                "bytes:",
                                data.count
                            )
                            urlSchemeTask.didReceive(response)
                            urlSchemeTask.didReceive(data)
                            urlSchemeTask.didFinish()
                            self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                        }
                    }()
                } catch {
                    if let sourceError = error as? ReaderPackageEntrySourceError,
                       case .entryNotFound = sourceError {
                        let response = HTTPURLResponse(
                            url: url,
                            statusCode: 404,
                            httpVersion: nil,
                            headerFields: nil
                        )!
                        print(
                            "# EBOOKPERF entry.missing",
                            "sourceURL:",
                            mainDocumentURL.absoluteString,
                            "subpath:",
                            subpath
                        )
                        await { @MainActor in
                            if self.schemeHandlers[urlSchemeTask.hash] != nil {
                                urlSchemeTask.didReceive(response)
                                urlSchemeTask.didFinish()
                                self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                            }
                        }()
                        return
                    }
                    print(
                        "# EBOOKPERF entry.error",
                        "sourceURL:",
                        mainDocumentURL.absoluteString,
                        "subpath:",
                        subpath,
                        "error:",
                        error.localizedDescription
                    )
                    await { @MainActor in
                        urlSchemeTask.didFailWithError(error)
                        self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                    }()
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
                } else if let viewerHtmlPath = Bundle.module.path(forResource: "ebook-viewer", ofType: "html", inDirectory: "foliate-js") {
                    // File viewer bundle file.
                    if ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" {
                        logEbookAsset("# EBOOKASSET fallbackViewerHTML url=\(url.absoluteString) path=\(viewerHtmlPath)")
                    }
                    do {
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
                    } catch {
                        print(error)
                        await { @MainActor in
                            urlSchemeTask.didFailWithError(error)
                            self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                        }()
                    }
                } else {
                    if ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" {
                        logEbookAsset("# EBOOKASSET missing url=\(url.absoluteString)")
                    }
                    await { @MainActor in
                        urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                    }()
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
            debugPrint(
                "# EBOOKPERF entry-source.invalid route:",
                route,
                "reason:",
                "missingSourceURL",
                "requestURL:",
                request.url?.absoluteString ?? "nil",
                "requestedSourceURL:",
                requestedSourceURL ?? "nil",
                "querySourceURL:",
                requestSourceURL ?? "nil"
            )
            assertionFailure("Missing source URL for ebook entry request")
            return nil
        }
        guard mainDocumentURL.scheme == "ebook",
              mainDocumentURL.host == "ebook",
              mainDocumentURL.pathComponents.starts(with: ["/", "load"]) else {
            debugPrint(
                "# EBOOKPERF entry-source.invalid route:",
                route,
                "reason:",
                "unexpectedSourceURL",
                "mainDocumentURL:",
                mainDocumentURL.absoluteString,
                "requestedSourceURL:",
                requestedSourceURL ?? "nil",
                "querySourceURL:",
                requestSourceURL ?? "nil"
            )
            assertionFailure("Unexpected source URL for ebook entry request: \(mainDocumentURL.absoluteString)")
            return nil
        }
        if let requestedSourceURL,
           requestedSourceURL != mainDocumentURL.absoluteString {
            debugPrint("# EBOOKPERF entry-source.mismatch route:", route, "mainDocumentURL:", mainDocumentURL.absoluteString, "requestedSourceURL:", requestedSourceURL)
        }
        if let requestSourceURL,
           requestSourceURL != mainDocumentURL.absoluteString {
            debugPrint("# EBOOKPERF entry-source.query-mismatch route:", route, "mainDocumentURL:", mainDocumentURL.absoluteString, "querySourceURL:", requestSourceURL)
            assertionFailure("Mismatched ebook source URL and mainDocumentURL")
        }
        if !hasLoggedValidatedMainDocumentURL {
            hasLoggedValidatedMainDocumentURL = true
            debugPrint(
                "# EBOOKPERF entry-source.mainDocumentURL route:",
                route,
                "mainDocumentURL:",
                mainDocumentURL.absoluteString,
                "requestedSourceURL:",
                requestedSourceURL ?? "nil",
                "querySourceURL:",
                requestSourceURL ?? "nil"
            )
        }
        return mainDocumentURL
    }

    nonisolated private static func mimeType(ofFileAtUrl url: URL) -> String? {
        switch url.lakePathExtension.lowercased() {
        case "js", "mjs":
            return "text/javascript"
        case "css":
            return "text/css"
        case "html", "htm":
            return "text/html"
        case "json":
            return "application/json"
        case "svg":
            return "image/svg+xml"
        default:
            return UTType(filenameExtension: url.lakePathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}

fileprivate extension String {
    func deletingPrefix(_ prefix: String) -> String {
        guard self.hasPrefix(prefix) else { return self }
        return String(self.dropFirst(prefix.count))
    }
}
