import SwiftUI
import OrderedCollections
import SwiftUIWebView
import RealmSwift
import RealmSwiftGaps
import LakeKit
import WebKit

private let readerModeDatasetProbeScript = """
(() => {
    const hasDocument = typeof document !== 'undefined';
    const hasBody = hasDocument && !!document.body;
    const summary = { hasBody };
    if (!hasBody) {
        return JSON.stringify(summary);
    }
    const ds = document.body.dataset ?? {};
    const dataset = {};
    [
        "manabiReaderModeAvailable",
        "manabiReaderModeAvailableFor",
        "manabiReaderModeAvailableConfidently",
        "isNextLoadInReaderMode",
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
    summary.readerContentPresent = !!document.getElementById("reader-content");
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
fileprivate class ReaderMessageHandlers: Identifiable {
    var forceReaderModeWhenAvailable: Bool
    
    var scriptCaller: WebViewScriptCaller
    var readerViewModel: ReaderViewModel
    var readerModeViewModel: ReaderModeViewModel
    var readerContent: ReaderContent
    var navigator: WebViewNavigator
    
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
            ("readerOnError", { [weak self] message in
                guard let self else { return }
                guard let result = ReaderOnErrorMessage(fromMessage: message) else {
                    return
                }
                
                // Filter error logging based on URL
                guard result.source.isEBookURL || result.source.scheme == "blob" || result.source.isFileURL || result.source.isReaderFileURL || result.source.isSnippetURL else { return }
                
                Logger.shared.logger.error("[JS] Error: \(result.message ?? "unknown message") @ \(result.source.absoluteString):\(result.lineno ?? -1):\(result.colno ?? -1) — error: \(result.error ?? "n/a")")
            }),
            ("readabilityFramePing", { @MainActor [weak self] message in
                guard let self else { return }
                guard let uuid = (message.body as? [String: String])?["uuid"], let windowURLRaw = (message.body as? [String: String])?["windowURL"] as? String, let windowURL = URL(string: windowURLRaw) else {
                    debugPrint("Unexpectedly received readableFramePing message without valid parameters", message.body as? [String: String])
                    return
                }
                guard !windowURL.isNativeReaderView, let content = try? await ReaderViewModel.getContent(forURL: windowURL) else { return }
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
                guard let url = result.windowURL, url == readerViewModel.state.pageURL, let content = try? await ReaderViewModel.getContent(forURL: url) else {
                    return
                }
                debugPrint("# READERMODEBUTTON readabilityParsed message url=\(url.absoluteString) isReaderMode=\(readerModeViewModel.isReaderMode) isLoading=\(readerModeViewModel.isReaderModeLoading) contentAvailable=\(content.isReaderModeAvailable) default=\(content.isReaderModeByDefault)")
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
                    try await content.asyncWrite { _, content in
                        content.isReaderModeAvailable = false
                        content.refreshChangeMetadata(explicitlyModified: true)
                    }
                    
                    try await { @RealmBackgroundActor in
                        let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.historyRealmConfiguration)
                        if let historyRecord = HistoryRecord.get(forURL: url, realm: historyRealm) {
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
                guard let url = result.windowURL, url == readerViewModel.state.pageURL, let content = try? await ReaderViewModel.getContent(forURL: url) else {
                    return
                }
                if !message.frameInfo.isMainFrame, readerModeViewModel.readabilityContent != nil, readerModeViewModel.readabilityContainerFrameInfo != message.frameInfo {
                    // Don't override a parent window readability result.
                    return
                }
                guard !result.outputHTML.isEmpty else {
                    try? await content.asyncWrite { _, content in
                        content.isReaderModeAvailable = false
                        content.refreshChangeMetadata(explicitlyModified: true)
                    }
                    return
                }
                
                guard !url.isNativeReaderView else { return }

                let outputLooksLikeReader = result.outputHTML.contains("class=\"readability-mode\"") &&
                    result.outputHTML.contains("id=\"reader-content\"")

                let hasProcessedReadability = readerModeViewModel.readabilityContent != nil
                debugPrint("# READERMODEBUTTON readabilityParsed shortCircuitCheck url=\(url.absoluteString) readerMode=\(readerModeViewModel.isReaderMode) outputLooksLikeReader=\(outputLooksLikeReader) hasProcessedReadability=\(hasProcessedReadability)")
                if (readerModeViewModel.isReaderMode || outputLooksLikeReader) && hasProcessedReadability {
                    debugPrint("# READERMODEBUTTON readabilityParsed shortCircuit url=\(url.absoluteString) readerMode=\(readerModeViewModel.isReaderMode) loading=\(readerModeViewModel.isReaderModeLoading) outputLooksLikeReader=\(outputLooksLikeReader)")
                    await logReaderDatasetState(stage: "readabilityParsed.shortCircuit.preUpdate", url: url, frameInfo: message.frameInfo)
                    try? await scriptCaller.evaluateJavaScript("""
                        if (document.body) {
                            document.body.dataset.manabiReaderModeAvailable = 'false';
                            document.body.dataset.manabiReaderModeAvailableFor = '';
                            document.body.dataset.isNextLoadInReaderMode = 'false';
                            if (!document.body.classList.contains('readability-mode')) {
                                document.body.classList.add('readability-mode');
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
                        readerModeViewModel.isReaderMode = true
                        debugPrint("# READERMODEBUTTON readabilityParsed toggled viewModel.isReaderMode true url=\(url.absoluteString)")
                    }
                    if readerModeViewModel.isReaderModeLoadPending(for: url) {
                        readerModeViewModel.markReaderModeLoadComplete(for: url)
                    }
                    await logReaderDatasetState(stage: "readabilityParsed.shortCircuit.postUpdate", url: url, frameInfo: message.frameInfo)
                    return
                }

                readerModeViewModel.readabilityContent = result.outputHTML
                debugPrint("# READERMODEBUTTON readabilityParsed storedContent url=\(url.absoluteString) bytes=\(result.outputHTML.utf8.count)")
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
                    if !content.isReaderModeAvailable {
                        try await content.asyncWrite { _, content in
                            content.isReaderModeAvailable = true
                            content.refreshChangeMetadata(explicitlyModified: true)
                        }
                    }
                    
                    try await { @RealmBackgroundActor in
                        let historyRealm = try await RealmBackgroundActor.shared.cachedRealm(for: ReaderContentLoader.historyRealmConfiguration)
                        if let historyRecord = HistoryRecord.get(forURL: url, realm: historyRealm) {
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
                    guard let windowURL = result.windowURL, !windowURL.isNativeReaderView, let content = try await ReaderViewModel.getContent(forURL: windowURL) else { return }
                    let pairs = result.rssURLs.prefix(10)
                    let urls = pairs.compactMap { $0.first }.compactMap { URL(string: $0) }
                    let titles = pairs.map { $0.last ?? $0.first ?? "" }
                    try await content.asyncWrite { _, content in
                        content.rssURLs.removeAll()
                        content.rssTitles.removeAll()
                        content.rssURLs.append(objectsIn: urls)
                        content.rssTitles.append(objectsIn: titles)
                        content.isRSSAvailable = !content.rssURLs.isEmpty
                        content.refreshChangeMetadata(explicitlyModified: true)
                    }
                } catch {
                    print(error)
                }
            }),
            ("pageMetadataUpdated", { @MainActor [weak self] message in
                guard let self else { return }
                do {
                    guard let result = PageMetadataUpdatedMessage(fromMessage: message) else { return }
                    guard result.url == readerViewModel.state.pageURL else { return }
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
                debugPrint("# READERMODEBUTTON datasetProbeFallback stage=\(stage) urlSummary=\(summary)")
                return summary
            }
            if let rawResult {
                debugPrint(
                    "# READERMODEBUTTON datasetProbeUnexpected stage=\(stage)",
                    "type=\(type(of: rawResult))",
                    "value=\(String(describing: rawResult))"
                )
            }
        } catch {
            debugPrint("# READERMODEBUTTON datasetProbeError stage=\(stage) error=\(error.localizedDescription)")
        }
        return nil
    }
    
    private func logReaderDatasetState(stage: String, url: URL, frameInfo: WKFrameInfo?) async {
        if let summary = await readerDatasetSummary(stage: stage, frameInfo: frameInfo) {
            debugPrint("# READERMODEBUTTON dataset stage=\(stage) url=\(url.absoluteString) state=\(summary)")
        } else {
            debugPrint("# READERMODEBUTTON dataset stage=\(stage) url=\(url.absoluteString) state=<nil>")
        }
    }
    
    init(
        forceReaderModeWhenAvailable: Bool,
        scriptCaller: WebViewScriptCaller,
        readerViewModel: ReaderViewModel,
        readerModeViewModel: ReaderModeViewModel,
        readerContent: ReaderContent,
        navigator: WebViewNavigator
    ) {
        self.forceReaderModeWhenAvailable = forceReaderModeWhenAvailable
        self.scriptCaller = scriptCaller
        self.readerViewModel = readerViewModel
        self.readerModeViewModel = readerModeViewModel
        self.readerContent = readerContent
        self.navigator = navigator
    }
    
    // MARK: Readability
    
    @MainActor
    func showOriginal() async throws {
        if readerContent.content?.isReaderModeByDefault ?? false {
            try await readerContent.content?.asyncWrite { _, content in
                content.isReaderModeByDefault = false
                content.refreshChangeMetadata(explicitlyModified: true)
            }
        }
        navigator.reload()
    }
}

internal struct ReaderMessageHandlersViewModifier: ViewModifier {
    var forceReaderModeWhenAvailable = false
    
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
                        navigator: navigator
                    )
                } else if let readerMessageHandlers {
                    readerMessageHandlers.forceReaderModeWhenAvailable = forceReaderModeWhenAvailable
                    readerMessageHandlers.scriptCaller = scriptCaller
                    readerMessageHandlers.readerViewModel = readerViewModel
                    readerMessageHandlers.readerModeViewModel = readerModeViewModel
                    readerMessageHandlers.readerContent = readerContent
                    readerMessageHandlers.navigator = navigator
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
    }
}
