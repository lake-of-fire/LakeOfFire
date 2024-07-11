import SwiftUI
import SwiftUIWebView
import RealmSwift
import RealmSwiftGaps

internal extension Reader {
    func readerMessageHandlers() -> [String: (WebViewMessage) async -> Void] {
        return [
            "readabilityFramePing": { @MainActor message in
                guard let uuid = (message.body as? [String: String])?["uuid"], let windowURLRaw = (message.body as? [String: String])?["windowURL"] as? String, let windowURL = URL(string: windowURLRaw) else { return }
                guard !windowURL.isNativeReaderView, let content = try? await ReaderViewModel.getContent(forURL: windowURL) else { return }
                if readerViewModel.scriptCaller.addMultiTargetFrame(message.frameInfo, uuid: uuid) {
                    readerViewModel.refreshSettingsInWebView(content: content)
                }
            },
            "readabilityParsed": { message in
                guard let result = ReadabilityParsedMessage(fromMessage: message) else {
                    return
                }
                guard let url = result.windowURL, url == readerViewModel.state.pageURL, let content = try? await ReaderViewModel.getContent(forURL: url) else { return }
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
                } else if result.outputHTML.lazy.filter({ String($0).hasKanji || String($0).hasKana }).prefix(51).count > 50 {
                    await readerViewModel.scriptCaller.evaluateJavaScript("document.body?.classList.add('manabi-reader-mode-available-confidently')")
                }
                
                if !content.isReaderModeAvailable {
                    try? await content.asyncWrite { _, content in
                        content.isReaderModeAvailable = true
                    }
                }
            },
            "showReaderView": { _ in
                Task { @MainActor in readerViewModel.showReaderView(content: readerContent.content) }
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
            "videoStatus": { message in
                Task { @RealmBackgroundActor in
                    guard let result = VideoStatusMessage(fromMessage: message) else { return }
                    debugPrint("!!", result)
                    if let pageURL = result.pageURL {
                        let mediaStatus = try await MediaStatus.getOrCreate(url: pageURL)
                    }
                }
            }
        ].merging(messageHandlers) { (current, new) in
            return { message in
                await current(message)
                await new(message)
            }
        }
    }
}

fileprivate extension Reader {
    // MARK: Readability
    
    @MainActor
    func showOriginal() async throws {
        try await readerContent.content.asyncWrite { _, content in
            content.isReaderModeByDefault = false
        }
        navigator.reload()
    }
}
