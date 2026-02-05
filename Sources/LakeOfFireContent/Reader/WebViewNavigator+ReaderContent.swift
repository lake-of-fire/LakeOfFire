import Foundation
import SwiftUIWebView
import LakeOfFireCore

public extension WebViewNavigator {
    /// Injects browser history (unlike loadHTMLWithBaseURL)
    @MainActor
    func load(
        content: any ReaderContentProtocol,
        readerFileManager: ReaderFileManager = ReaderFileManager.shared,
        readerModeViewModel: (any ReaderModeLoadHandling)?
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
                    if trackingURL.isSnippetURL || (loaderBaseURL?.isSnippetURL ?? false) {
                        debugPrint(
                            "# SNIPPETLOAD WebViewNavigator.load",
                            "trackingURL=\(trackingURL.absoluteString)",
                            "loaderURL=\(url.absoluteString)",
                            "hasHandler=\(readerModeViewModel != nil)",
                            "shouldTrigger=\(shouldTriggerReaderMode)"
                        )
                    }
                    if shouldTriggerReaderMode {
                        readerModeViewModel.beginReaderModeLoad(
                            for: trackingURL,
                            suppressSpinner: false,
                            reason: "webViewNavigator.load.prefetch"
                        )
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
