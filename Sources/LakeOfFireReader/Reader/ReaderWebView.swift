import SwiftUI
import LakeOfFireWeb
import LakeOfFireFiles
import LakeOfFireContentUI
import LakeOfFireContent
import LakeOfFireCore
import RealmSwift
import LakeKit
import SwiftUIWebView
import WebKit
import SwiftSoup
import Combine
import RealmSwiftGaps
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

struct ReaderWebViewObscuredInsetResolver {
    static func resolve(
        obscuredInsets: EdgeInsets?,
        additionalInsets: EdgeInsets,
        usesEBookChromeInsets: Bool,
        preservesLeadingSafeAreaInset: Bool
    ) -> EdgeInsets {
#if os(iOS)
        let sampledTop = additionalInsets.top > 0 || usesEBookChromeInsets
            ? 0
            : (obscuredInsets?.top ?? 0)
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
        EdgeInsets(
            top: max(0, additionalInsets.top),
            leading: preservesLeadingSafeAreaInset ? max(0, additionalInsets.leading) : 0,
            bottom: max(0, additionalInsets.bottom),
            trailing: max(0, additionalInsets.trailing)
        )
#endif
    }
}




// Lightweight callback adapter. ReaderWebView supplies one stable task manager
// so SwiftUI value-view rebuilds cannot create independent navigation owners.
@MainActor
final class ReaderWebViewHandler {
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
    let navigator: WebViewNavigator
    
    private let navigationTaskManager: NavigationTaskManager
    
    init(
        navigationTaskManager: NavigationTaskManager,
        onNavigationCommitted: ((WebViewState) async throws -> Void)? = nil,
        onNavigationFinished: ((WebViewState) -> Void)? = nil,
        onNavigationFailed: ((WebViewState) -> Void)? = nil,
        onDocumentContextInvalidated: (@MainActor (WebViewState, WebViewDocumentContextInvalidationReason) -> Void)? = nil,
        onURLChanged: ((WebViewState) async throws -> Void)? = nil,
        readerContent: ReaderContent,
        readerViewModel: ReaderViewModel,
        readerModeViewModel: ReaderModeViewModel,
        readerMediaPlayerViewModel: ReaderMediaPlayerViewModel,
        scriptCaller: WebViewScriptCaller,
        navigator: WebViewNavigator
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
        self.navigator = navigator
    }
    
    func handleNavigationCommitted(state: WebViewState) async throws {
//        debugPrint("Handle", state, self.readerViewModel.state, self.readerContent.pageURL)

        try Task.checkCancellation()
        if !readerModeViewModel.expectsSyntheticReaderLoaderCommit(
            for: state.pageURL
        ) {
            // A different committed document no longer owns an older render
            // overlay. The expected processed-HTML commit keeps it until its
            // render-ready message arrives.
            readerContent.isRenderingReaderHTML = false
        }
        do {
            try Task.checkCancellation()
            try await readerContent.load(url: state.pageURL)
            try Task.checkCancellation()
            guard let content = readerContent.content else {
                readerModeViewModel.cancelReaderModeLoad(
                    for: state.pageURL,
                    readerContent: readerContent
                )
                return
            }
            try await readerViewModel.onNavigationCommitted(
                content: content,
                newState: state
            )
            try Task.checkCancellation()
            try await readerModeViewModel.onNavigationCommitted(
                readerContent: readerContent,
                newState: state,
                scriptCaller: scriptCaller,
                navigator: navigator
            )
            try Task.checkCancellation()
            guard let content = readerContent.content,
                  content.url.matchesReaderURL(state.pageURL) else {
                throw CancellationError()
            }
            try await readerMediaPlayerViewModel.onNavigationCommitted(
                content: content,
                newState: state
            )
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Replacement commits cancel the previous task. If an unrelated
            // operation failed at the same time, its cleanup must not release a
            // newer same-URL reader render.
            guard !Task.isCancelled else {
                throw CancellationError()
            }
            readerModeViewModel.cancelReaderModeLoad(
                for: state.pageURL,
                readerContent: readerContent
            )
            throw error
        }
    }

    func handleNavigationFinished(state: WebViewState) async {
        guard !Task.isCancelled else { return }
        await readerModeViewModel.onNavigationFinished(
            newState: state,
            scriptCaller: scriptCaller
        )
        guard !Task.isCancelled,
              let content = readerContent.content,
              content.url.matchesReaderURL(state.pageURL) else {
            return
        }
        readerViewModel.onNavigationFinished(
            content: content,
            newState: state
        )
    }

    func handleURLChanged(state: WebViewState) async throws {
        try await handleNavigationCommitted(state: state)
        try Task.checkCancellation()
        await handleNavigationFinished(state: state)
        try Task.checkCancellation()
    }

    func onNavigationCommitted(state: WebViewState) {
        navigationTaskManager.startOnNavigationCommitted {
            try await self.handleNavigationCommitted(state: state)
            try Task.checkCancellation()
            do {
                try await self.onNavigationCommitted?(state)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Public observers are not part of the internal document commit.
                print("Error during public onNavigationCommitted: \(error)")
            }
        }
    }

    func onNavigationFinished(state: WebViewState) {
        navigationTaskManager.startOnNavigationFinished { @MainActor [weak self] in
            guard let self else { return }
            await self.handleNavigationFinished(state: state)
            guard !Task.isCancelled else { return }
            self.onNavigationFinished?(state)
        }
    }

    func onNavigationFailed(
        state: WebViewState,
        disposition: WebViewNavigationFailureDisposition
    ) {
        let preservesCommittedDocument = disposition == .preservedCommittedDocument
        navigationTaskManager.startOnNavigationFailed(
            preservingCommittedDocument: preservesCommittedDocument
        ) { @MainActor in
            if !preservesCommittedDocument {
                if self.readerContent.pageURL.matchesReaderURL(state.pageURL) {
                    self.readerContent.isRenderingReaderHTML = false
                }
                self.readerModeViewModel.onNavigationFailed(newState: state)
            }
            self.onNavigationFailed?(state)
        }
    }

    func onDocumentContextInvalidated(
        state: WebViewState,
        reason: WebViewDocumentContextInvalidationReason
    ) {
        // A committed replacement, process loss, or host detach invalidates all
        // asynchronous work that still belongs to the previous document.
        navigationTaskManager.cancelNavigationWork()
        if reason == .webContentProcessTerminated {
            if readerContent.pageURL.matchesReaderURL(state.pageURL) {
                readerContent.isRenderingReaderHTML = false
            }
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
                // Public observers must not retroactively invalidate an internally
                // completed same-document mutation.
                print("Error during public onURLChanged: \(error)")
            }
        }
    }

}

public struct ReaderWebView: View {
    var persistentWebViewID: String? = nil
    let obscuredInsets: EdgeInsets?
    var usesEBookChromeInsets = false
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
    let onScrollBottomStateChanged: (@MainActor (Bool) -> Void)?
    @Binding var hideNavigationDueToScroll: Bool
    @Binding var textSelection: String?
    var buildMenu: BuildMenuType?
    let lightModeTheme: LightModeTheme
    let darkModeTheme: DarkModeTheme
    
    @State private var ebookURLSchemeHandler = EbookURLSchemeHandler()
    @State private var readerFileURLSchemeHandler = ReaderFileURLSchemeHandler()
    // SwiftUI can rebuild this value-type view while a navigation callback is
    // suspended. Keep one task owner across those rebuilds so a newer callback,
    // failure, process termination, or disappearance can cancel older work.
    @State private var navigationTaskManager = NavigationTaskManager()
    
    @EnvironmentObject internal var readerContent: ReaderContent
    @EnvironmentObject internal var scriptCaller: WebViewScriptCaller
    @EnvironmentObject internal var readerViewModel: ReaderViewModel
    @EnvironmentObject internal var readerModeViewModel: ReaderModeViewModel
    @EnvironmentObject internal var readerMediaPlayerViewModel: ReaderMediaPlayerViewModel
    @Environment(\.webViewNavigator) internal var navigator: WebViewNavigator

    private var ebookSchemeBindingState: String {
        [
            "dependencyRevision=\(readerModeViewModel.processingDependencyRevision)",
            readerModeViewModel.ebookProcessedTextCacheReader != nil ? "cacheReader=1" : "cacheReader=0",
            readerModeViewModel.ebookProcessedTextCacheWriter != nil ? "cacheWriter=1" : "cacheWriter=0",
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
        bounces: Bool = true,
        additionalTopSafeAreaInset: CGFloat? = nil,
        additionalLeadingSafeAreaInset: CGFloat? = nil,
        additionalBottomSafeAreaInset: CGFloat? = nil,
        hidesTopScrollEdgeEffect: Bool = false,
        schemeHandlers: [(WKURLSchemeHandler, String)] = [],
        onNavigationCommitted: ((WebViewState) async throws -> Void)? = nil,
        onNavigationFinished: ((WebViewState) -> Void)? = nil,
        onNavigationFailed: ((WebViewState) -> Void)? = nil,
        onDocumentContextInvalidated: (@MainActor (WebViewState, WebViewDocumentContextInvalidationReason) -> Void)? = nil,
        onURLChanged: ((WebViewState) async throws -> Void)? = nil,
        onScrollBottomStateChanged: (@MainActor (Bool) -> Void)? = nil,
        hideNavigationDueToScroll: Binding<Bool> = .constant(false),
        textSelection: Binding<String?>? = nil,
        buildMenu: BuildMenuType? = nil,
        lightModeTheme: LightModeTheme = .white,
        darkModeTheme: DarkModeTheme = .black
    ) {
        self.persistentWebViewID = persistentWebViewID
        self.obscuredInsets = obscuredInsets
        self.usesEBookChromeInsets = usesEBookChromeInsets
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
        self.onScrollBottomStateChanged = onScrollBottomStateChanged
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
            scriptCaller: scriptCaller,
            navigator: navigator
        )
        ReaderWebViewInternal(
            persistentWebViewID: persistentWebViewID,
            obscuredInsets: obscuredInsets,
            usesEBookChromeInsets: usesEBookChromeInsets,
            bounces: bounces,
            additionalTopSafeAreaInset: additionalTopSafeAreaInset,
            additionalLeadingSafeAreaInset: additionalLeadingSafeAreaInset,
            additionalBottomSafeAreaInset: additionalBottomSafeAreaInset,
            hidesTopScrollEdgeEffect: hidesTopScrollEdgeEffect,
            schemeHandlers: schemeHandlers,
            hideNavigationDueToScroll: $hideNavigationDueToScroll,
            textSelection: $textSelection,
            onScrollBottomStateChanged: onScrollBottomStateChanged,
            buildMenu: buildMenu,
            lightModeTheme: lightModeTheme,
            darkModeTheme: darkModeTheme,
            scriptCaller: scriptCaller,
            userScripts: readerViewModel.allScripts,
            state: $readerViewModel.state,
            readerContentPageURLString: readerContent.pageURL.absoluteString,
            ebookURLSchemeHandler: ebookURLSchemeHandler,
            readerFileURLSchemeHandler: readerFileURLSchemeHandler,
            sharedReaderFontAsset: readerModeViewModel.sharedReaderFontAsset,
            handler: handler
        )
        .task(id: ebookSchemeBindingState) { @MainActor in
            navigator.shouldLoadFallbackOnAttach = false
            navigator.attachFallbackDelayNanoseconds = 700_000_000
            ebookURLSchemeHandler.ebookProcessedTextCacheReader = readerModeViewModel.ebookProcessedTextCacheReader
            ebookURLSchemeHandler.ebookProcessedTextCacheWriter = readerModeViewModel.ebookProcessedTextCacheWriter
            ebookURLSchemeHandler.ebookProcessingVariantProvider = readerModeViewModel.ebookProcessingVariantProvider
            ebookURLSchemeHandler.ebookSectionPresentationProvider = readerModeViewModel.ebookSectionPresentationProvider
            ebookURLSchemeHandler.ebookTextProcessor = ebookTextProcessor
            ebookURLSchemeHandler.processReadabilityContent = readerModeViewModel.processReadabilityContent
            ebookURLSchemeHandler.processHTMLDocument = readerModeViewModel.processHTMLDocument
            ebookURLSchemeHandler.processHTMLBytes = readerModeViewModel.processHTMLBytes
            ebookURLSchemeHandler.processHTML = readerModeViewModel.processHTML
            ebookURLSchemeHandler.sharedFontCSSBase64 = readerModeViewModel.sharedFontCSSBase64
            ebookURLSchemeHandler.sharedFontCSSBase64Provider = readerModeViewModel.sharedFontCSSBase64Provider
            ebookURLSchemeHandler.sharedReaderFontAsset = readerModeViewModel.sharedReaderFontAsset
            readerFileURLSchemeHandler.sharedReaderFontAsset = readerModeViewModel.sharedReaderFontAsset
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
    var bounces = true
    var additionalTopSafeAreaInset: CGFloat?
    var additionalLeadingSafeAreaInset: CGFloat?
    var additionalBottomSafeAreaInset: CGFloat?
    var hidesTopScrollEdgeEffect = false
    let schemeHandlers: [(WKURLSchemeHandler, String)]
    @Binding var hideNavigationDueToScroll: Bool
    @Binding var textSelection: String?
    let onScrollBottomStateChanged: (@MainActor (Bool) -> Void)?
    var buildMenu: BuildMenuType?
    let lightModeTheme: LightModeTheme
    let darkModeTheme: DarkModeTheme
    var scriptCaller: WebViewScriptCaller
    var userScripts: [WebViewUserScript]
    @Binding var state: WebViewState
    let readerContentPageURLString: String
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
    
    @Environment(\.webViewNavigator) private var navigator: WebViewNavigator
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
        let preservesLeadingSafeAreaInset: Bool
#if os(iOS)
        preservesLeadingSafeAreaInset = UIDevice.current.userInterfaceIdiom == .phone
#else
        preservesLeadingSafeAreaInset = true
#endif
        return ReaderWebViewObscuredInsetResolver.resolve(
            obscuredInsets: obscuredInsets,
            additionalInsets: additionalInsets,
            usesEBookChromeInsets: usesEBookChromeInsets,
            preservesLeadingSafeAreaInset: preservesLeadingSafeAreaInset
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
        WebView(
            config: WebViewConfig(
                dataDetectorsEnabled: false,
                backgroundColor: readerThemeBackgroundColor,
                usesSampledPageTopColorForUnderPageBackground: true,
                usesConfiguredBackgroundForReaderDocuments: true,
                adjustsScrollViewContentInsetsForSafeArea: false,
                hidesTopScrollEdgeEffect: hidesTopScrollEdgeEffect,
                nativeLookupHitTestingEnabled: state.pageURL.isEBookURL,
                userScripts: userScripts),
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
                handler.onNavigationFailed(
                    state: state,
                    disposition: disposition
                )
            },
            onDocumentContextInvalidated: { state, reason in
                handler.onDocumentContextInvalidated(state: state, reason: reason)
            },
            onURLChanged: { state in
                handler.onURLChanged(state: state)
            },
            onScrollBottomStateChanged: onScrollBottomStateChanged,
            buildMenu: { builder in
                buildMenu?(builder)
            },
            hideNavigationDueToScroll: $hideNavigationDueToScroll,
            textSelection: $textSelection,
            webViewPrewarmer: webViewPrewarmer
        )
        .onAppear {
        }
        .onDisappear {
        }
        .task(id: sharedReaderFontAsset?.localFileURL.path ?? "") { @MainActor in
            internalURLSchemeHandler.sharedReaderFontAsset = sharedReaderFontAsset
        }
    }
}
