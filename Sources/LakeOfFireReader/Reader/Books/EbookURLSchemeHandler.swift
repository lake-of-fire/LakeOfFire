import SwiftUI
import LakeOfFireWeb
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireContent
import LakeOfFireCore
@preconcurrency import WebKit
import UniformTypeIdentifiers
import SwiftSoup
import SwiftUtilities
import LakeKit

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

fileprivate enum EbookLoadRequestIDGenerator {
    private static let lock = NSLock()
    private static var nextID: UInt64 = 0

    static func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        return String(nextID)
    }
}

fileprivate func ebookProcessTextSample(_ value: String, limit: Int = 80) -> String {
    guard value.count > limit else { return value }
    return String(value.prefix(limit))
}

fileprivate func ebookEntrySubpath(from url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first(where: { $0.name == "subpath" })?
        .value
}

fileprivate func ebookBase64URLToken(for string: String) -> String {
    Data(string.utf8)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

fileprivate func ebookString(fromBase64URLToken token: String) -> String? {
    var base64 = token
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let padding = (4 - base64.count % 4) % 4
    if padding > 0 {
        base64 += String(repeating: "=", count: padding)
    }
    guard let data = Data(base64Encoded: base64) else { return nil }
    return String(data: data, encoding: .utf8)
}

fileprivate func ebookHTMLAttributeEscaped(_ string: String) -> String {
    string
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

fileprivate func ebookDirectorySubpath(for sectionHref: String) -> String {
    guard let slashIndex = sectionHref.lastIndex(of: "/") else { return "" }
    return String(sectionHref[..<sectionHref.index(after: slashIndex)])
}

fileprivate func ebookPathEscaped(_ path: String) -> String {
    path
        .split(separator: "/", omittingEmptySubsequences: false)
        .map { component in
            String(component).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(component)
        }
        .joined(separator: "/")
}

fileprivate func ebookProcessedSectionBaseURL(contentURL: URL, sectionHref: String) -> String {
    let token = ebookBase64URLToken(for: contentURL.absoluteString)
    return "ebook://ebook/entry-source/\(token)/\(ebookPathEscaped(ebookDirectorySubpath(for: sectionHref)))"
}

fileprivate func ebookHTMLWithInjectedBase(_ html: String, baseURL: String) -> String {
    let baseTag = "<base href=\"\(ebookHTMLAttributeEscaped(baseURL))\">"
    if let headOpenRange = html.range(of: "<head", options: [.caseInsensitive]),
       let headOpenEnd = html[headOpenRange.lowerBound...].firstIndex(of: ">") {
        var result = html
        result.insert(contentsOf: baseTag, at: html.index(after: headOpenEnd))
        return result
    }
    if let htmlOpenRange = html.range(of: "<html", options: [.caseInsensitive]),
       let htmlOpenEnd = html[htmlOpenRange.lowerBound...].firstIndex(of: ">") {
        var result = html
        result.insert(contentsOf: "<head>\(baseTag)</head>", at: html.index(after: htmlOpenEnd))
        return result
    }
    return "<!doctype html><html><head>\(baseTag)</head><body>\(html)</body></html>"
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
        "data-mnb-writing-direction=\"\(writingHint.direction)\"",
        "data-mnb-writing-mode=\"\(writingHint.writingMode)\"",
        "data-mnb-foliate-writing-direction=\"\(writingHint.direction)\"",
        "data-mnb-foliate-writing-mode=\"\(writingHint.writingMode)\""
    ].joined(separator: " ")

    var result = html
    result.insert(contentsOf: " \(attributes)", at: tagEnd)
    return result
}
func ebookProcessTextResponseData(processedText: String, isCacheWarmer: Bool) -> Data? {
    if isCacheWarmer {
        return Data()
    }
    return processedText.data(using: .utf8)
}

fileprivate struct EBookProcessTextRequestKey: Hashable {
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

    static func == (lhs: EBookProcessTextRequestKey, rhs: EBookProcessTextRequestKey) -> Bool {
        // Warmers and foreground loads produce the same transformed HTML; only the URL response body differs.
        lhs.contentURLString == rhs.contentURLString
            && lhs.location == rhs.location
            && lhs.textFingerprint == rhs.textFingerprint
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(contentURLString)
        hasher.combine(location)
        hasher.combine(textFingerprint)
    }
}

fileprivate enum EBookProcessTextRequestDeduperError: Error, Sendable, Equatable, LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

fileprivate actor EBookProcessTextRequestDeduper {
    private enum ProcessTextOutcome: Sendable {
        case success(String)
        case cancelled
        case failure(String)
    }

    private struct CompletedResponse {
        let responseText: String
        let byteCount: Int
    }

    private let completedResponseByteLimit = 48 * 1024 * 1024
    private var inFlightWaitersByKey: [EBookProcessTextRequestKey: [CheckedContinuation<ProcessTextOutcome, Never>]] = [:]
    private var completedResponsesByKey: [EBookProcessTextRequestKey: CompletedResponse] = [:]
    private var completedResponseKeysInAccessOrder: [EBookProcessTextRequestKey] = []
    private var completedResponseByteCount = 0

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

    private func rememberCompletedResponse(_ responseText: String, for key: EBookProcessTextRequestKey) {
        guard !key.isCacheWarmer else { return }
        let byteCount = responseText.utf8.count
        guard byteCount > 0, byteCount <= completedResponseByteLimit else { return }
        if let existing = completedResponsesByKey[key] {
            completedResponseByteCount -= existing.byteCount
            completedResponseKeysInAccessOrder.removeAll { $0 == key }
        }
        completedResponsesByKey[key] = CompletedResponse(responseText: responseText, byteCount: byteCount)
        completedResponseKeysInAccessOrder.append(key)
        completedResponseByteCount += byteCount
        while completedResponseByteCount > completedResponseByteLimit,
              let oldestKey = completedResponseKeysInAccessOrder.first {
            completedResponseKeysInAccessOrder.removeFirst()
            if let removed = completedResponsesByKey.removeValue(forKey: oldestKey) {
                completedResponseByteCount -= removed.byteCount
            }
        }
    }

    private func completedResponse(for key: EBookProcessTextRequestKey) -> String? {
        guard !key.isCacheWarmer, let completed = completedResponsesByKey[key] else { return nil }
        completedResponseKeysInAccessOrder.removeAll { $0 == key }
        completedResponseKeysInAccessOrder.append(key)
        return completed.responseText
    }

    func process(
        key: EBookProcessTextRequestKey,
        operation: @Sendable () async throws -> String
    ) async throws -> (responseText: String, didCoalesce: Bool, cacheOutcome: String) {
        if let completedResponse = completedResponse(for: key) {
            return (completedResponse, true, "completed-hit")
        }
        if inFlightWaitersByKey[key] != nil {
            let response = await withCheckedContinuation { continuation in
                inFlightWaitersByKey[key, default: []].append(continuation)
            }
            return (try resolve(response), true, "coalesced")
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
        rememberCompletedResponse(resolvedResponse, for: key)
        return (resolvedResponse, false, "processed")
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

public actor EBookProcessingActor {
    private let ebookTextProcessorCacheHits: EbookTextProcessorCacheHitsHandler?
    private let ebookProcessedTextCacheReader: EbookProcessedTextCacheReader?
    private let ebookProcessedTextCacheWriter: EbookProcessedTextCacheWriter?
    private let ebookTextProcessor: EbookTextProcessor?
    private let processReadabilityContent: EbookReadabilityContentProcessor?
    private let processHTMLDocument: EbookHTMLDocumentProcessor?
    private let processHTMLBytes: EbookHTMLBytesProcessor?
    private let processHTML: EbookHTMLProcessor?
    
    public init(
        ebookTextProcessorCacheHits: EbookTextProcessorCacheHitsHandler?,
        ebookProcessedTextCacheReader: EbookProcessedTextCacheReader? = nil,
        ebookProcessedTextCacheWriter: EbookProcessedTextCacheWriter? = nil,
        ebookTextProcessor: EbookTextProcessor?,
        processReadabilityContent: EbookReadabilityContentProcessor?,
        processHTMLDocument: EbookHTMLDocumentProcessor?,
        processHTMLBytes: EbookHTMLBytesProcessor?,
        processHTML: EbookHTMLProcessor?
    ) {
        self.ebookTextProcessorCacheHits = ebookTextProcessorCacheHits
        self.ebookProcessedTextCacheReader = ebookProcessedTextCacheReader
        self.ebookProcessedTextCacheWriter = ebookProcessedTextCacheWriter
        self.ebookTextProcessor = ebookTextProcessor
        self.processReadabilityContent = processReadabilityContent
        self.processHTMLDocument = processHTMLDocument
        self.processHTMLBytes = processHTMLBytes
        self.processHTML = processHTML
    }

    public func prewarm(
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
            contentFingerprint: EBookProcessTextRequestKey(
                contentURL: contentURL,
                location: sectionHref,
                isCacheWarmer: true,
                text: entryText
            ).textFingerprint,
            isCacheWarmer: true
        )
        return EBookNativeSectionPrewarmResult(
            sectionHref: sectionHref,
            requestBytes: entryData.count,
            responseBytes: processedText.utf8.count
        )
    }
    
    public func process(
        contentURL: URL,
        location: String,
        text: String,
        contentFingerprint: String? = nil,
        isCacheWarmer: Bool
    ) async throws -> String {
        let resolvedContentFingerprint = contentFingerprint ?? EBookProcessTextRequestKey(
            contentURL: contentURL,
            location: location,
            isCacheWarmer: isCacheWarmer,
            text: text
        ).textFingerprint
        if let ebookProcessedTextCacheReader {
            if let cachedResult = try await ebookProcessedTextCacheReader(contentURL, location, text, resolvedContentFingerprint) {
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
        if let ebookProcessedTextCacheWriter {
            if isCacheWarmer {
                await ebookProcessedTextCacheWriter(contentURL, location, text, resolvedContentFingerprint, result)
            } else {
                Task(priority: .utility) {
                    await ebookProcessedTextCacheWriter(contentURL, location, text, resolvedContentFingerprint, result)
                }
            }
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
        sharedFontCSSBase64Provider _: (() async -> String?)?
    ) async throws -> (HTTPURLResponse, Data) {
        var html = try String(contentsOfFile: viewerHtmlPath)
        let shouldEnablePageTurnInteractionDiagnostic =
            ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1"

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
public typealias EbookReadabilityContentProcessor = @Sendable (String, URL, URL?, Bool, Bool, String?, EbookDocumentTransform) async throws -> SwiftSoup.Document
public typealias EbookHTMLDocumentProcessor = @Sendable (SwiftSoup.Document, Bool) async throws -> [UInt8]
public typealias EbookHTMLBytesProcessor = @Sendable ([UInt8], Bool) async -> [UInt8]
public typealias EbookHTMLProcessor = @Sendable (String, Bool) async -> String
public typealias EbookTextProcessor = @Sendable (URL, String, String, String?, Bool, EbookReadabilityContentProcessor?, EbookHTMLDocumentProcessor?, EbookHTMLBytesProcessor?, EbookHTMLProcessor?) async throws -> String
public typealias EbookTextProcessorCacheHitsHandler = @Sendable (URL, String) async throws -> Bool
public typealias EbookProcessedTextCacheReader = @Sendable (URL, String, String, String?) async throws -> String?
public typealias EbookProcessedTextCacheWriter = @Sendable (URL, String, String, String?, String) async -> Void
public typealias SharedFontCSSBase64Provider = @Sendable () async -> String?

public final class EbookURLSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated(unsafe) var ebookTextProcessorCacheHits: EbookTextProcessorCacheHitsHandler?
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
    private static let sharedProcessTextRequestDeduper = EBookProcessTextRequestDeduper()
    private let processTextRequestDeduper = EbookURLSchemeHandler.sharedProcessTextRequestDeduper
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
        let requestID = EbookLoadRequestIDGenerator.next()
        let schemeRequestStartedAt = Date()
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
        let ebookTextProcessorCacheHits = self.ebookTextProcessorCacheHits
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
                    let isCacheWarmer = urlSchemeTask.request.value(forHTTPHeaderField: "X-IS-CACHE-WARMER") == "true"
                    let processRequestKey = EBookProcessTextRequestKey(
                        contentURL: contentURL,
                        location: replacedTextLocation,
                        isCacheWarmer: isCacheWarmer,
                        text: text
                    )
                    if !isCacheWarmer,
                       let ebookProcessedTextCacheReader,
                       let cachedText = try? await ebookProcessedTextCacheReader(contentURL, replacedTextLocation, text, processRequestKey.textFingerprint),
                       let cachedData = ebookProcessTextResponseData(processedText: cachedText, isCacheWarmer: false) {
                        let responseReadyElapsedMs = Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000)
                        let resp = HTTPURLResponse(
                            url: url,
                            statusCode: 200,
                            httpVersion: nil,
                            headerFields: [
                                "Content-Type": "text/plain; charset=utf-8",
                                "Content-Length": "\(cachedData.count)",
                                "X-Manabi-Process-Cache": "processed-direct-hit",
                                "X-Manabi-Response-Ready-Elapsed-Ms": "\(responseReadyElapsedMs)",
                                "X-Manabi-Response-Encode-Elapsed-Ms": "0",
                                "X-Manabi-Did-Coalesce": "false"
                            ]
                        ) ?? HTTPURLResponse(
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
                    if let ebookTextProcessor {
                        let requestStartedAt = Date()
                        let respText: String
                        let didCoalesce: Bool
                        let processTextCacheOutcome: String
                        do {
                            (respText, didCoalesce, processTextCacheOutcome) = try await self.processTextRequestDeduper.process(
                                key: processRequestKey
                            ) {
                                let processingActor = EBookProcessingActor(
                                    ebookTextProcessorCacheHits: ebookTextProcessorCacheHits,
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
                                    isCacheWarmer: isCacheWarmer
                                )
                            }
                        } catch {
                            await { @MainActor in
                                if self.schemeHandlers[urlSchemeTask.hash] != nil {
                                    urlSchemeTask.didFailWithError(error)
                                    self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                                } else {
                                }
                            }()
                            return
                        }
                        let responseDataEncodeStartedAt = Date()
                        if let respData = ebookProcessTextResponseData(processedText: respText, isCacheWarmer: isCacheWarmer) {
                            let responseDataEncodeElapsedMs = Int(Date().timeIntervalSince(responseDataEncodeStartedAt) * 1000)
                            let responseReadyElapsedMs = Int(Date().timeIntervalSince(requestStartedAt) * 1000)
                            let httpResponseBuildStartedAt = Date()
                            let resp = HTTPURLResponse(
                                url: url,
                                statusCode: 200,
                                httpVersion: nil,
                                headerFields: [
                                    "Content-Type": "text/plain; charset=utf-8",
                                    "Content-Length": "\(respData.count)",
                                    "X-Manabi-Process-Cache": processTextCacheOutcome,
                                    "X-Manabi-Response-Ready-Elapsed-Ms": "\(responseReadyElapsedMs)",
                                    "X-Manabi-Response-Encode-Elapsed-Ms": "\(responseDataEncodeElapsedMs)",
                                    "X-Manabi-Did-Coalesce": didCoalesce ? "true" : "false"
                                ]
                            ) ?? HTTPURLResponse(
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
                                    let deliveryStartedAt = Date()
                                    //                                    if !isCacheWarmer {
                                    //                                        print("# ebook proc text endpoint", replacedTextLocation, "receive...", respText)
                                    //                                    }
                                    urlSchemeTask.didReceive(resp)
                                    urlSchemeTask.didReceive(respData)
                                    urlSchemeTask.didFinish()
                                    self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                                } else {
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
                            } else {
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
            } else if url.path == "/processed-section" {
                guard let mainDocumentURL = self.validatedMainDocumentURL(for: urlSchemeTask.request, route: "/processed-section"),
                      let sectionHref = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "subpath" })?
                    .value,
                      !sectionHref.isEmpty else {
                    await { @MainActor in
                        if self.schemeHandlers[urlSchemeTask.hash] != nil {
                            urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                            self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                        }
                    }()
                    return
                }

                let requestStartedAt = Date()
                do {
                    let isDirectSectionLoad = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?
                        .contains(where: { $0.name == "direct" && $0.value == "1" }) == true
                    let cachedSource = try await ReaderPackageEntrySourceCache.shared.cachedSource(
                        forPackageURL: mainDocumentURL,
                        readerFileManager: readerFileManager
                    )
                    let sourceData = try cachedSource.source.readEntry(subpath: sectionHref)
                    let sourceText = String(decoding: sourceData, as: UTF8.self)

                    let responseText: String
                    let didCoalesce: Bool
                    let cacheOutcome: String
                    if let ebookTextProcessor {
                        let processRequestKey = EBookProcessTextRequestKey(
                            contentURL: mainDocumentURL,
                            location: sectionHref,
                            isCacheWarmer: false,
                            text: sourceText
                        )
                        if let ebookProcessedTextCacheReader,
                           let cachedText = try await ebookProcessedTextCacheReader(
                            mainDocumentURL,
                            sectionHref,
                            sourceText,
                            processRequestKey.textFingerprint
                           ) {
                            responseText = cachedText
                            didCoalesce = false
                            cacheOutcome = "processed-direct-hit"
                        } else {
                            (responseText, didCoalesce, cacheOutcome) = try await self.processTextRequestDeduper.process(
                                key: processRequestKey
                            ) {
                                let processingActor = EBookProcessingActor(
                                    ebookTextProcessorCacheHits: ebookTextProcessorCacheHits,
                                    ebookProcessedTextCacheReader: ebookProcessedTextCacheReader,
                                    ebookProcessedTextCacheWriter: ebookProcessedTextCacheWriter,
                                    ebookTextProcessor: ebookTextProcessor,
                                    processReadabilityContent: processReadabilityContent,
                                    processHTMLDocument: processHTMLDocument,
                                    processHTMLBytes: processHTMLBytes,
                                    processHTML: processHTML
                                )
                                return try await processingActor.process(
                                    contentURL: mainDocumentURL,
                                    location: sectionHref,
                                    text: sourceText,
                                    contentFingerprint: processRequestKey.textFingerprint,
                                    isCacheWarmer: false
                                )
                            }
                        }
                    } else {
                        throw CustomSchemeHandlerError.fileNotFound
                    }

                    let writingHint = ebookProcessedSectionWritingHint(from: url)
                    let responseHTML = ebookHTMLWithInjectedPresentationHints(
                        ebookHTMLWithInjectedBase(
                            responseText,
                            baseURL: ebookProcessedSectionBaseURL(contentURL: mainDocumentURL, sectionHref: sectionHref)
                        ),
                        writingHint: writingHint
                    )
                    if let writingHint {
                    }
                    guard let responseData = ebookProcessTextResponseData(processedText: responseHTML, isCacheWarmer: false) else {
                        throw CustomSchemeHandlerError.fileNotFound
                    }
                    let responseReadyElapsedMs = Int(Date().timeIntervalSince(requestStartedAt) * 1000)
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: [
                            "Content-Type": isDirectSectionLoad ? "text/html; charset=utf-8" : "text/plain; charset=utf-8",
                            "Content-Length": "\(responseData.count)",
                            "X-Manabi-Process-Cache": cacheOutcome,
                            "X-Manabi-Response-Ready-Elapsed-Ms": "\(responseReadyElapsedMs)",
                            "X-Manabi-Response-Encode-Elapsed-Ms": "0",
                            "X-Manabi-Did-Coalesce": didCoalesce ? "true" : "false"
                        ]
                    ) ?? HTTPURLResponse(
                        url: url,
                        mimeType: nil,
                        expectedContentLength: responseData.count,
                        textEncodingName: "utf-8"
                    )
                    await { @MainActor in
                        if self.schemeHandlers[urlSchemeTask.hash] != nil {
                            urlSchemeTask.didReceive(response)
                            urlSchemeTask.didReceive(responseData)
                            urlSchemeTask.didFinish()
                            self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                        }
                    }()
                } catch {
                    await { @MainActor in
                        if self.schemeHandlers[urlSchemeTask.hash] != nil {
                            urlSchemeTask.didFailWithError(error)
                            self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                        }
                    }()
                }
            } else if url.path == "/entries" {
                guard let mainDocumentURL = self.validatedMainDocumentURL(for: urlSchemeTask.request, route: "/entries") else {
                    await { @MainActor in
                        urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                        self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
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
                        } else {
                        }
                    }()
                } catch {
                    await { @MainActor in
                        urlSchemeTask.didFailWithError(error)
                        self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                    }()
                }
            } else if url.path == "/entry" || url.path.hasPrefix("/entry-source/") {
                let entrySourcePathPrefix = "/entry-source/"
                let pathBackedEntry: (mainDocumentURL: URL, subpath: String)? = {
                    guard url.path.hasPrefix(entrySourcePathPrefix) else { return nil }
                    let path = String(url.path.dropFirst(entrySourcePathPrefix.count))
                    guard let tokenEnd = path.firstIndex(of: "/") else { return nil }
                    let token = String(path[..<tokenEnd])
                    let rawSubpath = String(path[path.index(after: tokenEnd)...])
                    guard let sourceURLString = ebookString(fromBase64URLToken: token),
                          let mainDocumentURL = URL(string: sourceURLString),
                          mainDocumentURL.scheme == "ebook",
                          mainDocumentURL.host == "ebook",
                          mainDocumentURL.pathComponents.starts(with: ["/", "load"]) else {
                        return nil
                    }
                    return (mainDocumentURL, rawSubpath.removingPercentEncoding ?? rawSubpath)
                }()
                guard let entryRequest = pathBackedEntry ?? {
                    guard let mainDocumentURL = self.validatedMainDocumentURL(for: urlSchemeTask.request, route: "/entry"),
                          let subpath = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?
                        .first(where: { $0.name == "subpath" })?
                        .value else {
                        return nil
                    }
                    return (mainDocumentURL, subpath)
                }() else {
                    await { @MainActor in
                        urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                        self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                    }()
                    return
                }
                let mainDocumentURL = entryRequest.mainDocumentURL
                let subpath = entryRequest.subpath

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
                            let sendStartedAt = Date()
                            urlSchemeTask.didReceive(response)
                            urlSchemeTask.didReceive(data)
                            urlSchemeTask.didFinish()
                            self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                        } else {
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
                        } else {
                        }
                    }()
                } else if let viewerHtmlPath = Self.viewerHTMLPath() {
                    // File viewer bundle file.
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
                                } else {
                                }
                            }()
                        } catch {
                            await { @MainActor in
                                urlSchemeTask.didFailWithError(error)
                                self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                            }()
                        }
                } else {
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
            return nil
        }
        guard mainDocumentURL.scheme == "ebook",
              mainDocumentURL.host == "ebook",
              mainDocumentURL.pathComponents.starts(with: ["/", "load"]) else {
            return nil
        }
        if !hasLoggedValidatedMainDocumentURL {
            hasLoggedValidatedMainDocumentURL = true
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
