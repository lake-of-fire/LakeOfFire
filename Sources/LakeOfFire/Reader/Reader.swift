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
    
    func body(content: Content) -> some View {
        content
            .onChange(of: lightModeTheme) { newValue in
                Task { @MainActor in
                    try await scriptCaller.evaluateJavaScript("""
                        if (document.body?.getAttribute('data-manabi-light-theme') !== '\(newValue)') {
                            document.body?.setAttribute('data-manabi-light-theme', '\(newValue)');
                        }
                        """, duplicateInMultiTargetFrames: true)
                }
            }
            .onChange(of: darkModeTheme) { newValue in
                Task { @MainActor in
                    try await scriptCaller.evaluateJavaScript("""
                        if (document.body?.getAttribute('data-manabi-dark-theme') !== '\(newValue)') {
                            document.body?.setAttribute('data-manabi-dark-theme', '\(newValue)');
                        }
                        """, duplicateInMultiTargetFrames: true)
                }
            }
            .task(id: readerFontSize) { @MainActor in
                guard let readerFontSize else { return }
                do {
                    try await scriptCaller.evaluateJavaScript("document.body.style.fontSize = '\(readerFontSize)px';", duplicateInMultiTargetFrames: true)
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
            .modifier(ReaderLoadingProgressOverlayViewModifier(isLoading: $readerModeViewModel.isReaderModeLoading))
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
                readerModeViewModel.readerModeLoading((previouslyLoadedContent ?? content).isReaderModeByDefault)
            }
            load(URLRequest(url: url))
        }
    }
}

public struct Reader: View {
    var persistentWebViewID: String? = nil
    var forceReaderModeWhenAvailable = false
    var bounces = true
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
        bounces: Bool = true,
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
        self.bounces = bounces
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
        GeometryReader { geo in
            VStack(spacing: 0) {
                ReaderWebView(
                    persistentWebViewID: persistentWebViewID,
                    obscuredInsets: obscuredInsets,
                    bounces: bounces,
                    schemeHandlers: schemeHandlers,
                    onNavigationCommitted: onNavigationCommitted,
                    onNavigationFinished: onNavigationFinished,
                    onNavigationFailed: onNavigationFailed,
                    onURLChanged: onURLChanged,
                    hideNavigationDueToScroll: $hideNavigationDueToScroll,
                    textSelection: $textSelection,
                    buildMenu: buildMenu
                )
                .onChange(of: geo.safeAreaInsets) { safeAreaInsets in
                    obscuredInsets = safeAreaInsets
                }
            }
#if os(iOS)
            .edgesIgnoringSafeArea([.top, .bottom])
#endif
            .modifier(ReaderLoadingOverlayModifier())
        }
        .modifier(ReaderMessageHandlersViewModifier(forceReaderModeWhenAvailable: forceReaderModeWhenAvailable))
        .modifier(ReaderStateChangeModifier())
        .modifier(ThemeModifier())
        .modifier(PageMetadataModifier())
        .modifier(ReaderMediaPlayerViewModifier())
    }
}
