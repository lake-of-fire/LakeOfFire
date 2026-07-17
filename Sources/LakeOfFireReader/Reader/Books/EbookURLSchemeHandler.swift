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

func ebookViewerAssetCacheHeaderFields() -> [String: String] {
    [
        "Cache-Control": "no-store, no-cache, must-revalidate",
        "Pragma": "no-cache",
        "Expires": "0",
    ]
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

fileprivate func ebookEntrySubpath(from url: URL) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first(where: { $0.name == "subpath" })?
        .value
}

func ebookURLSchemeTaskPriority(for url: URL) -> TaskPriority {
    guard url.path == "/processed-section" else {
        return .userInitiated
    }
    let isDirectForegroundSection = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .contains(where: { $0.name == "direct" && $0.value == "1" }) == true
    return isDirectForegroundSection ? .userInitiated : .utility
}

private enum EbookBase64URLByte {
    static let plus = UInt8(ascii: "+")
    static let hyphen = UInt8(ascii: "-")
    static let slash = UInt8(ascii: "/")
    static let underscore = UInt8(ascii: "_")
    static let equals = UInt8(ascii: "=")
}

fileprivate func ebookBase64URLToken(for string: String) -> String {
    var bytes = Array(Data(string.utf8).base64EncodedData())
    for index in bytes.indices {
        if bytes[index] == EbookBase64URLByte.plus {
            bytes[index] = EbookBase64URLByte.hyphen
        } else if bytes[index] == EbookBase64URLByte.slash {
            bytes[index] = EbookBase64URLByte.underscore
        }
    }
    while bytes.last == EbookBase64URLByte.equals {
        bytes.removeLast()
    }
    return String(decoding: bytes, as: UTF8.self)
}

fileprivate func ebookString(fromBase64URLToken token: String) -> String? {
    var bytes = Array(token.utf8)
    for index in bytes.indices {
        if bytes[index] == EbookBase64URLByte.hyphen {
            bytes[index] = EbookBase64URLByte.plus
        } else if bytes[index] == EbookBase64URLByte.underscore {
            bytes[index] = EbookBase64URLByte.slash
        }
    }
    let padding = (4 - bytes.count % 4) % 4
    if padding > 0 {
        bytes.append(contentsOf: repeatElement(EbookBase64URLByte.equals, count: padding))
    }
    guard let data = Data(base64Encoded: Data(bytes)) else { return nil }
    return String(data: data, encoding: .utf8)
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

struct EBookSectionProcessingRequestKey: Hashable, Sendable {
    let contentURLString: String
    let location: String
    let textFingerprint: String

    init(contentURL: URL, location: String, contentData: Data) {
        contentURLString = contentURL.absoluteString
        self.location = location
        textFingerprint = ebookProcessDataFingerprint(contentData)
    }
}

@inline(__always)
public func ebookProcessTextFingerprint(_ text: String) -> String {
    "\(text.utf8.count)-\(stableHash(text))"
}

@inline(__always)
public func ebookProcessDataFingerprint(_ data: Data) -> String {
    "\(data.count)-\(stableHash(data: data))"
}

fileprivate enum EBookSectionProcessingDeduperError: Error, Sendable, Equatable, LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

actor EBookSectionProcessingDeduper {
    private enum SectionProcessingOutcome: Sendable {
        case success(EbookProcessedSectionPayload)
        case cancelled
        case failure(String)
    }

    private var inFlightWaitersByKey: [EBookSectionProcessingRequestKey: [CheckedContinuation<SectionProcessingOutcome, Never>]] = [:]

    private func resolve(_ outcome: SectionProcessingOutcome) throws -> EbookProcessedSectionPayload {
        switch outcome {
        case .success(let payload):
            return payload
        case .cancelled:
            throw CancellationError()
        case .failure(let message):
            throw EBookSectionProcessingDeduperError.failed(message)
        }
    }

#if DEBUG
    func inFlightWaiterCountForTesting(key: EBookSectionProcessingRequestKey) -> Int {
        inFlightWaitersByKey[key]?.count ?? 0
    }
#endif

    func process(
        key: EBookSectionProcessingRequestKey,
        operation: @Sendable () async throws -> EbookProcessedSectionPayload
    ) async throws -> (payload: EbookProcessedSectionPayload, didCoalesce: Bool, cacheOutcome: String) {
        if inFlightWaitersByKey[key] != nil {
            let response = await withCheckedContinuation { continuation in
                inFlightWaitersByKey[key, default: []].append(continuation)
            }
            return (try resolve(response), true, "coalesced")
        }

        inFlightWaitersByKey[key] = []
        let response: SectionProcessingOutcome
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
    private let ebookProcessedTextCacheWriter: EbookProcessedTextCacheWriter?
    private let ebookTextProcessor: EbookTextProcessor?
    private let processReadabilityContent: EbookReadabilityContentProcessor?
    private let processHTMLDocument: EbookHTMLDocumentProcessor?
    private let processHTMLBytes: EbookHTMLBytesProcessor?
    private let processHTML: EbookHTMLProcessor?
    
    public init(
        ebookProcessedTextCacheWriter: EbookProcessedTextCacheWriter? = nil,
        ebookTextProcessor: EbookTextProcessor?,
        processReadabilityContent: EbookReadabilityContentProcessor?,
        processHTMLDocument: EbookHTMLDocumentProcessor?,
        processHTMLBytes: EbookHTMLBytesProcessor?,
        processHTML: EbookHTMLProcessor?
    ) {
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
        let processedPayload = try await process(
            contentURL: contentURL,
            location: sectionHref,
            text: entryText,
            contentFingerprint: ebookProcessDataFingerprint(entryData),
            isCacheWarmer: true
        )
        return EBookNativeSectionPrewarmResult(
            sectionHref: sectionHref,
            requestBytes: entryData.count,
            responseBytes: processedPayload.combinedByteCount
        )
    }
    
    public func process(
        contentURL: URL,
        location: String,
        text: String,
        contentFingerprint: String? = nil,
        isCacheWarmer: Bool
    ) async throws -> EbookProcessedSectionPayload {
        let resolvedContentFingerprint = contentFingerprint ?? ebookProcessTextFingerprint(text)
        guard let ebookTextProcessor else {
            return EbookProcessedSectionPayload(
                documentHTML: Data(text.utf8),
                segmentSidecar: Data()
            )
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
        if !isCacheWarmer, let ebookProcessedTextCacheWriter {
            // Publish to the foreground memory cache before returning the response.
            // The writer detaches its persisted write internally, so awaiting it here
            // prevents an immediate reload from racing an unstarted utility task
            // without putting disk I/O on the visible processing path.
            await ebookProcessedTextCacheWriter(contentURL, location, resolvedContentFingerprint, result)
        }
        return result
    }
}
    
fileprivate actor EbookViewerAssetCache {
    static let shared = EbookViewerAssetCache()

    private var dataByURL = [URL: Data]()

    func data(for fileURL: URL) throws -> Data {
        if let cached = dataByURL[fileURL] {
            return cached
        }
        // Callers provide Bundle.module URLs, so normalization only adds filesystem
        // metadata I/O before an otherwise in-memory cache hit.
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        dataByURL[fileURL] = data
        return data
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
            data = try await EbookViewerAssetCache.shared.data(
                for: URL(fileURLWithPath: viewerHtmlPath)
            )
        }
        let response = ebookHTTPResponse(
            url: originalURL,
            mimeType: "text/html",
            byteCount: data.count,
            textEncodingName: "utf-8",
            // Viewer URLs are stable across app updates. They cannot be
            // advertised as immutable until the resource revision is part of
            // the URL itself.
            additionalHeaderFields: ebookViewerAssetCacheHeaderFields()
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
public typealias EbookHTMLDocumentProcessor = @Sendable (SwiftSoup.Document, Bool) async throws -> EbookProcessedSectionPayload
public typealias EbookHTMLBytesProcessor = @Sendable ([UInt8], Bool) async -> [UInt8]
public typealias EbookHTMLProcessor = @Sendable (String, Bool) async -> String
public typealias EbookTextProcessor = @Sendable (URL, String, String, String?, Bool, EbookReadabilityContentProcessor?, EbookHTMLDocumentProcessor?, EbookHTMLBytesProcessor?, EbookHTMLProcessor?) async throws -> EbookProcessedSectionPayload
public typealias EbookProcessedTextCacheReader = @Sendable (URL, String, String) async throws -> EbookProcessedSectionPayload?
public typealias EbookProcessedTextCacheWriter = @Sendable (URL, String, String, EbookProcessedSectionPayload) async -> Void
public typealias EbookSectionPresentationProvider = @Sendable () async -> EbookSectionPresentation
public typealias SharedFontCSSBase64Provider = @Sendable () async -> String?

public final class EbookURLSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated(unsafe) var ebookProcessedTextCacheReader: EbookProcessedTextCacheReader?
    nonisolated(unsafe) var ebookProcessedTextCacheWriter: EbookProcessedTextCacheWriter?
    nonisolated(unsafe) var ebookTextProcessor: EbookTextProcessor?
    nonisolated(unsafe) var ebookSectionPresentationProvider: EbookSectionPresentationProvider?
    public var readerFileManager: ReaderFileManager?
    nonisolated(unsafe) var processReadabilityContent: EbookReadabilityContentProcessor?
    nonisolated(unsafe) var processHTMLDocument: EbookHTMLDocumentProcessor?
    nonisolated(unsafe) var processHTMLBytes: EbookHTMLBytesProcessor?
    nonisolated(unsafe) var processHTML: EbookHTMLProcessor?
    nonisolated(unsafe) public var sharedFontCSSBase64: String?
    nonisolated(unsafe) var sharedFontCSSBase64Provider: SharedFontCSSBase64Provider?
    nonisolated(unsafe) public var sharedReaderFontAsset: SharedReaderFontAsset?
    
    private var schemeHandlers: [Int: WKURLSchemeTask] = [:]
    private static let sharedSectionProcessingDeduper = EBookSectionProcessingDeduper()
    private let sectionProcessingDeduper = EbookURLSchemeHandler.sharedSectionProcessingDeduper
    
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
        if url.path.hasPrefix(ReaderExternalSegmentSidecarScheme.ebook.endpointPathPrefix) {
            guard let sidecar = readerExternalSegmentSidecarResponse(
                for: url,
                scheme: .ebook
            ) else {
                urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                return
            }
            urlSchemeTask.didReceive(sidecar.response)
            urlSchemeTask.didReceive(sidecar.data)
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
        let ebookSectionPresentationProvider = self.ebookSectionPresentationProvider
        let processReadabilityContent = self.processReadabilityContent
        let processHTMLDocument = self.processHTMLDocument
        let processHTMLBytes = self.processHTMLBytes
        let processHTML = self.processHTML
        let sharedFontCSSBase64 = self.sharedFontCSSBase64
        let sharedFontCSSBase64Provider = self.sharedFontCSSBase64Provider

        
        Task.detached(priority: ebookURLSchemeTaskPriority(for: url)) { @EbookURLSchemeActor [weak self] in
            guard let self else { return }
            if url.path == "/processed-section" {
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
                    async let sectionPresentation = ebookSectionPresentationProvider?()
                    let cachedSource = try await ReaderPackageEntrySourceCache.shared.cachedSource(
                        forPackageURL: mainDocumentURL,
                        readerFileManager: readerFileManager
                    )
                    let sourceReadyElapsedMs = Int(Date().timeIntervalSince(requestStartedAt) * 1000)
                    let sourceData = try cachedSource.source.readEntry(subpath: sectionHref)
                    let sourceReadElapsedMs = Int(Date().timeIntervalSince(requestStartedAt) * 1000) - sourceReadyElapsedMs
                    let didCoalesce: Bool
                    let cacheOutcome: String
                    let processRequestKey = EBookSectionProcessingRequestKey(
                        contentURL: mainDocumentURL,
                        location: sectionHref,
                        contentData: sourceData
                    )
                    let cacheProbeStartedAt = Date()
                    let cachedPayload: EbookProcessedSectionPayload?
                    let cacheProbeOutcome: String
                    if let ebookProcessedTextCacheReader {
                        do {
                            let candidate = try await ebookProcessedTextCacheReader(
                                mainDocumentURL,
                                sectionHref,
                                processRequestKey.textFingerprint
                            )
                            cachedPayload = candidate.flatMap {
                                ebookProcessedSectionPayloadHasDurableSegmentIdentities($0) ? $0 : nil
                            }
                            cacheProbeOutcome = cachedPayload == nil ? "miss" : "hit"
                        } catch {
                            cachedPayload = nil
                            cacheProbeOutcome = "error:\(String(describing: type(of: error)))"
                        }
                    } else {
                        cachedPayload = nil
                        cacheProbeOutcome = "unavailable"
                    }
                    let cacheProbeElapsedMs = Int(Date().timeIntervalSince(cacheProbeStartedAt) * 1000)
                    let processedPayload: EbookProcessedSectionPayload
                    if let ebookTextProcessor {
                        if let cachedPayload {
                            processedPayload = cachedPayload
                            didCoalesce = false
                            cacheOutcome = "final-direct-hit"
                        } else {
                            let sourceText = String(decoding: sourceData, as: UTF8.self)
                            let processedResult = try await self.sectionProcessingDeduper.process(
                                key: processRequestKey
                            ) {
                                let processingActor = EBookProcessingActor(
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
                            processedPayload = processedResult.payload
                            didCoalesce = processedResult.didCoalesce
                            cacheOutcome = processedResult.didCoalesce
                                ? "final-miss-coalesced"
                                : "final-miss-processed"
                        }
                    } else {
                        throw CustomSchemeHandlerError.fileNotFound
                    }

                    let processingElapsedMs = Int(Date().timeIntervalSince(requestStartedAt) * 1000)
                        - sourceReadyElapsedMs
                        - sourceReadElapsedMs
                    let sidecarPublishStartedAt = Date()
                    let publishedSidecar = publishingCanonicalReaderSegmentSidecar(
                        processedPayload,
                        scheme: .ebook
                    )
                    let sidecarPublishElapsedMs = Int(
                        Date().timeIntervalSince(sidecarPublishStartedAt) * 1000
                    )
                    let processedResponseByteCount = processedPayload.combinedByteCount
                    let writingHint = ebookProcessedSectionWritingHint(from: url)
                    let responseBodyAttributes = [
                        "data-mnb-native-cache-outcome": cacheOutcome,
                        "data-mnb-native-cache-probe-outcome": cacheProbeOutcome,
                        "data-mnb-native-cache-probe-ms": "\(cacheProbeElapsedMs)",
                        "data-mnb-native-cache-reader-available": ebookProcessedTextCacheReader == nil ? "false" : "true",
                        "data-mnb-native-cache-writer-available": ebookProcessedTextCacheWriter == nil ? "false" : "true",
                        "data-mnb-native-content-fingerprint": processRequestKey.textFingerprint,
                        "data-mnb-native-did-coalesce": didCoalesce ? "true" : "false",
                        "data-mnb-native-response-bytes": "\(processedResponseByteCount)",
                        "data-mnb-native-source-bytes": "\(sourceData.count)",
                        "data-mnb-native-source-ready-ms": "\(sourceReadyElapsedMs)",
                        "data-mnb-native-source-read-ms": "\(sourceReadElapsedMs)",
                        "data-mnb-native-processing-ms": "\(processingElapsedMs)",
                        "data-mnb-native-document-bytes": "\(publishedSidecar.documentHTML.count)",
                        "data-mnb-native-sidecar-bytes": "\(publishedSidecar.canonicalSidecarByteCount)",
                        "data-mnb-native-sidecar-delivery": publishedSidecar.endpointURL == nil ? "embedded-or-empty" : "external",
                        "data-mnb-native-sidecar-publish-ms": "\(sidecarPublishElapsedMs)",
                    ]
                    let responseDecorationStartedAt = Date()
                    let responseData = ebookHTMLDataWithInjectedResponseMetadata(
                        publishedSidecar.documentHTML,
                        baseURL: ebookProcessedSectionBaseURL(
                            contentURL: mainDocumentURL,
                            sectionHref: sectionHref
                        ),
                        writingHint: writingHint,
                        bodyAttributes: responseBodyAttributes,
                        presentation: await sectionPresentation,
                        additionalHeadMarkup: publishedSidecar.headDescriptor,
                        suppressesInitialPaginatorLayout: isDirectSectionLoad
                    )
                    let responseEncodeElapsedMs = Int(Date().timeIntervalSince(responseDecorationStartedAt) * 1000)
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
                            "X-Manabi-Response-Encode-Elapsed-Ms": "\(responseEncodeElapsedMs)",
                            "X-Manabi-Did-Coalesce": didCoalesce ? "true" : "false",
                            "X-Manabi-Sidecar-Delivery": publishedSidecar.endpointURL == nil ? "embedded-or-empty" : "external",
                            "X-Manabi-Sidecar-Bytes": "\(publishedSidecar.canonicalSidecarByteCount)",
                            "X-Manabi-Sidecar-Publish-Elapsed-Ms": "\(sidecarPublishElapsedMs)",
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
                    let response = ebookHTTPResponse(
                        url: url,
                        mimeType: "application/json",
                        byteCount: data.count,
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
                    let response = ebookHTTPResponse(
                        url: url,
                        mimeType: metadata.mimeType,
                        byteCount: data.count,
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
                    let response = ebookHTTPResponse(
                        url: url,
                        mimeType: mimeType,
                        byteCount: data.count,
                        textEncodingName: mimeType.hasPrefix("text/") ? "utf-8" : nil,
                        // Bundle asset URLs are not revisioned across app
                        // updates, so browser persistence must be disabled.
                        additionalHeaderFields: ebookViewerAssetCacheHeaderFields()
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
