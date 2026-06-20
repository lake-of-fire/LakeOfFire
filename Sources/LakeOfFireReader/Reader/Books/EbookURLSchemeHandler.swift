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

fileprivate func logEbookAsset(_ line: String) {
    Logger.shared.logger.info("\(line)")
}

fileprivate func ebookLoadLogValue(_ value: Any?) -> String {
    func truncated(_ string: String, limit: Int = 240) -> String {
        guard string.count > limit else { return string }
        return String(string.prefix(limit))
    }
    guard let value else { return "nil" }
    switch value {
    case let value as Bool:
        return value ? "true" : "false"
    case let value as Int:
        return "\(value)"
    case let value as UInt:
        return "\(value)"
    case let value as Double:
        return value.isFinite ? String(format: "%.0f", value) : "\(value)"
    case let value as Float:
        return value.isFinite ? String(format: "%.0f", Double(value)) : "\(value)"
    case let value as URL:
        return truncated(value.absoluteString.replacingOccurrences(of: "\n", with: " "))
    default:
        return truncated(String(describing: value).replacingOccurrences(of: "\n", with: " "))
    }
}

fileprivate func ebookLoadLog(_ event: String, _ payload: [String: Any?] = [:]) {
    guard shouldLogNativeEbookLoad(event: event, payload: payload) else { return }
    let details = payload
        .sorted { $0.key < $1.key }
        .map { "\($0.key)=\(ebookLoadLogValue($0.value))" }
        .joined(separator: " ")
    let line = details.isEmpty ? "# EBOOKLOAD swift.\(event)" : "# EBOOKLOAD swift.\(event) \(details)"
    print(line)
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

fileprivate let ebookLoadVerboseLoggingEnabled =
    ProcessInfo.processInfo.environment["MANABI_EPUBLOAD_VERBOSE_LOGS"] == "1"

fileprivate func shouldLogNativeEbookLoad(event: String, payload: [String: Any?]) -> Bool {
    if ebookLoadVerboseLoggingEnabled { return true }
    if event.localizedCaseInsensitiveContains("error") { return true }
    if (payload["isCacheWarmer"] ?? nil) as? Bool == true { return false }
    let subpath = (payload["entrySubpath"] ?? payload["subpath"] ?? nil) as? String
    let isCSSAsset = subpath.map { ($0 as NSString).pathExtension.lowercased() == "css" } == true
        || ((payload["mimeType"] ?? nil) as? String)?.lowercased().contains("css") == true
    if isCSSAsset,
       event == "scheme.start"
        || event == "entry.sourceCache.start"
        || event == "entry.sourceCache.finish"
        || event == "entry.read.start"
        || event == "entry.responseReady"
        || event == "scheme.didReceiveResponse.entry"
        || event == "scheme.didReceiveData.entry"
        || event == "scheme.finish.entry" {
        return true
    }
    if event == "processText.responseReady",
       let elapsedMs = (payload["responseReadyElapsedMs"] ?? nil) as? Int,
       elapsedMs >= 5_000 {
        return true
    }
    if (event == "scheme.deliver.processText.begin"
        || event == "scheme.didReceiveResponse.processText"
        || event == "scheme.didReceiveData.processText"
        || event == "scheme.finish.processText"),
       let elapsedMs = (payload["elapsedMs"] ?? nil) as? Int,
       elapsedMs >= 1_000 {
        return true
    }
    if (event == "entry.responseReady"
        || event == "scheme.finish.entry"
        || event == "entries.responseReady"
        || event == "scheme.finish.entries"),
       let elapsedMs = (payload["elapsedMs"] ?? nil) as? Int,
       elapsedMs >= 1_000 {
        return true
    }
    return false
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

fileprivate func shouldLogEbookEntry(
    subpath: String,
    mimeType: String? = nil,
    elapsedMs: Int? = nil,
    isError: Bool = false
) -> Bool {
    if isError { return true }
    if let elapsedMs, elapsedMs >= 1_000 { return true }
    let ext = (subpath as NSString).pathExtension.lowercased()
    if ["xhtml", "html", "htm", "xml", "opf", "ncx", "css", "js", "svg"].contains(ext) {
        return true
    }
    guard let mimeType = mimeType?.lowercased() else { return false }
    return mimeType.contains("html")
        || mimeType.contains("xml")
        || mimeType.contains("css")
        || mimeType.contains("javascript")
        || mimeType.contains("svg")
}

fileprivate let ebookReplaceTextDetailedLoggingEnabled =
    ProcessInfo.processInfo.environment["MANABI_REPLACETEXT_DETAILED_LOGS"] == "1"
fileprivate let ebookReplaceTextVerboseLoggingEnabled =
    ProcessInfo.processInfo.environment["MANABI_REPLACETEXT_VERBOSE_LOGS"] == "1"

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
fileprivate let ebookReplaceTextSlowSummaryThresholdMs = 5_000

@inline(__always)
fileprivate func shouldEmitEbookReplaceTextLifecycleLog(elapsedMs: Int? = nil, didCoalesce: Bool = false) -> Bool {
    if ebookReplaceTextDetailedLoggingEnabled || didCoalesce {
        return true
    }
    guard let elapsedMs else { return false }
    return elapsedMs >= ebookReplaceTextSlowSummaryThresholdMs
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
        let startedAt = Date()
        ebookLoadLog("processText.deduper.enter", [
            "location": key.location,
            "isCacheWarmer": key.isCacheWarmer,
            "fingerprint": key.textFingerprint,
            "activeKeys": inFlightWaitersByKey.count
        ])
        if let completedResponse = completedResponse(for: key) {
            ebookLoadLog("processText.deduper.completedCache.hit", [
                "location": key.location,
                "isCacheWarmer": key.isCacheWarmer,
                "fingerprint": key.textFingerprint,
                "responseBytes": completedResponse.utf8.count
            ])
            return (completedResponse, true, "completed-hit")
        }
        if inFlightWaitersByKey[key] != nil {
            let waiterCountBeforeAppend = inFlightWaitersByKey[key]?.count ?? 0
            ebookLoadLog("processText.deduper.coalesce", [
                "location": key.location,
                "isCacheWarmer": key.isCacheWarmer,
                "fingerprint": key.textFingerprint,
                "waitersBefore": waiterCountBeforeAppend
            ])
            if ebookReplaceTextVerboseLoggingEnabled {
            }
            let response = await withCheckedContinuation { continuation in
                inFlightWaitersByKey[key, default: []].append(continuation)
            }
            let joinElapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            ebookLoadLog("processText.deduper.coalesce.finish", [
                "location": key.location,
                "isCacheWarmer": key.isCacheWarmer,
                "fingerprint": key.textFingerprint,
                "elapsedMs": joinElapsedMs
            ])
            if shouldEmitEbookReplaceTextLifecycleLog(elapsedMs: joinElapsedMs, didCoalesce: true) {
            }
            return (try resolve(response), true, "coalesced")
        }

        inFlightWaitersByKey[key] = []
        ebookLoadLog("processText.deduper.owner.start", [
            "location": key.location,
            "isCacheWarmer": key.isCacheWarmer,
            "fingerprint": key.textFingerprint
        ])
        if ebookReplaceTextVerboseLoggingEnabled {
        }
        let response: ProcessTextOutcome
        do {
            response = .success(try await operation())
            ebookLoadLog("processText.deduper.owner.operation.finish", [
                "location": key.location,
                "isCacheWarmer": key.isCacheWarmer,
                "fingerprint": key.textFingerprint,
                "elapsedMs": Int(Date().timeIntervalSince(startedAt) * 1000)
            ])
        } catch is CancellationError {
            response = .cancelled
            ebookLoadLog("processText.deduper.owner.operation.cancelled", [
                "location": key.location,
                "isCacheWarmer": key.isCacheWarmer,
                "fingerprint": key.textFingerprint,
                "elapsedMs": Int(Date().timeIntervalSince(startedAt) * 1000)
            ])
        } catch {
            response = .failure(error.localizedDescription)
            ebookLoadLog("processText.deduper.owner.operation.error", [
                "location": key.location,
                "isCacheWarmer": key.isCacheWarmer,
                "fingerprint": key.textFingerprint,
                "elapsedMs": Int(Date().timeIntervalSince(startedAt) * 1000),
                "error": error.localizedDescription
            ])
        }
        let waiters = inFlightWaitersByKey.removeValue(forKey: key) ?? []
        let resolveElapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        ebookLoadLog("processText.deduper.owner.resolve", [
            "location": key.location,
            "isCacheWarmer": key.isCacheWarmer,
            "fingerprint": key.textFingerprint,
            "waiters": waiters.count,
            "elapsedMs": resolveElapsedMs
        ])
        if shouldEmitEbookReplaceTextLifecycleLog(elapsedMs: resolveElapsedMs, didCoalesce: !waiters.isEmpty) {
        }
        for waiter in waiters {
            waiter.resume(returning: response)
        }
        let resolvedResponse = try resolve(response)
        rememberCompletedResponse(resolvedResponse, for: key)
        return (resolvedResponse, false, "processed")
    }
}

public struct EBookNativeSectionPrewarmResult: Equatable {
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
        let startedAt = Date()
        let resolvedContentFingerprint = contentFingerprint ?? EBookProcessTextRequestKey(
            contentURL: contentURL,
            location: location,
            isCacheWarmer: isCacheWarmer,
            text: text
        ).textFingerprint
        ebookLoadLog("processText.actor.start", [
            "location": location,
            "contentURL": contentURL.absoluteString,
            "isCacheWarmer": isCacheWarmer,
            "requestChars": text.count
        ])
        if ebookReplaceTextVerboseLoggingEnabled {
        }
        if let ebookProcessedTextCacheReader {
            let cacheLookupStartedAt = Date()
            if let cachedResult = try await ebookProcessedTextCacheReader(contentURL, location, text, resolvedContentFingerprint) {
                ebookLoadLog("processText.actor.finalCache.hit", [
                    "location": location,
                    "contentURL": contentURL.absoluteString,
                    "isCacheWarmer": isCacheWarmer,
                    "responseChars": cachedResult.count,
                    "elapsedMs": Int(Date().timeIntervalSince(cacheLookupStartedAt) * 1000)
                ])
                return cachedResult
            }
        }
        guard let ebookTextProcessor else {
            ebookLoadLog("processText.actor.noProcessor", [
                "location": location,
                "isCacheWarmer": isCacheWarmer
            ])
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
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        ebookLoadLog("processText.actor.finish", [
            "location": location,
            "isCacheWarmer": isCacheWarmer,
            "responseChars": result.count,
            "elapsedMs": elapsedMs
        ])
        if shouldEmitEbookReplaceTextLifecycleLog(elapsedMs: elapsedMs) {
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

private func ebookReaderLoadDebugLog(_ message: String) {
    guard ProcessInfo.processInfo.environment["MANABI_READER_LOAD_DEBUG"] == "1" else { return }
    let line = "# READERLOAD stage=\(message)\n"
    print(line, terminator: "")
    guard let data = line.data(using: .utf8) else { return }
    let path = ProcessInfo.processInfo.environment["MANABI_READER_LOAD_DEBUG_PATH"] ?? "/tmp/manabi-reader-load.log"
    let url = URL(fileURLWithPath: path)
    if FileManager.default.fileExists(atPath: url.path),
       let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: url, options: .atomic)
    }
}

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
        ebookLoadLog("scheme.stop", [
            "requestID": urlSchemeTask.hash,
            "url": urlSchemeTask.request.url?.absoluteString,
            "path": urlSchemeTask.request.url?.path,
            "mainDocumentURL": urlSchemeTask.request.mainDocumentURL?.absoluteString,
            "wasActive": schemeHandlers[urlSchemeTask.hash] != nil
        ])
        schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
    }
    
    public func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        schemeHandlers[urlSchemeTask.hash] = urlSchemeTask
        
        guard let url = urlSchemeTask.request.url else { return }
        let requestID = EbookLoadRequestIDGenerator.next()
        let schemeRequestStartedAt = Date()
        let entrySubpath = ebookEntrySubpath(from: url)
        ebookLoadLog("scheme.start", [
            "requestID": requestID,
            "taskHash": urlSchemeTask.hash,
            "url": url.absoluteString,
            "path": url.path,
            "method": urlSchemeTask.request.httpMethod,
            "mainDocumentURL": urlSchemeTask.request.mainDocumentURL?.absoluteString,
            "entrySubpath": entrySubpath
        ])
        let shouldLogSchemeStart = url.path != "/entry"
            || entrySubpath.map { shouldLogEbookEntry(subpath: $0) } == true
        if shouldLogSchemeStart {
        }
        if ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" {
            let mainDocumentURL = urlSchemeTask.request.mainDocumentURL?.absoluteString ?? "nil"
            logEbookAsset("# EBOOKASSET start url=\(url.absoluteString) mainDocument=\(mainDocumentURL)")
        }
        let sharedReaderFontAsset = self.sharedReaderFontAsset
        if let fontResponse = sharedReaderFontResponse(
            for: url,
            asset: sharedReaderFontAsset
        ) {
            ebookLoadLog("scheme.finish.font", [
                "requestID": requestID,
                "url": url.absoluteString,
                "bytes": fontResponse.data.count,
                "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000)
            ])
            urlSchemeTask.didReceive(fontResponse.response)
            urlSchemeTask.didReceive(fontResponse.data)
            urlSchemeTask.didFinish()
            schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
            return
        }
        guard let readerFileManager else {
            print("Error: Missing ReaderFileManager in EbookURLSchemeHandler")
            ebookLoadLog("scheme.fail", [
                "requestID": requestID,
                "url": url.absoluteString,
                "reason": "missingReaderFileManager",
                "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000)
            ])
            ebookReaderLoadDebugLog("ebook.scheme.fail reason=missingReaderFileManager url=\(url.absoluteString)")
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
                    ebookLoadLog("processText.start", [
                        "requestID": requestID,
                        "location": replacedTextLocation,
                        "contentURL": contentURL.absoluteString,
                        "isCacheWarmer": isCacheWarmer,
                        "requestBytes": payload.count
                    ])
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
                                ebookLoadLog("scheme.finish.processText.directCache", [
                                    "requestID": requestID,
                                    "location": replacedTextLocation,
                                    "bytes": cachedData.count,
                                    "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000)
                                ])
                            }
                        }()
                        return
                    }
                    if let ebookTextProcessor {
                        let requestStartedAt = Date()
                        if ebookReplaceTextVerboseLoggingEnabled {
                        }
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
                            ebookLoadLog("processText.error", [
                                "requestID": requestID,
                                "location": replacedTextLocation,
                                "isCacheWarmer": isCacheWarmer,
                                "elapsedMs": Int(Date().timeIntervalSince(requestStartedAt) * 1000),
                                "error": error.localizedDescription
                            ])
                            await { @MainActor in
                                if self.schemeHandlers[urlSchemeTask.hash] != nil {
                                    ebookLoadLog("scheme.fail.processText", [
                                        "requestID": requestID,
                                        "location": replacedTextLocation,
                                        "active": true,
                                        "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000),
                                        "error": error.localizedDescription
                                    ])
                                    urlSchemeTask.didFailWithError(error)
                                    self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                                } else {
                                    ebookLoadLog("scheme.skipFail.processText", [
                                        "requestID": requestID,
                                        "location": replacedTextLocation,
                                        "active": false,
                                        "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000)
                                    ])
                                }
                            }()
                            return
                        }
                        let responseDataEncodeStartedAt = Date()
                        if let respData = ebookProcessTextResponseData(processedText: respText, isCacheWarmer: isCacheWarmer) {
                            let responseDataEncodeElapsedMs = Int(Date().timeIntervalSince(responseDataEncodeStartedAt) * 1000)
                            let responseReadyElapsedMs = Int(Date().timeIntervalSince(requestStartedAt) * 1000)
                            if shouldEmitEbookReplaceTextLifecycleLog(elapsedMs: responseReadyElapsedMs, didCoalesce: didCoalesce) {
                            }
                            ebookLoadLog("processText.responseReady", [
                                "requestID": requestID,
                                "location": replacedTextLocation,
                                "isCacheWarmer": isCacheWarmer,
                                "didCoalesce": didCoalesce,
                                "cacheOutcome": processTextCacheOutcome,
                                "responseBytes": respData.count,
                                "responseReadyElapsedMs": responseReadyElapsedMs,
                                "responseEncodeElapsedMs": responseDataEncodeElapsedMs
                            ])
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
                                    ebookLoadLog("scheme.deliver.processText.begin", [
                                        "requestID": requestID,
                                        "location": replacedTextLocation,
                                        "isCacheWarmer": isCacheWarmer,
                                        "bytes": respData.count,
                                        "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000)
                                    ])
                                    //                                    if !isCacheWarmer {
                                    //                                        print("# ebook proc text endpoint", replacedTextLocation, "receive...", respText)
                                    //                                    }
                                    urlSchemeTask.didReceive(resp)
                                    ebookLoadLog("scheme.didReceiveResponse.processText", [
                                        "requestID": requestID,
                                        "location": replacedTextLocation,
                                        "isCacheWarmer": isCacheWarmer,
                                        "bytes": respData.count,
                                        "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000),
                                        "deliveryElapsedMs": Int(Date().timeIntervalSince(deliveryStartedAt) * 1000)
                                    ])
                                    urlSchemeTask.didReceive(respData)
                                    ebookLoadLog("scheme.didReceiveData.processText", [
                                        "requestID": requestID,
                                        "location": replacedTextLocation,
                                        "isCacheWarmer": isCacheWarmer,
                                        "bytes": respData.count,
                                        "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000),
                                        "deliveryElapsedMs": Int(Date().timeIntervalSince(deliveryStartedAt) * 1000)
                                    ])
                                    urlSchemeTask.didFinish()
                                    self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                                    ebookLoadLog("scheme.finish.processText", [
                                        "requestID": requestID,
                                        "location": replacedTextLocation,
                                        "isCacheWarmer": isCacheWarmer,
                                        "bytes": respData.count,
                                        "active": true,
                                        "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000),
                                        "deliveryElapsedMs": Int(Date().timeIntervalSince(deliveryStartedAt) * 1000)
                                    ])
                                } else {
                                    ebookLoadLog("scheme.skipFinish.processText", [
                                        "requestID": requestID,
                                        "location": replacedTextLocation,
                                        "isCacheWarmer": isCacheWarmer,
                                        "bytes": respData.count,
                                        "active": false,
                                        "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000)
                                    ])
                                }
                            }()
                        }
                    } else if let respData = text.data(using: .utf8) {
                        ebookLoadLog("processText.noProcessorEcho", [
                            "requestID": requestID,
                            "location": replacedTextLocation,
                            "bytes": respData.count
                        ])
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
                                ebookLoadLog("scheme.finish.processText.echo", [
                                    "requestID": requestID,
                                    "location": replacedTextLocation,
                                    "bytes": respData.count,
                                    "active": true,
                                    "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000)
                                ])
                            } else {
                                ebookLoadLog("scheme.skipFinish.processText.echo", [
                                    "requestID": requestID,
                                    "location": replacedTextLocation,
                                    "bytes": respData.count,
                                    "active": false,
                                    "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000)
                                ])
                            }
                        }()
                    } else {
                        ebookLoadLog("processText.invalidBody", [
                            "requestID": requestID,
                            "payloadBytes": payload.count
                        ])
                        await { @MainActor in
                            if self.schemeHandlers[urlSchemeTask.hash] != nil {
                                ebookLoadLog("scheme.fail.processText.invalidBody", [
                                    "requestID": requestID,
                                    "active": true,
                                    "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000)
                                ])
                                urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                                self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                            }
                        }()
                    }
                } else {
                    ebookLoadLog("processText.invalidRequest", [
                        "requestID": requestID,
                        "method": urlSchemeTask.request.httpMethod,
                        "hasBody": ebookRequestBodyData(urlSchemeTask.request) != nil,
                        "location": urlSchemeTask.request.value(forHTTPHeaderField: "X-REPLACED-TEXT-LOCATION"),
                        "contentURL": urlSchemeTask.request.value(forHTTPHeaderField: "X-CONTENT-LOCATION")
                    ])
                    await { @MainActor in
                        if self.schemeHandlers[urlSchemeTask.hash] != nil {
                            ebookLoadLog("scheme.fail.processText.invalidRequest", [
                                "requestID": requestID,
                                "active": true,
                                "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000)
                            ])
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
                    ebookLoadLog("processedSection.invalidRequest", [
                        "requestID": requestID,
                        "url": url.absoluteString,
                        "mainDocumentURL": urlSchemeTask.request.mainDocumentURL?.absoluteString,
                        "sourceHeader": urlSchemeTask.request.value(forHTTPHeaderField: "X-Ebook-Source-URL")
                    ])
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
                    ebookLoadLog("processedSection.start", [
                        "requestID": requestID,
                        "location": sectionHref,
                        "contentURL": mainDocumentURL.absoluteString,
                        "sourceBytes": sourceData.count
                    ])

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
                        ebookLoadLog("processedSection.missingProcessor", [
                            "requestID": requestID,
                            "location": sectionHref,
                            "contentURL": mainDocumentURL.absoluteString
                        ])
                        throw CustomSchemeHandlerError.fileNotFound
                    }

                    let responseHTML = ebookHTMLWithInjectedBase(
                        responseText,
                        baseURL: ebookProcessedSectionBaseURL(contentURL: mainDocumentURL, sectionHref: sectionHref)
                    )
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
                            ebookLoadLog("scheme.finish.processedSection", [
                                "requestID": requestID,
                                "location": sectionHref,
                                "bytes": responseData.count,
                                "cacheOutcome": cacheOutcome,
                                "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000)
                            ])
                        }
                    }()
                } catch {
                    ebookLoadLog("processedSection.error", [
                        "requestID": requestID,
                        "location": sectionHref,
                        "contentURL": mainDocumentURL.absoluteString,
                        "elapsedMs": Int(Date().timeIntervalSince(requestStartedAt) * 1000),
                        "error": error.localizedDescription
                    ])
                    await { @MainActor in
                        if self.schemeHandlers[urlSchemeTask.hash] != nil {
                            urlSchemeTask.didFailWithError(error)
                            self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                        }
                    }()
                }
            } else if url.path == "/entries" {
                guard let mainDocumentURL = self.validatedMainDocumentURL(for: urlSchemeTask.request, route: "/entries") else {
                    ebookLoadLog("entries.invalidMainDocument", [
                        "requestID": requestID,
                        "url": url.absoluteString,
                        "mainDocumentURL": urlSchemeTask.request.mainDocumentURL?.absoluteString,
                        "sourceHeader": urlSchemeTask.request.value(forHTTPHeaderField: "X-Ebook-Source-URL")
                    ])
                    await { @MainActor in
                        urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                        self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                    }()
                    return
                }

                do {
                    ebookLoadLog("entries.sourceCache.start", [
                        "requestID": requestID,
                        "mainDocumentURL": mainDocumentURL.absoluteString
                    ])
                    let cachedSource = try await ReaderPackageEntrySourceCache.shared.cachedSource(
                        forPackageURL: mainDocumentURL,
                        readerFileManager: readerFileManager
                    )
                    let responseBody = EBookEntriesResponse(entries: cachedSource.entries)
                    let data = try JSONEncoder().encode(responseBody)
                    ebookLoadLog("entries.responseReady", [
                        "requestID": requestID,
                        "mainDocumentURL": mainDocumentURL.absoluteString,
                        "entryCount": cachedSource.entries.count,
                        "bytes": data.count,
                        "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000)
                    ])
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
                            ebookLoadLog("scheme.finish.entries", [
                                "requestID": requestID,
                                "entryCount": cachedSource.entries.count,
                                "bytes": data.count,
                                "active": true,
                                "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000)
                            ])
                        } else {
                            ebookLoadLog("scheme.skipFinish.entries", [
                                "requestID": requestID,
                                "entryCount": cachedSource.entries.count,
                                "bytes": data.count,
                                "active": false,
                                "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000)
                            ])
                        }
                    }()
                } catch {
                    ebookLoadLog("entries.error", [
                        "requestID": requestID,
                        "mainDocumentURL": mainDocumentURL.absoluteString,
                        "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000),
                        "error": error.localizedDescription
                    ])
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
                    ebookLoadLog("entry.invalidRequest", [
                        "requestID": requestID,
                        "url": url.absoluteString,
                        "mainDocumentURL": urlSchemeTask.request.mainDocumentURL?.absoluteString,
                        "sourceHeader": urlSchemeTask.request.value(forHTTPHeaderField: "X-Ebook-Source-URL")
                    ])
                    await { @MainActor in
                        urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                        self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                    }()
                    return
                }
                let mainDocumentURL = entryRequest.mainDocumentURL
                let subpath = entryRequest.subpath

                do {
                    let shouldLogEntryStart = shouldLogEbookEntry(subpath: subpath)
                    if shouldLogEntryStart {
                    }
                    ebookLoadLog("entry.sourceCache.start", [
                        "requestID": requestID,
                        "mainDocumentURL": mainDocumentURL.absoluteString,
                        "subpath": subpath
                    ])
                    let sourceCacheStartedAt = Date()
                    let cachedSource = try await ReaderPackageEntrySourceCache.shared.cachedSource(
                        forPackageURL: mainDocumentURL,
                        readerFileManager: readerFileManager
                    )
                    ebookLoadLog("entry.sourceCache.finish", [
                        "requestID": requestID,
                        "mainDocumentURL": mainDocumentURL.absoluteString,
                        "subpath": subpath,
                        "entryCount": cachedSource.entries.count,
                        "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000),
                        "sourceCacheElapsedMs": Int(Date().timeIntervalSince(sourceCacheStartedAt) * 1000)
                    ])
                    ebookLoadLog("entry.read.start", [
                        "requestID": requestID,
                        "subpath": subpath
                    ])
                    let data = try cachedSource.source.readEntry(subpath: subpath)
                    let metadata = try cachedSource.source.mimeType(subpath: subpath)
                    let elapsedMs = Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000)
                    if shouldLogEbookEntry(subpath: subpath, mimeType: metadata.mimeType, elapsedMs: elapsedMs) {
                    }
                    ebookLoadLog("entry.responseReady", [
                        "requestID": requestID,
                        "subpath": subpath,
                        "mimeType": metadata.mimeType,
                        "encoding": metadata.textEncodingName,
                        "bytes": data.count,
                        "elapsedMs": elapsedMs
                    ])
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
                            ebookLoadLog("scheme.didReceiveResponse.entry", [
                                "requestID": requestID,
                                "subpath": subpath,
                                "mimeType": metadata.mimeType,
                                "bytes": data.count,
                                "active": true,
                                "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000),
                                "sendElapsedMs": Int(Date().timeIntervalSince(sendStartedAt) * 1000)
                            ])
                            urlSchemeTask.didReceive(data)
                            ebookLoadLog("scheme.didReceiveData.entry", [
                                "requestID": requestID,
                                "subpath": subpath,
                                "mimeType": metadata.mimeType,
                                "bytes": data.count,
                                "active": true,
                                "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000),
                                "sendElapsedMs": Int(Date().timeIntervalSince(sendStartedAt) * 1000)
                            ])
                            urlSchemeTask.didFinish()
                            self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                            ebookLoadLog("scheme.finish.entry", [
                                "requestID": requestID,
                                "subpath": subpath,
                                "mimeType": metadata.mimeType,
                                "bytes": data.count,
                                "active": true,
                                "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000),
                                "sendElapsedMs": Int(Date().timeIntervalSince(sendStartedAt) * 1000)
                            ])
                        } else {
                            ebookLoadLog("scheme.skipFinish.entry", [
                                "requestID": requestID,
                                "subpath": subpath,
                                "mimeType": metadata.mimeType,
                                "bytes": data.count,
                                "active": false,
                                "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000)
                            ])
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
                                ebookLoadLog("scheme.finish.entry404", [
                                    "requestID": requestID,
                                    "subpath": subpath,
                                    "active": true,
                                    "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000)
                                ])
                            }
                        }()
                        return
                    }
                    ebookLoadLog("entry.error", [
                        "requestID": requestID,
                        "subpath": subpath,
                        "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000),
                        "error": error.localizedDescription
                    ])
                    await { @MainActor in
                        urlSchemeTask.didFailWithError(error)
                        self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                    }()
                }
            } else if url.pathComponents.starts(with: ["/", "load"]) {
                ebookLoadLog("load.start", [
                    "requestID": requestID,
                    "url": url.absoluteString,
                    "pathComponents": url.pathComponents.joined(separator: "|")
                ])
                ebookReaderLoadDebugLog("ebook.scheme.load.begin url=\(url.absoluteString) pathComponents=\(url.pathComponents.joined(separator: "|"))")
                // Bundle file.
                if let fileUrl = Self.bundleURLFromWebURL(url),
                   let mimeType = Self.mimeType(ofFileAtUrl: fileUrl),
                   let data = try? Data(contentsOf: fileUrl) {
                    ebookLoadLog("load.bundle.responseReady", [
                        "requestID": requestID,
                        "url": url.absoluteString,
                        "fileURL": fileUrl.absoluteString,
                        "mimeType": mimeType,
                        "bytes": data.count,
                        "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000)
                    ])
                    ebookReaderLoadDebugLog("ebook.scheme.load.bundleHit url=\(url.absoluteString) fileURL=\(fileUrl.absoluteString) bytes=\(data.count)")
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
                            ebookLoadLog("scheme.finish.load.bundle", [
                                "requestID": requestID,
                                "url": url.absoluteString,
                                "mimeType": mimeType,
                                "bytes": data.count,
                                "active": true,
                                "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000)
                            ])
                        } else {
                            ebookLoadLog("scheme.skipFinish.load.bundle", [
                                "requestID": requestID,
                                "url": url.absoluteString,
                                "mimeType": mimeType,
                                "bytes": data.count,
                                "active": false,
                                "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000)
                            ])
                        }
                    }()
                } else if let viewerHtmlPath = Self.viewerHTMLPath() {
                    ebookLoadLog("load.viewer.start", [
                        "requestID": requestID,
                        "url": url.absoluteString,
                        "viewerHtmlPath": viewerHtmlPath
                    ])
                    ebookReaderLoadDebugLog("ebook.scheme.load.viewerBegin url=\(url.absoluteString) viewerHtmlPath=\(viewerHtmlPath)")
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
                            ebookLoadLog("load.viewer.responseReady", [
                                "requestID": requestID,
                                "url": url.absoluteString,
                                "bytes": data.count,
                                "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000)
                            ])
                            await { @MainActor in
                                if self.schemeHandlers[urlSchemeTask.hash] != nil {
                                    urlSchemeTask.didReceive(response)
                                    urlSchemeTask.didReceive(data)
                                    urlSchemeTask.didFinish()
                                    self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                                    ebookLoadLog("scheme.finish.load.viewer", [
                                        "requestID": requestID,
                                        "url": url.absoluteString,
                                        "bytes": data.count,
                                        "active": true,
                                        "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000)
                                    ])
                                } else {
                                    ebookLoadLog("scheme.skipFinish.load.viewer", [
                                        "requestID": requestID,
                                        "url": url.absoluteString,
                                        "bytes": data.count,
                                        "active": false,
                                        "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000)
                                    ])
                                }
                            }()
                        } catch {
                            ebookLoadLog("load.viewer.error", [
                                "requestID": requestID,
                                "url": url.absoluteString,
                                "viewerHtmlPath": viewerHtmlPath,
                                "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000),
                                "error": error.localizedDescription
                            ])
                            ebookReaderLoadDebugLog("ebook.scheme.load.viewerError url=\(url.absoluteString) viewerHtmlPath=\(viewerHtmlPath) error=\(String(describing: error))")
                            await { @MainActor in
                                urlSchemeTask.didFailWithError(error)
                                self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                            }()
                        }
                } else {
                    ebookLoadLog("load.error", [
                        "requestID": requestID,
                        "url": url.absoluteString,
                        "reason": "missingViewerHTMLPath",
                        "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000)
                    ])
                    ebookReaderLoadDebugLog("ebook.scheme.fail reason=missingViewerHTMLPath url=\(url.absoluteString)")
                    await { @MainActor in
                        urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                        self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                    }()
                }
            } else {
                ebookLoadLog("scheme.fail.unhandledPath", [
                    "requestID": requestID,
                    "url": url.absoluteString,
                    "path": url.path,
                    "elapsedMs": Int(Date().timeIntervalSince(schemeRequestStartedAt) * 1000)
                ])
                ebookReaderLoadDebugLog("ebook.scheme.fail reason=unhandledPath url=\(url.absoluteString) path=\(url.path)")
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
