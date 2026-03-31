import SwiftUI
import RealmSwift
import LakeKit
import SwiftUIWebView
import WebKit
import SwiftSoup
import Combine
import RealmSwiftGaps
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent
import LakeOfFireFiles

@MainActor
private func logLookupSmar10(_ payload: [String: Any]) {
    debugPrint("# LOOKUPSMAR10", payload)
}

// To avoid redraws...
@MainActor
private class ReaderWebViewHandler {
    var onNavigationCommitted: ((WebViewState) async throws -> Void)?
    var onNavigationFinished: ((WebViewState) -> Void)?
    var onNavigationFailed: ((WebViewState) -> Void)?
    var onURLChanged: ((WebViewState) async throws -> Void)?

    var readerContent: ReaderContent
    var readerViewModel: ReaderViewModel
    var readerModeViewModel: ReaderModeViewModel
    var readerMediaPlayerViewModel: ReaderMediaPlayerViewModel
    var scriptCaller: WebViewScriptCaller

    private let navigationTaskManager = NavigationTaskManager()
    private var lastHandledURL: URL?
    private var lastHandledIsProvisionallyNavigating: Bool?
    private var lastHandledIsLoading: Bool?
    private var readerLoadStartTimes: [String: Date] = [:]
    private var readerLoadStartSources: [String: String] = [:]
    private var deferredCachedReadabilityRenderTask: Task<Void, Never>?
    private var deferredReaderModeRecoveryTask: Task<Void, Never>?

    private func snippetCachedReaderHTMLIsRenderable(_ html: String) -> Bool {
        guard !html.isEmpty else { return false }
        do {
            let document = try SwiftSoup.parse(html)
            if (try? document.getElementsByTag("manabi-segment").size()) ?? 0 > 0 {
                return true
            }
            if (try? document.getElementById("reader-content")) != nil {
                return true
            }
            if let body = try? document.body() {
                if (try? body.hasClass("readability-mode")) == true {
                    return true
                }
                if (try? body.attr("data-next-load-is-readability-mode")) == "true" {
                    return true
                }
            }
        } catch {
            return false
        }
        return false
    }

    init(
        onNavigationCommitted: ((WebViewState) async throws -> Void)? = nil,
        onNavigationFinished: ((WebViewState) -> Void)? = nil,
        onNavigationFailed: ((WebViewState) -> Void)? = nil,
        onURLChanged: ((WebViewState) async throws -> Void)? = nil,
        readerContent: ReaderContent,
        readerViewModel: ReaderViewModel,
        readerModeViewModel: ReaderModeViewModel,
        readerMediaPlayerViewModel: ReaderMediaPlayerViewModel,
        scriptCaller: WebViewScriptCaller
    ) {
        self.onNavigationCommitted = onNavigationCommitted
        self.onNavigationFinished = onNavigationFinished
        self.onNavigationFailed = onNavigationFailed
        self.onURLChanged = onURLChanged
        self.readerContent = readerContent
        self.readerViewModel = readerViewModel
        self.readerModeViewModel = readerModeViewModel
        self.readerMediaPlayerViewModel = readerMediaPlayerViewModel
        self.scriptCaller = scriptCaller
    }

    private func parseJSONStringObject(_ value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            return dictionary
        }
        if let dictionary = value as? NSDictionary {
            return dictionary as? [String: Any]
        }
        if let string = value as? String,
           let data = string.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }
        if let data = value as? Data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }
        return nil
    }

    private func logNativeReaderSurfaceSnapshot(source: String, state: WebViewState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await self.scriptCaller.evaluateJavaScript(
                    """
                    (() => {
                      const firstTrackingButton = document.querySelector('.manabi-mark-section-as-read-button');
                      const finishedReadingButton = document.getElementById('manabi-finished-reading-button');
                      const firstSegment = document.querySelector('manabi-segment');
                      const firstSurface = document.querySelector('manabi-surface');
                      const readerSections = document.getElementsByClassName('manabi-tracking-section');
                      const styleFor = (element) => element ? getComputedStyle(element) : null;
                      const trackingStyle = styleFor(firstTrackingButton);
                      const finishedStyle = styleFor(finishedReadingButton);
                      const segmentStyle = styleFor(firstSegment);
                      const surfaceStyle = styleFor(firstSurface);
                      return {
                        livePageURL: window.location.href,
                        trackingButtonCount: document.getElementsByClassName('manabi-mark-section-as-read-button').length,
                        visibleTrackingButtonCount: Array.from(document.getElementsByClassName('manabi-mark-section-as-read-button')).filter((button) => {
                          const style = getComputedStyle(button);
                          return style.display !== 'none' && style.visibility !== 'hidden' && Number.parseFloat(style.opacity || '1') > 0.01;
                        }).length,
                        finishedReadingButtonPresent: Boolean(finishedReadingButton),
                        finishedReadingButtonDisplay: finishedStyle?.display ?? null,
                        finishedReadingButtonVisibility: finishedStyle?.visibility ?? null,
                        finishedReadingButtonOpacity: finishedStyle?.opacity ?? null,
                        finishedReadingButtonWidth: finishedReadingButton?.getBoundingClientRect?.().width ?? null,
                        finishedReadingButtonHeight: finishedReadingButton?.getBoundingClientRect?.().height ?? null,
                        sectionCount: readerSections.length,
                        segmentCount: document.getElementsByTagName('manabi-segment').length,
                        firstTrackingButtonDisplay: trackingStyle?.display ?? null,
                        firstTrackingButtonVisibility: trackingStyle?.visibility ?? null,
                        firstTrackingButtonOpacity: trackingStyle?.opacity ?? null,
                        firstTrackingButtonWidth: firstTrackingButton?.getBoundingClientRect?.().width ?? null,
                        firstTrackingButtonHeight: firstTrackingButton?.getBoundingClientRect?.().height ?? null,
                        firstSegmentUserSelect: segmentStyle?.userSelect ?? null,
                        firstSegmentTouchAction: segmentStyle?.touchAction ?? null,
                        firstSegmentPointerEvents: segmentStyle?.pointerEvents ?? null,
                        firstSurfaceUserSelect: surfaceStyle?.userSelect ?? null,
                        firstSurfacePointerEvents: surfaceStyle?.pointerEvents ?? null
                      };
                    })()
                    """
                )
                guard let payload = self.parseJSONStringObject(result) else {
                    guard result != nil else { return }
                    logLookupSmar10([
                        "stage": "native.readerSurfaceSnapshot",
                        "source": source,
                        "pageURL": state.pageURL.absoluteString,
                        "error": "unexpectedResultType",
                        "type": String(describing: Swift.type(of: result!))
                    ])
                    return
                }
                var enriched = payload
                enriched["stage"] = "native.readerSurfaceSnapshot"
                enriched["source"] = source
                enriched["pageURL"] = state.pageURL.absoluteString
                logLookupSmar10(enriched)
            } catch {
                logLookupSmar10([
                    "stage": "native.readerSurfaceSnapshot",
                    "source": source,
                    "pageURL": state.pageURL.absoluteString,
                    "error": String(describing: error)
                ])
            }
        }
    }

    private func logNativeViewportDOMProbe(source: String, state: WebViewState) {
        guard ProcessInfo.processInfo.environment["MANABI_LOOKUP_NATIVE_DOM_PROBE"] == "1" else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            logLookupSmar10([
                "stage": "native.webView.viewport.domProbe.requested",
                "source": source,
                "pageURL": state.pageURL.absoluteString
            ])
            guard !state.pageURL.isReaderURLLoaderURL else {
                logLookupSmar10([
                    "stage": "native.webView.viewport.domProbe.skipped",
                    "source": source,
                    "pageURL": state.pageURL.absoluteString,
                    "reason": "loaderURL"
                ])
                return
            }
            guard state.pageURL.absoluteString != "about:blank" else {
                logLookupSmar10([
                    "stage": "native.webView.viewport.domProbe.skipped",
                    "source": source,
                    "pageURL": state.pageURL.absoluteString,
                    "reason": "aboutBlank"
                ])
                return
            }
            do {
                let result = try await self.scriptCaller.evaluateJavaScript(
                    """
                    (() => {
                      const viewportX = window.innerWidth / 2;
                      const viewportY = window.innerHeight / 2;
                      const elementAtCenter = document.elementFromPoint(viewportX, viewportY);
                      const firstVisibleButton = Array.from(document.querySelectorAll('.manabi-mark-section-as-read-button')).find((button) => {
                        const style = getComputedStyle(button);
                        return style.display !== 'none' && style.visibility !== 'hidden' && Number.parseFloat(style.opacity || '1') > 0.01;
                      }) ?? null;
                      const firstSegment = document.querySelector('manabi-segment');
                      const firstSurface = document.querySelector('manabi-surface');
                      const describe = (node) => {
                        if (!node) return null;
                        const rect = typeof node.getBoundingClientRect === 'function' ? node.getBoundingClientRect() : null;
                        const style = getComputedStyle(node);
                        return {
                          tag: node.tagName ?? null,
                          id: node.id ?? null,
                          className: typeof node.className === 'string' ? node.className : null,
                          textSample: (node.textContent || '').trim().slice(0, 80),
                          pointerEvents: style.pointerEvents ?? null,
                          userSelect: style.userSelect ?? null,
                          touchAction: style.touchAction ?? null,
                          opacity: style.opacity ?? null,
                          display: style.display ?? null,
                          visibility: style.visibility ?? null,
                          backgroundColor: style.backgroundColor ?? null,
                          color: style.color ?? null,
                          rect: rect ? { x: rect.x, y: rect.y, width: rect.width, height: rect.height } : null
                        };
                      };
                      return JSON.stringify({
                        source,
                        viewportX,
                        viewportY,
                        bodyClassName: document.body?.className ?? null,
                        readerContentClassName: document.getElementById('reader-content')?.className ?? null,
                        visibleTrackingButtonCount: Array.from(document.querySelectorAll('.manabi-mark-section-as-read-button')).filter((button) => {
                          const style = getComputedStyle(button);
                          return style.display !== 'none' && style.visibility !== 'hidden' && Number.parseFloat(style.opacity || '1') > 0.01;
                        }).length,
                        sectionCount: document.querySelectorAll('.manabi-tracking-section').length,
                        segmentCount: document.querySelectorAll('manabi-segment').length,
                        elementAtCenter: describe(elementAtCenter),
                        centerClosestSegment: describe(elementAtCenter?.closest?.('manabi-segment') ?? null),
                        centerClosestSurface: describe(elementAtCenter?.closest?.('manabi-surface') ?? null),
                        firstVisibleButton: describe(firstVisibleButton),
                        firstSegment: describe(firstSegment),
                        firstSurface: describe(firstSurface)
                      });
                    })()
                    """,
                    arguments: ["source": source]
                )
                guard let payload = self.parseJSONStringObject(result) else {
                    guard result != nil else {
                        logLookupSmar10([
                            "stage": "native.webView.viewport.domProbe",
                            "source": source,
                            "pageURL": state.pageURL.absoluteString,
                            "error": "nilResult"
                        ])
                        return
                    }
                    logLookupSmar10([
                        "stage": "native.webView.viewport.domProbe",
                        "source": source,
                        "pageURL": state.pageURL.absoluteString,
                        "error": "unexpectedResultType",
                        "type": String(describing: Swift.type(of: result!))
                    ])
                    return
                }
                var flattened: [String: Any] = [
                    "stage": "native.webView.viewport.domProbe",
                    "source": source,
                    "pageURL": state.pageURL.absoluteString
                ]
                for (key, value) in payload {
                    if let dictionary = value as? [String: Any],
                       let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]),
                       let string = String(data: data, encoding: .utf8) {
                        flattened[key] = string
                    } else if let array = value as? [Any],
                              let data = try? JSONSerialization.data(withJSONObject: array, options: [.sortedKeys]),
                              let string = String(data: data, encoding: .utf8) {
                        flattened[key] = string
                    } else {
                        flattened[key] = value ?? "nil"
                    }
                }
                logLookupSmar10(flattened)
            } catch {
                logLookupSmar10([
                    "stage": "native.webView.viewport.domProbe",
                    "source": source,
                    "pageURL": state.pageURL.absoluteString,
                    "error": String(describing: error)
                ])
            }
        }
    }

    private func readerLoadKey(for url: URL) -> String {
        let resolvedURL = ReaderContentLoader.getContentURL(fromLoaderURL: url) ?? url
        return resolvedURL.absoluteString
    }

    private func markReaderLoadStart(for url: URL, source: String) {
        let key = readerLoadKey(for: url)
        guard readerLoadStartTimes[key] == nil else { return }
        readerLoadStartTimes[key] = Date()
        readerLoadStartSources[key] = source
        debugPrint(
            "# READERLOAD stage=readerWebView.navigationStart",
            "source=\(source)",
            "url=\(url.absoluteString)",
            "key=\(key)"
        )
    }

    private func finishReaderLoad(for url: URL, outcome: String) {
        let key = readerLoadKey(for: url)
        let start = readerLoadStartTimes.removeValue(forKey: key)
        let source = readerLoadStartSources.removeValue(forKey: key) ?? "unknown"
        guard let start else {
            debugPrint(
                "# READERLOAD stage=readerWebView.navigationEnd",
                "outcome=\(outcome)",
                "source=\(source)",
                "url=\(url.absoluteString)",
                "key=\(key)",
                "elapsed=nil"
            )
            return
        }
        let elapsed = Date().timeIntervalSince(start)
        debugPrint(
            "# READERLOAD stage=readerWebView.navigationEnd",
            "outcome=\(outcome)",
            "source=\(source)",
            "url=\(url.absoluteString)",
            "key=\(key)",
            "elapsed=\(String(format: "%.3fs", elapsed))",
            "slow=\(elapsed >= 2.5)"
        )
    }

    private func renderCachedReadabilityHTML(
        _ cachedHTML: String,
        for content: ReaderContentProtocol,
        pageURL: URL
    ) {
        readerModeViewModel.readabilityContent = cachedHTML
        readerModeViewModel.readabilityContainerSelector = nil
        readerModeViewModel.readabilityContainerFrameInfo = nil
        readerModeViewModel.showReaderView(
            readerContent: readerContent,
            scriptCaller: scriptCaller
        )
        debugPrint(
            "# READERRELOAD cachedReadability.rendered",
            "pageURL=\(pageURL.absoluteString)",
            "contentURL=\(content.url.absoluteString)",
            "hasAsyncCaller=\(scriptCaller.hasAsyncCaller)"
        )
    }

    private func deferCachedReadabilityRenderUntilAsyncCallerReady(
        cachedHTML: String,
        content: ReaderContentProtocol,
        pageURL: URL
    ) {
        deferredCachedReadabilityRenderTask?.cancel()
        deferredCachedReadabilityRenderTask = Task { @MainActor in
            for _ in 0..<100 {
                guard !Task.isCancelled else { return }
                if self.scriptCaller.hasAsyncCaller {
                    self.renderCachedReadabilityHTML(cachedHTML, for: content, pageURL: pageURL)
                    return
                }

                do {
                    try await Task.sleep(nanoseconds: 20_000_000)
                } catch {
                    return
                }
            }

            debugPrint(
                "# READERRELOAD cachedReadability.deferTimedOut",
                "pageURL=\(pageURL.absoluteString)",
                "contentURL=\(content.url.absoluteString)"
            )
        }
    }

    private func deferReaderModeRecoveryUntilAsyncCallerReady(
        content: ReaderContentProtocol,
        pageURL: URL,
        reason: String
    ) {
        let contentURL = content.url
        deferredReaderModeRecoveryTask?.cancel()
        deferredReaderModeRecoveryTask = Task { @MainActor in
            for _ in 0..<100 {
                guard !Task.isCancelled else { return }
                if self.scriptCaller.hasAsyncCaller {
                    guard self.readerContent.pageURL == pageURL,
                          self.readerContent.content?.url == contentURL else {
                        debugPrint(
                            "# READERLOAD stage=readerWebView.recoverAfterAsyncCaller.cancelledForNavigationChange",
                            "reason=\(reason)",
                            "expectedPageURL=\(pageURL.absoluteString)",
                            "currentPageURL=\(self.readerContent.pageURL.absoluteString)",
                            "expectedContentURL=\(contentURL.absoluteString)",
                            "currentContentURL=\(self.readerContent.content?.url.absoluteString ?? "nil")"
                        )
                        return
                    }
                    let hasPreparedReadability = self.readerModeViewModel.readabilityContent != nil
                    let shouldRecoverReaderMode =
                        content.isReaderModeByDefault
                        && content.hasHTML
                        && !self.readerModeViewModel.isReaderMode
                        && !self.readerModeViewModel.isReaderModeLoading
                        && !self.readerModeViewModel.isReadabilityRenderInFlight(for: content.url)
                    guard shouldRecoverReaderMode else { return }

                    debugPrint(
                        "# READERLOAD stage=readerWebView.recoverAfterAsyncCaller",
                        "reason=\(reason)",
                        "pageURL=\(pageURL.absoluteString)",
                        "contentURL=\(content.url.absoluteString)",
                        "hasPreparedReadability=\(hasPreparedReadability)"
                    )

                    if hasPreparedReadability {
                        self.readerModeViewModel.showReaderView(
                            readerContent: self.readerContent,
                            scriptCaller: self.scriptCaller
                        )
                    } else {
                        self.readerModeViewModel.showReaderView(
                            readerContent: self.readerContent,
                            scriptCaller: self.scriptCaller
                        )
                    }
                    return
                }

                do {
                    try await Task.sleep(nanoseconds: 20_000_000)
                } catch {
                    return
                }
            }

            debugPrint(
                "# READERLOAD stage=readerWebView.recoverAfterAsyncCaller.timedOut",
                "reason=\(reason)",
                "pageURL=\(pageURL.absoluteString)",
                "contentURL=\(content.url.absoluteString)"
            )
        }
    }

    func handleNewURL(state: WebViewState, source: String) async throws {
        debugPrint(
            "# FLASH ReaderWebViewHandler.handleNewURL start",
            "page=\(flashURLDescription(state.pageURL))",
            "loading=\(state.isLoading)",
            "provisional=\(state.isProvisionallyNavigating)",
            "source=\(source)"
        )
        debugPrint(
            "# READERPERF webView.state",
            "ts=\(Date().timeIntervalSince1970)",
            "url=\(state.pageURL.absoluteString)",
            "loading=\(state.isLoading)",
            "provisional=\(state.isProvisionallyNavigating)",
            "source=\(source)",
            "pendingReaderMode=\(readerModeViewModel.isReaderModeLoadPending(for: state.pageURL))"
        )

        if state.pageURL.isReaderURLLoaderURL,
           let contentURL = ReaderContentLoader.getContentURL(fromLoaderURL: state.pageURL),
           contentURL.isSnippetURL {
            debugPrint(
                "# READER snippet.loaderNavigation",
                "loaderURL=\(state.pageURL.absoluteString)",
                "contentURL=\(contentURL.absoluteString)",
                "provisional=\(state.isProvisionallyNavigating)",
                "loading=\(state.isLoading)"
            )
        }

        if state.pageURL.absoluteString == "about:blank" {
            debugPrint("# FLASH ReaderWebViewHandler.handleNewURL native reader view", "page=\(flashURLDescription(state.pageURL))")
            let cancelURL = readerContent.content?.url ?? readerContent.pageURL
            let pendingCanonicalURL = readerModeViewModel.pendingReaderModeURL?.canonicalReaderContentURL()
            let shouldPreserveSnippetReaderModeLoad =
                cancelURL.canonicalReaderContentURL().isSnippetURL
                || pendingCanonicalURL?.isSnippetURL == true
            debugPrint(
                "# READERLOAD stage=readerWebView.aboutBlankCancel",
                "source=\(source)",
                "stateURL=\(state.pageURL.absoluteString)",
                "cancelURL=\(cancelURL.absoluteString)",
                "contentURLBeforeLoad=\(readerContent.content?.url.absoluteString ?? "nil")",
                "pending=\(readerModeViewModel.pendingReaderModeURL?.absoluteString ?? "nil")",
                "expected=\(readerModeViewModel.expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")",
                "isReaderModeLoading=\(readerModeViewModel.isReaderModeLoading)",
                "preserveSnippetLoad=\(shouldPreserveSnippetReaderModeLoad)"
            )
            if !shouldPreserveSnippetReaderModeLoad {
                readerModeViewModel.cancelReaderModeLoad(for: cancelURL)
            }
        }

        if let lastHandledURL, lastHandledURL.matchesReaderURL(state.pageURL), lastHandledIsProvisionallyNavigating == state.isProvisionallyNavigating, lastHandledIsLoading == state.isLoading {
            debugPrint("# FLASH ReaderWebViewHandler.handleNewURL skipping duplicate", "page=\(flashURLDescription(state.pageURL))")
            return
        }

        lastHandledURL = state.pageURL
        lastHandledIsProvisionallyNavigating = state.isProvisionallyNavigating
        lastHandledIsLoading = state.isLoading

        try Task.checkCancellation()
        let contentLoadStartedAt = Date()
        try await readerContent.load(url: state.pageURL)
        let contentLoadElapsed = Date().timeIntervalSince(contentLoadStartedAt)
        debugPrint(
            "# READERLOAD stage=readerWebView.contentResolved",
            "source=\(source)",
            "stateURL=\(state.pageURL.absoluteString)",
            "contentURL=\(readerContent.content?.url.absoluteString ?? "nil")",
            "elapsed=\(String(format: "%.3fs", contentLoadElapsed))",
            "slow=\(contentLoadElapsed >= 0.8)"
        )
        debugPrint(
            "# READERRELOAD webView.handleNewURL",
            "pageURL=\(state.pageURL.absoluteString)",
            "readerContentURL=\(readerContent.content?.url.absoluteString ?? "nil")",
            "displayURL=\(readerContent.pageURL.absoluteString)",
            "isReaderMode=\(readerModeViewModel.isReaderMode)",
            "isReaderModeLoading=\(readerModeViewModel.isReaderModeLoading)"
        )
        if let content = readerContent.content,
           content.isReaderModeByDefault,
           !readerModeViewModel.isReaderMode,
           !readerModeViewModel.isReaderModeLoading,
           readerModeViewModel.pendingReaderModeURL == nil,
           !content.url.isNativeReaderView {
            debugPrint(
                "# READERLOAD stage=readerWebView.autoBeginReaderModeLoad",
                "source=\(source)",
                "stateURL=\(state.pageURL.absoluteString)",
                "contentURL=\(content.url.absoluteString)",
                "isReaderModeByDefault=\(content.isReaderModeByDefault)",
                "pending=\(readerModeViewModel.pendingReaderModeURL?.absoluteString ?? "nil")",
                "expected=\(readerModeViewModel.expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")",
                "isReaderModeLoading=\(readerModeViewModel.isReaderModeLoading)"
            )
            debugPrint(
                "# READERRELOAD readerMode.beginLoad",
                "reason=webView.handleNewURL",
                "pageURL=\(state.pageURL.absoluteString)",
                "contentURL=\(content.url.absoluteString)"
            )
            readerModeViewModel.beginReaderModeLoad(
                for: content.url,
                suppressSpinner: true,
                reason: "reload.handleNewURL"
            )
        }
        if state.pageURL.isSnippetURL {
            debugPrint("# FLASH ReaderWebViewHandler.handleNewURL snippetPageLoaded", "page=\(flashURLDescription(state.pageURL))")
        }
        if let current = readerContent.content {
            debugPrint(
                "# READER content.state",
                "pageURL=\(state.pageURL.absoluteString)",
                "contentURL=\(current.url.absoluteString)",
                "isSnippet=\(current.url.isSnippetURL)",
                "readerDefault=\(current.isReaderModeByDefault)",
                "hasHTML=\(current.hasHTML)",
                "rssFull=\(current.rssContainsFullContent)"
            )
        } else {
            debugPrint("# READER content.state", "pageURL=\(state.pageURL.absoluteString)", "contentURL=<nil>")
        }
        debugPrint("# FLASH ReaderWebViewHandler.handleNewURL readerContent loaded", "page=\(flashURLDescription(state.pageURL))")
        try Task.checkCancellation()
        guard let content = readerContent.content else {
            debugPrint("# FLASH ReaderWebViewHandler.handleNewURL missing readerContent.content", "page=\(flashURLDescription(state.pageURL))")
            return
        }

        // TODO: Add onURLChanged or rename these view model methods to be more generic...
        try await readerViewModel.onNavigationCommitted(content: content, newState: state)
        debugPrint("# FLASH ReaderWebViewHandler.handleNewURL readerViewModel committed", "page=\(flashURLDescription(state.pageURL))")
        try Task.checkCancellation()
        try await readerModeViewModel.onNavigationCommitted(
            readerContent: readerContent,
            newState: state,
            scriptCaller: scriptCaller
        )
        debugPrint("# FLASH ReaderWebViewHandler.handleNewURL readerModeViewModel committed", "page=\(flashURLDescription(state.pageURL))")
        try Task.checkCancellation()
        guard let content = readerContent.content, content.url.matchesReaderURL(state.pageURL) else { return }
        try await readerMediaPlayerViewModel.onNavigationCommitted(content: content, newState: state)
        debugPrint("# FLASH ReaderWebViewHandler.handleNewURL mediaPlayer committed", "page=\(flashURLDescription(state.pageURL))")
        try Task.checkCancellation()
    }

    func onNavigationCommitted(state: WebViewState) {
        debugPrint("# FLASH ReaderWebViewHandler.onNavigationCommitted event", "page=\(flashURLDescription(state.pageURL))")
        markReaderLoadStart(for: state.pageURL, source: "navigationCommitted")
        navigationTaskManager.startOnNavigationCommitted {
            let navigationToken = self.readerContent.beginMainFrameNavigationTask(to: state.pageURL)
            defer { self.readerContent.endMainFrameNavigationTask(navigationToken) }
            do {
                try await self.handleNewURL(state: state, source: "navigationCommitted")
            } catch {
                if error is CancellationError {
                    print("onNavigationCommitted task was cancelled.")
                } else {
                    print("Error during onNavigationCommitted: \(error)")
                }
            }
        }
    }

    func onNavigationFinished(state: WebViewState) {
        debugPrint("# FLASH ReaderWebViewHandler.onNavigationFinished event", "page=\(flashURLDescription(state.pageURL))")
        navigationTaskManager.startOnNavigationFinished { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishReaderLoad(for: state.pageURL, outcome: "finished") }
            let currentContent = self.readerContent.content
            let cachedHTMLBytes = currentContent?.html?.utf8.count ?? 0
            debugPrint(
                "# READERRELOAD webView.onNavigationFinished",
                "pageURL=\(state.pageURL.absoluteString)",
                "contentURL=\(currentContent?.url.absoluteString ?? "nil")",
                "hasHTML=\(currentContent?.hasHTML ?? false)",
                "cachedHTMLBytes=\(cachedHTMLBytes)",
                "isReaderMode=\(self.readerModeViewModel.isReaderMode)",
                "isReaderModeLoading=\(self.readerModeViewModel.isReaderModeLoading)",
                "hasAsyncCaller=\(self.scriptCaller.hasAsyncCaller)"
            )
            await self.readerModeViewModel.onNavigationFinished(
                newState: state,
                scriptCaller: scriptCaller
            )
            self.logNativeReaderSurfaceSnapshot(source: "readerWebView.onNavigationFinished", state: state)
            self.logNativeViewportDOMProbe(source: "readerWebView.onNavigationFinished", state: state)
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: 300_000_000)
                self.logNativeReaderSurfaceSnapshot(source: "readerWebView.onNavigationFinished.delayed", state: state)
                self.logNativeViewportDOMProbe(source: "readerWebView.onNavigationFinished.delayed", state: state)
            }
            debugPrint("# FLASH ReaderWebViewHandler.onNavigationFinished readerModeViewModel", "page=\(flashURLDescription(state.pageURL))")
            if let content = self.readerContent.content,
               content.isReaderModeByDefault {
                let pageMatchesContentURL = state.pageURL.matchesReaderURL(content.url)
                let shouldRenderDeferredPreparedReaderMode =
                    (
                        state.pageURL.isReaderURLLoaderURL
                        || (
                            pageMatchesContentURL
                            && !self.readerModeViewModel.hasRenderedReadabilityContent
                        )
                    )
                    && self.scriptCaller.hasAsyncCaller
                    && self.readerModeViewModel.readabilityContent != nil
                    && self.readerModeViewModel.isReaderModeLoadPending(for: content.url)
                    && !self.readerModeViewModel.isReadabilityRenderInFlight(for: content.url)

                if shouldRenderDeferredPreparedReaderMode {
                    debugPrint(
                        "# READERLOAD stage=readerWebView.renderDeferredPreparedReaderMode",
                        "pageURL=\(state.pageURL.absoluteString)",
                        "contentURL=\(content.url.absoluteString)",
                        "hasAsyncCaller=\(self.scriptCaller.hasAsyncCaller)",
                        "pageMatchesContent=\(pageMatchesContentURL)"
                    )
                    self.readerModeViewModel.showReaderView(
                        readerContent: self.readerContent,
                        scriptCaller: self.scriptCaller
                    )
                }

                let shouldRecoverDeferredReaderModeLoad =
                    state.pageURL.isReaderURLLoaderURL
                    && content.hasHTML
                    && self.readerModeViewModel.readabilityContent == nil
                    && self.readerModeViewModel.pendingReaderModeURL == nil
                    && !self.readerModeViewModel.isReaderMode
                    && !self.readerModeViewModel.isReaderModeLoading
                    && !self.readerModeViewModel.isReadabilityRenderInFlight(for: content.url)

                if shouldRecoverDeferredReaderModeLoad {
                    debugPrint(
                        "# READERLOAD stage=readerWebView.recoverDeferredReaderMode",
                        "pageURL=\(state.pageURL.absoluteString)",
                        "contentURL=\(content.url.absoluteString)",
                        "cachedHTMLBytes=\(cachedHTMLBytes)",
                        "hasAsyncCaller=\(self.scriptCaller.hasAsyncCaller)"
                    )
                    if self.scriptCaller.hasAsyncCaller {
                        self.readerModeViewModel.showReaderView(
                            readerContent: self.readerContent,
                            scriptCaller: self.scriptCaller
                        )
                    } else {
                        self.deferReaderModeRecoveryUntilAsyncCallerReady(
                            content: content,
                            pageURL: state.pageURL,
                            reason: "deferredReaderModeLoad"
                        )
                    }
                }

                let shouldRecoverPendingReaderModeLoad =
                    pageMatchesContentURL
                    && content.hasHTML
                    && self.readerModeViewModel.readabilityContent == nil
                    && self.readerModeViewModel.isReaderModeLoadPending(for: content.url)
                    && !self.readerModeViewModel.isReaderMode
                    && !self.readerModeViewModel.isReaderModeLoading
                    && !self.readerModeViewModel.isReadabilityRenderInFlight(for: content.url)

                if shouldRecoverPendingReaderModeLoad {
                    debugPrint(
                        "# READERLOAD stage=readerWebView.recoverPendingReaderMode",
                        "pageURL=\(state.pageURL.absoluteString)",
                        "contentURL=\(content.url.absoluteString)",
                        "pending=\(self.readerModeViewModel.pendingReaderModeURL?.absoluteString ?? "nil")",
                        "cachedHTMLBytes=\(cachedHTMLBytes)",
                        "hasAsyncCaller=\(self.scriptCaller.hasAsyncCaller)"
                    )
                    if self.scriptCaller.hasAsyncCaller {
                        self.readerModeViewModel.showReaderView(
                            readerContent: self.readerContent,
                            scriptCaller: self.scriptCaller
                        )
                    } else {
                        self.deferReaderModeRecoveryUntilAsyncCallerReady(
                            content: content,
                            pageURL: state.pageURL,
                            reason: "pendingReaderModeLoad"
                        )
                    }
                }

                let shouldRecoverVisiblePageReaderModeLoad =
                    pageMatchesContentURL
                    && content.isReaderModeByDefault
                    && content.hasHTML
                    && self.readerModeViewModel.readabilityContent == nil
                    && !self.readerModeViewModel.isReaderMode
                    && !self.readerModeViewModel.isReaderModeLoading
                    && !self.readerModeViewModel.isReadabilityRenderInFlight(for: content.url)

                if shouldRecoverVisiblePageReaderModeLoad {
                    debugPrint(
                        "# READERLOAD stage=readerWebView.recoverVisiblePageReaderMode",
                        "pageURL=\(state.pageURL.absoluteString)",
                        "contentURL=\(content.url.absoluteString)",
                        "pending=\(self.readerModeViewModel.pendingReaderModeURL?.absoluteString ?? "nil")",
                        "cachedHTMLBytes=\(cachedHTMLBytes)",
                        "hasAsyncCaller=\(self.scriptCaller.hasAsyncCaller)"
                    )
                    if self.scriptCaller.hasAsyncCaller {
                        self.readerModeViewModel.showReaderView(
                            readerContent: self.readerContent,
                            scriptCaller: self.scriptCaller
                        )
                    } else {
                        self.deferReaderModeRecoveryUntilAsyncCallerReady(
                            content: content,
                            pageURL: state.pageURL,
                            reason: "visiblePageReaderModeLoad"
                        )
                    }
                }

                let cachedHTML = content.html
                let cachedSnippetReaderHTMLReady = cachedHTML.map(self.snippetCachedReaderHTMLIsRenderable) ?? false
                let allowDuringLoading = self.readerModeViewModel.isReaderModeLoading
                    && self.readerModeViewModel.isReaderModeHandlingURL(content.url)
                let renderInFlight = self.readerModeViewModel.isReadabilityRenderInFlight(for: content.url)
                let canShowCached = self.readerModeViewModel.readabilityContent == nil
                    && cachedHTMLBytes > 0
                    && (!content.url.isSnippetURL || cachedSnippetReaderHTMLReady)
                    && (!self.readerModeViewModel.isReaderModeLoading || allowDuringLoading)
                    && !renderInFlight
                debugPrint(
                    "# READERRELOAD cachedReadability.check",
                    "pageURL=\(state.pageURL.absoluteString)",
                    "contentURL=\(content.url.absoluteString)",
                    "canShow=\(canShowCached)",
                    "allowDuringLoading=\(allowDuringLoading)",
                    "renderInFlight=\(renderInFlight)",
                    "isReaderMode=\(self.readerModeViewModel.isReaderMode)",
                    "isReaderModeLoading=\(self.readerModeViewModel.isReaderModeLoading)",
                    "hasAsyncCaller=\(self.scriptCaller.hasAsyncCaller)",
                    "cachedHTMLBytes=\(cachedHTMLBytes)",
                    "snippetReady=\(cachedSnippetReaderHTMLReady)"
                )
                if canShowCached, let cachedHTML {
                    guard !self.readerModeViewModel.isReadabilityRenderInFlight(for: content.url) else {
                        debugPrint(
                            "# READERPERF readerMode.render.singleFlight.skip",
                            "url=\(content.url.absoluteString)",
                            "reason=cachedReadability.show",
                            "generation=nil",
                            "pending=\(self.readerModeViewModel.pendingReaderModeURL?.absoluteString ?? "nil")",
                            "isReaderModeLoading=\(self.readerModeViewModel.isReaderModeLoading)",
                            "isReaderMode=\(self.readerModeViewModel.isReaderMode)"
                        )
                        return
                    }
                    debugPrint(
                        "# READERRELOAD cachedReadability.show",
                        "pageURL=\(state.pageURL.absoluteString)",
                        "contentURL=\(content.url.absoluteString)",
                        "bytes=\(cachedHTML.utf8.count)",
                        "hasAsyncCaller=\(self.scriptCaller.hasAsyncCaller)"
                    )
                    if self.scriptCaller.hasAsyncCaller {
                        self.renderCachedReadabilityHTML(
                            cachedHTML,
                            for: content,
                            pageURL: state.pageURL
                        )
                    } else {
                        self.deferCachedReadabilityRenderUntilAsyncCallerReady(
                            cachedHTML: cachedHTML,
                            content: content,
                            pageURL: state.pageURL
                        )
                    }
                }
            }
            if let content = self.readerContent.content {
                self.readerViewModel.onNavigationFinished(content: content, newState: state) { _ in
                    // no external callback here
                }
                debugPrint("# FLASH ReaderWebViewHandler.onNavigationFinished readerViewModel", "page=\(flashURLDescription(state.pageURL))")
            }
        }
    }

    func onNavigationFailed(state: WebViewState) {
        if state.pageURL.absoluteString == "about:blank", readerContent.content != nil {
            debugPrint("# FLASH ReaderWebViewHandler.onNavigationFailed skipping about:blank")
            finishReaderLoad(for: state.pageURL, outcome: "failed.aboutBlankSkipped")
            return
        }
        debugPrint("# FLASH ReaderWebViewHandler.onNavigationFailed event", "page=\(flashURLDescription(state.pageURL))")
        navigationTaskManager.startOnNavigationFailed { @MainActor in
            defer { self.finishReaderLoad(for: state.pageURL, outcome: "failed") }
            if let error = state.error {
                let nsError = error as NSError
                debugPrint(
                    "# READER navigation.failed",
                    "url=\(state.pageURL.absoluteString)",
                    "provisional=\(state.isProvisionallyNavigating)",
                    "code=\(nsError.code)",
                    "domain=\(nsError.domain)"
                )
                self.readerModeViewModel.onNavigationError(
                    pageURL: state.pageURL,
                    error: error,
                    isProvisional: state.isProvisionallyNavigating
                )
            }
            self.readerModeViewModel.onNavigationFailed(newState: state)
            // no external callback here
        }
    }

    func onURLChanged(state: WebViewState) {
        if state.pageURL.absoluteString == "about:blank", readerContent.content != nil {
            debugPrint("# FLASH ReaderWebViewHandler.onURLChanged skipping about:blank")
            return
        }
        debugPrint("# FLASH ReaderWebViewHandler.onURLChanged event", "page=\(flashURLDescription(state.pageURL))")
        markReaderLoadStart(for: state.pageURL, source: "urlChanged")
        navigationTaskManager.startOnURLChanged { @MainActor in
            let navigationToken = self.readerContent.beginMainFrameNavigationTask(to: state.pageURL)
            defer { self.readerContent.endMainFrameNavigationTask(navigationToken) }
            do {
                try await self.handleNewURL(state: state, source: "urlChanged")
            } catch is CancellationError {
                //                print("onURLChanged task was cancelled.")
            } catch {
                print("Error during onURLChanged: \(error)")
            }
        }
    }
}

public struct ReaderWebView: View {
    let obscuredInsets: EdgeInsets?
    var bounces = true
    var additionalBottomSafeAreaInset: CGFloat?
    let schemeHandlers: [(WKURLSchemeHandler, String)]
    let onNavigationCommitted: ((WebViewState) async throws -> Void)?
    let onNavigationFinished: ((WebViewState) -> Void)?
    let onNavigationFailed: ((WebViewState) -> Void)?
    let onURLChanged: ((WebViewState) async throws -> Void)?
    @Binding var hideNavigationDueToScroll: Bool
    @Binding var textSelection: String?
    var buildMenu: BuildMenuType?

    @State private var ebookURLSchemeHandler = EbookURLSchemeHandler()
    @State private var readerFileURLSchemeHandler = ReaderFileURLSchemeHandler()

    @EnvironmentObject internal var readerContent: ReaderContent
    @EnvironmentObject internal var scriptCaller: WebViewScriptCaller
    @EnvironmentObject internal var readerViewModel: ReaderViewModel
    @EnvironmentObject internal var readerModeViewModel: ReaderModeViewModel
    @EnvironmentObject internal var readerMediaPlayerViewModel: ReaderMediaPlayerViewModel

    @State private var handler: ReaderWebViewHandler?

    public init(
        obscuredInsets: EdgeInsets?,
        bounces: Bool = true,
        additionalBottomSafeAreaInset: CGFloat? = nil,
        schemeHandlers: [(WKURLSchemeHandler, String)] = [],
        onNavigationCommitted: ((WebViewState) async throws -> Void)? = nil,
        onNavigationFinished: ((WebViewState) -> Void)? = nil,
        onNavigationFailed: ((WebViewState) -> Void)? = nil,
        onURLChanged: ((WebViewState) async throws -> Void)? = nil,
        hideNavigationDueToScroll: Binding<Bool> = .constant(false),
        textSelection: Binding<String?>? = nil,
        buildMenu: BuildMenuType? = nil
    ) {
        self.obscuredInsets = obscuredInsets
        self.bounces = bounces
        self.additionalBottomSafeAreaInset = additionalBottomSafeAreaInset
        self.schemeHandlers = schemeHandlers
        self.onNavigationCommitted = onNavigationCommitted
        self.onNavigationFinished = onNavigationFinished
        self.onNavigationFailed = onNavigationFailed
        self.onURLChanged = onURLChanged
        _hideNavigationDueToScroll = hideNavigationDueToScroll
        _textSelection = textSelection ?? .constant(nil)
        self.buildMenu = buildMenu
    }
    
    public var body: some View {
        // Initialize handler if nil, and update dependencies
        return Group {
            if let handler = handler {
                ReaderWebViewInternal(
                    useTransparentWebViewBackground: readerModeViewModel.isReaderModeLoadedOrPending(url: readerViewModel.state.pageURL, content: readerContent.content),
                    obscuredInsets: obscuredInsets,
                    bounces: bounces,
                    additionalBottomSafeAreaInset: additionalBottomSafeAreaInset,
                    schemeHandlers: schemeHandlers,
                    hideNavigationDueToScroll: $hideNavigationDueToScroll,
                    textSelection: $textSelection,
                    buildMenu: buildMenu,
                    scriptCaller: scriptCaller,
                    userScripts: readerViewModel.allScripts,
                    state: $readerViewModel.state,
                    ebookURLSchemeHandler: ebookURLSchemeHandler,
                    readerFileURLSchemeHandler: readerFileURLSchemeHandler,
                    handler: handler
                )
            } else {
                // Show empty view or placeholder while handler is initializing
                Color.clear
            }
        }
        .task { @MainActor in
            if handler == nil {
                handler = ReaderWebViewHandler(
                    onNavigationCommitted: onNavigationCommitted,
                    onNavigationFinished: onNavigationFinished,
                    onNavigationFailed: onNavigationFailed,
                    onURLChanged: onURLChanged,
                    readerContent: readerContent,
                    readerViewModel: readerViewModel,
                    readerModeViewModel: readerModeViewModel,
                    readerMediaPlayerViewModel: readerMediaPlayerViewModel,
                    scriptCaller: scriptCaller
                )
            } else if let handler {
                handler.onNavigationCommitted = onNavigationCommitted
                handler.onNavigationFinished = onNavigationFinished
                handler.onNavigationFailed = onNavigationFailed
                handler.onURLChanged = onURLChanged
                handler.readerContent = readerContent
                handler.readerViewModel = readerViewModel
                handler.readerModeViewModel = readerModeViewModel
                handler.readerMediaPlayerViewModel = readerMediaPlayerViewModel
                handler.scriptCaller = scriptCaller
            }
            ebookURLSchemeHandler.ebookTextProcessorCacheHits = readerModeViewModel.ebookTextProcessorCacheHits
            ebookURLSchemeHandler.ebookTextProcessor = ebookTextProcessor
            ebookURLSchemeHandler.processReadabilityContent = readerModeViewModel.processReadabilityContent
            ebookURLSchemeHandler.processHTML = readerModeViewModel.processHTML
            ebookURLSchemeHandler.sharedFontCSSBase64 = readerModeViewModel.sharedFontCSSBase64
            ebookURLSchemeHandler.sharedFontCSSBase64Provider = readerModeViewModel.sharedFontCSSBase64Provider
        }
        .readerFileManagerSetup { readerFileManager in
            readerFileURLSchemeHandler.readerFileManager = readerFileManager
            ebookURLSchemeHandler.readerFileManager = readerFileManager
        }
    }
}

private struct ReaderWebViewInternal: View {
    let useTransparentWebViewBackground: Bool
    let obscuredInsets: EdgeInsets?
    var bounces = true
    var additionalBottomSafeAreaInset: CGFloat?
    let schemeHandlers: [(WKURLSchemeHandler, String)]
    @Binding var hideNavigationDueToScroll: Bool
    @Binding var textSelection: String?
    var buildMenu: BuildMenuType?
    var scriptCaller: WebViewScriptCaller
    var userScripts: [WebViewUserScript]
    @Binding var state: WebViewState
    var ebookURLSchemeHandler: EbookURLSchemeHandler
    var readerFileURLSchemeHandler: ReaderFileURLSchemeHandler
    var handler: ReaderWebViewHandler

    @State private var internalURLSchemeHandler = InternalURLSchemeHandler()

    @AppStorage("ebookViewerLayout") private var ebookViewerLayout = "paginated"
    @AppStorage("bookWritingDirectionSetting") private var bookWritingDirection = "original"

    @Environment(\.webViewNavigator) private var navigator: WebViewNavigator
    @Environment(\.contentBlockingRules) private var contentBlockingRules
    @Environment(\.contentBlockingEnabled) private var contentBlockingEnabled
    @EnvironmentObject private var readerContent: ReaderContent

    private func totalObscuredInsets(additionalInsets: EdgeInsets = .init(top: 0, leading: 0, bottom: 0, trailing: 0)) -> EdgeInsets {
        #if os(iOS)
        let insets = EdgeInsets(
            top: max(0, (obscuredInsets?.top ?? 0) + additionalInsets.top),
            leading: max(0, (obscuredInsets?.leading ?? 0) + additionalInsets.leading),
            bottom: max(0, (obscuredInsets?.bottom ?? 0) + additionalInsets.bottom),
            trailing: max(0, (obscuredInsets?.trailing ?? 0) + additionalInsets.trailing)
        )
        return insets
        #else
        EdgeInsets()
        #endif
    }

    private var isEbookContent: Bool {
        state.pageURL.isEBookURL
        || readerContent.pageURL.isEBookURL
        || readerContent.content?.url.isEBookURL == true
    }

    private var paginationConfiguration: WebViewPaginationConfiguration {
        guard isEbookContent, ebookViewerLayout == "paginated" else {
            return .disabled
        }

        // Phase 5 starts with a compact, runtime-only config derived from the existing
        // ebook settings. Until the renderer promotes richer pagination state up to Swift,
        // keep page length in explicit view-length mode and use a stable gutter.
        let mode: WebViewPaginationMode
        switch bookWritingDirection {
        case "vertical":
            mode = .rightToLeft
        case "horizontal", "original":
            mode = .leftToRight
        default:
            mode = .leftToRight
        }

        return WebViewPaginationConfiguration(
            mode: mode,
            storedPageLength: 0,
            gapBetweenPages: 24,
            behavesLikeColumns: true
        )
    }
    
    public var body: some View {
        let resolvedContentRules = contentBlockingEnabled ? contentBlockingRules : nil
        let webViewConfig: WebViewConfig = {
            if useTransparentWebViewBackground {
                return WebViewConfig(
                    contentRules: resolvedContentRules,
                    dataDetectorsEnabled: false,
                    isOpaque: false,
                    backgroundColor: .clear,
                    userScripts: userScripts,
                    paginationConfiguration: paginationConfiguration
                )
            }
            return WebViewConfig(
                contentRules: resolvedContentRules,
                dataDetectorsEnabled: false,
                userScripts: userScripts,
                paginationConfiguration: paginationConfiguration
            )
        }()
        
        WebView(
            config: webViewConfig,
            navigator: navigator,
            state: $state,
            scriptCaller: scriptCaller,
            obscuredInsets: totalObscuredInsets(
                additionalInsets: EdgeInsets(
                    top: 0,
                    leading: 0,
                    bottom: max(0, additionalBottomSafeAreaInset ?? 0),
                    trailing: 0
                )
            ),
            bounces: bounces,
            schemeHandlers: [
                (internalURLSchemeHandler, "internal"),
                (readerFileURLSchemeHandler, "reader-file"),
                (ebookURLSchemeHandler, "ebook")
            ] + schemeHandlers,
            onNavigationCommitted: { state in
                handler.onNavigationCommitted(state: state)
            },
            onNavigationFinished: { state in
                handler.onNavigationFinished(state: state)
            },
            onNavigationFailed: { state in
                handler.onNavigationFailed(state: state)
            },
            onURLChanged: { state in
                handler.onURLChanged(state: state)
            },
            buildMenu: { builder in
                buildMenu?(builder)
            },
            hideNavigationDueToScroll: $hideNavigationDueToScroll
        )
    }
}
