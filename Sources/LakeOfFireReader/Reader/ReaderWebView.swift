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

/// One mounted reader's model identity survives SwiftUI's callback-wrapper
/// reconstruction. A different model tuple gets a different owner, including
/// a return to the same models after an intervening replacement.
@MainActor
final class ReaderNavigationCallbackOwner {
    let readerContent: ReaderContent
    let readerViewModel: ReaderViewModel
    let readerModeViewModel: ReaderModeViewModel
    let readerMediaPlayerViewModel: ReaderMediaPlayerViewModel
    let scriptCaller: WebViewScriptCaller

    init(
        readerContent: ReaderContent,
        readerViewModel: ReaderViewModel,
        readerModeViewModel: ReaderModeViewModel,
        readerMediaPlayerViewModel: ReaderMediaPlayerViewModel,
        scriptCaller: WebViewScriptCaller
    ) {
        self.readerContent = readerContent
        self.readerViewModel = readerViewModel
        self.readerModeViewModel = readerModeViewModel
        self.readerMediaPlayerViewModel = readerMediaPlayerViewModel
        self.scriptCaller = scriptCaller
    }

    func matches(_ other: ReaderNavigationCallbackOwner) -> Bool {
        readerContent === other.readerContent
            && readerViewModel === other.readerViewModel
            && readerModeViewModel === other.readerModeViewModel
            && readerMediaPlayerViewModel === other.readerMediaPlayerViewModel
            && scriptCaller === other.scriptCaller
    }
}

/// Carries the original callback's binding and load receipt. Navigation activity
/// is separate from authority: ending its token does not retire a live document.
@MainActor
final class ReaderNavigationCallbackContext {
    let owner: ReaderNavigationCallbackOwner
    weak var taskManager: NavigationTaskManager?
    let binding: WebViewScriptCaller.JavaScriptBindingToken?
    let pageURL: URL
    var documentIsCurrent: @MainActor () -> Bool = { true }
    private(set) var selectionIsCurrent: (@MainActor () -> Bool)?
    var navigationActivityToken: UUID?

    var readerContent: ReaderContent { owner.readerContent }
    var readerViewModel: ReaderViewModel { owner.readerViewModel }
    var readerModeViewModel: ReaderModeViewModel { owner.readerModeViewModel }
    var readerMediaPlayerViewModel: ReaderMediaPlayerViewModel { owner.readerMediaPlayerViewModel }
    var scriptCaller: WebViewScriptCaller { owner.scriptCaller }

    init(owner: ReaderNavigationCallbackOwner, taskManager: NavigationTaskManager, state: WebViewState) {
        self.owner = owner
        self.taskManager = taskManager
        binding = owner.scriptCaller.currentJavaScriptBindingToken
        pageURL = state.pageURL
    }

    func captureSelection(using receipt: ReaderContentLoadReceipt) {
        captureSelection(requiring: { receipt.isCurrent })
    }

    func captureSelection(requiring fence: @escaping @MainActor () -> Bool) {
        guard selectionIsCurrent == nil else { return }
        let content = readerContent.content
        let pageURL = self.pageURL
        selectionIsCurrent = { [weak readerContent = readerContent] in
            guard let readerContent else { return false }
            return fence() && readerContent.content === content
                && readerContent.pageURL.matchesReaderURL(pageURL)
        }
    }

    func owns(requiringSelection: Bool) -> Bool {
        guard !Task.isCancelled, documentIsCurrent(), !Task.isCancelled,
              taskManager?.callbackOwner === owner,
              readerViewModel.scriptCaller === scriptCaller,
              scriptCaller.currentJavaScriptBindingToken == binding,
              binding != nil || !scriptCaller.canEvaluateJavaScript else { return false }
        return !requiringSelection || selectionIsCurrent?() == true
    }

    func endNavigationActivity() {
        let token = navigationActivityToken
        navigationActivityToken = nil
        if let token { readerContent.endMainFrameNavigationTask(token) }
    }
}

// To avoid redraws...
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

    private let navigationTaskManager: NavigationTaskManager
    private let callbackOwner: ReaderNavigationCallbackOwner

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
        callbackOwner = navigationTaskManager.registerCallbackOwner(.init(
            readerContent: readerContent, readerViewModel: readerViewModel,
            readerModeViewModel: readerModeViewModel,
            readerMediaPlayerViewModel: readerMediaPlayerViewModel,
            scriptCaller: scriptCaller
        ))
        readerViewModel.bindSettingsOwner(navigationTaskManager)
    }

    private func makeCallbackContext(state: WebViewState) -> ReaderNavigationCallbackContext {
        .init(owner: callbackOwner, taskManager: navigationTaskManager, state: state)
    }

    func handleNavigationCommitted(state: WebViewState) async throws {
        try await handleNavigationCommitted(state: state, context: makeCallbackContext(state: state))
    }

    private func handleNavigationCommitted(state: WebViewState, context: ReaderNavigationCallbackContext) async throws {
        guard context.owns(requiringSelection: false) else { throw CancellationError() }
        let receipt = try await context.readerContent.loadWithSelectionReceipt(url: state.pageURL)
        guard context.owns(requiringSelection: false), receipt.isCurrent,
              context.readerContent.pageURL.matchesReaderURL(state.pageURL) else {
            throw CancellationError()
        }
        context.captureSelection(using: receipt)
        guard let content = context.readerContent.content, !content.isInvalidated else { return }
        let contentURL = content.url
        let requireCurrentContent = { @MainActor in
            guard context.owns(requiringSelection: true), !content.isInvalidated,
                  content.url == contentURL, contentURL.matchesReaderURL(state.pageURL) else {
                throw CancellationError()
            }
        }
        try requireCurrentContent()
        try await context.readerViewModel.onNavigationCommitted(content: content, newState: state)
        try requireCurrentContent()
        try await context.readerModeViewModel.onNavigationCommitted(
            readerContent: context.readerContent,
            newState: state,
            scriptCaller: context.scriptCaller
        )
        try requireCurrentContent()
        try await context.readerMediaPlayerViewModel.onNavigationCommitted(content: content, newState: state)
        try requireCurrentContent()
    }

    func handleNavigationFinished(state: WebViewState) async {
        let context = makeCallbackContext(state: state)
        context.captureSelection(requiring: readerContent.makeSelectionCommitFence(
            requiring: readerContent.currentSelectionID
        ))
        await handleNavigationFinished(state: state, context: context)
    }

    private func handleNavigationFinished(state: WebViewState, context: ReaderNavigationCallbackContext) async {
        let isCurrent = { @MainActor in context.owns(requiringSelection: true) }
        guard context.pageURL.matchesReaderURL(state.pageURL), isCurrent() else { return }
        await context.readerModeViewModel.onNavigationFinished(
            newState: state,
            scriptCaller: context.scriptCaller,
            documentIsCurrent: isCurrent
        )
        guard isCurrent(), let content = context.readerContent.content,
              !content.isInvalidated, content.url.matchesReaderURL(state.pageURL) else { return }
        context.readerViewModel.onNavigationFinished(
            content: content, newState: state, documentIsCurrent: isCurrent
        )
    }

    func handleURLChanged(state: WebViewState) async throws {
        try await handleURLChanged(state: state, context: makeCallbackContext(state: state))
    }

    private func handleURLChanged(state: WebViewState, context: ReaderNavigationCallbackContext) async throws {
        try await handleNavigationCommitted(state: state, context: context)
        guard context.owns(requiringSelection: true) else { throw CancellationError() }
        await handleNavigationFinished(state: state, context: context)
        guard context.owns(requiringSelection: true) else { throw CancellationError() }
    }

    func onNavigationCommitted(state: WebViewState) {
        guard navigationTaskManager.callbackOwner === callbackOwner else { return }
        let context = makeCallbackContext(state: state)
        let previousContext = navigationTaskManager.committedCallbackContext
        navigationTaskManager.committedCallbackContext = context
        previousContext?.endNavigationActivity()
        guard navigationTaskManager.committedCallbackContext === context,
              context.owns(requiringSelection: false) else { return }
        context.navigationActivityToken = readerContent.beginMainFrameNavigationTask(to: state.pageURL)
        guard navigationTaskManager.committedCallbackContext === context,
              context.owns(requiringSelection: false) else {
            context.endNavigationActivity()
            return
        }
        navigationTaskManager.startOnNavigationCommitted {
            do {
                try await self.handleNavigationCommitted(state: state, context: context)
                guard context.owns(requiringSelection: true) else { throw CancellationError() }
            } catch {
                context.endNavigationActivity()
                throw error
            }
            do {
                try await self.onNavigationCommitted?(state)
                guard context.owns(requiringSelection: true) else { throw CancellationError() }
            } catch is CancellationError {
                context.endNavigationActivity()
                throw CancellationError()
            } catch {
                print("Error during public onNavigationCommitted: \(error)")
            }
        }
        let documentFence = navigationTaskManager.makeDocumentCommitFence()
        context.documentIsCurrent = { [weak navigationTaskManager, weak context] in
            guard let navigationTaskManager, let context else { return false }
            return navigationTaskManager.committedCallbackContext === context && documentFence()
        }
    }

    func onNavigationFinished(state: WebViewState) {
        guard navigationTaskManager.callbackOwner === callbackOwner else { return }
        guard let context = navigationTaskManager.committedCallbackContext,
              context.pageURL.matchesReaderURL(state.pageURL) else { return }
        navigationTaskManager.startOnNavigationFinished { @MainActor in
            defer { context.endNavigationActivity() }
            guard context.owns(requiringSelection: true) else { throw CancellationError() }
            await self.handleNavigationFinished(state: state, context: context)
            guard context.owns(requiringSelection: true) else { throw CancellationError() }
            self.onNavigationFinished?(state)
        }
    }

    func onNavigationFailed(
        state: WebViewState,
        disposition: WebViewNavigationFailureDisposition
    ) {
        guard navigationTaskManager.callbackOwner === callbackOwner else { return }
        let context = navigationTaskManager.committedCallbackContext
        let failedContext = context?.pageURL.matchesReaderURL(state.pageURL) == true ? context : nil
        let preservesCommittedDocument = disposition == .preservedCommittedDocument
        let isCurrent = { @MainActor in
            !Task.isCancelled
                && self.navigationTaskManager.callbackOwner === self.callbackOwner
                && self.navigationTaskManager.committedCallbackContext === (preservesCommittedDocument ? context : nil)
        }
        navigationTaskManager.startOnNavigationFailed(
            preservingCommittedDocument: preservesCommittedDocument
        ) { @MainActor in
            guard isCurrent() else { return }
            failedContext?.endNavigationActivity()
            guard isCurrent() else { return }
            if !preservesCommittedDocument {
                self.readerModeViewModel.onNavigationFailed(newState: state)
            }
            guard isCurrent() else { return }
            self.onNavigationFailed?(state)
        }
    }

    func onDocumentContextInvalidated(
        state: WebViewState,
        reason: WebViewDocumentContextInvalidationReason
    ) {
        guard navigationTaskManager.callbackOwner === callbackOwner else { return }
        navigationTaskManager.cancelNavigationWork()
        let isCurrent = { @MainActor in
            self.navigationTaskManager.callbackOwner === self.callbackOwner
                && self.navigationTaskManager.committedCallbackContext == nil
        }
        guard isCurrent() else { return }
        if reason == .webContentProcessTerminated {
            readerModeViewModel.onNavigationFailed(newState: state)
            guard isCurrent() else { return }
            onNavigationFailed?(state)
        }
        guard isCurrent() else { return }
        onDocumentContextInvalidated?(state, reason)
    }

    func onURLChanged(state: WebViewState) {
        guard navigationTaskManager.callbackOwner === callbackOwner else { return }
        let context = makeCallbackContext(state: state)
        context.documentIsCurrent = navigationTaskManager.makeDocumentCommitFence()
        navigationTaskManager.startOnURLChanged { @MainActor in
            try await self.handleURLChanged(state: state, context: context)
            guard context.owns(requiringSelection: true) else { throw CancellationError() }
            do {
                try await self.onURLChanged?(state)
                guard context.owns(requiringSelection: true) else { throw CancellationError() }
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
    @Environment(\.readerWebViewDataStore) private var readerWebViewDataStore

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
        let websiteDataStore = readerWebViewDataStore ?? WKWebsiteDataStore.default()
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
            handler: handler,
            websiteDataStore: websiteDataStore
        )
        .id(ObjectIdentifier(websiteDataStore))
        .task(id: ebookSchemeBindingState) { @MainActor in
            navigator.shouldLoadFallbackOnAttach = false
            ebookURLSchemeHandler.ebookProcessedTextCacheReader = readerModeViewModel.ebookProcessedTextCacheReader
            ebookURLSchemeHandler.ebookProcessedTextCacheWriter = readerModeViewModel.ebookProcessedTextCacheWriter
            ebookURLSchemeHandler.ebookProcessedPayloadAdmission = readerModeViewModel.ebookProcessedPayloadAdmission
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

#if os(iOS)
@MainActor
final class ReaderWebViewPoolOwner: ObservableObject {
    let prewarmer = WebViewPrewarmer(
        warmUpCount: 1,
        keepAliveCount: 0,
        defaultResetURL: URL(string: "about:blank")
    )

    deinit {
        // Older SwiftUIWebView factories retain their prewarmer through the
        // creation closure. This owner is never passed into that closure.
        MainActor.assumeIsolated {
            prewarmer.pool.invalidate(resetURL: nil)
        }
    }
}
#endif

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
    let websiteDataStore: WKWebsiteDataStore

    @State private var internalURLSchemeHandler = InternalURLSchemeHandler()
#if os(iOS)
    @StateObject private var webViewPoolOwner = ReaderWebViewPoolOwner()
#endif

    @Environment(\.readerWebViewConfigurationTransform) private var readerWebViewConfigurationTransform
    @Environment(\.readerWebViewMessageHandlersTransform) private var readerWebViewMessageHandlersTransform
    @Environment(\.webViewMessageHandlers) private var webViewMessageHandlers
    @Environment(\.webViewNavigator) private var navigator: WebViewNavigator
    @Environment(\.readerNavigationActionHandler) private var readerNavigationActionHandler
    @Environment(\.readerNavigationActionContextHandler) private var readerNavigationActionContextHandler
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
        let webViewPrewarmer: WebViewPrewarmer? = webViewPoolOwner.prewarmer
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
        let resolvedWebsiteDataStore = websiteDataStore

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
