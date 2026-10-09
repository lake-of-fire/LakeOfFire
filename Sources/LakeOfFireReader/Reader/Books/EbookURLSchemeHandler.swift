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

func ebookProcessedSectionMediaBootstrapMarkup() -> Data {
    Data(#"<script type="module" src="ebook://ebook/load/viewer-assets/foliate-js/ebook-package-media.js"></script>"#.utf8)
}

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

func ebookURLStringHasValidPercentEncoding(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    func isHex(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57)
            || (byte >= 65 && byte <= 70)
            || (byte >= 97 && byte <= 102)
    }
    var index = 0
    while index < bytes.count {
        if bytes[index] == UInt8(ascii: "%") {
            guard index + 2 < bytes.count,
                  isHex(bytes[index + 1]),
                  isHex(bytes[index + 2]) else {
                return false
            }
            index += 3
        } else {
            index += 1
        }
    }
    return true
}

/// Returns the canonical package URL only when it is a valid ebook backing URL.
/// The reader file manager owns the path grammar and containment checks, so the
/// scheme handler cannot accidentally accept a source URL that later resolves
/// differently when it is opened from a drive.
func ebookValidatedSourceURL(
    _ url: URL,
    readerFileManager: ReaderFileManager
) -> URL? {
    guard url.scheme == "ebook",
          url.host == "ebook",
          let canonicalReaderURL = readerFileManager.canonicalReaderBackingURL(for: url),
          var components = URLComponents(url: canonicalReaderURL, resolvingAgainstBaseURL: false) else {
        return nil
    }
    // Use the file manager's validated representation as the source of truth
    // for path normalization, then retain ebook as the document scheme.
    components.scheme = "ebook"
    components.host = "ebook"
    components.query = nil
    components.fragment = nil
    return components.url
}

/// Resolves the package source for an endpoint request. WebKit's main document
/// URL is the capability: values supplied by page JavaScript are accepted only
/// when they exactly identify that same package.
func ebookAuthorizedMainDocumentURL(
    for request: URLRequest,
    activePackageURL: URL? = nil,
    readerFileManager: ReaderFileManager
) -> URL? {
    func packageURL(from documentURL: URL?) -> URL? {
        guard let documentURL else { return nil }
        if let packageURL = ebookValidatedSourceURL(
            documentURL,
            readerFileManager: readerFileManager
        ) {
            return packageURL
        }
        guard documentURL.scheme == "ebook",
              documentURL.host == "ebook",
              documentURL.path == "/processed-section",
              let rawSourceURL = URLComponents(url: documentURL, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "sourceURL" })?
                .value,
              ebookURLStringHasValidPercentEncoding(rawSourceURL),
              let sourceURL = URL(string: rawSourceURL) else {
            return nil
        }
        return ebookValidatedSourceURL(sourceURL, readerFileManager: readerFileManager)
    }

    guard let documentPackageURL = packageURL(from: request.mainDocumentURL) else {
        return nil
    }
    let authorizedPackageURL = activePackageURL ?? documentPackageURL
    guard documentPackageURL == authorizedPackageURL else { return nil }

    let requestedSourceURL = request.value(forHTTPHeaderField: "X-Ebook-Source-URL")
    let requestSourceURL = URLComponents(
        url: request.url ?? URL(fileURLWithPath: "/"),
        resolvingAgainstBaseURL: false
    )?
        .queryItems?
        .first(where: { $0.name == "sourceURL" })?
        .value

    for candidateString in [requestedSourceURL, requestSourceURL].compactMap({ $0 }) {
        guard ebookURLStringHasValidPercentEncoding(candidateString),
              let candidateURL = URL(string: candidateString),
              ebookValidatedSourceURL(candidateURL, readerFileManager: readerFileManager)
                == authorizedPackageURL else {
            return nil
        }
    }
    return authorizedPackageURL
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
    let packageSessionID: String?
    let location: String
    let textFingerprint: String
    let processingVariant: EbookProcessingVariant

    init(
        contentURL: URL,
        location: String,
        contentData: Data,
        processingVariant: EbookProcessingVariant,
        packageSessionID: String? = nil
    ) {
        contentURLString = contentURL.absoluteString
        self.packageSessionID = packageSessionID
        self.location = location
        textFingerprint = ebookProcessDataFingerprint(contentData)
        self.processingVariant = processingVariant
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

    private struct Waiter {
        let continuation: CheckedContinuation<SectionProcessingOutcome, Never>
        let didCoalesce: Bool
    }

    private struct InFlightOperation {
        let id: UInt64
        var producer: Task<Void, Never>?
        var waiters: [UInt64: Waiter]
    }

    private var inFlightOperationByKey: [EBookSectionProcessingRequestKey: InFlightOperation] = [:]
    private var nextOperationID: UInt64 = 0
    private var nextWaiterID: UInt64 = 0

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
        inFlightOperationByKey[key]?.waiters.values.filter { $0.didCoalesce }.count ?? 0
    }
#endif

    private func complete(
        key: EBookSectionProcessingRequestKey,
        operationID: UInt64,
        outcome: SectionProcessingOutcome
    ) {
        guard let operation = inFlightOperationByKey[key], operation.id == operationID else {
            return
        }
        inFlightOperationByKey.removeValue(forKey: key)
        for waiter in operation.waiters.values {
            waiter.continuation.resume(returning: outcome)
        }
    }

    private func cancelWaiter(
        key: EBookSectionProcessingRequestKey,
        operationID: UInt64,
        waiterID: UInt64
    ) {
        guard var operation = inFlightOperationByKey[key],
              operation.id == operationID,
              let waiter = operation.waiters.removeValue(forKey: waiterID) else {
            return
        }

        let producerToCancel: Task<Void, Never>?
        if operation.waiters.isEmpty {
            inFlightOperationByKey.removeValue(forKey: key)
            producerToCancel = operation.producer
        } else {
            inFlightOperationByKey[key] = operation
            producerToCancel = nil
        }
        waiter.continuation.resume(returning: .cancelled)
        producerToCancel?.cancel()
    }

    func process(
        key: EBookSectionProcessingRequestKey,
        operation: @Sendable @escaping () async throws -> EbookProcessedSectionPayload
    ) async throws -> (payload: EbookProcessedSectionPayload, didCoalesce: Bool) {
        try Task.checkCancellation()

        nextWaiterID &+= 1
        let waiterID = nextWaiterID
        let operationID: UInt64
        let didCoalesce: Bool

        if let existingOperation = inFlightOperationByKey[key] {
            operationID = existingOperation.id
            didCoalesce = true
        } else {
            nextOperationID &+= 1
            operationID = nextOperationID
            didCoalesce = false
            inFlightOperationByKey[key] = InFlightOperation(
                id: operationID,
                producer: nil,
                waiters: [:]
            )

            let producer = Task { [operation] in
                let outcome: SectionProcessingOutcome
                do {
                    outcome = .success(try await operation())
                } catch is CancellationError {
                    outcome = .cancelled
                } catch {
                    outcome = .failure(error.localizedDescription)
                }
                self.complete(key: key, operationID: operationID, outcome: outcome)
            }
            if var currentOperation = inFlightOperationByKey[key],
               currentOperation.id == operationID {
                currentOperation.producer = producer
                inFlightOperationByKey[key] = currentOperation
            } else {
                producer.cancel()
            }
        }

        let response = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<SectionProcessingOutcome, Never>) in
                guard var currentOperation = inFlightOperationByKey[key],
                      currentOperation.id == operationID else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                currentOperation.waiters[waiterID] = Waiter(
                    continuation: continuation,
                    didCoalesce: didCoalesce
                )
                inFlightOperationByKey[key] = currentOperation
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(
                    key: key,
                    operationID: operationID,
                    waiterID: waiterID
                )
            }
        }

        try Task.checkCancellation()
        return (try resolve(response), didCoalesce)
    }
}

public enum EBookNativeSectionPageStatsOutcome: Equatable, Sendable {
    /// Native processing produced and published an authoritative section row.
    case produced
    /// This section cannot produce page stats for the current processing contract.
    /// Retrying without a causal contract change would repeat the same result.
    case unsupported
}

public struct EBookNativeSectionPrewarmResult: Equatable, Sendable {
    public let sectionHref: String
    public let requestBytes: Int
    public let responseBytes: Int
    public let pageStatsRequested: Bool
    public let pageStatsOutcome: EBookNativeSectionPageStatsOutcome

    public init(
        sectionHref: String,
        requestBytes: Int,
        responseBytes: Int,
        pageStatsRequested: Bool = true,
        pageStatsOutcome: EBookNativeSectionPageStatsOutcome = .unsupported
    ) {
        self.sectionHref = sectionHref
        self.requestBytes = requestBytes
        self.responseBytes = responseBytes
        self.pageStatsRequested = pageStatsRequested
        self.pageStatsOutcome = pageStatsOutcome
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
        if !isCacheWarmer,
           ebookProcessedSectionPayloadHasDurableSegmentIdentities(result),
           let ebookProcessedTextCacheWriter {
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
        let shouldEnablePageTurnInteractionDiagnostic: Bool = {
#if DEBUG
            ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1"
#else
            false
#endif
        }()
        let shouldEnableProgressAdmissionDiagnostic: Bool = {
#if DEBUG
            ProcessInfo.processInfo.environment["MANABI_EBOOK_PROGRESS_ADMISSION_DIAGNOSTIC"] == "1"
#else
            false
#endif
        }()
        let data: Data
        if shouldEnablePageTurnInteractionDiagnostic || shouldEnableProgressAdmissionDiagnostic {
            var html = try String(contentsOfFile: viewerHtmlPath, encoding: .utf8)
            let diagnosticPayload = """
            <script>
            (function() {
                try {
                    globalThis.manabiPageTurnInteractionDiagnostic = \(shouldEnablePageTurnInteractionDiagnostic);
                    if (\(shouldEnableProgressAdmissionDiagnostic)) {
                        const stages = new Set([
                            'ebook.confirmedProgress.rejected',
                            'ebook.updateReadingProgress.rejected',
                            'ebook.updateReadingProgress.dispatch',
                            'ebook.relocate.progressAdmission',
                            'ebook.positionSave.userInput'
                        ]);
                        const fields = new Set([
                            'stage', 'reason', 'source', 'closed', 'hasLoadedLastPosition',
                            'restoreInProgress', 'suppressNextSave', 'requiresUserInput',
                            'hasProducerOwner', 'hasBookScope', 'locationRevision',
                            'capturedRevision', 'currentRevision', 'sectionIndex',
                            'documentMismatch', 'sectionMismatch', 'locationCFIMismatch',
                            'locationFractionMismatch'
                        ]);
                        globalThis.__manabiRestoreDebugLog = (stage, payload = {}) => {
                            if (!stages.has(stage)) return;
                            const safe = {};
                            for (const [key, value] of Object.entries(payload)) {
                                if (!fields.has(key)) continue;
                                if (typeof value === 'boolean' || Number.isFinite(value)) safe[key] = value;
                                else if (['stage', 'reason', 'source'].includes(key) && typeof value === 'string') {
                                    safe[key] = value.slice(0, 80);
                                }
                            }
                            window.webkit?.messageHandlers?.readerConsoleLog?.postMessage({
                                severity: 'debug',
                                arguments: '# READER ebook-progress-boundary stage=' + stage + ' ' + JSON.stringify(safe)
                            });
                        };
                    }
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
    let packageDocumentPath: String?
}

@globalActor
public actor EbookURLSchemeActor {
    public static let shared = EbookURLSchemeActor()
    
    public init() { }
}

public typealias EbookDocumentTransform = @Sendable (SwiftSoup.Document) async -> SwiftSoup.Document
public typealias EbookReadabilityContentProcessor = @Sendable (String, URL, URL?, Bool, Bool, String?, EbookDocumentTransform) async throws -> SwiftSoup.Document
public enum EbookReaderProcessingCompletion: UInt8, Sendable {
    case incomplete
    case completed
}

public struct EbookProcessedDocumentPayload: Sendable {
    public let documentHTML: [UInt8]
    public let canonicalSegmentSidecar: Data?
    public let processingCompletion: EbookReaderProcessingCompletion

    public init(
        documentHTML: [UInt8],
        canonicalSegmentSidecar: Data? = nil,
        processingCompletion: EbookReaderProcessingCompletion = .incomplete
    ) {
        self.documentHTML = documentHTML
        self.canonicalSegmentSidecar = canonicalSegmentSidecar
        self.processingCompletion = processingCompletion
    }
}

public typealias EbookHTMLDocumentProcessor = @Sendable (
    SwiftSoup.Document,
    Bool,
    EbookReaderProcessingCompletionProof
) async throws -> EbookProcessedSectionPayload
public typealias EbookHTMLBytesProcessor = @Sendable ([UInt8], Bool) async -> [UInt8]
public typealias EbookHTMLProcessor = @Sendable (String, Bool) async -> String
public typealias EbookTextProcessor = @Sendable (URL, String, String, String?, Bool, EbookReadabilityContentProcessor?, EbookHTMLDocumentProcessor?, EbookHTMLBytesProcessor?, EbookHTMLProcessor?) async throws -> EbookProcessedSectionPayload
public typealias EbookProcessedTextCacheReader = @Sendable (URL, String, String) async throws -> EbookProcessedSectionPayload?
public typealias EbookProcessedTextCacheWriter = @Sendable (URL, String, String, EbookProcessedSectionPayload) async -> Void
public typealias EbookSectionPresentationProvider = @Sendable () async -> EbookSectionPresentation
public typealias SharedFontCSSBase64Provider = @Sendable () async -> String?

struct EbookProcessedSectionCacheProbeResult: Sendable {
    let payload: EbookProcessedSectionPayload?
    let outcome: String
}

func probeEbookProcessedSectionCache(
    reader: EbookProcessedTextCacheReader?,
    contentURL: URL,
    location: String,
    contentFingerprint: String
) async throws -> EbookProcessedSectionCacheProbeResult {
    try Task.checkCancellation()
    guard let reader else {
        return EbookProcessedSectionCacheProbeResult(payload: nil, outcome: "unavailable")
    }

    do {
        let candidate = try await reader(contentURL, location, contentFingerprint)
        try Task.checkCancellation()
        let payload = candidate.flatMap {
            ebookProcessedSectionPayloadHasDurableSegmentIdentities($0) ? $0 : nil
        }
        return EbookProcessedSectionCacheProbeResult(
            payload: payload,
            outcome: payload == nil ? "miss" : "hit"
        )
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        try Task.checkCancellation()
        return EbookProcessedSectionCacheProbeResult(
            payload: nil,
            outcome: "error:\(String(describing: type(of: error)))"
        )
    }
}

/// Resource access captured synchronously at WKURLSchemeTask receipt. Never
/// select a replacement session after waiting for the processing actor/cache.
private struct EbookCapturedPackageRead: Sendable {
    let access: ReaderEBookServingAccess
    var sourceURL: URL { access.sourceURL }
    var lease: ReaderEBookServingLease? { access.lease }
    func validate() throws { try access.validate() }

    func source(readerFileManager: ReaderFileManager) async throws -> EbookResolvedPackageSource {
        try validate()
        if let lease { return .bound(lease) }
        let source = try await ReaderPackageEntrySourceCache.shared.cachedSource(
            forPackageURL: sourceURL, readerFileManager: readerFileManager
        )
        try validate()
        return .legacy(source)
    }
}

private enum EbookResolvedPackageSource: Sendable {
    case legacy(ReaderPackageEntrySourceCache.CachedSource)
    case bound(ReaderEBookServingLease)

    var entries: [ReaderPackageEntryMetadata] {
        switch self {
        case let .legacy(source): return source.entries
        case let .bound(lease): return lease.package.entries
        }
    }
    var generationID: String {
        switch self {
        case let .legacy(source): return source.generationID
        case let .bound(lease): return lease.generationID
        }
    }
    func readEntry(subpath: String) throws -> Data {
        switch self {
        case let .legacy(source): return try source.source.readEntry(subpath: subpath)
        case let .bound(lease): return try lease.readEntry(subpath: subpath)
        }
    }
    func mimeType(subpath: String, data: Data) throws -> ReaderPackageEntryResponseMetadata {
        switch self {
        case let .legacy(source): return try source.source.mimeType(subpath: subpath, data: data)
        case let .bound(lease): return try lease.metadata(subpath: subpath, data: data)
        }
    }
}

public final class EbookURLSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated(unsafe) var ebookProcessedTextCacheReader: EbookProcessedTextCacheReader?
    nonisolated(unsafe) var ebookProcessedTextCacheWriter: EbookProcessedTextCacheWriter?
    nonisolated(unsafe) var ebookTextProcessor: EbookTextProcessor?
    nonisolated(unsafe) var ebookProcessingVariantProvider: EbookProcessingVariantProvider?
    nonisolated(unsafe) var ebookSectionPresentationProvider: EbookSectionPresentationProvider?
    public var readerFileManager: ReaderFileManager?
    nonisolated(unsafe) var processReadabilityContent: EbookReadabilityContentProcessor?
    nonisolated(unsafe) var processHTMLDocument: EbookHTMLDocumentProcessor?
    nonisolated(unsafe) var processHTMLBytes: EbookHTMLBytesProcessor?
    nonisolated(unsafe) var processHTML: EbookHTMLProcessor?
    nonisolated(unsafe) public var sharedFontCSSBase64: String?
    nonisolated(unsafe) var sharedFontCSSBase64Provider: SharedFontCSSBase64Provider?
    nonisolated(unsafe) public var sharedReaderFontAsset: SharedReaderFontAsset?

    private let packageSessionBinding = ReaderEBookServingSessionBinding()
    public var packageSessions: ReaderEBookServingSessionStore {
        get { packageSessionBinding.currentStore }
        set { packageSessionBinding.replace(with: newValue) }
    }

    private let schemeTaskCompletionOwnership = URLSchemeTaskCompletionOwnership()
    private let sectionProcessingDeduper = EBookSectionProcessingDeduper()
    @EbookURLSchemeActor private var activePackageURL: URL?
    
    enum CustomSchemeHandlerError: Error {
        case fileNotFound
    }

    public override init() {
        super.init()
    }

    func processSectionForRequest(
        key: EBookSectionProcessingRequestKey,
        operation: @Sendable @escaping () async throws -> EbookProcessedSectionPayload
    ) async throws -> (payload: EbookProcessedSectionPayload, didCoalesce: Bool) {
        try await sectionProcessingDeduper.process(key: key, operation: operation)
    }

    @discardableResult
    private func finishActiveTask(
        _ urlSchemeTask: WKURLSchemeTask,
        requiring packageRead: EbookCapturedPackageRead? = nil,
        response: URLResponse,
        data: Data? = nil
    ) -> Bool {
        do { try packageRead?.validate() }
        catch { return failActiveTask(urlSchemeTask, error: error) }
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
        
        let request = urlSchemeTask.request
        guard let url = request.url else {
            failActiveTask(urlSchemeTask, error: CustomSchemeHandlerError.fileNotFound)
            return
        }
        let sharedReaderFontAsset = self.sharedReaderFontAsset
        if let fontResponse = sharedReaderFontResponse(
            for: url,
            asset: sharedReaderFontAsset
        ) {
            finishActiveTask(
                urlSchemeTask,
                response: fontResponse.response,
                data: fontResponse.data
            )
            return
        }
        if url.path.hasPrefix(ReaderExternalSegmentSidecarScheme.ebook.endpointPathPrefix) {
            guard let sidecar = readerExternalSegmentSidecarResponse(
                for: url,
                scheme: .ebook
            ) else {
                failActiveTask(urlSchemeTask, error: CustomSchemeHandlerError.fileNotFound)
                return
            }
            finishActiveTask(
                urlSchemeTask,
                response: sidecar.response,
                data: sidecar.data
            )
            return
        }
        guard let readerFileManager else {
            print("Error: Missing ReaderFileManager in EbookURLSchemeHandler")
            failActiveTask(urlSchemeTask, error: CustomSchemeHandlerError.fileNotFound)
            return
        }
        let packageRead: EbookCapturedPackageRead?
        do { packageRead = try capturePackageRead(request, readerFileManager: readerFileManager) }
        catch {
            failActiveTask(urlSchemeTask, error: error)
            return
        }
        let ebookProcessedTextCacheReader = self.ebookProcessedTextCacheReader
        let ebookProcessedTextCacheWriter = self.ebookProcessedTextCacheWriter
        let ebookTextProcessor = self.ebookTextProcessor
        let ebookProcessingVariantProvider = self.ebookProcessingVariantProvider
        let ebookSectionPresentationProvider = self.ebookSectionPresentationProvider
        let processReadabilityContent = self.processReadabilityContent
        let processHTMLDocument = self.processHTMLDocument
        let processHTMLBytes = self.processHTMLBytes
        let processHTML = self.processHTML
        let sharedFontCSSBase64 = self.sharedFontCSSBase64
        let sharedFontCSSBase64Provider = self.sharedFontCSSBase64Provider

        
        let workTask = Task.detached(priority: ebookURLSchemeTaskPriority(for: url)) { @EbookURLSchemeActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            if let requestedPackageURL = ebookValidatedSourceURL(
                url,
                readerFileManager: readerFileManager
            ) {
                let mainDocumentPackageURL = request.mainDocumentURL.flatMap {
                    ebookValidatedSourceURL($0, readerFileManager: readerFileManager)
                }
                if request.mainDocumentURL == nil
                    || mainDocumentPackageURL == requestedPackageURL {
                    // This handler belongs to one WebView. Only a top-level
                    // package navigation may replace its package binding.
                    self.activePackageURL = requestedPackageURL
                }
            }
            if let packageRead, packageRead.lease == nil,
               self.validatedMainDocumentURL(for: request, readerFileManager: readerFileManager)
                != packageRead.sourceURL {
                await { @MainActor in
                    self.failActiveTask(urlSchemeTask, error: CustomSchemeHandlerError.fileNotFound)
                }()
                return
            }
            if url.path == "/processed-section" {
                guard let sectionRequest = ebookDirectSectionRequest(from: url),
                      let capturedRead = packageRead,
                      sectionRequest.sourceURL == capturedRead.sourceURL else {
                    await { @MainActor in
                        self.failActiveTask(
                            urlSchemeTask,
                            error: CustomSchemeHandlerError.fileNotFound
                        )
                    }()
                    return
                }

                let mainDocumentURL = capturedRead.sourceURL
                let sectionHref = sectionRequest.subpath

                let requestStartedAt = Date()
                do {
                    try Task.checkCancellation()
                    let processingVariant = await ebookProcessingVariantProvider?()
                    try Task.checkCancellation()
                    try await EbookProcessingVariantContext.$current.withValue(processingVariant) {
                    let isDirectSectionLoad = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?
                        .contains(where: { $0.name == "direct" && $0.value == "1" }) == true
                    guard let capturedRead = packageRead else { throw CustomSchemeHandlerError.fileNotFound }
                    let cachedSource = try await capturedRead.source(readerFileManager: readerFileManager)
                    try Task.checkCancellation()
                    let sourceReadyElapsedMs = Int(Date().timeIntervalSince(requestStartedAt) * 1000)
                    let sourceData = try cachedSource.readEntry(subpath: sectionHref)
                    try Task.checkCancellation()
                    let sourceReadElapsedMs = Int(Date().timeIntervalSince(requestStartedAt) * 1000) - sourceReadyElapsedMs
                    let didCoalesce: Bool
                    let cacheOutcome: String
                    let processRequestKey = EBookSectionProcessingRequestKey(
                        contentURL: mainDocumentURL,
                        location: sectionHref,
                        contentData: sourceData,
                        processingVariant: processingVariant ?? .unspecified,
                        packageSessionID: packageRead?.lease?.id
                    )
                    let cacheProbeStartedAt = Date()
                    let cacheProbe = try await probeEbookProcessedSectionCache(
                        reader: ebookProcessedTextCacheReader,
                        contentURL: mainDocumentURL,
                        location: sectionHref,
                        contentFingerprint: processRequestKey.textFingerprint
                    )
                    let cachedPayload = cacheProbe.payload
                    let cacheProbeOutcome = cacheProbe.outcome
                    let cacheProbeElapsedMs = Int(Date().timeIntervalSince(cacheProbeStartedAt) * 1000)
                    let processedPayload: EbookProcessedSectionPayload
                    if let ebookTextProcessor {
                        if let cachedPayload {
                            processedPayload = cachedPayload
                            didCoalesce = false
                            cacheOutcome = "final-direct-hit"
                        } else {
                            let sourceText = ReaderPackageEntrySource.decodeText(sourceData)
                            let processedResult = try await self.processSectionForRequest(
                                key: processRequestKey
                            ) {
                                let processingActor = EBookProcessingActor(
                                    ebookProcessedTextCacheWriter: ebookProcessedTextCacheWriter.map { writer in
                                        { contentURL, location, fingerprint, payload in
                                            do { try capturedRead.validate() } catch { return }
                                            await writer(contentURL, location, fingerprint, payload)
                                        }
                                    },
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
                            if processedPayload.isAuthoritativelyProcessed {
                                cacheOutcome = processedResult.didCoalesce
                                    ? "final-miss-coalesced"
                                    : "final-miss-processed"
                            } else {
                                cacheOutcome = processedResult.didCoalesce
                                    ? "final-miss-coalesced-fallback"
                                    : "final-miss-fallback"
                            }
                        }
                    } else {
                        throw CustomSchemeHandlerError.fileNotFound
                    }
                    try Task.checkCancellation()

                    let sectionPresentation = await ebookSectionPresentationProvider?()
                    try Task.checkCancellation()

                    let processingElapsedMs = Int(Date().timeIntervalSince(requestStartedAt) * 1000)
                        - sourceReadyElapsedMs
                        - sourceReadElapsedMs
                    try capturedRead.validate()
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
                        "data-mnb-native-processing-authoritative": processedPayload.isAuthoritativelyProcessed ? "true" : "false",
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
                    var sectionHeadMarkup = publishedSidecar.headDescriptor ?? Data()
                    sectionHeadMarkup.append(ebookProcessedSectionMediaBootstrapMarkup())
                    let responseData = ebookHTMLDataWithInjectedResponseMetadata(
                        publishedSidecar.documentHTML,
                        baseURL: ebookProcessedSectionBaseURL(
                            sourceURL: mainDocumentURL,
                            sectionHref: sectionHref,
                            generationID: cachedSource.generationID,
                            packageSessionID: packageRead?.lease?.id
                        ),
                        writingHint: writingHint,
                        bodyAttributes: responseBodyAttributes,
                        presentation: sectionPresentation,
                        additionalHeadMarkup: sectionHeadMarkup,
                        suppressesInitialPaginatorLayout: isDirectSectionLoad
                    )
                    let responseEncodeElapsedMs = Int(Date().timeIntervalSince(responseDecorationStartedAt) * 1000)
                    let responseReadyElapsedMs = Int(Date().timeIntervalSince(requestStartedAt) * 1000)
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: [
                            "Cache-Control": "no-store",
                            "Content-Type": isDirectSectionLoad ? "text/html; charset=utf-8" : "text/plain; charset=utf-8",
                            "Content-Length": "\(responseData.count)",
                            "X-Manabi-Process-Cache": cacheOutcome,
                            "X-Manabi-Response-Ready-Elapsed-Ms": "\(responseReadyElapsedMs)",
                            "X-Manabi-Response-Encode-Elapsed-Ms": "\(responseEncodeElapsedMs)",
                            "X-Manabi-Did-Coalesce": didCoalesce ? "true" : "false",
                            "X-Manabi-Processing-Authoritative": processedPayload.isAuthoritativelyProcessed ? "true" : "false",
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
                        self.finishActiveTask(
                            urlSchemeTask,
                            requiring: packageRead,
                            response: response,
                            data: responseData
                        )
                    }()
                    }
                } catch {
                    await { @MainActor in
                        self.failActiveTask(urlSchemeTask, error: error)
                    }()
                }
            } else if url.path == "/entries" {
                do {
                    guard let capturedRead = packageRead else { throw CustomSchemeHandlerError.fileNotFound }
                    let cachedSource = try await capturedRead.source(readerFileManager: readerFileManager)
                    let responseBody = EBookEntriesResponse(entries: cachedSource.entries,
                        packageDocumentPath: packageRead?.lease?.package.fingerprint.packageDocumentPath)
                    let data = try JSONEncoder().encode(responseBody)
                    let response = ebookHTTPResponse(
                        url: url,
                        mimeType: "application/json",
                        byteCount: data.count,
                        textEncodingName: "utf-8"
                    )
                    await { @MainActor in
                        self.finishActiveTask(
                            urlSchemeTask,
                            requiring: packageRead,
                            response: response,
                            data: data
                        )
                    }()
                } catch {
                    await { @MainActor in
                        self.failActiveTask(urlSchemeTask, error: error)
                    }()
                }
            } else if url.path == "/entry" || url.path.hasPrefix("/entry-source/") || url.path.hasPrefix("/entry-session/") {
                let pathBackedRequest = ebookPathBackedEntryRequest(
                    from: url,
                    mainDocumentURL: request.mainDocumentURL
                )
                let queryBackedRequest: EbookPathBackedEntryRequest? = {
                    guard url.path == "/entry",
                          let capturedRead = packageRead,
                          let subpath = ebookEntryQuerySubpath(in: url) else { return nil }
                    return .init(sourceURL: capturedRead.sourceURL, generationID: nil,
                                 subpath: subpath, packageSessionID: capturedRead.lease?.id)
                }()
                guard let entryRequest = pathBackedRequest ?? queryBackedRequest else {
                    await { @MainActor in
                        self.failActiveTask(urlSchemeTask, error: CustomSchemeHandlerError.fileNotFound)
                    }()
                    return
                }

                do {
                    guard let capturedRead = packageRead else { throw CustomSchemeHandlerError.fileNotFound }
                    let cachedSource = try await capturedRead.source(readerFileManager: readerFileManager)
                    guard entryRequest.generationID.map({
                        cachedSource.generationID == $0
                    }) != false else {
                        throw ReaderPackageEntrySourceError.entryNotFound
                    }
                    let data = try cachedSource.readEntry(subpath: entryRequest.subpath)
                    let metadata = try cachedSource.mimeType(
                        subpath: entryRequest.subpath,
                        data: data
                    )
                    let response = ebookHTTPResponse(
                        url: url,
                        mimeType: metadata.mimeType,
                        byteCount: data.count,
                        textEncodingName: metadata.textEncodingName,
                        additionalHeaderFields: ["Cache-Control": "no-store"]
                    )
                    await { @MainActor in
                        self.finishActiveTask(
                            urlSchemeTask,
                            requiring: packageRead,
                            response: response,
                            data: data
                        )
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
                            self.finishActiveTask(
                                urlSchemeTask,
                                requiring: packageRead,
                                response: response
                            )
                        }()
                        return
                    }
                    await { @MainActor in
                        self.failActiveTask(urlSchemeTask, error: error)
                    }()
                }
            } else if url.pathComponents.starts(with: ["/", "load"]) {
                // Bundle file.
                if let fileUrl = Self.bundleURLFromWebURL(url),
                   let mimeType = Self.mimeType(ofFileAtUrl: fileUrl),
                   let data = try? await EbookViewerAssetCache.shared.data(for: fileUrl) {
                    guard !Task.isCancelled else { return }
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
                        self.finishActiveTask(
                            urlSchemeTask,
                            requiring: packageRead,
                            response: response,
                            data: data
                        )
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
                            try Task.checkCancellation()
                            await { @MainActor in
                                self.finishActiveTask(
                                    urlSchemeTask,
                                    requiring: packageRead,
                                    response: response,
                                    data: data
                                )
                            }()
                        } catch {
                            await { @MainActor in
                                self.failActiveTask(urlSchemeTask, error: error)
                            }()
                        }
                } else {
                    await { @MainActor in
                        self.failActiveTask(
                            urlSchemeTask,
                            error: CustomSchemeHandlerError.fileNotFound
                        )
                    }()
                }
            } else {
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

    private func capturePackageRead(
        _ request: URLRequest,
        readerFileManager: ReaderFileManager
    ) throws -> EbookCapturedPackageRead? {
        guard let url = request.url else { throw CustomSchemeHandlerError.fileNotFound }
        let sourceURL: URL
        let generationID: String?
        let sessionID: String?
        let suppliedID = try ebookPackageSessionID(in: url,
            header: request.value(forHTTPHeaderField: "X-Ebook-Package-Session"))
        switch url.path {
        case "/processed-section":
            guard let parsed = ebookDirectSectionRequest(from: url) else { throw CustomSchemeHandlerError.fileNotFound }
            // The document's URL must retain the capability for relative asset
            // ownership; accepting only a header here would lose that context.
            guard parsed.packageSessionID == suppliedID,
                  ebookPackageSourceURL(requestURL: url, mainDocumentURL: request.mainDocumentURL,
                    header: request.value(forHTTPHeaderField: "X-Ebook-Source-URL"))
                    == parsed.sourceURL else { throw CustomSchemeHandlerError.fileNotFound }
            sourceURL = parsed.sourceURL; sessionID = suppliedID; generationID = nil
        case "/entries", "/entry":
            guard let source = ebookPackageSourceURL(requestURL: url, mainDocumentURL: request.mainDocumentURL,
                header: request.value(forHTTPHeaderField: "X-Ebook-Source-URL")) else {
                throw CustomSchemeHandlerError.fileNotFound
            }
            sourceURL = source; sessionID = suppliedID; generationID = nil
        default:
            guard url.path.hasPrefix("/entry-source/") || url.path.hasPrefix("/entry-session/") else { return nil }
            guard let parsed = ebookPathBackedEntryRequest(from: url, mainDocumentURL: request.mainDocumentURL),
                  suppliedID == nil || suppliedID == parsed.packageSessionID,
                  ebookPackageSourceURL(requestURL: url, mainDocumentURL: request.mainDocumentURL,
                    header: request.value(forHTTPHeaderField: "X-Ebook-Source-URL"))
                    == parsed.sourceURL else {
                throw CustomSchemeHandlerError.fileNotFound
            }
            sourceURL = parsed.sourceURL; sessionID = parsed.packageSessionID; generationID = parsed.generationID
        }
        if let documentURL = request.mainDocumentURL, documentURL.path == "/processed-section" {
            guard let owner = ebookDirectSectionRequest(from: documentURL),
                  owner.packageSessionID == sessionID else {
                throw CustomSchemeHandlerError.fileNotFound
            }
        }
        // Bound sessions authorize their immutable snapshot even after the
        // physical path disappears. Legacy requests retain file-manager and
        // main-document authorization before any asynchronous source lookup.
        if sessionID == nil {
            guard ebookAuthorizedMainDocumentURL(for: request, readerFileManager: readerFileManager)
                    == sourceURL else { throw CustomSchemeHandlerError.fileNotFound }
        }
        return .init(access: try packageSessionBinding.capture(
            sourceURL: sourceURL, sessionID: sessionID, generationID: generationID))
    }

    @EbookURLSchemeActor
    private func validatedMainDocumentURL(
        for request: URLRequest,
        readerFileManager: ReaderFileManager
    ) -> URL? {
        return ebookAuthorizedMainDocumentURL(
            for: request,
            activePackageURL: activePackageURL,
            readerFileManager: readerFileManager
        )
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
