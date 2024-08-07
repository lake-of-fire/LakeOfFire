import SwiftUI
import RealmSwift
import SwiftUIWebView
import WebKit
import SwiftSoup
import Combine
import RealmSwiftGaps
import SplitView

public extension URL {
    var isNativeReaderView: Bool {
        return absoluteString == "about:blank" || (scheme == "internal" && host == "local" && path != "/snippet")
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
    func load(content: any ReaderContentProtocol, readerFileManager: ReaderFileManager) async throws {
        if let url = try await ReaderContentLoader.load(content: content, readerFileManager: readerFileManager) {
            load(URLRequest(url: url))
        }
    }
}

public struct Reader: View {
    var persistentWebViewID: String? = nil
    var forceReaderModeWhenAvailable = false
    var bounces = true
    var obscuredInsets: EdgeInsets? = nil
    var messageHandlers: [String: (WebViewMessage) async -> Void] = [:]
    var onNavigationCommitted: ((WebViewState) async throws -> Void)?
    var onNavigationFinished: ((WebViewState) -> Void)?
    
    @AppStorage("readerFontSize") internal var readerFontSize: Double?
    @AppStorage("lightModeTheme") private var lightModeTheme: LightModeTheme = .white
    @AppStorage("darkModeTheme") private var darkModeTheme: DarkModeTheme = .black
    
    @State private var internalURLSchemeHandler = InternalURLSchemeHandler()
    @State private var ebookURLSchemeHandler = EbookURLSchemeHandler()
    @State private var readerFileURLSchemeHandler = ReaderFileURLSchemeHandler()
    
    @EnvironmentObject internal var readerContent: ReaderContent
    @EnvironmentObject internal var scriptCaller: WebViewScriptCaller
    @EnvironmentObject internal var readerViewModel: ReaderViewModel
    @EnvironmentObject internal var readerModeViewModel: ReaderModeViewModel
    @EnvironmentObject internal var readerMediaPlayerViewModel: ReaderMediaPlayerViewModel
    @EnvironmentObject private var readerFileManager: ReaderFileManager
    @Environment(\.webViewNavigator) internal var navigator: WebViewNavigator

//    var url: URL {
//        return readerContent.content.url
//    }
    private var navigationTitle: String? {
        guard !readerContent.content.isInvalidated else { return nil }
        return readerContent.content.titleForDisplay
    }
    
    public init(persistentWebViewID: String? = nil, forceReaderModeWhenAvailable: Bool = false, bounces: Bool = true, obscuredInsets: EdgeInsets? = nil, messageHandlers: [String: (WebViewMessage) async -> Void] = [:], onNavigationCommitted: ((WebViewState) async throws -> Void)? = nil, onNavigationFinished: ((WebViewState) -> Void)? = nil) {
        self.persistentWebViewID = persistentWebViewID
        self.forceReaderModeWhenAvailable = forceReaderModeWhenAvailable
        self.bounces = bounces
        self.obscuredInsets = obscuredInsets
        self.messageHandlers = messageHandlers
        self.onNavigationCommitted = onNavigationCommitted
        self.onNavigationFinished = onNavigationFinished
    }
    
    public var body: some View {
        // TODO: Capture segment identifier and use it for unique word tracking instead of element ID
        // TODO: capture reading progress via sentence identifiers from a read section
        //        let _ = Self._printChanges()
        VStack(spacing: 0) {
//#if os(macOS)
//            if readerViewModel.isReaderModeButtonBarVisible {
////                ReaderModeButtonBar(readerViewModel: readerViewModel)
//                HStack {
//                    Spacer()
//                    Text("Hello")
//                    Spacer()
//                }
//            }
//#endif
            
            WebView(
                config: WebViewConfig(
                    contentRules: readerModeViewModel.contentRules,
                    dataDetectorsEnabled: false, // TODO: Bugs out with Manabi Reader callbacks...
                    userScripts: readerViewModel.allScripts),
                navigator: navigator,
                state: $readerViewModel.state,
                scriptCaller: scriptCaller,
                blockedHosts: Set([
                    "googleads.g.doubleclick.net", "tpc.googlesyndication.com", "pagead2.googlesyndication.com", "www.google-analytics.com", "www.googletagservices.com",
                    "adclick.g.doublecklick.net", "media-match.com", "www.omaze.com", "omaze.com", "pubads.g.doubleclick.net", "googlehosted.l.googleusercontent.com",
                    "pagead46.l.doubleclick.net", "pagead.l.doubleclick.net", "video-ad-stats.googlesyndication.com", "pagead-googlehosted.l.google.com",
                    "partnerad.l.doubleclick.net", "adserver.adtechus.com", "na.gmtdmp.com", "anycast.pixel.adsafeprotected.com", "d361oi6ppvq2ym.cloudfront.net",
                    "track.gawker.com", "domains.googlesyndication.com", "partner.googleadservices.com", "ads2.opensubtitles.org", "stats.wordpress.com", "botd.wordpress.com",
                    "adservice.google.ca", "adservice.google.com", "adservice.google.jp",
                ]),
                obscuredInsets: totalObscuredInsets(),
                bounces: bounces,
                persistentWebViewID: persistentWebViewID,
                schemeHandlers: [
                    (internalURLSchemeHandler, "internal"),
                    (readerFileURLSchemeHandler, "reader-file"),
                    (ebookURLSchemeHandler, "ebook"),
                ],
                messageHandlers: readerMessageHandlers(),
                onNavigationCommitted: { state in
                    Task { @MainActor in
                        readerContent.content = try await ReaderViewModel.getContent(forURL: state.pageURL) ?? ReaderContentLoader.unsavedHome
                        try await readerViewModel.onNavigationCommitted(content: readerContent.content, newState: state)
                        try await readerModeViewModel.onNavigationCommitted(content: readerContent.content, newState: state)
                        try await readerMediaPlayerViewModel.onNavigationCommitted(content: readerContent.content, newState: state)
                        if let onNavigationCommitted = onNavigationCommitted {
                            try await onNavigationCommitted(state)
                        }
                    }
                },
                onNavigationFinished: { state in
                    Task { @MainActor in
                        readerViewModel.onNavigationFinished(content: readerContent.content, newState: state) { newState in
                            if let onNavigationFinished = onNavigationFinished {
                                onNavigationFinished(newState)
                            }
                        }
                        
                        await scriptCaller.evaluateJavaScript("return document.body?.classList.contains('readability-mode')") { @MainActor result in
                            switch result {
                            case .success(let response):
                                if let isReaderMode = response as? Bool {
                                    readerModeViewModel.isReaderMode = state.pageURL.isEBookURL || isReaderMode
                                }
                            case .failure(let error):
                                print(error)
                            }
                        }
                    }
                })
#if os(iOS)
            .edgesIgnoringSafeArea([.top, .bottom])
#endif
        }
        .onChange(of: readerViewModel.state) { state in
            if let imageURL = state.pageImageURL, readerContent.content.realm != nil, readerContent.content.url == state.pageURL, readerContent.content.imageUrl == nil {
                readerContent.content.updateImageUrl(imageURL: imageURL)
            }
        }
        .onChange(of: readerViewModel.state.pageTitle) { pageTitle in
            Task { @MainActor in
                try await readerViewModel.pageMetadataUpdated(title: pageTitle)
            }
        }
        .task(id: readerFontSize) { @MainActor in
            guard let readerFontSize = readerFontSize else { return }
            await scriptCaller.evaluateJavaScript("document.body.style.fontSize = '\(readerFontSize)px';", duplicateInMultiTargetFrames: true)
        }
        .onChange(of: lightModeTheme) { lightModeTheme in
            Task { @MainActor in
                await scriptCaller.evaluateJavaScript("document.body?.setAttribute('data-manabi-light-theme', '\(lightModeTheme)')", duplicateInMultiTargetFrames: true)
            }
        }
        .onChange(of: darkModeTheme) { darkModeTheme in
            Task { @MainActor in
                await scriptCaller.evaluateJavaScript("document.body?.setAttribute('data-manabi-dark-theme', '\(darkModeTheme)')", duplicateInMultiTargetFrames: true)
            }
        }
        .onChange(of: readerMediaPlayerViewModel.audioURLs) { audioURLs in
            Task { @MainActor in
                readerMediaPlayerViewModel.isMediaPlayerPresented = !audioURLs.isEmpty
            }
        }
        .task { @MainActor in
            ebookURLSchemeHandler.ebookTextProcessor = ebookTextProcessor
        }
        .task(id: readerFileManager.ubiquityContainerIdentifier) { @MainActor in
            readerFileURLSchemeHandler.readerFileManager = readerFileManager
            ebookURLSchemeHandler.readerFileManager = readerFileManager
        }
//#if os(iOS)
//        .toolbar {
//            ToolbarItem(placement: .automatic) {
//                //        .safeAreaInset(edge: .top, spacing: 0) {
//                if readerViewModel.isReaderModeButtonBarVisible {
//                    ReaderModeButtonBar(readerViewModel: readerViewModel)
//                }
//                //        }
//            }
//        }
//#endif
    }
    
    private func totalObscuredInsets(additionalInsets: EdgeInsets = .init(top: 0, leading: 0, bottom: 0, trailing: 0)) -> EdgeInsets {
#if os(iOS)
        let insets = EdgeInsets(top: (obscuredInsets?.top ?? 0) + additionalInsets.top, leading: (obscuredInsets?.leading ?? 0) + additionalInsets.leading, bottom: (obscuredInsets?.bottom ?? 0) + additionalInsets.bottom, trailing: (obscuredInsets?.trailing ?? 0) + additionalInsets.trailing)
        return insets
#else
        EdgeInsets()
#endif
    }
}
