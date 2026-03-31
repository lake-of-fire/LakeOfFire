import SwiftUI
import WebKit
import UniformTypeIdentifiers
import SwiftSoup
import SwiftUtilities
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent

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
    let segmentCount = html.components(separatedBy: "<manabi-segment").count - 1
    let hasTrackingFlag = html.contains("data-manabi-tracking-enabled")
    print("# EBOOKHTML stage=\(stage) cacheWarmer=\(isCacheWarmer) contentURL=\(contentURL.absoluteString) location=\(location) length=\(html.utf8.count) segmentCount=\(max(segmentCount, 0)) hasTrackingFlag=\(hasTrackingFlag)")
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
        operation: () async throws -> String
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
    let ebookTextProcessorCacheHits: ((URL, String?) async throws -> Bool)?
    let ebookTextProcessor: ((URL, String, String, Bool, ((String, URL, URL?, Bool, (SwiftSoup.Document) async -> SwiftSoup.Document) async throws -> SwiftSoup.Document)?, ((String, Bool) async -> String)?) async throws -> String)?
    let processReadabilityContent: ((String, URL, URL?, Bool, ((SwiftSoup.Document) async -> SwiftSoup.Document)) async throws -> SwiftSoup.Document)?
    let processHTML: ((String, Bool) async -> String)?

    init(
        ebookTextProcessorCacheHits: ((URL, String?) async throws -> Bool)?,
        ebookTextProcessor: ((URL, String, String, Bool, ((String, URL, URL?, Bool, (SwiftSoup.Document) async -> SwiftSoup.Document) async throws -> SwiftSoup.Document)?, ((String, Bool) async -> String)?) async throws -> String)?,
        processReadabilityContent: ((String, URL, URL?, Bool, ((SwiftSoup.Document) async -> SwiftSoup.Document)) async throws -> SwiftSoup.Document)?,
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
        sharedFontCSSBase64Provider: (() async -> String?)?
    ) async throws -> (HTTPURLResponse, Data) {
        // Load HTML content from bundle path
        var html = try String(contentsOfFile: viewerHtmlPath)

        // Inject shared font CSS payload as a single blob URL for all sections.
        var base64 = sharedFontCSSBase64
        if (base64 == nil || base64?.isEmpty == true), let provider = sharedFontCSSBase64Provider {
            base64 = await provider()
        }

        if let base64, !base64.isEmpty {
            let payload = """
            <script id="manabi-font-css-base64" type="application/json">\(base64)</script>
            <script>
            (function() {
                try {
                    globalThis.manabiFontCSSBase64 = "\(base64)";
                    const el = document.getElementById('manabi-font-css-base64');
                    if (!el || globalThis.manabiFontCSSBlobURL) return;
                    const css = atob(el.textContent || '');
                    const blob = new Blob([css], { type: 'text/css' });
                    const url = URL.createObjectURL(blob);
                    globalThis.manabiFontCSSBlobURL = url;
                } catch (err) {
                    console.error('Failed to prepare font blob', err);
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
    public static var shared = EbookURLSchemeActor()

    public init() { }
}

public final class EbookURLSchemeHandler: NSObject, WKURLSchemeHandler {
    public var ebookTextProcessorCacheHits: ((URL, String?) async throws -> Bool)?
    public var ebookTextProcessor: ((URL, String, String, Bool, ((String, URL, URL?, Bool, (SwiftSoup.Document) async -> SwiftSoup.Document) async throws -> SwiftSoup.Document)?, ((String, Bool) async -> String)?) async throws -> String)?
    public var readerFileManager: ReaderFileManager?
    public var processReadabilityContent: ((String, URL, URL?, Bool, ((SwiftSoup.Document) async -> SwiftSoup.Document)) async throws -> SwiftSoup.Document)?
    public var processHTML: ((String, Bool) async -> String)?
    /// Optional base64-encoded shared font CSS supplied by the host app to avoid adding a dependency here.
    public var sharedFontCSSBase64: String?
    /// Optional provider to lazily supply the base64 CSS when not yet set.
    public var sharedFontCSSBase64Provider: (() async -> String?)?

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
        guard let readerFileManager else {
            print("Error: Missing ReaderFileManager in EbookURLSchemeHandler")
            urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
            return
        }

        Task.detached(priority: .utility) { @EbookURLSchemeActor [weak self] in
            guard let self else { return }
            let taskHash = urlSchemeTask.hash
            if url.path == "/process-text" {
                if urlSchemeTask.request.httpMethod == "POST", let payload = urlSchemeTask.request.httpBody, let text = String(data: payload, encoding: .utf8), let replacedTextLocation = urlSchemeTask.request.value(forHTTPHeaderField: "X-REPLACED-TEXT-LOCATION"), let contentURLRaw = urlSchemeTask.request.value(forHTTPHeaderField: "X-CONTENT-LOCATION"), let contentURL = URL(string: contentURLRaw) {
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
                    let cachedSource = try await ReaderPackageEntrySourceCache.shared.cachedSource(
                        forPackageURL: mainDocumentURL,
                        readerFileManager: readerFileManager
                    )
                    let data = try cachedSource.source.readEntry(subpath: subpath)
                    let metadata = try cachedSource.source.mimeType(subpath: subpath)
                    debugPrint(
                        "# EBOOKPERF entry.success",
                        "sourceURL:",
                        mainDocumentURL.absoluteString,
                        "subpath:",
                        subpath,
                        "bytes:",
                        data.count,
                        "mimeType:",
                        metadata.mimeType
                    )
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
                } catch {
                    if let sourceError = error as? ReaderPackageEntrySourceError,
                       case .entryNotFound = sourceError {
                        let response = HTTPURLResponse(
                            url: url,
                            statusCode: 404,
                            httpVersion: nil,
                            headerFields: nil
                        )!
                        debugPrint(
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
                    debugPrint(
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
                if let fileUrl = bundleURLFromWebURL(url),
                   let mimeType = mimeType(ofFileAtUrl: fileUrl),
                   let data = try? Data(contentsOf: fileUrl) {
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
                    do {
                        let (response, data) = try await EBookLoadingActor().loadViewerFile(
                            at: viewerHtmlPath,
                            originalURL: url,
                            sharedFontCSSBase64: self.sharedFontCSSBase64,
                            sharedFontCSSBase64Provider: self.sharedFontCSSBase64Provider
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
                    await { @MainActor in
                        urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                    }()
                }
            }
        }
    }

    private func bundleURLFromWebURL(_ url: URL) -> URL? {
        guard url.path.hasPrefix("/load/viewer-assets/") else { return nil }
        let assetName = url.deletingPathExtension().lastPathComponent
        let assetExtension = url.pathExtension
        let assetDirectory = url.deletingLastPathComponent().path.deletingPrefix("/load/viewer-assets/")
        return Bundle.module.url(forResource: assetName, withExtension: assetExtension, subdirectory: assetDirectory)
    }

    @EbookURLSchemeActor
    private func validatedMainDocumentURL(for request: URLRequest, route: String) -> URL? {
        let requestedSourceURL = request.value(forHTTPHeaderField: "X-Ebook-Source-URL")
        guard let mainDocumentURL = request.mainDocumentURL else {
            debugPrint("# EBOOKPERF entry-source.invalid route:", route, "reason:", "missingMainDocumentURL", "requestURL:", request.url?.absoluteString ?? "nil", "requestedSourceURL:", requestedSourceURL ?? "nil")
            assertionFailure("Missing mainDocumentURL for ebook entry request")
            return nil
        }
        guard mainDocumentURL.scheme == "ebook",
              mainDocumentURL.host == "ebook",
              mainDocumentURL.pathComponents.starts(with: ["/", "load"]) else {
            debugPrint("# EBOOKPERF entry-source.invalid route:", route, "reason:", "unexpectedMainDocumentURL", "mainDocumentURL:", mainDocumentURL.absoluteString, "requestedSourceURL:", requestedSourceURL ?? "nil")
            assertionFailure("Unexpected mainDocumentURL for ebook entry request: \(mainDocumentURL.absoluteString)")
            return nil
        }
        if let requestedSourceURL,
           requestedSourceURL != mainDocumentURL.absoluteString {
            debugPrint("# EBOOKPERF entry-source.mismatch route:", route, "mainDocumentURL:", mainDocumentURL.absoluteString, "requestedSourceURL:", requestedSourceURL)
            assertionFailure("Mismatched ebook source URL and mainDocumentURL")
        }
        if !hasLoggedValidatedMainDocumentURL {
            hasLoggedValidatedMainDocumentURL = true
            debugPrint("# EBOOKPERF entry-source.mainDocumentURL route:", route, "mainDocumentURL:", mainDocumentURL.absoluteString, "requestedSourceURL:", requestedSourceURL ?? "nil")
        }
        return mainDocumentURL
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
