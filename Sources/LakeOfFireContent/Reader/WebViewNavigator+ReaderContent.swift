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
        forceReaderModeForSnippets: Bool = false,
        shouldLoad: @MainActor () -> Bool = { true },
        willDispatchLoad: @MainActor () -> Void = {}
    ) async throws {
        try await loadResolvedContent(
            content: content,
            readerModeViewModel: readerModeViewModel,
            forceReaderModeForSnippets: forceReaderModeForSnippets,
            shouldLoad: shouldLoad,
            willDispatchLoad: willDispatchLoad,
            resolveURL: {
                try await ReaderContentLoader.load(content: content, readerFileManager: readerFileManager)
            },
            resolvePreviousContent: { navigationURL in
                try await ReaderContentLoader.load(
                    url: navigationURL,
                    persist: false,
                    countsAsHistoryVisit: false,
                    source: "WebViewNavigator.load.prefetchPrevious"
                )
            }
        )
    }

    /// The public load and deterministic suspension regressions share this path.
    /// Resolution is injectable; presentation and navigation remain real effects.
    @MainActor
    internal func loadResolvedContent(
        content: any ReaderContentProtocol,
        readerModeViewModel: (any ReaderModeLoadHandling)?,
        forceReaderModeForSnippets: Bool = false,
        shouldLoad: @MainActor () -> Bool = { true },
        willDispatchLoad: @MainActor () -> Void = {},
        resolveURL: @MainActor () async throws -> URL?,
        resolvePreviousContent: @MainActor (URL) async throws -> (any ReaderContentProtocol)?
    ) async throws {
        guard !Task.isCancelled, shouldLoad(), !Task.isCancelled,
              !content.isInvalidated else { return }
        let contentURL = content.url
        var trackingIdentity: (content: any ReaderContentProtocol, url: URL)?
        func isAdmitted() -> Bool {
            guard !Task.isCancelled, shouldLoad(), !Task.isCancelled,
                  !content.isInvalidated, content.url == contentURL else { return false }
            if let trackingIdentity {
                return !trackingIdentity.content.isInvalidated
                    && trackingIdentity.content.url == trackingIdentity.url
            }
            return true
        }
        debugPrint("# FLASH WebViewNavigator.load begin", contentURL)
        let resolvedURL: URL?
        do {
            resolvedURL = try await resolveURL()
        } catch {
            // A retired source cannot publish an error that makes its caller
            // reload the current page as a fallback.
            guard isAdmitted() else { return }
            throw error
        }
        guard isAdmitted() else { return }
        if let url = resolvedURL {
            let navigationURL: URL
            if forceReaderModeForSnippets, contentURL.isSnippetURL {
                navigationURL = ReaderContentLoader.readerLoaderURL(for: contentURL) ?? url
            } else {
                navigationURL = url
            }
            debugPrint("# FLASH WebViewNavigator.load resolved url", navigationURL)
            if let readerModeViewModel {
                let previouslyLoadedContent: (any ReaderContentProtocol)?
                if navigationURL.isEBookURL || navigationURL.isReaderFileURL {
                    previouslyLoadedContent = nil
                } else {
                    do {
                        previouslyLoadedContent = try await resolvePreviousContent(navigationURL)
                    } catch {
                        guard isAdmitted() else { return }
                        throw error
                    }
                    guard isAdmitted() else { return }
                }
                guard isAdmitted() else { return }
                if navigationURL.isHTTP || navigationURL.isFileURL || navigationURL.isSnippetURL || navigationURL.isReaderURLLoaderURL {
                    let trackingContent = (previouslyLoadedContent ?? content)
                    guard !trackingContent.isInvalidated else { return }
                    let trackingContentURL = trackingContent.url
                    trackingIdentity = (trackingContent, trackingContentURL)
                    guard isAdmitted() else { return }
                    let loaderBaseURL = navigationURL.isReaderURLLoaderURL ? ReaderContentLoader.getContentURL(fromLoaderURL: navigationURL) : nil
                    let trackingURL = loaderBaseURL ?? trackingContentURL
                    let shouldTriggerReaderMode =
                        trackingContent.isReaderModeByDefault
                        || loaderBaseURL != nil
                        || (forceReaderModeForSnippets && trackingURL.isSnippetURL)
                    // Mode publication can synchronously retire either row.
                    // Keep diagnostics on values captured before that callback.
                    let trackingHasHTML = trackingContent.hasHTML
                    let trackingRSSContainsFullContent = trackingContent.rssContainsFullContent
                    let trackingCompressedByteCount = trackingContent.content?.count ?? 0
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
                        "hasHTML=\(trackingHasHTML)",
                        "rssFull=\(trackingRSSContainsFullContent)",
                        "compressedBytes=\(trackingCompressedByteCount)",
                        "requestURL=\(navigationURL.absoluteString)"
                    )
                }
            }
            guard isAdmitted() else { return }
            // Consumption belongs to this final accepted dispatch. A caller may
            // retire its receipt here, so do not re-admit the consumed receipt.
            willDispatchLoad()
            load(URLRequest(url: navigationURL))
            debugPrint("# FLASH WebViewNavigator.load request issued", navigationURL)
        } else {
            debugPrint("# FLASH WebViewNavigator.load missing url", contentURL)
            throw ReaderContentNavigationError.unresolvedURL(contentURL)
        }
    }
}
