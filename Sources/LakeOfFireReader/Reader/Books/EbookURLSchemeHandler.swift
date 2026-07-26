import SwiftUI
@preconcurrency import WebKit
import CryptoKit
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

private enum EbookBase64URLByte {
    static let plus = UInt8(ascii: "+")
    static let hyphen = UInt8(ascii: "-")
    static let slash = UInt8(ascii: "/")
    static let underscore = UInt8(ascii: "_")
    static let equals = UInt8(ascii: "=")
}

func ebookBase64URLToken(for string: String) -> String {
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

func ebookString(fromBase64URLToken token: String) -> String? {
    var bytes = Array(token.utf8)
    for index in bytes.indices {
        if bytes[index] == EbookBase64URLByte.hyphen {
            bytes[index] = EbookBase64URLByte.plus
        } else if bytes[index] == EbookBase64URLByte.underscore {
            bytes[index] = EbookBase64URLByte.slash
        }
    }
    bytes.append(contentsOf: repeatElement(EbookBase64URLByte.equals, count: (4 - bytes.count % 4) % 4))
    guard let data = Data(base64Encoded: Data(bytes)) else { return nil }
    return String(data: data, encoding: .utf8)
}

func normalizedEbookEntrySubpath(_ rawSubpath: String) -> String? {
    guard !rawSubpath.isEmpty,
          !rawSubpath.hasPrefix("/"),
          !rawSubpath.contains("\\"),
          !rawSubpath.contains("\0") else {
        return nil
    }
    let components = rawSubpath.split(separator: "/", omittingEmptySubsequences: false)
    guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
        return nil
    }
    return components.joined(separator: "/")
}

struct EbookDirectSectionRequest: Equatable, Sendable {
    let sourceURL: URL
    let subpath: String
}

func ebookDirectSectionRequest(from url: URL) -> EbookDirectSectionRequest? {
    guard url.path == "/processed-section",
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return nil
    }
    let sourceValues = components.queryItems?.filter { $0.name == "sourceURL" }.compactMap(\.value) ?? []
    let subpathValues = components.queryItems?.filter { $0.name == "subpath" }.compactMap(\.value) ?? []
    guard sourceValues.count == 1,
          subpathValues.count == 1,
          let sourceURL = URL(string: sourceValues[0]),
          sourceURL.scheme == "ebook",
          sourceURL.host == "ebook",
          sourceURL.pathComponents.starts(with: ["/", "load"]),
          let subpath = normalizedEbookEntrySubpath(subpathValues[0]) else {
        return nil
    }
    return EbookDirectSectionRequest(sourceURL: sourceURL, subpath: subpath)
}

struct EbookPathBackedEntryRequest: Equatable, Sendable {
    let sourceURL: URL
    let generationID: String?
    let subpath: String
}

func ebookPathBackedEntryRequest(from url: URL, mainDocumentURL: URL?) -> EbookPathBackedEntryRequest? {
    let prefix = "/entry-source/"
    guard url.path.hasPrefix(prefix) else { return nil }
    let path = String(url.path.dropFirst(prefix.count))
    guard let separator = path.firstIndex(of: "/") else { return nil }
    let token = String(path[..<separator])
    let generationAndSubpath = String(path[path.index(after: separator)...])
    guard let generationSeparator = generationAndSubpath.firstIndex(of: "/") else {
        return nil
    }
    let generationID = String(generationAndSubpath[..<generationSeparator])
    let rawSubpath = String(generationAndSubpath[generationAndSubpath.index(after: generationSeparator)...])
    let generationDigest = generationID.dropFirst(3)
    guard let sourceURLString = ebookString(fromBase64URLToken: token),
          let sourceURL = URL(string: sourceURLString),
          sourceURL.scheme == "ebook",
          sourceURL.host == "ebook",
          sourceURL.pathComponents.starts(with: ["/", "load"]),
          generationID.hasPrefix("g1-"),
          generationDigest.utf8.count == 64,
          generationDigest.allSatisfy({
              $0.isASCII && ($0.isNumber || ("a"..."f").contains($0))
          }),
          let subpath = normalizedEbookEntrySubpath(rawSubpath.removingPercentEncoding ?? rawSubpath) else {
        return nil
    }
    guard let mainDocumentURL,
          let owner = ebookDirectSectionRequest(from: mainDocumentURL),
          owner.sourceURL == sourceURL else {
        return nil
    }
    return EbookPathBackedEntryRequest(
        sourceURL: sourceURL,
        generationID: generationID,
        subpath: subpath
    )
}

private func ebookDirectorySubpath(for sectionHref: String) -> String {
    guard let slashIndex = sectionHref.lastIndex(of: "/") else { return "" }
    return String(sectionHref[..<sectionHref.index(after: slashIndex)])
}

private func ebookPathEscaped(_ path: String) -> String {
    path.split(separator: "/", omittingEmptySubsequences: false)
        .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
        .joined(separator: "/")
}

func ebookProcessedSectionBaseURL(
    sourceURL: URL,
    sectionHref: String,
    generationID: String
) -> String {
    let token = ebookBase64URLToken(for: sourceURL.absoluteString)
    return [
        "ebook://ebook/entry-source/",
        token,
        "/",
        generationID,
        "/",
        ebookPathEscaped(ebookDirectorySubpath(for: sectionHref)),
    ].joined()
}

func ebookURLSchemeTaskPriority(for url: URL) -> TaskPriority {
    guard url.path == "/processed-section" else { return .userInitiated }
    guard let directItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter({
        $0.name == "direct"
    }), directItems.count == 1, directItems[0].value == "1" else {
        return .utility
    }
    return .userInitiated
}

fileprivate func logEbookAsset(_ line: String) {
    Logger.shared.logger.info("\(line)")
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

func missingEbookViewerAssetResponse(for url: URL) -> HTTPURLResponse? {
    guard url.path.hasPrefix("/load/viewer-assets/") else { return nil }
    return HTTPURLResponse(
        url: url,
        statusCode: 404,
        httpVersion: nil,
        headerFields: ["Cache-Control": "no-store"]
    )
}

let ebookViewerAssetCacheHeaderFields = [
    "Cache-Control": "public, max-age=31536000, immutable",
]

func ebookPackageEntryResponse(
    url: URL,
    metadata: ReaderPackageEntryResponseMetadata,
    byteCount: Int,
    isGenerationBacked: Bool
) -> HTTPURLResponse {
    ebookHTTPResponse(
        url: url,
        mimeType: metadata.mimeType,
        byteCount: byteCount,
        textEncodingName: metadata.textEncodingName,
        additionalHeaderFields: isGenerationBacked
            ? ebookViewerAssetCacheHeaderFields
            : ["Cache-Control": "no-store"]
    )
}

private let ebookViewerAssetRevisionPlaceholder = "__MNB_VIEWER_ASSET_REVISION__"
private let ebookViewerAssetResourceSchemaVersion = 1

enum EbookViewerAssetRevisionError: Error {
    case invalidRevision
    case invalidViewerHTML
}

func ebookViewerAssetRevision(
    applicationIdentifier: String,
    applicationVersion: String,
    applicationBuild: String,
    resourceSchemaVersion: Int
) -> String {
    let identity = [
        applicationIdentifier,
        applicationVersion,
        applicationBuild,
        String(resourceSchemaVersion),
    ].joined(separator: "\u{0}")
    let digest = SHA256.hash(data: Data(identity.utf8))
    let digestPrefix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    return "v\(resourceSchemaVersion)-\(digestPrefix)"
}

func ebookViewerHTMLApplyingAssetRevision(
    _ html: String,
    revision: String
) throws -> String {
    guard revision.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
        throw EbookViewerAssetRevisionError.invalidRevision
    }
    guard html.components(separatedBy: ebookViewerAssetRevisionPlaceholder).count - 1 == 2 else {
        throw EbookViewerAssetRevisionError.invalidViewerHTML
    }
    return html.replacingOccurrences(
        of: ebookViewerAssetRevisionPlaceholder,
        with: revision
    )
}

func ebookViewerAssetRelativePath(
    from url: URL,
    activeRevision: String
) -> String? {
    guard url.scheme == "ebook",
          url.host == "ebook" else {
        return nil
    }
    let prefix = "/load/viewer-assets/"
    guard let encodedPath = URLComponents(
        url: url,
        resolvingAgainstBaseURL: false
    )?.percentEncodedPath else {
        return nil
    }
    guard encodedPath.hasPrefix(prefix) else {
        return nil
    }
    let encodedComponents = encodedPath
        .dropFirst(prefix.count)
        .split(separator: "/", omittingEmptySubsequences: false)
    guard encodedComponents.count >= 2 else {
        return nil
    }
    let components = encodedComponents.compactMap {
        String($0).removingPercentEncoding
    }
    guard components.count == encodedComponents.count,
          components[0] == activeRevision else {
        return nil
    }
    let assetComponents = components.dropFirst()
    guard assetComponents.allSatisfy({
        !$0.isEmpty &&
        $0 != "." &&
        $0 != ".." &&
        !$0.contains("/") &&
        !$0.contains("\\") &&
        !$0.contains("\u{0}")
    }) else {
        return nil
    }
    return assetComponents.joined(separator: "/")
}

private func currentEbookViewerAssetRevision() -> String {
    let bundle = Bundle.main
    return ebookViewerAssetRevision(
        applicationIdentifier: bundle.bundleIdentifier ?? "unknown-application",
        applicationVersion: bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0",
        applicationBuild: bundle.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "0",
        resourceSchemaVersion: ebookViewerAssetResourceSchemaVersion
    )
}

func ebookProcessTextResponseData(processedText: String, isCacheWarmer: Bool) -> Data? {
    if isCacheWarmer {
        return Data()
    }
    return externalizingCanonicalReaderSegmentSidecar(
        in: Array(processedText.utf8),
        scheme: .ebook
    ).documentHTML
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
    let isCacheWarmer: Bool

    init(contentURL: URL, location: String, isCacheWarmer: Bool, text: String) {
        contentURLString = contentURL.absoluteString
        self.location = location
        textFingerprint = ebookProcessTextFingerprint(text)
        self.isCacheWarmer = isCacheWarmer
    }

    init(contentURL: URL, location: String, text: String) {
        self.init(contentURL: contentURL, location: location, isCacheWarmer: false, text: text)
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
        case success(EbookProcessedSectionPayload)
        case cancelled
        case failure(String)
    }

    private final class ProcessTextWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ProcessTextOutcome, Never>?
        private var outcome: ProcessTextOutcome?

        func install(_ continuation: CheckedContinuation<ProcessTextOutcome, Never>) {
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(returning: outcome)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }

        func resolve(_ outcome: ProcessTextOutcome) {
            lock.lock()
            guard self.outcome == nil else {
                lock.unlock()
                return
            }
            self.outcome = outcome
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: outcome)
        }
    }

    private var inFlightWaitersByKey: [
        EBookProcessTextRequestKey: [UUID: ProcessTextWaiter]
    ] = [:]

    private func resolve(_ outcome: ProcessTextOutcome) throws -> EbookProcessedSectionPayload {
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

    private func removeWaiter(
        key: EBookProcessTextRequestKey,
        waiterID: UUID
    ) {
        inFlightWaitersByKey[key]?.removeValue(forKey: waiterID)
    }

    func process(
        key: EBookProcessTextRequestKey,
        operation: @Sendable () async throws -> EbookProcessedSectionPayload
    ) async throws -> (payload: EbookProcessedSectionPayload, didCoalesce: Bool) {
        if inFlightWaitersByKey[key] != nil {
            try Task.checkCancellation()
            let waiterID = UUID()
            let waiter = ProcessTextWaiter()
            inFlightWaitersByKey[key]?[waiterID] = waiter
            let response = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    waiter.install(continuation)
                }
            } onCancel: {
                waiter.resolve(.cancelled)
                Task {
                    await self.removeWaiter(key: key, waiterID: waiterID)
                }
            }
            return (try resolve(response), true)
        }

        try Task.checkCancellation()
        inFlightWaitersByKey[key] = [:]
        let response: ProcessTextOutcome
        do {
            response = .success(try await operation())
        } catch is CancellationError {
            response = .cancelled
        } catch {
            response = .failure(error.localizedDescription)
        }
        let waiters = inFlightWaitersByKey
            .removeValue(forKey: key)
            .map { Array($0.values) } ?? []
        for waiter in waiters {
            waiter.resolve(response)
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
        let processedPayload = try await process(
            contentURL: contentURL,
            location: sectionHref,
            text: entryText,
            isCacheWarmer: true
        )
        return EBookNativeSectionPrewarmResult(
            sectionHref: sectionHref,
            requestBytes: entryData.count,
            responseBytes: processedPayload.combinedByteCount
        )
    }

    func process(
        contentURL: URL,
        location: String,
        text: String,
        contentFingerprint: String? = nil,
        isCacheWarmer: Bool,
        shouldReadProcessedCache: Bool = true
    ) async throws -> EbookProcessedSectionPayload {
        let resolvedContentFingerprint = contentFingerprint ?? EBookProcessTextRequestKey(
            contentURL: contentURL,
            location: location,
            isCacheWarmer: isCacheWarmer,
            text: text
        ).textFingerprint
        if !isCacheWarmer, shouldReadProcessedCache, let ebookProcessedTextCacheReader {
            if let cachedResult = try await ebookProcessedTextCacheReader(
                contentURL,
                location,
                text,
                resolvedContentFingerprint
            ), ebookProcessedSectionPayloadHasDurableSegmentIdentities(cachedResult) {
                return cachedResult
            }
        }
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
        if !isCacheWarmer,
           ebookProcessedSectionPayloadHasDurableSegmentIdentities(result),
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
        assetRevision: String,
        sharedFontCSSBase64 _: String?,
        sharedFontCSSBase64Provider _: SharedFontCSSBase64Provider?
    ) async throws -> (HTTPURLResponse, Data) {
        let shouldEnablePageTurnInteractionDiagnostic =
            ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1"
        var html = try String(contentsOfFile: viewerHtmlPath, encoding: .utf8)
        html = try ebookViewerHTMLApplyingAssetRevision(
            html,
            revision: assetRevision
        )
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
public struct EbookProcessedDocumentPayload: Sendable {
    public let documentHTML: [UInt8]
    public let canonicalSegmentSidecar: Data?

    public init(documentHTML: [UInt8], canonicalSegmentSidecar: Data? = nil) {
        self.documentHTML = documentHTML
        self.canonicalSegmentSidecar = canonicalSegmentSidecar
    }
}

public typealias EbookHTMLDocumentProcessor = @Sendable (SwiftSoup.Document, Bool) async throws -> EbookProcessedDocumentPayload
public typealias EbookHTMLBytesProcessor = @Sendable ([UInt8], Bool) async -> [UInt8]
public typealias EbookHTMLProcessor = @Sendable (String, Bool) async -> String
public typealias EbookTextProcessor = @Sendable (URL, String, String, String?, Bool, EbookReadabilityContentProcessor?, EbookHTMLDocumentProcessor?, EbookHTMLBytesProcessor?, EbookHTMLProcessor?) async throws -> EbookProcessedSectionPayload
public typealias EbookProcessedTextCacheReader = @Sendable (URL, String, String, String?) async throws -> EbookProcessedSectionPayload?
public typealias EbookProcessedTextCacheWriter = @Sendable (URL, String, String, String?, EbookProcessedSectionPayload) async -> Void
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
        if url.path.hasPrefix(ReaderExternalSegmentSidecarScheme.ebook.endpointPathPrefix) {
            guard let sidecar = readerExternalSegmentSidecarResponse(for: url, scheme: .ebook) else {
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
                guard let request = ebookDirectSectionRequest(from: url),
                      let ebookTextProcessor else {
                    await { @MainActor in
                        if self.schemeHandlers[urlSchemeTask.hash] != nil {
                            urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                            self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                        }
                    }()
                    return
                }
                do {
                    let cachedSource = try await ReaderPackageEntrySourceCache.shared.cachedSource(
                        forPackageURL: request.sourceURL,
                        readerFileManager: readerFileManager
                    )
                    let sourceData = try cachedSource.source.readEntry(subpath: request.subpath)
                    let sourceText = String(decoding: sourceData, as: UTF8.self)
                    let processRequestKey = EBookProcessTextRequestKey(
                        contentURL: request.sourceURL,
                        location: request.subpath,
                        text: sourceText
                    )
                    let (processedPayload, _) = try await self.processTextRequestDeduper.process(
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
                            contentURL: request.sourceURL,
                            location: request.subpath,
                            text: sourceText,
                            contentFingerprint: processRequestKey.textFingerprint,
                            isCacheWarmer: false
                        )
                    }
                    guard ebookProcessedSectionPayloadHasDurableSegmentIdentities(processedPayload) else {
                        throw CustomSchemeHandlerError.fileNotFound
                    }
                    let publishedSidecar = publishingCanonicalReaderSegmentSidecar(
                        processedPayload,
                        scheme: .ebook
                    )
                    let responseData = ebookHTMLDataWithInjectedDirectSectionResponseMetadata(
                        publishedSidecar.documentHTML,
                        baseURL: ebookProcessedSectionBaseURL(
                            sourceURL: request.sourceURL,
                            sectionHref: request.subpath,
                            generationID: cachedSource.generationID
                        ),
                        sourceHref: request.subpath,
                        writingHint: ebookProcessedSectionWritingHint(from: url),
                        presentation: await ebookSectionPresentationProvider?(),
                        additionalHeadMarkup: publishedSidecar.headDescriptor
                    )
                    let response = ebookHTTPResponse(
                        url: url,
                        mimeType: "text/html",
                        byteCount: responseData.count,
                        textEncodingName: "utf-8",
                        additionalHeaderFields: ["Cache-Control": "no-store"]
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
            } else if url.path == "/process-text" {
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
                           let cachedPayload = try? await ebookProcessedTextCacheReader(
                            contentURL,
                            replacedTextLocation,
                            text,
                            processRequestKey.textFingerprint
                           ),
                           ebookProcessedSectionPayloadHasDurableSegmentIdentities(cachedPayload),
                           let cachedData = ebookProcessTextResponseData(
                            processedText: String(
                                decoding: externalizingReaderSegmentSidecar(
                                    documentHTML: Array(cachedPayload.documentHTML),
                                    canonicalSidecar: cachedPayload.segmentSidecar,
                                    scheme: .ebook
                                ).documentHTML,
                                as: UTF8.self
                            ),
                            isCacheWarmer: false
                           ) {
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
                        let responsePayload: EbookProcessedSectionPayload
                        do {
                            (responsePayload, _) = try await self.processTextRequestDeduper.process(
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
                        if !isCacheWarmer,
                           !ebookProcessedSectionPayloadHasDurableSegmentIdentities(responsePayload) {
                            await { @MainActor in
                                if self.schemeHandlers[urlSchemeTask.hash] != nil {
                                    urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                                    self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                                }
                            }()
                            return
                        }
                        let responseText = String(
                            decoding: externalizingReaderSegmentSidecar(
                                documentHTML: Array(responsePayload.documentHTML),
                                canonicalSidecar: responsePayload.segmentSidecar,
                                scheme: .ebook
                            ).documentHTML,
                            as: UTF8.self
                        )
                        if let respData = ebookProcessTextResponseData(
                            processedText: responseText,
                            isCacheWarmer: isCacheWarmer
                        ) {
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
            } else if url.path == "/entry" || url.path.hasPrefix("/entry-source/") {
                let pathBackedRequest = ebookPathBackedEntryRequest(
                    from: url,
                    mainDocumentURL: urlSchemeTask.request.mainDocumentURL
                )
                let queryBackedRequest: EbookPathBackedEntryRequest? = {
                    guard url.path == "/entry",
                          let mainDocumentURL = self.validatedMainDocumentURL(for: urlSchemeTask.request, route: "/entry"),
                          let subpath = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                            .queryItems?
                            .first(where: { $0.name == "subpath" })?
                            .value,
                          let normalizedSubpath = normalizedEbookEntrySubpath(subpath) else {
                        return nil
                    }
                    return EbookPathBackedEntryRequest(
                        sourceURL: mainDocumentURL,
                        generationID: nil,
                        subpath: normalizedSubpath
                    )
                }()
                guard let entryRequest = pathBackedRequest ?? queryBackedRequest else {
                    await { @MainActor in
                        if self.schemeHandlers[urlSchemeTask.hash] != nil {
                            urlSchemeTask.didFailWithError(CustomSchemeHandlerError.fileNotFound)
                            self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                        }
                    }()
                    return
                }

                do {
                    let cachedSource = try await ReaderPackageEntrySourceCache.shared.cachedSource(
                        forPackageURL: entryRequest.sourceURL,
                        readerFileManager: readerFileManager
                    )
                    guard entryRequest.generationID.map({
                        cachedSource.generationID == $0
                    }) != false else {
                        throw ReaderPackageEntrySourceError.entryNotFound
                    }
                    let data = try cachedSource.source.readEntry(subpath: entryRequest.subpath)
                    let metadata = try cachedSource.source.mimeType(subpath: entryRequest.subpath)
                    let response = ebookPackageEntryResponse(
                        url: url,
                        metadata: metadata,
                        byteCount: data.count,
                        isGenerationBacked: entryRequest.generationID != nil
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
                let assetRevision = currentEbookViewerAssetRevision()
                if let fileUrl = Self.bundleURLFromWebURL(
                    url,
                    activeRevision: assetRevision
                ),
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
                        additionalHeaderFields: ebookViewerAssetCacheHeaderFields
                    )
                    await { @MainActor in
                        if self.schemeHandlers[urlSchemeTask.hash] != nil {
                            urlSchemeTask.didReceive(response)
                            urlSchemeTask.didReceive(data)
                            urlSchemeTask.didFinish()
                            self.schemeHandlers.removeValue(forKey: urlSchemeTask.hash)
                        }
                    }()
                } else if let missingAssetResponse = missingEbookViewerAssetResponse(for: url) {
                    await { @MainActor in
                        if self.schemeHandlers[urlSchemeTask.hash] != nil {
                            urlSchemeTask.didReceive(missingAssetResponse)
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
                                assetRevision: assetRevision,
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

    nonisolated private static func bundleURLFromWebURL(
        _ url: URL,
        activeRevision: String
    ) -> URL? {
        guard let relativePath = ebookViewerAssetRelativePath(
            from: url,
            activeRevision: activeRevision
        ) else {
            return nil
        }
        let relativeURL = URL(fileURLWithPath: relativePath)
        let assetName = relativeURL.deletingPathExtension().lastPathComponent
        let assetExtension = relativeURL.lakePathExtension
        let assetDirectory = relativeURL.deletingLastPathComponent().relativePath
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
