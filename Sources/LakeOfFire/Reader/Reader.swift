import SwiftUI
import RealmSwift
import LakeKit
import SwiftUIWebView
import WebKit
import SwiftSoup
import Combine
import RealmSwiftGaps

typealias ReaderSettingsJavaScriptEvaluator = (_ js: String, _ duplicateInMultiTargetFrames: Bool) async throws -> Void

@MainActor
func readerPaginationTrackingSettingsKey(
    readerFontSize: Double?,
    lightModeTheme: LightModeTheme,
    darkModeTheme: DarkModeTheme
) -> String {
    "pagination-size:v1|font:\(readerFontSize ?? 0)|light:\(lightModeTheme.rawValue)|dark:\(darkModeTheme.rawValue)"
}

@MainActor
func syncReaderPaginationTrackingSettingsKey(
    readerFontSize: Double?,
    lightModeTheme: LightModeTheme,
    darkModeTheme: DarkModeTheme,
    reason: String,
    hasAsyncCaller: Bool,
    evaluateJavaScript: ReaderSettingsJavaScriptEvaluator
) async {
    guard hasAsyncCaller else {
        debugPrint("# READER paginationSettingsKey.set.skip", "reason=\(reason)", "key=<nil>", "info=no asyncCaller")
        return
    }
    let key = readerPaginationTrackingSettingsKey(
        readerFontSize: readerFontSize,
        lightModeTheme: lightModeTheme,
        darkModeTheme: darkModeTheme
    )
    do {
        try await evaluateJavaScript(
            "window.paginationTrackingSettingsKey = '" + key + "';",
            true
        )
        debugPrint("# READER paginationSettingsKey.set", "reason=\(reason)", "key=\(key)")
    } catch {
        debugPrint("# READER paginationSettingsKey.set.error", error.localizedDescription)
    }
}

@MainActor
func requestReaderTrackingSectionGeometryBake(
    reason: String,
    evaluateJavaScript: ReaderSettingsJavaScriptEvaluator
) async {
    do {
        try await evaluateJavaScript(
            "window.reader?.view?.renderer?.requestTrackingSectionGeometryBake?.({ reason: '\(reason)', restoreLocation: true, immediate: true });",
            true
        )
    } catch {
        print("Geometry bake request failed: \(error)")
    }
}

@MainActor
func applyReaderFontSize(
    _ size: Double,
    readerFontSize: Double?,
    lightModeTheme: LightModeTheme,
    darkModeTheme: DarkModeTheme,
    reason: String,
    hasAsyncCaller: Bool,
    evaluateJavaScript: ReaderSettingsJavaScriptEvaluator
) async {
    guard hasAsyncCaller else {
        debugPrint("# READER paginationSettingsKey.set.skip", "reason=\(reason)", "key=<nil>", "info=no asyncCaller")
        return
    }
    do {
        try await evaluateJavaScript("document.body.style.fontSize = '\(size)px';", true)
        await syncReaderPaginationTrackingSettingsKey(
            readerFontSize: readerFontSize,
            lightModeTheme: lightModeTheme,
            darkModeTheme: darkModeTheme,
            reason: "font-size-change",
            hasAsyncCaller: hasAsyncCaller,
            evaluateJavaScript: evaluateJavaScript
        )
        await requestReaderTrackingSectionGeometryBake(reason: reason, evaluateJavaScript: evaluateJavaScript)
    } catch {
        print("Font size update failed: \(error)")
    }
}

@MainActor
func applyInitialReaderPresentationSettings(
    readerFontSize: Double?,
    lightModeTheme: LightModeTheme,
    darkModeTheme: DarkModeTheme,
    hasAsyncCaller: Bool,
    evaluateJavaScript: ReaderSettingsJavaScriptEvaluator
) async {
    await syncReaderPaginationTrackingSettingsKey(
        readerFontSize: readerFontSize,
        lightModeTheme: lightModeTheme,
        darkModeTheme: darkModeTheme,
        reason: "initial",
        hasAsyncCaller: hasAsyncCaller,
        evaluateJavaScript: evaluateJavaScript
    )
    if let readerFontSize {
        await applyReaderFontSize(
            readerFontSize,
            readerFontSize: readerFontSize,
            lightModeTheme: lightModeTheme,
            darkModeTheme: darkModeTheme,
            reason: "font-size-initial",
            hasAsyncCaller: hasAsyncCaller,
            evaluateJavaScript: evaluateJavaScript
        )
    }
}

@MainActor
func applyReaderLightTheme(
    _ lightModeTheme: LightModeTheme,
    readerFontSize: Double?,
    darkModeTheme: DarkModeTheme,
    hasAsyncCaller: Bool,
    evaluateJavaScript: ReaderSettingsJavaScriptEvaluator
) async throws {
    try await evaluateJavaScript(
        """
        if (document.body?.getAttribute('data-manabi-light-theme') !== '\(lightModeTheme)') {
            document.body?.setAttribute('data-manabi-light-theme', '\(lightModeTheme)');
        }
        """,
        true
    )
    await syncReaderPaginationTrackingSettingsKey(
        readerFontSize: readerFontSize,
        lightModeTheme: lightModeTheme,
        darkModeTheme: darkModeTheme,
        reason: "light-theme-change",
        hasAsyncCaller: hasAsyncCaller,
        evaluateJavaScript: evaluateJavaScript
    )
    await requestReaderTrackingSectionGeometryBake(reason: "light-theme-change", evaluateJavaScript: evaluateJavaScript)
}

@MainActor
func applyReaderDarkTheme(
    _ darkModeTheme: DarkModeTheme,
    readerFontSize: Double?,
    lightModeTheme: LightModeTheme,
    hasAsyncCaller: Bool,
    evaluateJavaScript: ReaderSettingsJavaScriptEvaluator
) async throws {
    try await evaluateJavaScript(
        """
        if (document.body?.getAttribute('data-manabi-dark-theme') !== '\(darkModeTheme)') {
            document.body?.setAttribute('data-manabi-dark-theme', '\(darkModeTheme)');
        }
        """,
        true
    )
    await syncReaderPaginationTrackingSettingsKey(
        readerFontSize: readerFontSize,
        lightModeTheme: lightModeTheme,
        darkModeTheme: darkModeTheme,
        reason: "dark-theme-change",
        hasAsyncCaller: hasAsyncCaller,
        evaluateJavaScript: evaluateJavaScript
    )
    await requestReaderTrackingSectionGeometryBake(reason: "dark-theme-change", evaluateJavaScript: evaluateJavaScript)
}

fileprivate struct ThemeModifier: ViewModifier {
    @AppStorage("readerFontSize") internal var readerFontSize: Double?
    @AppStorage("lightModeTheme") var lightModeTheme: LightModeTheme = .white
    @AppStorage("darkModeTheme") var darkModeTheme: DarkModeTheme = .black
    @EnvironmentObject var scriptCaller: WebViewScriptCaller

    private func applyFontSize(_ size: Double, reason: String) async {
        await applyReaderFontSize(
            size,
            readerFontSize: readerFontSize,
            lightModeTheme: lightModeTheme,
            darkModeTheme: darkModeTheme,
            reason: reason,
            hasAsyncCaller: scriptCaller.hasAsyncCaller
        ) { js, duplicateInMultiTargetFrames in
            _ = try await scriptCaller.evaluateJavaScript(
                js,
                duplicateInMultiTargetFrames: duplicateInMultiTargetFrames
            )
        }
    }
    
    func body(content: Content) -> some View {
        content
            .onChange(of: lightModeTheme) { newValue in
                Task { @MainActor in
                    try await applyReaderLightTheme(
                        newValue,
                        readerFontSize: readerFontSize,
                        darkModeTheme: darkModeTheme,
                        hasAsyncCaller: scriptCaller.hasAsyncCaller
                    ) { js, duplicateInMultiTargetFrames in
                        _ = try await scriptCaller.evaluateJavaScript(
                            js,
                            duplicateInMultiTargetFrames: duplicateInMultiTargetFrames
                        )
                    }
                }
            }
            .onChange(of: darkModeTheme) { newValue in
                Task { @MainActor in
                    try await applyReaderDarkTheme(
                        newValue,
                        readerFontSize: readerFontSize,
                        lightModeTheme: lightModeTheme,
                        hasAsyncCaller: scriptCaller.hasAsyncCaller
                    ) { js, duplicateInMultiTargetFrames in
                        _ = try await scriptCaller.evaluateJavaScript(
                            js,
                            duplicateInMultiTargetFrames: duplicateInMultiTargetFrames
                        )
                    }
                }
            }
            .task { @MainActor in
                await applyInitialReaderPresentationSettings(
                    readerFontSize: readerFontSize,
                    lightModeTheme: lightModeTheme,
                    darkModeTheme: darkModeTheme,
                    hasAsyncCaller: scriptCaller.hasAsyncCaller
                ) { js, duplicateInMultiTargetFrames in
                    _ = try await scriptCaller.evaluateJavaScript(
                        js,
                        duplicateInMultiTargetFrames: duplicateInMultiTargetFrames
                    )
                }
            }
            .onChange(of: readerFontSize) { newValue in
                guard let newValue else { return }
                Task { @MainActor in
                    await applyFontSize(newValue, reason: "font-size-change")
                }
            }
    }
}

fileprivate struct PageMetadataModifier: ViewModifier {
    @EnvironmentObject var readerContent: ReaderContent
    @EnvironmentObject var readerViewModel: ReaderViewModel
    
    func body(content: Content) -> some View {
        content
            .onChange(of: readerViewModel.state.pageImageURL) { pageImageURL in
                guard !readerContent.isReaderProvisionallyNavigating else { return }
                guard let imageURL = pageImageURL,
                      let contentItem = readerContent.content,
                      contentItem.realm != nil else { return }
                let contentURL = contentItem.url
                guard contentURL == readerViewModel.state.pageURL else { return }
                Task { @RealmBackgroundActor in
                    let contents = try await ReaderContentLoader.loadAll(url: contentURL)
                    for content in contents where content.imageUrl == nil {
                        try await content.realm?.asyncWrite {
                            content.imageUrl = imageURL
                            content.refreshChangeMetadata(explicitlyModified: true)
                        }
                    }
                }
            }
            .onChange(of: readerViewModel.state.pageTitle) { pageTitle in
                Task { @MainActor in
                    try await readerViewModel.pageMetadataUpdated(title: pageTitle)
                }
            }
    }
}

fileprivate struct ReaderStateChangeModifier: ViewModifier {
    @EnvironmentObject var readerContent: ReaderContent
    @EnvironmentObject var readerViewModel: ReaderViewModel
    
    func body(content: Content) -> some View {
        content
            .onChange(of: readerViewModel.state) { [oldState = readerViewModel.state] state in
                if readerContent.isReaderProvisionallyNavigating != state.isProvisionallyNavigating {
                    readerContent.isReaderProvisionallyNavigating = state.isProvisionallyNavigating
                }
                
                //            if !state.isLoading && !state.isProvisionallyNavigating, oldState.pageURL != state.pageURL, readerContent.content.url != state.pageURL {
                // May be from replaceState or pushState
                // TODO: Improve replaceState support
                //                onNavigationCommitted(state: state)
                //            }
            }
    }
}

fileprivate struct ReaderMediaPlayerViewModifier: ViewModifier {
    @EnvironmentObject var readerMediaPlayerViewModel: ReaderMediaPlayerViewModel
    
    func body(content: Content) -> some View {
        content
            .onChange(of: readerMediaPlayerViewModel.audioURLs) { audioURLs in
                Task { @MainActor in
                    readerMediaPlayerViewModel.isMediaPlayerPresented = !audioURLs.isEmpty
                }
            }
    }
}

fileprivate struct ReaderLoadingOverlayModifier: ViewModifier {
    @EnvironmentObject var readerModeViewModel: ReaderModeViewModel
    
    func body(content: Content) -> some View {
        content
            .modifier(ReaderLoadingProgressOverlayViewModifier(isLoading: readerModeViewModel.isReaderModeLoading))
//            .overlay { Text(readerModeViewModel.isReaderModeLoading ? "read" : "") }
//            .overlay {
//                Text(readerModeViewModel.isReaderModeLoading.description)
//                    .font(.title)
//            }
    }
}

public extension URL {
    var isNativeReaderView: Bool {
        if absoluteString == "about:blank" {
            return true
        }
        return ReaderProtocolRegistry.shared.get(forURL: self)?.providesNativeReaderView(forURL: self) ?? false
    }
}

public struct WebViewNavigatorEnvironmentKey: EnvironmentKey {
    public static var defaultValue = WebViewNavigator()
}

public extension EnvironmentValues {
    // the new key path to access your object (\.object)
    var webViewNavigator: WebViewNavigator {
        get { self[WebViewNavigatorEnvironmentKey.self] }
        set { self[WebViewNavigatorEnvironmentKey.self] = newValue }
    }
}

public extension WebViewNavigator {
    /// Injects browser history (unlike loadHTMLWithBaseURL)
    @MainActor
    func load(
        content: any ReaderContentProtocol,
        readerFileManager: ReaderFileManager = ReaderFileManager.shared,
        readerModeViewModel: ReaderModeViewModel?
    ) async throws {
        if let url = try await ReaderContentLoader.load(content: content, readerFileManager: readerFileManager) {
            if let readerModeViewModel {
                let previouslyLoadedContent = try await ReaderContentLoader.load(url: url, persist: false, countsAsHistoryVisit: false)
                if url.isHTTP || url.isFileURL || url.isSnippetURL || url.isReaderURLLoaderURL {
                    
                    let isLoading = (previouslyLoadedContent ?? content).isReaderModeByDefault
                    readerModeViewModel.readerModeLoading(isLoading)
//                    debugPrint("# WebViewNavigator load", isLoading)
                }
            }
            load(URLRequest(url: url))
        }
    }
}

public struct Reader: View {
    var persistentWebViewID: String? = nil
    var forceReaderModeWhenAvailable = false
//    var obscuredInsets: EdgeInsets? = nil
    var bounces = true
    var additionalBottomSafeAreaInset: CGFloat? = nil
    var onAdditionalSafeAreaBarTap: (() -> Void)?
    let schemeHandlers: [(WKURLSchemeHandler, String)]
    let onNavigationCommitted: ((WebViewState) async throws -> Void)?
    let onNavigationFinished: ((WebViewState) -> Void)?
    let onNavigationFailed: ((WebViewState) -> Void)?
    let onURLChanged: ((WebViewState) async throws -> Void)?
    @Binding var hideNavigationDueToScroll: Bool
    @Binding var textSelection: String?
    var buildMenu: BuildMenuType?
    
    @EnvironmentObject private var readerContent: ReaderContent
    @EnvironmentObject private var scriptCaller: WebViewScriptCaller
    
    @State private var obscuredInsets: EdgeInsets? = nil
    
    public init(
        persistentWebViewID: String? = nil,
        forceReaderModeWhenAvailable: Bool = false,
//        obscuredInsets: EdgeInsets? = nil,
        bounces: Bool = true,
        additionalBottomSafeAreaInset: CGFloat? = nil,
        onAdditionalSafeAreaBarTap: (() -> Void)? = nil,
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
        self.forceReaderModeWhenAvailable = forceReaderModeWhenAvailable
//        self.obscuredInsets = obscuredInsets
        self.bounces = bounces
        self.additionalBottomSafeAreaInset = additionalBottomSafeAreaInset
        self.onAdditionalSafeAreaBarTap = onAdditionalSafeAreaBarTap
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
        //            VStack(spacing: 0) {
        ReaderWebView(
            persistentWebViewID: persistentWebViewID,
            obscuredInsets: obscuredInsets,
            bounces: bounces,
            additionalBottomSafeAreaInset: additionalBottomSafeAreaInset,
            schemeHandlers: schemeHandlers,
            onNavigationCommitted: onNavigationCommitted,
            onNavigationFinished: onNavigationFinished,
            onNavigationFailed: onNavigationFailed,
            onURLChanged: onURLChanged,
            hideNavigationDueToScroll: $hideNavigationDueToScroll,
            textSelection: $textSelection,
            buildMenu: buildMenu
        )
#if os(iOS)
        .ignoresSafeArea(.all, edges: .all)
        .modifier {
            if #available(iOS 26, *) {
                $0.safeAreaBar(edge: .bottom, spacing: 0) {
                    if let additionalBottomSafeAreaInset, additionalBottomSafeAreaInset > 0 {
                        Color.white.opacity(0.0000000001)
                            .frame(height: additionalBottomSafeAreaInset)
                            .onTapGesture {
                                onAdditionalSafeAreaBarTap?()
                            }
                    }
                }
            } else { $0 }
        }
#endif
        .background {
            GeometryReader { geometry in
                Color.clear
                    .task {
                        obscuredInsets = EdgeInsets(
                            top: max(0, geometry.safeAreaInsets.top),
                            leading: max(0, geometry.safeAreaInsets.leading),
                            bottom: max(0, geometry.safeAreaInsets.bottom),
                            trailing: max(0, geometry.safeAreaInsets.trailing)
                        )
                    }
                    .onChange(of: geometry.safeAreaInsets) { safeAreaInsets in
                        obscuredInsets = EdgeInsets(
                            top: max(0, safeAreaInsets.top),
                            leading: max(0, safeAreaInsets.leading),
                            bottom: max(0, safeAreaInsets.bottom),
                            trailing: max(0, safeAreaInsets.trailing)
                        )
                    }
            }
        }
        //            }
        //#if os(iOS)
        //            .edgesIgnoringSafeArea([.top, .bottom])
        //            .ignoresSafeArea(.all, edges: [.top, .bottom])
        //#endif
//                .ignoresSafeArea(.all, edges: [.top, .bottom])
        .modifier(ReaderLoadingOverlayModifier())
        .modifier(ReaderMessageHandlersViewModifier(
            forceReaderModeWhenAvailable: forceReaderModeWhenAvailable,
            hideNavigationDueToScroll: $hideNavigationDueToScroll
        ))
        .modifier(ReaderStateChangeModifier())
        .modifier(ThemeModifier())
        .modifier(PageMetadataModifier())
        .modifier(ReaderMediaPlayerViewModifier())
        .onReceive(readerContent.contentTitleSubject.receive(on: RunLoop.main)) { _ in
            Task { @MainActor in
                guard scriptCaller.hasAsyncCaller else { return }
                let displayTitle = readerContent.content?.titleForDisplay ?? readerContent.contentTitle
                guard !displayTitle.isEmpty else { return }
                do {
                    try await scriptCaller.evaluateJavaScript(
                        """
                        (function() {
                          const el = document.getElementById('reader-title');
                          if (el && el.textContent !== title) {
                            el.textContent = title;
                          }
                        })();
                        """,
                        arguments: ["title": displayTitle],
                        duplicateInMultiTargetFrames: true
                    )
                } catch {
                    debugPrint("# READER title.sync.failed", error.localizedDescription)
                }
            }
        }
    }
}
