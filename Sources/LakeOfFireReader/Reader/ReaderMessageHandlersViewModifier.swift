import Foundation
import SwiftUI
import LakeOfFireWeb
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireContent
import LakeOfFireCore
@preconcurrency import WebKit
import OrderedCollections
import SwiftUIWebView
import RealmSwift
import RealmSwiftGaps
import LakeKit

private struct ReaderEBookInitialRestoreBridgeRequest {
    let requestID: String
    let cfi: String
    let fractionalCompletion: Double?
    let requestedLocator: String

    init?(restore: ReaderContentEbookInitialRestore?) {
        guard let restore else { return nil }
        let normalizedCFI = restore.cfi
        let normalizedFraction = restore.fractionalCompletion.map { Double($0) }
        let hasCFI = !normalizedCFI.isEmpty
        let hasFraction = (normalizedFraction ?? 0) > 0
        guard hasCFI || hasFraction else { return nil }
        requestID = UUID().uuidString
        cfi = normalizedCFI
        fractionalCompletion = normalizedFraction
        requestedLocator = hasCFI ? "cfi" : "fraction"
    }

    var javaScriptArgument: [String: any Sendable] {
        var payload: [String: any Sendable] = [
            "requestID": requestID,
            "requestedLocator": requestedLocator,
            "cfi": cfi,
        ]
        if let fractionalCompletion {
            payload["fractionalCompletion"] = fractionalCompletion
        }
        return payload
    }
}

public typealias ReaderShowOriginalWillBeginHandler = @MainActor @Sendable (_ contentURL: URL, _ pageURL: URL) async -> Void
public struct ReaderNavigationVisibilityChange: Sendable {
    public let shouldHide: Bool
    public let reason: String?
    public let source: String?
    public let direction: String?

    public init(shouldHide: Bool, reason: String?, source: String?, direction: String?) {
        self.shouldHide = shouldHide
        self.reason = reason
        self.source = source
        self.direction = direction
    }
}
public typealias ReaderNavigationVisibilityWillChangeHandler = @MainActor @Sendable (_ change: ReaderNavigationVisibilityChange) -> Void

private struct ReaderShowOriginalWillBeginHandlerKey: EnvironmentKey {
    static let defaultValue: ReaderShowOriginalWillBeginHandler? = nil
}

private struct ReaderNavigationVisibilityWillChangeHandlerKey: EnvironmentKey {
    static let defaultValue: ReaderNavigationVisibilityWillChangeHandler? = nil
}

public extension EnvironmentValues {
    var readerShowOriginalWillBeginHandler: ReaderShowOriginalWillBeginHandler? {
        get { self[ReaderShowOriginalWillBeginHandlerKey.self] }
        set { self[ReaderShowOriginalWillBeginHandlerKey.self] = newValue }
    }

    var readerNavigationVisibilityWillChangeHandler: ReaderNavigationVisibilityWillChangeHandler? {
        get { self[ReaderNavigationVisibilityWillChangeHandlerKey.self] }
        set { self[ReaderNavigationVisibilityWillChangeHandlerKey.self] = newValue }
    }
}

public extension View {
    func onReaderShowOriginalWillBegin(_ handler: @escaping ReaderShowOriginalWillBeginHandler) -> some View {
        environment(\.readerShowOriginalWillBeginHandler, handler)
    }

    func onReaderNavigationVisibilityWillChange(_ handler: @escaping ReaderNavigationVisibilityWillChangeHandler) -> some View {
        environment(\.readerNavigationVisibilityWillChangeHandler, handler)
    }
}

private struct ReaderSizeTrackingCacheEntry: Codable {
    let id: String
    let inlineSize: Double
    let blockSize: Double
    let blockStart: Double?
}

private struct ReaderSizeTrackingCacheSnapshot: Codable {
    let cacheKey: String
    let savedAt: Date
    let reason: String?
    let entries: [ReaderSizeTrackingCacheEntry]
}

private struct ReaderSizeTrackingCacheBucket: Codable {
    var snapshots: [ReaderSizeTrackingCacheSnapshot] = []

    init(snapshots: [ReaderSizeTrackingCacheSnapshot] = []) {
        self.snapshots = snapshots
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let snapshots = try? container.decode([ReaderSizeTrackingCacheSnapshot].self) {
            self.snapshots = snapshots
            return
        }
        if let legacyEntries = try? container.decode([ReaderSizeTrackingCacheEntry].self) {
            self.snapshots = [
                ReaderSizeTrackingCacheSnapshot(
                    cacheKey: "legacy",
                    savedAt: Date(),
                    reason: "legacy",
                    entries: legacyEntries
                )
            ]
            return
        }
        self.snapshots = []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(snapshots)
    }

    mutating func upsertSnapshot(_ snapshot: ReaderSizeTrackingCacheSnapshot, limit: Int) {
        snapshots.removeAll { $0.cacheKey == snapshot.cacheKey }
        snapshots.insert(snapshot, at: 0)
        if snapshots.count > limit {
            snapshots.removeLast(snapshots.count - limit)
        }
    }

    func snapshot(for cacheKey: String) -> ReaderSizeTrackingCacheSnapshot? {
        snapshots.first { $0.cacheKey == cacheKey }
    }
}

private let readerPaginationSizeTrackingCache = PersistedLRUCache<String, ReaderSizeTrackingCacheBucket>(
    namespace: "reader-pagination-size-tracking-cache-v2",
    version: 2,
    totalBytesLimit: 20 * 1024 * 1024,
    countLimit: 10_000,
    inlineStorageThreshold: 64 * 1024
)

/// Opens the shared pagination cache before a reader view needs to install its message handlers.
public func prewarmReaderPaginationSizeTrackingCache() {
    _ = readerPaginationSizeTrackingCache
}

@MainActor
fileprivate class ReaderMessageHandlers: ObservableObject, Identifiable {
    var forceReaderModeWhenAvailable: Bool
    
    var scriptCaller: WebViewScriptCaller
    var readerViewModel: ReaderViewModel
    var readerModeViewModel: ReaderModeViewModel
    var readerContent: ReaderContent
    var navigator: WebViewNavigator
    var hideNavigationDueToScroll: Binding<Bool>
    var showOriginalWillBeginHandler: ReaderShowOriginalWillBeginHandler?
    var navigationVisibilityWillChangeHandler: ReaderNavigationVisibilityWillChangeHandler?
    var colorScheme: ColorScheme

    private struct NavigationVisibilityEvent {
        let timestamp: Date
        let shouldHide: Bool
        let source: String?
        let direction: String?
    }

    private var lastNavigationVisibilityEvent: NavigationVisibilityEvent?
    private var lastNonEBookReaderProgress: (url: URL, fractionalCompletion: Float)?
    private let trackingSizeHistoryLimit = 10
    fileprivate var automaticReadabilityTask: Task<Void, Never>?

    nonisolated private func makeBucketKey(from cacheKey: String) -> String {
        let parts = cacheKey.split(separator: "|").map(String.init)
        var book: String?
        var href: String?
        for part in parts {
            if part.hasPrefix("book:") {
                book = String(part.dropFirst("book:".count))
            } else if part.hasPrefix("href:") {
                href = String(part.dropFirst("href:".count))
            }
        }
        if let book, let href {
            return "book:\(book)|href:\(href)"
        } else if let href {
            return "href:\(href)"
        } else {
            return "legacy:\(cacheKey)"
        }
    }

    private func urlsMatchIgnoringFragment(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs == rhs {
            return true
        }
        var lhsComponents = URLComponents(url: lhs, resolvingAgainstBaseURL: false)
        var rhsComponents = URLComponents(url: rhs, resolvingAgainstBaseURL: false)
        lhsComponents?.fragment = nil
        rhsComponents?.fragment = nil
        return lhsComponents?.url == rhsComponents?.url
    }

    private func canRunAutomaticReadability(for windowURL: URL?) -> Bool {
        let state = readerViewModel.state
        if let statusCode = state.mainFrameHTTPStatusCode,
           ReaderHTTPErrorRecoveryPolicy.isHTTPErrorStatus(statusCode) {
            return false
        }
        guard state.pageURL.scheme != "about",
              state.pageURL.scheme != "blob",
              state.pageURL.scheme != "ebook",
              !state.pageURL.isNativeReaderView else {
            return false
        }
        if let windowURL, !urlsMatchIgnoringFragment(windowURL, state.pageURL) {
            return false
        }
        return true
    }

    private func scheduleAutomaticReadability(reason: String, windowURL: URL?, frameInfo: WKFrameInfo) {
        guard canRunAutomaticReadability(for: windowURL) else { return }
        automaticReadabilityTask?.cancel()
        automaticReadabilityTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let delayNanoseconds: UInt64 = reason == "mutation" ? 3_000_000_000 : 100_000_000
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            guard canRunAutomaticReadability(for: windowURL) else { return }
            try? await scriptCaller.evaluateJavaScript(
                "window.manabi_readability?.()",
                in: frameInfo
            )
        }
    }

    @MainActor
    private func registerEbookViewerFrame(_ frameInfo: WKFrameInfo?) {
        guard let frameInfo else { return }
        let stateURL = readerViewModel.state.pageURL
        let pageURL = stateURL.isEBookURL ? stateURL : readerContent.pageURL
        _ = scriptCaller.addMultiTargetFrame(
            frameInfo,
            uuid: "ebook-viewer-frame:\(pageURL.absoluteString)",
            canonicalURL: pageURL
        )
    }

    @MainActor
    private func contentForWindowURL(
        _ windowURL: URL,
        source: String
    ) async throws -> (any ReaderContentProtocol)? {
        if let currentContent = readerContent.content,
           currentContent.url.matchesReaderURL(windowURL) {
            return currentContent
        }
        return try await ReaderViewModel.getContent(forURL: windowURL, source: source)
    }
    
    lazy var webViewMessageHandlers = {
        WebViewMessageHandlers([
            ("readerConsoleLog", { [weak self] message in
                guard let self else { return }
                guard let result = ConsoleLogMessage(fromMessage: message) else {
                    return
                }
                
                // Filter error logging based on URL
                let mainDocumentURL = message.frameInfo.request.mainDocumentURL
                if let mainDocumentURL {
                    guard mainDocumentURL.isEBookURL || mainDocumentURL.scheme == "blob" || mainDocumentURL.isFileURL || mainDocumentURL.isReaderFileURL || mainDocumentURL.isSnippetURL else { return }
                }
                
                let renderedMessage = result.message ?? result.arguments?.map { "\($0 ?? "nil")" }.joined(separator: " ") ?? "(no message)"
                Logger.shared.logger.log(
                    level: .init(rawValue: result.severity.lowercased()) ?? .info,
                    "[JS] \(result.severity.capitalized) [\(mainDocumentURL?.lastPathComponent ?? "(unknown URL)")]: \(renderedMessage)"
                )
            }),
            ("print", { @MainActor [weak self] message in
                guard let self else { return }
                if let logMessage = message.body as? String {
                    if logMessage.contains("\"reader.open:view-ready\"")
                        || logMessage.contains("\"loadEBook:posting-loaded\"")
                        || logMessage.contains("\"loadEBook:delayed-state:1s\"")
                        || logMessage.contains("\"loadEBook:delayed-state:3s\"")
                        || logMessage.contains("\"loadEBook:delayed-state:8s\"") {
                        registerEbookViewerFrame(message.frameInfo)
                    }
                    return
                }
                guard let payload = message.body as? [String: Any] else {
                    return
                }

                let logMessage = payload["message"] as? String ?? "SwiftReadability.print"
                _ = logMessage
            }),
            ("readerDocState", { @MainActor [weak self] message in
                guard let self else { return }
                guard let body = message.body as? [String: Any],
                      let href = body["href"] as? String,
                      let pageURL = URL(string: href)
                else { return }
                let hasReaderRenderReady = body["hasReaderRenderReady"] as? Bool ?? false
                if readerViewModel.state.hasReaderRenderReady != hasReaderRenderReady {
                    var state = readerViewModel.state
                    state.hasReaderRenderReady = hasReaderRenderReady
                    readerViewModel.state = state
                }
                guard hasReaderRenderReady, !pageURL.isReaderURLLoaderURL else { return }
                if readerContent.pageURL.matchesReaderURL(pageURL) {
                    readerContent.isRenderingReaderHTML = false
                }
                readerModeViewModel.handleRenderedReaderDocumentReady(
                    pageURL: pageURL,
                    hasReaderContent: true
                )
            }),
            ("readabilityNeedsUpdate", { @MainActor [weak self] message in
                guard let self else { return }
                guard let body = message.body as? [String: Any] else { return }
                let reason = body["reason"] as? String ?? "unknown"
                let windowURL = (body["windowURL"] as? String).flatMap(URL.init(string:))
                scheduleAutomaticReadability(
                    reason: reason,
                    windowURL: windowURL,
                    frameInfo: message.frameInfo
                )
            }),
            ("trackingBookKey", { [weak self] message in
                guard let body = message.body as? [String: Any],
                      let bookKey = body["bookKey"] as? String else { return }
                Task { @MainActor in
                    try? await self?.scriptCaller.evaluateJavaScript(
                        "window.paginationTrackingBookKey = bookKey;",
                        arguments: ["bookKey": bookKey],
                        in: message.frameInfo
                    )
                }
            }),
            ("trackingSizeCache", { [weak self] message in
                guard let self else { return }
                guard let body = message.body as? [String: Any],
                      let command = body["command"] as? String,
                      let key = body["key"] as? String else { return }

                let bucketKey = makeBucketKey(from: key)

                switch command {
                case "set":
                    if let entries = body["entries"] as? [[String: Any]] {
                        let decoded: [ReaderSizeTrackingCacheEntry] = entries.compactMap { dict in
                            guard let id = dict["id"] as? String,
                                  let inlineSize = dict["inlineSize"] as? Double,
                                  let blockSize = dict["blockSize"] as? Double else { return nil }
                            let blockStart = dict["blockStart"] as? Double
                            return ReaderSizeTrackingCacheEntry(
                                id: id,
                                inlineSize: inlineSize,
                                blockSize: blockSize,
                                blockStart: blockStart
                            )
                        }
                        var bucket = readerPaginationSizeTrackingCache.value(forKey: bucketKey) ?? ReaderSizeTrackingCacheBucket()
                        let snapshot = ReaderSizeTrackingCacheSnapshot(
                            cacheKey: key,
                            savedAt: Date(),
                            reason: body["reason"] as? String,
                            entries: decoded
                        )
                        bucket.upsertSnapshot(snapshot, limit: trackingSizeHistoryLimit)
                        readerPaginationSizeTrackingCache.setValue(bucket, forKey: bucketKey)
                    }
                case "get":
                    guard let requestId = body["requestId"] as? String else { return }
                    if let bucket = readerPaginationSizeTrackingCache.value(forKey: bucketKey),
                       let cached = bucket.snapshot(for: key)?.entries {
                        do {
                            let data = try JSONEncoder().encode(cached)
                            if let json = String(data: data, encoding: .utf8) {
                                let js = "window.manabiResolveTrackingSizeCache(requestId, \(json))"
                                Task { @MainActor in
                                    try? await self.scriptCaller.evaluateJavaScript(
                                        js,
                                        arguments: ["requestId": requestId],
                                        in: message.frameInfo
                                    )
                                }
                            }
                        } catch {
                            // Ignore encoding errors.
                        }
                    } else {
                        Task { @MainActor in
                            try? await self.scriptCaller.evaluateJavaScript(
                                "window.manabiResolveTrackingSizeCache(requestId, null)",
                                arguments: ["requestId": requestId],
                                in: message.frameInfo
                            )
                        }
                    }
                default:
                    break
                }
            }),
            ("readerOnError", { [weak self] message in
                guard let self else { return }
                guard let result = ReaderOnErrorMessage(fromMessage: message) else {
                    return
                }
                
                // Filter error logging based on URL
                let mainDocumentURL = message.frameInfo.request.mainDocumentURL
                let isReaderErrorSource =
                    result.source.isEBookURL
                    || result.source.scheme == "blob"
                    || result.source.isFileURL
                    || result.source.isReaderFileURL
                    || result.source.isSnippetURL
                    || mainDocumentURL?.isEBookURL == true
                    || mainDocumentURL?.isReaderFileURL == true
                guard isReaderErrorSource else { return }
                let source = result.source.absoluteString
                let messageText = result.message ?? "unknown message"
                let errorText = result.error ?? "n/a"
                Logger.shared.logger.error("[JS] Error: \(messageText) @ \(source):\(result.lineno ?? -1):\(result.colno ?? -1) — error: \(errorText)")
            }),
            ("ebookNavigationVisibility", { @MainActor [weak self] message in
                guard let self else { return }
                guard let payload = message.body as? [String: Any],
                      let shouldHide = payload["hideNavigationDueToScroll"] as? Bool else {
                    return
                }
                let source = payload["source"] as? String
                let direction = payload["direction"] as? String
                if source == "toolbar.blankTap" {
                    navigationVisibilityWillChangeHandler?(
                        ReaderNavigationVisibilityChange(
                            shouldHide: shouldHide,
                            reason: nil,
                            source: source,
                            direction: direction
                        )
                    )
                    lastNavigationVisibilityEvent = .init(
                        timestamp: Date(),
                        shouldHide: shouldHide,
                        source: source,
                        direction: direction
                    )
                    return
                }
                if !shouldHide,
                   source?.contains("page-turn") == true,
                   direction != "backward" {
                    navigationVisibilityWillChangeHandler?(
                        ReaderNavigationVisibilityChange(
                            shouldHide: shouldHide,
                            reason: nil,
                            source: source,
                            direction: direction
                        )
                    )
                    lastNavigationVisibilityEvent = .init(
                        timestamp: Date(),
                        shouldHide: shouldHide,
                        source: source,
                        direction: direction
                    )
                    return
                }
                setHideNavigationDueToScroll(
                    shouldHide,
                    reason: nil,
                    source: source,
                    direction: direction
                )
                lastNavigationVisibilityEvent = .init(
                    timestamp: Date(),
                    shouldHide: shouldHide,
                    source: source,
                    direction: direction
                )
            }),
            ("readabilityFramePing", { @MainActor [weak self] message in
                guard let self else { return }
                guard let uuid = (message.body as? [String: String])?["uuid"], let windowURLRaw = (message.body as? [String: String])?["windowURL"] as? String, let windowURL = URL(string: windowURLRaw) else {
                    debugPrint("Unexpectedly received readableFramePing message without valid parameters", message.body as? [String: String])
                    return
                }
                guard !windowURL.isNativeReaderView,
                      let content = try? await contentForWindowURL(windowURL, source: "readabilityFramePing") else { return }
                if await readerViewModel.scriptCaller.addMultiTargetFrame(message.frameInfo, uuid: uuid) {
                    readerViewModel.refreshSettingsInWebView(content: content, reason: "readability-frame-ping")
                }
            }),
            ("readabilityModeUnavailable", { @MainActor [weak self] message in
                guard let self else { return }
                guard let result = ReaderModeUnavailableMessage(fromMessage: message) else {
                    return
                }
                // TODO: Reuse guard code across this and readabilityParsed
                guard let url = result.windowURL,
                      url == readerViewModel.state.pageURL else {
                    return
                }
                guard readabilityMessageCanRepresentTopLevelDocument(
                    pageURL: result.pageURL,
                    windowURL: result.windowURL,
                    isMainFrame: message.frameInfo.isMainFrame
                ) else {
                    return
                }
                if ReaderHTTPErrorRecoveryPolicy.shouldPreserveReaderState(
                    isMainFrame: message.frameInfo.isMainFrame,
                    statusCode: readerViewModel.state.mainFrameHTTPStatusCode
                ) {
                    return
                }
                if readerModeViewModel.isReaderModeLoading || readerModeViewModel.isReaderModeHandlingURL(url) {
                    return
                }
                guard let content = try? await contentForWindowURL(url, source: "readabilityModeUnavailable") else {
                    return
                }
                if content.rssContainsFullContent && !content.isReaderModeByDefault {
                    try? await scriptCaller.evaluateJavaScript("""
                        if (document.body) {
                            document.body.dataset.mnbReaderModeAvailable = 'true';
                            document.body.dataset.mnbReaderModeAvailableConfidently = 'true';
                            document.body.dataset.mnbReaderModeAvailableFor = window.location.href;
                            document.body.dataset.isNextLoadInReaderMode = 'false';
                        }
                        """)
                    try? await ReaderContentLoader.updateContent(url: url) { object in
                        var didChange = false
                        if !object.isReaderModeAvailable {
                            object.isReaderModeAvailable = true
                            didChange = true
                        }
                        if !object.isReaderModeOfferHidden {
                            object.isReaderModeOfferHidden = true
                            didChange = true
                        }
                        return didChange
                    }
                    return
                }
                if !message.frameInfo.isMainFrame, readerModeViewModel.readabilityContent != nil, readerModeViewModel.readabilityContainerFrameInfo != message.frameInfo {
                    // Don't override a parent window readability result.
                    return
                }
                guard !url.isReaderURLLoaderURL else { return }
                
                try? await scriptCaller.evaluateJavaScript("""
                        if (document.body) {
                            document.body.dataset.isNextLoadInReaderMode = 'false';
                        }
                        """)
                
                if readerModeViewModel.isReaderMode {
                    readerModeViewModel.isReaderMode = false
                }
                
                do {
                    try await ReaderContentLoader.updateContent(url: url) { object in
                        guard object.isReaderModeAvailable else { return false }
                        object.isReaderModeAvailable = false
                        return true
                    }
                    
                    try await { @RealmBackgroundActor in
                        if let historyRecord = try await HistoryRecord.get(forURL: url) {
                            try await historyRecord.refreshDemotedStatus()
                        }
                    }()
                } catch {
                    print(error)
                }
            }),
            ("readabilityParsed", { @MainActor [weak self] message in
                guard let self else { return }
                guard let result = ReadabilityParsedMessage(fromMessage: message) else {
                    return
                }
                guard let url = result.windowURL,
                      url == readerViewModel.state.pageURL,
                      let content = try? await contentForWindowURL(url, source: "readabilityParsed") else {
                    return
                }
                guard readabilityMessageCanRepresentTopLevelDocument(
                    pageURL: result.pageURL,
                    windowURL: result.windowURL,
                    isMainFrame: message.frameInfo.isMainFrame
                ) else {
                    return
                }
                if ReaderHTTPErrorRecoveryPolicy.shouldPreserveReaderState(
                    isMainFrame: message.frameInfo.isMainFrame,
                    statusCode: readerViewModel.state.mainFrameHTTPStatusCode
                ) {
                    return
                }
                if !message.frameInfo.isMainFrame, readerModeViewModel.readabilityContent != nil, readerModeViewModel.readabilityContainerFrameInfo != message.frameInfo {
                    // Don't override a parent window readability result.
                    return
                }
                guard !result.outputHTML.isEmpty else {
                    if content.rssContainsFullContent && !content.isReaderModeByDefault {
                        try? await ReaderContentLoader.updateContent(url: url) { object in
                            var didChange = false
                            if !object.isReaderModeAvailable {
                                object.isReaderModeAvailable = true
                                didChange = true
                            }
                            if !object.isReaderModeOfferHidden {
                                object.isReaderModeOfferHidden = true
                                didChange = true
                            }
                            return didChange
                        }
                        return
                    }
                    try? await ReaderContentLoader.updateContent(url: url) { object in
                        guard object.isReaderModeAvailable else { return false }
                        object.isReaderModeAvailable = false
                        return true
                    }
                    return
                }
                
                guard !url.isNativeReaderView else { return }
                let hasParsedPublicationDate = result.outputHTML.contains("id=\"reader-publication-date\"")
                let publicationDateFallback = hasParsedPublicationDate
                    ? nil
                    : await readerContentPublicationDateFallback(for: content)
                let resolvedOutputHTML = publicationDateFallback.map {
                    buildCanonicalReadabilityHTML(
                        title: result.title,
                        byline: result.byline,
                        publishedTime: $0,
                        content: result.content,
                        contentURL: content.url
                    )
                } ?? result.outputHTML
                if publicationDateFallback != nil {
                }
                let shouldPreserveFullContentOriginal = content.rssContainsFullContent && !content.isReaderModeByDefault
                if shouldPreserveFullContentOriginal {
                    readerModeViewModel.readabilityContent = nil
                    readerModeViewModel.readabilityContainerSelector = nil
                    readerModeViewModel.readabilityContainerFrameInfo = nil
                } else {
                    readerModeViewModel.readabilityContent = resolvedOutputHTML
                    readerModeViewModel.readabilityContainerSelector = result.readabilityContainerSelector
                    readerModeViewModel.readabilityContainerFrameInfo = message.frameInfo
                }
                if !shouldPreserveFullContentOriginal && (content.isReaderModeByDefault || forceReaderModeWhenAvailable) {
                    readerModeViewModel.showReaderView(
                        readerContent: readerContent,
                        scriptCaller: scriptCaller
                    )
                } else if resolvedOutputHTML.lazy.filter({ String($0).hasKanji || String($0).hasKana }).prefix(51).count > 50 {
                    try? await scriptCaller.evaluateJavaScript("""
                        if (document.body) {
                            document.body.dataset.mnbReaderModeAvailableConfidently = 'true';
                            document.body.dataset.isNextLoadInReaderMode = 'false';
                        }
                        """)
                } else {
                    try? await scriptCaller.evaluateJavaScript("""
                        if (document.body) {
                            document.body.dataset.isNextLoadInReaderMode = 'false';
                        }
                        """)
                }
                
                do {
                    try await ReaderContentLoader.updateContent(url: url) { object in
                        var didChange = false
                        if !object.isReaderModeAvailable {
                            object.isReaderModeAvailable = true
                            didChange = true
                        }
                        if shouldPreserveFullContentOriginal && !object.isReaderModeOfferHidden {
                            object.isReaderModeOfferHidden = true
                            didChange = true
                        }
                        return didChange
                    }
                    await readerContent.content?.realm?.asyncRefresh()
                    if let observedObject = readerContent.content as? (Object & ReaderContentProtocol),
                       observedObject.url.matchesReaderURL(url),
                       !observedObject.isReaderModeAvailable,
                       let observedRealm = observedObject.realm {
                        try await observedRealm.asyncWrite {
                            observedObject.isReaderModeAvailable = true
                            if shouldPreserveFullContentOriginal && !observedObject.isReaderModeOfferHidden {
                                observedObject.isReaderModeOfferHidden = true
                            }
                            observedObject.refreshChangeMetadata(explicitlyModified: true)
                        }
                    }
                    
                    try await { @RealmBackgroundActor in
                        if let historyRecord = try await HistoryRecord.get(forURL: url) {
                            try await historyRecord.refreshDemotedStatus()
                        }
                    }()
                } catch {
                    print(error)
                }
                await readerContent.content?.realm?.asyncRefresh()
                readerContent.refreshObservedContentState()
            }),
            ("showOriginal", { @MainActor [weak self] _ in
                guard let self else { return }
                do {
                    try await showOriginal()
                } catch {
                    print(error)
                }
            }),
            //            "youtubeCaptions": { message in
            //                Task { @MainActor in
            //                    guard let result = YoutubeCaptionsMessage(fromMessage: message) else { return }
            //                    debugPrint(result)
            //                }
            //            },
            ("rssURLs", { @MainActor [weak self] message in
                guard let self else { return }
                do {
                    guard let result = RSSURLsMessage(fromMessage: message) else { return }
                    guard let windowURL = result.windowURL,
                          !windowURL.isNativeReaderView,
                          let _ = try await contentForWindowURL(windowURL, source: "rssURLs") else { return }
                    let pairs = result.rssURLs.prefix(10)
                    let urls = pairs.compactMap { $0.first }.compactMap { URL(string: $0) }
                    let titles = pairs.map { $0.last ?? $0.first ?? "" }
                    try await ReaderContentLoader.updateContent(url: windowURL) { object in
                        let existingURLs = Array(object.rssURLs)
                        let existingTitles = Array(object.rssTitles)
                        let isRSSAvailable = !urls.isEmpty
                        guard existingURLs != urls
                            || existingTitles != titles
                            || object.isRSSAvailable != isRSSAvailable else {
                            return false
                        }
                        object.rssURLs.removeAll()
                        object.rssTitles.removeAll()
                        object.rssURLs.append(objectsIn: urls)
                        object.rssTitles.append(objectsIn: titles)
                        object.isRSSAvailable = isRSSAvailable
                        return true
                    }
                } catch {
                    print(error)
                }
            }),
            ("pageMetadataUpdated", { @MainActor [weak self] message in
                guard let self else { return }
                do {
                    guard let result = PageMetadataUpdatedMessage(fromMessage: message) else { return }
                    guard urlsMatchWithoutHash(result.url, readerViewModel.state.pageURL) else { return }
                    try await readerViewModel.pageMetadataUpdated(
                        title: result.title,
                        author: result.author
                    )
                } catch {
                    print(error)
                }
            }),
            ("imageUpdated", { @RealmBackgroundActor [weak self] message in
                guard let self else { return }
                do {
                    guard let result = ImageUpdatedMessage(fromMessage: message) else { return }
                    guard let url = result.mainDocumentURL, !url.isNativeReaderView else { return }
                    let contents = try await ReaderContentLoader.loadAll(url: url)
                    for content in contents {
                        guard content.imageUrl != result.newImageURL else { continue }
                        //                        await content.realm?.asyncRefresh()
                        try await content.realm?.asyncWrite {
                            content.imageUrl = result.newImageURL
                            content.refreshChangeMetadata(explicitlyModified: true)
                        }
                    }
                } catch {
                    print(error)
                }
            }),
            ("ebookViewerInitialized", { @MainActor [weak self] message in
                guard let self else { return }
                registerEbookViewerFrame(message.frameInfo)
                let stateURL = readerViewModel.state.pageURL
                let url = stateURL.isEBookURL ? stateURL : readerContent.pageURL
                if let scheme = url.scheme,
                   (scheme == "ebook" || scheme == "ebook-url"),
                   url.absoluteString.hasPrefix("\(scheme)://"),
                   url.isEBookURL,
                   let loaderURL = URL(string: "\(scheme)://\(url.absoluteString.dropFirst("\(scheme)://".count))") {
                    _ = try? await scriptCaller.evaluateJavaScript(
                        "window.manabiMarkEbookViewerInitializedAck && window.manabiMarkEbookViewerInitializedAck()",
                        in: message.frameInfo
                    )
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let initialRestore = try? await ReaderContentReadingProgressLoader.ebookInitialRestoreLoader?(url)
                        var loadArguments: [String: any Sendable] = [
                            "url": loaderURL.absoluteString,
                            "layoutMode": UserDefaults.standard.string(forKey: "ebookViewerLayout") ?? "paginated",
                        ]
                        let readerFontSize = UserDefaults.standard.object(forKey: "readerFontSize") as? Double ?? 16
                        loadArguments["readerPresentationState"] = [
                            "colorScheme": colorScheme == .dark ? "dark" : "light",
                            "lightModeTheme": UserDefaults.standard.string(forKey: "lightModeTheme") ?? "white",
                            "darkModeTheme": UserDefaults.standard.string(forKey: "darkModeTheme") ?? "black",
                            "readerFontSize": readerFontSize,
                            "readerContentRTSize": readerFontSize * 0.46,
                            "readerBoldText": UserDefaults.standard.object(forKey: "readerBoldText") as? Bool ?? false,
                            "maxWidthOverride": readerAdaptiveMaxWidthOverrideCSSValue(readerFontSize: readerFontSize),
                            "writingDirection": "original",
                        ]
                        let initialRestoreRequest = ReaderEBookInitialRestoreBridgeRequest(restore: initialRestore)
                        loadArguments["initialRestore"] = initialRestoreRequest?.javaScriptArgument ?? NSNull()
                        loadArguments["initialRestoreRequestID"] = initialRestoreRequest?.requestID ?? "nil"
                        loadArguments["initialRestoreRequestedLocator"] = initialRestoreRequest?.requestedLocator ?? "none"
                        do {
                            _ = try await scriptCaller.evaluateJavaScript(
                                """
                                window.loadEBook({ url, layoutMode, initialRestore, readerPresentationState });
                                """,
                                arguments: loadArguments,
                                in: message.frameInfo
                            )
                        } catch {
                            let loaderURLString = loaderURL.absoluteString
                            Logger.shared.logger.error("Ebook viewer load failed for \(loaderURLString): \(String(describing: error))")
                        }
                    }
                }
            }),
            ("updateReadingProgress", { @MainActor [weak self] message in
                guard let self else { return }
                guard let result = FractionalCompletionMessage(fromMessage: message) else { return }
                handleNavigationVisibility(for: result)
            }),
            ("videoStatus", { @RealmBackgroundActor [weak self] message in
                guard let self else { return }
                do {
                    guard let result = VideoStatusMessage(fromMessage: message) else { return }
                    //                    debugPrint("!!", result)
                    if let pageURL = result.pageURL {
                        _ = try await MediaStatus.getOrCreate(url: pageURL)
                    }
                } catch {
                    print(error)
                }
            })
        ])
    }()
    
    init(
        forceReaderModeWhenAvailable: Bool,
        scriptCaller: WebViewScriptCaller,
        readerViewModel: ReaderViewModel,
        readerModeViewModel: ReaderModeViewModel,
        readerContent: ReaderContent,
        navigator: WebViewNavigator,
        hideNavigationDueToScroll: Binding<Bool>,
        showOriginalWillBeginHandler: ReaderShowOriginalWillBeginHandler?,
        navigationVisibilityWillChangeHandler: ReaderNavigationVisibilityWillChangeHandler?,
        colorScheme: ColorScheme
    ) {
        self.forceReaderModeWhenAvailable = forceReaderModeWhenAvailable
        self.scriptCaller = scriptCaller
        self.readerViewModel = readerViewModel
        self.readerModeViewModel = readerModeViewModel
        self.readerContent = readerContent
        self.navigator = navigator
        self.hideNavigationDueToScroll = hideNavigationDueToScroll
        self.showOriginalWillBeginHandler = showOriginalWillBeginHandler
        self.navigationVisibilityWillChangeHandler = navigationVisibilityWillChangeHandler
        self.colorScheme = colorScheme
    }

    func update(
        forceReaderModeWhenAvailable: Bool,
        scriptCaller: WebViewScriptCaller,
        readerViewModel: ReaderViewModel,
        readerModeViewModel: ReaderModeViewModel,
        readerContent: ReaderContent,
        navigator: WebViewNavigator,
        hideNavigationDueToScroll: Binding<Bool>,
        showOriginalWillBeginHandler: ReaderShowOriginalWillBeginHandler?,
        navigationVisibilityWillChangeHandler: ReaderNavigationVisibilityWillChangeHandler?,
        colorScheme: ColorScheme
    ) {
        self.forceReaderModeWhenAvailable = forceReaderModeWhenAvailable
        self.scriptCaller = scriptCaller
        self.readerViewModel = readerViewModel
        self.readerModeViewModel = readerModeViewModel
        self.readerContent = readerContent
        self.navigator = navigator
        self.hideNavigationDueToScroll = hideNavigationDueToScroll
        self.showOriginalWillBeginHandler = showOriginalWillBeginHandler
        self.navigationVisibilityWillChangeHandler = navigationVisibilityWillChangeHandler
        self.colorScheme = colorScheme
    }
    
    // MARK: Readability
    
    @MainActor
    func showOriginal() async throws {
        let contentURL = readerContent.content?.url
            ?? ReaderContentLoader.getContentURL(fromLoaderURL: readerContent.pageURL)
            ?? readerContent.pageURL
        let hasCapturedReadabilityContent =
            readerModeViewModel.readabilityContent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let shouldRestoreStoredFullContent = readerContent.content?.rssContainsFullContent == true
        if shouldRestoreStoredFullContent {
            readerModeViewModel.readabilityContent = nil
            readerModeViewModel.readabilityContainerSelector = nil
            readerModeViewModel.readabilityContainerFrameInfo = nil
        }
        await showOriginalWillBeginHandler?(contentURL, readerContent.pageURL)
        try await ReaderContentLoader.updateContent(url: contentURL) { object in
            let update = ReaderHTTPErrorRecoveryPolicy.showOriginalFlagUpdate(
                currentFlags: ReaderHTTPErrorRecoveryPolicy.ReaderModeFlags(
                    isReaderModeByDefault: object.isReaderModeByDefault,
                    isReaderModeAvailable: object.isReaderModeAvailable,
                    isReaderModeOfferHidden: object.isReaderModeOfferHidden
                ),
                hasCapturedReadabilityContent: hasCapturedReadabilityContent,
                hasStoredFullContent: object.rssContainsFullContent
            )
            object.isReaderModeByDefault = update.flags.isReaderModeByDefault
            object.isReaderModeAvailable = update.flags.isReaderModeAvailable
            object.isReaderModeOfferHidden = update.flags.isReaderModeOfferHidden
            return update.didChange
        }
        await readerContent.content?.realm?.asyncRefresh()
        navigator.reload()
    }

    private func setHideNavigationDueToScroll(
        _ shouldHide: Bool,
        reason: String? = nil,
        source: String? = nil,
        direction: String? = nil
    ) {
        let previousValue = hideNavigationDueToScroll.wrappedValue
        let isPageTurnVisibilityChange = source?.contains("page-turn") == true
        guard previousValue != shouldHide else {
            if isPageTurnVisibilityChange {
                navigationVisibilityWillChangeHandler?(
                    ReaderNavigationVisibilityChange(
                        shouldHide: shouldHide,
                        reason: reason,
                        source: source,
                        direction: direction
                    )
                )
            }
            return
        }
        navigationVisibilityWillChangeHandler?(
            ReaderNavigationVisibilityChange(
                shouldHide: shouldHide,
                reason: reason,
                source: source,
                direction: direction
            )
        )
        if isPageTurnVisibilityChange {
            hideNavigationDueToScroll.wrappedValue = shouldHide
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                hideNavigationDueToScroll.wrappedValue = shouldHide
            }
        }
    }

    private func handleNavigationVisibility(for result: FractionalCompletionMessage) {
        let normalizedReason = result.reason.lowercased()
        let messageURL = result.mainDocumentURL ?? readerContent.pageURL
        let isEBookProgressMessage = messageURL.isEBookURL || readerContent.pageURL.isEBookURL
        if !isEBookProgressMessage,
           normalizedReason == "navigation" {
            lastNonEBookReaderProgress = (messageURL, result.fractionalCompletion)
            return
        }
        if !isEBookProgressMessage,
           normalizedReason == "live-scroll" {
            let previousProgress = lastNonEBookReaderProgress
            lastNonEBookReaderProgress = (messageURL, result.fractionalCompletion)
            if let previousProgress,
               previousProgress.url == messageURL,
               previousProgress.fractionalCompletion != result.fractionalCompletion {
                let isForwardProgress = result.fractionalCompletion > previousProgress.fractionalCompletion
                setHideNavigationDueToScroll(
                    isForwardProgress,
                    reason: normalizedReason,
                    source: "updateReadingProgress",
                    direction: isForwardProgress ? "forward" : "backward"
                )
            }
            return
        }
        if ["navigation", "selection", "live-scroll"].contains(normalizedReason) {
            let recentPageMotionHide = lastNavigationVisibilityEvent.flatMap { event -> (age: TimeInterval, source: String?, direction: String?)? in
                let isPageMotion =
                    event.source?.contains("page-turn") == true
                    || event.source?.contains("relocate") == true
                    || event.source?.contains("goTo") == true
                guard event.shouldHide, isPageMotion else { return nil }
                return (Date().timeIntervalSince(event.timestamp), event.source, event.direction)
            }
            if normalizedReason == "navigation",
               hideNavigationDueToScroll.wrappedValue,
               let recentPageMotionHide,
               recentPageMotionHide.age >= 0,
               recentPageMotionHide.age < 5.0 {
                return
            }
            setHideNavigationDueToScroll(
                false,
                reason: normalizedReason,
                source: "updateReadingProgress",
                direction: nil
            )
        }
    }
}

internal struct ReaderMessageHandlersViewModifier: ViewModifier {
    var forceReaderModeWhenAvailable = false
    var hideNavigationDueToScroll: Binding<Bool> = .constant(false)
    
    @AppStorage("ebookViewerLayout") internal var ebookViewerLayout = "paginated"
    
    @EnvironmentObject internal var scriptCaller: WebViewScriptCaller
    @EnvironmentObject internal var readerViewModel: ReaderViewModel
    @EnvironmentObject internal var readerModeViewModel: ReaderModeViewModel
    @EnvironmentObject internal var readerContent: ReaderContent
    @Environment(\.webViewMessageHandlers) internal var webViewMessageHandlers
    @Environment(\.webViewNavigator) internal var navigator: WebViewNavigator
    @Environment(\.readerShowOriginalWillBeginHandler) internal var showOriginalWillBeginHandler
    @Environment(\.readerNavigationVisibilityWillChangeHandler) internal var navigationVisibilityWillChangeHandler
    @Environment(\.colorScheme) internal var colorScheme
    
    func body(content: Content) -> some View {
        ReaderMessageHandlersInstaller(
            content: content,
            forceReaderModeWhenAvailable: forceReaderModeWhenAvailable,
            scriptCaller: scriptCaller,
            readerViewModel: readerViewModel,
            readerModeViewModel: readerModeViewModel,
            readerContent: readerContent,
            navigator: navigator,
            hideNavigationDueToScroll: hideNavigationDueToScroll,
            showOriginalWillBeginHandler: showOriginalWillBeginHandler,
            navigationVisibilityWillChangeHandler: navigationVisibilityWillChangeHandler,
            colorScheme: colorScheme,
            webViewMessageHandlers: webViewMessageHandlers
        )
    }
}

@MainActor
private struct ReaderMessageHandlersInstaller<Content: View>: View {
    let content: Content
    var forceReaderModeWhenAvailable: Bool
    var scriptCaller: WebViewScriptCaller
    var readerViewModel: ReaderViewModel
    var readerModeViewModel: ReaderModeViewModel
    var readerContent: ReaderContent
    var navigator: WebViewNavigator
    var hideNavigationDueToScroll: Binding<Bool>
    var showOriginalWillBeginHandler: ReaderShowOriginalWillBeginHandler?
    var navigationVisibilityWillChangeHandler: ReaderNavigationVisibilityWillChangeHandler?
    var colorScheme: ColorScheme
    var webViewMessageHandlers: WebViewMessageHandlers

    @StateObject private var readerMessageHandlers: ReaderMessageHandlers
    @State private var lastPushedHideNavigationDueToScroll: Bool?
    @State private var lastPushedHideNavigationPageURL: URL?

    init(
        content: Content,
        forceReaderModeWhenAvailable: Bool,
        scriptCaller: WebViewScriptCaller,
        readerViewModel: ReaderViewModel,
        readerModeViewModel: ReaderModeViewModel,
        readerContent: ReaderContent,
        navigator: WebViewNavigator,
        hideNavigationDueToScroll: Binding<Bool>,
        showOriginalWillBeginHandler: ReaderShowOriginalWillBeginHandler?,
        navigationVisibilityWillChangeHandler: ReaderNavigationVisibilityWillChangeHandler?,
        colorScheme: ColorScheme,
        webViewMessageHandlers: WebViewMessageHandlers
    ) {
        self.content = content
        self.forceReaderModeWhenAvailable = forceReaderModeWhenAvailable
        self.scriptCaller = scriptCaller
        self.readerViewModel = readerViewModel
        self.readerModeViewModel = readerModeViewModel
        self.readerContent = readerContent
        self.navigator = navigator
        self.hideNavigationDueToScroll = hideNavigationDueToScroll
        self.showOriginalWillBeginHandler = showOriginalWillBeginHandler
        self.navigationVisibilityWillChangeHandler = navigationVisibilityWillChangeHandler
        self.colorScheme = colorScheme
        self.webViewMessageHandlers = webViewMessageHandlers
        _readerMessageHandlers = StateObject(wrappedValue: ReaderMessageHandlers(
            forceReaderModeWhenAvailable: forceReaderModeWhenAvailable,
            scriptCaller: scriptCaller,
            readerViewModel: readerViewModel,
            readerModeViewModel: readerModeViewModel,
            readerContent: readerContent,
            navigator: navigator,
            hideNavigationDueToScroll: hideNavigationDueToScroll,
            showOriginalWillBeginHandler: showOriginalWillBeginHandler,
            navigationVisibilityWillChangeHandler: navigationVisibilityWillChangeHandler,
            colorScheme: colorScheme
        ))
    }

    var body: some View {
        content
            .environment(\.webViewMessageHandlers, readerMessageHandlers.webViewMessageHandlers + webViewMessageHandlers)
            .task { @MainActor in
                readerMessageHandlers.update(
                    forceReaderModeWhenAvailable: forceReaderModeWhenAvailable,
                    scriptCaller: scriptCaller,
                    readerViewModel: readerViewModel,
                    readerModeViewModel: readerModeViewModel,
                    readerContent: readerContent,
                    navigator: navigator,
                    hideNavigationDueToScroll: hideNavigationDueToScroll,
                    showOriginalWillBeginHandler: showOriginalWillBeginHandler,
                    navigationVisibilityWillChangeHandler: navigationVisibilityWillChangeHandler,
                    colorScheme: colorScheme
                )
            }
            .task(id: hideNavigationDueToScroll.wrappedValue) {
                await pushHideNavigationStateToWebView(reason: "binding", force: false)
            }
            .task(id: colorScheme) { @MainActor in
                readerMessageHandlers.colorScheme = colorScheme
            }
            .task(id: readerContent.pageURL) {
                await pushHideNavigationStateToWebView(reason: "pageURL", force: true)
            }
    }

    @MainActor
    private func pushHideNavigationStateToWebView(reason: String, force: Bool) async {
        let pageURL = readerContent.pageURL
        guard pageURL.isEBookURL else { return }
        let shouldHide = hideNavigationDueToScroll.wrappedValue
        if reason == "binding", !force, !shouldHide {
            await Task.yield()
            let settledPageURL = readerContent.pageURL
            let settledShouldHide = hideNavigationDueToScroll.wrappedValue
            if settledPageURL != pageURL || settledShouldHide != shouldHide {
                return
            }
        }
        let nowMs = Date().timeIntervalSince1970 * 1000
        let lastNativeLookupTapAtMs = UserDefaults.standard.double(forKey: "MAY15LastNativeLookupTapAtMs")
        let nativeLookupTapAgeMs = lastNativeLookupTapAtMs > 0 ? nowMs - lastNativeLookupTapAtMs : nil
        let isRecentNativeLookupHide =
            reason == "binding"
            && shouldHide
            && lastNativeLookupTapAtMs > 0
            && nowMs - lastNativeLookupTapAtMs < 750
        if isRecentNativeLookupHide {
            return
        }
        let boolLiteral = shouldHide ? "true" : "false"
        do {
            try await scriptCaller.evaluateJavaScript("window.manabiSetHideNavigationDueToScroll?.(\(boolLiteral), 'swift.bindingPush');")
            lastPushedHideNavigationDueToScroll = shouldHide
            lastPushedHideNavigationPageURL = pageURL
        } catch {
            // Ignore boot timing races.
        }
    }
}
