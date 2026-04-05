import SwiftUI
import OrderedCollections
import SwiftUIWebView
import RealmSwift
import RealmSwiftGaps
import LakeKit
import Logging
import WebKit
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent

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
        // Support legacy payloads that stored a flat array of entries for a single key.
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
        // Remove any prior snapshot for the same cacheKey so we overwrite per-key.
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

private let readerModeDatasetProbeScript = """
(() => {
    const hasDocument = typeof document !== 'undefined';
    const hasBody = hasDocument && !!document.body;
    const summary = { hasBody };
    if (!hasBody) {
        return JSON.stringify(summary);
    }
    const ds = document.body.dataset ?? {};
    const bodyHTMLBytes = typeof document.body.innerHTML === "string" ? document.body.innerHTML.length : 0;
    const bodyTextBytes = typeof document.body.textContent === "string" ? document.body.textContent.length : 0;
    const readerContentNode = document.getElementById("reader-content");
    const readerContentHTMLBytes = readerContentNode && typeof readerContentNode.innerHTML === "string" ? readerContentNode.innerHTML.length : 0;
    const readerContentTextBytes = readerContentNode && typeof readerContentNode.textContent === "string" ? readerContentNode.textContent.length : 0;
    const dataset = {};
    [
        "manabiReaderModeAvailable",
        "manabiReaderModeAvailableFor",
        "manabiReaderModeAvailableConfidently",
        "manabiTrackingEnabled",
        "manabiSettingsInitialized",
        "manabiFuriganaEnabled",
        "manabiKnownFuriganaEnabled",
        "manabiFamiliarFuriganaEnabled",
        "manabiTrackingHighlightsEnabled",
        "manabiLearningFuriganaEnabled",
        "manabiSubscriptionIsActive",
        "manabiShowKnown",
        "manabiShowFamiliar",
        "manabiHasMarkedSectionRead"
    ].forEach((key) => {
        dataset[key] = ds[key] ?? null;
    });
    const trackedWordsSource = (hasDocument && typeof document.manabi_trackedWords === "object" && document.manabi_trackedWords) ? document.manabi_trackedWords : null;
    const trackedWordCount = trackedWordsSource ? Object.keys(trackedWordsSource).length : 0;
    const statsObject = (typeof window.manabi_latestContentStats === "object" && window.manabi_latestContentStats) ? window.manabi_latestContentStats : null;
    summary.hasReadabilityClass = document.body.classList.contains("readability-mode");
    summary.readerHeaderPresent = !!document.getElementById("reader-header");
    summary.readerContentPresent = !!readerContentNode;
    summary.bodyHTMLBytes = bodyHTMLBytes;
    summary.bodyTextBytes = bodyTextBytes;
    summary.readerContentHTMLBytes = readerContentHTMLBytes;
    summary.readerContentTextBytes = readerContentTextBytes;
    summary.dataset = dataset;
    summary.swiftuiFrameUUID = ds.swiftuiwebviewFrameUuid ?? null;
    summary.trackedWordCount = trackedWordCount;
    summary.updateTrackedWordsType = typeof window.manabi_updateTrackedWords;
    summary.updateContentStatsType = typeof window.manabi_updateContentStats;
    summary.selectionHandlerType = typeof window.manabi_getPrimaryTrackedWordForSegment;
    summary.pendingContentStats = !!window.manabi_latestContentStatsPending;
    summary.hasStatsPayload = !!statsObject;
    if (statsObject) {
        summary.statsPreview = {
            tokenCount: statsObject.tokenCount ?? null,
            kanjiCount: statsObject.kanjiCount ?? null,
            familiarCount: statsObject.familiarCount ?? null,
            knownCount: statsObject.knownCount ?? null
        };
    }
    const payload = JSON.stringify(summary);
    try {
        if (typeof window !== 'undefined') {
            window.manabiDatasetDebugSummary = payload;
        }
    } catch (error) {
        // no-op
    }
    return payload;
})()
"""

@MainActor
internal struct ReaderNavigationVisibilityEvent {
    let timestamp: Date
    let shouldHide: Bool
    let source: String?
    let direction: String?
}

@MainActor
internal final class ReaderNavigationVisibilityCoordinator: ObservableObject {
    @Published private(set) var lastHostPageTurnEvent: ReaderNavigationVisibilityEvent?

    func recordHostPageTurnEvent(shouldHide: Bool, source: String, direction: String?) {
        lastHostPageTurnEvent = ReaderNavigationVisibilityEvent(
            timestamp: Date(),
            shouldHide: shouldHide,
            source: source,
            direction: direction
        )
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
    var navigationVisibilityCoordinator: ReaderNavigationVisibilityCoordinator
    var updateReadingProgressHandler: ((FractionalCompletionMessage) async -> Void)?
    var contentBlockingEnabled: Bool
    var contentBlockingStatsModel: AdblockStatsModel?
    private var lastNavigationVisibilityEvent: ReaderNavigationVisibilityEvent?

    // Cache baked tracking-section sizes keyed by section href + book, with per-key snapshots.
    private let trackingSizeCache = LRUFileCache<String, ReaderSizeTrackingCacheBucket>(
        namespace: "reader-pagination-size-tracking-cache-v2",
        version: 2,
        totalBytesLimit: 20 * 1024 * 1024,
        countLimit: 10_000
    )
    private let trackingSizeHistoryLimit = 10

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

    private func handleAdblockStatsMessage(_ message: WebViewMessage) async {
        guard let statsModel = contentBlockingStatsModel else { return }
        guard AdblockStatsUserScript.isValidMessageBody(message.body) else { return }
        guard let candidates = AdblockStatsModel.candidates(from: message.body) else {
            return
        }
        let mainDocumentURL = message.mainDocumentURL
        let pageURL = mainDocumentURL ?? message.requestURL
        await statsModel.handleCandidates(
            candidates,
            pageURL: pageURL,
            isContentBlockingEnabled: contentBlockingEnabled
        )
    }

    private func handleTrackingSizeCacheMessage(_ message: WebViewMessage) async {
        guard let body = message.body as? [String: Any],
              let command = body["command"] as? String,
              let key = body["key"] as? String else { return }

        let bucketKey = makeBucketKey(from: key)

        switch command {
        case "set":
            guard let entries = body["entries"] as? [[String: Any]] else { return }
            let decoded: [ReaderSizeTrackingCacheEntry] = entries.compactMap { dict in
                guard let id = dict["id"] as? String,
                      let inlineSize = dict["inlineSize"] as? Double,
                      let blockSize = dict["blockSize"] as? Double else { return nil }
                let blockStart = dict["blockStart"] as? Double
                return ReaderSizeTrackingCacheEntry(id: id, inlineSize: inlineSize, blockSize: blockSize, blockStart: blockStart)
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
            debugPrint("# READER trackingSizeCache set",
                       "bucket=\(bucketKey.prefix(72))…",
                       "cacheKey=\(key.prefix(72))…",
                       "entries=\(decoded.count)",
                       "snapshots=\(bucket.snapshots.count)",
                       "reason=\(snapshot.reason ?? "<nil>")")
        case "get":
            guard let requestId = body["requestId"] as? String else { return }
            guard let bucket = trackingSizeCache.value(forKey: bucketKey),
                  let cached = bucket.snapshot(for: key)?.entries else {
                _ = try? await scriptCaller.evaluateJavaScript("window.manabiResolveTrackingSizeCache(\"\(requestId)\", null)", in: message.frameInfo)
                debugPrint("# READER trackingSizeCache miss", "key=\(key.prefix(72))…")
                return
            }

            do {
                let data = try JSONEncoder().encode(cached)
                guard let json = String(data: data, encoding: .utf8) else { return }
                let js = "window.manabiResolveTrackingSizeCache(\"\(requestId)\", \(json))"
                _ = try? await scriptCaller.evaluateJavaScript(js, in: message.frameInfo)
                debugPrint("# READER trackingSizeCache hit",
                           "bucket=\(bucketKey.prefix(72))…",
                           "cacheKey=\(key.prefix(72))…",
                           "entries=\(cached.count)",
                           "snapshots=\(bucket.snapshots.count)")
            } catch {
                // ignore encoding errors
            }
        default:
            break
        }
    }

    lazy var webViewMessageHandlers: WebViewMessageHandlers = {
        let handlers: [(String, @Sendable (WebViewMessage) async -> Void)] = [
            ("readerConsoleLog", { [weak self] message in
                guard let self else { return }
                guard let result = ConsoleLogMessage(fromMessage: message) else {
                    return
                }
                
                // Filter error logging based on URL
                let mainDocumentURL = message.mainDocumentURL
                if let mainDocumentURL {
                    guard mainDocumentURL.isEBookURL || mainDocumentURL.scheme == "blob" || mainDocumentURL.isFileURL || mainDocumentURL.isReaderFileURL || mainDocumentURL.isSnippetURL else { return }
                }
                
                let severity = Logging.Logger.Level(rawValue: result.severity.lowercased()) ?? .info
                let urlSuffix = mainDocumentURL?.lastPathComponent ?? "(unknown URL)"
                let fallbackMessage = result.arguments?.map { argument in
                    guard let argument else { return "nil" }
                    return String(describing: argument)
                }.joined(separator: " ") ?? "(no message)"
                let messageText = result.message ?? fallbackMessage
                LakeKit.Logger.shared.logger.log(
                    level: severity,
                    "[JS] \(result.severity.capitalized) [\(urlSuffix)]: \(messageText)"
                )
            }),
            ("print", { @MainActor [weak self] message in
                guard let self else { return }
                guard let payload = message.body as? [String: Any] else {
                    debugPrint("# READER readabilityInit.swiftLog", "body=\(String(describing: message.body))")
                    return
                }
                let logMessage = payload["message"] as? String ?? "# READER SwiftReadability.print"
                if logMessage == "# READER snippetLoader.documentReady",
                   let windowURLString = payload["windowURL"] as? String,
                   let windowURL = URL(string: windowURLString) {
                    let hasReaderContent: Bool = {
                        if let number = payload["hasReaderContent"] as? NSNumber {
                            return number.intValue != 0
                        }
                        if let bool = payload["hasReaderContent"] as? Bool {
                            return bool
                        }
                        return false
                    }()
                    let resolvedURL = ReaderContentLoader.getContentURL(fromLoaderURL: windowURL) ?? windowURL
                    self.readerModeViewModel.handleRenderedReaderDocumentReady(
                        pageURL: resolvedURL,
                        hasReaderContent: hasReaderContent
                    )
                }
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
            (AdblockStatsUserScript.handlerName, { @Sendable [weak self] message in
                await self?.handleAdblockStatsMessage(message)
            }),
            ("trackingBookKey", { [weak self] message in
                guard let body = message.body as? [String: Any],
                      let bookKey = body["bookKey"] as? String else { return }
                Task { @MainActor in
                    _ = try? await self?.scriptCaller.evaluateJavaScript("window.paginationTrackingBookKey = '" + bookKey + "';", in: message.frameInfo)
                    debugPrint("# READER paginationBookKey.set", "key=\(bookKey.prefix(72))…")
                }
            }),
            ("trackingSizeCache", { [weak self] message in
                await self?.handleTrackingSizeCacheMessage(message)
            }),
            ("readerOnError", { [weak self] message in
                guard let self else { return }
                guard let result = ReaderOnErrorMessage(fromMessage: message) else {
                    return
                }
                
                // Filter error logging based on URL
                guard result.source.isEBookURL || result.source.scheme == "blob" || result.source.isFileURL || result.source.isReaderFileURL || result.source.isSnippetURL else { return }
                
                LakeKit.Logger.shared.logger.error("[JS] Error: \(result.message ?? "unknown message") @ \(result.source.absoluteString):\(result.lineno ?? -1):\(result.colno ?? -1) — error: \(result.error ?? "n/a")")
            }),
            ("ebookNavigationVisibility", { @MainActor [weak self] message in
                guard let self else { return }
                guard let payload = message.body as? [String: Any], let shouldHide = payload["hideNavigationDueToScroll"] as? Bool else {
                    return
                }
                let source = payload["source"] as? String
                let direction = payload["direction"] as? String
                debugPrint("# HIDENAV message ebookNavigationVisibility hide=\(shouldHide) source=\(source ?? "<nil>") direction=\(direction ?? "<nil>") url=\(readerContent.pageURL.absoluteString)")

                self.setHideNavigationDueToScroll(
                    shouldHide,
                    reason: nil,
                    source: source,
                    direction: direction
                )
                self.lastNavigationVisibilityEvent = .init(
                    timestamp: Date(),
                    shouldHide: shouldHide,
                    source: source,
                    direction: direction
                )
            }),
            ("updateReadingProgress", { @MainActor [weak self] message in
                guard let self else { return }
                guard let result = FractionalCompletionMessage(fromMessage: message) else { return }
                debugPrint(
                    "# HIDENAV message updateReadingProgress reason=\(result.reason) fraction=\(result.fractionalCompletion) url=\(result.mainDocumentURL?.absoluteString ?? readerContent.pageURL.absoluteString) hideNavigation=\(hideNavigationDueToScroll.wrappedValue)"
                )
                self.handleNavigationVisibility(for: result)
                if let handler = self.updateReadingProgressHandler {
                    Task { await handler(result) }
                }
            }),
            ("readabilityFramePing", { @MainActor [weak self] message in
                guard let self else { return }
                let frameInfo = message.frameInfo
                let frameRequestURL = message.requestURL?.absoluteString ?? "<nil>"
                let frameMainDocURL = message.mainDocumentURL?.absoluteString ?? "<nil>"
                let frameSecurityOrigin = String(describing: frameInfo.securityOrigin)
                debugPrint(
                    "# READER readability.framePing.frameInfo",
                    "debug=\(frameInfo.debugDescription)",
                    "requestURL=\(frameRequestURL)",
                    "mainDocumentURL=\(frameMainDocURL)",
                    "securityOrigin=\(frameSecurityOrigin)",
                    "isMain=\(message.isMainFrame)"
                )
                guard let uuid = (message.body as? [String: String])?["uuid"], let windowURLRaw = (message.body as? [String: String])?["windowURL"] as? String, let windowURL = URL(string: windowURLRaw) else {
                    debugPrint("Unexpectedly received readableFramePing message without valid parameters", (message.body as? [String: String]) as Any)
                    return
                }
                let canonicalWindowURL = ReaderContentLoader.getContentURL(fromLoaderURL: windowURL) ?? windowURL
                debugPrint(
                    "# READER readability.framePing",
                    "uuid=\(uuid)",
                    "windowURL=\(windowURL.absoluteString)",
                    "canonicalURL=\(canonicalWindowURL.absoluteString)",
                    "frameURL=\(message.requestURL?.absoluteString ?? "<nil>")",
                    "isMain=\(message.isMainFrame)"
                )
                guard !canonicalWindowURL.isNativeReaderView, let content = try? await ReaderViewModel.getContent(forURL: canonicalWindowURL) else { return }
                if readerViewModel.scriptCaller.addMultiTargetFrame(message.frameInfo, uuid: uuid, canonicalURL: canonicalWindowURL) {
                    readerViewModel.refreshSettingsInWebView(content: content)
                }
                if readerModeViewModel.readabilityContainerFrameInfo == nil {
                    readerModeViewModel.readabilityContainerFrameInfo = message.frameInfo
                }
            }),
            ("readerBootstrapPing", { @MainActor [weak self] message in
                guard let self else { return }
                let frameInfo = message.frameInfo
                let frameURL = message.requestURL
                let body = message.body as? [String: Any]
                let href = body?["href"] as? String ?? "<nil>"
                let readyState = body?["readyState"] as? String ?? "<nil>"
                debugPrint(
                    "# READER bootstrap.ping",
                    "href=\(href)",
                    "readyState=\(readyState)",
                    "frameURL=\(frameURL?.absoluteString ?? "<nil>")",
                    "isMain=\(message.isMainFrame)"
                )
                // Try to seed the frame registry early.
                if let url = frameURL {
                    let canonicalHref = URL(string: href).flatMap { ReaderContentLoader.getContentURL(fromLoaderURL: $0) ?? $0 }
                    let bootstrapKey = canonicalHref?.absoluteString ?? url.absoluteString
                    _ = readerViewModel.scriptCaller.addMultiTargetFrame(frameInfo, uuid: "bootstrap-\(bootstrapKey)", canonicalURL: canonicalHref)
                    let pageMatches = canonicalHref.map { urlsMatchWithoutHash($0, self.readerViewModel.state.pageURL) || (self.readerModeViewModel.isReaderModeLoadPending(for: $0)) } ?? false
                    if message.isMainFrame && pageMatches {
                        // Always refresh to the latest main-frame WKFrameInfo for this page; older instances become invalid after nav.
                        readerModeViewModel.readabilityContainerFrameInfo = frameInfo
                    } else if readerModeViewModel.readabilityContainerFrameInfo == nil {
                        readerModeViewModel.readabilityContainerFrameInfo = frameInfo
                    }
                }
            }),
            ("readerDocState", { @MainActor _ in
                debugPrint("# READER docState.ping")
            }),
            ("readabilityModeUnavailable", { @MainActor [weak self] message in
                guard let self else { return }
                guard let result = ReaderModeUnavailableMessage(fromMessage: message) else {
                    return
                }
                // TODO: Reuse guard code across this and readabilityParsed
                guard let rawURL = result.windowURL else { return }
                let resolvedURL = ReaderContentLoader.getContentURL(fromLoaderURL: rawURL) ?? rawURL
                let stateURL = readerViewModel.state.pageURL
                let stateMatches = resolvedURL.matchesReaderURL(stateURL)
                if !stateMatches {
                    let canonicalStateURL = ReaderContentLoader.getContentURL(fromLoaderURL: stateURL) ?? stateURL
                    debugPrint(
                        "# READERMODEPROCESSING readabilityUnavailable.mismatch",
                        "windowURL=\(rawURL.absoluteString)",
                        "contentURL=\(resolvedURL.absoluteString)",
                        "stateURL=\(stateURL.absoluteString)",
                        "canonicalStateURL=\(canonicalStateURL.absoluteString)"
                    )
                    debugPrint(
                        "# READERMODE readabilityUnavailable.drop",
                        "reason=stateURLMismatch",
                        "windowURL=\(rawURL.absoluteString)",
                        "contentURL=\(resolvedURL.absoluteString)",
                        "stateURL=\(stateURL.absoluteString)"
                    )
                    return
                }
                guard let content = try? await ReaderViewModel.getContent(forURL: resolvedURL) else {
                    debugPrint(
                        "# READERMODE readabilityUnavailable.drop",
                        "reason=contentMissing",
                        "windowURL=\(rawURL.absoluteString)",
                        "contentURL=\(resolvedURL.absoluteString)"
                    )
                    return
                }
                let isSnippetURL = resolvedURL.isSnippetURL
                debugPrint(
                    "# READERMODE readabilityUnavailable",
                    "windowURL=\(rawURL.absoluteString)",
                    "contentURL=\(resolvedURL.absoluteString)",
                    "frameIsMain=\(message.isMainFrame)",
                    "isSnippet=\(isSnippetURL)",
                    "readerAvailable=\(content.isReaderModeAvailable)",
                    "readerDefault=\(content.isReaderModeByDefault)",
                    "hasReadability=\(readerModeViewModel.readabilityContent != nil)"
                )
                debugPrint(
                    "# READERRELOAD readabilityUnavailable",
                    "windowURL=\(rawURL.absoluteString)",
                    "resolved=\(resolvedURL.absoluteString)",
                    "frameIsMain=\(message.isMainFrame)",
                    "readerDefault=\(content.isReaderModeByDefault)",
                    "isReaderMode=\(readerModeViewModel.isReaderMode)",
                    "isReaderModeLoading=\(readerModeViewModel.isReaderModeLoading)",
                    "pending=\(readerModeViewModel.pendingReaderModeURL?.absoluteString ?? "nil")",
                    "expected=\(readerModeViewModel.expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")"
                )
                if isSnippetURL {
                    debugPrint(
                        "# READER snippet.readabilityParsed",
                        "pageURL=\(resolvedURL.absoluteString)",
                        "frameIsMain=\(message.isMainFrame)"
                    )
                }
                if !message.isMainFrame, readerModeViewModel.readabilityContent != nil, readerModeViewModel.readabilityContainerFrameInfo != message.frameInfo {
                    // Don't override a parent window readability result.
                    return
                }
                guard !resolvedURL.isReaderURLLoaderURL else { return }
                let pendingMatches = readerModeViewModel.pendingReaderModeURL?.matchesReaderURL(resolvedURL) == true
                let expectedMatches = readerModeViewModel.expectedSyntheticReaderLoaderURL?.matchesReaderURL(resolvedURL) == true
                if message.isMainFrame,
                   (readerModeViewModel.isReaderModeLoading || pendingMatches || expectedMatches) {
                    debugPrint(
                        "# READERRELOAD readabilityUnavailable.skip",
                        "reason=readerModeInFlight",
                        "contentURL=\(resolvedURL.absoluteString)",
                        "isLoading=\(readerModeViewModel.isReaderModeLoading)",
                        "pending=\(readerModeViewModel.pendingReaderModeURL?.absoluteString ?? "nil")",
                        "expected=\(readerModeViewModel.expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")"
                    )
                    return
                }
                if content.isReaderModeByDefault, content.hasHTML, !isSnippetURL {
                    debugPrint(
                        "# READERRELOAD readabilityUnavailable.skip",
                        "reason=readerDefaultHasHTML",
                        "contentURL=\(resolvedURL.absoluteString)",
                        "hasHTML=\(content.hasHTML)"
                    )
                    return
                }

                if isSnippetURL {
                    debugPrint(
                        "# READERRELOAD readabilityUnavailable.skip",
                        "reason=snippetHandledByReaderModePipeline",
                        "contentURL=\(resolvedURL.absoluteString)",
                        "isLoading=\(readerModeViewModel.isReaderModeLoading)",
                        "pending=\(readerModeViewModel.pendingReaderModeURL?.absoluteString ?? "nil")",
                        "expected=\(readerModeViewModel.expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")"
                    )
                    return
                }

                if isSnippetURL, readerModeViewModel.readabilityContent != nil {
                    debugPrint(
                        "# READER readability.snippetReset",
                        "url=\(resolvedURL.absoluteString)",
                        "reason=existingReadabilityState"
                    )
                    readerModeViewModel.readabilityContent = nil
                    readerModeViewModel.readabilityContainerSelector = nil
                    readerModeViewModel.readabilityContainerFrameInfo = nil
                }

                if readerModeViewModel.isReaderMode {
                    debugPrint(
                        "# READERRELOAD readerMode.setFalse",
                        "reason=readabilityUnavailable",
                        "contentURL=\(resolvedURL.absoluteString)",
                        "readerDefault=\(content.isReaderModeByDefault)"
                    )
                    debugPrint(
                        "# WRITINGDIR readerMode.stateChange",
                        "reason=readabilityUnavailable",
                        "newValue=false",
                        "vm=\(ObjectIdentifier(readerModeViewModel).debugDescription)",
                        "resolvedURL=\(resolvedURL.absoluteString)",
                        "pageURL=\(readerViewModel.state.pageURL.absoluteString)",
                        "pending=\(readerModeViewModel.pendingReaderModeURL?.absoluteString ?? "nil")",
                        "isLoading=\(readerModeViewModel.isReaderModeLoading)",
                        "hasRenderedReadability=\(readerModeViewModel.hasRenderedReadabilityContent)"
                    )
                    readerModeViewModel.isReaderMode = false
                }
                
                do {
                    try await ReaderContentLoader.updateContent(url: resolvedURL) { object in
                        guard object.isReaderModeAvailable else { return false }
                        object.isReaderModeAvailable = false
                        return true
                    }
                    
                    try await { @RealmBackgroundActor in
                        let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.historyRealmConfiguration)
                        if let historyRecord = HistoryRecord.get(forURL: resolvedURL, realm: historyRealm) {
                            try await historyRecord.refreshDemotedStatus()
                        }
                    }()
                } catch {
                    print(error)
                }
            }),
            ("readabilityParsed", { @MainActor [weak self] message in
                guard let self else { return }
                let frameInfo = message.frameInfo
                let frameRequestURL = message.requestURL?.absoluteString ?? "<nil>"
                let frameMainDocURL = message.mainDocumentURL?.absoluteString ?? "<nil>"
                let frameSecurityOrigin = String(describing: frameInfo.securityOrigin)
                debugPrint(
                    "# READER readability.parsed.frameInfo",
                    "debug=\(frameInfo.debugDescription)",
                    "requestURL=\(frameRequestURL)",
                    "mainDocumentURL=\(frameMainDocURL)",
                    "securityOrigin=\(frameSecurityOrigin)",
                    "isMain=\(message.isMainFrame)"
                )
                guard let result = ReadabilityParsedMessage(fromMessage: message) else {
                    return
                }
                guard let rawWindowURL = result.windowURL else { return }
                let resolvedURL = ReaderContentLoader.getContentURL(fromLoaderURL: rawWindowURL) ?? rawWindowURL
                let stateURL = readerViewModel.state.pageURL
                let stateMatches = resolvedURL.matchesReaderURL(stateURL)
                if !stateMatches {
                    let canonicalStateURL = ReaderContentLoader.getContentURL(fromLoaderURL: stateURL) ?? stateURL
                    debugPrint(
                        "# READERMODEPROCESSING readabilityParsed.mismatch",
                        "windowURL=\(rawWindowURL.absoluteString)",
                        "contentURL=\(resolvedURL.absoluteString)",
                        "stateURL=\(stateURL.absoluteString)",
                        "canonicalStateURL=\(canonicalStateURL.absoluteString)"
                    )
                    debugPrint(
                        "# READERMODE readabilityParsed.drop",
                        "reason=stateURLMismatch",
                        "windowURL=\(rawWindowURL.absoluteString)",
                        "contentURL=\(resolvedURL.absoluteString)",
                        "stateURL=\(stateURL.absoluteString)"
                    )
                    return
                }
                guard let content = try? await ReaderViewModel.getContent(forURL: resolvedURL) else {
                    debugPrint(
                        "# READERMODE readabilityParsed.drop",
                        "reason=contentMissing",
                        "windowURL=\(rawWindowURL.absoluteString)",
                        "contentURL=\(resolvedURL.absoluteString)"
                    )
                    return
                }
                let isSnippetURL = resolvedURL.isSnippetURL
                let outputHTML = buildCanonicalReadabilityHTML(
                    title: result.title,
                    byline: result.byline,
                    publishedTime: result.publishedTime,
                    content: result.content,
                    contentURL: resolvedURL
                )
                debugPrint(
                    "# READERMODE readabilityParsed",
                    "windowURL=\(rawWindowURL.absoluteString)",
                    "contentURL=\(resolvedURL.absoluteString)",
                    "frameIsMain=\(message.isMainFrame)",
                    "isSnippet=\(isSnippetURL)",
                    "outputBytes=\(outputHTML.utf8.count)",
                    "readerAvailable=\(content.isReaderModeAvailable)",
                    "readerDefault=\(content.isReaderModeByDefault)",
                    "forceReader=\(forceReaderModeWhenAvailable)",
                    "hasReadability=\(readerModeViewModel.readabilityContent != nil)",
                    "pending=\(readerModeViewModel.pendingReaderModeURL?.absoluteString ?? "nil")"
                )
                debugPrint(
                    "# READERRELOAD readabilityParsed",
                    "contentURL=\(resolvedURL.absoluteString)",
                    "outputBytes=\(outputHTML.utf8.count)",
                    "frameIsMain=\(message.isMainFrame)",
                    "readerDefault=\(content.isReaderModeByDefault)",
                    "isReaderMode=\(readerModeViewModel.isReaderMode)",
                    "isReaderModeLoading=\(readerModeViewModel.isReaderModeLoading)",
                    "pending=\(readerModeViewModel.pendingReaderModeURL?.absoluteString ?? "nil")",
                    "expected=\(readerModeViewModel.expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")"
                )
                if isSnippetURL {
                    debugPrint(
                        "# READER snippet.readabilityParsed",
                        "windowURL=\(rawWindowURL.absoluteString)",
                        "contentURL=\(resolvedURL.absoluteString)",
                        "frameIsMain=\(message.isMainFrame)"
                    )
                    debugPrint(
                        "# READER snippet.readabilityHTML",
                        "windowURL=\(rawWindowURL.absoluteString)",
                        "bytes=\(outputHTML.utf8.count)",
                        "html=\(outputHTML)"
                    )
                    let hasReaderContent = outputHTML.contains("id=\"reader-content\"")
                    debugPrint(
                        "# READER readability.snippetOutput",
                        "windowURL=\(resolvedURL.absoluteString)",
                        "contentURL=\(resolvedURL.absoluteString)",
                        "hasReaderContent=\(hasReaderContent)"
                    )
                }
                if let bodySummary = summarizeBodyMarkup(from: outputHTML) {
                    debugPrint(
                        "# READER readability.parsedBody",
                        "windowURL=\(resolvedURL.absoluteString)",
                        "contentBytes=\(outputHTML.utf8.count)",
                        "body=\(bodySummary)"
                    )
                }
                if !message.isMainFrame,
                   readerModeViewModel.readabilityContent != nil,
                   readerModeViewModel.readabilityContainerFrameInfo != message.frameInfo {
                    // Don't override a parent window readability result.
                    return
                }
                let hasMeaningfulContent = !result.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                guard hasMeaningfulContent else {
                    if isSnippetURL {
                        debugPrint(
                            "# READER readability.empty",
                            "windowURL=\(resolvedURL.absoluteString)",
                            "contentURL=\(resolvedURL.absoluteString)",
                            "snippet=true"
                        )
                    }
                    try? await ReaderContentLoader.updateContent(url: resolvedURL) { object in
                        guard object.isReaderModeAvailable else { return false }
                        object.isReaderModeAvailable = false
                        return true
                    }
                    return
                }

                guard !resolvedURL.isNativeReaderView else { return }

                let hasProcessedReadability = readerModeViewModel.readabilityContent != nil
                var shouldShortCircuit = readerModeViewModel.isReaderMode && hasProcessedReadability
                if shouldShortCircuit && !isSnippetURL {
                    let rawReadabilityMarkers = try? await scriptCaller.evaluateJavaScript(
                        """
                        (() => {
                            const body = document.body;
                            return {
                                hasReadabilityClass: body?.classList.contains("readability-mode") === true,
                                hasReaderContent: document.getElementById("reader-content") !== null,
                                hasReaderHeader: document.getElementById("reader-header") !== null
                            };
                        })()
                        """
                    )
                    let readabilityMarkers: (hasReadabilityClass: Bool?, hasReaderContent: Bool?, hasReaderHeader: Bool?) = {
                        guard let unwrapped = self.unwrapJavaScriptValue(rawReadabilityMarkers) else {
                            return (nil, nil, nil)
                        }
                        guard let dictionary = unwrapped as? [String: Any] else {
                            return (nil, nil, nil)
                        }
                        func boolValue(_ value: Any?) -> Bool? {
                            guard let value else { return nil }
                            if let number = value as? NSNumber {
                                return number.intValue != 0
                            }
                            if let bool = value as? Bool {
                                return bool
                            }
                            return nil
                        }
                        return (
                            boolValue(dictionary["hasReadabilityClass"]),
                            boolValue(dictionary["hasReaderContent"]),
                            boolValue(dictionary["hasReaderHeader"])
                        )
                    }()
                    let hasReadabilityMarkers = readabilityMarkers.hasReadabilityClass == true
                        && readabilityMarkers.hasReaderContent == true
                        && readabilityMarkers.hasReaderHeader == true
                    debugPrint(
                        "# READERPERF readerMode.shortCircuit.precheck",
                        "url=\(resolvedURL.absoluteString)",
                        "hasReadabilityClass=\(String(describing: readabilityMarkers.hasReadabilityClass))",
                        "hasReaderContent=\(String(describing: readabilityMarkers.hasReaderContent))",
                        "hasReaderHeader=\(String(describing: readabilityMarkers.hasReaderHeader))",
                        "hasMarkers=\(hasReadabilityMarkers)",
                        "isReaderMode=\(readerModeViewModel.isReaderMode)",
                        "hasProcessedReadability=\(hasProcessedReadability)"
                    )
                    if !hasReadabilityMarkers {
                        let hasPendingReadabilityLoad = readerModeViewModel.isReaderModeLoading
                            && readerModeViewModel.isReaderModeLoadPending(for: resolvedURL)
                        if hasPendingReadabilityLoad {
                            debugPrint(
                                "# WRONGREADERMODE shortCircuitMismatchDeferred",
                                "windowURL=\(resolvedURL.absoluteString)",
                                "contentURL=\(resolvedURL.absoluteString)",
                                "reason=missingReadabilityMarkers.whilePendingReadabilityLoad",
                                "hasReadabilityClass=\(String(describing: readabilityMarkers.hasReadabilityClass))",
                                "hasReaderContent=\(String(describing: readabilityMarkers.hasReaderContent))",
                                "hasReaderHeader=\(String(describing: readabilityMarkers.hasReaderHeader))",
                                "pending=\(readerModeViewModel.pendingReaderModeURL?.absoluteString ?? "nil")",
                                "isLoading=\(readerModeViewModel.isReaderModeLoading)"
                            )
                            shouldShortCircuit = false
                        } else {
                            debugPrint(
                                "# WRONGREADERMODE shortCircuitMismatch",
                                "windowURL=\(resolvedURL.absoluteString)",
                                "contentURL=\(resolvedURL.absoluteString)",
                                "reason=missingReadabilityMarkers",
                                "hasReadabilityClass=\(String(describing: readabilityMarkers.hasReadabilityClass))",
                                "hasReaderContent=\(String(describing: readabilityMarkers.hasReaderContent))",
                                "hasReaderHeader=\(String(describing: readabilityMarkers.hasReaderHeader))"
                            )
                            debugPrint(
                                "# WRITINGDIR readerMode.stateChange",
                                "reason=shortCircuitMismatch.missingReadabilityMarkers",
                                "newValue=false",
                                "vm=\(ObjectIdentifier(readerModeViewModel).debugDescription)",
                                "resolvedURL=\(resolvedURL.absoluteString)",
                                "pageURL=\(readerViewModel.state.pageURL.absoluteString)",
                                "pending=\(readerModeViewModel.pendingReaderModeURL?.absoluteString ?? "nil")",
                                "isLoading=\(readerModeViewModel.isReaderModeLoading)",
                                "hasRenderedReadability=\(readerModeViewModel.hasRenderedReadabilityContent)",
                                "hasReadabilityClass=\(String(describing: readabilityMarkers.hasReadabilityClass))",
                                "hasReaderContent=\(String(describing: readabilityMarkers.hasReaderContent))",
                                "hasReaderHeader=\(String(describing: readabilityMarkers.hasReaderHeader))"
                            )
                            readerModeViewModel.isReaderMode = false
                            shouldShortCircuit = false
                        }
                    }
                }
                if shouldShortCircuit {
                    let shortCircuitReason = "readerModeActive"
                    if isSnippetURL {
                        debugPrint(
                            "# READER readability.shortCircuitSkipped",
                            "windowURL=\(resolvedURL.absoluteString)",
                            "contentURL=\(resolvedURL.absoluteString)",
                            "reason=\(shortCircuitReason)",
                            "snippet=true"
                        )
                    } else {
                        debugPrint(
                            "# READER readability.shortCircuit",
                            "windowURL=\(resolvedURL.absoluteString)",
                            "contentURL=\(resolvedURL.absoluteString)",
                            "reason=\(shortCircuitReason)",
                            "snippet=false"
                        )
                        await logReaderDatasetState(stage: "readabilityParsed.shortCircuit.preUpdate", url: resolvedURL, frameInfo: message.frameInfo)
                        _ = try? await scriptCaller.evaluateJavaScript("""
                            if (document.body) {
                                document.body.dataset.manabiReaderModeAvailable = 'false';
                                document.body.dataset.manabiReaderModeAvailableFor = '';
                                if (!document.body.classList.contains('readability-mode')) {
                                    try {
                                        const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.print
                                        if (handler && typeof handler.postMessage === "function") {
                                            handler.postMessage({
                                                message: "# WRONGREADERMODE readabilityModeClassMissing",
                                                context: "readabilityParsed.shortCircuit",
                                                windowURL: window.location.href,
                                                pageURL: document.location.href
                                            })
                                        }
                                    } catch (error) {
                                        try { console.log("wrongReaderMode log error", error) } catch (_) {}
                                    }
                                }
                            }
                            """)
                        try? await content.asyncWrite { _, content in
                            if content.isReaderModeAvailable {
                                content.isReaderModeAvailable = false
                                content.refreshChangeMetadata(explicitlyModified: true)
                            }
                        }
                        if !readerModeViewModel.isReaderMode {
                            debugPrint(
                                "# WRITINGDIR readerMode.stateChange",
                                "reason=readabilityParsed.shortCircuit",
                                "newValue=true",
                                "vm=\(ObjectIdentifier(readerModeViewModel).debugDescription)",
                                "resolvedURL=\(resolvedURL.absoluteString)",
                                "pageURL=\(readerViewModel.state.pageURL.absoluteString)",
                                "pending=\(readerModeViewModel.pendingReaderModeURL?.absoluteString ?? "nil")",
                                "isLoading=\(readerModeViewModel.isReaderModeLoading)",
                                "hasRenderedReadability=\(readerModeViewModel.hasRenderedReadabilityContent)"
                            )
                            readerModeViewModel.isReaderMode = true
                        }
                        if readerModeViewModel.isReaderModeLoadPending(for: resolvedURL) {
                            readerModeViewModel.markReaderModeLoadComplete(for: resolvedURL)
                        }
                        await logReaderDatasetState(stage: "readabilityParsed.shortCircuit.postUpdate", url: resolvedURL, frameInfo: message.frameInfo)
                        return
                    }
                }

                readerModeViewModel.readabilityContent = outputHTML
                readerModeViewModel.readabilityPublishedTime = result.publishedTime
                readerModeViewModel.readabilityContainerSelector = result.readabilityContainerSelector
                readerModeViewModel.readabilityContainerFrameInfo = message.frameInfo
                    debugPrint(
                        "# FLASH readability.parsed",
                        "contentURL=\(flashURLDescription(resolvedURL))",
                        "frameURL=\(flashURLDescription(message.requestURL))",
                        "outputBytes=\(outputHTML.utf8.count)",
                        "frameIsMain=\(message.isMainFrame)"
                    )
                debugPrint(
                    "# READER readabilityParsed.dispatch",
                    "contentURL=\(resolvedURL.absoluteString)",
                    "frameURL=\(message.requestURL?.absoluteString ?? "<nil>")",
                    "outputBytes=\(outputHTML.utf8.count)",
                    "frameIsMain=\(message.isMainFrame)"
                )
                if isSnippetURL {
                    debugPrint(
                        "# READER snippet.readabilityDispatch",
                        "contentURL=\(resolvedURL.absoluteString)",
                        "outputBytes=\(outputHTML.utf8.count)",
                        "willRenderImmediately=\(content.isReaderModeByDefault || forceReaderModeWhenAvailable)"
                    )
                }
                if content.isReaderModeByDefault || forceReaderModeWhenAvailable {
                    let renderInFlight = readerModeViewModel.isReadabilityRenderInFlight(for: resolvedURL)
                    if renderInFlight {
                        debugPrint(
                            "# READERPERF readerMode.render.singleFlight.skip",
                            "url=\(resolvedURL.absoluteString)",
                            "reason=readabilityParsed.dispatch",
                            "generation=nil",
                            "pending=\(readerModeViewModel.pendingReaderModeURL?.absoluteString ?? "nil")",
                            "isReaderModeLoading=\(readerModeViewModel.isReaderModeLoading)",
                            "isReaderMode=\(readerModeViewModel.isReaderMode)"
                        )
                    } else {
                        debugPrint(
                            "# FLASH readability.showReaderView.dispatch",
                            "contentURL=\(flashURLDescription(resolvedURL))",
                            "outputBytes=\(outputHTML.utf8.count)",
                            "frameIsMain=\(message.isMainFrame)"
                        )
                        debugPrint(
                            "# READERRELOAD showReaderView.dispatch",
                            "contentURL=\(resolvedURL.absoluteString)",
                            "outputBytes=\(outputHTML.utf8.count)",
                            "frameIsMain=\(message.isMainFrame)"
                        )
                        readerModeViewModel.showReaderView(
                            readerContent: readerContent,
                            scriptCaller: scriptCaller
                        )
                    }
                } else if outputHTML.lazy.filter({ String($0).hasKanji || String($0).hasKana }).prefix(51).count > 50 {
                    _ = try? await scriptCaller.evaluateJavaScript("""
                        if (document.body) {
                            document.body.dataset.manabiReaderModeAvailableConfidently = 'true';
                        }
                        """)
                }
                
                do {
                    try await ReaderContentLoader.updateContent(url: resolvedURL) { object in
                        guard !object.isReaderModeAvailable else { return false }
                        object.isReaderModeAvailable = true
                        return true
                    }
                    
                    try await { @RealmBackgroundActor in
                        let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.historyRealmConfiguration)
                        if let historyRecord = HistoryRecord.get(forURL: resolvedURL, realm: historyRealm) {
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
                    guard let windowURL = result.windowURL, !windowURL.isNativeReaderView, let _ = try await ReaderViewModel.getContent(forURL: windowURL) else { return }
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
                debugPrint(
                    "# READER ebookViewerInitialized",
                    "page=\(readerViewModel.state.pageURL.absoluteString)",
                    "frame=\(message.frameInfo.request.url?.absoluteString ?? "<nil>")"
                )
                let url = readerViewModel.state.pageURL
                if let scheme = url.scheme,
                   (scheme == "ebook" || scheme == "ebook-url"),
                   url.absoluteString.hasPrefix("\(scheme)://"),
                   url.isEBookURL,
                   let loaderURL = URL(string: "\(scheme)://\(url.absoluteString.dropFirst("\(scheme)://".count))") {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        try await scriptCaller.evaluateJavaScript(
                            "window.loadEBook({ url, layoutMode })",
                            arguments: [
                                "url": loaderURL.absoluteString,
                                //                                "layoutMode": UserDefaults.standard.string(forKey: "ebookViewerLayout") ?? "paginated"
                                "layoutMode": "paginated",
                            ]
                        )
                    }
                }
            }),
            (ReaderWebMediaBridge.messageHandlerName, { @RealmBackgroundActor [weak self] message in
                guard self != nil else { return }
                guard let decoded = ReaderWebMediaBridge.decode(message: message) else { return }
                switch decoded {
                case .readyState:
                    return
                case .media(let info):
                    ReaderWebMediaBridge.postCandidateUpdate(info)
                case .playback(let event):
                    ReaderWebMediaBridge.postPlaybackUpdate(event)

                    guard let pageURL = URL(string: event.snapshot.pageSrc),
                          !pageURL.isNativeReaderView
                    else { return }
                    guard let sourceURL = URL(string: event.snapshot.effectiveSource),
                          let scheme = sourceURL.scheme?.lowercased(),
                          scheme == "http" || scheme == "https"
                    else { return }

                    let stableMediaIdentity = MediaTranscript.stableMediaIdentity(url: sourceURL)
                    let playbackKind: ReaderPrimaryMediaKind?
                    switch event.snapshot.mediaType {
                    case .audio:
                        playbackKind = .audio
                    case .video:
                        playbackKind = .video
                    case .unknown:
                        playbackKind = nil
                    }

                    let shouldWritePlaybackPosition: Bool = switch event.eventName {
                    case .pause, .seeked, .ended, .heartbeat:
                        true
                    default:
                        false
                    }

                    let shouldWriteDuration: Bool = switch event.eventName {
                    case .loadedmetadata, .durationchange, .play, .playing:
                        true
                    default:
                        false
                    }

                    guard shouldWritePlaybackPosition || shouldWriteDuration else { return }

                    do {
                        try await ReaderContentLoader.updateContent(url: pageURL) { object in
                            guard object.primaryMediaIdentity == stableMediaIdentity else {
                                return false
                            }

                            var changed = false
                            if shouldWriteDuration,
                               event.snapshot.duration.isFinite,
                               event.snapshot.duration > 0,
                               object.primaryMediaDuration != event.snapshot.duration
                            {
                                object.primaryMediaDuration = event.snapshot.duration
                                changed = true
                            }
                            if shouldWritePlaybackPosition,
                               event.snapshot.currentTime.isFinite,
                               object.primaryMediaLastPlaybackTime != event.snapshot.currentTime
                            {
                                object.primaryMediaLastPlaybackTime = event.snapshot.currentTime
                                changed = true
                            }
                            if let playbackKind,
                               object.primaryMediaKind != playbackKind
                            {
                                object.primaryMediaKind = playbackKind
                                changed = true
                            }
                            if object.primaryMediaSourceURL != sourceURL {
                                object.primaryMediaSourceURL = sourceURL
                                changed = true
                            }
                            return changed
                        }
                    } catch {
                        print(error)
                    }
                }
            }),
            ("videoStatus", { @RealmBackgroundActor [weak self] message in
                guard let self else { return }
                do {
                    guard let result = ExternalMediaSubtitlesMessage(fromMessage: message) else { return }
                    guard let pageURL = result.pageURL, !pageURL.isNativeReaderView else { return }
                    guard let preferredTrack = result.preferredTrack(for: .autoupdatingCurrent) else { return }
                    try await ReaderContentLoader.updateContent(url: pageURL) { object in
                        if object.audioSubtitlesURL != nil && object.audioSubtitlesRole != .media {
                            return false
                        }

                        var changed = false
                        if object.audioSubtitlesURL != preferredTrack.webVTTURL {
                            object.audioSubtitlesURL = preferredTrack.webVTTURL
                            changed = true
                        }
                        if object.audioSubtitlesRole != .media {
                            object.audioSubtitlesRole = .media
                            changed = true
                        }
                        return changed
                    }

                    ReaderWebMediaBridge.postExternalSubtitlesUpdate(
                        ReaderExternalMediaSubtitlesUpdate(
                            canonicalContentURL: MediaTranscript.canonicalContentURL(from: pageURL),
                            pageURL: pageURL,
                            providerVideoID: result.providerVideoID,
                            subtitleURL: preferredTrack.webVTTURL,
                            languageCode: preferredTrack.languageCode,
                            isAutoGenerated: preferredTrack.isAutoGenerated
                        )
                    )
                } catch {
                    print(error)
                }
            })
        ]
        return WebViewMessageHandlers(handlers)
    }()
    
    private func trimmedDatasetSummary(_ summary: String) -> String {
        summary.count <= 360 ? summary : String(summary.prefix(360)) + "…"
    }
    
    private func unwrapJavaScriptValue(_ value: Any?) -> Any? {
        guard let value else { return nil }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else {
            return value
        }
        if let child = mirror.children.first {
            return unwrapJavaScriptValue(child.value)
        }
        return nil
    }
    
    private func datasetSummaryString(from value: Any?) -> String? {
        guard let unwrapped = unwrapJavaScriptValue(value) else {
            return nil
        }
        if let string = unwrapped as? String {
            return trimmedDatasetSummary(string)
        }
        if let nsString = unwrapped as? NSString {
            return trimmedDatasetSummary(nsString as String)
        }
        if unwrapped is NSNull {
            return nil
        }
        if let data = unwrapped as? Data, let string = String(data: data, encoding: .utf8) {
            return trimmedDatasetSummary(string)
        }
        if JSONSerialization.isValidJSONObject(unwrapped),
           let jsonData = try? JSONSerialization.data(withJSONObject: unwrapped, options: [.sortedKeys]),
           let string = String(data: jsonData, encoding: .utf8) {
            return trimmedDatasetSummary(string)
        }
        return nil
    }

    private func summarizeBodyMarkup(from html: String, maxLength: Int = 360) -> String? {
        guard let bodyRange = html.range(of: "<body", options: [.caseInsensitive]) else {
            return nil
        }
        let start = bodyRange.lowerBound
        guard let openTagEnd = html[start...].firstIndex(of: ">") else { return nil }
        let afterOpen = html.index(after: openTagEnd)
        let searchRange = afterOpen..<html.endIndex
        let closingRange = html.range(of: "</body", options: [.caseInsensitive], range: searchRange)
        let end: String.Index
        if let closingRange,
           let closingGT = html[closingRange.lowerBound...].firstIndex(of: ">") {
            end = html.index(after: closingGT)
        } else {
            end = html.endIndex
        }
        var snippet = String(html[start..<end])
        snippet = snippet.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        snippet = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        if snippet.count > maxLength {
            let idx = snippet.index(snippet.startIndex, offsetBy: maxLength)
            snippet = String(snippet[..<idx]) + "…"
        }
        return snippet.isEmpty ? nil : snippet
    }
    
    private func setHideNavigationDueToScroll(
        _ shouldHide: Bool,
        reason: String? = nil,
        source: String? = nil,
        direction: String? = nil
    ) {
        let previousValue = hideNavigationDueToScroll.wrappedValue
        debugPrint(
            "# HIDENAV set request prev=\(previousValue) new=\(shouldHide) url=\(readerContent.pageURL.absoluteString) reason=\(reason ?? "<nil>") source=\(source ?? "<nil>") direction=\(direction ?? "<nil>")"
        )
        guard previousValue != shouldHide else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            hideNavigationDueToScroll.wrappedValue = shouldHide
        }
    }
    
    private func handleNavigationVisibility(for result: FractionalCompletionMessage) {
        let normalizedReason = result.reason.lowercased()
        debugPrint("# HIDENAV handler updateReadingProgress reason=\(result.reason) normalized=\(normalizedReason)")
        if ["navigation", "selection", "live-scroll"].contains(normalizedReason) {
            if normalizedReason == "navigation",
               let event = latestNavigationVisibilityEvent,
               event.shouldHide,
               event.direction == "forward",
               Date().timeIntervalSince(event.timestamp) < 0.8 {
                debugPrint(
                    "# HIDENAV handler updateReadingProgress navigation skipped due to recent forward hide event delta=\(String(format: "%.3f", Date().timeIntervalSince(event.timestamp))) source=\(event.source ?? "<nil>")"
                )
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

    private var latestNavigationVisibilityEvent: ReaderNavigationVisibilityEvent? {
        [lastNavigationVisibilityEvent, navigationVisibilityCoordinator.lastHostPageTurnEvent]
            .compactMap { $0 }
            .max { lhs, rhs in
                lhs.timestamp < rhs.timestamp
            }
    }
    
    private func readerDatasetSummary(stage: String, frameInfo: WKFrameInfo?) async -> String? {
        do {
            let rawResult: Any?
            if let frameInfo {
                rawResult = try await scriptCaller.evaluateJavaScript(readerModeDatasetProbeScript, in: frameInfo)
            } else {
                rawResult = try await scriptCaller.evaluateJavaScript(readerModeDatasetProbeScript)
            }
            if let summary = datasetSummaryString(from: rawResult) {
                return summary
            }
            let fallbackRaw: Any?
            if let frameInfo {
                fallbackRaw = try? await scriptCaller.evaluateJavaScript("return window.manabiDatasetDebugSummary ?? null", in: frameInfo)
            } else {
                fallbackRaw = try? await scriptCaller.evaluateJavaScript("return window.manabiDatasetDebugSummary ?? null")
            }
            if let summary = datasetSummaryString(from: fallbackRaw) {
                return summary
            }
        } catch {
            debugPrint("# FLASH ReaderMessageHandlers.readerDatasetSummary error", error.localizedDescription)
        }
        return nil
    }
    
    private func logReaderDatasetState(stage: String, url: URL, frameInfo: WKFrameInfo?) async {
        let summary = await readerDatasetSummary(stage: stage, frameInfo: frameInfo)
        let pending = readerModeViewModel.pendingReaderModeURL?.absoluteString ?? "nil"
        let expected = readerModeViewModel.expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil"
        let isLoading = readerModeViewModel.isReaderModeLoading
        let isReaderMode = readerModeViewModel.isReaderMode
        debugPrint(
            "# READERPERF dataset.state",
            "stage=\(stage)",
            "url=\(url.absoluteString)",
            "frameIsMain=\(frameInfo?.isMainFrame ?? true)",
            "pending=\(pending)",
            "expectedLoader=\(expected)",
            "isReaderModeLoading=\(isLoading)",
            "isReaderMode=\(isReaderMode)",
            "summary=\(summary ?? "nil")"
        )
    }
    
    init(
        forceReaderModeWhenAvailable: Bool,
        scriptCaller: WebViewScriptCaller,
        readerViewModel: ReaderViewModel,
        readerModeViewModel: ReaderModeViewModel,
        readerContent: ReaderContent,
        navigator: WebViewNavigator,
        hideNavigationDueToScroll: Binding<Bool>,
        navigationVisibilityCoordinator: ReaderNavigationVisibilityCoordinator,
        updateReadingProgressHandler: ((FractionalCompletionMessage) async -> Void)?,
        contentBlockingEnabled: Bool,
        contentBlockingStatsModel: AdblockStatsModel?
    ) {
        self.forceReaderModeWhenAvailable = forceReaderModeWhenAvailable
        self.scriptCaller = scriptCaller
        self.readerViewModel = readerViewModel
        self.readerModeViewModel = readerModeViewModel
        self.readerContent = readerContent
        self.navigator = navigator
        self.hideNavigationDueToScroll = hideNavigationDueToScroll
        self.navigationVisibilityCoordinator = navigationVisibilityCoordinator
        self.updateReadingProgressHandler = updateReadingProgressHandler
        self.contentBlockingEnabled = contentBlockingEnabled
        self.contentBlockingStatsModel = contentBlockingStatsModel
    }
    
    // MARK: Readability
    
    @MainActor
    func showOriginal() async throws {
        let contentURL = readerContent.content?.url
            ?? ReaderContentLoader.getContentURL(fromLoaderURL: readerContent.pageURL)
            ?? readerContent.pageURL
        debugPrint(
            "# READERRELOAD viewOriginal.enter",
            "pageURL=\(readerContent.pageURL.absoluteString)",
            "contentURL=\(readerContent.content?.url.absoluteString ?? "nil")",
            "readerDefault=\(readerContent.content?.isReaderModeByDefault ?? false)",
            "isReaderMode=\(readerModeViewModel.isReaderMode)",
            "isReaderModeLoading=\(readerModeViewModel.isReaderModeLoading)"
        )
        if readerContent.content == nil {
            debugPrint(
                "# READERRELOAD viewOriginal.skipPersist",
                "reason=missingContent",
                "pageURL=\(readerContent.pageURL.absoluteString)"
            )
        }
        try await ReaderContentLoader.updateContent(url: contentURL) { object in
            let shouldEnableAvailability = object.hasHTML
            guard object.isReaderModeByDefault || (shouldEnableAvailability && !object.isReaderModeAvailable) else {
                return false
            }
            object.isReaderModeByDefault = false
            if shouldEnableAvailability {
                object.isReaderModeAvailable = true
            }
            return true
        }
        debugPrint(
            "# READERRELOAD viewOriginal.defaultDisabled",
            "contentURL=\(readerContent.content?.url.absoluteString ?? "nil")"
        )
        debugPrint(
            "# READERRELOAD viewOriginal.persisted",
            "contentURL=\(readerContent.content?.url.absoluteString ?? "nil")"
        )
        debugPrint(
            "# WRITINGDIR readerMode.stateChange",
            "reason=viewOriginal",
            "newValue=false",
            "vm=\(ObjectIdentifier(readerModeViewModel).debugDescription)",
            "contentURL=\(contentURL.absoluteString)",
            "pageURL=\(readerContent.pageURL.absoluteString)",
            "pending=\(readerModeViewModel.pendingReaderModeURL?.absoluteString ?? "nil")",
            "isLoading=\(readerModeViewModel.isReaderModeLoading)",
            "hasRenderedReadability=\(readerModeViewModel.hasRenderedReadabilityContent)"
        )
        readerModeViewModel.isReaderMode = false
        readerModeViewModel.clearReadabilityCache(for: contentURL, reason: "viewOriginal")
        debugPrint(
            "# READERRELOAD viewOriginal.reload",
            "pageURL=\(readerContent.pageURL.absoluteString)",
            "contentURL=\(readerContent.content?.url.absoluteString ?? "nil")"
        )
        navigator.reload()
    }
}

internal struct ReaderMessageHandlersViewModifier: ViewModifier {
    var forceReaderModeWhenAvailable = false
    var hideNavigationDueToScroll: Binding<Bool> = .constant(false)
    var navigationVisibilityCoordinator = ReaderNavigationVisibilityCoordinator()
    
    @AppStorage("ebookViewerLayout") internal var ebookViewerLayout = "paginated"
    
    @EnvironmentObject internal var scriptCaller: WebViewScriptCaller
    @EnvironmentObject internal var readerViewModel: ReaderViewModel
    @EnvironmentObject internal var readerModeViewModel: ReaderModeViewModel
    @EnvironmentObject internal var readerContent: ReaderContent
    @Environment(\.webViewMessageHandlers) internal var webViewMessageHandlers
    @Environment(\.webViewNavigator) internal var navigator: WebViewNavigator
    @Environment(\.readerUpdateReadingProgressHandler) private var updateReadingProgressHandler
    @Environment(\.contentBlockingEnabled) private var contentBlockingEnabled
    @Environment(\.contentBlockingStatsModel) private var contentBlockingStatsModel
    
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
                        navigationVisibilityCoordinator: navigationVisibilityCoordinator,
                        updateReadingProgressHandler: updateReadingProgressHandler,
                        contentBlockingEnabled: contentBlockingEnabled,
                        contentBlockingStatsModel: contentBlockingStatsModel
                    )
                } else if let readerMessageHandlers {
                    readerMessageHandlers.forceReaderModeWhenAvailable = forceReaderModeWhenAvailable
                    readerMessageHandlers.scriptCaller = scriptCaller
                    readerMessageHandlers.readerViewModel = readerViewModel
                    readerMessageHandlers.readerModeViewModel = readerModeViewModel
                    readerMessageHandlers.readerContent = readerContent
                    readerMessageHandlers.navigator = navigator
                    readerMessageHandlers.hideNavigationDueToScroll = hideNavigationDueToScroll
                    readerMessageHandlers.navigationVisibilityCoordinator = navigationVisibilityCoordinator
                    readerMessageHandlers.updateReadingProgressHandler = updateReadingProgressHandler
                    readerMessageHandlers.contentBlockingEnabled = contentBlockingEnabled
                    readerMessageHandlers.contentBlockingStatsModel = contentBlockingStatsModel
                }
            }
            .task(id: webViewMessageHandlers.handlers.keys) {
                let handlerKeys = Array(webViewMessageHandlers.handlers.keys)
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
                contentBlockingStatsModel?.beginPage(url: readerViewModel.state.pageURL)
            }
            .task(id: readerContent.pageURL) {
                await pushHideNavigationStateToWebView()
            }
            .task(id: contentBlockingEnabled) {
                readerMessageHandlers?.contentBlockingEnabled = contentBlockingEnabled
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
            debugPrint("# HIDENAV sync error \(error.localizedDescription)")
        }
    }
}
