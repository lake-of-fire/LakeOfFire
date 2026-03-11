import Foundation
import SwiftUIWebView
import LakeOfFireCore

private enum ReaderContentNavigationError: LocalizedError {
    case unresolvedURL(URL)

    var errorDescription: String? {
        switch self {
        case .unresolvedURL(let url):
            return "Reader content could not resolve a navigable URL for \(url.absoluteString)"
        }
    }
}

public extension WebViewNavigator {
    /// Injects browser history (unlike loadHTMLWithBaseURL)
    @MainActor
    func load(
        content: any ReaderContentProtocol,
        readerFileManager: ReaderFileManager = ReaderFileManager.shared,
        readerModeViewModel: (any ReaderModeLoadHandling)?,
        forceReaderModeForSnippets: Bool = false
    ) async throws {
        debugPrint("# FLASH WebViewNavigator.load begin", content.url)
        if let url = try await ReaderContentLoader.load(content: content, readerFileManager: readerFileManager) {
            let navigationURL: URL
            if forceReaderModeForSnippets, content.url.isSnippetURL {
                navigationURL = ReaderContentLoader.readerLoaderURL(for: content.url) ?? url
            } else {
                navigationURL = url
            }
            debugPrint("# FLASH WebViewNavigator.load resolved url", navigationURL)
            if let readerModeViewModel {
                let previouslyLoadedContent = try await ReaderContentLoader.load(url: navigationURL, persist: false, countsAsHistoryVisit: false)
                if navigationURL.isHTTP || navigationURL.isFileURL || navigationURL.isSnippetURL || navigationURL.isReaderURLLoaderURL {
                    let trackingContent = (previouslyLoadedContent ?? content)
                    let loaderBaseURL = navigationURL.isReaderURLLoaderURL ? ReaderContentLoader.getContentURL(fromLoaderURL: navigationURL) : nil
                    let trackingURL = loaderBaseURL ?? trackingContent.url
                    let shouldTriggerReaderMode =
                        trackingContent.isReaderModeByDefault
                        || loaderBaseURL != nil
                        || (forceReaderModeForSnippets && trackingURL.isSnippetURL)
                    if trackingURL.isSnippetURL || (loaderBaseURL?.isSnippetURL ?? false) {
                        debugPrint(
                            "# SNIPPETLOAD WebViewNavigator.load",
                            "trackingURL=\(trackingURL.absoluteString)",
                            "loaderURL=\(navigationURL.absoluteString)",
                            "hasHandler=\(readerModeViewModel != nil)",
                            "shouldTrigger=\(shouldTriggerReaderMode)",
                            "forceReaderModeForSnippets=\(forceReaderModeForSnippets)"
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
                        "requestURL=\(navigationURL.absoluteString)"
                    )
                }
            }
            load(URLRequest(url: navigationURL))
            debugPrint("# FLASH WebViewNavigator.load request issued", navigationURL)
        } else {
            debugPrint("# FLASH WebViewNavigator.load missing url", content.url)
            throw ReaderContentNavigationError.unresolvedURL(content.url)
        }
    }
}
