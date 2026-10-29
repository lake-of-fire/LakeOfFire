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
        // The explicit sheet clearance already includes the physical bottom
        // safe area. Sampling it again must not add a second home-indicator gap.
        let resolvedBottom = max(sampledBottom, additionalInsets.bottom)
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

    private func shouldIgnoreIntermediateBlankCallback(
        state: WebViewState,
        callback: String
    ) -> Bool {
        guard state.pageURL.absoluteString == "about:blank",
              navigator.hasPendingInternalReaderRequest else { return false }
        ReaderLoadTrace.event("webview.intermediateBlankSkipped", "callback=\(callback)")
        return true
    }
    
    func handleNavigationCommitted(state: WebViewState) async throws {
        let trace = ReaderLoadTrace.begin("webview.commit")
        defer { trace?.end(Task.isCancelled ? "cancelled" : "returned") }
//        debugPrint("Handle", state, self.readerViewModel.state, self.readerContent.pageURL)

        try Task.checkCancellation()
        do {
            try Task.checkCancellation()
            do {
                let contentTrace = ReaderLoadTrace.begin("webview.commit.content")
                defer { contentTrace?.end() }
                try await readerContent.load(url: state.pageURL)
            }
            try Task.checkCancellation()
            guard let content = readerContent.content else {
                readerModeViewModel.cancelReaderModeLoad(
                    for: state.pageURL,
                    readerContent: readerContent
                )
                return
            }
            // ReaderContent can suppress an obsolete startup blank load.
            // Validate selection before publishing any commit side effects.
            guard content.url.matchesReaderURL(state.pageURL) else {
                throw CancellationError()
            }
            if !readerModeViewModel.expectsSyntheticReaderLoaderCommit(
                for: state.pageURL
            ) {
                // Only the admitted document can release the preceding overlay.
                readerContent.isRenderingReaderHTML = false
            }
            do {
                let viewModelTrace = ReaderLoadTrace.begin("webview.commit.viewModel")
                defer { viewModelTrace?.end() }
                try await readerViewModel.onNavigationCommitted(
                    content: content,
                    newState: state
                )
                try Task.checkCancellation()
            }
            do {
                let readerModeTrace = ReaderLoadTrace.begin("webview.commit.readerMode")
                defer { readerModeTrace?.end() }
                try await readerModeViewModel.onNavigationCommitted(
                    readerContent: readerContent,
                    newState: state,
                    scriptCaller: scriptCaller,
                    navigator: navigator
                )
                try Task.checkCancellation()
            }
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
        let trace = ReaderLoadTrace.begin("webview.finish")
        defer { trace?.end() }
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
        // Decide at event admission: the queued target may already have been
        // accepted by the time an asynchronous commit task gets to run.
        guard !shouldIgnoreIntermediateBlankCallback(state: state, callback: "commit") else { return }
        ReaderLoadTrace.event("webview.didCommit", "loader=\(state.pageURL.isReaderURLLoaderURL)")
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
        guard !shouldIgnoreIntermediateBlankCallback(state: state, callback: "finish") else { return }
        ReaderLoadTrace.event("webview.didFinish", "loader=\(state.pageURL.isReaderURLLoaderURL)")
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
        ReaderLoadTrace.event("webview.navigationFailed",
                              "disposition=\(disposition.rawValue) loader=\(state.pageURL.isReaderURLLoaderURL) ready=\(state.hasReaderRenderReady) errorCode=\(state.error.map { ($0 as NSError).code } ?? 0)")
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
        ReaderLoadTrace.event("webview.documentContextInvalidated",
                              "reason=\(reason.rawValue) loader=\(state.pageURL.isReaderURLLoaderURL) ready=\(state.hasReaderRenderReady)")
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
        guard !shouldIgnoreIntermediateBlankCallback(state: state, callback: "urlChanged") else { return }
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

// WebView owns its callback closures for longer than a single SwiftUI body
// evaluation. Keep the callback target stable while replacing the handler it
// forwards to whenever ReaderWebView receives newer environment objects.
@MainActor
fileprivate final class ReaderWebViewCallbackRelay: ObservableObject {
    var handler: ReaderWebViewHandler?
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
    @State private var defaultEBookPackageSessions = ReaderEBookServingSessionStore()
    @Environment(\.readerEBookPackageSessions) private var readerEBookPackageSessions
    @State private var readerFileURLSchemeHandler = ReaderFileURLSchemeHandler()
    // SwiftUI can rebuild this value-type view while a navigation callback is
    // suspended. Keep one task owner across those rebuilds so a newer callback,
    // failure, process termination, or document detach can cancel older work.
    @State private var navigationTaskManager = NavigationTaskManager()
    @StateObject private var callbackRelay = ReaderWebViewCallbackRelay()
    
    @EnvironmentObject internal var readerContent: ReaderContent
    @EnvironmentObject internal var scriptCaller: WebViewScriptCaller
    @EnvironmentObject internal var readerViewModel: ReaderViewModel
    @EnvironmentObject internal var readerModeViewModel: ReaderModeViewModel
    @EnvironmentObject internal var readerMediaPlayerViewModel: ReaderMediaPlayerViewModel
    @Environment(\.webViewNavigator) internal var navigator: WebViewNavigator

    @MainActor
    private func makeHandler() -> ReaderWebViewHandler {
        ReaderWebViewHandler(
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
    }

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

    private func configuredEBookURLSchemeHandler() -> EbookURLSchemeHandler {
        let handler = ebookURLSchemeHandler
        handler.packageSessions = readerEBookPackageSessions ?? defaultEBookPackageSessions
        return handler
    }

    
    public var body: some View {
        let handler = makeHandler()
        let _ = callbackRelay.handler = handler
        let ebookURLSchemeHandler = configuredEBookURLSchemeHandler()
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
            callbackRelay: callbackRelay
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
            ebookURLSchemeHandler.sharedReaderFontAsset = readerModeViewModel.sharedReaderFontAsset
            readerFileURLSchemeHandler.sharedReaderFontAsset = readerModeViewModel.sharedReaderFontAsset
        }
        .readerFileManagerSetup { readerFileManager in
            readerFileURLSchemeHandler.readerFileManager = readerFileManager
            ebookURLSchemeHandler.readerFileManager = readerFileManager
        }
        // Visibility changes do not invalidate the mounted document. Its commit
        // may still be preparing reader HTML when a scene or overlay disappears.
        // Actual detach, replacement and process loss cancel through the document
        // context invalidation callback above.
    }
}

fileprivate struct ReaderWebViewInternal: View {
    @MainActor
    private static func recordConstructionTiming(_ timing: WebViewConstructionTiming) {
        ReaderLoadTrace.event("webview.construction",
            "step=\(timing.step.rawValue) elapsed_ms=\(String(format: "%.3f", timing.elapsedMilliseconds))")
    }

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
    let callbackRelay: ReaderWebViewCallbackRelay

    @State private var internalURLSchemeHandler = InternalURLSchemeHandler()
    
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
        // This long-lived reader owns its mounted WebView. A pool first created
        // here cannot prewarm it before mount; it instead starts blank-page
        // navigation and creates a spare during the first layout.
        let resolvedObscuredInsets = totalObscuredInsets(
            additionalInsets: EdgeInsets(
                top: max(0, additionalTopSafeAreaInset ?? 0),
                leading: max(0, additionalLeadingSafeAreaInset ?? 0),
                bottom: max(0, additionalBottomSafeAreaInset ?? 0),
                trailing: 0
            )
        )
        let constructionTiming: (@MainActor (WebViewConstructionTiming) -> Void)? =
            ReaderLoadTrace.isRecording("webview.construction") ? Self.recordConstructionTiming : nil
        WebView(
            config: WebViewConfig(
                dataDetectorsEnabled: false,
                backgroundColor: readerThemeBackgroundColor,
                usesSampledPageTopColorForUnderPageBackground: true,
                usesConfiguredBackgroundForReaderDocuments: true,
                adjustsScrollViewContentInsetsForSafeArea: false,
                reservesWindowTopSafeAreaInObscuredInsets: true,
                reservesDocumentTopInset: !state.pageURL.isEBookURL,
                reservesDocumentBottomInset: !usesEBookChromeInsets && !state.pageURL.isEBookURL,
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
                callbackRelay.handler?.onNavigationCommitted(state: state)
            },
            onNavigationFinished: { state in
                callbackRelay.handler?.onNavigationFinished(state: state)
            },
            onNavigationFailedWithDisposition: { state, disposition in
                callbackRelay.handler?.onNavigationFailed(
                    state: state,
                    disposition: disposition
                )
            },
            onDocumentContextInvalidated: { state, reason in
                callbackRelay.handler?.onDocumentContextInvalidated(
                    state: state,
                    reason: reason
                )
            },
            onURLChanged: { state in
                callbackRelay.handler?.onURLChanged(state: state)
            },
            onNavigationAction: { action in
                if ReaderLoadTrace.isRecording("webview.readerNavigationPolicy"),
                   action.targetFrame?.isMainFrame == true,
                   let url = action.request.url, url.isReaderDocumentURL {
                    let generation = ReaderDocumentResourceRegistry.shared.document(at: url)?.generation
                    ReaderLoadTrace.$operationID.withValue(generation) {
                        ReaderLoadTrace.event("webview.readerNavigationPolicy")
                    }
                }
                // Observation only: keep the WebView's normal navigation and
                // provider-frame security policy authoritative.
                return nil
            },
            onScrollBottomStateChanged: onScrollBottomStateChanged,
            buildMenu: { builder in
                buildMenu?(builder)
            },
            hideNavigationDueToScroll: $hideNavigationDueToScroll,
            textSelection: $textSelection,
            onConstructionTiming: constructionTiming
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
