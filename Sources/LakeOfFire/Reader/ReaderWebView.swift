import SwiftUI
import RealmSwift
import LakeKit
import SwiftUIWebView
import WebKit
import SwiftSoup
import Combine
import RealmSwiftGaps

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
            readerModeViewModel.cancelReaderModeLoad(for: cancelURL)
        }

        if let lastHandledURL, lastHandledURL.matchesReaderURL(state.pageURL), lastHandledIsProvisionallyNavigating == state.isProvisionallyNavigating, lastHandledIsLoading == state.isLoading {
            debugPrint("# FLASH ReaderWebViewHandler.handleNewURL skipping duplicate", "page=\(flashURLDescription(state.pageURL))")
            return
        }

        lastHandledURL = state.pageURL
        lastHandledIsProvisionallyNavigating = state.isProvisionallyNavigating
        lastHandledIsLoading = state.isLoading

        try Task.checkCancellation()
        try await readerContent.load(url: state.pageURL)
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
            await self.readerModeViewModel.onNavigationFinished(
                newState: state,
                scriptCaller: scriptCaller
            )
            debugPrint("# FLASH ReaderWebViewHandler.onNavigationFinished readerModeViewModel", "page=\(flashURLDescription(state.pageURL))")
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
            return
        }
        debugPrint("# FLASH ReaderWebViewHandler.onNavigationFailed event", "page=\(flashURLDescription(state.pageURL))")
        navigationTaskManager.startOnNavigationFailed { @MainActor in
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
    var persistentWebViewID: String?
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
        persistentWebViewID: String? = nil,
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
        self.persistentWebViewID = persistentWebViewID
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
                    persistentWebViewID: persistentWebViewID,
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
    var persistentWebViewID: String?
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

    @Environment(\.webViewNavigator) private var navigator: WebViewNavigator
    @Environment(\.contentBlockingRules) private var contentBlockingRules
    @Environment(\.contentBlockingEnabled) private var contentBlockingEnabled

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
    
    public var body: some View {
        let resolvedContentRules = contentBlockingEnabled ? contentBlockingRules : nil
        let webViewConfig: WebViewConfig = {
            if useTransparentWebViewBackground {
                return WebViewConfig(
                    contentRules: resolvedContentRules,
                    dataDetectorsEnabled: false,
                    isOpaque: false,
                    backgroundColor: .clear,
                    userScripts: userScripts
                )
            }
            return WebViewConfig(
                contentRules: resolvedContentRules,
                dataDetectorsEnabled: false,
                userScripts: userScripts
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
            persistentWebViewID: persistentWebViewID,
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
