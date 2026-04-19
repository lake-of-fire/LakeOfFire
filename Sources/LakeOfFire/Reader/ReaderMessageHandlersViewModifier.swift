import SwiftUI
@preconcurrency import WebKit
import OrderedCollections
import SwiftUIWebView
import RealmSwift
import RealmSwiftGaps
import LakeKit

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

    private struct NavigationVisibilityEvent {
        let timestamp: Date
        let shouldHide: Bool
        let source: String?
        let direction: String?
    }

    private var lastNavigationVisibilityEvent: NavigationVisibilityEvent?
    private let trackingSizeCache = LRUFileCache<String, ReaderSizeTrackingCacheBucket>(
        namespace: "reader-pagination-size-tracking-cache-v2",
        version: 2,
        totalBytesLimit: 20 * 1024 * 1024,
        countLimit: 10_000
    )
    private let trackingSizeHistoryLimit = 10
    fileprivate var ebookBootstrapFallbackTask: Task<Void, Never>?

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

        ebookBootstrapFallbackTask?.cancel()
        ebookBootstrapFallbackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await scriptCaller.evaluateJavaScript(
                        """
                        return (() => {
                            const startedAt = Number(globalThis.manabiLoadEBookStartedAt || 0);
                            const startedAgeMs = startedAt > 0 ? (Date.now() - startedAt) : null;
                            const hasReader = !!globalThis.reader;
                            const hasView = !!globalThis.reader?.view;
                            const hasRenderer = !!globalThis.reader?.view?.renderer;
                            const hasSectionLayoutController = !!globalThis.manabiEbookSectionLayoutController
                                || !!globalThis.reader?.view?.document?.defaultView?.manabiEbookSectionLayoutController;
                            const hasLivePageRoot = !!document?.querySelector?.('.manabi-page-root');
                            const hasLiveChunk = !!document?.querySelector?.('.manabi-page-root .manabi-page-column-chunk');
                            const hasLiveChunkBody = !!document?.querySelector?.('.manabi-page-root .manabi-page-column-body');
                            const hasLiveChunkText = (() => {
                                const node = document?.querySelector?.('.manabi-page-root .manabi-page-column-chunk');
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
                            const isStaleStart = startedAgeMs !== null && startedAgeMs > 2500;
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
                            if (globalThis.manabiLoadEBookStarted && hasView) return JSON.stringify({
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
                            if (globalThis.manabiLoadEBookStarted && hasReader) return JSON.stringify({
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
                            if (globalThis.manabiLoadEBookStarted) return JSON.stringify({
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
                            if (isTerminalFailure) return JSON.stringify({
                                state: "terminal-failure",
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
                            if (globalThis.manabiEbookFallbackLoadRequested === true) return JSON.stringify({
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
                            return JSON.stringify({
                                state: "observe-only",
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
                debugPrint(
                    "# READER ebookViewerInitialized.fallback",
                    "mode=single-shot",
                    "state=\(state)",
                    "page=\(url.absoluteString)",
                    "frameURL=\(frameInfo?.request.url?.absoluteString ?? "nil")",
                    "frameMainDocumentURL=\(frameInfo?.request.mainDocumentURL?.absoluteString ?? "nil")"
                )
            } catch {
                debugPrint(
                    "# READER ebookViewerInitialized.fallback.error",
                    "mode=single-shot",
                    "error=\(error)",
                    "page=\(url.absoluteString)"
                )
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
                
                Logger.shared.logger.log(
                    level: .init(rawValue: result.severity.lowercased()) ?? .info,
                    "[JS] \(result.severity.capitalized) [\(mainDocumentURL?.lastPathComponent ?? "(unknown URL)")]: \(result.message ?? result.arguments?.map { "\($0 ?? "nil")" }.joined(separator: " ") ?? "(no message)")"
                )
            }),
            ("print", { @MainActor [weak self] message in
                guard let self else { return }
                if let logMessage = message.body as? String {
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
                    debugPrint("# READER readabilityInit.swiftLog", "body=\(String(describing: message.body))")
                    return
                }
                let logMessage = payload["message"] as? String ?? "# READER SwiftReadability.print"
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
                if components.isEmpty {
                    debugPrint(logMessage)
                } else {
                    debugPrint(logMessage, components.joined(separator: " "))
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

                guard hasReaderRenderReady, !pageURL.isReaderURLLoaderURL else { return }
                readerModeViewModel.logSyntheticDocumentState(
                    pageURL: pageURL,
                    readyState: readyState,
                    hasReaderContent: hasReaderContent,
                    hasReaderRenderReady: hasReaderRenderReady,
                    reason: reason
                )
                debugPrint(
                    "# READERLOAD stage=readerDocState.ready",
                    "pageURL=\(pageURL.absoluteString)",
                    "readyState=\(readyState)",
                    "hasReaderContent=\(hasReaderContent)",
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
            ("trackingBookKey", { [weak self] message in
                guard let body = message.body as? [String: Any],
                      let bookKey = body["bookKey"] as? String else { return }
                Task { @MainActor in
                    try? await self?.scriptCaller.evaluateJavaScript(
                        "window.paginationTrackingBookKey = bookKey;",
                        arguments: ["bookKey": bookKey],
                        in: message.frameInfo
                    )
                    debugPrint("# READER paginationBookKey.set", "key=\(bookKey.prefix(72))…")
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
                            "# READER trackingSizeCache set",
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
                                Task { @MainActor in
                                    try? await self.scriptCaller.evaluateJavaScript(
                                        js,
                                        arguments: ["requestId": requestId],
                                        in: message.frameInfo
                                    )
                                }
                            }
                            debugPrint(
                                "# READER trackingSizeCache hit",
                                "bucket=\(bucketKey.prefix(72))…",
                                "cacheKey=\(key.prefix(72))…",
                                "entries=\(cached.count)",
                                "snapshots=\(bucket.snapshots.count)"
                            )
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
                        debugPrint("# READER trackingSizeCache miss", "key=\(key.prefix(72))…")
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
                      url == readerViewModel.state.pageURL,
                      let content = try? await contentForWindowURL(url, source: "readabilityModeUnavailable") else {
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
                if !message.frameInfo.isMainFrame, readerModeViewModel.readabilityContent != nil, readerModeViewModel.readabilityContainerFrameInfo != message.frameInfo {
                    // Don't override a parent window readability result.
                    return
                }
                guard !result.outputHTML.isEmpty else {
                    try? await ReaderContentLoader.updateContent(url: url) { object in
                        guard object.isReaderModeAvailable else { return false }
                        object.isReaderModeAvailable = false
                        return true
                    }
                    return
                }
                
                guard !url.isNativeReaderView else { return }
                readerModeViewModel.readabilityContent = result.outputHTML
                readerModeViewModel.readabilityContainerSelector = result.readabilityContainerSelector
                readerModeViewModel.readabilityContainerFrameInfo = message.frameInfo
                if content.isReaderModeByDefault || forceReaderModeWhenAvailable {
                    readerModeViewModel.showReaderView(
                        readerContent: readerContent,
                        scriptCaller: scriptCaller
                    )
                } else if result.outputHTML.lazy.filter({ String($0).hasKanji || String($0).hasKana }).prefix(51).count > 50 {
                    try? await scriptCaller.evaluateJavaScript("""
                        if (document.body) {
                            document.body.dataset.manabiReaderModeAvailableConfidently = 'true';
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
                        guard !object.isReaderModeAvailable else { return false }
                        object.isReaderModeAvailable = true
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
                    try await readerViewModel.pageMetadataUpdated(title: result.title, author: result.author)
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
                        "# READER ebookViewerInitialized",
                        "page=\(url.absoluteString)",
                        "frame=\(message.frameInfo.request.url?.absoluteString ?? "<nil>")"
                    )
                    _ = try? await scriptCaller.evaluateJavaScript(
                        "window.manabiMarkEbookViewerInitializedAck && window.manabiMarkEbookViewerInitializedAck()",
                        in: message.frameInfo
                    )
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        try await scriptCaller.evaluateJavaScript(
                            "window.loadEBook({ url, layoutMode })",
                            arguments: [
                                "url": loaderURL.absoluteString,
                                "layoutMode": UserDefaults.standard.string(forKey: "ebookViewerLayout") ?? "paginated",
                            ],
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
        hideNavigationDueToScroll: Binding<Bool>
    ) {
        self.forceReaderModeWhenAvailable = forceReaderModeWhenAvailable
        self.scriptCaller = scriptCaller
        self.readerViewModel = readerViewModel
        self.readerModeViewModel = readerModeViewModel
        self.readerContent = readerContent
        self.navigator = navigator
        self.hideNavigationDueToScroll = hideNavigationDueToScroll
    }
    
    // MARK: Readability
    
    @MainActor
    func showOriginal() async throws {
        let contentURL = readerContent.content?.url
            ?? ReaderContentLoader.getContentURL(fromLoaderURL: readerContent.pageURL)
            ?? readerContent.pageURL
        try await ReaderContentLoader.updateContent(url: contentURL) { object in
            guard object.isReaderModeByDefault else { return false }
            object.isReaderModeByDefault = false
            return true
        }
        navigator.reload()
    }

    private func setHideNavigationDueToScroll(
        _ shouldHide: Bool,
        reason: String? = nil,
        source: String? = nil,
        direction: String? = nil
    ) {
        let previousValue = hideNavigationDueToScroll.wrappedValue
        guard previousValue != shouldHide else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            hideNavigationDueToScroll.wrappedValue = shouldHide
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
                        hideNavigationDueToScroll: hideNavigationDueToScroll
                    )
                } else if let readerMessageHandlers {
                    readerMessageHandlers.forceReaderModeWhenAvailable = forceReaderModeWhenAvailable
                    readerMessageHandlers.scriptCaller = scriptCaller
                    readerMessageHandlers.readerViewModel = readerViewModel
                    readerMessageHandlers.readerModeViewModel = readerModeViewModel
                    readerMessageHandlers.readerContent = readerContent
                    readerMessageHandlers.navigator = navigator
                    readerMessageHandlers.hideNavigationDueToScroll = hideNavigationDueToScroll
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
                await pushHideNavigationStateToWebView()
            }
            .task(id: readerViewModel.state.pageURL) { @MainActor in
                if !readerViewModel.state.pageURL.isEBookURL {
                    readerMessageHandlers?.ebookBootstrapFallbackTask?.cancel()
                    readerMessageHandlers?.ebookBootstrapFallbackTask = nil
                }
            }
            .task(id: readerContent.pageURL) {
                await pushHideNavigationStateToWebView()
            }
    }
}

extension ReaderMessageHandlersViewModifier {
    @MainActor
    private func pushHideNavigationStateToWebView() async {
        guard readerContent.pageURL.isEBookURL else { return }
        let boolLiteral = hideNavigationDueToScroll.wrappedValue ? "true" : "false"
        do {
            try await scriptCaller.evaluateJavaScript("window.manabiSetHideNavigationDueToScroll?.(\(boolLiteral));")
        } catch {
            // Ignore boot timing races.
        }
    }
}
