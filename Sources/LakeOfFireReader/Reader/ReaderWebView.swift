import SwiftUI
import RealmSwift
import LakeKit
import SwiftUIWebView
import WebKit
import SwiftSoup
import Combine
import RealmSwiftGaps
import LakeOfFireContent
import LakeOfFireFiles
#if os(iOS)
import UIKit
#endif

fileprivate let blockedHosts = Set([
    "googleads.g.doubleclick.net", "tpc.googlesyndication.com", "pagead2.googlesyndication.com", "www.google-analytics.com", "www.googletagservices.com",
    "adclick.g.doublecklick.net", "media-match.com", "www.omaze.com", "omaze.com", "pubads.g.doubleclick.net", "googlehosted.l.googleusercontent.com",
    "pagead46.l.doubleclick.net", "pagead.l.doubleclick.net", "video-ad-stats.googlesyndication.com", "pagead-googlehosted.l.google.com",
    "partnerad.l.doubleclick.net", "adserver.adtechus.com", "na.gmtdmp.com", "anycast.pixel.adsafeprotected.com", "d361oi6ppvq2ym.cloudfront.net",
    "track.gawker.com", "domains.googlesyndication.com", "partner.googleadservices.com", "ads2.opensubtitles.org", "stats.wordpress.com", "botd.wordpress.com",
    "adservice.google.ca", "adservice.google.com", "adservice.google.jp",
])

#if os(iOS)
private func currentWindowTopSafeAreaInset() -> CGFloat {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first { $0.isKeyWindow }?
        .safeAreaInsets.top ?? 0
}
#endif

// To avoid redraws...
@MainActor
fileprivate class ReaderWebViewHandler {
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
    private var activeMainFrameNavigationTokens: [String: UUID] = [:]

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

    func handleNewURL(state: WebViewState) async throws {
//        debugPrint("Handle", state, self.readerViewModel.state, self.readerContent.pageURL)

        try Task.checkCancellation()
        try await readerContent.load(url: state.pageURL)
        try Task.checkCancellation()
        guard let content = readerContent.content else {
            return
        }
        // TODO: Add onURLChanged or rename these view model methods to be more generic...
        try await readerViewModel.onNavigationCommitted(content: content, newState: state)
        try Task.checkCancellation()
        try await readerModeViewModel.onNavigationCommitted(
            readerContent: readerContent,
            newState: state,
            scriptCaller: scriptCaller
        )
        try Task.checkCancellation()
        guard let content = readerContent.content, content.url.matchesReaderURL(state.pageURL) else { return }
        try await readerMediaPlayerViewModel.onNavigationCommitted(content: content, newState: state)
        try Task.checkCancellation()

        await self.readerModeViewModel.onNavigationFinished(
            newState: state,
            scriptCaller: scriptCaller
        )
        try Task.checkCancellation()
        self.readerViewModel.onNavigationFinished(content: content, newState: state) { newState in
            // no external callback here
        }
    }

    func onNavigationCommitted(state: WebViewState) {
        let navigationKey = state.pageURL.absoluteString
        let navigationToken = readerContent.beginMainFrameNavigationTask(to: state.pageURL)
        activeMainFrameNavigationTokens[navigationKey] = navigationToken
        navigationTaskManager.startOnNavigationCommitted {
            do {
                try await self.handleNewURL(state: state)
            } catch {
                if error is CancellationError {
                    print("onNavigationCommitted task was cancelled.")
                } else {
                    print("Error during onNavigationCommitted: \(error)")
                }
            }
            await MainActor.run {
                if self.activeMainFrameNavigationTokens[navigationKey] == navigationToken {
                    self.activeMainFrameNavigationTokens.removeValue(forKey: navigationKey)
                }
                self.readerContent.endMainFrameNavigationTask(navigationToken)
            }
        }
    }

    func onNavigationFinished(state: WebViewState) {
        let navigationKey = state.pageURL.absoluteString
        let navigationToken = activeMainFrameNavigationTokens.removeValue(forKey: navigationKey)
        navigationTaskManager.startOnNavigationFinished { @MainActor [weak self] in
            guard let self else { return }
            if let navigationToken {
                self.readerContent.endMainFrameNavigationTask(navigationToken)
            }
            await self.readerModeViewModel.onNavigationFinished(
                newState: state,
                scriptCaller: scriptCaller
            )
            guard let content = self.readerContent.content else { return }
            self.readerViewModel.onNavigationFinished(content: content, newState: state) { newState in
                // no external callback here
            }
        }
    }

    func onNavigationFailed(state: WebViewState) {
        let navigationKey = state.pageURL.absoluteString
        let navigationToken = activeMainFrameNavigationTokens.removeValue(forKey: navigationKey)
        navigationTaskManager.startOnNavigationFailed { @MainActor in
            if let navigationToken {
                self.readerContent.endMainFrameNavigationTask(navigationToken)
            }
            self.readerModeViewModel.onNavigationFailed(newState: state)
            // no external callback here
        }
    }

    func onURLChanged(state: WebViewState) {
        navigationTaskManager.startOnURLChanged { @MainActor in
            do {
                try await self.handleNewURL(state: state)
            } catch is CancellationError {
//                print("onURLChanged task was cancelled.")
            } catch {
                print("Error during onURLChanged: \(error)")
            }
        }
    }
}

public struct ReaderWebView: View {
    var persistentWebViewID: String? = nil
    let obscuredInsets: EdgeInsets?
    var usesEBookChromeInsets = false
    var ignoresSampledTopObscuredInset = false
    var bounces = true
    var additionalTopSafeAreaInset: CGFloat?
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
    @Environment(\.webViewNavigator) internal var navigator: WebViewNavigator

    private var ebookSchemeBindingState: String {
        [
            readerModeViewModel.ebookTextProcessorCacheHits != nil ? "cacheHits=1" : "cacheHits=0",
            readerModeViewModel.processReadabilityContent != nil ? "readability=1" : "readability=0",
            readerModeViewModel.processHTMLBytes != nil ? "htmlBytes=1" : "htmlBytes=0",
            readerModeViewModel.processHTML != nil ? "html=1" : "html=0",
            readerModeViewModel.sharedFontCSSBase64 == nil ? "fontCSS=0" : "fontCSS=1",
            readerModeViewModel.sharedFontCSSBase64Provider == nil ? "fontCSSProvider=0" : "fontCSSProvider=1",
            readerModeViewModel.sharedReaderFontAsset == nil ? "fontAsset=0" : "fontAsset=1",
        ]
        .joined(separator: " ")
    }

    public init(
        persistentWebViewID: String? = nil,
        obscuredInsets: EdgeInsets?,
        usesEBookChromeInsets: Bool = false,
        ignoresSampledTopObscuredInset: Bool = false,
        bounces: Bool = true,
        additionalTopSafeAreaInset: CGFloat? = nil,
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
        self.usesEBookChromeInsets = usesEBookChromeInsets
        self.ignoresSampledTopObscuredInset = ignoresSampledTopObscuredInset
        self.bounces = bounces
        self.additionalTopSafeAreaInset = additionalTopSafeAreaInset
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
        let handler = ReaderWebViewHandler(
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
        let ebookURLSchemeHandler = self.ebookURLSchemeHandler
        let readerFileURLSchemeHandler = self.readerFileURLSchemeHandler
        ReaderWebViewInternal(
            persistentWebViewID: persistentWebViewID,
            obscuredInsets: obscuredInsets,
            usesEBookChromeInsets: usesEBookChromeInsets,
            ignoresSampledTopObscuredInset: ignoresSampledTopObscuredInset,
            bounces: bounces,
            additionalTopSafeAreaInset: additionalTopSafeAreaInset,
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
            sharedReaderFontAsset: readerModeViewModel.sharedReaderFontAsset,
            handler: handler
        )
        .task(id: ebookSchemeBindingState) { @MainActor in
            navigator.shouldLoadFallbackOnAttach = false
            ebookURLSchemeHandler.ebookTextProcessorCacheHits = readerModeViewModel.ebookTextProcessorCacheHits
            ebookURLSchemeHandler.ebookTextProcessor = ebookTextProcessor
            ebookURLSchemeHandler.processReadabilityContent = readerModeViewModel.processReadabilityContent
            ebookURLSchemeHandler.processHTMLBytes = readerModeViewModel.processHTMLBytes
            ebookURLSchemeHandler.processHTML = readerModeViewModel.processHTML
            ebookURLSchemeHandler.sharedFontCSSBase64 = readerModeViewModel.sharedFontCSSBase64
            ebookURLSchemeHandler.sharedFontCSSBase64Provider = readerModeViewModel.sharedFontCSSBase64Provider
            ebookURLSchemeHandler.sharedReaderFontAsset = readerModeViewModel.sharedReaderFontAsset
            readerFileURLSchemeHandler.sharedReaderFontAsset = readerModeViewModel.sharedReaderFontAsset
            print("# EPUB", "readerWebView.schemeHandlerBindings", ebookSchemeBindingState)
        }
        .readerFileManagerSetup { readerFileManager in
            readerFileURLSchemeHandler.readerFileManager = readerFileManager
            ebookURLSchemeHandler.readerFileManager = readerFileManager
        }
    }
}

fileprivate struct ReaderWebViewInternal: View {
    var persistentWebViewID: String? = nil
    let obscuredInsets: EdgeInsets?
    var usesEBookChromeInsets = false
    var ignoresSampledTopObscuredInset = false
    var bounces = true
    var additionalTopSafeAreaInset: CGFloat?
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
    let sharedReaderFontAsset: SharedReaderFontAsset?
    let handler: ReaderWebViewHandler

    @State private var internalURLSchemeHandler = InternalURLSchemeHandler()
    @StateObject private var webViewPrewarmer = WebViewPrewarmer(
        warmUpCount: 1,
        keepAliveCount: 1,
        defaultResetURL: URL(string: "about:blank")
    )

    @Environment(\.readerWebViewConfigurationTransform) private var readerWebViewConfigurationTransform
    @Environment(\.readerWebViewMessageHandlersTransform) private var readerWebViewMessageHandlersTransform
    @Environment(\.webViewMessageHandlers) private var webViewMessageHandlers
    @Environment(\.webViewNavigator) private var navigator: WebViewNavigator
    @Environment(\.readerNavigationActionHandler) private var readerNavigationActionHandler
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("lightModeTheme") private var lightModeTheme: LightModeTheme = .white
    @AppStorage("darkModeTheme") private var darkModeTheme: DarkModeTheme = .black

    private var readerThemeBackgroundColor: Color {
        switch colorScheme {
        case .dark:
            switch darkModeTheme {
            case .black:
                return .black
            case .gray:
                return Color(red: Double(0x31) / 255, green: Double(0x32) / 255, blue: Double(0x34) / 255)
            }
        default:
            switch lightModeTheme {
            case .white:
                return .white
            case .beige:
                return Color(red: Double(0xf7) / 255, green: Double(0xf0) / 255, blue: Double(0xd8) / 255)
            }
        }
    }

    private func totalObscuredInsets(additionalInsets: EdgeInsets = .init(top: 0, leading: 0, bottom: 0, trailing: 0)) -> EdgeInsets {
#if os(iOS)
        let rawSampledTop = obscuredInsets?.top ?? 0
        let sampledTop: CGFloat = {
            if additionalInsets.top > 0 || usesEBookChromeInsets {
                return 0
            }
            guard ignoresSampledTopObscuredInset else {
                return rawSampledTop
            }
#if os(iOS)
            let fallbackTopInset = max(0, currentWindowTopSafeAreaInset())
            let clampedSampledInset = rawSampledTop > 0 ? min(rawSampledTop, 88) : 0
            return max(fallbackTopInset, clampedSampledInset)
#else
            return 0
#endif
        }()
        let sampledBottom = usesEBookChromeInsets
            ? 0
            : (obscuredInsets?.bottom ?? 0)
        return EdgeInsets(
            top: max(0, sampledTop + additionalInsets.top),
            leading: max(0, (obscuredInsets?.leading ?? 0) + additionalInsets.leading),
            bottom: max(0, sampledBottom + additionalInsets.bottom),
            trailing: max(0, (obscuredInsets?.trailing ?? 0) + additionalInsets.trailing)
        )
#else
        EdgeInsets()
#endif
    }

    public var body: some View {
        let resolvedObscuredInsets = totalObscuredInsets(
            additionalInsets: EdgeInsets(
                top: max(0, additionalTopSafeAreaInset ?? 0),
                leading: 0,
                bottom: max(0, additionalBottomSafeAreaInset ?? 0),
                trailing: 0
            )
        )

        let webViewConfig = WebViewConfig(
            dataDetectorsEnabled: false,
            backgroundColor: readerThemeBackgroundColor,
            usesSampledPageTopColorForUnderPageBackground: true,
            usesConfiguredBackgroundForReaderDocuments: true,
            adjustsScrollViewContentInsetsForSafeArea: false,
            nativeLookupHitTestingEnabled: state.pageURL.isEBookURL,
            userScripts: userScripts
        )

        WebView(
            config: readerWebViewConfigurationTransform(webViewConfig),
            navigator: navigator,
            state: $state,
            scriptCaller: scriptCaller,
            blockedHosts: blockedHosts,
            obscuredInsets: resolvedObscuredInsets,
            bounces: bounces,
            schemeHandlers: [
                (internalURLSchemeHandler, "internal"),
                (readerFileURLSchemeHandler, "reader-file"),
                (ebookURLSchemeHandler, "ebook"),
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
            onNavigationAction: { action in
                await readerNavigationActionHandler?(action)
            },
            buildMenu: { builder in
                buildMenu?(builder)
            },
            hideNavigationDueToScroll: $hideNavigationDueToScroll,
            textSelection: $textSelection,
            webViewPrewarmer: webViewPrewarmer
        )
        .environment(\.webViewMessageHandlers, readerWebViewMessageHandlersTransform(webViewMessageHandlers, scriptCaller))
        .task(id: sharedReaderFontAsset?.localFileURL.path ?? "") { @MainActor in
            internalURLSchemeHandler.sharedReaderFontAsset = sharedReaderFontAsset
        }
    }
}
