import SwiftUI
import RealmSwift
import SwiftUIWebView
import WebKit
import SwiftSoup
import Combine
import RealmSwiftGaps
import SwiftUIDownloads

struct ReaderWebViewStateKey: EnvironmentKey {
    static let defaultValue: WebViewState = .empty
}

public extension EnvironmentValues {
    var readerWebViewState: WebViewState {
        get { self[ReaderWebViewStateKey.self] }
        set { self[ReaderWebViewStateKey.self] = newValue }
    }
}

public extension URL {
    var isNativeReaderView: Bool {
        return absoluteString == "about:blank" || (scheme == "internal" && host == "local" && path != "/snippet")
    }
}

public extension WebViewNavigator {
    /// Injects browser history (unlike loadHTMLWithBaseURL)
    @MainActor
    func load(content: any ReaderContentModel, readerFileManager: ReaderFileManager) async {
        var url: URL?
        if content.url.isEBookURL {
//            guard let absoluteStringWithoutScheme = content.url.absoluteStringWithoutScheme, let loadURL = URL(string: "ebook://ebook/load" + absoluteStringWithoutScheme) else {
//                print("Invalid ebook URL \(content.url)")
//                return
//            }
            url = content.url
        } else if !content.url.isReaderFileURL, content.isReaderModeByDefault, await content.htmlToDisplay(readerFileManager: readerFileManager) != nil {
            guard let encodedURL = content.url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics), let historyURL = URL(string: "internal://local/load/reader?reader-url=\(encodedURL)") else { return }
            url = historyURL
        } else {
            url = content.url
        }
        if let url = url {
            Task { @MainActor in
                load(URLRequest(url: url))
            }
        }
    }
}

public struct Reader: View {
    @ObservedObject var readerViewModel: ReaderViewModel
    var persistentWebViewID: String? = nil
    var forceReaderModeWhenAvailable = false
    var bounces = true
    var obscuredInsets: EdgeInsets? = nil
    var messageHandlers: [String: (WebViewMessage) async -> Void] = [:]
    var onNavigationCommitted: ((WebViewState) async throws -> Void)?
    var onNavigationFinished: ((WebViewState) -> Void)?
    
    @ObservedObject private var downloadController = DownloadController.shared
    
    @ScaledMetric(relativeTo: .body) internal var defaultFontSize: CGFloat = Font.pointSize(for: Font.TextStyle.body) + 2 // Keep in sync with ReaderSettings defaultFontSize
    @AppStorage("readerFontSize") internal var readerFontSize: Double?
    @AppStorage("lightModeTheme") private var lightModeTheme: LightModeTheme = .white
    @AppStorage("darkModeTheme") private var darkModeTheme: DarkModeTheme = .black
    
    @State private var internalURLSchemeHandler = InternalURLSchemeHandler()
    @State private var ebookURLSchemeHandler = EbookURLSchemeHandler()
    @State private var readerFileURLSchemeHandler = ReaderFileURLSchemeHandler()
    
    @EnvironmentObject private var readerFileManager: ReaderFileManager
    
//    var url: URL {
//        return readerViewModel.content.url
//    }
    private var navigationTitle: String? {
        guard !readerViewModel.content.isInvalidated else { return nil }
        return readerViewModel.content.titleForDisplay
    }
    
    public init(readerViewModel: ReaderViewModel, persistentWebViewID: String? = nil, forceReaderModeWhenAvailable: Bool = false, bounces: Bool = true, obscuredInsets: EdgeInsets? = nil, messageHandlers: [String: (WebViewMessage) async -> Void] = [:], onNavigationCommitted: ((WebViewState) async throws -> Void)? = nil, onNavigationFinished: ((WebViewState) -> Void)? = nil) {
        self.readerViewModel = readerViewModel
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
        GeometryReader { geometry in
            WebView(
                config: WebViewConfig(
                    contentRules: readerViewModel.contentRules,
                    userScripts: readerViewModel.allScripts),
                navigator: readerViewModel.navigator,
                state: $readerViewModel.state,
                scriptCaller: readerViewModel.scriptCaller,
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
                messageHandlers: [
                    "readabilityFramePing": { @MainActor message in
                        guard let uuid = (message.body as? [String: String])?["uuid"], let windowURLRaw = (message.body as? [String: String])?["windowURL"] as? String, let windowURL = URL(string: windowURLRaw) else { return }
                        guard !windowURL.isNativeReaderView, let content = try? await readerViewModel.getContent(forURL: windowURL) else { return }
                        if readerViewModel.scriptCaller.addMultiTargetFrame(message.frameInfo, uuid: uuid) {
                            readerViewModel.refreshSettingsInWebView(content: content)
                        }
                    },
                    "readabilityParsed": { message in
                        guard let result = ReadabilityParsedMessage(fromMessage: message) else {
                            return
                        }
                        try? await Task { @MainActor in
                            guard let url = result.windowURL, url == readerViewModel.state.pageURL, let content = try await readerViewModel.getContent(forURL: url) else { return }
                            if !message.frameInfo.isMainFrame, readerViewModel.readabilityContent != nil, readerViewModel.readabilityContainerFrameInfo != message.frameInfo {
                                // Don't override a parent window readability result.
                                return
                            }
                            guard !result.outputHTML.isEmpty else {
                                try? await content.asyncWrite { _, content in
                                    content.isReaderModeAvailable = false
                                }
                                return
                            }
 
                            guard !url.isNativeReaderView else { return }
                            readerViewModel.readabilityContent = result.outputHTML
                            readerViewModel.readabilityContainerSelector = result.readabilityContainerSelector
                            readerViewModel.readabilityContainerFrameInfo = message.frameInfo
                            if content.isReaderModeByDefault || forceReaderModeWhenAvailable {
                                readerViewModel.showReaderView(content: content)
                            } else if result.outputHTML.filter({ String($0).hasKanji || String($0).hasKana }).count > 50 {
                                await readerViewModel.scriptCaller.evaluateJavaScript("document.body?.classList.add('manabi-reader-mode-available-confidently')")
                            }
                            
                            if !content.isReaderModeAvailable {
                                try await content.asyncWrite { _, content in
                                    content.isReaderModeAvailable = true
                                }
                            }
                        }.value
                    },
                    "showReaderView": { _ in
                        Task { @MainActor in readerViewModel.showReaderView() }
                    },
                    "showOriginal": { _ in
                        Task { @MainActor in
                            try await showOriginal()
                        }
                    },
                    //            .onMessageReceived(forName: "youtubeCaptions") { message in
                    //                Task { @MainActor in
                    //                    guard let result = YoutubeCaptionsMessage(fromMessage: message) else { return }
                    //                }
                    //            }
                    "rssURLs": { message in
                        Task { @MainActor in
                            guard let result = RSSURLsMessage(fromMessage: message) else { return }
                            guard let windowURL = result.windowURL, !windowURL.isNativeReaderView, let content = try await readerViewModel.getContent(forURL: windowURL) else { return }
                            let pairs = result.rssURLs.prefix(10)
                            let urls = pairs.compactMap { $0.first }.compactMap { URL(string: $0) }
                            let titles = pairs.map { $0.last ?? $0.first ?? "" }
                            try await content.asyncWrite { _, content in
                                content.rssURLs.removeAll()
                                content.rssTitles.removeAll()
                                content.rssURLs.append(objectsIn: urls)
                                content.rssTitles.append(objectsIn: titles)
                                content.isRSSAvailable = !content.rssURLs.isEmpty
                            }
                        }
                    },
                    "pageMetadataUpdated": { message in
                        Task { @MainActor in
                            guard let result = PageMetadataUpdatedMessage(fromMessage: message) else { return }
                            guard result.url == readerViewModel.state.pageURL else { return }
                            try await readerViewModel.pageMetadataUpdated(title: result.title, author: result.author)
                        }
                    },
                    "imageUpdated": { message in
                        Task { @RealmBackgroundActor in
                            guard let result = ImageUpdatedMessage(fromMessage: message) else { return }
                            guard let url = result.mainDocumentURL, !url.isNativeReaderView else { return }
                            let contents = try await ReaderContentLoader.loadAll(url: url)
                            for content in contents {
                                guard content.imageUrl != result.newImageURL else { continue }
                                try await content.realm?.asyncWrite {
                                    content.imageUrl = result.newImageURL
                                }
                            }
                        }
                    },
                    "ebookViewerInitialized": { message in
                        let url = readerViewModel.state.pageURL
                        if let scheme = url.scheme, scheme == "ebook" || scheme == "ebook-url", url.absoluteString.hasPrefix("\(url.scheme ?? "")://"), url.isEBookURL, let loaderURL = URL(string: "\(scheme)://\(url.absoluteString.dropFirst("\(url.scheme ?? "")://".count))") {
                            Task { @MainActor in
                                await  readerViewModel.scriptCaller.evaluateJavaScript("window.loadEBook({ url })", arguments: ["url": loaderURL.absoluteString])
                            }
                        }
                    },
                ].merging(messageHandlers) { (current, new) in
                    return { message in
                        await current(message)
                        await new(message)
                    }
                },
                onNavigationCommitted: { state in
                    Task { @MainActor in
                        readerViewModel.isReaderMode = state.pageURL.isEBookURL
                        readerViewModel.readabilityContainerFrameInfo = nil
                        try await readerViewModel.onNavigationCommitted(newState: state)
                        if let onNavigationCommitted = onNavigationCommitted {
                            try await onNavigationCommitted(state)
                        }
                    }
                },
                onNavigationFinished: { state in
                    Task { @MainActor in
                        readerViewModel.onNavigationFinished(newState: state) { newState in
                            if let onNavigationFinished = onNavigationFinished {
                                onNavigationFinished(newState)
                            }
                        }
                        
                        await readerViewModel.scriptCaller.evaluateJavaScript("return document.body?.classList.contains('readability-mode')") { @MainActor result in
                            switch result {
                            case .success(let response):
                                if let isReaderMode = response as? Bool {
                                    readerViewModel.isReaderMode = state.pageURL.isEBookURL || isReaderMode
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
            .onChange(of: readerViewModel.state.pageTitle) { pageTitle in
                Task { @MainActor in
                    try await readerViewModel.pageMetadataUpdated(title: pageTitle)
                }
            }
            .task(id: readerFontSize) { @MainActor in
                guard let readerFontSize = readerFontSize else { return }
                await readerViewModel.scriptCaller.evaluateJavaScript("document.body.style.fontSize = '\(readerFontSize)px';", duplicateInMultiTargetFrames: true)
            }
            .onChange(of: lightModeTheme) { lightModeTheme in
                Task { @MainActor in
                    await readerViewModel.scriptCaller.evaluateJavaScript("document.body?.setAttribute('data-manabi-light-theme', '\(lightModeTheme)')", duplicateInMultiTargetFrames: true)
                }
            }
            .onChange(of: darkModeTheme) { darkModeTheme in
                Task { @MainActor in
                    await readerViewModel.scriptCaller.evaluateJavaScript("document.body?.setAttribute('data-manabi-dark-theme', '\(darkModeTheme)')", duplicateInMultiTargetFrames: true)
                }
            }
            .onChange(of: readerViewModel.audioURLs) { audioURLs in
                Task { @MainActor in
                    readerViewModel.isMediaPlayerPresented = !audioURLs.isEmpty
                }
            }
            .safeAreaInset(edge: .bottom) {
                if readerViewModel.content.isReaderModeAvailable && !readerViewModel.content.isReaderModeByDefault {
                    ReaderModeButtonBar(showReaderView: {
                       readerViewModel.showReaderView()
                    })
                }
            }
            .task { @MainActor in
                readerViewModel.defaultFontSize = defaultFontSize
                ebookURLSchemeHandler.ebookTextProcessor = ebookTextProcessor
            }
            .task(id: readerFileManager.ubiquityContainerIdentifier) { @MainActor in
                readerFileURLSchemeHandler.readerFileManager = readerFileManager
                ebookURLSchemeHandler.readerFileManager = readerFileManager
            }
        }
    }
   
    private func totalObscuredInsets(additionalInsets: EdgeInsets = .init(top: 0, leading: 0, bottom: 0, trailing: 0)) -> EdgeInsets {
#if os(iOS)
//        EdgeInsets(top: (obscuredInsets?.top ?? 0) + additionalInsets.top, leading: (obscuredInsets?.leading ?? 0) + additionalInsets.leading, bottom: (obscuredInsets?.bottom ?? 0) + additionalInsets.bottom, trailing: (obscuredInsets?.trailing ?? 0) + additionalInsets.trailing)
        return EdgeInsets(top: (obscuredInsets?.top ?? 0) + additionalInsets.top, leading: (obscuredInsets?.leading ?? 0) + additionalInsets.leading, bottom: (obscuredInsets?.bottom ?? 0) + additionalInsets.bottom, trailing: (obscuredInsets?.trailing ?? 0) + additionalInsets.trailing)
#else
        EdgeInsets()
#endif
    }
}

//fileprivate extension Reader {
//    // MARK: Reader settings in web view
//
//    func refreshSettingsInWebView(in frame: WKFrameInfo? = nil) {
//        Task { @MainActor in
//            await readerViewModel.scriptCaller.evaluateJavaScript(
//                """
//                if (\(readerFontSize ?? -1) > -1) {
//                    document.body?.style.fontSize = '\(readerFontSize ?? -1)px'
//                }
//                document.body?.setAttribute('data-manabi-light-theme', '\(lightModeTheme)')
//                document.body?.setAttribute('data-manabi-dark-theme', '\(darkModeTheme)')
//                """,
//                in: frame, duplicateInMultiTargetFrames: true, in: .page)
//        }
//    }
//}

fileprivate extension Reader {
    // MARK: Readability
    
    @MainActor
    func showOriginal() async throws {
        //        if !(readerViewModel.content is FeedEntry) {
        try await readerViewModel.content.asyncWrite { _, content in
            content.isReaderModeByDefault = false
        }
        //        }
        readerViewModel.navigator.reload()
    }
}
