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

struct ReaderWebViewObscuredInsetResolver {
    static func resolve(
        obscuredInsets: EdgeInsets?,
        additionalInsets: EdgeInsets,
        usesEBookChromeInsets: Bool,
        preservesLeadingSafeAreaInset: Bool,
        ignoresSampledTopObscuredInset: Bool = false,
        fallbackTopInset: CGFloat = 0
    ) -> EdgeInsets {
#if os(iOS)
        let rawSampledTop = obscuredInsets?.top ?? 0
        let sampledTop: CGFloat
        if additionalInsets.top > 0 || usesEBookChromeInsets {
            sampledTop = 0
        } else if ignoresSampledTopObscuredInset {
            let clampedSampledInset = rawSampledTop > 0 ? min(rawSampledTop, 88) : 0
            sampledTop = max(0, fallbackTopInset, clampedSampledInset)
        } else {
            sampledTop = rawSampledTop
        }
        let sampledBottom = obscuredInsets?.bottom ?? 0
        let sampledLeading = additionalInsets.leading > 0
            ? 0
            : (obscuredInsets?.leading ?? 0)
        let resolvedBottom = usesEBookChromeInsets
            ? max(sampledBottom, additionalInsets.bottom)
            : sampledBottom + additionalInsets.bottom
        let resolvedLeading = preservesLeadingSafeAreaInset
            ? max(0, sampledLeading + additionalInsets.leading)
            : 0
        return EdgeInsets(
            top: max(0, sampledTop + additionalInsets.top),
            leading: resolvedLeading,
            bottom: max(0, resolvedBottom),
            trailing: max(0, (obscuredInsets?.trailing ?? 0) + additionalInsets.trailing)
        )
#else
        return EdgeInsets(
            top: max(0, additionalInsets.top),
            leading: preservesLeadingSafeAreaInset ? max(0, additionalInsets.leading) : 0,
            bottom: max(0, additionalInsets.bottom),
            trailing: max(0, additionalInsets.trailing)
        )
#endif
    }
}

fileprivate let blockedHosts = Set([
    "googleads.g.doubleclick.net", "tpc.googlesyndication.com", "pagead2.googlesyndication.com", "www.google-analytics.com", "www.googletagservices.com",
    "adclick.g.doublecklick.net", "media-match.com", "www.omaze.com", "omaze.com", "pubads.g.doubleclick.net", "googlehosted.l.googleusercontent.com",
    "pagead46.l.doubleclick.net", "pagead.l.doubleclick.net", "video-ad-stats.googlesyndication.com", "pagead-googlehosted.l.google.com",
    "partnerad.l.doubleclick.net", "adserver.adtechus.com", "na.gmtdmp.com", "anycast.pixel.adsafeprotected.com", "d361oi6ppvq2ym.cloudfront.net",
    "track.gawker.com", "domains.googlesyndication.com", "partner.googleadservices.com", "ads2.opensubtitles.org", "stats.wordpress.com", "botd.wordpress.com",
    "adservice.google.ca", "adservice.google.com", "adservice.google.jp",
])

#if os(iOS)
@MainActor
private func currentWindowTopSafeAreaInset() -> CGFloat {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
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
    var onDocumentContextInvalidated: (@MainActor (WebViewState, WebViewDocumentContextInvalidationReason) -> Void)?
    var onURLChanged: ((WebViewState) async throws -> Void)?

    var readerContent: ReaderContent
    var readerViewModel: ReaderViewModel
    var readerModeViewModel: ReaderModeViewModel
    var readerMediaPlayerViewModel: ReaderMediaPlayerViewModel
    var scriptCaller: WebViewScriptCaller

    private let navigationTaskManager: NavigationTaskManager
    private var activeMainFrameNavigationTokens: [String: UUID] = [:]

    init(
        navigationTaskManager: NavigationTaskManager,
        onNavigationCommitted: ((WebViewState) async throws -> Void)? = nil,
        onNavigationFinished: ((WebViewState) -> Void)? = nil,
        onNavigationFailed: ((WebViewState) -> Void)? = nil,
        onDocumentContextInvalidated: (@MainActor (
            WebViewState,
            WebViewDocumentContextInvalidationReason
        ) -> Void)? = nil,
        onURLChanged: ((WebViewState) async throws -> Void)? = nil,
        readerContent: ReaderContent,
        readerViewModel: ReaderViewModel,
        readerModeViewModel: ReaderModeViewModel,
        readerMediaPlayerViewModel: ReaderMediaPlayerViewModel,
        scriptCaller: WebViewScriptCaller
    ) {
        self.navigationTaskManager = navigationTaskManager
        self.onNavigationCommitted = onNavigationCommitted
        self.onNavigationFinished = onNavigationFinished
        self.onNavigationFailed = onNavigationFailed
        self.onDocumentContextInvalidated = onDocumentContextInvalidated
        self.onURLChanged = onURLChanged
        self.readerContent = readerContent
        self.readerViewModel = readerViewModel
        self.readerModeViewModel = readerModeViewModel
        self.readerMediaPlayerViewModel = readerMediaPlayerViewModel
        self.scriptCaller = scriptCaller
    }

    func handleNavigationCommitted(state: WebViewState) async throws {
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
        guard let content = readerContent.content,
              content.url.matchesReaderURL(state.pageURL) else {
            throw CancellationError()
        }
        try await readerMediaPlayerViewModel.onNavigationCommitted(content: content, newState: state)
        try Task.checkCancellation()
    }

    func handleNavigationFinished(state: WebViewState) async {
        guard !Task.isCancelled else { return }
        await readerModeViewModel.onNavigationFinished(
            newState: state,
            scriptCaller: scriptCaller
        )
        guard !Task.isCancelled,
              let content = readerContent.content,
              content.url.matchesReaderURL(state.pageURL) else { return }
        readerViewModel.onNavigationFinished(content: content, newState: state) { _ in
            // no external callback here
        }
    }

    func handleURLChanged(state: WebViewState) async throws {
        try await handleNavigationCommitted(state: state)
        try Task.checkCancellation()
        await handleNavigationFinished(state: state)
        try Task.checkCancellation()
    }

    private func endAllMainFrameNavigationTasks() {
        let tokens = Array(activeMainFrameNavigationTokens.values)
        activeMainFrameNavigationTokens.removeAll()
        for token in tokens {
            readerContent.endMainFrameNavigationTask(token)
        }
    }

    func onNavigationCommitted(state: WebViewState) {
        endAllMainFrameNavigationTasks()
        let navigationKey = state.pageURL.absoluteString
        let navigationToken = readerContent.beginMainFrameNavigationTask(to: state.pageURL)
        activeMainFrameNavigationTokens[navigationKey] = navigationToken
        navigationTaskManager.startOnNavigationCommitted {
            do {
                try await self.handleNavigationCommitted(state: state)
                try Task.checkCancellation()
            } catch {
                if self.activeMainFrameNavigationTokens[navigationKey] == navigationToken {
                    self.activeMainFrameNavigationTokens.removeValue(forKey: navigationKey)
                    self.readerContent.endMainFrameNavigationTask(navigationToken)
                }
                throw error
            }
            do {
                try await self.onNavigationCommitted?(state)
            } catch is CancellationError {
                if self.activeMainFrameNavigationTokens[navigationKey] == navigationToken {
                    self.activeMainFrameNavigationTokens.removeValue(forKey: navigationKey)
                    self.readerContent.endMainFrameNavigationTask(navigationToken)
                }
                throw CancellationError()
            } catch {
                print("Error during public onNavigationCommitted: \(error)")
            }
        }
    }

    func onNavigationFinished(state: WebViewState) {
        let navigationKey = state.pageURL.absoluteString
        let navigationToken = activeMainFrameNavigationTokens.removeValue(forKey: navigationKey)
        navigationTaskManager.startOnNavigationFinished { @MainActor [weak self] in
            guard let self else { return }
            await self.handleNavigationFinished(state: state)
            if let navigationToken {
                self.readerContent.endMainFrameNavigationTask(navigationToken)
            }
            guard !Task.isCancelled else { return }
            self.onNavigationFinished?(state)
        }
    }

    func onNavigationFailed(
        state: WebViewState,
        disposition: WebViewNavigationFailureDisposition
    ) {
        let navigationKey = state.pageURL.absoluteString
        let navigationToken = activeMainFrameNavigationTokens.removeValue(forKey: navigationKey)
        let preservesCommittedDocument = disposition == .preservedCommittedDocument
        navigationTaskManager.startOnNavigationFailed(
            preservingCommittedDocument: preservesCommittedDocument
        ) { @MainActor in
            if let navigationToken {
                self.readerContent.endMainFrameNavigationTask(navigationToken)
            }
            if !preservesCommittedDocument {
                self.readerModeViewModel.onNavigationFailed(newState: state)
            }
            self.onNavigationFailed?(state)
        }
    }

    func onDocumentContextInvalidated(
        state: WebViewState,
        reason: WebViewDocumentContextInvalidationReason
    ) {
        navigationTaskManager.cancelNavigationWork()
        endAllMainFrameNavigationTasks()
        if reason == .webContentProcessTerminated {
            readerModeViewModel.onNavigationFailed(newState: state)
            onNavigationFailed?(state)
        }
        onDocumentContextInvalidated?(state, reason)
    }

    func onURLChanged(state: WebViewState) {
        navigationTaskManager.startOnURLChanged { @MainActor in
            try await self.handleURLChanged(state: state)
            do {
                try await self.onURLChanged?(state)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                print("Error during public onURLChanged: \(error)")
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
    var additionalLeadingSafeAreaInset: CGFloat?
    var additionalBottomSafeAreaInset: CGFloat?
    var hidesTopScrollEdgeEffect = false
    let schemeHandlers: [(WKURLSchemeHandler, String)]
    let onNavigationCommitted: ((WebViewState) async throws -> Void)?
    let onNavigationFinished: ((WebViewState) -> Void)?
    let onNavigationFailed: ((WebViewState) -> Void)?
    let onDocumentContextInvalidated: (@MainActor (WebViewState, WebViewDocumentContextInvalidationReason) -> Void)?
    let onURLChanged: ((WebViewState) async throws -> Void)?
    @Binding var hideNavigationDueToScroll: Bool
    @Binding var textSelection: String?
    var buildMenu: BuildMenuType?
    let lightModeTheme: LightModeTheme
    let darkModeTheme: DarkModeTheme

    @State private var ebookURLSchemeHandler = EbookURLSchemeHandler()
    @State private var readerFileURLSchemeHandler = ReaderFileURLSchemeHandler()
    @State private var navigationTaskManager = NavigationTaskManager()

    @EnvironmentObject internal var readerContent: ReaderContent
    @EnvironmentObject internal var scriptCaller: WebViewScriptCaller
    @EnvironmentObject internal var readerViewModel: ReaderViewModel
    @EnvironmentObject internal var readerModeViewModel: ReaderModeViewModel
    @EnvironmentObject internal var readerMediaPlayerViewModel: ReaderMediaPlayerViewModel
    @Environment(\.webViewNavigator) internal var navigator: WebViewNavigator

    private var ebookSchemeBindingState: String {
        [
            readerModeViewModel.ebookProcessedTextCacheReader != nil ? "processedTextRead=1" : "processedTextRead=0",
            readerModeViewModel.ebookProcessedTextCacheWriter != nil ? "processedTextWrite=1" : "processedTextWrite=0",
            readerModeViewModel.ebookProcessingVariantProvider != nil ? "processingVariant=1" : "processingVariant=0",
            readerModeViewModel.ebookSectionPresentationProvider != nil ? "presentation=1" : "presentation=0",
            readerModeViewModel.processReadabilityContent != nil ? "readability=1" : "readability=0",
            readerModeViewModel.processHTMLDocument != nil ? "htmlDocument=1" : "htmlDocument=0",
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
        additionalLeadingSafeAreaInset: CGFloat? = nil,
        additionalBottomSafeAreaInset: CGFloat? = nil,
        hidesTopScrollEdgeEffect: Bool = false,
        schemeHandlers: [(WKURLSchemeHandler, String)] = [],
        onNavigationCommitted: ((WebViewState) async throws -> Void)? = nil,
        onNavigationFinished: ((WebViewState) -> Void)? = nil,
        onNavigationFailed: ((WebViewState) -> Void)? = nil,
        onDocumentContextInvalidated: (@MainActor (
            WebViewState,
            WebViewDocumentContextInvalidationReason
        ) -> Void)? = nil,
        onURLChanged: ((WebViewState) async throws -> Void)? = nil,
        hideNavigationDueToScroll: Binding<Bool> = .constant(false),
        textSelection: Binding<String?>? = nil,
        buildMenu: BuildMenuType? = nil,
        lightModeTheme: LightModeTheme = .white,
        darkModeTheme: DarkModeTheme = .black
    ) {
        self.persistentWebViewID = persistentWebViewID
        self.obscuredInsets = obscuredInsets
        self.usesEBookChromeInsets = usesEBookChromeInsets
        self.ignoresSampledTopObscuredInset = ignoresSampledTopObscuredInset
        self.bounces = bounces
        self.additionalTopSafeAreaInset = additionalTopSafeAreaInset
        self.additionalLeadingSafeAreaInset = additionalLeadingSafeAreaInset
        self.additionalBottomSafeAreaInset = additionalBottomSafeAreaInset
        self.hidesTopScrollEdgeEffect = hidesTopScrollEdgeEffect
        self.schemeHandlers = schemeHandlers
        self.onNavigationCommitted = onNavigationCommitted
        self.onNavigationFinished = onNavigationFinished
        self.onNavigationFailed = onNavigationFailed
        self.onDocumentContextInvalidated = onDocumentContextInvalidated
        self.onURLChanged = onURLChanged
        _hideNavigationDueToScroll = hideNavigationDueToScroll
        _textSelection = textSelection ?? .constant(nil)
        self.buildMenu = buildMenu
        self.lightModeTheme = lightModeTheme
        self.darkModeTheme = darkModeTheme
    }

    public var body: some View {
        let handler = ReaderWebViewHandler(
            navigationTaskManager: navigationTaskManager,
            onNavigationCommitted: onNavigationCommitted,
            onNavigationFinished: onNavigationFinished,
            onNavigationFailed: onNavigationFailed,
            onDocumentContextInvalidated: onDocumentContextInvalidated,
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
            additionalLeadingSafeAreaInset: additionalLeadingSafeAreaInset,
            additionalBottomSafeAreaInset: additionalBottomSafeAreaInset,
            hidesTopScrollEdgeEffect: hidesTopScrollEdgeEffect,
            schemeHandlers: schemeHandlers,
            hideNavigationDueToScroll: $hideNavigationDueToScroll,
            textSelection: $textSelection,
            buildMenu: buildMenu,
            lightModeTheme: lightModeTheme,
            darkModeTheme: darkModeTheme,
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
            ebookURLSchemeHandler.ebookProcessedTextCacheReader = readerModeViewModel.ebookProcessedTextCacheReader
            ebookURLSchemeHandler.ebookProcessedTextCacheWriter = readerModeViewModel.ebookProcessedTextCacheWriter
            ebookURLSchemeHandler.ebookTextProcessor = ebookTextProcessor
            ebookURLSchemeHandler.ebookProcessingVariantProvider = readerModeViewModel.ebookProcessingVariantProvider
            ebookURLSchemeHandler.ebookSectionPresentationProvider = readerModeViewModel.ebookSectionPresentationProvider
            ebookURLSchemeHandler.processReadabilityContent = readerModeViewModel.processReadabilityContent
            ebookURLSchemeHandler.processHTMLDocument = readerModeViewModel.processHTMLDocument
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
        .onDisappear {
            navigationTaskManager.cancelNavigationWork()
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
    var additionalLeadingSafeAreaInset: CGFloat?
    var additionalBottomSafeAreaInset: CGFloat?
    var hidesTopScrollEdgeEffect = false
    let schemeHandlers: [(WKURLSchemeHandler, String)]
    @Binding var hideNavigationDueToScroll: Bool
    @Binding var textSelection: String?
    var buildMenu: BuildMenuType?
    let lightModeTheme: LightModeTheme
    let darkModeTheme: DarkModeTheme
    var scriptCaller: WebViewScriptCaller
    var userScripts: [WebViewUserScript]
    @Binding var state: WebViewState
    var ebookURLSchemeHandler: EbookURLSchemeHandler
    var readerFileURLSchemeHandler: ReaderFileURLSchemeHandler
    let sharedReaderFontAsset: SharedReaderFontAsset?
    let handler: ReaderWebViewHandler

    @State private var internalURLSchemeHandler = InternalURLSchemeHandler()
#if os(iOS)
    @StateObject private var webViewPrewarmer = WebViewPrewarmer(
        warmUpCount: 1,
        keepAliveCount: 0,
        defaultResetURL: URL(string: "about:blank")
    )
#endif

    @Environment(\.readerWebViewConfigurationTransform) private var readerWebViewConfigurationTransform
    @Environment(\.readerWebViewMessageHandlersTransform) private var readerWebViewMessageHandlersTransform
    @Environment(\.webViewMessageHandlers) private var webViewMessageHandlers
    @Environment(\.webViewNavigator) private var navigator: WebViewNavigator
    @Environment(\.readerNavigationActionHandler) private var readerNavigationActionHandler
    @Environment(\.readerNavigationActionContextHandler) private var readerNavigationActionContextHandler
    @Environment(\.readerWebViewDataStore) private var readerWebViewDataStore
    @Environment(\.colorScheme) private var colorScheme

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
        let preservesLeadingSafeAreaInset = UIDevice.current.userInterfaceIdiom == .phone
        let fallbackTopInset = max(0, currentWindowTopSafeAreaInset())
#else
        let preservesLeadingSafeAreaInset = true
        let fallbackTopInset: CGFloat = 0
#endif
        return ReaderWebViewObscuredInsetResolver.resolve(
            obscuredInsets: obscuredInsets,
            additionalInsets: additionalInsets,
            usesEBookChromeInsets: usesEBookChromeInsets,
            preservesLeadingSafeAreaInset: preservesLeadingSafeAreaInset,
            ignoresSampledTopObscuredInset: ignoresSampledTopObscuredInset,
            fallbackTopInset: fallbackTopInset
        )
    }

    public var body: some View {
#if os(iOS)
        let webViewPrewarmer: WebViewPrewarmer? = self.webViewPrewarmer
#else
        // A local macOS pool cannot warm before NSView construction. Loading its
        // spare views here launches WebKit services synchronously during layout.
        let webViewPrewarmer: WebViewPrewarmer? = nil
#endif
        let resolvedObscuredInsets = totalObscuredInsets(
            additionalInsets: EdgeInsets(
                top: max(0, additionalTopSafeAreaInset ?? 0),
                leading: max(0, additionalLeadingSafeAreaInset ?? 0),
                bottom: max(0, additionalBottomSafeAreaInset ?? 0),
                trailing: 0
            )
        )
        let resolvedWebsiteDataStore = readerWebViewDataStore ?? WKWebsiteDataStore.default()

        let webViewConfig = WebViewConfig(
            dataDetectorsEnabled: false,
            backgroundColor: readerThemeBackgroundColor,
            usesSampledPageTopColorForUnderPageBackground: true,
            usesConfiguredBackgroundForReaderDocuments: true,
            adjustsScrollViewContentInsetsForSafeArea: false,
            hidesTopScrollEdgeEffect: hidesTopScrollEdgeEffect,
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
            onNavigationFailedWithDisposition: { state, disposition in
                handler.onNavigationFailed(state: state, disposition: disposition)
            },
            onDocumentContextInvalidated: { state, reason in
                handler.onDocumentContextInvalidated(state: state, reason: reason)
            },
            onURLChanged: { state in
                handler.onURLChanged(state: state)
            },
            onNavigationAction: { action in
                if let readerNavigationActionContextHandler,
                   let policy = await readerNavigationActionContextHandler(
                       ReaderNavigationActionContext(
                           action: action,
                           websiteDataStore: resolvedWebsiteDataStore
                       )
                   ) {
                    return policy
                }
                return await readerNavigationActionHandler?(action)
            },
            buildMenu: { builder in
                buildMenu?(builder)
            },
            hideNavigationDueToScroll: $hideNavigationDueToScroll,
            textSelection: $textSelection,
            websiteDataStore: resolvedWebsiteDataStore,
            webViewPrewarmer: webViewPrewarmer
        )
        .environment(\.webViewMessageHandlers, readerWebViewMessageHandlersTransform(webViewMessageHandlers, scriptCaller))
        .task(id: sharedReaderFontAsset?.localFileURL.path ?? "") { @MainActor in
            internalURLSchemeHandler.sharedReaderFontAsset = sharedReaderFontAsset
        }
    }
}
