import SwiftUI
import SwiftUIWebView
import RealmSwift
import RealmSwiftGaps

internal struct ReaderMessageHandlersViewModifier: ViewModifier {
    var forceReaderModeWhenAvailable = false
    
    @EnvironmentObject internal var scriptCaller: WebViewScriptCaller
    @EnvironmentObject internal var readerViewModel: ReaderViewModel
    @EnvironmentObject internal var readerModeViewModel: ReaderModeViewModel
    @EnvironmentObject internal var readerContent: ReaderContent
    @Environment(\.webViewNavigator) internal var navigator: WebViewNavigator
    @Environment(\.webViewMessageHandlers) private var webViewMessageHandlers
    
    func body(content: Content) -> some View {
        content
            .environment(\.webViewMessageHandlers, webViewMessageHandlers.merging(readerMessageHandlers()) { (current, new) in
                return { message in
                    await current(message)
                    await new(message)
                }
            })
    }
}

internal extension ReaderMessageHandlersViewModifier {
    func readerMessageHandlers() -> [String: (WebViewMessage) async -> Void] {
        return [
            "readabilityFramePing": { @MainActor message in
                guard let uuid = (message.body as? [String: String])?["uuid"], let windowURLRaw = (message.body as? [String: String])?["windowURL"] as? String, let windowURL = URL(string: windowURLRaw) else {
                    debugPrint("Unexpectedly received readableFramePing message without valid parameters", message.body as? [String: String])
                    return
                }
                guard !windowURL.isNativeReaderView, let content = try? await ReaderViewModel.getContent(forURL: windowURL) else { return }
                if readerViewModel.scriptCaller.addMultiTargetFrame(message.frameInfo, uuid: uuid) {
                    readerViewModel.refreshSettingsInWebView(content: content)
                }
            },
            "readabilityModeUnavailable": { @MainActor message in
                guard let result = ReaderModeUnavailableMessage(fromMessage: message) else {
                    return
                }
                // TODO: Reuse guard code across this and readabilityParsed
                guard let url = result.windowURL, url == readerViewModel.state.pageURL, let content = try? await ReaderViewModel.getContent(forURL: url) else {
                    return
                }
                if !message.frameInfo.isMainFrame, readerModeViewModel.readabilityContent != nil, readerModeViewModel.readabilityContainerFrameInfo != message.frameInfo {
                    // Don't override a parent window readability result.
                    return
                }
                if readerModeViewModel.isReaderMode && !url.isReaderURLLoaderURL {
                    readerModeViewModel.isReaderMode = false
                }
            },
            "readabilityParsed": { @MainActor message in
                guard let result = ReadabilityParsedMessage(fromMessage: message) else {
                    return
                }
                guard let url = result.windowURL, url == readerViewModel.state.pageURL, let content = try? await ReaderViewModel.getContent(forURL: url) else {
                    return
                }
                if !message.frameInfo.isMainFrame, readerModeViewModel.readabilityContent != nil, readerModeViewModel.readabilityContainerFrameInfo != message.frameInfo {
                    // Don't override a parent window readability result.
                    return
                }
                guard !result.outputHTML.isEmpty else {
                    try? await content.asyncWrite { _, content in
                        content.isReaderModeAvailable = false
                        content.modifiedAt = Date()
                    }
                    return
                }
                
                guard !url.isNativeReaderView else { return }
                readerModeViewModel.readabilityContent = result.outputHTML
                readerModeViewModel.readabilityContainerSelector = result.readabilityContainerSelector
                readerModeViewModel.readabilityContainerFrameInfo = message.frameInfo
                if content.isReaderModeByDefault || forceReaderModeWhenAvailable {
                    readerModeViewModel.showReaderView(
                        readerContent: readerContent,
                        scriptCaller: scriptCaller
                    )
                } else if result.outputHTML.lazy.filter({ String($0).hasKanji || String($0).hasKana }).prefix(51).count > 50 {
                    await scriptCaller.evaluateJavaScript("""
                        if (document.body) {
                            document.body.dataset.manabiReaderModeAvailableConfidently = 'true';
                            document.body.dataset.isNextLoadInReaderMode = 'false';
                        }
                        """)
                } else {
                    await scriptCaller.evaluateJavaScript("""
                        if (document.body) {
                            document.body.dataset.isNextLoadInReaderMode = 'false';
                        }
                        """)
                }
                
                if !content.isReaderModeAvailable {
                    try? await content.asyncWrite { _, content in
                        content.isReaderModeAvailable = true
                        content.modifiedAt = Date()
                    }
                }
            },
            "showReaderView": { @MainActor _ in
//                let contentURL = readerContent.pageURL
//                Task { @MainActor in
                    guard readerContent.pageURL == readerViewModel.state.pageURL else {
                        print("ERROR: showReaderView called with mismatched content URL (\(readerContent.content?.url.absoluteString) vs \(readerViewModel.state.pageURL.absoluteString)")
                        return
                    }
//                    guard readerContent.pageURL == contentURL else { return }
                readerModeViewModel.showReaderView(
                    readerContent: readerContent,
                    scriptCaller: scriptCaller
                )
//                }
            },
            "showOriginal": { @MainActor _ in
                Task { @MainActor in
                    try await showOriginal()
                }
            },
//            "youtubeCaptions": { message in
//                Task { @MainActor in
//                    guard let result = YoutubeCaptionsMessage(fromMessage: message) else { return }
//                    debugPrint(result)
//                }
//            },
            "rssURLs": { @MainActor message in
                Task { @MainActor in
                    guard let result = RSSURLsMessage(fromMessage: message) else { return }
                    guard let windowURL = result.windowURL, !windowURL.isNativeReaderView, let content = try await ReaderViewModel.getContent(forURL: windowURL) else { return }
                    let pairs = result.rssURLs.prefix(10)
                    let urls = pairs.compactMap { $0.first }.compactMap { URL(string: $0) }
                    let titles = pairs.map { $0.last ?? $0.first ?? "" }
                    try await content.asyncWrite { _, content in
                        content.rssURLs.removeAll()
                        content.rssTitles.removeAll()
                        content.rssURLs.append(objectsIn: urls)
                        content.rssTitles.append(objectsIn: titles)
                        content.isRSSAvailable = !content.rssURLs.isEmpty
                        content.modifiedAt = Date()
                    }
                }
            },
            "pageMetadataUpdated": { @MainActor message in
                Task { @MainActor in
                    guard let result = PageMetadataUpdatedMessage(fromMessage: message) else { return }
                    guard result.url == readerViewModel.state.pageURL else { return }
                    try await readerViewModel.pageMetadataUpdated(title: result.title, author: result.author)
                }
            },
            "imageUpdated": { @MainActor message in
                Task(priority: .utility) { @RealmBackgroundActor in
                    guard let result = ImageUpdatedMessage(fromMessage: message) else { return }
                    guard let url = result.mainDocumentURL, !url.isNativeReaderView else { return }
                    let contents = try await ReaderContentLoader.loadAll(url: url)
                    for content in contents {
                        guard content.imageUrl != result.newImageURL else { continue }
                        await content.realm?.asyncRefresh()
                        try await content.realm?.asyncWrite {
                            content.imageUrl = result.newImageURL
                            content.modifiedAt = Date()
                        }
                    }
                }
            },
            "ebookViewerInitialized": { @MainActor message in
                let url = readerViewModel.state.pageURL
                if let scheme = url.scheme, scheme == "ebook" || scheme == "ebook-url", url.absoluteString.hasPrefix("\(url.scheme ?? "")://"), url.isEBookURL, let loaderURL = URL(string: "\(scheme)://\(url.absoluteString.dropFirst("\(url.scheme ?? "")://".count))") {
                    Task { @MainActor in
                        await scriptCaller.evaluateJavaScript("window.loadEBook({ url })", arguments: ["url": loaderURL.absoluteString])
                    }
                }
            },
            "videoStatus": { @MainActor message in
                Task(priority: .utility) { @RealmBackgroundActor in
                    guard let result = VideoStatusMessage(fromMessage: message) else { return }
                    debugPrint("!!", result)
                    if let pageURL = result.pageURL {
                        let mediaStatus = try await MediaStatus.getOrCreate(url: pageURL)
                    }
                }
            }
        ]
    }
}

fileprivate extension ReaderMessageHandlersViewModifier {
    // MARK: Readability
    
    @MainActor
    func showOriginal() async throws {
        if readerContent.content?.isReaderModeByDefault ?? false {
            try await readerContent.content?.asyncWrite { _, content in
                content.isReaderModeByDefault = false
                content.modifiedAt = Date()
            }
        }
        navigator.reload()
    }
}
