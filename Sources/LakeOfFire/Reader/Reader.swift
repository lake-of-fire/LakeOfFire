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
struct ReaderContentKey: EnvironmentKey {
    static let defaultValue: (any ReaderContentModel) = ReaderContentLoader.unsavedHome
}

public extension EnvironmentValues {
//    var readerContentURL: URL {
//        get { self[ReaderContentURLKey.self] }
//        set { self[ReaderContentURLKey.self] = newValue }
//    }
    var readerContent: (any ReaderContentModel) {
        get { self[ReaderContentKey.self] }
        set { self[ReaderContentKey.self] = newValue }
    }
    var readerWebViewState: WebViewState {
        get { self[ReaderWebViewStateKey.self] }
        set { self[ReaderWebViewStateKey.self] = newValue }
    }
}

public extension URL {
    var isNativeReaderView: Bool {
        return scheme == "about" && (["about:blank"].contains(absoluteString) || absoluteString.hasPrefix("about:load"))
    }
}

public extension WebViewNavigator {
    /// Injects browser history (unlike loadHTMLWithBaseURL)
    func load(content: any ReaderContentModel) {
        if content.isReaderModeByDefault && content.htmlToDisplay != nil {
            guard let encodedURL = content.url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics), let historyURL = URL(string: "about:load/reader?reader-url=\(encodedURL)") else { return }
            load(URLRequest(url: historyURL))
        } else {
            load(URLRequest(url: content.url))
        }
    }
}

public struct Reader: View {
    @ObservedObject var readerViewModel: ReaderViewModel
    var persistentWebViewID: String? = nil
    var forceReaderModeWhenAvailable = false
    var bounces = true
    var processReadabilityContent: ((SwiftSoup.Document) -> SwiftSoup.Document)? = nil
    var obscuredInsets: EdgeInsets? = nil
    var messageHandlers: [String: (WebViewMessage) async -> Void] = [:]
    var onNavigationCommitted: ((WebViewState) -> Void)?
    var onNavigationFinished: ((WebViewState) -> Void)?
    
    @ObservedObject private var downloadController = DownloadController.shared
    
    @ScaledMetric(relativeTo: .body) private var defaultFontSize: CGFloat = Font.pointSize(for: Font.TextStyle.body) + 2 // Keep in sync with ReaderSettings defaultFontSize
    @AppStorage("readerFontSize") private var readerFontSize: Double?
    @AppStorage("lightModeTheme") private var lightModeTheme: LightModeTheme = .white
    @AppStorage("darkModeTheme") private var darkModeTheme: DarkModeTheme = .black
    
    var url: URL {
        return readerViewModel.content.url
    }
    private var navigationTitle: String? {
        guard !readerViewModel.content.isInvalidated else { return nil }
        return readerViewModel.content.titleForDisplay
    }
    
    public init(readerViewModel: ReaderViewModel, persistentWebViewID: String? = nil, forceReaderModeWhenAvailable: Bool = false, bounces: Bool = true, processReadabilityContent: ((SwiftSoup.Document) -> SwiftSoup.Document)? = nil, obscuredInsets: EdgeInsets? = nil, messageHandlers: [String: (WebViewMessage) async -> Void] = [:], onNavigationCommitted: ((WebViewState) -> Void)? = nil, onNavigationFinished: ((WebViewState) -> Void)? = nil) {
        self.readerViewModel = readerViewModel
        self.persistentWebViewID = persistentWebViewID
        self.forceReaderModeWhenAvailable = forceReaderModeWhenAvailable
        self.bounces = bounces
        self.processReadabilityContent = processReadabilityContent
        self.obscuredInsets = obscuredInsets
        self.messageHandlers = messageHandlers
        self.onNavigationCommitted = onNavigationCommitted
        self.onNavigationFinished = onNavigationFinished
    }
    
    public var body: some View {
        // TODO: Capture segment identifier and use it for unique word tracking instead of element ID
        // TODO: capture reading progress via sentence identifiers from a read section
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
            obscuredInsets: obscuredInsets ?? EdgeInsets(),
            bounces: bounces,
            persistentWebViewID: persistentWebViewID,
            messageHandlers: [
                "readabilityParsed": { message in
                    guard let result = ReadabilityParsedMessage(fromMessage: message) else {
                        return
                    }
                    guard readerViewModel.content.url == result.pageURL else { return }
                    guard !result.content.isEmpty else {
                        safeWrite(readerViewModel.content) { _, content in
                            readerViewModel.content.isReaderModeAvailable = false
                        }
                        return
                    }
                    Task { @MainActor in
                        guard !url.isNativeReaderView else { return }
                        readerViewModel.readabilityContent = result.outputHTML
                        if readerViewModel.isNextLoadInReaderMode || forceReaderModeWhenAvailable {
                            readerViewModel.isNextLoadInReaderMode = false
                            showReaderView()
                        } else if result.outputHTML.filter({ String($0).hasKanji || String($0).hasKana }).count > 50 {
                            readerViewModel.scriptCaller.evaluateJavaScript("document.documentElement.classList.add('manabi-reader-mode-available-confidently')")
                        }
                        safeWrite(readerViewModel.content) { _, content in
                            readerViewModel.content.isReaderModeAvailable = true
                            #warning("FIXME: have the button check for any matching records, or make sure that view model prefers history record, or doesn't switch, etc")
                        }
                    }
                },
                "showReaderView": { _ in
                    Task { @MainActor in showReaderView() }
                },
                "showOriginal": { _ in
                    Task { @MainActor in showOriginal() }
                },
                //            .onMessageReceived(forName: "youtubeCaptions") { message in
                //                Task { @MainActor in
                //                    guard let result = YoutubeCaptionsMessage(fromMessage: message) else { return }
                //                }
                //            }
                "rssURLs": { message in
                    Task { @MainActor in
                        guard !url.isNativeReaderView else { return }
                        guard let result = RSSURLsMessage(fromMessage: message) else { return }
                        let pairs = result.rssURLs.prefix(10)
                        let urls = pairs.compactMap { $0.first }.compactMap { URL(string: $0) }
                        let titles = pairs.map { $0.last ?? $0.first ?? "" }
                        safeWrite(readerViewModel.content) { _, content in
                            content.rssURLs.removeAll()
                            content.rssTitles.removeAll()
                            content.rssURLs.append(objectsIn: urls)
                            content.rssTitles.append(objectsIn: titles)
                            content.isRSSAvailable = !content.rssURLs.isEmpty
                        }
                    }
                },
                "titleUpdated": { message in
                    Task { @MainActor in
                        guard !url.isNativeReaderView else { return }
                        guard let result = TitleUpdatedMessage(fromMessage: message) else { return }
                        guard result.url == readerViewModel.state.pageURL && result.url == readerViewModel.content.url else { return }
                        let newTitle = fixAnnoyingTitlesWithPipes(title: result.newTitle)
                        // Only update if empty... sometimes annoying titles load later.
                        if readerViewModel.content.titleForDisplay.isEmpty && readerViewModel.content.title.isEmpty, !newTitle.isEmpty {
                            safeWrite(readerViewModel.content) { _, content in
                                content.title = newTitle
                            }
                            readerViewModel.refreshTitleInWebView()
                        }
                    }
                }
            ].merging(messageHandlers) { (current, _) in current },
            onNavigationCommitted: { state in
                readerViewModel.onNavigationCommitted(newState: state) { newState in
                    if let onNavigationCommitted = onNavigationCommitted {
                        onNavigationCommitted(newState)
                    }
                }
            },
            onNavigationFinished: { state in
                readerViewModel.onNavigationFinished(newState: state) { newState in
                    if let onNavigationFinished = onNavigationFinished {
                        onNavigationFinished(newState)
                    }
                }
            })
        .edgesIgnoringSafeArea(.all)
        .onChange(of: readerFontSize) { newFontSize in
            guard let newFontSize = newFontSize else { return }
            Task { @MainActor in
                readerViewModel.scriptCaller.evaluateJavaScript("document.documentElement.style.fontSize = '\(newFontSize)px';")
            }
        }
        .onChange(of: lightModeTheme) { lightModeTheme in
            Task { @MainActor in
                readerViewModel.scriptCaller.evaluateJavaScript("document.documentElement.setAttribute('data-manabi-light-theme', '\(lightModeTheme)')")
            }
        }
        .onChange(of: darkModeTheme) { darkModeTheme in
            Task { @MainActor in
                readerViewModel.scriptCaller.evaluateJavaScript("document.documentElement.setAttribute('data-manabi-dark-theme', '\(darkModeTheme)')")
            }
        }
        .onChange(of: readerViewModel.audioURLs) { audioURLs in
            Task { @MainActor in
                readerViewModel.isMediaPlayerPresented = !audioURLs.isEmpty
            }
        }
        .safeAreaInset(edge: .bottom) {
            if readerViewModel.content.isReaderModeAvailable && !readerViewModel.content.isReaderModeByDefault {
                ReaderModeButtonBar(showReaderView: showReaderView)
            }
        }
    }
}

fileprivate extension Reader {
    // MARK: Readability
   
    @MainActor
    func showOriginal() {
        if !(readerViewModel.content is FeedEntry) {
            safeWrite(readerViewModel.content) { _, content in
                content.isReaderModeByDefault = false
            }
        }
        readerViewModel.navigator.reload()
    }
    
    @MainActor
    func showReaderView() {
        guard let readabilityContent = readerViewModel.readabilityContent else {
            return
        }
        let title = readerViewModel.content.title
        let imageURL = readerViewModel.content.imageUrl
        let renderToSelector = url.isEPUBURL ? "#viewer" : nil
        Task.detached(priority: .userInitiated) {
            do {
                try await showReadabilityContent(content: readabilityContent, url: url, defaultTitle: title, imageURL: imageURL, renderToSelector: renderToSelector)
            } catch { }
        }
    }
    
    /// Content before it has been treated with Reader-specific processing.
    private func showReadabilityContent(content: String, url: URL?, defaultTitle: String?, imageURL: URL?, renderToSelector: String?) async throws {
        return try await withCheckedThrowingContinuation({ (continuation: CheckedContinuation<(), Error>) in
            safeWrite(readerViewModel.content) { _, content in
                content.isReaderModeAvailable = true
                content.isReaderModeByDefault = true
            }
            
            let injectEntryImageIntoHeader = readerViewModel.content.injectEntryImageIntoHeader
            let readerFontSize = readerFontSize
            let defaultFontSize = defaultFontSize
            let processReadabilityContent = processReadabilityContent
            Task.detached {
                var doc: SwiftSoup.Document
                do {
                    if let url = url {
                        doc = try SwiftSoup.parse(content, url.absoluteString)
                    } else {
                        doc = try SwiftSoup.parse(content)
                    }
                } catch {
                    print(error.localizedDescription)
                    continuation.resume()
                    return
                }
                doc.outputSettings().prettyPrint(pretty: false)
                
                if let htmlTag = try? doc.select("html") {
                    var htmlStyle = "font-size: \(readerFontSize ?? defaultFontSize)px"
                    if let existingHtmlStyle = try? htmlTag.attr("style"), !existingHtmlStyle.isEmpty {
                        htmlStyle = "\(htmlStyle); \(existingHtmlStyle)"
                    }
                    _ = try? htmlTag.attr("style", htmlStyle)
                }
                
                if let defaultTitle = defaultTitle, let existing = try? doc.select("#reader-title"), !existing.hasText() {
                    let escapedTitle = Entities.escape(defaultTitle, OutputSettings().charset(String.Encoding.utf8).escapeMode(Entities.EscapeMode.extended))
                    do {
                        try doc.body()?.select("#reader-title").html(escapedTitle)
                    } catch { }
                }
                do {
                    try fixAnnoyingTitlesWithPipes(doc: doc)
                } catch { }
                
                if injectEntryImageIntoHeader, let imageURL = imageURL, let existing = try? doc.select("img[src='\(imageURL.absoluteString)'"), existing.isEmpty() {
                    do {
                        try doc.body()?.select("#reader-header").prepend("<img src='\(imageURL.absoluteString)'>")
                    } catch { }
                }
                if let url = url {
                    transformContentSpecificToFeed(doc: doc, url: url)
                    do {
                        try wireViewOriginalLinks(doc: doc, url: url)
                    } catch { }
                }
                
                if let processReadabilityContent = processReadabilityContent {
                    doc = processReadabilityContent(doc)
                }
                
                #warning("SwiftUIDrag menu")
                
                let docToSet = doc
                Task { @MainActor in
                    do {
                        if let renderToSelector = renderToSelector, let body = docToSet.body() {
                            let transformedContent: String
                            transformedContent = try body.html()
                            await readerViewModel.scriptCaller.evaluateJavaScript(
                                "document.querySelector(${renderToSelector}.innerHTML = ${html}",
                                arguments: ["renderToSelector": renderToSelector, "html": transformedContent])
                            continuation.resume()
                        } else {
                            let transformedContent: String
                            transformedContent = try docToSet.outerHtml()
                            readerViewModel.navigator.loadHTML(transformedContent, baseURL: url)
                            continuation.resume()
                        }
                    } catch {
                        continuation.resume()
                        return
                    }
                }
            }
        })
    }
}
