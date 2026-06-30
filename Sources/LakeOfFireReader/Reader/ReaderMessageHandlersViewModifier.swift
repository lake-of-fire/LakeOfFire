import SwiftUI
@preconcurrency import WebKit
import OrderedCollections
import SwiftUIWebView
import RealmSwift
import RealmSwiftGaps
import LakeKit
import LakeOfFireContent
import LakeOfFireCore
import PersistedLRUCacheHybrid

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

@MainActor
fileprivate class ReaderMessageHandlers: Identifiable {
    var forceReaderModeWhenAvailable: Bool

    var scriptCaller: WebViewScriptCaller
    var readerViewModel: ReaderViewModel
    var readerModeViewModel: ReaderModeViewModel
    var readerContent: ReaderContent
    var navigator: WebViewNavigator
    var hideNavigationDueToScroll: Binding<Bool>
    var showOriginalWillBeginHandler: ReaderShowOriginalWillBeginHandler?
    var navigationVisibilityWillChangeHandler: ReaderNavigationVisibilityWillChangeHandler?

    private struct NavigationVisibilityEvent {
        let timestamp: Date
        let shouldHide: Bool
        let source: String?
        let direction: String?
    }

    private var lastNavigationVisibilityEvent: NavigationVisibilityEvent?
    private let trackingSizeCache = PersistedLRUCache<String, ReaderSizeTrackingCacheBucket>(
        namespace: "reader-pagination-size-tracking-cache-v2",
        version: 2,
        totalBytesLimit: 20 * 1024 * 1024,
        countLimit: 10_000,
        inlineStorageThreshold: 64 * 1024
    )
    private let trackingSizeHistoryLimit = 10
    fileprivate var ebookBootstrapFallbackTask: Task<Void, Never>?
    fileprivate var ebookBootstrapFallbackURL: URL?
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
    fileprivate func scheduleEbookViewerInitializationFallback(in frameInfo: WKFrameInfo? = nil) {
        registerEbookViewerFrame(frameInfo)
        let url = readerViewModel.state.pageURL
        guard let scheme = url.scheme,
              (scheme == "ebook" || scheme == "ebook-url"),
              url.absoluteString.hasPrefix("\(scheme)://"),
              url.isEBookURL,
              let loaderURL = URL(string: "\(scheme)://\(url.absoluteString.dropFirst("\(scheme)://".count))")
        else {
            return
        }

        if ebookBootstrapFallbackURL == loaderURL, ebookBootstrapFallbackTask != nil {
            return
        }
        ebookBootstrapFallbackTask?.cancel()
        ebookBootstrapFallbackURL = loaderURL
        ebookBootstrapFallbackTask = Task { @MainActor [weak self] in
            defer {
                if self?.ebookBootstrapFallbackURL == loaderURL {
                    self?.ebookBootstrapFallbackTask = nil
                    self?.ebookBootstrapFallbackURL = nil
                }
            }
            guard let self else { return }
            for attempt in 0..<24 {
                try? await Task.sleep(nanoseconds: attempt == 0 ? 350_000_000 : 450_000_000)
                if Task.isCancelled { return }
                do {
                    let result = try await scriptCaller.evaluateJavaScript(
                        """
                        return (() => {
                            const fallbackURL = url;
                            const fallbackLayoutMode = layoutMode;
                            const startedAt = Number(globalThis.manabiLoadEBookStartedAt || 0);
                            const startedAgeMs = startedAt > 0 ? (Date.now() - startedAt) : null;
                            const hasReader = !!globalThis.reader;
                            const hasView = !!globalThis.reader?.view;
                            const hasRenderer = !!globalThis.reader?.view?.renderer;
                            const hasSectionLayoutController = !!globalThis.manabiEbookSectionLayoutController
                                || !!globalThis.reader?.view?.document?.defaultView?.manabiEbookSectionLayoutController;
                            const hasLivePageRoot = !!document?.querySelector?.('.mnb-page-root');
                            const hasLiveChunk = !!document?.querySelector?.('.mnb-page-root .mnb-page-column-chunk');
                            const hasLiveChunkBody = !!document?.querySelector?.('.mnb-page-root .mnb-page-column-body');
                            const hasLiveChunkText = (() => {
                                const node = document?.querySelector?.('.mnb-page-root .mnb-page-column-chunk');
                                const text = node?.textContent || '';
                                return text.trim().length > 0;
                            })();
                            const hasPendingArgs = globalThis.manabiPendingLoadEBookArgs != null;
                            const locationHref = document?.location?.href ?? null;
                            const readyState = document?.readyState ?? null;
                            const loadEBookLastState = globalThis.manabiLoadEBookLastState ?? null;
                            const isTerminalFailure =
                                (typeof loadEBookLastState === "string" && loadEBookLastState.startsWith("open-error:"))
                                || loadEBookLastState === "open-watchdog-timeout";
                            const isStaleStart = startedAgeMs !== null && startedAgeMs > 6000;
                            if (
                                hasRenderer
                                || hasSectionLayoutController
                                || hasLiveChunkBody
                                || hasLiveChunkText
                                || (hasLivePageRoot && hasLiveChunk)
                            ) return JSON.stringify({
                                state: "ready",
                                startedAgeMs,
                                hasReader,
                                hasView,
                                hasRenderer,
                                hasSectionLayoutController,
                                hasLivePageRoot,
                                hasLiveChunk,
                                hasLiveChunkBody,
                                hasLiveChunkText,
                                hasPendingArgs,
                                hasLoadEBookFunction: typeof window.loadEBook === "function",
                                loadEBookLastState,
                                loadEBookReady: globalThis.manabiLoadEBookReady === true,
                                readyState,
                                locationHref,
                            });
                            if (isTerminalFailure) {
                                globalThis.manabiLoadEBookStarted = false;
                                globalThis.manabiLoadEBookInFlight = false;
                                globalThis.manabiEbookFallbackLoadRequested = false;
                            }
                            if (globalThis.manabiLoadEBookStarted && hasView && !isStaleStart) return JSON.stringify({
                                state: "started-pending",
                                startedAgeMs,
                                hasReader,
                                hasView,
                                hasRenderer,
                                hasPendingArgs,
                                hasLoadEBookFunction: typeof window.loadEBook === "function",
                                loadEBookLastState,
                                loadEBookReady: globalThis.manabiLoadEBookReady === true,
                                readyState,
                                locationHref,
                            });
                            if (globalThis.manabiLoadEBookStarted && hasReader && !isStaleStart) return JSON.stringify({
                                state: "reader-created",
                                startedAgeMs,
                                hasReader,
                                hasView,
                                hasRenderer,
                                hasPendingArgs,
                                hasLoadEBookFunction: typeof window.loadEBook === "function",
                                loadEBookLastState,
                                loadEBookReady: globalThis.manabiLoadEBookReady === true,
                                readyState,
                                locationHref,
                            });
                            if (globalThis.manabiLoadEBookStarted && !isStaleStart) return JSON.stringify({
                                state: "started-no-reader",
                                startedAgeMs,
                                hasReader,
                                hasView,
                                hasRenderer,
                                hasPendingArgs,
                                hasLoadEBookFunction: typeof window.loadEBook === "function",
                                loadEBookLastState,
                                loadEBookReady: globalThis.manabiLoadEBookReady === true,
                                readyState,
                                locationHref,
                            });
                            if (typeof window.loadEBook !== "function") return JSON.stringify({
                                state: "loadEBook-missing",
                                startedAgeMs,
                                hasReader,
                                hasView,
                                hasRenderer,
                                hasPendingArgs,
                                hasLoadEBookFunction: false,
                                loadEBookLastState,
                                loadEBookReady: globalThis.manabiLoadEBookReady === true,
                                readyState,
                                locationHref,
                            });
                            if (globalThis.manabiEbookFallbackLoadRequested === true && !isStaleStart) return JSON.stringify({
                                state: "fallback-start-already-requested",
                                startedAgeMs,
                                hasReader,
                                hasView,
                                hasRenderer,
                                hasPendingArgs,
                                hasLoadEBookFunction: typeof window.loadEBook === "function",
                                loadEBookLastState,
                                loadEBookReady: globalThis.manabiLoadEBookReady === true,
                                readyState,
                                locationHref,
                            });
                            if (globalThis.manabiEbookFallbackLoadRequested === true && isStaleStart) {
                                globalThis.manabiEbookFallbackLoadRequested = false;
                            }
                            globalThis.manabiEbookFallbackLoadRequested = true;
                            const loadArgs = {};
                            loadArgs.url = fallbackURL;
                            loadArgs.layoutMode = fallbackLayoutMode;
                            window.loadEBook(loadArgs);
                            return JSON.stringify({
                                state: "fallback-started",
                                startedAgeMs,
                                hasReader,
                                hasView,
                                hasRenderer,
                                hasPendingArgs,
                                hasLoadEBookFunction: typeof window.loadEBook === "function",
                                loadEBookLastState: globalThis.manabiLoadEBookLastState ?? null,
                                loadEBookReady: globalThis.manabiLoadEBookReady === true,
                                readyState,
                                locationHref,
                            });
                        })();
                        """,
                        arguments: [
                            "url": loaderURL.absoluteString,
                            "layoutMode": UserDefaults.standard.string(forKey: "ebookViewerLayout") ?? "paginated",
                        ],
                        in: frameInfo
                    )
                    let state = String(describing: result ?? "nil")
                    if state.contains(#""ready""#) {
                        return
                    }
                } catch {
                }
            }
        }
    }

    @MainActor
    private func registerEbookViewerFrame(_ frameInfo: WKFrameInfo?) {
        guard let frameInfo else { return }
        let pageURL = readerViewModel.state.pageURL
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
            debugPrint(
                "# READERLOAD stage=readerMessageHandlers.contentReuseCurrent",
                "source=\(source)",
                "windowURL=\(windowURL.absoluteString)",
                "contentURL=\(currentContent.url.absoluteString)",
                "readerPageURL=\(readerContent.pageURL.absoluteString)"
            )
            return currentContent
        }
        debugPrint(
            "# READERLOAD stage=readerMessageHandlers.contentFallbackLoad",
            "source=\(source)",
            "windowURL=\(windowURL.absoluteString)",
            "readerPageURL=\(readerContent.pageURL.absoluteString)",
            "currentContentURL=\(readerContent.content?.url.absoluteString ?? "nil")"
        )
        return try await ReaderViewModel.getContent(forURL: windowURL, source: source)
    }

    lazy var webViewMessageHandlers = {
        WebViewMessageHandlers([
            ("readerConsoleLog", { @MainActor [weak self] message in
                guard let self else { return }
                guard let result = ConsoleLogMessage(fromMessage: message) else {
                    return
                }

                // Filter error logging based on URL
                let mainDocumentURL = message.frameInfo.request.mainDocumentURL
                if let mainDocumentURL {
                    guard mainDocumentURL.isEBookURL || mainDocumentURL.scheme == "blob" || mainDocumentURL.isFileURL || mainDocumentURL.isReaderFileURL || mainDocumentURL.isSnippetURL else { return }
                }

                Logger.shared.logger.log(
                    level: .init(rawValue: result.severity.lowercased()) ?? .info,
                    "[JS] \(result.severity.capitalized) [\(mainDocumentURL?.lastPathComponent ?? "(unknown URL)")]: \(result.message ?? result.arguments?.map { "\($0 ?? "nil")" }.joined(separator: " ") ?? "(no message)")"
                )
            }),
            ("print", { @MainActor [weak self] message in
                guard let self else { return }
                if let logMessage = message.body as? String {
                    if logMessage.hasPrefix("# CAROUSEL") {
                        print(logMessage)
                        Logger.shared.logger.info("\(logMessage)")
                    }
                    if logMessage.contains("\"module:posting-initialized\"") {
                        scheduleEbookViewerInitializationFallback(in: message.frameInfo)
                    }
                    if logMessage.contains("\"reader.open:view-ready\"")
                        || logMessage.contains("\"loadEBook:posting-loaded\"")
                        || logMessage.contains("\"loadEBook:delayed-state:1s\"")
                        || logMessage.contains("\"loadEBook:delayed-state:3s\"")
                        || logMessage.contains("\"loadEBook:delayed-state:8s\"") {
                        registerEbookViewerFrame(message.frameInfo)
                    }
                    if logMessage.hasPrefix("# EBOOKFIX1")
                        || logMessage.hasPrefix("# BOOKBUG1")
                        || logMessage.hasPrefix("# EBOOKHTML")
                        || logMessage.hasPrefix("# EBOOKFETCH") {
                        Logger.shared.logger.info("\(logMessage)")
                    }
                    debugPrint(logMessage)
                    return
                }
                guard let payload = message.body as? [String: Any] else {
                    debugPrint("# EPUB  readabilityInit.swiftLog", "body=\(String(describing: message.body))")
                    return
                }
                let logMessage = payload["message"] as? String ?? "# EPUB  SwiftReadability.print"
                var components: [String] = []
                if let windowURL = payload["windowURL"] as? String, !windowURL.isEmpty {
                    components.append("windowURL=\(windowURL)")
                }
                if let pageURL = payload["pageURL"] as? String, !pageURL.isEmpty {
                    components.append("pageURL=\(pageURL)")
                }
                for (key, value) in payload where key != "message" && key != "windowURL" && key != "pageURL" {
                    let printable: String
                    if value is NSNull {
                        printable = "null"
                    } else {
                        printable = String(describing: value)
                    }
                    components.append("\(key)=\(printable)")
                }
                if logMessage.hasPrefix("# READER") || logMessage.hasPrefix("# CAROUSEL") {
                    let line = components.isEmpty
                        ? logMessage
                        : "\(logMessage) \(components.joined(separator: " "))"
                    if line.hasPrefix("# CAROUSEL") {
                        print(line)
                    }
                    Logger.shared.logger.info("\(line)")
                }
            }),
            ("readerDocState", { @MainActor [weak self] message in
                guard let self else { return }
                guard let body = message.body as? [String: Any],
                      let href = body["href"] as? String,
                      let pageURL = URL(string: href)
                else { return }
                let hasReaderRenderReady = body["hasReaderRenderReady"] as? Bool ?? false
                let hasReaderContent = body["hasReaderContent"] as? Bool ?? false
                let readyState = body["readyState"] as? String ?? "unknown"
                let reason = body["reason"] as? String ?? "unknown"
                let manabiFontPending = body["manabiFontPending"].map { String(describing: $0) } ?? "nil"
                let bodyVisibility = body["bodyVisibility"] as? String ?? "nil"
                let bodyOpacity = body["bodyOpacity"].map { String(describing: $0) } ?? "nil"

                guard hasReaderRenderReady, !pageURL.isReaderURLLoaderURL else { return }
                readerModeViewModel.logSyntheticDocumentState(
                    pageURL: pageURL,
                    readyState: readyState,
                    hasReaderContent: hasReaderContent,
                    hasReaderRenderReady: hasReaderRenderReady,
                    reason: reason,
                    manabiFontPending: manabiFontPending,
                    bodyVisibility: bodyVisibility,
                    bodyOpacity: bodyOpacity
                )
                debugPrint(
                    "# READERLOAD stage=readerDocState.ready",
                    "pageURL=\(pageURL.absoluteString)",
                    "readyState=\(readyState)",
                    "hasReaderContent=\(hasReaderContent)",
                    "manabiFontPending=\(manabiFontPending)",
                    "bodyVisibility=\(bodyVisibility)",
                    "bodyOpacity=\(bodyOpacity)",
                    "reason=\(reason)"
                )
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
                    debugPrint("# EPUB  paginationBookKey.set", "key=\(bookKey.prefix(72))…")
                }
            }),
            ("trackingSizeCache", { @MainActor [weak self] message in
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
                        var bucket = trackingSizeCache.value(forKey: bucketKey) ?? ReaderSizeTrackingCacheBucket()
                        let snapshot = ReaderSizeTrackingCacheSnapshot(
                            cacheKey: key,
                            savedAt: Date(),
                            reason: body["reason"] as? String,
                            entries: decoded
                        )
                        bucket.upsertSnapshot(snapshot, limit: trackingSizeHistoryLimit)
                        trackingSizeCache.setValue(bucket, forKey: bucketKey)
                        debugPrint(
                            "# EPUB  trackingSizeCache set",
                            "bucket=\(bucketKey.prefix(72))…",
                            "cacheKey=\(key.prefix(72))…",
                            "entries=\(decoded.count)",
                            "snapshots=\(bucket.snapshots.count)",
                            "reason=\(snapshot.reason ?? "<nil>")"
                        )
                    }
                case "get":
                    guard let requestId = body["requestId"] as? String else { return }
                    if let bucket = trackingSizeCache.value(forKey: bucketKey),
                       let cached = bucket.snapshot(for: key)?.entries {
                        do {
                            let data = try JSONEncoder().encode(cached)
                            if let json = String(data: data, encoding: .utf8) {
                                let js = "window.manabiResolveTrackingSizeCache(requestId, \(json))"
                                try? await self.scriptCaller.evaluateJavaScript(
                                    js,
                                    arguments: ["requestId": requestId],
                                    in: message.frameInfo
                                )
                            }
                            debugPrint(
                                "# EPUB  trackingSizeCache hit",
                                "bucket=\(bucketKey.prefix(72))…",
                                "cacheKey=\(key.prefix(72))…",
                                "entries=\(cached.count)",
                                "snapshots=\(bucket.snapshots.count)"
                            )
                        } catch {
                            // Ignore encoding errors.
                        }
                    } else {
                        try? await self.scriptCaller.evaluateJavaScript(
                            "window.manabiResolveTrackingSizeCache(requestId, null)",
                            arguments: ["requestId": requestId],
                            in: message.frameInfo
                        )
                        debugPrint("# EPUB  trackingSizeCache miss", "key=\(key.prefix(72))…")
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
                guard result.source.isEBookURL || result.source.scheme == "blob" || result.source.isFileURL || result.source.isReaderFileURL || result.source.isSnippetURL else { return }

                Logger.shared.logger.error("[JS] Error: \(result.message ?? "unknown message") @ \(result.source.absoluteString):\(result.lineno ?? -1):\(result.colno ?? -1) — error: \(result.error ?? "n/a")")
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
                    readerViewModel.refreshSettingsInWebView(content: content)
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
                debugPrint(
                    "# READERLOAD stage=readerMessageHandlers.readabilityUnavailableEvaluating",
                    "windowURL=\(url.absoluteString)",
                    "readerPageURL=\(readerContent.pageURL.absoluteString)",
                    "readerStateURL=\(readerViewModel.state.pageURL.absoluteString)",
                    "httpStatus=\(readerViewModel.state.mainFrameHTTPStatusCode.map(String.init) ?? "nil")",
                    "frameURL=\(message.frameInfo.request.url?.absoluteString ?? "nil")",
                    "frameMainDocumentURL=\(message.frameInfo.request.mainDocumentURL?.absoluteString ?? "nil")",
                    "isMainFrame=\(message.frameInfo.isMainFrame)",
                    "isReaderModeLoading=\(readerModeViewModel.isReaderModeLoading)",
                    "isHandlingURL=\(readerModeViewModel.isReaderModeHandlingURL(url))",
                    "hasReadabilityContent=\(readerModeViewModel.readabilityContent != nil)"
                )
                if ReaderHTTPErrorRecoveryPolicy.shouldPreserveReaderState(
                    isMainFrame: message.frameInfo.isMainFrame,
                    statusCode: readerViewModel.state.mainFrameHTTPStatusCode
                ) {
                    let statusCode = readerViewModel.state.mainFrameHTTPStatusCode
                    debugPrint(
                        "# 404 reader.readabilityUnavailable.skip",
                        "url=\(url.absoluteString)",
                        "status=\(statusCode.map(String.init) ?? "nil")",
                        "hasReadabilityContent=\(readerModeViewModel.readabilityContent?.isEmpty == false)",
                        "preservedAvailability=true"
                    )
                    debugPrint(
                        "# READERLOAD stage=readerMessageHandlers.readabilityUnavailableSkipped",
                        "reason=httpError",
                        "status=\(statusCode.map(String.init) ?? "nil")",
                        "windowURL=\(url.absoluteString)"
                    )
                    return
                }
                if readerModeViewModel.isReaderModeLoading || readerModeViewModel.isReaderModeHandlingURL(url) {
                    debugPrint(
                        "# READERLOAD stage=readerMessageHandlers.readabilityUnavailableSkipped",
                        "reason=readerModeInFlight",
                        "windowURL=\(url.absoluteString)",
                        "readerPageURL=\(readerContent.pageURL.absoluteString)",
                        "isMainFrame=\(message.frameInfo.isMainFrame)",
                        "isReaderModeLoading=\(readerModeViewModel.isReaderModeLoading)"
                    )
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
                        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.historyRealmConfiguration)
                        if let historyRecord = HistoryRecord.get(forURL: url, realm: realm) {
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
                    let statusCode = readerViewModel.state.mainFrameHTTPStatusCode
                    debugPrint(
                        "# 404 reader.readabilityParsed.skip",
                        "url=\(url.absoluteString)",
                        "status=\(statusCode.map(String.init) ?? "nil")",
                        "newHTMLBytes=\(result.outputHTML.utf8.count)",
                        "hasReadabilityContent=\(readerModeViewModel.readabilityContent?.isEmpty == false)",
                        "preservedReadabilityContent=true"
                    )
                    debugPrint(
                        "# READERLOAD stage=readerMessageHandlers.readabilityParsedSkipped",
                        "reason=httpError",
                        "status=\(statusCode.map(String.init) ?? "nil")",
                        "windowURL=\(url.absoluteString)",
                        "preservedReadabilityContent=\(readerModeViewModel.readabilityContent?.isEmpty == false)"
                    )
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
                let shouldPreserveFullContentOriginal = content.rssContainsFullContent && !content.isReaderModeByDefault
                if shouldPreserveFullContentOriginal {
                    readerModeViewModel.readabilityContent = nil
                    readerModeViewModel.readabilityContainerSelector = nil
                    readerModeViewModel.readabilityContainerFrameInfo = nil
                } else {
                    readerModeViewModel.readabilityContent = result.outputHTML
                    readerModeViewModel.readabilityContainerSelector = result.readabilityContainerSelector
                    readerModeViewModel.readabilityContainerFrameInfo = message.frameInfo
                }
                if !shouldPreserveFullContentOriginal && (content.isReaderModeByDefault || forceReaderModeWhenAvailable) {
                    readerModeViewModel.showReaderView(
                        readerContent: readerContent,
                        scriptCaller: scriptCaller
                    )
                } else if result.outputHTML.lazy.filter({ String($0).hasKanji || String($0).hasKana }).prefix(51).count > 50 {
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
                        let realm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.historyRealmConfiguration)
                        if let historyRecord = HistoryRecord.get(forURL: url, realm: realm) {
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
                ebookBootstrapFallbackTask?.cancel()
                ebookBootstrapFallbackTask = nil
                registerEbookViewerFrame(message.frameInfo)
                let url = readerViewModel.state.pageURL
                if let scheme = url.scheme,
                   (scheme == "ebook" || scheme == "ebook-url"),
                   url.absoluteString.hasPrefix("\(scheme)://"),
                   url.isEBookURL,
                   let loaderURL = URL(string: "\(scheme)://\(url.absoluteString.dropFirst("\(scheme)://".count))") {
                    debugPrint(
                        "# EPUB  ebookViewerInitialized",
                        "page=\(url.absoluteString)",
                        "frame=\(message.frameInfo.request.url?.absoluteString ?? "<nil>")"
                    )
                    _ = try? await scriptCaller.evaluateJavaScript(
                        "window.manabiMarkEbookViewerInitializedAck && window.manabiMarkEbookViewerInitializedAck()",
                        in: message.frameInfo
                    )
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let initialRestore = try? await ReaderContentReadingProgressLoader.ebookInitialRestoreLoader?(url)
                        var loadArguments: [String: Any] = [
                            "url": loaderURL.absoluteString,
                            "layoutMode": UserDefaults.standard.string(forKey: "ebookViewerLayout") ?? "paginated",
                        ]
                        if let initialRestore {
                            var restoreArguments: [String: Any] = ["cfi": initialRestore.cfi]
                            if let fractionalCompletion = initialRestore.fractionalCompletion {
                                restoreArguments["fractionalCompletion"] = fractionalCompletion
                            }
                            loadArguments["initialRestore"] = restoreArguments
                        }
                        try await scriptCaller.evaluateJavaScript(
                            """
                            const fallbackURL = url;
                            const fallbackLayoutMode = layoutMode;
                            window.loadEBook({ url, layoutMode, initialRestore });
                            """,
                            arguments: loadArguments,
                            in: message.frameInfo
                        )
                    }
                }
            }),
            ("updateReadingProgress", { @MainActor [weak self] message in
                guard let self else { return }
                guard let result = FractionalCompletionMessage(fromMessage: message) else { return }
                handleNavigationVisibility(for: result)
            }),
            (ReaderWebMediaBridge.messageHandlerName, { @MainActor message in
                guard let event = ReaderWebMediaBridge.decode(message: message) else { return }
                switch event {
                case .readyState:
                    break
                case .media(let info):
                    let pageURL = URL(string: info.pageSrc) ?? message.frameInfo.request.mainDocumentURL ?? message.frameInfo.request.url
                    ReaderWebMediaBridge.postCandidateUpdate(
                        info,
                        requestHeaders: pageURL.map {
                            ReaderWebMediaBridge.mediaRequestHeaders(from: message, pageURL: $0)
                        } ?? [:]
                    )
                case .playback(let event):
                    let pageURL = URL(string: event.snapshot.pageSrc) ?? message.frameInfo.request.mainDocumentURL ?? message.frameInfo.request.url
                    ReaderWebMediaBridge.postPlaybackUpdate(
                        event,
                        requestHeaders: pageURL.map {
                            ReaderWebMediaBridge.mediaRequestHeaders(from: message, pageURL: $0)
                        } ?? [:]
                    )
                }
            }),
            ("videoStatus", { @MainActor message in
                ReaderWebMediaBridge.postExternalSubtitlesUpdate(from: message)
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
        navigationVisibilityWillChangeHandler: ReaderNavigationVisibilityWillChangeHandler?
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
        debugPrint(
            "# 404 reader.showOriginal.begin",
            "contentURL=\(contentURL.absoluteString)",
            "pageURL=\(readerContent.pageURL.absoluteString)",
            "hasCapturedReadabilityContent=\(hasCapturedReadabilityContent)",
            "shouldRestoreStoredFullContent=\(shouldRestoreStoredFullContent)"
        )
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
            let shouldKeepReaderModeAvailable = hasCapturedReadabilityContent || object.rssContainsFullContent
            debugPrint(
                "# 404 reader.showOriginal.persist",
                "contentURL=\(object.url.absoluteString)",
                "hasCapturedReadabilityContent=\(hasCapturedReadabilityContent)",
                "rssContainsFullContent=\(object.rssContainsFullContent)",
                "shouldKeepReaderModeAvailable=\(shouldKeepReaderModeAvailable)",
                "isReaderModeByDefault=\(object.isReaderModeByDefault)",
                "isReaderModeAvailable=\(object.isReaderModeAvailable)",
                "isReaderModeOfferHidden=\(object.isReaderModeOfferHidden)",
                "didChange=\(update.didChange)"
            )
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
        if ["navigation", "selection", "live-scroll"].contains(normalizedReason) {
            if normalizedReason == "navigation",
               let event = lastNavigationVisibilityEvent,
               event.shouldHide,
               event.direction == "forward",
               Date().timeIntervalSince(event.timestamp) < 0.8 {
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

    @State private var readerMessageHandlers: ReaderMessageHandlers?
    @State private var lastAppendedHandlerKeys: [String] = []

    func body(content: Content) -> some View {
        content
            .environment(\.webViewMessageHandlers, readerMessageHandlers?.webViewMessageHandlers ?? webViewMessageHandlers)
            .task { @MainActor in
                if readerMessageHandlers == nil {
                    readerMessageHandlers = ReaderMessageHandlers(
                        forceReaderModeWhenAvailable: forceReaderModeWhenAvailable,
                        scriptCaller: scriptCaller,
                        readerViewModel: readerViewModel,
                        readerModeViewModel: readerModeViewModel,
                        readerContent: readerContent,
                        navigator: navigator,
                        hideNavigationDueToScroll: hideNavigationDueToScroll,
                        showOriginalWillBeginHandler: showOriginalWillBeginHandler,
                        navigationVisibilityWillChangeHandler: navigationVisibilityWillChangeHandler
                    )
                } else if let readerMessageHandlers {
                    readerMessageHandlers.forceReaderModeWhenAvailable = forceReaderModeWhenAvailable
                    readerMessageHandlers.scriptCaller = scriptCaller
                    readerMessageHandlers.readerViewModel = readerViewModel
                    readerMessageHandlers.readerModeViewModel = readerModeViewModel
                    readerMessageHandlers.readerContent = readerContent
                    readerMessageHandlers.navigator = navigator
                    readerMessageHandlers.hideNavigationDueToScroll = hideNavigationDueToScroll
                    readerMessageHandlers.showOriginalWillBeginHandler = showOriginalWillBeginHandler
                    readerMessageHandlers.navigationVisibilityWillChangeHandler = navigationVisibilityWillChangeHandler
                }
            }
            .task(id: webViewMessageHandlers.handlers.keys) {
                let handlerKeys = Array(webViewMessageHandlers.handlers.keys).sorted()
                guard handlerKeys != lastAppendedHandlerKeys else { return }
                if let existing = readerMessageHandlers?.webViewMessageHandlers {
                    readerMessageHandlers?.webViewMessageHandlers = existing + webViewMessageHandlers
                    lastAppendedHandlerKeys = handlerKeys
                }
            }
            .task(id: hideNavigationDueToScroll.wrappedValue) {
                await pushHideNavigationStateToWebView(reason: "binding", force: false)
            }
            .task(id: readerViewModel.state.pageURL) { @MainActor in
                if !readerViewModel.state.pageURL.isEBookURL {
                    readerMessageHandlers?.ebookBootstrapFallbackTask?.cancel()
                    readerMessageHandlers?.ebookBootstrapFallbackTask = nil
                    readerMessageHandlers?.ebookBootstrapFallbackURL = nil
                } else {
                    readerMessageHandlers?.scheduleEbookViewerInitializationFallback()
                }
            }
            .task(id: readerContent.pageURL) {
                await pushHideNavigationStateToWebView(reason: "pageURL", force: true)
            }
    }
}

extension ReaderMessageHandlersViewModifier {
    @MainActor
    private func pushHideNavigationStateToWebView(reason: String, force: Bool) async {
        let pageURL = readerContent.pageURL
        guard pageURL.isEBookURL else { return }
        let shouldHide = hideNavigationDueToScroll.wrappedValue
        if reason == "binding", !force, !shouldHide {
            try? await Task.sleep(nanoseconds: 120_000_000)
            let settledPageURL = readerContent.pageURL
            let settledShouldHide = hideNavigationDueToScroll.wrappedValue
            if settledPageURL != pageURL || settledShouldHide != shouldHide {
                return
            }
        }
        let boolLiteral = shouldHide ? "true" : "false"
        do {
            try await scriptCaller.evaluateJavaScript("window.manabiSetHideNavigationDueToScroll?.(\(boolLiteral), 'swift.bindingPush');")
        } catch {
            // Ignore boot timing races.
        }
    }
}
