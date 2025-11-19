import SwiftUI
import RealmSwift
import LakeKit
import SwiftUIWebView
import WebKit
import SwiftSoup
import Combine
import RealmSwiftGaps

fileprivate struct ThemeModifier: ViewModifier {
    @AppStorage("readerFontSize") internal var readerFontSize: Double?
    @AppStorage("lightModeTheme") var lightModeTheme: LightModeTheme = .white
    @AppStorage("darkModeTheme") var darkModeTheme: DarkModeTheme = .black
    @EnvironmentObject var scriptCaller: WebViewScriptCaller

    private func requestGeometryBake(reason: String) async {
        do {
            try await scriptCaller.evaluateJavaScript("window.reader?.view?.renderer?.requestTrackingSectionGeometryBake?.({ reason: '\(reason)', restoreLocation: true, immediate: true });", duplicateInMultiTargetFrames: true)
        } catch {
            print("Geometry bake request failed: \(error)")
        }
    }
    
    func body(content: Content) -> some View {
        content
            .onChange(of: lightModeTheme) { newValue in
                Task { @MainActor in
                    try await scriptCaller.evaluateJavaScript("""
                        if (document.body?.getAttribute('data-manabi-light-theme') !== '\(newValue)') {
                            document.body?.setAttribute('data-manabi-light-theme', '\(newValue)');
                        }
                        """, duplicateInMultiTargetFrames: true)
                    await requestGeometryBake(reason: "light-theme-change")
                }
            }
            .onChange(of: darkModeTheme) { newValue in
                Task { @MainActor in
                    try await scriptCaller.evaluateJavaScript("""
                        if (document.body?.getAttribute('data-manabi-dark-theme') !== '\(newValue)') {
                            document.body?.setAttribute('data-manabi-dark-theme', '\(newValue)');
                        }
                        """, duplicateInMultiTargetFrames: true)
                    await requestGeometryBake(reason: "dark-theme-change")
                }
            }
            .task(id: readerFontSize) { @MainActor in
                guard let readerFontSize else { return }
                do {
                    try await scriptCaller.evaluateJavaScript("document.body.style.fontSize = '\(readerFontSize)px';", duplicateInMultiTargetFrames: true)
                    await requestGeometryBake(reason: "font-size-change")
                } catch {
                    print("\(error)")
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
                guard urlsMatchWithoutHash(contentURL, readerViewModel.state.pageURL) else { return }
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
            .onChange(of: readerViewModel.state) { state in
                let shouldSyncProvisionalFlag: Bool
                if state.isProvisionallyNavigating {
                    shouldSyncProvisionalFlag = true
                } else {
                    let urlsMatch = readerContent.pageURL.matchesReaderURL(state.pageURL)
                    || state.pageURL.matchesReaderURL(readerContent.pageURL)
                    shouldSyncProvisionalFlag = urlsMatch || state.pageURL.isNativeReaderView
                }

                if shouldSyncProvisionalFlag,
                   readerContent.isReaderProvisionallyNavigating != state.isProvisionallyNavigating {
                    readerContent.isReaderProvisionallyNavigating = state.isProvisionallyNavigating
                }
                
                // TODO: Improve replaceState support if we need to detect navigation changes without provisional events.
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
        .modifier(ReaderLoadingProgressOverlayViewModifier(isLoading: readerModeViewModel.isReaderModeLoading, context: "ReaderWebView"))
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
        debugPrint("# FLASH WebViewNavigator.load begin", content.url)
        if let url = try await ReaderContentLoader.load(content: content, readerFileManager: readerFileManager) {
            debugPrint("# FLASH WebViewNavigator.load resolved url", url)
            if let readerModeViewModel {
                let previouslyLoadedContent = try await ReaderContentLoader.load(url: url, persist: false, countsAsHistoryVisit: false)
                if url.isHTTP || url.isFileURL || url.isSnippetURL || url.isReaderURLLoaderURL {
                    let trackingContent = (previouslyLoadedContent ?? content)
                    let loaderBaseURL = url.isReaderURLLoaderURL ? ReaderContentLoader.getContentURL(fromLoaderURL: url) : nil
                    let trackingURL = loaderBaseURL ?? trackingContent.url
                    let shouldTriggerReaderMode = trackingContent.isReaderModeByDefault || loaderBaseURL != nil
                    if shouldTriggerReaderMode {
                        readerModeViewModel.beginReaderModeLoad(for: trackingURL)
                    } else {
                        readerModeViewModel.cancelReaderModeLoad(for: trackingURL)
                    }
                    debugPrint(
                        "# READER readerMode.prefetchDecision",
                        "trackingURL=\(trackingURL.absoluteString)",
                        "shouldTrigger=\(shouldTriggerReaderMode)",
                        "forcedByLoader=\(loaderBaseURL != nil)",
                        "hasHTML=\(trackingContent.hasHTML)",
                        "rssFull=\(trackingContent.rssContainsFullContent)",
                        "compressedBytes=\(trackingContent.content?.count ?? 0)",
                        "requestURL=\(url.absoluteString)"
                    )
                }
            }
            load(URLRequest(url: url))
            debugPrint("# FLASH WebViewNavigator.load request issued", url)
        } else {
            debugPrint("# FLASH WebViewNavigator.load missing url", content.url)
        }
    }
}

public struct Reader: View {
    var persistentWebViewID: String? = nil
    var forceReaderModeWhenAvailable = false
//    var obscuredInsets: EdgeInsets? = nil
    var bounces = true
    var additionalBottomSafeAreaInset: CGFloat? = nil
    let schemeHandlers: [(WKURLSchemeHandler, String)]
    let onNavigationCommitted: ((WebViewState) async throws -> Void)?
    let onNavigationFinished: ((WebViewState) -> Void)?
    let onNavigationFailed: ((WebViewState) -> Void)?
    let onURLChanged: ((WebViewState) async throws -> Void)?
    @Binding var hideNavigationDueToScroll: Bool
    @Binding var textSelection: String?
    var buildMenu: BuildMenuType?
    
    @State private var obscuredInsets: EdgeInsets? = nil
    
    public init(
        persistentWebViewID: String? = nil,
        forceReaderModeWhenAvailable: Bool = false,
//        obscuredInsets: EdgeInsets? = nil,
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
        self.forceReaderModeWhenAvailable = forceReaderModeWhenAvailable
//        self.obscuredInsets = obscuredInsets
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
//            .modifier {
//                if #available(iOS 26, *) {
//                    $0.safeAreaBar(edge: .bottom, spacing: 0) {
//                        if let additionalBottomSafeAreaInset {
//                            Color.white.opacity(0.0000000001)
//                                .frame(height: additionalBottomSafeAreaInset)
//                        }
//                    }
//                } else { $0 }
//            }
//        .overlay(alignment: .bottom) {
//            if #available(iOS 26, *), let additionalBottomSafeAreaInset, additionalBottomSafeAreaInset > 0 {
//                Color.white.opacity(0.0000000001)
//                    .frame(height: additionalBottomSafeAreaInset)
//                    .allowsHitTesting(false)
//            }
//        }
        .ignoresSafeArea(.all, edges: .all)
        .modifier {
            if #available(iOS 26, *) {
                $0.safeAreaBar(edge: .bottom, spacing: 0) {
                    if let additionalBottomSafeAreaInset {
                        Color.white.opacity(0.0000000001)
                            .frame(height: additionalBottomSafeAreaInset)
                    }
                }
            } else { $0 }
        }
#endif
        .background {
            GeometryReader { geometry in
                Color.clear
                    .task { @MainActor in
                        obscuredInsets = geometry.safeAreaInsets
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
        .modifier(
            ReaderMessageHandlersViewModifier(
                forceReaderModeWhenAvailable: forceReaderModeWhenAvailable,
                hideNavigationDueToScroll: $hideNavigationDueToScroll
            )
        )
        .modifier(ReaderStateChangeModifier())
        .modifier(ThemeModifier())
        .modifier(PageMetadataModifier())
        .modifier(ReaderMediaPlayerViewModifier())
    }
}
