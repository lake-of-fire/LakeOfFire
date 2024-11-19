import SwiftUI
import RealmSwift
import LakeKit
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

class NavigationTaskManager: ObservableObject {
    @Published var onNavigationCommittedTask: Task<Void, Error>?
    @Published var onNavigationFinishedTask: Task<Void, Error>?
    
    func startOnNavigationCommitted(task: @escaping () async throws -> Void) {
        onNavigationCommittedTask?.cancel()
        onNavigationCommittedTask = Task { @MainActor in
            do {
                try await task()
            } catch {
                if !Task.isCancelled {
                    print("Error during onNavigationCommitted: \(error)")
                }
            }
        }
    }
    
    func startOnNavigationFinished(task: @escaping () async -> Void) {
        onNavigationFinishedTask?.cancel()
        onNavigationFinishedTask = Task { @MainActor in
            if let committedTask = onNavigationCommittedTask {
                _ = try? await committedTask.value // Wait for the committed task to finish if it's still running
            }
            try Task.checkCancellation()
            await task()
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
    @AppStorage("lightModeTheme") internal var lightModeTheme: LightModeTheme = .white
    @AppStorage("darkModeTheme") internal var darkModeTheme: DarkModeTheme = .black
    
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
    @Environment(\.colorScheme) private var colorScheme

    @StateObject private var navigationTaskManager = NavigationTaskManager()
    
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
        VStack(spacing: 0) {
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
                    onNavigationCommitted(state: state)
                },
                onNavigationFinished: { state in
                    navigationTaskManager.startOnNavigationFinished {
                        readerViewModel.onNavigationFinished(content: readerContent.content, newState: state) { newState in
                            if let onNavigationFinished = onNavigationFinished {
                                onNavigationFinished(newState)
                            }
                        }
                        Task {
                            await scriptCaller.evaluateJavaScript("return document.body?.classList.contains('readability-mode')") { @MainActor result in
                                switch result {
                                case .success(let response):
                                    if let isReaderMode = response as? Bool {
                                        withAnimation {
                                            readerModeViewModel.isReaderMode = state.pageURL.isEBookURL || isReaderMode
                                        }
                                    }
                                case .failure(let error):
                                    print(error)
                                }
                            }
                        }
                    }
                })
#if os(iOS)
            .edgesIgnoringSafeArea([.top, .bottom])
#endif
            .overlay {
                if !readerModeViewModel.isReaderMode && readerContent.content.isReaderModeByDefault {
                    ZStack {
                        Rectangle()
                            .fill(colorScheme == .dark ? .black.opacity(0.7) : .white.opacity(0.7))
                        Rectangle()
                            .fill(.ultraThickMaterial)
                        ProgressView()
                            .controlSize(.small)
                            .delayedAppearance()
                    }
                    .ignoresSafeArea(.all)
                }
            }
        }
        .onChange(of: readerViewModel.state) { [oldState = readerViewModel.state] state in
            if readerContent.isReaderProvisionallyNavigating != state.isProvisionallyNavigating {
                readerContent.isReaderProvisionallyNavigating = state.isProvisionallyNavigating
            }
            
            if !state.isLoading && !state.isProvisionallyNavigating, oldState.pageURL != state.pageURL, readerContent.content.url != state.pageURL {
                // May be from replaceState or pushState
                // TODO: Improve replaceState support
                onNavigationCommitted(state: state)
            }
        }
        .onChange(of: readerViewModel.state.pageImageURL) { pageImageURL in
            guard !readerContent.isReaderProvisionallyNavigating else { return }
            guard let imageURL = pageImageURL, readerContent.content.realm != nil, readerContent.content.url == readerViewModel.state.pageURL else { return }
            Task { @RealmBackgroundActor in
                try await readerContent.content.updateImageUrl(imageURL: imageURL)
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
                await scriptCaller.evaluateJavaScript("""
                    if (document.body?.getAttribute('data-manabi-light-theme') !== '\(lightModeTheme)') {
                        document.body?.setAttribute('data-manabi-light-theme', '\(lightModeTheme)');
                    }
                    """, duplicateInMultiTargetFrames: true)
            }
        }
        .onChange(of: darkModeTheme) { darkModeTheme in
            Task { @MainActor in
                await scriptCaller.evaluateJavaScript("""
                    if (document.body?.getAttribute('data-manabi-dark-theme') !== '\(darkModeTheme)') {
                        document.body?.setAttribute('data-manabi-dark-theme', '\(darkModeTheme)');
                    }
                    """, duplicateInMultiTargetFrames: true)
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
    }
    
    private func totalObscuredInsets(additionalInsets: EdgeInsets = .init(top: 0, leading: 0, bottom: 0, trailing: 0)) -> EdgeInsets {
#if os(iOS)
        let insets = EdgeInsets(top: (obscuredInsets?.top ?? 0) + additionalInsets.top, leading: (obscuredInsets?.leading ?? 0) + additionalInsets.leading, bottom: (obscuredInsets?.bottom ?? 0) + additionalInsets.bottom, trailing: (obscuredInsets?.trailing ?? 0) + additionalInsets.trailing)
        return insets
#else
        EdgeInsets()
#endif
    }
    
    private func onNavigationCommitted(state: WebViewState) {
        navigationTaskManager.startOnNavigationCommitted {
            do {
                try Task.checkCancellation()
                try await readerContent.load(url: state.pageURL)
                try Task.checkCancellation()
                try await readerViewModel.onNavigationCommitted(content: readerContent.content, newState: state)
                try Task.checkCancellation()
                try await readerModeViewModel.onNavigationCommitted(content: readerContent.content, newState: state)
                try Task.checkCancellation()
                try await readerMediaPlayerViewModel.onNavigationCommitted(content: readerContent.content, newState: state)
                try Task.checkCancellation()
                if let onNavigationCommitted = onNavigationCommitted {
                    try await onNavigationCommitted(state)
                }
            } catch {
                if Task.isCancelled {
                    print("onNavigationCommitted task was cancelled.")
                } else {
                    print("Error during onNavigationCommitted: \(error)")
                }
            }
        }
    }
}
