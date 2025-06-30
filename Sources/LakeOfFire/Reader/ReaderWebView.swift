import SwiftUI
import RealmSwift
import LakeKit
import SwiftUIWebView
import WebKit
import SwiftSoup
import Combine
import RealmSwiftGaps

@MainActor
class NavigationTaskManager: ObservableObject {
    @Published var onNavigationCommittedTask: Task<Void, Error>?
    @Published var onNavigationFinishedTask: Task<Void, Error>?
    @Published var onNavigationFailedTask: Task<Void, Error>?
    @Published var onURLChangedTask: Task<Void, Error>?
    
    func startOnNavigationCommitted(task: @escaping () async throws -> Void) {
        onNavigationCommittedTask?.cancel()
        onNavigationCommittedTask = Task { @MainActor in
            do {
                try await task()
            } catch {
                if !(error is CancellationError) {
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
    
    func startOnNavigationFailed(task: @escaping () async -> Void) {
        onNavigationFailedTask?.cancel()
        onNavigationFailedTask = Task { @MainActor in
            if let failedTask = onNavigationFailedTask {
                _ = try? await failedTask.value
            }
            try Task.checkCancellation()
            await task()
        }
    }
    
    func startOnURLChanged(task: @escaping () async -> Void) {
        Task { @MainActor in
            onURLChangedTask?.cancel()
            _ = try? await onURLChangedTask?.value
            onURLChangedTask = Task { @MainActor in
                try Task.checkCancellation()
                await task()
            }
            _ = try? await onURLChangedTask?.value
            onURLChangedTask = nil
        }
    }
}

fileprivate let blockedHosts = Set([
    "googleads.g.doubleclick.net", "tpc.googlesyndication.com", "pagead2.googlesyndication.com", "www.google-analytics.com", "www.googletagservices.com",
    "adclick.g.doublecklick.net", "media-match.com", "www.omaze.com", "omaze.com", "pubads.g.doubleclick.net", "googlehosted.l.googleusercontent.com",
    "pagead46.l.doubleclick.net", "pagead.l.doubleclick.net", "video-ad-stats.googlesyndication.com", "pagead-googlehosted.l.google.com",
    "partnerad.l.doubleclick.net", "adserver.adtechus.com", "na.gmtdmp.com", "anycast.pixel.adsafeprotected.com", "d361oi6ppvq2ym.cloudfront.net",
    "track.gawker.com", "domains.googlesyndication.com", "partner.googleadservices.com", "ads2.opensubtitles.org", "stats.wordpress.com", "botd.wordpress.com",
    "adservice.google.ca", "adservice.google.com", "adservice.google.jp",
])

public struct ReaderWebView: View {
    var persistentWebViewID: String? = nil
    let obscuredInsets: EdgeInsets?
    var bounces = true
    let schemeHandlers: [(WKURLSchemeHandler, String)]
    var onNavigationCommitted: ((WebViewState) async throws -> Void)?
    var onNavigationFinished: ((WebViewState) -> Void)?
    var onNavigationFailed: ((WebViewState) -> Void)?
    var onURLChanged: ((WebViewState) async throws -> Void)?
    @Binding var hideNavigationDueToScroll: Bool
    @Binding var textSelection: String?
    var buildMenu: BuildMenuType?
    
    @State private var internalURLSchemeHandler = InternalURLSchemeHandler()
    @State private var ebookURLSchemeHandler = EbookURLSchemeHandler()
    @State private var readerFileURLSchemeHandler = ReaderFileURLSchemeHandler()
    
    @EnvironmentObject internal var readerContent: ReaderContent
    @EnvironmentObject internal var scriptCaller: WebViewScriptCaller
    @EnvironmentObject internal var readerViewModel: ReaderViewModel
    @EnvironmentObject internal var readerModeViewModel: ReaderModeViewModel
    @EnvironmentObject internal var readerMediaPlayerViewModel: ReaderMediaPlayerViewModel
    @Environment(\.webViewNavigator) internal var navigator: WebViewNavigator
    
    @StateObject private var navigationTaskManager = NavigationTaskManager()
    
    private var navigationTitle: String? {
        guard let content = readerContent.content else { return nil }
        guard !content.isInvalidated else { return nil }
        return content.titleForDisplay
    }
    

    public init(
        persistentWebViewID: String? = nil,
        obscuredInsets: EdgeInsets?,
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
        self.obscuredInsets = obscuredInsets
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
        WebView(
            config: WebViewConfig(
//                contentRules: readerModeViewModel.contentRules,
                dataDetectorsEnabled: false, // TODO: Bugs out with Manabi Reader callbacks...
                userScripts: readerViewModel.allScripts),
            navigator: navigator,
            state: $readerViewModel.state,
            scriptCaller: scriptCaller,
            blockedHosts: blockedHosts,
            obscuredInsets: totalObscuredInsets(),
            bounces: bounces,
            persistentWebViewID: persistentWebViewID,
            schemeHandlers: [
                (internalURLSchemeHandler, "internal"),
                (readerFileURLSchemeHandler, "reader-file"),
                (ebookURLSchemeHandler, "ebook"),
            ] + schemeHandlers,
            onNavigationCommitted: { state in
                onNavigationCommitted(state: state)
            },
            onNavigationFinished: { state in
                onNavigationFinished(state: state)
            },
            onNavigationFailed: { state in
                onNavigationFailed(state: state)
            },
            onURLChanged: { state in
                onURLChanged(state: state)
            },
            //                textSelection: $textSelection,
            buildMenu: { builder in
                buildMenu?(builder)
            },
            hideNavigationDueToScroll: $hideNavigationDueToScroll
        )
        .task { @MainActor in
            ebookURLSchemeHandler.ebookTextProcessorCacheHits = readerModeViewModel.ebookTextProcessorCacheHits
            ebookURLSchemeHandler.ebookTextProcessor = ebookTextProcessor
            ebookURLSchemeHandler.processReadabilityContent = readerModeViewModel.processReadabilityContent
            ebookURLSchemeHandler.processHTML = readerModeViewModel.processHTML
        }
        .readerFileManagerSetup { readerFileManager in
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
                try await handleNewURL(state: state)
                try await onNavigationCommitted?(state)
            } catch {
                if error is CancellationError {
                    print("onNavigationCommitted task was cancelled.")
                } else {
                    print("Error during onNavigationCommitted: \(error)")
                }
            }
        }
    }
    
    private func onNavigationFinished(state: WebViewState) {
        navigationTaskManager.startOnNavigationFinished { @MainActor in
            readerModeViewModel.onNavigationFinished()
            guard let content = readerContent.content else { return }
            readerViewModel.onNavigationFinished(content: content, newState: state) { newState in
                onNavigationFinished?(newState)
            }
        }
    }
    
    private func onNavigationFailed(state: WebViewState) {
        navigationTaskManager.startOnNavigationFailed { @MainActor in
            readerModeViewModel.onNavigationFailed(newState: state)
            onNavigationFailed?(state)
        }
    }
    
    private func onURLChanged(state: WebViewState) {
        navigationTaskManager.startOnURLChanged { @MainActor in
            do {
                try await handleNewURL(state: state)
                try await onURLChanged?(state)
            } catch {
                if Task.isCancelled {
                    print("onURLChanged task was cancelled.")
                } else {
                    print("Error during onURLChanged: \(error)")
                }
            }
        }
    }
    
    private func handleNewURL(state: WebViewState) async throws {
        try Task.checkCancellation()
        try await readerContent.load(url: state.pageURL)
        try Task.checkCancellation()
        guard let content = readerContent.content else {
            return
        }
        // TODO: Add onURLChanged or rename these view model methods to be more generic...
        try await readerViewModel.onNavigationCommitted(content: content, newState: state)
        try Task.checkCancellation()
        try await readerModeViewModel.onNavigationCommitted(
            readerContent: readerContent,
            newState: state,
            scriptCaller: scriptCaller
        )
        try Task.checkCancellation()
        guard let content = readerContent.content, content.url.matchesReaderURL(state.pageURL) else { return }
        try await readerMediaPlayerViewModel.onNavigationCommitted(content: content, newState: state)
        try Task.checkCancellation()
    }
}
