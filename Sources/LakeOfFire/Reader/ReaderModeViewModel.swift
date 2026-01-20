import SwiftUI
import SwiftUIWebView
import SwiftSoup
import SwiftReadability
import SwiftDOMPurify
import RealmSwift
import Combine
import RealmSwiftGaps
import LakeKit
import WebKit

private extension URL {
    var isAboutBlank: Bool { absoluteString == "about:blank" }
}

@globalActor
public actor ReaderViewModelActor {
    public static let shared = ReaderViewModelActor()
}

private let readerPerfStacksEnabled = false

private let readabilityExcludedDomains: Set<String> = [
    "x.com",
    "twitter.com",
    "facebook.com",
    "instagram.com",
    "youtube.com",
    "web.whatsapp.com",
    "mail.google.com",
    "outlook.live.com",
    "discord.com",
    "teams.microsoft.com",
    "docs.google.com",
    "drive.google.com",
    "calendar.google.com",
    "slack.com",
    "notion.so",
    "linkedin.com",
    "reddit.com",
    "messenger.com",
    "meet.google.com",
    "tiktok.com",
    "amazon.com",
    "line.me",
    "mail.yahoo.co.jp"
]

private let readabilityClassesToPreserve: [String] = [
    "caption",
    "emoji",
    "hidden",
    "invisible",
    "sr-only",
    "visually-hidden",
    "visuallyhidden",
    "wp-caption",
    "wp-caption-text",
    "wp-smiley"
]

private let readabilityBylinePrefixRegex = try! NSRegularExpression(pattern: "^(by|par)\\s+", options: [.caseInsensitive])

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
    public var lastRenderedURL: URL? { lastRenderedReadabilityURL }
    public private(set) var expectedSyntheticReaderLoaderURL: URL?
    public private(set) var pendingReaderModeURL: URL?
    private var loadTraceRecords: [String: ReaderModeLoadTraceRecord] = [:]
    private var loadStartTimes: [String: Date] = [:]

    @Published public var isReaderMode = false
    @Published public var isReaderModeLoading = false
    public var hasRenderedReadabilityContent: Bool { lastRenderedReadabilityURL != nil }
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

        func matchesSyntheticCommit(_ expected: URL, _ actual: URL) -> Bool {
            // IMPORTANT: do not use `matchesReaderURL` here.
            // The loader trampoline (`internal://local/load/reader?...`) must NOT match the content URL,
            // otherwise we consume the expectation on the initial loader navigation and prematurely
            // mark loads complete (often via `complete.emptyReadability`).
            urlsMatchWithoutHash(expected, actual)
        }

        if matchesSyntheticCommit(expectedSyntheticReaderLoaderURL, url) {
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
        // Ignore about:blank churn; it should never drive pending state.
        if let newValue, newValue.isAboutBlank {
            debugPrint(
                "# FLASH readerMode.pendingUpdate.skipAboutBlank",
                "reason=\(reason)",
                "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")"
            )
            return
        }
        debugPrint(
            "# READERRELOAD pending.update",
            "reason=\(reason)",
            "from=\(pendingReaderModeURL?.absoluteString ?? "nil")",
            "to=\(newValue?.absoluteString ?? "nil")",
            "isReaderMode=\(isReaderMode)",
            "isReaderModeLoading=\(isReaderModeLoading)"
        )
        let oldValue = pendingReaderModeURL
        let canonicalNewValue = newValue?.canonicalReaderContentURL()
        let canonicalOldValue = oldValue?.canonicalReaderContentURL()
        let oldDescription = oldValue?.absoluteString ?? "nil"
        let newDescription = canonicalNewValue?.absoluteString ?? "nil"
        let changeDescription: String
        if urlsMatchWithoutHash(canonicalOldValue, canonicalNewValue) {
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
        debugPrint(
            "# FLASH readerMode.pendingUpdate",
            "from=\(oldDescription)",
            "to=\(newDescription)",
            "change=\(changeDescription)",
            "reason=\(reason)",
            "isLoading=\(isReaderModeLoading)",
            "awaitingFirstRender=\(lastRenderedReadabilityURL == nil)"
        )
        pendingReaderModeURL = canonicalNewValue
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
        return pendingKeysMatch(lastRenderedReadabilityURL, url)
    }

    /// Normalizes loader/snippet URLs so pending/completion matching stays stable
    /// across internal loader redirects and snippet content URLs.
    private func normalizedPendingMatchKey(for url: URL?) -> String? {
        guard let url else { return nil }

        // Canonicalize snippet URLs by key so loader and final URLs line up.
        if let snippetKey = url.snippetKey {
            return "snippet:\(snippetKey)"
        }

        // If this is the internal reader loader, prefer its reader-url target.
        if url.isReaderURLLoaderURL,
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let readerValue = components.queryItems?.first(where: { $0.name == "reader-url" })?.value {
            let decodedReaderURLString = readerValue.removingPercentEncoding ?? readerValue
            guard let readerURL = URL(string: decodedReaderURLString) else {
                return url.absoluteString
            }
            // Preserve snippet equivalence even when nested in the loader.
            if let snippetKey = readerURL.snippetKey {
                return "snippet:\(snippetKey)"
            }
            return readerURL.absoluteString
        }

        return url.absoluteString
    }

    private func pendingKeysMatch(_ lhs: URL?, _ rhs: URL?) -> Bool {
        normalizedPendingMatchKey(for: lhs) == normalizedPendingMatchKey(for: rhs)
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

    internal func readerModeLoading(_ isLoading: Bool, frameIsMain: Bool = true) {
        // Ignore loads that originate from subframes; only the main frame should drive the overlay.
        if !frameIsMain {
            return
        }
        // Ignore about:blank spinner flips; they are bootstrap navigations.
        if pendingReaderModeURL?.isAboutBlank == true {
            debugPrint("# FLASH readerMode.spinner.skipAboutBlank", "loading=\(isLoading)")
            return
        }
        if isLoading && !isReaderModeLoading {
            debugPrint(
                "# FLASH readerMode.spinner",
                "loading=true",
                "pendingURL=\(pendingReaderModeURL?.absoluteString ?? "nil")"
            )
            debugPrint(
                "# FLASH readerMode.spinnerState",
                "loading=true",
                "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")",
                "lastRendered=\(lastRenderedReadabilityURL?.absoluteString ?? "nil")",
                "expectedLoader=\(expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")"
            )
            debugPrint(
                "# READERPERF readerMode.spinner.set",
                "ts=\(Date().timeIntervalSince1970)",
                "value=true",
                "pendingURL=\(pendingReaderModeURL?.absoluteString ?? "nil")",
                "lastRendered=\(lastRenderedReadabilityURL?.absoluteString ?? "nil")"
            )
            debugPrint(
                "# FLASH readerMode.spinner.set",
                "value=true",
                "pendingURL=\(pendingReaderModeURL?.absoluteString ?? "nil")",
                "lastRendered=\(lastRenderedReadabilityURL?.absoluteString ?? "nil")",
                "stack=\(Thread.callStackSymbols.prefix(4).joined(separator: " | "))"
            )
            isReaderModeLoading = true
        } else if !isLoading && isReaderModeLoading {
            debugPrint(
                "# FLASH readerMode.spinner",
                "loading=false",
                "pendingURL=\(pendingReaderModeURL?.absoluteString ?? "nil")"
            )
            debugPrint(
                "# FLASH readerMode.spinnerState",
                "loading=false",
                "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")",
                "lastRendered=\(lastRenderedReadabilityURL?.absoluteString ?? "nil")",
                "expectedLoader=\(expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")"
            )
            debugPrint(
                "# READERPERF readerMode.spinner.set",
                "ts=\(Date().timeIntervalSince1970)",
                "value=false",
                "pendingURL=\(pendingReaderModeURL?.absoluteString ?? "nil")",
                "lastRendered=\(lastRenderedReadabilityURL?.absoluteString ?? "nil")"
            )
            debugPrint(
                "# FLASH readerMode.spinner.set",
                "value=false",
                "pendingURL=\(pendingReaderModeURL?.absoluteString ?? "nil")",
                "lastRendered=\(lastRenderedReadabilityURL?.absoluteString ?? "nil")",
                "stack=\(Thread.callStackSymbols.prefix(4).joined(separator: " | "))"
            )
            isReaderModeLoading = false
        }
    }

    @MainActor
    public func beginReaderModeLoad(for url: URL, suppressSpinner: Bool = false, reason: String? = nil) {
        let canonicalURL = url.canonicalReaderContentURL()
        let matchesRendered = urlMatchesLastRendered(canonicalURL)
        let start = Date()

        debugPrint(
            "# READERRELOAD beginLoad",
            "url=\(canonicalURL.absoluteString)",
            "reason=\(reason ?? "nil")",
            "suppressSpinner=\(suppressSpinner)",
            "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")",
            "expected=\(expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")",
            "isReaderMode=\(isReaderMode)",
            "isReaderModeLoading=\(isReaderModeLoading)",
            "lastRendered=\(lastRenderedReadabilityURL?.absoluteString ?? "nil")",
            "hasReadability=\(readabilityContent != nil)"
        )
        debugPrint(
            "# READERPERF readerMode.beginLoad.request",
            "ts=\(start.timeIntervalSince1970)",
            "url=\(canonicalURL.absoluteString)",
            "reason=\(reason ?? "nil")",
            "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")",
            "expectedLoader=\(expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")",
            "isReaderModeLoading=\(isReaderModeLoading)",
            "isReaderMode=\(isReaderMode)",
            "lastRendered=\(lastRenderedReadabilityURL?.absoluteString ?? "nil")"
        )
        debugPrint(
            "# BEGINREADERMODELOAD",
            "url=\(canonicalURL.absoluteString)",
            "suppressSpinner=\(suppressSpinner)",
            "reason=\(reason ?? "nil")",
            "matchesRendered=\(matchesRendered)",
            "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")",
            "expectedLoader=\(expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")"
        )
        if let expected = expectedSyntheticReaderLoaderURL {
            let canonicalExpected = expected.canonicalReaderContentURL()
            if !urlsMatchWithoutHash(canonicalExpected, canonicalURL) {
                debugPrint(
                    "# READERPERF readerMode.expectedLoader.reset",
                    "from=\(expected.absoluteString)",
                    "to=nil",
                    "reason=beginLoad.newURL",
                    "ts=\(Date().timeIntervalSince1970)"
                )
                expectedSyntheticReaderLoaderURL = nil
            }
        }

        let pendingMatches = pendingReaderModeURL?.matchesReaderURL(canonicalURL) == true
        let alreadyLoadingSame = pendingMatches && isReaderModeLoading
        let isSameAsLastRendered = lastRenderedReadabilityURL.map { pendingKeysMatch($0, canonicalURL) } ?? false

        if let pending = pendingReaderModeURL, !pending.matchesReaderURL(canonicalURL) {
            let stack = Thread.callStackSymbols.prefix(6).joined(separator: " | ")
            debugPrint(
                "# READERPERF readerMode.beginLoad.pendingMismatch",
                "ts=\(start.timeIntervalSince1970)",
                "url=\(canonicalURL.absoluteString)",
                "pending=\(pending.absoluteString)",
                "reason=\(reason ?? "nil")",
                "isReaderModeLoading=\(isReaderModeLoading)",
                "isReaderMode=\(isReaderMode)",
                "lastRendered=\(lastRenderedReadabilityURL?.absoluteString ?? "nil")",
                "stack=\(stack)"
            )
        }

        if alreadyLoadingSame {
            let stack = Thread.callStackSymbols.prefix(6).joined(separator: " | ")
            debugPrint(
                "# READERPERF readerMode.beginLoad.skipped",
                "ts=\(start.timeIntervalSince1970)",
                "url=\(canonicalURL.absoluteString)",
                "reason=alreadyLoadingPending",
                "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")",
                "lastRendered=\(lastRenderedReadabilityURL?.absoluteString ?? "nil")",
                "stack=\(stack)"
            )
            if let pending = pendingReaderModeURL {
                debugPrint(
                    "# READERPERF readerMode.beginLoad.skipped.detail",
                    "pendingMatches=true",
                    "pending=\(pending.absoluteString)",
                    "expectedLoader=\(expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")",
                    "isReaderModeLoading=\(isReaderModeLoading)",
                    "isReaderMode=\(isReaderMode)",
                    "isSameAsLastRendered=\(isSameAsLastRendered)",
                    "reasonHint=\(reason ?? "nil")"
                )
            }
            logPerfStack("beginLoad.skipped", url: canonicalURL)
            return
        }

        if matchesRendered,
           pendingReaderModeURL == nil,
           isReaderMode {
            if readabilityContent != nil {
                debugPrint(
                    "# READERRELOAD beginLoad.shortCircuit",
                    "reason=alreadyRenderedWithReadability",
                    "url=\(canonicalURL.absoluteString)",
                    "lastRendered=\(lastRenderedReadabilityURL?.absoluteString ?? "nil")",
                    "isLoading=\(isReaderModeLoading)"
                )
                readerModeLoading(false, frameIsMain: true)
                return
            }
            debugPrint(
                "# READER readerMode.beginLoad.rerenderAlreadyRendered",
                "url=\(canonicalURL.absoluteString)",
                "lastRendered=\(lastRenderedReadabilityURL?.absoluteString ?? "nil")"
            )
            // Force a fresh render to avoid stale/empty content while still clearing spinners.
            if let rendered = lastRenderedReadabilityURL, !pendingKeysMatch(rendered, canonicalURL) {
                lastRenderedReadabilityURL = nil
                debugPrint(
                    "# FLASH readerMode.lastRendered.clear",
                    "url=\(canonicalURL.absoluteString)",
                    "reason=rerenderAlreadyRendered.mismatch"
                )
            }
        }
        logStateSnapshot("beginLoad.precheck", url: canonicalURL)
        var isContinuing = false
        if let pendingReaderModeURL, pendingReaderModeURL.matchesReaderURL(canonicalURL) {
            // already tracking this load
            isContinuing = true
        } else {
            updatePendingReaderModeURL(canonicalURL, reason: "beginLoad")
            if let rendered = lastRenderedReadabilityURL, !pendingKeysMatch(rendered, canonicalURL) {
                lastRenderedReadabilityURL = nil
                debugPrint(
                    "# FLASH readerMode.lastRendered.clear",
                    "url=\(canonicalURL.absoluteString)",
                    "reason=beginLoad.newPending"
                )
            }
            lastFallbackLoaderURL = nil
        }
        let trackedURL = pendingReaderModeURL ?? canonicalURL
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
            readerModeLoading(true, frameIsMain: true)
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
        debugPrint(
            "# READERRELOAD cancel.enter",
            "url=\(url?.absoluteString ?? "nil")",
            "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")",
            "expected=\(expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")",
            "isReaderMode=\(isReaderMode)",
            "isReaderModeLoading=\(isReaderModeLoading)"
        )
        if let url,
           url.isReaderURLLoaderURL,
           let pendingReaderModeURL,
           pendingKeysMatch(pendingReaderModeURL, url),
           (readabilityContent != nil || lastRenderedReadabilityURL != nil) {
            debugPrint(
                "# READERRELOAD cancel.skip",
                "reason=loaderCancelWithReadability",
                "url=\(url.absoluteString)",
                "pending=\(pendingReaderModeURL.absoluteString)"
            )
            return
        }
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
            readerModeLoading(false, frameIsMain: true)
            debugPrint(
                "# READER readerMode.spinner.forceOff",
                "reason=noPendingCancel",
                "requestedURL=\(url?.absoluteString ?? "nil")"
            )
            // Clear stale loader expectation so it can't leak into the next navigation,
            // but keep the last rendered URL so snippet flows can suppress redundant reloads.
            expectedSyntheticReaderLoaderURL = nil
            if let handler = readerModeLoadCompletionHandler {
                let completedURL: URL = {
                    if let url, !url.isAboutBlank {
                        return url.canonicalReaderContentURL()
                    }
                    if let lastRenderedReadabilityURL {
                        return lastRenderedReadabilityURL
                    }
                    if let lastFallbackLoaderURL {
                        return lastFallbackLoaderURL
                    }
                    return URL(string: "about:blank")!
                }()
                handler(completedURL)
            }
            return
        }
        if let url, !pendingKeysMatch(pendingReaderModeURL, url) {
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
        readerModeLoading(false, frameIsMain: true)
        expectedSyntheticReaderLoaderURL = nil
        lastRenderedReadabilityURL = nil
        debugPrint(
            "# FLASH readerMode.lastRendered.clear",
            "url=\((traceURL ?? url)?.absoluteString ?? "nil")",
            "reason=cancelReaderModeLoad"
        )
        if let handler = readerModeLoadCompletionHandler {
            handler(traceURL ?? url ?? URL(string: "about:blank")!)
        }
    }

    @MainActor
    public func markReaderModeLoadComplete(for url: URL) {
        debugPrint(
            "# READERRELOAD complete.enter",
            "url=\(url.absoluteString)",
            "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")",
            "expected=\(expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")",
            "isReaderMode=\(isReaderMode)",
            "isReaderModeLoading=\(isReaderModeLoading)",
            "hasReadability=\(readabilityContent != nil)"
        )
        guard let pendingReaderModeURL, pendingKeysMatch(pendingReaderModeURL, url) else {
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
                readerModeLoading(false, frameIsMain: true)
                readerModeLoadCompletionHandler?(url)
            }
            return
        }
        let readabilityBytes = readabilityContent?.utf8.count ?? 0
        if readabilityBytes == 0 {
            if handleEmptyReadabilityCompletion(url: url, pendingReaderModeURL: pendingReaderModeURL) {
                return
            }
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
        if lastRenderedReadabilityURL == nil {
            lastRenderedReadabilityURL = traceURL
            debugPrint(
                "# FLASH readerMode.rendered.setFallback",
                "url=\(traceURL.absoluteString)",
                "reason=complete.success.noRenderedURL"
            )
        }
        logStateSnapshot("complete.success", url: traceURL)
        logTrace(.complete, url: traceURL, details: "markReaderModeLoadComplete")
        loadStartTimes.removeValue(forKey: traceURL.absoluteString)
        readerModeLoading(false, frameIsMain: true)
        readerModeLoadCompletionHandler?(traceURL)
    }

    private func handleEmptyReadabilityCompletion(url: URL, pendingReaderModeURL: URL) -> Bool {
        let canonicalURL = url.canonicalReaderContentURL()

        // If we already rendered readability for this URL, treat missing readabilityContent
        // as a non-fatal state (it may have been cleared after rendering to reduce memory).
        if urlMatchesLastRendered(canonicalURL) {
            debugPrint(
                "# FLASH readerMode.complete.emptyReadability.rendered",
                "url=\(canonicalURL.absoluteString)",
                "pending=\(pendingReaderModeURL.absoluteString)"
            )
            logStateSnapshot("complete.renderedEmptyReadability", url: pendingReaderModeURL)
            updatePendingReaderModeURL(nil, reason: "markReaderModeLoadComplete.renderedEmptyReadability")
            readerModeLoading(false, frameIsMain: true)
            readerModeLoadCompletionHandler?(canonicalURL)
            return true
        }

        if canonicalURL.isSnippetURL {
            debugPrint(
                "# SNIPPETLOAD readerMode.complete.emptyReadability.snippet",
                canonicalURL.absoluteString
            )
            logStateSnapshot("complete.emptyReadability.snippet", url: pendingReaderModeURL)
            updatePendingReaderModeURL(nil, reason: "complete.emptyReadability.snippet")
            expectedSyntheticReaderLoaderURL = nil
            lastFallbackLoaderURL = canonicalURL
            readerModeLoading(false, frameIsMain: true)
            readerModeLoadCompletionHandler?(canonicalURL)
            return true
        }

        if expectedSyntheticReaderLoaderURL != nil {
            debugPrint(
                "# READER readerMode.complete.defer.emptyReadability.expectedSyntheticCommit",
                url.absoluteString
            )
            return true
        }

        debugPrint(
            "# READERPERF readerMode.complete.deferred",
            "url=\(url.absoluteString)",
            "reason=emptyReadability",
            "pending=\(pendingReaderModeURL.absoluteString)",
            "expectedLoader=\(expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")",
            "isReaderModeLoading=\(isReaderModeLoading)",
            "ts=\(Date().timeIntervalSince1970)",
            "stack=\(Thread.callStackSymbols.prefix(5).joined(separator: " | "))"
        )

        // Treat empty readability (e.g., EPUB native view or script-only pages) as
        // a terminal state so spinners do not linger indefinitely.
        logStateSnapshot("complete.emptyReadability", url: pendingReaderModeURL)
        updatePendingReaderModeURL(nil, reason: "complete.emptyReadability")
        lastFallbackLoaderURL = canonicalURL
        readerModeLoading(false, frameIsMain: true)
        readerModeLoadCompletionHandler?(canonicalURL)
        return true
    }

    @MainActor
    public func isReaderModeLoadPending(for url: URL) -> Bool {
        guard let pendingReaderModeURL else { return false }
        return pendingKeysMatch(pendingReaderModeURL, url)
    }

    @MainActor
    public func clearReadabilityCache(for url: URL, reason: String) {
        let canonicalURL = url.canonicalReaderContentURL()
        let matchesLastRendered = lastRenderedReadabilityURL.map { pendingKeysMatch($0, canonicalURL) } ?? false
        let matchesPending = pendingReaderModeURL.map { pendingKeysMatch($0, canonicalURL) } ?? false
        let isHandling = isReaderModeHandlingURL(canonicalURL)
        let shouldClear = matchesLastRendered || matchesPending || isHandling
        debugPrint(
            "# READERRELOAD cache.clear",
            "url=\(canonicalURL.absoluteString)",
            "reason=\(reason)",
            "matchesLastRendered=\(matchesLastRendered)",
            "matchesPending=\(matchesPending)",
            "isHandling=\(isHandling)",
            "hadReadability=\(readabilityContent != nil)",
            "lastRendered=\(lastRenderedReadabilityURL?.absoluteString ?? "nil")"
        )
        guard shouldClear else { return }
        readabilityContent = nil
        readabilityContainerSelector = nil
        readabilityContainerFrameInfo = nil
        expectedSyntheticReaderLoaderURL = nil
        if matchesLastRendered {
            lastRenderedReadabilityURL = nil
        }
    }

    func isReaderModeHandlingURL(_ url: URL) -> Bool {
        if let pendingReaderModeURL, pendingKeysMatch(pendingReaderModeURL, url) {
            return true
        }
        if let lastRenderedReadabilityURL, pendingKeysMatch(lastRenderedReadabilityURL, url) {
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
        if let pendingReaderModeURL, pendingKeysMatch(pendingReaderModeURL, content.url) {
            return true
        }
        return !isReaderMode && content.isReaderModeAvailable && content.isReaderModeByDefault
    }
    
    // TODO: Might not need to pass both of these in... seems like a lot of redundant checks...
    func isReaderModeLoadedOrPending(url: URL, content: (any ReaderContentProtocol)?) -> Bool {
        if isReaderModeLoading || isReaderMode || isReaderModeLoadPending(for: url) {
            return true
        }
        if let content {
            return isReaderModeLoadPending(content: content)
        }
        return false
    }

    @MainActor
    public func showReaderView(readerContent: ReaderContent, scriptCaller: WebViewScriptCaller) {
        debugPrint("# READER readerMode.showReaderView", readerContent.pageURL)
        debugPrint(
            "# READERMODE showReaderView.state",
            "pageURL=\(readerContent.pageURL.absoluteString)",
            "isReaderMode=\(isReaderMode)",
            "isReaderModeLoading=\(isReaderModeLoading)",
            "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")",
            "expectedLoader=\(expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")",
            "lastRendered=\(lastRenderedReadabilityURL?.absoluteString ?? "nil")",
            "hasReadability=\(readabilityContent != nil)",
            "readabilityBytes=\(readabilityContent?.utf8.count ?? 0)",
            "contentLoaded=\(readerContent.content != nil)"
        )
        if let content = readerContent.content {
            debugPrint(
                "# READERMODE showReaderView.content",
                "contentURL=\(content.url.absoluteString)",
                "readerAvailable=\(content.isReaderModeAvailable)",
                "readerDefault=\(content.isReaderModeByDefault)",
                "rssFull=\(content.rssContainsFullContent)",
                "fromClipboard=\(content.isFromClipboard)"
            )
        }
        debugPrint(
            "# FLASH readability.showReaderView",
            "contentURL=\(flashURLDescription(readerContent.pageURL))",
            "hasReadability=\(readabilityContent != nil)"
        )
        let readabilityBytes = readabilityContent?.utf8.count ?? 0
        logTrace(.readabilityTaskScheduled, url: readerContent.pageURL, details: "readabilityBytes=\(readabilityBytes)")
        let contentURL = readerContent.pageURL
        guard let readabilityContent else {
            // FIME: WHY THIS CALLED WHEN LOAD??
            debugPrint("# READER readerMode.showReaderView.missingContent", readerContent.pageURL)
            debugPrint("# READER readability.missingContent", "url=\(readerContent.pageURL.absoluteString)")
            debugPrint(
                "# READERMODE showReaderView.missingReadability",
                "pageURL=\(contentURL.absoluteString)",
                "isReaderMode=\(isReaderMode)",
                "isReaderModeLoading=\(isReaderModeLoading)",
                "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")",
                "expectedLoader=\(expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")",
                "lastRendered=\(lastRenderedReadabilityURL?.absoluteString ?? "nil")"
            )
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
                "# FLASH readability.targetFrame",
                "frameURL=\(flashURLDescription(frameInfo.request.url))",
                "pageURL=\(flashURLDescription(readerContent.pageURL))"
            )
        } else {
            debugPrint("# FLASH readability.targetFrame", "frameURL=<nil>", "pageURL=\(flashURLDescription(readerContent.pageURL))")
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
                "# FLASH snippet.renderStart",
                "contentURL=\(url.absoluteString)",
                "readabilityBytes=\(readabilityContent.utf8.count)",
                "frameIsMain=\(frameInfo?.isMainFrame ?? true)",
                "renderSelector=\(renderToSelector ?? "<root>")"
            )
        }
        debugPrint(
            "# FLASH readability.render.start",
            "contentURL=\(flashURLDescription(url))",
            "bytes=\(readabilityContent.utf8.count)",
            "renderSelector=\(renderToSelector ?? "<root>")",
            "frameIsMain=\(frameInfo?.isMainFrame ?? true)"
        )
        let renderBaseURL: URL
        let canonicalContentURL = url.canonicalReaderContentURL()
        if let scheme = canonicalContentURL.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            renderBaseURL = canonicalContentURL
        } else if canonicalContentURL.absoluteString == "about:blank" {
            renderBaseURL = readerContent.pageURL.canonicalReaderContentURL()
        } else {
            renderBaseURL = canonicalContentURL
        }
        debugPrint(
            "# READER readability.renderBase",
            "contentURL=\(url.absoluteString)",
            "renderBase=\(renderBaseURL.absoluteString)",
            "frameIsMain=\(frameInfo?.isMainFrame ?? true)"
        )
        let renderTarget = renderToSelector ?? "<root>"
        logTrace(.readabilityProcessingStart, url: url, details: "renderTo=\(renderTarget) | frameIsMain=\(frameInfo?.isMainFrame ?? true)")

        if let lastRenderedReadabilityURL,
           pendingKeysMatch(lastRenderedReadabilityURL, url),
           readabilityContent == nil {
            debugPrint("# FLASH readability.render.skipAlreadyRendered", "url=\(url.absoluteString)")
            markReaderModeLoadComplete(for: url)
            return
        }

        if lastFallbackLoaderURL != nil {
            self.lastFallbackLoaderURL = nil
        }

        Task {
            do {
                debugPrint("# FLASH readability.preloadStyles", "url=\(url.absoluteString)")
                try await scriptCaller.evaluateJavaScript("""
                if (document.body) {
                    try {
                        if (document.documentElement) {
                            document.documentElement.style.setProperty('background-color', 'transparent', 'important');
                        }
                        document.body.style.setProperty('background-color', 'transparent', 'important');
                        if (typeof CSS !== 'undefined' && CSS.supports && CSS.supports('content-visibility', 'hidden')) {
                            document.body.style.setProperty('content-visibility', 'hidden');
                        }
                    } catch (_) {}
                }
                """)
            } catch {
                debugPrint("# FLASH readability.preloadStyles.error", error.localizedDescription)
            }
        }

        let asyncWriteStartedAt = Date()
        logTrace(.contentWriteStart, url: url, details: "marking reader defaults")
        try await content.asyncWrite { [weak self] _, content in
            let wasReaderDefault = content.isReaderModeByDefault
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
            if !wasReaderDefault {
                debugPrint(
                    "# NOREADERMODE defaultEnabled",
                    "url=\(url.absoluteString)",
                    "reason=renderReadabilityContent"
                )
            }
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
            let derivedTitle = titleFromReadabilityDocument(doc) ?? titleForDisplay
            await propagateReaderModeDefaults(
                for: url,
                primaryRecord: content,
                readabilityHTML: readabilityContent,
                fallbackTitle: titleForDisplay,
                derivedTitle: derivedTitle
            )
            debugPrint(
                "# READERPERF readerMode.propagateDefaults",
                "url=\(url.absoluteString)"
            )
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
                let pageURL = readerContent.pageURL
                let urlsMatch = url.matchesReaderURL(pageURL)
                debugPrint(
                    "# READERRELOAD showReadabilityContent.enter",
                    "contentURL=\(url.absoluteString)",
                    "pageURL=\(pageURL.absoluteString)",
                    "matches=\(urlsMatch)",
                    "frameIsMain=\(frameInfo?.isMainFrame ?? true)"
                )
                guard urlsMatch else {
                    debugPrint("# READER readability.readerURLMismatch", url, pageURL)
                    print("Readability content URL mismatch", url, pageURL)
                    cancelReaderModeLoad(for: url)
                    return
                }
                if let frameInfo = frameInfo, !frameInfo.isMainFrame {
                    debugPrint("# READER readability.frameInjection", frameInfo)
                    do {
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
                            try {
                                const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.print
                                if (handler && typeof handler.postMessage === "function") {
                                    handler.postMessage({
                                        message: "# WRONGREADERMODE readabilityModeClassAdded",
                                        context: "showReadabilityContent.frameInjected",
                                        windowURL: window.location.href,
                                        pageURL: document.location.href
                                    })
                                }
                            } catch (error) {
                                try { console.log("wrongReaderMode log error", error) } catch (_) {}
                            }
                            try { document.body?.style.removeProperty('content-visibility') } catch (_) {}
                            """
                            ,
                            arguments: [
                                "renderToSelector": renderToSelector ?? "",
                                "html": transformedContent,
                                "insertBytes": transformedContent.utf8.count,
                                "css": Readability.shared.css
                            ], in: frameInfo)
                        debugPrint(
                            "# READERRELOAD showReadabilityContent.frameInjected",
                            "contentURL=\(url.absoluteString)",
                            "frameURL=\(frameInfo.request.url?.absoluteString ?? "<nil>")",
                            "bytes=\(transformedContent.utf8.count)"
                        )
                    } catch {
                        debugPrint(
                            "# READERRELOAD showReadabilityContent.frameInjectFailed",
                            "contentURL=\(url.absoluteString)",
                            "error=\(error.localizedDescription)"
                        )
                        cancelReaderModeLoad(for: url)
                        return
                    }
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
                        "# FLASH readability.navigator.load",
                        "url=\(flashURLDescription(url))",
                        "base=\(flashURLDescription(renderBaseURL))",
                        "bytes=\(transformedBytes)",
                        "frameIsMain=\(frameInfo?.isMainFrame ?? true)"
                    )
                    debugPrint(
                        "# READER readability.navigatorLoad.dispatched",
                        "url=\(url.absoluteString)",
                        "base=\(renderBaseURL.absoluteString)",
                        "bytes=\(transformedBytes)",
                        "elapsed=\(String(format: "%.3f", Date().timeIntervalSince(loadDispatch)))s"
                    )
                    debugPrint(
                        "# READERRELOAD showReadabilityContent.navigatorLoad",
                        "contentURL=\(url.absoluteString)",
                        "baseURL=\(renderBaseURL.absoluteString)",
                        "bytes=\(transformedBytes)",
                        "frameIsMain=\(frameInfo?.isMainFrame ?? true)"
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
                let canonicalURL = url.canonicalReaderContentURL()
                lastRenderedReadabilityURL = canonicalURL
                debugPrint(
                    "# FLASH readerMode.rendered",
                    "url=\(canonicalURL.absoluteString)",
                    "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")"
                )
                let totalRenderElapsed = Date().timeIntervalSince(renderStart)
                debugPrint(
                    "# READERPERF readerMode.render.total",
                    "ts=\(Date().timeIntervalSince1970)",
                    "url=\(canonicalURL.absoluteString)",
                    "elapsed=\(String(format: "%.3f", totalRenderElapsed))s"
                )
                markReaderModeLoadComplete(for: canonicalURL)
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
        if newState.pageURL.isReaderURLLoaderURL {
            debugPrint(
                "# SNIPPETLOAD readerMode.navCommit",
                "pageURL=\(newState.pageURL.absoluteString)",
                "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")",
                "expected=\(expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")"
            )
        }
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
            if let pendingReaderModeURL, pendingKeysMatch(pendingReaderModeURL, committedURL) {
                markReaderModeLoadComplete(for: committedURL)
            }
            if committedURL.isSnippetURL {
                debugPrint(
                    "# SNIPPETLOAD readerMode.syntheticCommit.continue",
                    "loaderURL=\(newState.pageURL.absoluteString)",
                    "contentURL=\(committedURL.absoluteString)"
                )
            } else {
                return
            }
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
            debugPrint(
                "# SNIPPETLOAD snippet.navCommit.continue",
                "pageURL=\(newState.pageURL.absoluteString)",
                "contentURL=\(committedURL.absoluteString)"
            )
        }

        if isLoaderNavigation {
            debugPrint(
                "# READER readerMode.loaderCommit",
                "loaderURL=\(newState.pageURL.absoluteString)",
                "contentURL=\(committedURL.absoluteString)",
                "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")"
            )
            if committedURL.isSnippetURL {
                debugPrint(
                    "# SNIPPETLOAD readerMode.loaderCommit",
                    "loaderURL=\(newState.pageURL.absoluteString)",
                    "contentURL=\(committedURL.absoluteString)",
                    "pending=\(pendingReaderModeURL?.absoluteString ?? "nil")"
                )
            }
        }

        // FIXME: Mokuro? check plugins thing for reader mode url instead of hardcoding methods here
        let isReaderModeVerified = content.isReaderModeByDefault
        try Task.checkCancellation()

        if isLoaderNavigation,
           pendingReaderModeURL == nil,
           let lastRenderedReadabilityURL,
           pendingKeysMatch(lastRenderedReadabilityURL, committedURL) {
            if committedURL.isSnippetURL {
                debugPrint(
                    "# SNIPPETLOAD readerMode.navCommit.skipLoader.override",
                    "loaderURL=\(newState.pageURL.absoluteString)",
                    "contentURL=\(committedURL.absoluteString)"
                )
            } else {
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
            let activeReaderFileManager = readerFileManager ?? ReaderFileManager.shared
            if readerFileManager == nil {
                debugPrint(
                    "# SNIPPETLOAD readerMode.loaderNoFileManager",
                    "pageURL=\(newState.pageURL.absoluteString)",
                    "contentURL=\(committedURL.absoluteString)",
                    "snippet=\(committedURL.isSnippetURL)"
                )
            }
            do {
                logTrace(.htmlFetchStart, url: committedURL, details: readerFileManager == nil ? "readerFileManager fallback" : "readerFileManager available")
                debugPrint(
                    "# READERPERF readerMode.htmlFetch",
                    "stage=start",
                    "url=\(committedURL.absoluteString)",
                    "source=\(readerFileManager == nil ? "readerFileManager fallback" : "readerFileManager")"
                )
                let htmlFetchStartedAt = Date()
                var htmlResult = try await content.htmlToDisplay(readerFileManager: activeReaderFileManager)
                if htmlResult == nil, committedURL.isSnippetURL {
                    let fallbackHTML = content.html
                    debugPrint(
                        "# SNIPPETLOAD htmlFetch.nilFallback",
                        "url=\(committedURL.absoluteString)",
                        "fallbackBytes=\(fallbackHTML?.utf8.count ?? 0)",
                        "hasFallback=\(fallbackHTML != nil)"
                    )
                    htmlResult = fallbackHTML
                }
                let fetchDuration = formattedInterval(Date().timeIntervalSince(htmlFetchStartedAt))
                debugPrint(
                    "# READERPERF readerMode.htmlFetch",
                    "stage=end",
                    "url=\(committedURL.absoluteString)",
                    "source=\(readerFileManager == nil ? "readerFileManager fallback" : "readerFileManager")",
                    "elapsed=\(fetchDuration)"
                )
                let htmlByteCount = htmlResult?.utf8.count ?? 0
                let htmlSource = content.rssContainsFullContent
                    ? "stored-html"
                    : (content.isFromClipboard ? "clipboard" : (content.url.isReaderFileURL ? "reader-file" : "unknown"))
                let isSnippetURL = committedURL.isSnippetURL
                if isSnippetURL {
                    debugPrint(
                        "# SNIPPETLOAD htmlFetch.start",
                        "url=\(committedURL.absoluteString)",
                        "source=\(htmlSource)",
                        "rssFull=\(content.rssContainsFullContent)",
                        "clipboard=\(content.isFromClipboard)"
                    )
                }
                if isSnippetURL {
                    debugPrint(
                        "# SNIPPETLOAD htmlFetch.result",
                        "url=\(committedURL.absoluteString)",
                        "bytes=\(htmlByteCount)",
                        "hasHTML=\(htmlResult != nil)"
                    )
                }
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
                    if isEffectivelyEmpty && isSnippetURL {
                        debugPrint(
                            "# SNIPPETLOAD htmlFetch.emptyBody",
                            "url=\(committedURL.absoluteString)",
                            "bytes=\(htmlByteCount)",
                            "bodyHTMLBytes=\(metrics.bodyHTMLBytes)",
                            "bodyTextBytes=\(metrics.bodyTextBytes)",
                            "hasReadabilityMarkup=\(readabilityMarkersPresent)"
                        )
                        htmlBodyIsEmpty = false
                    } else if isEffectivelyEmpty {
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
                    debugPrint(
                        "# FLASH readerMode.render.clearLastRendered",
                        "url=\(committedURL.absoluteString)",
                        "reason=htmlFetchEmptyBody"
                    )
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
                    let hasReaderModeAvailableFlag = html.range(
                        of: #"data-manabi-reader-mode-available=['"]true['"]"#,
                        options: [.regularExpression, .caseInsensitive]
                    ) != nil
                    var readerModeAvailableForMatchesURL = false
                    if let regex = try? NSRegularExpression(
                        pattern: #"data-manabi-reader-mode-available-for=['"]([^'"]+)['"]"#,
                        options: [.caseInsensitive]
                    ) {
                        let nsHTML = html as NSString
                        let nsRange = NSRange(location: 0, length: nsHTML.length)
                        if let match = regex.firstMatch(in: html, options: [], range: nsRange) {
                            let valueRange = match.range(at: 1)
                            if valueRange.location != NSNotFound,
                               let swiftRange = Range(valueRange, in: html) {
                                let attrValue = String(html[swiftRange])
                                if let attrURL = URL(string: attrValue),
                                   attrURL.matchesReaderURL(committedURL) {
                                    readerModeAvailableForMatchesURL = true
                                }
                            }
                        }
                    }
                    let hasPreprocessedManabiReaderMarkup = hasReaderModeAvailableFlag && readerModeAvailableForMatchesURL
                    let hasNextLoadReadabilityMarker = html.range(of: #"<body.*?data-next-load-is-readability-mode=['\"]true['\"]"#, options: .regularExpression) != nil
                    let hasReadabilityMarkup = hasReadabilityClass || hasReaderContentNode || hasNextLoadReadabilityMarker || hasPreprocessedManabiReaderMarkup
                    let snippetHasReaderContent = isSnippetURL && hasReaderContentNode
                    if snippetHasReaderContent {
                        debugPrint(
                            "# READER snippet.readerContentCached",
                            "url=\(committedURL.absoluteString)",
                            "bytes=\(html.utf8.count)"
                        )
                    }
                    let shouldSwiftReadability = shouldProcessReadabilityInSwift(content: content, url: committedURL)
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
                    if isSnippetURL {
                        debugPrint(
                            "# SNIPPETLOAD snippet.readabilityDecision",
                            "url=\(committedURL.absoluteString)",
                            "hasMarkup=\(hasReadabilityMarkup)",
                            "shouldUse=\(shouldUseReadability)",
                            "swiftEligible=\(shouldSwiftReadability)"
                        )
                    }

                    var didRenderReadability = false
                    if shouldUseReadability {
                        readabilityContent = html
                        debugPrint(
                            "# READER readability.captured",
                            "url=\(committedURL.absoluteString)",
                            "snippet=\(isSnippetURL)",
                            "hasMarkup=\(hasReadabilityMarkup)",
                            "bytes=\(html.utf8.count)"
                        )
                        if isSnippetURL {
                            debugPrint(
                                "# SNIPPETLOAD snippet.readabilitySource",
                                "url=\(committedURL.absoluteString)",
                                "source=cachedMarkup",
                                "bytes=\(html.utf8.count)"
                            )
                        }
                        didRenderReadability = true
                    } else if shouldSwiftReadability {
                        let minChars = max(content.meaningfulContentMinLength, 1)
                        let swiftOutcome = await processReadabilityHTMLInSwift(
                            html: html,
                            url: committedURL,
                            meaningfulContentMinChars: minChars
                        )
                        switch swiftOutcome {
                        case .success(let result):
                            readabilityContent = result.outputHTML
                            readabilityPublishedTime = result.publishedTime
                            readabilityContainerSelector = nil
                            readabilityContainerFrameInfo = nil
                            debugPrint(
                                "# READER readability.swift.captured",
                                "url=\(committedURL.absoluteString)",
                                "snippet=\(isSnippetURL)",
                                "bytes=\(result.outputHTML.utf8.count)"
                            )
                            if isSnippetURL {
                                debugPrint(
                                    "# SNIPPETLOAD snippet.readabilitySource",
                                    "url=\(committedURL.absoluteString)",
                                    "source=swift",
                                    "bytes=\(result.outputHTML.utf8.count)"
                                )
                            }
                            do {
                                if !content.isReaderModeAvailable {
                                    try await content.asyncWrite { _, record in
                                        record.isReaderModeAvailable = true
                                        record.refreshChangeMetadata(explicitlyModified: true)
                                    }
                                }
                            } catch {
                                debugPrint("# READER readability.swift.availableUpdate.error", error.localizedDescription)
                            }
                            didRenderReadability = true
                        case .unavailable(let reason):
                            debugPrint(
                                "# READER readability.swift.unavailable",
                                "url=\(committedURL.absoluteString)",
                                "reason=\(reason)"
                            )
                            readabilityContent = nil
                            readabilityPublishedTime = nil
                            html = prepareHTMLForDirectLoad(html)
                        case .failed(let reason):
                            debugPrint(
                                "# READER readability.swift.failed",
                                "url=\(committedURL.absoluteString)",
                                "reason=\(reason)"
                            )
                            readabilityContent = nil
                            readabilityPublishedTime = nil
                            html = prepareHTMLForDirectLoad(html)
                        }
                    } else {
                        if isSnippetURL {
                            debugPrint(
                                "# READER snippet.readabilityBypass",
                                "url=\(committedURL.absoluteString)",
                                "reason=missingReadabilityMarkup"
                            )
                            debugPrint(
                                "# SNIPPETLOAD snippet.readabilitySource",
                                "url=\(committedURL.absoluteString)",
                                "source=bypass"
                            )
                            debugPrint(
                                "# SNIPPETLOAD snippet.directFallback",
                                "url=\(committedURL.absoluteString)",
                                "reason=missingReadabilityMarkup"
                            )
                            html = prepareHTMLForDirectLoad(html)
                        } else {
                            html = prepareHTMLForNextReaderLoad(html)
                        }
                    }

                    if didRenderReadability {
                        let details = "hasReadabilityMarkup=\(hasReadabilityMarkup) | snippet=\(isSnippetURL) | source=\(shouldUseReadability ? "cached" : "swift")"
                        logTrace(.readabilityContentReady, url: committedURL, details: details)
                        if isSnippetURL {
                            debugPrint(
                                "# SNIPPETLOAD snippet.readabilityReady",
                                "url=\(committedURL.absoluteString)",
                                "source=\(shouldUseReadability ? "cached" : "swift")"
                            )
                        }
                        showReaderView(
                            readerContent: readerContent,
                            scriptCaller: scriptCaller
                        )
                        lastFallbackLoaderURL = nil
                    } else {
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
                            if isSnippetURL {
                                debugPrint(
                                    "# SNIPPETLOAD snippet.fallbackLoad",
                                    "url=\(committedURL.absoluteString)",
                                    "bytes=\(htmlData.count)",
                                    "hasBody=\(payloadMetrics.hasBody)",
                                    "bodyHTMLBytes=\(payloadMetrics.bodyHTMLBytes)",
                                    "bodyTextBytes=\(payloadMetrics.bodyTextBytes)"
                                )
                            }
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
        debugPrint("# FLASH readerMode.navFinished", "pageURL=\(newState.pageURL.absoluteString)")
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

        if let deferral = navigationFinishedDeferral(newState: newState) {
            switch deferral {
            case .loader:
                debugPrint("# FLASH readerMode.navFinished.defer.loader", "pageURL=\(newState.pageURL)")
            case .synthetic(let pendingURL, let expectedURL):
                debugPrint(
                    "# FLASH readerMode.navFinished.defer.synthetic",
                    "pageURL=\(newState.pageURL)",
                    "pending=\(pendingURL)",
                    "expected=\(expectedURL)"
                )
            case .pending(let pendingURL):
                debugPrint(
                    "# FLASH readerMode.navFinished.defer.pending",
                    "pageURL=\(newState.pageURL.absoluteString)",
                    "pending=\(pendingURL.absoluteString)",
                    "expected=\(expectedSyntheticReaderLoaderURL?.absoluteString ?? "nil")",
                    "isReaderModeLoading=\(isReaderModeLoading)"
                )
            }
            return
        }

        let pendingMatchesPage: Bool = {
            guard let pendingReaderModeURL else { return false }

            let pendingKey = normalizedPendingMatchKey(for: pendingReaderModeURL)
            let pendingLoaderKey = normalizedPendingMatchKey(for: ReaderContentLoader.readerLoaderURL(for: pendingReaderModeURL))
            let pageKey = normalizedPendingMatchKey(for: newState.pageURL)
            let pageLoaderKey = normalizedPendingMatchKey(for: ReaderContentLoader.readerLoaderURL(for: newState.pageURL))

            if let pendingKey {
                if pendingKey == pageKey || pendingKey == pageLoaderKey { return true }
            }
            if let pendingLoaderKey {
                if pendingLoaderKey == pageKey || pendingLoaderKey == pendingKey { return true }
            }
            return false
        }()

        if pendingMatchesPage, let pendingReaderModeURL {
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

    private enum NavigationFinishedDeferral {
        case loader
        case synthetic(pendingURL: URL, expectedURL: URL)
        case pending(pendingURL: URL)
    }

    // Keep navigation-finished side effects lightweight: reader-mode completion should be
    // driven by the readability render pipeline, not intermediate trampoline navigations.
    private func navigationFinishedDeferral(newState: WebViewState) -> NavigationFinishedDeferral? {
        guard let pendingReaderModeURL else { return nil }

        // Loader navigation finishing is NOT reader-mode completion.
        // The loader is a trampoline; completion should be driven by:
        //  - readability.showReaderView → showReadabilityContent → navigator synthetic commit, OR
        //  - the final content URL flow.
        if newState.pageURL.isReaderURLLoaderURL {
            return .loader
        }

        if let expectedSyntheticReaderLoaderURL {
            return .synthetic(pendingURL: pendingReaderModeURL, expectedURL: expectedSyntheticReaderLoaderURL)
        }

        // If we're still in the pre-render phase, navigation finishing is a prerequisite
        // for readability, not completion.
        if !hasRenderedReadabilityContent {
            return .pending(pendingURL: pendingReaderModeURL)
        }

        return nil
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
        guard isReaderMode || isReaderModeLoading else { return }
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
    var updatedHTML: String
    let preloadBodyInlineStyle = "content-visibility: hidden;"

    if html.range(of: "<body", options: .caseInsensitive) != nil {
        updatedHTML = html
    } else {
        // Ensure a valid body exists so downstream Readability sees content.
        return """
        <html>
        <head></head>
        <body style='\(preloadBodyInlineStyle)'>
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
        if existingStyle.range(of: "content-visibility", options: .caseInsensitive) == nil,
           existingStyle.range(of: "visibility", options: .caseInsensitive) == nil,
           existingStyle.range(of: "opacity", options: .caseInsensitive) == nil {
            let prefix = nsHTML.substring(with: styleMatch.range(at: 1))
            let suffix = nsHTML.substring(with: styleMatch.range(at: 3))
            let newStyle = "\(preloadBodyInlineStyle) \(existingStyle)"
            let replacement = prefix + newStyle + suffix
            updatedHTML = nsHTML.replacingCharacters(in: styleMatch.range, with: replacement)
        }
    } else {
        updatedHTML = updatedHTML.replacingOccurrences(of: "<body", with: "<body style='\(preloadBodyInlineStyle)'", options: .caseInsensitive)
    }

    return updatedHTML
}

private func prepareHTMLForDirectLoad(_ html: String) -> String {
    var updatedHTML = html
    let markerPatterns = [
        #"data-next-load-is-readability-mode=['\"][^'"]*['\"]"#,
        #"data-manabi-reader-mode-available=['\"][^'"]*['\"]"#,
        #"data-manabi-reader-mode-available-for=['\"][^'"]*['\"]"#
    ]
    for pattern in markerPatterns {
        updatedHTML = updatedHTML.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }

    if updatedHTML.range(of: "<body", options: .caseInsensitive) == nil {
        return """
        <html>
        <head></head>
        <body>
        \(updatedHTML)
        </body>
        </html>
        """
    }
    return updatedHTML
}

private enum SwiftReadabilityProcessingOutcome {
    case success(SwiftReadabilityProcessingResult)
    case unavailable(reason: String)
    case failed(reason: String)
}

private struct SwiftReadabilityProcessingResult {
    let outputHTML: String
    let publishedTime: String?
    let sanitizedContentBytes: Int
}

private func shouldProcessReadabilityInSwift(
    content: any ReaderContentProtocol,
    url: URL
) -> Bool {
    if url.isEBookURL || url.isNativeReaderView {
        return false
    }
    let scheme = url.scheme?.lowercased() ?? ""
    if scheme == "blob" || scheme == "ebook" || scheme == "ebook-url" {
        return false
    }
    return content.rssContainsFullContent || content.isFromClipboard || url.isReaderFileURL || url.isSnippetURL
}

@ReaderViewModelActor
private func processReadabilityHTMLInSwift(
    html: String,
    url: URL,
    meaningfulContentMinChars: Int
) async -> SwiftReadabilityProcessingOutcome {
    let normalizedURL = url.canonicalReaderContentURL()
    guard canHaveReadabilityContent(for: normalizedURL) else {
        return .unavailable(reason: "excludedDomainOrProtocol")
    }
    guard !normalizedURL.isEBookURL else {
        return .unavailable(reason: "ebookURL")
    }
    let normalizedHTML = ensureReadabilityBodyExists(html)
    let options = SwiftReadability.ReadabilityOptions(
        charThreshold: max(meaningfulContentMinChars, 1),
        classesToPreserve: readabilityClassesToPreserve
    )
    let parser = SwiftReadability.Readability(html: normalizedHTML, url: normalizedURL, options: options)
    guard let result = try? parser.parse() else {
        return .failed(reason: "parseReturnedNil")
    }
    if !result.readerable {
        debugPrint(
            "# READER readability.swift.readerableFalse",
            "url=\(normalizedURL.absoluteString)",
            "length=\(result.length)"
        )
        return .unavailable(reason: "readerableFalse")
    }
    let rawContent = result.content
    guard !rawContent.isEmpty else {
        return .failed(reason: "emptyContent")
    }
    let rawTitle = stripTemplateTagsForSanitize(result.title ?? "")
    let rawByline = stripTemplateTagsForSanitize(result.byline ?? "")
    let rawContentForSanitize = stripTemplateTagsForSanitize(rawContent)
    let title = SwiftDOMPurify.DOMPurify.sanitize(rawTitle)
    let byline = SwiftDOMPurify.DOMPurify.sanitize(rawByline)
    let content = SwiftDOMPurify.DOMPurify.sanitize(rawContentForSanitize)
    let outputHTML = buildReadabilityHTML(
        title: title,
        byline: byline,
        publishedTime: result.publishedTime,
        content: content,
        contentURL: normalizedURL
    )
    let contentBytes = content.utf8.count
    if contentBytes == 0 {
        return .failed(reason: "emptySanitizedContent")
    }
    return .success(
        SwiftReadabilityProcessingResult(
            outputHTML: outputHTML,
            publishedTime: result.publishedTime,
            sanitizedContentBytes: contentBytes
        )
    )
}

private func canHaveReadabilityContent(for url: URL) -> Bool {
    let scheme = url.scheme?.lowercased()
    if scheme == "about" {
        return false
    }
    if scheme == "https", let host = url.host?.lowercased(), readabilityExcludedDomains.contains(host) {
        return false
    }
    if url.absoluteString.hasPrefix("ebook://") {
        return false
    }
    return true
}

private func ensureReadabilityBodyExists(_ html: String) -> String {
    if html.range(of: "<body", options: .caseInsensitive) != nil {
        return html
    }
    return """
    <html>
    <head></head>
    <body>
    \(html)
    </body>
    </html>
    """
}

private func stripTemplateTagsForSanitize(_ html: String) -> String {
    guard html.range(of: "<template", options: .caseInsensitive) != nil else {
        return html
    }
    return html.replacingOccurrences(
        of: #"(?is)<template\b[^>]*>.*?</template>"#,
        with: "",
        options: .regularExpression
    )
}

private func buildReadabilityHTML(
    title: String,
    byline: String,
    publishedTime: String?,
    content: String,
    contentURL: URL
) -> String {
    let normalizedByline = normalizeBylineText(byline)
    let hasByline = !normalizedByline.isEmpty
    let viewOriginal = isInternalReaderURL(contentURL) ? "" : "<a class=\"reader-view-original\">View Original</a>"
    let bylineLine = hasByline
        ? "<div id=\"reader-byline-line\" class=\"byline-line\"><span class=\"byline-label\">By</span> <span id=\"reader-byline\" class=\"byline\">\(normalizedByline)</span></div>"
        : ""
    let metaLine = "<div id=\"reader-meta-line\" class=\"byline-meta-line\"><span id=\"reader-publication-date\"></span>\(viewOriginal.isEmpty ? "" : "<span class=\"reader-meta-divider\"></span>\(viewOriginal)")</div>"
    let css = Readability.shared.css
    let scripts = Readability.shared.scripts
    let availabilityAttributes = "data-manabi-reader-mode-available=\"true\" data-manabi-reader-mode-available-for=\"\(escapeHTMLAttribute(contentURL.absoluteString))\""
    let documentReadyScript = """
    (function () {
        function logDocumentState(reason) {
            try {
                const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.print
                if (!handler || typeof handler.postMessage !== "function") {
                    return
                }
                const readerContent = document.getElementById("reader-content")
                const payload = {
                    message: "# READER snippetLoader.documentReady",
                    reason: reason,
                    bodyHTMLBytes: document.body && typeof document.body.innerHTML === "string" ? document.body.innerHTML.length : 0,
                    bodyTextBytes: document.body && typeof document.body.textContent === "string" ? document.body.textContent.length : 0,
                    hasReaderContent: !!readerContent,
                    readerContentHTMLBytes: readerContent && typeof readerContent.innerHTML === "string" ? readerContent.innerHTML.length : 0,
                    readerContentTextBytes: readerContent && typeof readerContent.textContent === "string" ? readerContent.textContent.length : 0,
                    readerContentPreview: readerContent && typeof readerContent.textContent === "string" ? readerContent.textContent.slice(0, 240) : null,
                    windowURL: window.location.href,
                    pageURL: document.location.href
                }
                handler.postMessage(payload)
            } catch (error) {
                try {
                    console.log("snippetLoader.documentReady log error", error)
                } catch (_) {}
            }
        }
        if (document.readyState === "complete" || document.readyState === "interactive") {
            logDocumentState("immediate")
        } else {
            document.addEventListener("DOMContentLoaded", function () {
                logDocumentState("domcontentloaded")
            }, { once: true })
        }
    })();
    """
    let escapedTitle = title
    let escapedContent = content
    return """
    <!DOCTYPE html>
    <html>
        <head>
            <meta content="text/html; charset=UTF-8" http-equiv="content-type">
            <meta name="viewport" content="width=device-width, user-scalable=no, minimum-scale=1.0, maximum-scale=1.0, initial-scale=1.0">
            <meta name="referrer" content="never">
            <style id='swiftuiwebview-readability-styles'>
                \(css)
            </style>
            <title>\(escapedTitle)</title>
        </head>

        <body class="readability-mode" \(availabilityAttributes)>
            <div id="reader-header" class="header">
                <h1 id="reader-title">\(escapedTitle)</h1>
                <div id="reader-byline-container">
                    \(bylineLine)
                    \(metaLine)
                </div>
            </div>
            <div id="reader-content">
                \(escapedContent)
            </div>
            <script>
                \(scripts)
            </script>
            <script>
                \(documentReadyScript)
            </script>
        </body>
    </html>
    """
}

private func normalizeBylineText(_ rawByline: String) -> String {
    let trimmed = rawByline.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    let nsByline = trimmed as NSString
    let range = NSRange(location: 0, length: nsByline.length)
    let stripped = readabilityBylinePrefixRegex.stringByReplacingMatches(
        in: trimmed,
        options: [],
        range: range,
        withTemplate: ""
    )
    let cleaned = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? trimmed : cleaned
}

private func isInternalReaderURL(_ url: URL) -> Bool {
    return url.scheme == "internal" && url.host == "local"
}

private func escapeHTMLAttribute(_ raw: String) -> String {
    let settings = OutputSettings().escapeMode(Entities.EscapeMode.extended).charset(String.Encoding.utf8)
    let escaped = Entities.escape(raw, settings)
    return escaped.replacingOccurrences(of: "\"", with: "&quot;")
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
    fallbackTitle: String?,
    derivedTitle: String? = nil
) async {
    let primaryKey = primaryRecord.compoundKey
    let resolvedTitle = derivedTitle ?? titleFromReadabilityHTML(readabilityHTML) ?? fallbackTitle
    _ = await Task { @RealmBackgroundActor in
        do {
            let relatedRecords = try await ReaderContentLoader.loadAll(url: url)
            for record in relatedRecords {
                guard record.compoundKey != primaryKey, let realm = record.realm else { continue }
                try await realm.asyncWrite {
                    let wasReaderDefault = record.isReaderModeByDefault
                    record.isReaderModeByDefault = true
                    record.isReaderModeAvailable = false
                    if !url.isEBookURL && !url.isFileURL && !url.isNativeReaderView {
                        if !url.isReaderFileURL && (record.content?.isEmpty ?? true) {
                            record.html = readabilityHTML
                        }
                        if let resolvedTitle,
                           record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            record.title = resolvedTitle
                        }
                        record.rssContainsFullContent = true
                    }
                    record.refreshChangeMetadata(explicitlyModified: true)
                    if !wasReaderDefault {
                        debugPrint(
                            "# NOREADERMODE defaultEnabled",
                            "url=\(url.absoluteString)",
                            "reason=propagateReaderModeDefaults",
                            "recordURL=\(record.url.absoluteString)"
                        )
                    }
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
    if let doc = try? SwiftSoup.parse(html),
       let title = titleFromReadabilityDocument(doc) {
        return title
    }

    // Final fallback: strip markup and grab the first line as before.
    func normalisedTitle(_ raw: String?) -> String? {
        let trimmed = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.truncate(36)
    }
    let stripped = html.strippingHTML().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !stripped.isEmpty else { return nil }
    let candidate = stripped.components(separatedBy: "\n").first ?? stripped
    return normalisedTitle(candidate)
}

internal func titleFromReadabilityDocument(_ doc: SwiftSoup.Document) -> String? {
    func normalisedTitle(_ raw: String?) -> String? {
        let trimmed = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.truncate(36)
    }

    // Prefer semantic title hints in the readability HTML.
    if let readerTitleText = try? doc.getElementById("reader-title")?.text(),
       let title = normalisedTitle(readerTitleText) {
        return title
    }

    if let headingText = try? doc.getElementsByTag("h1").first()?.text(),
       let title = normalisedTitle(headingText) {
        return title
    }

    if let headTitle = try? doc.title(),
       let title = normalisedTitle(headTitle) {
        return title
    }

    // Avoid pulling the full article body into the title by skipping the main
    // content container before falling back to the body text.
    if let body = doc.body(),
       let bodyText = bodyTextExcludingReaderContent(from: body),
       let title = normalisedTitle(bodyText) {
        return title
    }
    return nil
}

private func bodyTextExcludingReaderContent(from body: SwiftSoup.Element) -> String? {
    let children = body.children().array()
    guard !children.isEmpty else {
        return try? body.text()
    }

    var candidates: [String] = []
    candidates.reserveCapacity(children.count)
    for child in children {
        if (try? child.attr("id")) == "reader-content" { continue }
        if (try? child.getElementById("reader-content")) != nil { continue }
        let text = (try? child.text())?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let text, !text.isEmpty {
            candidates.append(text)
        }
    }
    if candidates.isEmpty {
        return try? body.text()
    }
    return candidates.joined(separator: " ")
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
                    .filter {
                        let lowercased = $0.lowercased()
                        if lowercased.hasPrefix("content-visibility") { return false }
                        if lowercased.hasPrefix("visibility") { return false }
                        if lowercased.hasPrefix("opacity") { return false }
                        return !$0.isEmpty
                    }
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
