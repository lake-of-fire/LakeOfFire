import SwiftUI
import SwiftUIWebView
import SwiftSoup
import RealmSwift
import Combine
import RealmSwiftGaps
import LakeKit
import WebKit

@globalActor
fileprivate actor ReaderViewModelActor {
    static var shared = ReaderViewModelActor()
}

private let readerPerfStacksEnabled = false

@MainActor
public class ReaderModeViewModel: ObservableObject {
    public var readerFileManager: ReaderFileManager?
    public var ebookTextProcessorCacheHits: ((URL, String?) async throws -> Bool)?
    public var processReadabilityContent: ((String, URL, URL?, Bool, ((SwiftSoup.Document) async -> SwiftSoup.Document)) async -> SwiftSoup.Document)?
    public var processHTML: ((String, Bool) async -> String)?
    public var navigator: WebViewNavigator?
    public var defaultFontSize: Double?
    public var readerModeLoadCompletionHandler: ((URL) -> Void)?
    public var sharedFontCSSBase64: String?
    public var sharedFontCSSBase64Provider: (() async -> String?)?
    private var lastFallbackLoaderURL: URL?
    private var lastRenderedReadabilityURL: URL?
    public private(set) var expectedSyntheticReaderLoaderURL: URL?
    public private(set) var pendingReaderModeURL: URL?
    private var loadTraceRecords: [String: ReaderModeLoadTraceRecord] = [:]
    private var loadStartTimes: [String: Date] = [:]

    @Published public var isReaderMode = false
    @Published public var isReaderModeLoading = false
    @Published var readabilityContent: String?
    @Published var readabilityContainerSelector: String?
    @Published var readabilityContainerFrameInfo: WKFrameInfo? {
        didSet {
            let oldURL = oldValue?.request.url?.absoluteString ?? "<nil>"
            let newURL = readabilityContainerFrameInfo?.request.url?.absoluteString ?? "<nil>"
            let newIsMain = readabilityContainerFrameInfo?.isMainFrame ?? false
            debugPrint("# READER readability.frameInfo.set",
                       "old=\(oldURL)",
                       "new=\(newURL)",
                       "isMain=\(newIsMain)")
        }
    }
    @Published var readabilityFrames = Set<WKFrameInfo>()
    var readabilityPublishedTime: String?

    //    @Published var contentRules: String? = nil

    @AppStorage("lightModeTheme") private var lightModeTheme: LightModeTheme = .white
    @AppStorage("darkModeTheme") private var darkModeTheme: DarkModeTheme = .black

    private struct ReaderModeLoadTraceRecord {
        var startedAt: Date
        var lastEventAt: Date
    }

    private enum ReaderModeLoadStage: String {
        case begin
        case navCommitted
        case htmlFetchStart
        case htmlFetchEnd
        case readabilityContentReady
        case readabilityTaskScheduled
        case contentWriteStart
        case contentWriteEnd
        case readabilityProcessingStart
        case readabilityProcessingFinish
        case processForReaderModeStart
        case processForReaderModeFinish
        case navigatorLoad
        case fallbackLoad
        case cancel
        case complete
        case navFinished

        var isTerminal: Bool {
            switch self {
            case .complete, .cancel:
                return true
            default:
                return false
            }
        }
    }

    fileprivate static let readerHeaderDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        let template = DateFormatter.dateFormat(
            fromTemplate: "MMM d, yyyy",
            options: 0,
            locale: formatter.locale
        ) ?? "MMM d, yyyy"
        formatter.dateFormat = template
        formatter.timeStyle = .none
        return formatter
    }()

    private func formattedInterval(_ interval: TimeInterval) -> String {
        String(format: "%.3fs", interval)
    }

    private func logPerfStack(_ label: String, url: URL?) {
        guard readerPerfStacksEnabled else { return }
        let stack = Thread.callStackSymbols.prefix(6).joined(separator: " | ")
        debugPrint(
            "# READERPERF stack",
            "label=\(label)",
            "url=\(url?.absoluteString ?? "nil")",
            "stack=\(stack)"
        )
    }

    private func expectSyntheticReaderLoaderCommit(for baseURL: URL?) {
        guard let baseURL else {
            expectedSyntheticReaderLoaderURL = nil
            return
        }
        expectedSyntheticReaderLoaderURL = baseURL
        let stack = Thread.callStackSymbols.prefix(6).joined(separator: " | ")
        debugPrint(
            "# READERPERF readerMode.expectedLoader.set",
            "ts=\(Date().timeIntervalSince1970)",
            "expected=\(baseURL.absoluteString)",
            "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")",
            "isLoading=\(isReaderModeLoading)",
            "stack=\(stack)"
        )
    }

    @discardableResult
    private func consumeSyntheticReaderLoaderExpectationIfNeeded(for url: URL) -> Bool {
        guard let expectedSyntheticReaderLoaderURL else { return false }
        let stack = Thread.callStackSymbols.prefix(6).joined(separator: " | ")

        func matchesLoaderURL(_ lhs: URL, _ rhs: URL) -> Bool {
            if lhs.matchesReaderURL(rhs) || rhs.matchesReaderURL(lhs) {
                return true
            }
            return urlsMatchWithoutHash(lhs, rhs)
        }

        if matchesLoaderURL(expectedSyntheticReaderLoaderURL, url) {
            self.expectedSyntheticReaderLoaderURL = nil
            debugPrint(
                "# READERPERF readerMode.expectedLoader.consume",
                "ts=\(Date().timeIntervalSince1970)",
                "url=\(url.absoluteString)",
                "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")",
                "isLoading=\(isReaderModeLoading)",
                "stack=\(stack)"
            )
            return true
        }

        return false
    }

    private func traceKey(for url: URL) -> String {
        url.absoluteString
    }

    private func updatePendingReaderModeURL(_ newValue: URL?, reason: String) {
        let oldValue = pendingReaderModeURL
        let oldDescription = oldValue?.absoluteString ?? "nil"
        let newDescription = newValue?.absoluteString ?? "nil"
        let changeDescription: String
        if urlsMatchWithoutHash(oldValue, newValue) {
            changeDescription = "unchanged"
        } else {
            changeDescription = "updated"
        }
        debugPrint(
            "# READER readerMode.pendingUpdate",
            "from=\(oldDescription)",
            "to=\(newDescription)",
            "change=\(changeDescription)",
            "reason=\(reason)",
            "ts=\(Date().timeIntervalSince1970)",
            "isLoading=\(isReaderModeLoading)",
            "lastRendered=\(lastRenderedReadabilityURL?.absoluteString ?? "nil")",
            "expectedLoader=\(expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")",
            "stack=\(Thread.callStackSymbols.prefix(5).joined(separator: " | "))"
        )
        pendingReaderModeURL = newValue
    }

    private func logStateSnapshot(_ label: String, url: URL?) {
        debugPrint(
            "# READERPERF state.snapshot",
            "label=\(label)",
            "url=\(url?.absoluteString ?? "nil")",
            "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")",
            "expectedLoader=\(expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")",
            "isReaderModeLoading=\(isReaderModeLoading)",
            "isReaderMode=\(isReaderMode)",
            "lastRendered=\(lastRenderedReadabilityURL?.absoluteString ?? "nil")",
            "lastFallback=\(lastFallbackLoaderURL?.absoluteString ?? "nil")"
        )
    }

    private func urlMatchesLastRendered(_ url: URL) -> Bool {
        guard let lastRenderedReadabilityURL else { return false }

        if lastRenderedReadabilityURL.matchesReaderURL(url) || urlsMatchWithoutHash(lastRenderedReadabilityURL, url) {
            return true
        }

        if let loader = ReaderContentLoader.readerLoaderURL(for: lastRenderedReadabilityURL) {
            if loader.matchesReaderURL(url) || urlsMatchWithoutHash(loader, url) {
                return true
            }
        }

        if let resolved = ReaderContentLoader.getContentURL(fromLoaderURL: url) {
            if lastRenderedReadabilityURL.matchesReaderURL(resolved) || urlsMatchWithoutHash(lastRenderedReadabilityURL, resolved) {
                return true
            }
        }

        return false
    }

    private func logTrace(
        _ stage: ReaderModeLoadStage,
        url: URL?,
        captureStart: Bool = false,
        details: String? = nil
    ) {
        let now = Date()
        guard let url else { return }
        let key = traceKey(for: url)
        var elapsedSinceStart: TimeInterval = 0
        var elapsedSinceLast: TimeInterval?
        if captureStart || loadTraceRecords[key] == nil {
            loadTraceRecords[key] = ReaderModeLoadTraceRecord(startedAt: now, lastEventAt: now)
        } else if var record = loadTraceRecords[key] {
            elapsedSinceStart = now.timeIntervalSince(record.startedAt)
            elapsedSinceLast = now.timeIntervalSince(record.lastEventAt)
            record.lastEventAt = now
            loadTraceRecords[key] = record
        }
        var segments: [String] = [
            "# READER readerMode.trace",
            "stage=\(stage.rawValue)",
            "url=\(url.absoluteString)",
            "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")",
            "elapsed=\(formattedInterval(elapsedSinceStart))"
        ]
        if let elapsedSinceLast {
            segments.append("delta=\(formattedInterval(elapsedSinceLast))")
        }
        if let details, !details.isEmpty {
            segments.append("details=\(details)")
        }
        debugPrint(segments.joined(separator: " "))
        if stage.isTerminal {
            loadTraceRecords.removeValue(forKey: key)
        }
    }

    //    private var contentRulesForReadabilityLoading = """
    //    [\(["image", "style-sheet", "font", "media", "popup", "svg-document", "websocket", "other"].map {
    //        """
    //        {
    //             "trigger": {
    //                 "url-filter": ".*",
    //                 "resource-type": ["\($0)"]
    //             },
    //             "action": {
    //                 "type": "block"
    //             }
    //         }
    //        """
    //    } .joined(separator: ", "))
    //    ]
    //    """

    internal func readerModeLoading(_ isLoading: Bool) {
        if isLoading && !isReaderModeLoading {
            debugPrint(
                "# READER readerMode.spinner",
                "loading=true",
                "pendingURL=\(pendingReaderModeURL?.absoluteString ?? "nil")"
            )
            debugPrint(
                "# READERPERF readerMode.spinner.set",
                "ts=\(Date().timeIntervalSince1970)",
                "value=true",
                "pendingURL=\(pendingReaderModeURL?.absoluteString ?? "nil")",
                "lastRendered=\(lastRenderedReadabilityURL?.absoluteString ?? "nil")"
            )
            isReaderModeLoading = true
        } else if !isLoading && isReaderModeLoading {
            debugPrint(
                "# READER readerMode.spinner",
                "loading=false",
                "pendingURL=\(pendingReaderModeURL?.absoluteString ?? "nil")"
            )
            debugPrint(
                "# READERPERF readerMode.spinner.set",
                "ts=\(Date().timeIntervalSince1970)",
                "value=false",
                "pendingURL=\(pendingReaderModeURL?.absoluteString ?? "nil")",
                "lastRendered=\(lastRenderedReadabilityURL?.absoluteString ?? "nil")"
            )
            isReaderModeLoading = false
        }
    }

    @MainActor
    public func beginReaderModeLoad(for url: URL, suppressSpinner: Bool = false, reason: String? = nil) {
        let matchesRendered = urlMatchesLastRendered(url)
        let start = Date()

        if let expected = expectedSyntheticReaderLoaderURL, !urlsMatchWithoutHash(expected, url) {
            debugPrint(
                "# READERPERF readerMode.expectedLoader.reset",
                "from=\(expected.absoluteString)",
                "to=nil",
                "reason=beginLoad.newURL",
                "ts=\(Date().timeIntervalSince1970)"
            )
            expectedSyntheticReaderLoaderURL = nil
        }

        let pendingMatches = pendingReaderModeURL?.matchesReaderURL(url) == true
        let alreadyLoadingSame = pendingMatches && isReaderModeLoading
        let isSameAsLastRendered = lastRenderedReadabilityURL?.matchesReaderURL(url) == true

        if alreadyLoadingSame {
            debugPrint(
                "# READERPERF readerMode.beginLoad.skipped",
                "ts=\(start.timeIntervalSince1970)",
                "url=\(url.absoluteString)",
                "reason=alreadyLoadingPending",
                "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")",
                "lastRendered=\(lastRenderedReadabilityURL?.absoluteString ?? "nil")"
            )
            logPerfStack("beginLoad.skipped", url: url)
            return
        }

        if matchesRendered,
           pendingReaderModeURL == nil,
           isReaderMode {
            debugPrint(
                "# READER readerMode.beginLoad.rerenderAlreadyRendered",
                "url=\(url.absoluteString)",
                "lastRendered=\(lastRenderedReadabilityURL?.absoluteString ?? "nil")"
            )
            // Force a fresh render to avoid stale/empty content while still clearing spinners.
            lastRenderedReadabilityURL = nil
        }
        logStateSnapshot("beginLoad.precheck", url: url)
        var isContinuing = false
        if let pendingReaderModeURL, pendingReaderModeURL.matchesReaderURL(url) {
            // already tracking this load
            isContinuing = true
        } else {
            updatePendingReaderModeURL(url, reason: "beginLoad")
            lastRenderedReadabilityURL = nil
            lastFallbackLoaderURL = nil
        }
        let trackedURL = pendingReaderModeURL ?? url
        debugPrint(
            "# READER readerMode.beginLoad",
            "url=\(trackedURL.absoluteString)",
            "continuing=\(isContinuing)",
            "suppressSpinner=\(suppressSpinner)",
            "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")",
            "lastRendered=\(lastRenderedReadabilityURL?.absoluteString ?? "nil")",
            "expectedLoader=\(expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")",
            "isLoading=\(isReaderModeLoading)",
            "reason=\(reason ?? "unspecified")"
        )
        debugPrint(
            "# READERPERF readerMode.beginLoad",
            "ts=\(start.timeIntervalSince1970)",
            "url=\(trackedURL.absoluteString)",
            "continuing=\(isContinuing)",
            "suppressSpinner=\(suppressSpinner)",
            "pendingMatches=\(pendingMatches)",
            "isSameAsLastRendered=\(isSameAsLastRendered)",
            "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")",
            "lastRendered=\(lastRenderedReadabilityURL?.absoluteString ?? "nil")",
            "expectedLoader=\(expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")",
            "isLoading=\(isReaderModeLoading)",
            "reason=\(reason ?? "unspecified")"
        )
        logPerfStack("beginLoad", url: trackedURL)
        logStateSnapshot("beginLoad.postcheck", url: trackedURL)
        logTrace(
            .begin,
            url: trackedURL,
            captureStart: !isContinuing,
            details: isContinuing ? "continuing pending load" : "starting new load"
        )
        if !suppressSpinner {
            readerModeLoading(true)
        }
        loadStartTimes[trackedURL.absoluteString] = start
        debugPrint(
            "# READERPERF readerMode.loadStart",
            "ts=\(start.timeIntervalSince1970)",
            "url=\(trackedURL.absoluteString)"
        )
    }

    @MainActor
    public func cancelReaderModeLoad(for url: URL? = nil) {
        logPerfStack("cancel.invoked", url: url)
        logStateSnapshot("cancel.invoked", url: url)
        guard let pendingReaderModeURL else {
            debugPrint(
                "# READER readerMode.cancel",
                "url=\(url?.absoluteString ?? "nil")",
                "reason=noPending",
                "isLoading=\(isReaderModeLoading)",
                "lastRendered=\(lastRenderedReadabilityURL?.absoluteString ?? "nil")",
                "expectedLoader=\(expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")",
                "readerMode=\(isReaderMode)"
            )
            debugPrint(
                "# READERPERF readerMode.cancel",
                "ts=\(Date().timeIntervalSince1970)",
                "url=\(url?.absoluteString ?? "nil")",
                "pending=nil",
                "reason=noPending",
                "isLoading=\(isReaderModeLoading)",
                "lastRendered=\(lastRenderedReadabilityURL?.absoluteString ?? "nil")",
                "expectedLoader=\(expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")"
            )
            logPerfStack("cancel.noPending", url: url)
            logStateSnapshot("cancel.noPending", url: url)
            logTrace(.cancel, url: url, details: "no pending load to cancel")
            // If a caller asks us to cancel but we no longer have a pending URL,
            // still force the spinner off so the UI cannot get stuck in a loading state.
            readerModeLoading(false)
            debugPrint(
                "# READER readerMode.spinner.forceOff",
                "reason=noPendingCancel",
                "requestedURL=\(url?.absoluteString ?? "nil")"
            )
            if let handler = readerModeLoadCompletionHandler {
                let completedURL = url
                    ?? lastRenderedReadabilityURL
                    ?? lastFallbackLoaderURL
                    ?? URL(string: "about:blank")!
                handler(completedURL)
            }
            return
        }
        if let url, !pendingReaderModeURL.matchesReaderURL(url) {
            let matchesRendered = urlMatchesLastRendered(url)
            debugPrint(
                "# READER readerMode.cancel",
                "url=\(url.absoluteString)",
                "reason=pendingMismatch",
                "pending=\(pendingReaderModeURL.absoluteString)",
                "isReaderModeLoading=\(isReaderModeLoading)",
                "matchesRendered=\(matchesRendered)"
            )
            logStateSnapshot("cancel.pendingMismatch", url: url)
            logTrace(.cancel, url: url, details: "cancel ignored: pending load is for \(pendingReaderModeURL.absoluteString)")
            return
        }
        debugPrint(
            "# READER readerMode.cancel",
            "url=\(pendingReaderModeURL.absoluteString)",
            "reason=requested",
            "caller=\(url?.absoluteString ?? "nil")",
            "isLoading=\(isReaderModeLoading)",
            "lastRendered=\(lastRenderedReadabilityURL?.absoluteString ?? "nil")",
            "expectedLoader=\(expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")"
        )
        let traceURL = pendingReaderModeURL
        logStateSnapshot("cancel.requested", url: traceURL)
        updatePendingReaderModeURL(nil, reason: "cancelReaderModeLoad")
        logTrace(.cancel, url: traceURL, details: "cancelReaderModeLoad invoked")
        readerModeLoading(false)
        if let handler = readerModeLoadCompletionHandler {
            handler(traceURL ?? url ?? URL(string: "about:blank")!)
        }
    }

    @MainActor
    public func markReaderModeLoadComplete(for url: URL) {
        guard let pendingReaderModeURL, pendingReaderModeURL.matchesReaderURL(url) else {
            let pendingDescription = self.pendingReaderModeURL?.absoluteString ?? "nil"
            let readabilityBytes = readabilityContent?.utf8.count ?? 0
            let pendingState = self.pendingReaderModeURL == nil ? "noPending" : "pendingMismatch"
            let matchesRendered = urlMatchesLastRendered(url)
            debugPrint(
                "# READER readerMode.complete.skip",
                "url=\(url.absoluteString)",
                "pending=\(pendingDescription)",
                "pendingState=\(pendingState)",
                "isReaderMode=\(isReaderMode)",
                "isReaderModeLoading=\(isReaderModeLoading)",
                "readabilityBytes=\(readabilityBytes)",
                "lastRendered=\(lastRenderedReadabilityURL?.absoluteString ?? "nil")",
                "lastFallback=\(lastFallbackLoaderURL?.absoluteString ?? "nil")",
                "expectedLoader=\(expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")",
                "matchesRendered=\(matchesRendered)",
                "ts=\(Date().timeIntervalSince1970)"
            )
            logPerfStack("complete.skip", url: url)
            logStateSnapshot("complete.skip", url: url)

            // If the content was already rendered (e.g., we navigated away and back to
            // a reader-file loader URL), we still want to clear spinners even though
            // the pending URL was cleared earlier.
            if matchesRendered {
                readerModeLoading(false)
                readerModeLoadCompletionHandler?(url)
            }
            return
        }
        let readabilityBytes = readabilityContent?.utf8.count ?? 0
        if readabilityBytes == 0 {
            debugPrint(
                "# READERPERF readerMode.complete.deferred",
                "url=\(url.absoluteString)",
                "reason=emptyReadability",
                "pending=\(pendingReaderModeURL.absoluteString)",
                "expectedLoader=\(expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")"
            )
            return
        }
        let traceURL = pendingReaderModeURL
        updatePendingReaderModeURL(nil, reason: "markReaderModeLoadComplete")
        let loadStart = loadStartTimes[traceURL.absoluteString] ?? Date()
        let loadElapsed = Date().timeIntervalSince(loadStart)
        let hasReadableBody = readabilityBytes > 0
        debugPrint(
            "# READER readerMode.complete",
            "url=\(traceURL.absoluteString)"
        )
        debugPrint(
            "# READERPERF readerMode.complete",
            "ts=\(Date().timeIntervalSince1970)",
            "url=\(traceURL.absoluteString)",
            "elapsed=\(formattedInterval(loadElapsed))",
            "readabilityBytes=\(readabilityBytes)",
            "hasReadableBody=\(hasReadableBody)"
        )
        logStateSnapshot("complete.success", url: traceURL)
        logTrace(.complete, url: traceURL, details: "markReaderModeLoadComplete")
        loadStartTimes.removeValue(forKey: traceURL.absoluteString)
        readerModeLoading(false)
        readerModeLoadCompletionHandler?(traceURL)
    }

    @MainActor
    public func isReaderModeLoadPending(for url: URL) -> Bool {
        guard let pendingReaderModeURL else { return false }
        return pendingReaderModeURL.matchesReaderURL(url)
    }

    func isReaderModeHandlingURL(_ url: URL) -> Bool {
        if let pendingReaderModeURL, pendingReaderModeURL.matchesReaderURL(url) {
            return true
        }
        if let lastRenderedReadabilityURL, lastRenderedReadabilityURL.matchesReaderURL(url) {
            return true
        }
        return false
    }

    //    @MainActor
    //    public func invalidateLastRenderedReadabilityURL() {
    //        debugPrint("# FLASH ReaderModeViewModel.invalidateLastRenderedReadabilityURL clearing", lastRenderedReadabilityURL?.absoluteString ?? "nil")
    //        lastRenderedReadabilityURL = nil
    //        lastFallbackLoaderURL = nil
    //    }

    public func isReaderModeButtonAvailable(content: any ReaderContentProtocol) -> Bool {
        return !isReaderMode && content.isReaderModeAvailable && !content.isReaderModeByDefault
    }

    public init() { }

    func isReaderModeLoadPending(content: any ReaderContentProtocol) -> Bool {
        if let pendingReaderModeURL, pendingReaderModeURL.matchesReaderURL(content.url) {
            return true
        }
        return !isReaderMode && content.isReaderModeAvailable && content.isReaderModeByDefault
    }

    @MainActor
    public func showReaderView(readerContent: ReaderContent, scriptCaller: WebViewScriptCaller) {
        debugPrint("# READER readerMode.showReaderView", readerContent.pageURL)
        let readabilityBytes = readabilityContent?.utf8.count ?? 0
        logTrace(.readabilityTaskScheduled, url: readerContent.pageURL, details: "readabilityBytes=\(readabilityBytes)")
        let contentURL = readerContent.pageURL
        guard let readabilityContent else {
            // FIME: WHY THIS CALLED WHEN LOAD??
            debugPrint("# READER readerMode.showReaderView.missingContent", readerContent.pageURL)
            debugPrint("# READER readability.missingContent", "url=\(readerContent.pageURL.absoluteString)")
            cancelReaderModeLoad(for: readerContent.pageURL)
            return
        }
        let readabilityPreview = snippetPreview(readabilityContent, maxLength: 360)
        debugPrint(
            "# READER readability.renderHTML",
            "url=\(contentURL.absoluteString)",
            "bytes=\(readabilityBytes)",
            "preview=\(readabilityPreview)"
        )
        beginReaderModeLoad(
            for: contentURL,
            suppressSpinner: false,
            reason: "showReaderView"
        )
        Task { @MainActor in
            guard urlsMatchWithoutHash(contentURL, readerContent.pageURL) else {
                debugPrint("# READER readerMode.showReaderView.urlMismatch", contentURL, readerContent.pageURL)
                cancelReaderModeLoad(for: contentURL)
                return
            }
            do {
                try await showReadabilityContent(
                    readerContent: readerContent,
                    readabilityContent: readabilityContent,
                    renderToSelector: readabilityContainerSelector,
                    in: readabilityContainerFrameInfo,
                    scriptCaller: scriptCaller
                )
            } catch {
                debugPrint("# READER readerMode.showReaderView.loadFailed", error.localizedDescription)
                print(error)
                cancelReaderModeLoad(for: contentURL)
            }
        }
    }

    /// `readerContent` is used to verify current reader state before loading processed `content`
    @MainActor
    internal func showReadabilityContent(
        readerContent: ReaderContent,
        readabilityContent: String,
        renderToSelector: String?,
        in frameInfo: WKFrameInfo?,
        scriptCaller: WebViewScriptCaller
    ) async throws {
        guard let content = try await readerContent.getContent() else {
            print("No content set to show in reader mode")
            cancelReaderModeLoad(for: readerContent.pageURL)
            return
        }
        let renderStart = Date()
        if let frameInfo {
            debugPrint(
                "# READER readability.targetFrame",
                "frameURL=\(frameInfo.request.url?.absoluteString ?? "<nil>")",
                "pageURL=\(readerContent.pageURL.absoluteString)"
            )
        } else {
            debugPrint("# READER readability.targetFrame", "frameURL=<nil>", "pageURL=\(readerContent.pageURL.absoluteString)")
        }
        let readabilityPublishedTime = self.readabilityPublishedTime
        self.readabilityPublishedTime = nil
        let headerDateText = makeReaderHeaderDateText(
            readabilityPublishedTime: readabilityPublishedTime,
            content: content
        )
        let url = content.url
        if url.isSnippetURL {
            debugPrint(
                "# READER snippet.renderStart",
                "contentURL=\(url.absoluteString)",
                "readabilityBytes=\(readabilityContent.utf8.count)",
                "frameIsMain=\(frameInfo?.isMainFrame ?? true)",
                "renderSelector=\(renderToSelector ?? "<root>")"
            )
        }
        let renderBaseURL: URL
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            renderBaseURL = url
        } else if let loaderURL = ReaderContentLoader.readerLoaderURL(for: url) {
            renderBaseURL = loaderURL
        } else {
            renderBaseURL = readerContent.pageURL
        }
        debugPrint(
            "# READER readability.renderBase",
            "contentURL=\(url.absoluteString)",
            "renderBase=\(renderBaseURL.absoluteString)",
            "frameIsMain=\(frameInfo?.isMainFrame ?? true)"
        )
        let renderTarget = renderToSelector ?? "<root>"
        logTrace(.readabilityProcessingStart, url: url, details: "renderTo=\(renderTarget) | frameIsMain=\(frameInfo?.isMainFrame ?? true)")

        if let lastRenderedReadabilityURL, lastRenderedReadabilityURL.matchesReaderURL(url) {
            markReaderModeLoadComplete(for: url)
            return
        }

        if lastFallbackLoaderURL != nil {
            self.lastFallbackLoaderURL = nil
        }

        Task {
            do {
                debugPrint("# READER readability.datasetFlag", "url=\(url.absoluteString)")
                try await scriptCaller.evaluateJavaScript("""
                if (document.body) {
                    document.body.dataset.isNextLoadInReaderMode = 'true';
                    try { document.body.style.setProperty('content-visibility', 'hidden'); } catch (_) {}
                }
                """)
            } catch {
                debugPrint("# READER readability.datasetFlag.error", error.localizedDescription)
            }
        }

        let asyncWriteStartedAt = Date()
        logTrace(.contentWriteStart, url: url, details: "marking reader defaults")
        try await content.asyncWrite { [weak self] _, content in
            content.isReaderModeByDefault = true
            content.isReaderModeAvailable = false
            if !url.isEBookURL && !url.isNativeReaderView {
                if content.html?.isEmpty ?? true {
                    if url.isSnippetURL {
                        guard let self else { return }
                        let oldPreview = snippetPreview(content.html ?? "")
                        let newPreview = snippetPreview(readabilityContent)
                        debugPrint(
                            "# READER snippetUpdate.content",
                            "url=\(url.absoluteString)",
                            "oldPreview=\(oldPreview)",
                            "newPreview=\(newPreview)",
                            "newBytes=\(readabilityContent.utf8.count)"
                        )
                    }
                    content.html = readabilityContent
                }
                if content.title.isEmpty {
                    content.title = content.html?.strippingHTML().trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first?.truncate(36) ?? ""
                }
                content.rssContainsFullContent = true
            }
            content.refreshChangeMetadata(explicitlyModified: true)
        }
        let writeElapsed = Date().timeIntervalSince(asyncWriteStartedAt)
        logTrace(.contentWriteEnd, url: url, details: "duration=\(formattedInterval(writeElapsed))")
        debugPrint(
            "# READERPERF readerMode.contentWrite",
            "url=\(url.absoluteString)",
            "elapsed=\(formattedInterval(writeElapsed))"
        )

        let injectEntryImageIntoHeader = content.injectEntryImageIntoHeader
        let titleForDisplay = content.titleForDisplay
        let imageURLToDisplay = try await content.imageURLToDisplay()
        let processReadabilityContent = processReadabilityContent
        let processHTML = processHTML

        await propagateReaderModeDefaults(
            for: url,
            primaryRecord: content,
            readabilityHTML: readabilityContent,
            fallbackTitle: titleForDisplay
        )
        debugPrint(
            "# READERPERF readerMode.propagateDefaults",
            "url=\(url.absoluteString)"
        )

        if !isReaderMode {
            isReaderMode = true
        }

        try await { @ReaderViewModelActor [weak self] in
            let parseStartedAt = Date()
            var doc: SwiftSoup.Document?
            let readabilityBytes = readabilityContent.utf8.count
            let readabilityChars = readabilityContent.count
            let isXML = readabilityContent.hasPrefix("<?xml") || readabilityContent.hasPrefix("<?XML")
            await MainActor.run {
                let pending = self?.pendingReaderModeURL?.absoluteString ?? "nil"
                let expected = self?.expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil"
                let loading = self?.isReaderModeLoading ?? false
                let readerMode = self?.isReaderMode ?? false
                let isInternalShell = url.scheme == "internal"
                debugPrint(
                    "# READERPERF readerMode.readability.input",
                    "ts=\(parseStartedAt.timeIntervalSince1970)",
                    "url=\(url.absoluteString)",
                    "bytes=\(readabilityBytes)",
                    "chars=\(readabilityChars)",
                    "isXML=\(isXML)",
                    "pending=\(pending)",
                    "expectedLoader=\(expected)",
                    "isReaderModeLoading=\(loading)",
                    "isReaderMode=\(readerMode)",
                    "isInternalShell=\(isInternalShell)"
                )
            }

            if let processReadabilityContent {
                doc = await processReadabilityContent(
                    readabilityContent,
                    url,
                    nil,
                    false, { doc in
                        do {
                            return try await preprocessWebContentForReaderMode(
                                doc: doc,
                                url: url,
                                fallbackTitle: titleForDisplay
                            )
                        } catch {
                            print(error)
                            return doc
                        }
                    }
                )
            } else {
                let parser = isXML ? SwiftSoup.Parser.xmlParser() : SwiftSoup.Parser.htmlParser()
                doc = try SwiftSoup.parse(readabilityContent, url.absoluteString, parser)
                doc?.outputSettings().prettyPrint(pretty: false).syntax(syntax: isXML ? .xml : .html)
                doc?.outputSettings().charset(.utf8)
                if isXML {
                    doc?.outputSettings().escapeMode(.xhtml)
                }
            }

            guard let doc else {
                print("Error: Unexpectedly failed to receive doc")
                return
            }
            let parseDuration = Date().timeIntervalSince(parseStartedAt)
            let parseSummary = String(format: "%.3fs", parseDuration)
            try updateBylineSection(
                in: doc,
                publicationDateText: headerDateText
            )
            await MainActor.run {
                self?.logTrace(.readabilityProcessingFinish, url: url, details: "duration=\(parseSummary)")
                debugPrint(
                    "# READERPERF readerMode.pipeline",
                    "stage=parseReadability",
                    "url=\(url.absoluteString)",
                    "elapsed=\(parseSummary)"
                )
            }

            let transformStartedAt = Date()
            await MainActor.run {
                self?.logTrace(.processForReaderModeStart, url: url)
            }
            try await processForReaderMode(
                doc: doc,
                url: url,
                contentSectionLocationIdentifier: nil,
                isEBook: false,
                isCacheWarmer: false,
                defaultTitle: titleForDisplay,
                imageURL: imageURLToDisplay,
                injectEntryImageIntoHeader: injectEntryImageIntoHeader,
                defaultFontSize: defaultFontSize ?? 21
            )
            let transformDuration = Date().timeIntervalSince(transformStartedAt)
            let transformSummary = String(format: "%.3fs", transformDuration)
            await MainActor.run {
                self?.logTrace(.processForReaderModeFinish, url: url, details: "duration=\(transformSummary)")
                debugPrint(
                    "# READERPERF readerMode.pipeline",
                    "stage=processForReaderMode",
                    "url=\(url.absoluteString)",
                    "elapsed=\(transformSummary)"
                )
            }

            var html = try doc.outerHtml()

            if let processHTML {
                debugPrint("# READER readability.processHTML", url)
                html = await processHTML(
                    html,
                    false
                )
            }

            let transformedContent = html
            debugPrint(
                "# READER readability.contentPrepared",
                "url=\(url.absoluteString)",
                "bytes=\(transformedContent.utf8.count)",
                "frameIsMain=\(frameInfo?.isMainFrame ?? true)"
            )
            if let bodySummary = summarizeBodyMarkup(from: transformedContent) {
                debugPrint(
                    "# READER readability.renderBody",
                    "url=\(url.absoluteString)",
                    "body=\(bodySummary)"
                )
            }
            try await { @MainActor in
                guard url.matchesReaderURL(readerContent.pageURL) else {
                    debugPrint("# READER readability.readerURLMismatch", url, readerContent.pageURL)
                    print("Readability content URL mismatch", url, readerContent.pageURL)
                    cancelReaderModeLoad(for: url)
                    return
                }
                if let frameInfo = frameInfo, !frameInfo.isMainFrame {
                    debugPrint("# READER readability.frameInjection", frameInfo)
                    try await scriptCaller.evaluateJavaScript(
                        """
                        var root = document.body
                        if (renderToSelector) {
                            root = document.querySelector(renderToSelector)
                        }
                        var serialized = html

                        let xmlns = document.body?.getAttribute('xmlns')
                        if (xmlns) {
                            let parser = new DOMParser()
                            let doc = parser.parseFromString(serialized, 'text/html')
                            let readabilityNode = doc.body
                            let replacementNode = root.cloneNode()
                            replacementNode.innerHTML = ''
                            for (let innerNode of readabilityNode.childNodes) {
                                serialized = new XMLSerializer().serializeToString(innerNode)
                                replacementNode.innerHTML += serialized
                            }
                            root.innerHTML = replacementNode.innerHTML
                        } else if (root) {
                            root.outerHTML = serialized
                        }
                        try {
                            const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.print
                            if (handler) {
                                handler.postMessage({
                                    message: "# READER snippetLoader.injected",
                                    context: "frame",
                                    targetSelector: renderToSelector || "<root>",
                                    htmlBytes: insertBytes,
                                    windowURL: window.location.href,
                                    pageURL: document.location.href
                                })
                            }
                        } catch (error) {
                            try { console.log("snippetLoader.injected log error", error) } catch (_) {}
                        }

                        let style = document.createElement('style')
                        style.textContent = css
                        document.head.appendChild(style)
                        document.body?.classList.add('readability-mode')
                        """
                        ,
                        arguments: [
                            "renderToSelector": renderToSelector ?? "",
                            "html": transformedContent,
                            "insertBytes": transformedContent.utf8.count,
                            "css": Readability.shared.css
                        ], in: frameInfo)
                    logTrace(.navigatorLoad, url: url, details: "mode=frame-injection")
                    markReaderModeLoadComplete(for: url)
                } else if let htmlData = transformedContent.data(using: .utf8) {
                    guard let navigator else {
                        print("ReaderModeViewModel: navigator missing while loading readability content for", url.absoluteString)
                        cancelReaderModeLoad(for: url)
                        return
                    }
                    let transformedBytes = transformedContent.utf8.count
                    let transformedPreview = snippetPreview(transformedContent, maxLength: 240)
                    debugPrint(
                        "# READER readability.navigatorLoad",
                        "url=\(url.absoluteString)",
                        "base=\(renderBaseURL.absoluteString)",
                        "bytes=\(transformedBytes)"
                    )
                    debugPrint(
                        "# READER readability.navigatorLoad.preview",
                        "url=\(url.absoluteString)",
                        "bytes=\(transformedBytes)",
                        "preview=\(transformedPreview)"
                    )
                    logTrace(.navigatorLoad, url: url, details: "mode=readability-html | bytes=\(transformedBytes)")
                    expectSyntheticReaderLoaderCommit(for: renderBaseURL)
                    let loadDispatch = Date()
                    navigator.load(
                        htmlData,
                        mimeType: "text/html",
                        characterEncodingName: "UTF-8",
                        baseURL: renderBaseURL
                    )
                    debugPrint(
                        "# READER readability.navigatorLoad.dispatched",
                        "url=\(url.absoluteString)",
                        "base=\(renderBaseURL.absoluteString)",
                        "bytes=\(transformedBytes)",
                        "elapsed=\(String(format: "%.3f", Date().timeIntervalSince(loadDispatch)))s"
                    )
                    debugPrint(
                        "# READERPERF readerMode.navigatorLoad.readability",
                        "ts=\(Date().timeIntervalSince1970)",
                        "url=\(url.absoluteString)",
                        "base=\(renderBaseURL.absoluteString)",
                        "bytes=\(transformedBytes)"
                    )
                    if url.isSnippetURL {
                        let preview = snippetPreview(transformedContent, maxLength: 240) ?? "<empty>"
                        debugPrint(
                            "# READER snippetLoader.navigatorLoad",
                            "contentURL=\(url.absoluteString)",
                            "base=\(renderBaseURL.absoluteString)",
                            "bytes=\(transformedContent.utf8.count)",
                            "preview=\(preview)"
                        )
                        injectSnippetLoaderProbe(scriptCaller: scriptCaller, baseURL: renderBaseURL)
                    }
                } else {
                    print("ReaderModeViewModel: readability HTML data missing for", url.absoluteString)
                    debugPrint("# READER readability.navigatorLoad missingData", "url=\(url.absoluteString)")
                    cancelReaderModeLoad(for: url)
                }

                //                try await { @MainActor in
                //                    readerModeLoading(false)
                //                }()
            }()
            try await { @MainActor in
                lastRenderedReadabilityURL = url
                let totalRenderElapsed = Date().timeIntervalSince(renderStart)
                debugPrint(
                    "# READERPERF readerMode.render.total",
                    "ts=\(Date().timeIntervalSince1970)",
                    "url=\(url.absoluteString)",
                    "elapsed=\(String(format: "%.3f", totalRenderElapsed))s"
                )
            }()
        }()
    }

    private nonisolated func summarizeBodyMarkup(from html: String, maxLength: Int = 360) -> String? {
        guard let bodyRange = html.range(of: "<body", options: [.caseInsensitive]) else {
            return nil
        }
        let start = bodyRange.lowerBound
        guard let openTagEnd = html[start...].firstIndex(of: ">") else { return nil }
        let afterOpen = html.index(after: openTagEnd)
        let searchRange = afterOpen..<html.endIndex
        let closingRange = html.range(of: "</body", options: [.caseInsensitive], range: searchRange)
        let end: String.Index
        if let closingRange,
           let closingGT = html[closingRange.lowerBound...].firstIndex(of: ">") {
            end = html.index(after: closingGT)
        } else {
            end = html.endIndex
        }
        var snippet = String(html[start..<end])
        snippet = snippet.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        snippet = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        if snippet.count > maxLength {
            let idx = snippet.index(snippet.startIndex, offsetBy: maxLength)
            snippet = String(snippet[..<idx]) + "…"
        }
        return snippet.isEmpty ? nil : snippet
    }

    private func snippetPreview(_ html: String, maxLength: Int = 360) -> String {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "<empty>" }
        if trimmed.count <= maxLength { return trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: maxLength)
        return String(trimmed[..<idx]) + "…"
    }

    private func logDomSnapshot(
        pageURL: URL,
        scriptCaller: WebViewScriptCaller,
        reason: String
    ) {
        debugPrint("# READER readerMode.domSnapshot", "reason=\(reason)", "pageURL=\(pageURL.absoluteString)", "info=<swift-layer-only>")
    }

    @MainActor
    private func injectSnippetLoaderProbe(
        scriptCaller: WebViewScriptCaller,
        baseURL: URL
    ) {
        Task { @MainActor [weak scriptCaller] in
            guard let scriptCaller else { return }
            do {
                debugPrint("# READER snippetLoader.injectProbe.injecting", "baseURL=\(baseURL.absoluteString)")
                try await scriptCaller.evaluateJavaScript(
                    """
                    (function () {
                        const logState = () => {
                            try {
                                const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.print
                                if (!handler || typeof handler.postMessage !== "function") {
                                    return
                                }
                                const readerContent = document.getElementById("reader-content")
                                const body = document.body
                                const bodyHTMLBytes = body && typeof body.innerHTML === "string" ? body.innerHTML.length : 0
                                const bodyTextBytes = body && typeof body.textContent === "string" ? body.textContent.length : 0
                                const readerContentHTMLBytes = readerContent && typeof readerContent.innerHTML === "string" ? readerContent.innerHTML.length : 0
                                const readerContentTextBytes = readerContent && typeof readerContent.textContent === "string" ? readerContent.textContent.length : 0
                                handler.postMessage({
                                    message: "# READER snippetLoader.injectProbe",
                                    stage: document.readyState,
                                    hasBody: !!body,
                                    bodyHTMLBytes,
                                    bodyTextBytes,
                                    hasReaderContent: !!readerContent,
                                    readerContentHTMLBytes,
                                    readerContentTextBytes,
                                    bodyPreview: body && typeof body.innerHTML === "string" ? body.innerHTML.slice(0, 240) : null,
                                    readerContentPreview: readerContent && typeof readerContent.textContent === "string" ? readerContent.textContent.slice(0, 240) : null,
                                    windowURL: window.location.href,
                                    pageURL: document.location.href
                                })
                            } catch (error) {
                                try { console.log("snippetLoader.injectProbe error", error) } catch (_) {}
                            }
                        }
                        logState()
                        document.addEventListener("readystatechange", logState)
                    })();
                    """
                )
            } catch {
                debugPrint("# READER snippetLoader.injectProbe.error", error.localizedDescription)
            }
        }
    }

    @MainActor
    public func onNavigationCommitted(
        readerContent: ReaderContent,
        newState: WebViewState,
        scriptCaller: WebViewScriptCaller
    ) async throws {
        debugPrint("# READER readerMode.navCommit", "pageURL=\(newState.pageURL.absoluteString)")
        debugPrint(
            "# READERPERF readerMode.navCommit.detail",
            "ts=\(Date().timeIntervalSince1970)",
            "pageURL=\(newState.pageURL.absoluteString)",
            "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")",
            "isReaderMode=\(isReaderMode)",
            "isReaderModeLoading=\(isReaderModeLoading)"
        )
        let pageURL = newState.pageURL
        // Provide a stable book key for JS tracking-size cache
        if !scriptCaller.hasAsyncCaller {
            debugPrint("# READER paginationBookKey.set.skip", "reason=asyncCallerNil", "url=\(pageURL.absoluteString)")
        } else {
            do {
                try await scriptCaller.evaluateJavaScript(
                    "window.paginationTrackingBookKey = '" + pageURL.absoluteString + "';",
                    in: nil,
                    duplicateInMultiTargetFrames: true
                )
                debugPrint("# READER paginationBookKey.set", "key=\(pageURL.absoluteString.prefix(72))…")
            } catch {
                debugPrint("# READER paginationBookKey.set.error", error.localizedDescription)
            }
        }
        // Keep the current frame info during navigation; clear only if it points to a different page to avoid stale invalid frames.
        if let existingFrame = readabilityContainerFrameInfo {
            let canonicalExisting = ReaderContentLoader.getContentURL(fromLoaderURL: existingFrame.request.url ?? existingFrame.request.mainDocumentURL ?? existingFrame.request.url ?? pageURL) ?? (existingFrame.request.url ?? pageURL)
            let canonicalTarget = ReaderContentLoader.getContentURL(fromLoaderURL: pageURL) ?? pageURL
            if !urlsMatchWithoutHash(canonicalExisting, canonicalTarget) {
                debugPrint("# READER readability.frameInfo.clear", "reason=navCommitMismatch", "old=\(canonicalExisting.absoluteString)", "new=\(canonicalTarget.absoluteString)")
                readabilityContainerFrameInfo = nil
            }
        }
        readabilityContent = nil
        readabilityContainerSelector = nil
        //        contentRules = nil
        try Task.checkCancellation()

        guard let content = readerContent.content else {
            debugPrint("# READER readerMode.navCommit.missingContent", newState.pageURL)
            print("No content to display in ReaderModeViewModel onNavigationCommitted")
            cancelReaderModeLoad(for: newState.pageURL)
            return
        }
        try Task.checkCancellation()
        let committedURL = content.url

        guard committedURL.matchesReaderURL(newState.pageURL) else {
            debugPrint("# READER readerMode.navCommit.urlMismatch", committedURL, newState.pageURL)
            print("URL mismatch in ReaderModeViewModel onNavigationCommitted", committedURL, newState.pageURL)
            cancelReaderModeLoad(for: committedURL)
            return
        }
        try Task.checkCancellation()
        logTrace(.navCommitted, url: committedURL, details: "pageURL=\(newState.pageURL.absoluteString)")

        // Inject reader font via JS for non-ebook pages before any scroll/geometry restore runs.
        await injectSharedFontIfNeeded(scriptCaller: scriptCaller, pageURL: committedURL)

        let isLoaderNavigation = newState.pageURL.isReaderURLLoaderURL

        debugPrint(
            "# READERPERF readerMode.navCommit.flags",
            "ts=\(Date().timeIntervalSince1970)",
            "pageURL=\(newState.pageURL.absoluteString)",
            "committedURL=\(committedURL.absoluteString)",
            "isLoaderNavigation=\(isLoaderNavigation)",
            "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")",
            "expectedLoader=\(expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")",
            "isReaderModeLoading=\(isReaderModeLoading)",
            "isReaderMode=\(isReaderMode)"
        )

        if consumeSyntheticReaderLoaderExpectationIfNeeded(for: newState.pageURL) {
            debugPrint(
                "# READERPERF readerMode.syntheticCommit.matched",
                "ts=\(Date().timeIntervalSince1970)",
                "loaderURL=\(newState.pageURL.absoluteString)",
                "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")"
            )
            if let pendingReaderModeURL, pendingReaderModeURL.matchesReaderURL(committedURL) {
                markReaderModeLoadComplete(for: committedURL)
            }
            return
        }

        let isSnippetContent = committedURL.isSnippetURL
        let isSnippetPage = newState.pageURL.isSnippetURL
        if isSnippetContent && isSnippetPage {
            debugPrint(
                "# READER snippet.navCommit",
                "pageURL=\(newState.pageURL.absoluteString)",
                "contentURL=\(committedURL.absoluteString)",
                "loaderPending=\(pendingReaderModeURL?.absoluteString ?? "nil")"
            )
            return
        }

        if isLoaderNavigation {
            debugPrint(
                "# READER readerMode.loaderCommit",
                "loaderURL=\(newState.pageURL.absoluteString)",
                "contentURL=\(committedURL.absoluteString)",
                "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")"
            )
        }

        // FIXME: Mokuro? check plugins thing for reader mode url instead of hardcoding methods here
        let isReaderModeVerified = content.isReaderModeByDefault
        try Task.checkCancellation()

        if isLoaderNavigation,
           pendingReaderModeURL == nil,
           let lastRenderedReadabilityURL,
           lastRenderedReadabilityURL.matchesReaderURL(committedURL) {
            debugPrint(
                "# READER readerMode.navCommit.skipLoader",
                newState.pageURL,
                "for",
                committedURL
            )
            debugPrint(
                "# READERPERF readerMode.navCommit.skipLoader",
                "ts=\(Date().timeIntervalSince1970)",
                "loaderURL=\(newState.pageURL.absoluteString)",
                "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")",
                "lastRendered=\(lastRenderedReadabilityURL.absoluteString)"
            )
            return
        }

        if isReaderMode != isReaderModeVerified && !newState.pageURL.isEBookURL {
            withAnimation {
                if isReaderModeVerified {
                    beginReaderModeLoad(
                        for: committedURL,
                        suppressSpinner: false,
                        reason: "navCommit.isReaderModeVerified"
                    )
                } else {
                    cancelReaderModeLoad(for: committedURL)
                }
                isReaderMode = isReaderModeVerified // Reset and confirm via JS later
            }
            debugPrint(
                "# READERPERF readerMode.toggleByNavCommit",
                "ts=\(Date().timeIntervalSince1970)",
                "pageURL=\(newState.pageURL.absoluteString)",
                "isReaderModeVerified=\(isReaderModeVerified)",
                "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")"
            )
            try Task.checkCancellation()
        }

        if isLoaderNavigation {
            if let readerFileManager {
                logTrace(.htmlFetchStart, url: committedURL, details: "readerFileManager available")
                debugPrint(
                    "# READERPERF readerMode.htmlFetch",
                    "stage=start",
                    "url=\(committedURL.absoluteString)",
                    "source=readerFileManager"
                )
                let htmlFetchStartedAt = Date()
                var htmlResult = try await content.htmlToDisplay(readerFileManager: readerFileManager)
                let fetchDuration = formattedInterval(Date().timeIntervalSince(htmlFetchStartedAt))
                debugPrint(
                    "# READERPERF readerMode.htmlFetch",
                    "stage=end",
                    "url=\(committedURL.absoluteString)",
                    "source=readerFileManager",
                    "elapsed=\(fetchDuration)"
                )
                let htmlByteCount = htmlResult?.utf8.count ?? 0
                let htmlSource = content.rssContainsFullContent
                    ? "stored-html"
                    : (content.isFromClipboard ? "clipboard" : (content.url.isReaderFileURL ? "reader-file" : "unknown"))
                let isSnippetURL = committedURL.isSnippetURL
                var htmlBodyIsEmpty = false
                if
                    let html = htmlResult,
                    let bodyInnerHTML = bodyInnerHTML(from: html)?.trimmingCharacters(in: .whitespacesAndNewlines)
                {
                    let metrics = bodyMetrics(for: html)
                    let hasReaderContentNode = html.range(of: #"id=['"]reader-content['"]"#, options: .regularExpression) != nil
                    let hasReadabilityClass = html.range(of: #"<body[^>]*class=['\"][^>]*readability-mode"#, options: .regularExpression) != nil
                    let readabilityMarkersPresent = hasReaderContentNode || hasReadabilityClass
                    let isEffectivelyEmpty = metrics.bodyHTMLBytes == 0 || (metrics.bodyTextBytes == 0 && !readabilityMarkersPresent) || bodyInnerHTML.isEmpty
                    if isEffectivelyEmpty {
                        htmlBodyIsEmpty = true
                        let preview = snippetPreview(html, maxLength: 160)
                        debugPrint(
                            "# READER readability.htmlFetched.emptyBody",
                            "url=\(committedURL.absoluteString)",
                            "bytes=\(htmlByteCount)",
                            "preview=\(preview)",
                            "rssFull=\(content.rssContainsFullContent)",
                            "readerDefault=\(content.isReaderModeByDefault)",
                            "compressedBytes=\(content.content?.count ?? 0)",
                            "hasReaderContent=\(hasReaderContentNode)",
                            "hasReadabilityClass=\(hasReadabilityClass)"
                        )
                        if !(isSnippetURL && readabilityMarkersPresent) {
                            await invalidateReaderModeCache(
                                for: content,
                                url: committedURL,
                                reason: "emptyBodyAfterDecompress"
                            )
                            // Fall back to forcing a fresh fetch rather than treating this as success.
                            htmlResult = nil
                        }
                    }
                }
                let traceDetails = [
                    "bytes=\(htmlByteCount)",
                    "duration=\(fetchDuration)",
                    "emptyBody=\(htmlBodyIsEmpty)"
                ].joined(separator: " | ")
                logTrace(.htmlFetchEnd, url: committedURL, details: traceDetails)
                if htmlResult == nil {
                    debugPrint(
                        "# READER readability.htmlFetched.nil",
                        "url=\(committedURL.absoluteString)",
                        "reason=emptyBodyOrDecompressFailure"
                    )
                    // Do not abandon the load outright; instead, clear cached render state
                    // and let the caller retry (so we don't get stuck with blank content).
                    lastRenderedReadabilityURL = nil
                    readerModeLoading(false)
                    updatePendingReaderModeURL(nil, reason: "htmlFetchEmptyBody")
                    readerModeLoadCompletionHandler?(committedURL)
                    return
                }
                if var html = htmlResult {
                    if !htmlBodyIsEmpty {
                        debugPrint(
                            "# READER readability.htmlFetched",
                            "url=\(committedURL.absoluteString)",
                            "bytes=\(html.utf8.count)"
                        )
                    }
                    try Task.checkCancellation()

                    let currentURL = readerContent.pageURL
                    guard committedURL.matchesReaderURL(currentURL) else {
                        debugPrint("# READER readerMode.navCommit.currentURLMismatch", committedURL, currentURL)
                        print("URL mismatch in ReaderModeViewModel.onNavigationCommitted", currentURL, committedURL)
                        cancelReaderModeLoad(for: committedURL)
                        return
                    }
                    if let lastFallbackLoaderURL, lastFallbackLoaderURL == newState.pageURL {
                        debugPrint("# READER readerMode.navCommit.skipDuplicateFallback", newState.pageURL)
                        return
                    }

                    let hasReaderContentNode = html.range(of: #"id=['"]reader-content['"]"#, options: .regularExpression) != nil
                    let hasReadabilityClass = html.range(of: #"<body[^>]*class=['\"].*?readability-mode.*?['\"]"#, options: .regularExpression) != nil
                    let hasNextLoadMarkers = html.range(of: #"<body.*?data-(is-next-load-in-reader-mode|next-load-is-readability-mode)=['\"]true['\"]"#, options: .regularExpression) != nil
                    let hasReadabilityMarkup = hasReadabilityClass || hasReaderContentNode || hasNextLoadMarkers
                    let snippetHasReaderContent = isSnippetURL && hasReaderContentNode
                    if snippetHasReaderContent {
                        debugPrint(
                            "# READER snippet.readerContentCached",
                            "url=\(committedURL.absoluteString)",
                            "bytes=\(html.utf8.count)"
                        )
                    }
                    let shouldUseReadability = hasReadabilityMarkup
                    logHTMLBodyMetrics(
                        event: "beforePrepare",
                        html: html,
                        source: htmlSource,
                        url: committedURL,
                        isSnippet: isSnippetURL,
                        hasReadabilityMarkup: hasReadabilityMarkup
                    )
                    debugPrint(
                        "# READER readability.decision",
                        "url=\(committedURL.absoluteString)",
                        "hasMarkup=\(hasReadabilityMarkup)",
                        "snippet=\(isSnippetURL)",
                        "shouldUse=\(shouldUseReadability)"
                    )

                    if shouldUseReadability {
                        readabilityContent = html
                        debugPrint(
                            "# READER readability.captured",
                            "url=\(committedURL.absoluteString)",
                            "snippet=\(isSnippetURL)",
                            "hasMarkup=\(hasReadabilityMarkup)",
                            "bytes=\(html.utf8.count)"
                        )
                        let details = "hasReadabilityMarkup=\(hasReadabilityMarkup) | snippet=\(isSnippetURL)"
                        logTrace(.readabilityContentReady, url: committedURL, details: details)
                        showReaderView(
                            readerContent: readerContent,
                            scriptCaller: scriptCaller
                        )
                        lastFallbackLoaderURL = nil
                    } else {
                        if isSnippetURL {
                            debugPrint(
                                "# READER snippet.readabilityBypass",
                                "url=\(committedURL.absoluteString)",
                                "reason=missingReadabilityMarkup"
                            )
                        }
                        html = prepareHTMLForNextReaderLoad(html)
                        logHTMLBodyMetrics(
                            event: "afterPrepare",
                            html: html,
                            source: htmlSource,
                            url: committedURL,
                            isSnippet: isSnippetURL,
                            hasReadabilityMarkup: hasReadabilityMarkup
                        )
                        try Task.checkCancellation()
                        if let htmlData = html.data(using: .utf8) {
                            let payloadMetrics = bodyMetrics(for: html)
                            debugPrint(
                                "# READER readability.navigatorLoad.payload",
                                "url=\(committedURL.absoluteString)",
                                "bytes=\(htmlData.count)",
                                "hasBody=\(payloadMetrics.hasBody)",
                                "bodyHTMLBytes=\(payloadMetrics.bodyHTMLBytes)",
                                "bodyTextBytes=\(payloadMetrics.bodyTextBytes)"
                            )
                            Task { @MainActor in
                                expectSyntheticReaderLoaderCommit(for: committedURL)
                                debugPrint(
                                    "# READER navigator.load.call",
                                    "baseURL=\(committedURL.absoluteString)",
                                    "pendingURL=\(pendingReaderModeURL?.absoluteString ?? "<nil>")"
                                )
                                if let navigator {
                                    let fallbackLoadStart = Date()
                                    navigator.load(
                                        htmlData,
                                        mimeType: "text/html",
                                        characterEncodingName: "UTF-8",
                                        baseURL: committedURL
                                    )
                                    debugPrint(
                                        "# READERPERF readerMode.navigatorLoad.fallback",
                                        "ts=\(Date().timeIntervalSince1970)",
                                        "url=\(committedURL.absoluteString)",
                                        "bytes=\(htmlData.count)",
                                        "elapsed=\(String(format: "%.3f", Date().timeIntervalSince(fallbackLoadStart)))s"
                                    )
                                } else {
                                    debugPrint("# READER navigator.missing", "url=\(committedURL.absoluteString)")
                                }
                                logTrace(.navigatorLoad, url: committedURL, details: "mode=fallback-html | bytes=\(htmlData.count)")
                            }
                        }
                        lastFallbackLoaderURL = newState.pageURL
                        logTrace(.fallbackLoad, url: committedURL, details: "rendered fallback markup")
                    }
                } else {
                    logTrace(.fallbackLoad, url: committedURL, details: "htmlToDisplay returned nil | duration=\(fetchDuration)")
                    guard let navigator else {
                        print("Error: No navigator set in ReaderModeViewModel onNavigationCommitted")
                        return
                    }
                    logTrace(.navigatorLoad, url: committedURL, details: "mode=fallback-request")
                    expectSyntheticReaderLoaderCommit(for: nil)
                    navigator.load(URLRequest(url: committedURL))
                }
            } else {
                logTrace(.htmlFetchStart, url: committedURL, details: "readerFileManager missing; falling back to request")
                guard let navigator else {
                    print("Error: No navigator set in ReaderModeViewModel onNavigationCommitted")
                    return
                }
                logTrace(.navigatorLoad, url: committedURL, details: "mode=fallback-request")
                expectSyntheticReaderLoaderCommit(for: nil)
                navigator.load(URLRequest(url: committedURL))
            }
            //        } else {
            //            debugPrint("# nav commit mid 2..", newState.pageURL, content.isReaderModeAvailable)
            //            if content.isReaderModeByDefault, !content.isReaderModeAvailable {
            //                debugPrint("# on commit, read mode NOT avail, loading false")
            //                readerModeLoading(false)
            //            }
        } else {
            lastFallbackLoaderURL = nil
        }
    }

    @MainActor
    public func onNavigationFinished(
        newState: WebViewState,
        scriptCaller: WebViewScriptCaller
    ) async {
        debugPrint("# READER readerMode.navFinished", "pageURL=\(newState.pageURL.absoluteString)")
        debugPrint(
            "# READERPERF readerMode.navFinished.detail",
            "ts=\(Date().timeIntervalSince1970)",
            "pageURL=\(newState.pageURL.absoluteString)",
            "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")",
            "isReaderModeLoading=\(isReaderModeLoading)",
            "isReaderMode=\(isReaderMode)"
        )
        await injectSharedFontIfNeeded(scriptCaller: scriptCaller, pageURL: newState.pageURL)
        if let trackedURL = pendingReaderModeURL {
            logTrace(.navFinished, url: trackedURL, details: "pageURL=\(newState.pageURL.absoluteString)")
        } else if loadTraceRecords[traceKey(for: newState.pageURL)] != nil {
            logTrace(.navFinished, url: newState.pageURL, details: "pageURL=\(newState.pageURL.absoluteString)")
        }
        if let pendingReaderModeURL, pendingReaderModeURL.matchesReaderURL(newState.pageURL) {
            debugPrint(
                "# READERPERF readerMode.navFinished.markComplete",
                "ts=\(Date().timeIntervalSince1970)",
                "pending=\(pendingReaderModeURL.absoluteString)"
            )
            markReaderModeLoadComplete(for: pendingReaderModeURL)
        } else {
            debugPrint(
                "# READERPERF readerMode.navFinished.spinnerOff",
                "ts=\(Date().timeIntervalSince1970)",
                "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")"
            )
            readerModeLoading(false)
        }

        logDomSnapshot(pageURL: newState.pageURL, scriptCaller: scriptCaller, reason: newState.pageURL.isReaderURLLoaderURL ? "loader-navFinished" : "navFinished")
    }

    @MainActor
    public func onNavigationFailed(newState: WebViewState) {
        debugPrint("# READER readerMode.navFailed", newState.pageURL)
        cancelReaderModeLoad(for: newState.pageURL)
    }

    @MainActor
    public func onNavigationError(
        pageURL: URL,
        error: Error,
        isProvisional: Bool
    ) {
        debugPrint(
            "# READER readerMode.navigationError",
            "pageURL=\(pageURL.absoluteString)",
            "provisional=\(isProvisional)",
            "error=\(error.localizedDescription)"
        )
        cancelReaderModeLoad(for: pageURL)
    }

}

@MainActor
private extension ReaderModeViewModel {
    func injectSharedFontIfNeeded(scriptCaller: WebViewScriptCaller, pageURL: URL) async {
        guard !pageURL.isEBookURL, pageURL.absoluteString != "about:blank" else { return }
        guard scriptCaller.hasAsyncCaller else { return }
        guard #available(iOS 16.4, macOS 14, *) else { return }
        let base64: String?
        if let inline = sharedFontCSSBase64 {
            base64 = inline
        } else if let provider = sharedFontCSSBase64Provider {
            base64 = await provider()
        } else {
            base64 = nil
        }
        guard let base64, !base64.isEmpty else { return }
        let js = """
        (function() {
            try {
                if (document.documentElement?.dataset?.manabiFontInjected === '1') { return; }
                const css = atob('\(base64)');
                const style = document.createElement('style');
                style.id = 'manabi-custom-fonts-inline';
                style.textContent = css;
                (document.head || document.documentElement).appendChild(style);
                document.documentElement.dataset.manabiFontInjected = '1';
            } catch (e) {
                try { console.log('manabi font inject error', e); } catch (_) {}
            }
        })();
        """
        try? await scriptCaller.evaluateJavaScript(js, duplicateInMultiTargetFrames: true)
    }
}

private func makeReaderHeaderDateText(
    readabilityPublishedTime: String?,
    content: any ReaderContentProtocol
) -> String? {
    if let readabilityPublishedTime,
       !readabilityPublishedTime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if let parsed = parseReadabilityPublishedDate(readabilityPublishedTime) {
            return ReaderDateFormatter.absoluteString(
                from: parsed,
                dateFormatter: ReaderModeViewModel.readerHeaderDateFormatter
            )
        }
        return readabilityPublishedTime.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    guard content.displayPublicationDate else { return nil }
    return content.humanReadablePublicationDate
}

private func parseReadabilityPublishedDate(_ rawValue: String) -> Date? {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let isoWithFractional = ISO8601DateFormatter()
    isoWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = isoWithFractional.date(from: trimmed) {
        return date
    }

    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    if let date = iso.date(from: trimmed) {
        return date
    }

    let dateOnly = ISO8601DateFormatter()
    dateOnly.formatOptions = [.withFullDate]
    if let date = dateOnly.date(from: trimmed) {
        return date
    }

    let simple = DateFormatter()
    simple.locale = Locale(identifier: "en_US_POSIX")
    simple.dateFormat = "yyyy-MM-dd"
    return simple.date(from: trimmed)
}

private func updateBylineSection(
    in doc: SwiftSoup.Document,
    publicationDateText: String?
) throws {
    let bylineElement = try doc.getElementById("reader-byline")
    let bylineText = try bylineElement?.text(trimAndNormaliseWhitespace: true) ?? ""
    if bylineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        try doc.getElementById("reader-byline-line")?.remove()
    }

    let metaLine = try doc.getElementById("reader-meta-line")
    let dateSpan = try doc.getElementById("reader-publication-date")
    let viewOriginal = try metaLine?.select("a.reader-view-original").first()
    let dateText = publicationDateText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let hasDate = !dateText.isEmpty

    if hasDate {
        if let dateSpan {
            try dateSpan.text(dateText)
        }
    } else {
        try dateSpan?.remove()
    }

    if let divider = try metaLine?.select(".reader-meta-divider").first() {
        if hasDate && viewOriginal != nil {
            try divider.text(" | ")
        } else {
            try divider.remove()
        }
    }

    if let metaLine, metaLine.children().isEmpty() {
        try metaLine.remove()
    }

    if let container = try doc.getElementById("reader-byline-container"),
       container.children().isEmpty() {
        try container.remove()
    }
}

private let readerFontSizeStylePattern = #"(?i)(<body[^>]*\bstyle="[^"]*?)(font-size:\s*[\d.]+px)([^"]*")"#
private let readerFontSizeStyleRegex = try! NSRegularExpression(pattern: readerFontSizeStylePattern, options: .caseInsensitive)

private let bodyStylePattern = #"(?i)(<body[^>]*\bstyle=")([^"]*)(")"#
private let bodyStyleRegex = try! NSRegularExpression(pattern: bodyStylePattern, options: .caseInsensitive)

private let bodyInnerHTMLRegex = try! NSRegularExpression(pattern: #"(?is)<body[^>]*>(.*?)</body>"#)

internal func bodyInnerHTML(from html: String) -> String? {
    let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
    guard
        let match = bodyInnerHTMLRegex.firstMatch(in: html, options: [], range: nsRange),
        match.numberOfRanges > 1,
        let range = Range(match.range(at: 1), in: html)
    else {
        return nil
    }
    return String(html[range])
}

internal func bodyMetrics(for html: String) -> (hasBody: Bool, bodyHTMLBytes: Int, bodyTextBytes: Int) {
    guard let bodyHTML = bodyInnerHTML(from: html) else {
        return (false, 0, 0)
    }
    let bodyHTMLBytes = bodyHTML.utf8.count
    let stripped: String
    if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
        let range = NSRange(location: 0, length: (bodyHTML as NSString).length)
        stripped = regex.stringByReplacingMatches(
            in: bodyHTML,
            options: [],
            range: range,
            withTemplate: " "
        )
    } else {
        stripped = bodyHTML
    }
    let bodyTextBytes = stripped.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count
    return (true, bodyHTMLBytes, bodyTextBytes)
}

private func logHTMLBodyMetrics(
    event: String,
    html: String,
    source: String,
    url: URL,
    isSnippet: Bool,
    hasReadabilityMarkup: Bool
) {
    let metrics = bodyMetrics(for: html)
    var parts: [String] = [
        "# READER readability.htmlBodyMetrics",
        "event=\(event)",
        "url=\(url.absoluteString)",
        "source=\(source)",
        "htmlBytes=\(html.utf8.count)",
        "hasBody=\(metrics.hasBody)",
        "bodyHTMLBytes=\(metrics.bodyHTMLBytes)",
        "bodyTextBytes=\(metrics.bodyTextBytes)",
        "hasReadabilityMarkup=\(hasReadabilityMarkup)",
        "snippet=\(isSnippet)"
    ]
    if metrics.hasBody == false {
        let preview = html.prefix(160)
        parts.append("bodyMissingPreview=\(preview)")
    }
    debugPrint(parts.joined(separator: " "))
}

internal func prepareHTMLForNextReaderLoad(_ html: String) -> String {
    if html.range(of: #"<body[^>]*class=['\"].*?readability-mode.*?['\"]"#, options: .regularExpression) != nil
        || html.range(of: #"id=['"]reader-content['"]"#, options: .regularExpression) != nil {
        return html
    }
    let markerAttributes = "data-is-next-load-in-reader-mode='true'"
    var updatedHTML: String

    if html.range(of: "<body", options: .caseInsensitive) != nil {
        updatedHTML = html.replacingOccurrences(of: "<body", with: "<body \(markerAttributes) ", options: .caseInsensitive)
    } else {
        // Ensure a valid body exists so downstream Readability sees content.
        return """
        <html>
        <head></head>
        <body \(markerAttributes) style='content-visibility: hidden;'>
        \(html)
        </body>
        </html>
        """
    }

    let nsHTML = updatedHTML as NSString
    let nsRange = NSRange(location: 0, length: nsHTML.length)

    // Ensure the fallback body stays hidden until the readability content is injected.
    if let styleMatch = bodyStyleRegex.firstMatch(in: updatedHTML, options: [], range: nsRange) {
        let existingStyle = nsHTML.substring(with: styleMatch.range(at: 2))
        if existingStyle.range(of: "content-visibility", options: .caseInsensitive) == nil {
            let prefix = nsHTML.substring(with: styleMatch.range(at: 1))
            let suffix = nsHTML.substring(with: styleMatch.range(at: 3))
            let newStyle = "content-visibility: hidden; \(existingStyle)"
            let replacement = prefix + newStyle + suffix
            updatedHTML = nsHTML.replacingCharacters(in: styleMatch.range, with: replacement)
        }
    } else {
        updatedHTML = updatedHTML.replacingOccurrences(of: "<body", with: "<body style='content-visibility: hidden;'", options: .caseInsensitive)
    }

    return updatedHTML
}

@MainActor
private func invalidateReaderModeCache(
    for content: any ReaderContentProtocol,
    url: URL,
    reason: String
) async {
    let compressedBytes = content.content?.count ?? 0
    debugPrint(
        "# READER readability.cache.invalidate",
        "url=\(url.absoluteString)",
        "compressedBytes=\(compressedBytes)",
        "reason=\(reason)",
        "readerDefault=\(content.isReaderModeByDefault)",
        "rssFull=\(content.rssContainsFullContent)"
    )
    do {
        try await content.asyncWrite { _, record in
            record.content = nil
            if !url.isSnippetURL {
                record.rssContainsFullContent = false
                record.isReaderModeByDefault = false
                record.isReaderModeAvailable = false
            }
            record.refreshChangeMetadata(explicitlyModified: true)
        }
    } catch {
        debugPrint(
            "# READER readerMode.invalidateCache.error",
            url.absoluteString,
            error.localizedDescription
        )
    }
}

@MainActor
private func propagateReaderModeDefaults(
    for url: URL,
    primaryRecord: any ReaderContentProtocol,
    readabilityHTML: String,
    fallbackTitle: String?
) async {
    let primaryKey = primaryRecord.compoundKey
    let derivedTitle = titleFromReadabilityHTML(readabilityHTML) ?? fallbackTitle
    _ = await Task { @RealmBackgroundActor in
        do {
            let relatedRecords = try await ReaderContentLoader.loadAll(url: url)
            for record in relatedRecords {
                guard record.compoundKey != primaryKey, let realm = record.realm else { continue }
                try await realm.asyncWrite {
                    record.isReaderModeByDefault = true
                    record.isReaderModeAvailable = false
                    if !url.isEBookURL && !url.isFileURL && !url.isNativeReaderView {
                        if !url.isReaderFileURL && (record.content?.isEmpty ?? true) {
                            record.html = readabilityHTML
                        }
                        if let derivedTitle,
                           record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            record.title = derivedTitle
                        }
                        record.rssContainsFullContent = true
                    }
                    record.refreshChangeMetadata(explicitlyModified: true)
                }
            }
        } catch {
            debugPrint(
                "# READER readerMode.propagateDefaults.error",
                url.absoluteString,
                error.localizedDescription
            )
        }
    }.value
}

internal func titleFromReadabilityHTML(_ html: String) -> String? {
    func normalisedTitle(_ raw: String?) -> String? {
        let trimmed = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.truncate(36)
    }

    // Prefer semantic title hints in the readability HTML.
    if let doc = try? SwiftSoup.parse(html) {
        if let readerTitleText = try? doc.getElementById("reader-title")?.text(),
           let title = normalisedTitle(readerTitleText) {
            return title
        }

        if let headingText = try? doc.select("h1").first()?.text(),
           let title = normalisedTitle(headingText) {
            return title
        }

        if let headTitle = try? doc.title(),
           let title = normalisedTitle(headTitle) {
            return title
        }

        // Avoid pulling the full article body into the title by removing the main
        // content container before falling back to the body text.
        let docCopy = doc
        if let readerContent = try? docCopy.getElementById("reader-content") {
            try? readerContent.remove()
        }
        if let bodyText = try? docCopy.body()?.text(),
           let title = normalisedTitle(bodyText) {
            return title
        }
    }

    // Final fallback: strip markup and grab the first line as before.
    let stripped = html.strippingHTML().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !stripped.isEmpty else { return nil }
    let candidate = stripped.components(separatedBy: "\n").first ?? stripped
    return normalisedTitle(candidate)
}

internal func rewriteManabiReaderFontSizeStyle(in htmlBytes: [UInt8], newFontSize: Double) -> [UInt8] {
    // Convert the UTF8 bytes to a String.
    guard let html = String(bytes: htmlBytes, encoding: .utf8) else {
        return htmlBytes
    }

    let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
    let nsHTML = html as NSString
    var updatedHtml: String
    let formattedFontSize = newFontSize.truncatingRemainder(dividingBy: 1) == 0
        ? String(Int(newFontSize))
        : String(newFontSize)
    let newFontSizeStr = "font-size: " + formattedFontSize + "px"
    // If a font-size exists in the style, replace its value while preserving other declarations.
    if let firstMatch = readerFontSizeStyleRegex.firstMatch(in: html, options: [], range: nsRange),
       firstMatch.numberOfRanges >= 4 {
        let prefix = nsHTML.substring(with: firstMatch.range(at: 1))
        let suffix = nsHTML.substring(with: firstMatch.range(at: 3))
        let replacement = prefix + newFontSizeStr + suffix
        updatedHtml = nsHTML.replacingCharacters(in: firstMatch.range, with: replacement)
    }
    // Otherwise, if a <body ... style="..."> exists, insert the font-size.
    else if let styleMatch = bodyStyleRegex.firstMatch(in: html, options: [], range: nsRange) {
        let prefix = nsHTML.substring(with: styleMatch.range(at: 1))
        let content = nsHTML.substring(with: styleMatch.range(at: 2))
        let suffix = nsHTML.substring(with: styleMatch.range(at: 3))
        let newContent = newFontSizeStr + "; " + content
        let replacement = prefix + newContent + suffix
        updatedHtml = nsHTML.replacingCharacters(in: styleMatch.range, with: replacement)
    } else {
        updatedHtml = html
    }

    // Convert the updated HTML string back to UTF8 bytes.
    return Array(updatedHtml.utf8)
}

public func preprocessWebContentForReaderMode(
    doc: SwiftSoup.Document,
    url: URL,
    fallbackTitle: String? = nil
) throws -> SwiftSoup.Document {
    transformContentSpecificToFeed(doc: doc, url: url)
    do {
        try wireViewOriginalLinks(doc: doc, url: url)
    } catch { }

    if let fallbackTitle, !fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        if let titleElement = try doc.getElementById("reader-title") {
            let currentTitleText = try titleElement.text(trimAndNormaliseWhitespace: false)
            if currentTitleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try titleElement.text(fallbackTitle)
                if let headTitle = try doc.head()?.getElementsByTag("title").first() {
                    let currentHeadTitle = try headTitle.text()
                    if currentHeadTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        try headTitle.text(fallbackTitle)
                    }
                }
            }
        }
    }
    return doc
}

public func processForReaderMode(
    doc: SwiftSoup.Document,
    url: URL,
    contentSectionLocationIdentifier: String?,
    isEBook: Bool,
    isCacheWarmer: Bool,
    defaultTitle: String?,
    imageURL: URL?,
    injectEntryImageIntoHeader: Bool,
    defaultFontSize: CGFloat
) throws {
    // Migrate old cached versions
    // TODO: Update cache, if this is a performance issue.
    if let oldElement = try doc.getElementsByClass("reader-content").first(), try doc.getElementById("reader-content") == nil {
        try oldElement.attr("id", "reader-content")
        try oldElement.removeAttr("class")
    }

    if isEBook {
        try doc.body()?.attr("data-is-ebook", "true")
    }

    if !isCacheWarmer {
        if let bodyTag = doc.body() {
            // TODO: font size and theme set elsewhere already..?
            let readerFontSize = (UserDefaults.standard.object(forKey: "readerFontSize") as? Double) ?? defaultFontSize
            let lightModeTheme = (UserDefaults.standard.object(forKey: "lightModeTheme") as? LightModeTheme) ?? .white
            let darkModeTheme = (UserDefaults.standard.object(forKey: "darkModeTheme") as? DarkModeTheme) ?? .black

            var existingBodyStyle = (try? bodyTag.attr("style")) ?? ""
            if !existingBodyStyle.isEmpty {
                existingBodyStyle = existingBodyStyle
                    .split(separator: ";")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.lowercased().hasPrefix("content-visibility") && !$0.isEmpty }
                    .joined(separator: "; ")
                _ = try? bodyTag.attr("style", existingBodyStyle)
            }

            var bodyStyle = "font-size: \(readerFontSize)px"
            if !existingBodyStyle.isEmpty {
                bodyStyle = "\(bodyStyle); \(existingBodyStyle)"
            }
            _ = try? bodyTag.attr("style", bodyStyle)
            _ = try? bodyTag.attr("data-manabi-light-theme", lightModeTheme.rawValue)
            _ = try? bodyTag.attr("data-manabi-dark-theme", darkModeTheme.rawValue)
        }

        if let defaultTitle = defaultTitle, let existing = try? doc.getElementById("reader-title"), !existing.hasText() {
            let escapedTitle = Entities.escape(defaultTitle, OutputSettings().charset(String.Encoding.utf8).escapeMode(Entities.EscapeMode.extended))
            do {
                try existing.html(escapedTitle)
            } catch { }
        }

        if !isEBook {
            do {
                try fixAnnoyingTitlesWithPipes(doc: doc)
            } catch { }
        }

        if try injectEntryImageIntoHeader || (doc.body()?.getElementsByTag(UTF8Arrays.img).isEmpty() ?? true), let imageURL = imageURL, let existing = try? doc.select("img[src='\(imageURL.absoluteString)'"), existing.isEmpty() {
            do {
                try doc.getElementById("reader-header")?.prepend("<img src='\(imageURL.absoluteString)'>")
            } catch { }
        }
    }
}
