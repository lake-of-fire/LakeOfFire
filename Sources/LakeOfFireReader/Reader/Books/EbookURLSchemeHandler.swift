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

fileprivate func ebookHTMLAttributeEscaped(_ string: String) -> String {
    string
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

struct EBookProcessedSectionWritingHint {
    let direction: String
    let writingMode: String
}

fileprivate func ebookProcessedSectionWritingHint(from url: URL) -> EBookProcessedSectionWritingHint? {
    let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let direction = queryItems
        .first(where: { $0.name == "mnbWritingDirection" })?
        .value?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    guard direction == "vertical" else { return nil }
    let requestedWritingMode = queryItems
        .first(where: { $0.name == "mnbWritingMode" })?
        .value?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    let writingMode = requestedWritingMode == "vertical-lr" ? "vertical-lr" : "vertical-rl"
    return EBookProcessedSectionWritingHint(direction: "vertical", writingMode: writingMode)
}

func ebookHTMLWithInjectedPresentationHints(_ html: String, writingHint: EBookProcessedSectionWritingHint?) -> String {
    guard let writingHint else { return html }
    guard let bodyTagRange = html.range(of: "<body", options: [.caseInsensitive]) else { return html }
    let afterBodyName = bodyTagRange.upperBound
    if afterBodyName < html.endIndex {
        let nextCharacter = html[afterBodyName]
        guard nextCharacter == ">" || nextCharacter == "/" || nextCharacter.isWhitespace else { return html }
    }
    guard let tagEnd = html[afterBodyName...].firstIndex(of: ">") else { return html }

    let attributes = [
        "data-mnb-writing-direction=\"\(ebookHTMLAttributeEscaped(writingHint.direction))\"",
        "data-mnb-writing-mode=\"\(ebookHTMLAttributeEscaped(writingHint.writingMode))\"",
        "data-mnb-foliate-writing-direction=\"\(ebookHTMLAttributeEscaped(writingHint.direction))\"",
        "data-mnb-foliate-writing-mode=\"\(ebookHTMLAttributeEscaped(writingHint.writingMode))\""
    ].joined(separator: " ")

    var result = html
    result.insert(contentsOf: " \(attributes)", at: tagEnd)
    return result
}

func ebookHTTPResponse(
    url: URL,
    mimeType: String,
    byteCount: Int,
    textEncodingName: String? = nil,
    additionalHeaderFields: [String: String] = [:]
) -> HTTPURLResponse {
    var contentType = mimeType
    if let textEncodingName {
        contentType += "; charset=\(textEncodingName)"
    }
    var headerFields = additionalHeaderFields
    headerFields["Content-Type"] = contentType
    headerFields["Content-Length"] = "\(byteCount)"
    return HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: nil,
        headerFields: headerFields
    )!
}

func ebookProcessTextResponseData(processedText: String, isCacheWarmer: Bool) -> Data? {
    if isCacheWarmer {
        return Data()
    }
    return processedText.data(using: .utf8)
}

actor EbookViewerAssetCache {
    static let shared = EbookViewerAssetCache()

    private var dataByFileURL = [URL: Data]()

    func data(for fileURL: URL) throws -> Data {
        if let cachedData = dataByFileURL[fileURL] {
            return cachedData
        }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        dataByFileURL[fileURL] = data
        return data
    }
}

public func ebookProcessTextFingerprint(_ text: String) -> String {
    "\(text.utf8.count)-\(stableHash(text))"
}

struct EBookProcessTextRequestKey: Hashable, Sendable {
    let contentURLString: String
    let location: String
    let textFingerprint: String

    init(contentURL: URL, location: String, isCacheWarmer _: Bool, text: String) {
        self.init(contentURL: contentURL, location: location, text: text)
    }

    init(contentURL: URL, location: String, text: String) {
        contentURLString = contentURL.absoluteString
        self.location = location
        textFingerprint = ebookProcessTextFingerprint(text)
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
        let resolvedResponse = try resolve(response)
        return (resolvedResponse, false)
    }
}

public struct EBookNativeSectionPrewarmResult: Equatable, Sendable {
    public let sectionHref: String
    public let requestBytes: Int
    public let responseBytes: Int
    public let pageStatsRequested: Bool
    public let pageStatsProduced: Bool

    public init(
        sectionHref: String,
        requestBytes: Int,
        responseBytes: Int,
        pageStatsRequested: Bool = true,
        pageStatsProduced: Bool = false
    ) {
        self.sectionHref = sectionHref
        self.requestBytes = requestBytes
        self.responseBytes = responseBytes
        self.pageStatsRequested = pageStatsRequested
        self.pageStatsProduced = pageStatsProduced
    }
}

actor EBookProcessingActor {
    let ebookProcessedTextCacheReader: EbookProcessedTextCacheReader?
    let ebookProcessedTextCacheWriter: EbookProcessedTextCacheWriter?
    let ebookTextProcessor: EbookTextProcessor?
    let processReadabilityContent: EbookReadabilityContentProcessor?
    let processHTMLDocument: EbookHTMLDocumentProcessor?
    let processHTMLBytes: EbookHTMLBytesProcessor?
    let processHTML: EbookHTMLProcessor?

    init(
        ebookProcessedTextCacheReader: EbookProcessedTextCacheReader? = nil,
        ebookProcessedTextCacheWriter: EbookProcessedTextCacheWriter? = nil,
        ebookTextProcessor: EbookTextProcessor?,
        processReadabilityContent: EbookReadabilityContentProcessor?,
        processHTMLDocument: EbookHTMLDocumentProcessor? = nil,
        processHTMLBytes: EbookHTMLBytesProcessor?,
        processHTML: EbookHTMLProcessor?
    ) {
        self.ebookProcessedTextCacheReader = ebookProcessedTextCacheReader
        self.ebookProcessedTextCacheWriter = ebookProcessedTextCacheWriter
        self.ebookTextProcessor = ebookTextProcessor
        self.processReadabilityContent = processReadabilityContent
        self.processHTMLDocument = processHTMLDocument
        self.processHTMLBytes = processHTMLBytes
        self.processHTML = processHTML
    }

    func prewarm(
        contentURL: URL,
        sectionHref: String,
        source: ReaderPackageEntrySource
    ) async throws -> EBookNativeSectionPrewarmResult {
        let entryData = try source.readEntry(subpath: sectionHref)
        let entryText = String(decoding: entryData, as: UTF8.self)
        let processedText = try await process(
            contentURL: contentURL,
            location: sectionHref,
            text: entryText,
            isCacheWarmer: true
        )
        return EBookNativeSectionPrewarmResult(
            sectionHref: sectionHref,
            requestBytes: entryData.count,
            responseBytes: processedText.utf8.count
        )
    }

    func process(
        contentURL: URL,
        location: String,
        text: String,
        contentFingerprint: String? = nil,
        isCacheWarmer: Bool,
        shouldReadProcessedCache: Bool = true
    ) async throws -> String {
        let resolvedContentFingerprint = contentFingerprint ?? EBookProcessTextRequestKey(
            contentURL: contentURL,
            location: location,
            isCacheWarmer: isCacheWarmer,
            text: text
        ).textFingerprint
        if shouldReadProcessedCache, let ebookProcessedTextCacheReader {
            if let cachedResult = try await ebookProcessedTextCacheReader(
                contentURL,
                location,
                text,
                resolvedContentFingerprint
            ) {
                return cachedResult
            }
        }
        guard let ebookTextProcessor else {
            return text
        }

        let result = try await ebookTextProcessor(
            contentURL,
            location,
            text,
            resolvedContentFingerprint,
            isCacheWarmer,
            processReadabilityContent,
            processHTMLDocument,
            processHTMLBytes,
            processHTML
        )
        if !isCacheWarmer,
           let ebookProcessedTextCacheWriter {
            await ebookProcessedTextCacheWriter(contentURL, location, text, resolvedContentFingerprint, result)
        }
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
        sharedFontCSSBase64 _: String?,
        sharedFontCSSBase64Provider _: SharedFontCSSBase64Provider?
    ) async throws -> (HTTPURLResponse, Data) {
        let shouldEnablePageTurnInteractionDiagnostic =
            ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1"
        let data: Data
        if shouldEnablePageTurnInteractionDiagnostic {
            var html = try String(contentsOfFile: viewerHtmlPath, encoding: .utf8)
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
            guard let encodedHTML = html.data(using: .utf8) else {
                throw EbookLoadingError.fileNotFound
            }
            data = encodedHTML
        } else {
            data = try Data(
                contentsOf: URL(fileURLWithPath: viewerHtmlPath),
                options: [.mappedIfSafe]
            )
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
public typealias EbookReadabilityContentProcessor = @Sendable (String, URL, URL?, Bool, Bool, String?, EbookDocumentTransform) async throws -> SwiftSoup.Document
public typealias EbookHTMLDocumentProcessor = @Sendable (SwiftSoup.Document, Bool) async throws -> [UInt8]
public typealias EbookHTMLBytesProcessor = @Sendable ([UInt8], Bool) async -> [UInt8]
public typealias EbookHTMLProcessor = @Sendable (String, Bool) async -> String
public typealias EbookTextProcessor = @Sendable (URL, String, String, String?, Bool, EbookReadabilityContentProcessor?, EbookHTMLDocumentProcessor?, EbookHTMLBytesProcessor?, EbookHTMLProcessor?) async throws -> String
public typealias EbookProcessedTextCacheReader = @Sendable (URL, String, String, String?) async throws -> String?
public typealias EbookProcessedTextCacheWriter = @Sendable (URL, String, String, String?, String) async -> Void
public typealias SharedFontCSSBase64Provider = @Sendable () async -> String?

public final class EbookURLSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated(unsafe) var ebookProcessedTextCacheReader: EbookProcessedTextCacheReader?
    nonisolated(unsafe) var ebookProcessedTextCacheWriter: EbookProcessedTextCacheWriter?
    nonisolated(unsafe) var ebookTextProcessor: EbookTextProcessor?
    public var readerFileManager: ReaderFileManager?
    nonisolated(unsafe) var processReadabilityContent: EbookReadabilityContentProcessor?
    nonisolated(unsafe) var processHTMLDocument: EbookHTMLDocumentProcessor?
    nonisolated(unsafe) var processHTMLBytes: EbookHTMLBytesProcessor?
    nonisolated(unsafe) var processHTML: EbookHTMLProcessor?
    nonisolated(unsafe) public var sharedFontCSSBase64: String?
    nonisolated(unsafe) var sharedFontCSSBase64Provider: SharedFontCSSBase64Provider?
    nonisolated(unsafe) public var sharedReaderFontAsset: SharedReaderFontAsset?

    private var schemeHandlers: [Int: WKURLSchemeTask] = [:]
    private let processTextRequestDeduper = EBookProcessTextRequestDeduper()

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
        let mainDocumentURL = urlSchemeTask.request.mainDocumentURL?.absoluteString ?? "nil"
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
            return
        }
        guard let readerFileManager else {
            print("Error: Missing ReaderFileManager in EbookURLSchemeHandler")
            urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
            schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
            return
        }
        let ebookProcessedTextCacheReader = self.ebookProcessedTextCacheReader
        let ebookProcessedTextCacheWriter = self.ebookProcessedTextCacheWriter
        let ebookTextProcessor = self.ebookTextProcessor
        let processReadabilityContent = self.processReadabilityContent
        let processHTMLDocument = self.processHTMLDocument
        let processHTMLBytes = self.processHTMLBytes
        let processHTML = self.processHTML
        let sharedFontCSSBase64 = self.sharedFontCSSBase64
        let sharedFontCSSBase64Provider = self.sharedFontCSSBase64Provider

        Task.detached(priority: .utility) { @EbookURLSchemeActor [weak self] in
            guard let self else { return }
            if url.path == "/process-text" {
                if urlSchemeTask.request.httpMethod == "POST", let payload = ebookRequestBodyData(urlSchemeTask.request), let text = String(data: payload, encoding: .utf8), let replacedTextLocation = urlSchemeTask.request.value(forHTTPHeaderField: "X-REPLACED-TEXT-LOCATION"), let contentURLRaw = urlSchemeTask.request.value(forHTTPHeaderField: "X-CONTENT-LOCATION"), let contentURL = URL(string: contentURLRaw) {
                    if let ebookTextProcessor {
                        let isCacheWarmer = urlSchemeTask.request.value(forHTTPHeaderField: "X-IS-CACHE-WARMER") == "true"
                        let processRequestKey = EBookProcessTextRequestKey(
                            contentURL: contentURL,
                            location: replacedTextLocation,
                            isCacheWarmer: isCacheWarmer,
                            text: text
                        )
                        if !isCacheWarmer,
                           let ebookProcessedTextCacheReader,
                           let cachedText = try? await ebookProcessedTextCacheReader(
                            contentURL,
                            replacedTextLocation,
                            text,
                            processRequestKey.textFingerprint
                           ),
                           let cachedData = ebookProcessTextResponseData(processedText: cachedText, isCacheWarmer: false) {
                            let resp = HTTPURLResponse(
                                url: url,
                                mimeType: nil,
                                expectedContentLength: cachedData.count,
                                textEncodingName: "utf-8"
                            )
                            await { @MainActor in
                                if self.schemeHandlers[urlSchemeTask.hash] != nil {
                                    urlSchemeTask.didReceive(resp)
                                    urlSchemeTask.didReceive(cachedData)
                                    urlSchemeTask.didFinish()
                                    self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                                }
                            }()
                            return
                        }
                        let respText: String
                        do {
                            (respText, _) = try await self.processTextRequestDeduper.process(
                                key: processRequestKey
                            ) {
                                let processingActor = EBookProcessingActor(
                                    ebookProcessedTextCacheReader: ebookProcessedTextCacheReader,
                                    ebookProcessedTextCacheWriter: ebookProcessedTextCacheWriter,
                                    ebookTextProcessor: ebookTextProcessor,
                                    processReadabilityContent: processReadabilityContent,
                                    processHTMLDocument: processHTMLDocument,
                                    processHTMLBytes: processHTMLBytes,
                                    processHTML: processHTML
                                )
                                return try await processingActor.process(
                                    contentURL: contentURL,
                                    location: replacedTextLocation,
                                    text: text,
                                    contentFingerprint: processRequestKey.textFingerprint,
                                    isCacheWarmer: isCacheWarmer,
                                    shouldReadProcessedCache: false
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
                        if let respData = ebookProcessTextResponseData(processedText: respText, isCacheWarmer: isCacheWarmer) {
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
                    } else {
                        await { @MainActor in
                            if self.schemeHandlers[urlSchemeTask.hash] != nil {
                                urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                                self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                            }
                        }()
                    }
                } else {
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
                        await { @MainActor in
                            if self.schemeHandlers[urlSchemeTask.hash] != nil {
                                urlSchemeTask.didReceive(response)
                                urlSchemeTask.didFinish()
                                self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                            }
                        }()
                        return
                    }
                    await { @MainActor in
                        urlSchemeTask.didFailWithError(error)
                        self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                    }()
                }
            } else if url.pathComponents.starts(with: ["/", "load"]) {
                // Bundle file.
                if let fileUrl = Self.bundleURLFromWebURL(url),
                   let mimeType = Self.mimeType(ofFileAtUrl: fileUrl),
                   let data = try? await EbookViewerAssetCache.shared.data(for: fileUrl) {
                    if ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" {
                        logEbookAsset("# EBOOKASSET hit url=\(url.absoluteString) fileURL=\(fileUrl.absoluteString) mime=\(mimeType) bytes=\(data.count)")
                    }
                    let response = ebookHTTPResponse(
                        url: url,
                        mimeType: mimeType,
                        byteCount: data.count,
                        textEncodingName: mimeType.hasPrefix("text/") ? "utf-8" : nil,
                        additionalHeaderFields: [
                            "Cache-Control": "no-store, no-cache, must-revalidate",
                            "Pragma": "no-cache",
                            "Expires": "0",
                        ]
                    )
                    await { @MainActor in
                        if self.schemeHandlers[urlSchemeTask.hash] != nil {
                            urlSchemeTask.didReceive(response)
                            urlSchemeTask.didReceive(data)
                            urlSchemeTask.didFinish()
                            self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                        }
                    }()
                } else if let viewerHtmlPath = Self.viewerHTMLPath() {
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
                        self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                    }()
                }
            } else {
                await { @MainActor in
                    if self.schemeHandlers[urlSchemeTask.hash] != nil {
                        urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                        self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                    }
                }()
            }
        }
    }

    nonisolated private static func bundleURLFromWebURL(_ url: URL) -> URL? {
        guard url.path.hasPrefix("/load/viewer-assets/") else { return nil }
        let assetName = url.deletingPathExtension().lastPathComponent
        let assetExtension = url.lakePathExtension
        let assetDirectory = url.deletingLastPathComponent().path.deletingPrefix("/load/viewer-assets/")
        let resolvedURL = [
            assetDirectory,
            "Resources/\(assetDirectory)",
            "Resources/Resources/\(assetDirectory)",
        ].lazy.compactMap { subdirectory in
            Bundle.module.url(
                forResource: assetName,
                withExtension: assetExtension,
                subdirectory: subdirectory
            )
        }.first
        if resolvedURL == nil, ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" {
            logEbookAsset("# EBOOKASSET resolveMiss url=\(url.absoluteString) assetName=\(assetName) ext=\(assetExtension) dir=\(assetDirectory)")
        }
        return resolvedURL
    }

    nonisolated private static func viewerHTMLPath() -> String? {
        [
            "foliate-js",
            "Resources/foliate-js",
            "Resources/Resources/foliate-js",
        ].lazy.compactMap { directory in
            Bundle.module.path(forResource: "ebook-viewer", ofType: "html", inDirectory: directory)
        }.first
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
