import SwiftUI
import RealmSwift
import LakeKit
import SwiftUIPageTurn
import SwiftUIWebView
import WebKit
import SwiftSoup
import Combine
import RealmSwiftGaps
import LakeOfFireCore
import LakeOfFireAdblock
import LakeOfFireContent
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

fileprivate struct ThemeModifier: ViewModifier {
    @AppStorage("readerFontSize") internal var readerFontSize: Double?
    @AppStorage("lightModeTheme") var lightModeTheme: LightModeTheme = .white
    @AppStorage("darkModeTheme") var darkModeTheme: DarkModeTheme = .black
    @EnvironmentObject var scriptCaller: WebViewScriptCaller

    private func updateTrackingSettingsKey(reason: String) async {
        guard scriptCaller.hasAsyncCaller else {
            debugPrint("# READER paginationSettingsKey.set.skip", "reason=\(reason)", "key=<nil>", "info=no asyncCaller")
            return
        }
        let key = "pagination-size:v1|font:\(readerFontSize ?? 0)|light:\(lightModeTheme.rawValue)|dark:\(darkModeTheme.rawValue)"
        do {
            try await scriptCaller.evaluateJavaScript(
                "window.paginationTrackingSettingsKey = '" + key + "';",
                duplicateInMultiTargetFrames: true
            )
            debugPrint("# READER paginationSettingsKey.set", "reason=\(reason)", "key=\(key)")
        } catch {
            debugPrint("# READER paginationSettingsKey.set.error", error.localizedDescription)
        }
    }

    private func requestGeometryBake(reason: String) async {
        do {
            try await scriptCaller.evaluateJavaScript("window.reader?.view?.renderer?.requestTrackingSectionGeometryBake?.({ reason: '\(reason)', restoreLocation: true, immediate: true });", duplicateInMultiTargetFrames: true)
        } catch {
            print("Geometry bake request failed: \(error)")
        }
    }
    
    private func applyFontSize(_ size: Double, reason: String) async {
        guard scriptCaller.hasAsyncCaller else {
            debugPrint("# READER paginationSettingsKey.set.skip", "reason=\(reason)", "key=<nil>", "info=no asyncCaller")
            return
        }
        do {
            try await scriptCaller.evaluateJavaScript("document.body.style.fontSize = '\(size)px';", duplicateInMultiTargetFrames: true)
            await updateTrackingSettingsKey(reason: "font-size-change")
            await requestGeometryBake(reason: reason)
        } catch {
            print("Font size update failed: \(error)")
        }
    }
    
    func body(content: Content) -> some View {
        content
            .task(id: lightModeTheme) { @MainActor in
                do {
                    try await scriptCaller.evaluateJavaScript("""
                        if (document.body?.getAttribute('data-manabi-light-theme') !== '\(lightModeTheme)') {
                            document.body?.setAttribute('data-manabi-light-theme', '\(lightModeTheme)');
                        }
                        """, duplicateInMultiTargetFrames: true)
                } catch {
                    print("Light theme update failed: \(error)")
                }
                await updateTrackingSettingsKey(reason: "light-theme-change")
                await requestGeometryBake(reason: "light-theme-change")
            }
            .task(id: darkModeTheme) { @MainActor in
                do {
                    try await scriptCaller.evaluateJavaScript("""
                        if (document.body?.getAttribute('data-manabi-dark-theme') !== '\(darkModeTheme)') {
                            document.body?.setAttribute('data-manabi-dark-theme', '\(darkModeTheme)');
                        }
                        """, duplicateInMultiTargetFrames: true)
                } catch {
                    print("Dark theme update failed: \(error)")
                }
                await updateTrackingSettingsKey(reason: "dark-theme-change")
                await requestGeometryBake(reason: "dark-theme-change")
            }
            .task { @MainActor in
                await updateTrackingSettingsKey(reason: "initial")
                if let readerFontSize {
                    await applyFontSize(readerFontSize, reason: "font-size-initial")
                }
            }
            .task(id: readerFontSize) { @MainActor in
                guard let readerFontSize else { return }
                await applyFontSize(readerFontSize, reason: "font-size-change")
            }
    }
}

fileprivate struct PageMetadataModifier: ViewModifier {
    @EnvironmentObject var readerContent: ReaderContent
    @EnvironmentObject var readerViewModel: ReaderViewModel
    
    func body(content: Content) -> some View {
        content
            .task(id: readerViewModel.state.pageImageURL) {
                let pageImageURL = readerViewModel.state.pageImageURL
                guard !readerContent.isReaderProvisionallyNavigating else { return }
                guard let imageURL = pageImageURL,
                      let contentItem = readerContent.content,
                      contentItem.realm != nil else { return }
                let contentURL = contentItem.url
                guard urlsMatchWithoutHash(contentURL, readerViewModel.state.pageURL) else { return }
                Task { @RealmBackgroundActor in
                    let contents = try await ReaderContentLoader.loadAll(url: contentURL)
                    for content in contents where content.imageUrl == nil {
                        try await content.realm?.asyncWrite {
                            content.imageUrl = imageURL
                            content.refreshChangeMetadata(explicitlyModified: true)
                        }
                    }
                }
            }
            .task(id: readerViewModel.state.pageTitle) { @MainActor in
                do {
                    try await readerViewModel.pageMetadataUpdated(title: readerViewModel.state.pageTitle)
                } catch {
                    print("Page metadata update failed: \(error)")
                }
            }
    }
}

fileprivate struct ReaderStateChangeModifier: ViewModifier {
    @EnvironmentObject var readerContent: ReaderContent
    @EnvironmentObject var readerViewModel: ReaderViewModel
    
    func body(content: Content) -> some View {
        content
            .task(id: readerViewModel.state) {
                let state = readerViewModel.state
                let shouldSyncProvisionalFlag: Bool
                if state.isProvisionallyNavigating {
                    shouldSyncProvisionalFlag = true
                } else {
                    let urlsMatch = readerContent.pageURL.matchesReaderURL(state.pageURL)
                    || state.pageURL.matchesReaderURL(readerContent.pageURL)
                    shouldSyncProvisionalFlag = urlsMatch || state.pageURL.isNativeReaderView
                }

                if shouldSyncProvisionalFlag,
                   readerContent.isReaderProvisionallyNavigating != state.isProvisionallyNavigating {
                    readerContent.isReaderProvisionallyNavigating = state.isProvisionallyNavigating
                }
                
                // TODO: Improve replaceState support if we need to detect navigation changes without provisional events.
            }
    }
}

fileprivate struct ReaderMediaPlayerViewModifier: ViewModifier {
    @EnvironmentObject var readerMediaPlayerViewModel: ReaderMediaPlayerViewModel
    
    func body(content: Content) -> some View {
        content
            .task(id: readerMediaPlayerViewModel.audioURLs) { @MainActor in
                guard readerMediaPlayerViewModel.playbackSource == .recordedAudio else { return }
                readerMediaPlayerViewModel.isMediaPlayerPresented = !readerMediaPlayerViewModel.audioURLs.isEmpty
            }
    }
}

fileprivate struct ReaderLoadingOverlayModifier: ViewModifier {
    @EnvironmentObject var readerModeViewModel: ReaderModeViewModel
    @EnvironmentObject var readerContent: ReaderContent
    
    func body(content: Content) -> some View {
        let currentCanonicalURL = readerContent.pageURL.canonicalReaderContentURL()
        let pendingCanonicalURL = readerModeViewModel.pendingReaderModeURL?.canonicalReaderContentURL()
        let isSnippet = currentCanonicalURL.isSnippetURL
            || pendingCanonicalURL?.isSnippetURL == true
        content
            // Snippets manage their own overlay; suppress the generic reader-mode spinner for them
            .modifier(
                ReaderLoadingProgressOverlayViewModifier(
                    isLoading: !isSnippet && readerModeViewModel.isReaderModeLoading,
                    context: "ReaderWebView"
                )
            )
    }
}

public struct ReaderPageTurnProbeSnapshot: Equatable {
    public var pageURL: String
    public var requestedEnabled: Bool
    public var structurallyEligible: Bool
    public var activeEnabled: Bool
    public var supportsActivePageTurn: Bool
    public var gestureCaptureEnabled: Bool
    public var gestureCaptureBlockReason: String?
    public var hideNavigationDueToScroll: Bool
    public var pageProgressionDirection: String
    public var phase: String
    public var mountedHostIdentifier: String?
    public var appliedHostIdentifier: String?
    public var liveWebViewIdentifier: String?
    public var interactionKind: String?
    public var interactionQualified: Bool?
    public var interactionDirection: String?
    public var interactionPrimaryAxisDelta: Double?
    public var interactionSecondaryAxisDelta: Double?
    public var interactionProgress: Double?
    public var interactionVelocity: Double?
    public var interactionShouldCommit: Bool?
    public var interactionRefusedOppositeDirectionFlick: Bool?
    public var interactionNote: String?

    public init(
        pageURL: String,
        requestedEnabled: Bool,
        structurallyEligible: Bool,
        activeEnabled: Bool,
        supportsActivePageTurn: Bool,
        gestureCaptureEnabled: Bool,
        gestureCaptureBlockReason: String?,
        hideNavigationDueToScroll: Bool,
        pageProgressionDirection: String,
        phase: String,
        mountedHostIdentifier: String?,
        appliedHostIdentifier: String?,
        liveWebViewIdentifier: String?,
        interactionKind: String?,
        interactionQualified: Bool?,
        interactionDirection: String?,
        interactionPrimaryAxisDelta: Double?,
        interactionSecondaryAxisDelta: Double?,
        interactionProgress: Double?,
        interactionVelocity: Double?,
        interactionShouldCommit: Bool?,
        interactionRefusedOppositeDirectionFlick: Bool?,
        interactionNote: String?
    ) {
        self.pageURL = pageURL
        self.requestedEnabled = requestedEnabled
        self.structurallyEligible = structurallyEligible
        self.activeEnabled = activeEnabled
        self.supportsActivePageTurn = supportsActivePageTurn
        self.gestureCaptureEnabled = gestureCaptureEnabled
        self.gestureCaptureBlockReason = gestureCaptureBlockReason
        self.hideNavigationDueToScroll = hideNavigationDueToScroll
        self.pageProgressionDirection = pageProgressionDirection
        self.phase = phase
        self.mountedHostIdentifier = mountedHostIdentifier
        self.appliedHostIdentifier = appliedHostIdentifier
        self.liveWebViewIdentifier = liveWebViewIdentifier
        self.interactionKind = interactionKind
        self.interactionQualified = interactionQualified
        self.interactionDirection = interactionDirection
        self.interactionPrimaryAxisDelta = interactionPrimaryAxisDelta
        self.interactionSecondaryAxisDelta = interactionSecondaryAxisDelta
        self.interactionProgress = interactionProgress
        self.interactionVelocity = interactionVelocity
        self.interactionShouldCommit = interactionShouldCommit
        self.interactionRefusedOppositeDirectionFlick = interactionRefusedOppositeDirectionFlick
        self.interactionNote = interactionNote
    }

    public var summary: String {
        [
            "pageURL=\(pageURL)",
            "requested=\(requestedEnabled)",
            "eligible=\(structurallyEligible)",
            "active=\(activeEnabled)",
            "supports=\(supportsActivePageTurn)",
            "gestureCaptureEnabled=\(gestureCaptureEnabled)",
            "gestureCaptureBlockReason=\(gestureCaptureBlockReason ?? "nil")",
            "hideNav=\(hideNavigationDueToScroll)",
            "progression=\(pageProgressionDirection)",
            "phase=\(phase)",
            "mountedHost=\(mountedHostIdentifier ?? "nil")",
            "appliedHost=\(appliedHostIdentifier ?? "nil")",
            "liveWebView=\(liveWebViewIdentifier ?? "nil")",
            "interactionKind=\(interactionKind ?? "nil")",
            "interactionQualified=\(interactionQualified.map(String.init) ?? "nil")",
            "interactionDirection=\(interactionDirection ?? "nil")",
            "interactionPrimary=\(interactionPrimaryAxisDelta.map { String(format: "%.3f", $0) } ?? "nil")",
            "interactionSecondary=\(interactionSecondaryAxisDelta.map { String(format: "%.3f", $0) } ?? "nil")",
            "interactionProgress=\(interactionProgress.map { String(format: "%.3f", $0) } ?? "nil")",
            "interactionVelocity=\(interactionVelocity.map { String(format: "%.3f", $0) } ?? "nil")",
            "interactionCommit=\(interactionShouldCommit.map(String.init) ?? "nil")",
            "interactionOppositeFlickRefused=\(interactionRefusedOppositeDirectionFlick.map(String.init) ?? "nil")",
            "interactionNote=\(interactionNote ?? "nil")",
        ].joined(separator: ";")
    }
}

@MainActor
public final class ReaderPageTurnProbeModel: ObservableObject {
    @Published public private(set) var snapshot: ReaderPageTurnProbeSnapshot?
    @Published public private(set) var lastCommandResult: String?

    private var commandHandler: ((ReaderPageTurnProbeCommand) async -> String)?

    public init() {}

    func update(_ snapshot: ReaderPageTurnProbeSnapshot) {
        self.snapshot = snapshot
    }

    func bindCommandHandler(
        _ handler: @escaping (ReaderPageTurnProbeCommand) async -> String
    ) {
        commandHandler = handler
    }

    public func perform(_ command: ReaderPageTurnProbeCommand) async {
        guard let commandHandler else {
            lastCommandResult = "unavailable:noHandler"
            return
        }
        lastCommandResult = await commandHandler(command)
    }
}

private struct ReaderPageTurnProbeModelKey: EnvironmentKey {
    static let defaultValue: ReaderPageTurnProbeModel? = nil
}

public extension EnvironmentValues {
    var readerPageTurnProbeModel: ReaderPageTurnProbeModel? {
        get { self[ReaderPageTurnProbeModelKey.self] }
        set { self[ReaderPageTurnProbeModelKey.self] = newValue }
    }
}

public enum ReaderPageTurnProbeCommand: String, CaseIterable, Sendable, Identifiable {
    case hostForwardTurn
    case hostBackwardTurn

    public var id: String { rawValue }
}

public struct ReaderPageTurnInteractionContext: Equatable, Sendable {
    public var lookupPresented: Bool
    public var mediaPresented: Bool
    public var hasSelection: Bool

    public init(
        lookupPresented: Bool = false,
        mediaPresented: Bool = false,
        hasSelection: Bool = false
    ) {
        self.lookupPresented = lookupPresented
        self.mediaPresented = mediaPresented
        self.hasSelection = hasSelection
    }

    public var blocksGestureCapture: Bool {
        blockingReason != nil
    }

    public var blockingReason: String? {
        if hasSelection {
            return "selection"
        }
        if lookupPresented {
            return "lookup"
        }
        if mediaPresented {
            return "media"
        }
        return nil
    }
}

private struct ReaderPageTurnInteractionContextKey: EnvironmentKey {
    static let defaultValue = ReaderPageTurnInteractionContext()
}

public extension EnvironmentValues {
    var readerPageTurnInteractionContext: ReaderPageTurnInteractionContext {
        get { self[ReaderPageTurnInteractionContextKey.self] }
        set { self[ReaderPageTurnInteractionContextKey.self] = newValue }
    }
}

private struct ReaderResolvedPaginationModeKey: EnvironmentKey {
    static let defaultValue: WebViewPaginationMode? = nil
}

public extension EnvironmentValues {
    var readerResolvedPaginationMode: WebViewPaginationMode? {
        get { self[ReaderResolvedPaginationModeKey.self] }
        set { self[ReaderResolvedPaginationModeKey.self] = newValue }
    }
}

fileprivate struct ReaderPageTurnNavigationProbe {
    var hasView: Bool
    var hasRenderer: Bool
    var canNext: Bool
    var canPrev: Bool
    var canForward: Bool
    var canBackward: Bool
    var hasSectionLayoutController: Bool
    var bookDirection: String?
    var isRightToLeft: Bool
    var isVertical: Bool
    var isVerticalRightToLeft: Bool

    var resolvedPaginationMode: WebViewPaginationMode {
        if isVertical {
            return isVerticalRightToLeft ? .rightToLeft : .leftToRight
        }
        return isRightToLeft ? .rightToLeft : .leftToRight
    }

    var pageProgressionDirection: PageTurnPageProgressionDirection {
        resolvedPaginationMode == .rightToLeft ? .rightToLeft : .leftToRight
    }
}

@MainActor
fileprivate func readerPageTurnObject(_ value: Any?) -> [String: Any]? {
    if let dictionary = value as? [String: Any] {
        return dictionary
    }
    if let dictionary = value as? NSDictionary {
        return dictionary as? [String: Any]
    }
    return nil
}

@MainActor
fileprivate func readerPageTurnBool(_ value: Any?, default fallback: Bool = false) -> Bool {
    if let value = value as? Bool {
        return value
    }
    if let value = value as? NSNumber {
        return value.boolValue
    }
    return fallback
}

@MainActor
fileprivate func captureReaderPageTurnSnapshot(
    from webView: WKWebView,
    contentRect: CGRect
) async -> PageTurnPlatformImage? {
    let bounds = webView.bounds
    var rect = contentRect.integral
    if rect.isNull || rect.isEmpty {
        rect = bounds.integral
    } else {
        rect = rect.intersection(bounds).integral
    }
    if rect.isNull || rect.isEmpty {
        rect = bounds.integral
    }

    let configuration = WKSnapshotConfiguration()
    configuration.afterScreenUpdates = false
    configuration.rect = rect

    return await withCheckedContinuation { continuation in
        webView.takeSnapshot(with: configuration) { image, _ in
            continuation.resume(returning: image)
        }
    }
}

fileprivate struct ReaderPageTurnTurnEvent: Equatable {
    enum Kind: String, Equatable {
        case committed
        case cancelled
    }

    var serial: Int
    var kind: Kind
    var direction: PageTurnDirection
}

@MainActor
fileprivate final class ReaderPageTurnBridge: ObservableObject, PageTurnSnapshotProvider, PageTurnTurnDriver, @unchecked Sendable {
    @Published private(set) var supportsActivePageTurn = false
    @Published private(set) var pageProgressionDirection: PageTurnPageProgressionDirection = .leftToRight
    @Published private(set) var resolvedPaginationMode: WebViewPaginationMode = .leftToRight
    @Published private(set) var lastTurnEvent: ReaderPageTurnTurnEvent?

    private var navigator: WebViewNavigator?
    private var scriptCaller: WebViewScriptCaller?
    private var lastKnownState: WebViewState = .empty
    private var capabilityRefreshTask: Task<Void, Never>?
    private var lastCapabilityKey: String?
    private var nextTurnEventSerial = 0

    deinit {
        capabilityRefreshTask?.cancel()
    }

    func updateContext(
        navigator: WebViewNavigator,
        scriptCaller: WebViewScriptCaller,
        webViewState: WebViewState,
        isEligibleForActiveTurns: Bool
    ) {
        self.navigator = navigator
        self.scriptCaller = scriptCaller
        self.lastKnownState = webViewState

        guard isEligibleForActiveTurns, scriptCaller.hasAsyncCaller else {
            capabilityRefreshTask?.cancel()
            capabilityRefreshTask = nil
            lastCapabilityKey = nil
            supportsActivePageTurn = false
            pageProgressionDirection = .leftToRight
            resolvedPaginationMode = .leftToRight
            return
        }

        let paginationState = webViewState.paginationState
        let nextKey = [
            webViewState.pageURL.absoluteString,
            paginationState?.appliedHostIdentifier ?? "nil",
            paginationState?.mountedHostIdentifier ?? "nil",
            paginationState.map { String($0.appliedConfiguration?.mode.rawValue ?? -1) } ?? "nil",
            paginationState?.pageCount.map(String.init) ?? "nil",
            navigator.hasAttachedWebView ? "attached" : "detached",
        ].joined(separator: "|")

        guard nextKey != lastCapabilityKey else { return }
        lastCapabilityKey = nextKey

        capabilityRefreshTask?.cancel()
        capabilityRefreshTask = Task { [weak self] in
            guard let self else { return }
            let probe = await self.fetchNavigationProbe()
            guard !Task.isCancelled else { return }
            supportsActivePageTurn = probe?.supportsActivePageTurn ?? false
            pageProgressionDirection = probe?.pageProgressionDirection ?? .leftToRight
            resolvedPaginationMode = probe?.resolvedPaginationMode ?? .leftToRight
        }
    }

    func destinationAvailability(for direction: PageTurnDirection) async -> PageTurnDestinationAvailability {
        guard supportsActivePageTurn,
              let probe = await fetchNavigationProbe() else {
            return .unavailable
        }
        let isAvailable = switch direction {
        case .forward:
            probe.canForward
        case .backward:
            probe.canBackward
        }
        return isAvailable ? .both : .unavailable
    }

    func commitTurn(_ direction: PageTurnDirection) async throws {
        guard supportsActivePageTurn, let scriptCaller else { return }

        let script: String
        switch direction {
        case .forward:
            script = """
            (async () => {
              const view = globalThis.reader?.view;
              if (!view || typeof view.next !== 'function') {
                return false;
              }
              await view.next();
              return true;
            })()
            """
        case .backward:
            script = """
            (async () => {
              const view = globalThis.reader?.view;
              if (!view || typeof view.prev !== 'function') {
                return false;
              }
              await view.prev();
              return true;
            })()
            """
        }

        let result = try await scriptCaller.evaluateJavaScript(script)
        guard readerPageTurnBool(result) else { return }
        publishTurnEvent(.committed, direction: direction)
    }

    func cancelTurn(_ direction: PageTurnDirection) async {
        publishTurnEvent(.cancelled, direction: direction)
    }

    func snapshot(for request: PageTurnSnapshotRequest) async throws -> PageTurnSnapshotArtifact {
        let image = await navigator?.withAttachedWebView { webView in
            await captureReaderPageTurnSnapshot(from: webView, contentRect: request.contentRect)
        } ?? nil

        return PageTurnSnapshotArtifact(
            image: image ?? makePlaceholderSnapshotImage(size: request.contentRect.size),
            pageID: lastKnownState.pageURL.absoluteString,
            contentRect: request.contentRect,
            layoutGeneration: request.layoutGeneration,
            includesChrome: request.includeChrome
        )
    }

    private func fetchNavigationProbe() async -> ReaderPageTurnNavigationProbe? {
        guard let scriptCaller, scriptCaller.hasAsyncCaller else { return nil }

        let result = try? await scriptCaller.evaluateJavaScript(
            """
            (async () => {
              const view = globalThis.reader?.view;
              const renderer = view?.renderer;
              const page = typeof renderer?.page === 'function' ? await renderer.page() : null;
              const pageCount = typeof renderer?.pages === 'function' ? await renderer.pages() : null;
              const atSectionStart = typeof renderer?.isAtSectionStart === 'function'
                ? await renderer.isAtSectionStart()
                : null;
              const atSectionEnd = typeof renderer?.isAtSectionEnd === 'function'
                ? await renderer.isAtSectionEnd()
                : null;
              const hasPrevSection = typeof renderer?.getHasPrevSection === 'function'
                ? !!renderer.getHasPrevSection()
                : false;
              const hasNextSection = typeof renderer?.getHasNextSection === 'function'
                ? !!renderer.getHasNextSection()
                : false;
              const canBackward = atSectionStart === true
                ? hasPrevSection
                : (Number.isFinite(page) ? page > 1 || hasPrevSection : false);
              const canForward = atSectionEnd === true
                ? hasNextSection
                : (Number.isFinite(page) && Number.isFinite(pageCount) ? page < pageCount || hasNextSection : false);
              return {
                hasView: !!view,
                hasRenderer: !!renderer,
                canNext: typeof view?.next === 'function',
                canPrev: typeof view?.prev === 'function',
                canForward,
                canBackward,
                hasSectionLayoutController: !!(
                  view?.document?.defaultView?.manabiEbookSectionLayoutController
                  ?? globalThis.manabiEbookSectionLayoutController
                ),
                bookDirection: globalThis.reader?.book?.dir ?? view?.book?.dir ?? null,
                isRightToLeft: !!(
                  globalThis.manabiGetWritingDirectionSnapshot?.()?.rtl
                  ?? ((globalThis.reader?.book?.dir ?? view?.book?.dir ?? '').toLowerCase() === 'rtl')
                ),
                isVertical: globalThis.manabiGetWritingDirectionSnapshot?.()?.vertical === true,
                isVerticalRightToLeft: globalThis.manabiGetWritingDirectionSnapshot?.()?.verticalRTL === true,
              };
            })()
            """
        )

        guard let dictionary = readerPageTurnObject(result) else { return nil }
        return ReaderPageTurnNavigationProbe(
            hasView: readerPageTurnBool(dictionary["hasView"]),
            hasRenderer: readerPageTurnBool(dictionary["hasRenderer"]),
            canNext: readerPageTurnBool(dictionary["canNext"]),
            canPrev: readerPageTurnBool(dictionary["canPrev"]),
            canForward: readerPageTurnBool(dictionary["canForward"]),
            canBackward: readerPageTurnBool(dictionary["canBackward"]),
            hasSectionLayoutController: readerPageTurnBool(dictionary["hasSectionLayoutController"]),
            bookDirection: dictionary["bookDirection"] as? String,
            isRightToLeft: readerPageTurnBool(dictionary["isRightToLeft"]),
            isVertical: readerPageTurnBool(dictionary["isVertical"]),
            isVerticalRightToLeft: readerPageTurnBool(dictionary["isVerticalRightToLeft"])
        )
    }

    private func makePlaceholderSnapshotImage(size: CGSize) -> PageTurnPlatformImage {
        let resolvedSize = CGSize(width: max(size.width, 1), height: max(size.height, 1))
        #if os(macOS)
        let image = NSImage(size: resolvedSize)
        image.lockFocus()
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: resolvedSize)).fill()
        image.unlockFocus()
        return image
        #elseif os(iOS)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: resolvedSize, format: format)
        return renderer.image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(origin: .zero, size: resolvedSize))
        }
        #endif
    }

    private func publishTurnEvent(_ kind: ReaderPageTurnTurnEvent.Kind, direction: PageTurnDirection) {
        nextTurnEventSerial += 1
        lastTurnEvent = ReaderPageTurnTurnEvent(
            serial: nextTurnEventSerial,
            kind: kind,
            direction: direction
        )
    }
}

fileprivate extension ReaderPageTurnNavigationProbe {
    var supportsActivePageTurn: Bool {
        hasView
        && hasRenderer
        && canNext
        && canPrev
        && hasSectionLayoutController
    }
}

@MainActor
fileprivate func readerPageTurnPlatformFamily() -> PageTurnPlatformFamily {
    #if os(macOS)
    return .macOS
    #elseif os(iOS)
    switch UIDevice.current.userInterfaceIdiom {
    case .phone:
        return .iPhone
    default:
        return .iPad
    }
    #endif
}

@MainActor
fileprivate func makeReaderPageTurnLayoutModel() -> PageTurnLayoutModel {
    let platformFamily = readerPageTurnPlatformFamily()
    return PageTurnLayoutModel(
        initialInputs: PageTurnLayoutInputs(
            containerBounds: CGRect(x: 0, y: 0, width: 900, height: 700),
            contentRect: CGRect(x: 80, y: 40, width: 740, height: 620),
            safeAreaInsets: .zero,
            isCompactWidth: false,
            platformFamily: platformFamily,
            appearance: .light,
            chromeVisibility: .init(showTitle: true, showHeader: platformFamily != .iPhone)
        )
    )
}

fileprivate struct ReaderPageTurnIdentitySnapshot: Equatable {
    var requestedEnabled: Bool
    var structurallyEligible: Bool
    var activeEnabled: Bool
    var supportsActivePageTurn: Bool
    var gestureCaptureEnabled: Bool
    var gestureCaptureBlockReason: String?
    var pageURL: String
    var pageProgressionDirection: PageTurnPageProgressionDirection
    var mountedHostIdentifier: String?
    var appliedHostIdentifier: String?
    var isAppliedToMountedHost: Bool
    var navigatorAttached: Bool
    var navigatorObjectID: String
    var liveWebViewIdentifier: String?

    var dictionaryRepresentation: [String: String] {
        [
            "requestedEnabled": "\(requestedEnabled)",
            "structurallyEligible": "\(structurallyEligible)",
            "activeEnabled": "\(activeEnabled)",
            "supportsActivePageTurn": "\(supportsActivePageTurn)",
            "gestureCaptureEnabled": "\(gestureCaptureEnabled)",
            "gestureCaptureBlockReason": gestureCaptureBlockReason ?? "nil",
            "pageURL": pageURL,
            "pageProgressionDirection": pageProgressionDirection.rawValue,
            "mountedHostIdentifier": mountedHostIdentifier ?? "nil",
            "appliedHostIdentifier": appliedHostIdentifier ?? "nil",
            "isAppliedToMountedHost": "\(isAppliedToMountedHost)",
            "navigatorAttached": "\(navigatorAttached)",
            "navigatorObjectID": navigatorObjectID,
            "liveWebViewIdentifier": liveWebViewIdentifier ?? "nil",
        ]
    }
}

@MainActor
fileprivate final class ReaderPageTurnIdentityMonitor: ObservableObject {
    private var previousSnapshot: ReaderPageTurnIdentitySnapshot?

    func record(_ snapshot: ReaderPageTurnIdentitySnapshot) {
        guard ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_IDENTITY_DIAGNOSTIC"] == "1" else {
            previousSnapshot = snapshot
            return
        }

        let previousSnapshot: ReaderPageTurnIdentitySnapshot? = self.previousSnapshot
        self.previousSnapshot = snapshot

        guard previousSnapshot != snapshot else { return }

        debugPrint("# PAGETURN identity", snapshot.dictionaryRepresentation)

        guard let previousSnapshot else { return }

        if previousSnapshot.pageURL == snapshot.pageURL,
           previousSnapshot.navigatorObjectID == snapshot.navigatorObjectID,
           previousSnapshot.liveWebViewIdentifier != nil,
           snapshot.liveWebViewIdentifier != nil,
           previousSnapshot.liveWebViewIdentifier != snapshot.liveWebViewIdentifier {
            debugPrint(
                "# PAGETURN identity.warning",
                [
                    "kind": "liveWebViewChanged",
                    "pageURL": snapshot.pageURL,
                    "previousLiveWebViewIdentifier": previousSnapshot.liveWebViewIdentifier ?? "nil",
                    "nextLiveWebViewIdentifier": snapshot.liveWebViewIdentifier ?? "nil",
                    "previousActiveEnabled": previousSnapshot.activeEnabled,
                    "nextActiveEnabled": snapshot.activeEnabled,
                    "previousMountedHostIdentifier": previousSnapshot.mountedHostIdentifier ?? "nil",
                    "nextMountedHostIdentifier": snapshot.mountedHostIdentifier ?? "nil",
                ] as [String: Any]
            )
        }
    }
}

@MainActor
fileprivate func readerPageTurnStyle() -> PageTurnStyle {
    switch readerPageTurnPlatformFamily() {
    case .macOS:
        return .macOSDefault()
    case .iPhone:
        return .iPhoneDefault(
            displayCornerRadiusProvider: { rect in
                min(rect.width, rect.height) * 0.08
            }
        )
    case .iPad:
        return .iPadDefault(
            displayCornerRadiusProvider: { rect in
                min(rect.width, rect.height) * 0.05
            }
        )
    }
}

fileprivate struct ReaderPageTurnHost<Content: View>: View {
    let requestedEnabled: Bool
    @Binding var hideNavigationDueToScroll: Bool
    let navigationVisibilityCoordinator: ReaderNavigationVisibilityCoordinator
    let probeModel: ReaderPageTurnProbeModel
    let content: Content

    @StateObject private var controller = PageTurnController()
    @StateObject private var layoutModel = makeReaderPageTurnLayoutModel()
    @StateObject private var bridge = ReaderPageTurnBridge()
    @StateObject private var identityMonitor = ReaderPageTurnIdentityMonitor()

    @Environment(\.webViewNavigator) private var navigator
    @Environment(\.readerPageTurnInteractionContext) private var interactionContext
    @EnvironmentObject private var scriptCaller: WebViewScriptCaller
    @EnvironmentObject private var readerViewModel: ReaderViewModel

    init(
        requestedEnabled: Bool,
        hideNavigationDueToScroll: Binding<Bool>,
        navigationVisibilityCoordinator: ReaderNavigationVisibilityCoordinator,
        probeModel: ReaderPageTurnProbeModel,
        @ViewBuilder content: () -> Content
    ) {
        self.requestedEnabled = requestedEnabled
        _hideNavigationDueToScroll = hideNavigationDueToScroll
        self.navigationVisibilityCoordinator = navigationVisibilityCoordinator
        self.probeModel = probeModel
        self.content = content()
    }

    var body: some View {
        content.pageTurn(
            enabled: isActivePageTurnEnabled,
            controller: controller,
            snapshotProvider: bridge,
            turnDriver: bridge,
            layoutModel: layoutModel,
            style: readerPageTurnStyle()
        )
        .environment(\.readerResolvedPaginationMode, bridge.resolvedPaginationMode)
        .task(id: bridgeRefreshKey) {
            bridge.updateContext(
                navigator: navigator,
                scriptCaller: scriptCaller,
                webViewState: readerViewModel.state,
                isEligibleForActiveTurns: isStructurallyEligibleForActiveTurns
            )
            controller.setPageProgressionDirection(bridge.pageProgressionDirection)
        }
        .task(id: bridge.pageProgressionDirection) {
            controller.setPageProgressionDirection(bridge.pageProgressionDirection)
        }
        .task(id: controller.visualState.structuralStateSerial) {
            syncHostNavigationVisibilityForPageTurnPhase()
        }
        .task(id: bridge.lastTurnEvent?.serial) {
            guard let event = bridge.lastTurnEvent else { return }
            switch event.kind {
            case .committed:
                applyHostNavigationVisibility(
                    event.direction == .forward,
                    source: "pageTurnCommit",
                    direction: event.direction
                )
            case .cancelled:
                applyHostNavigationVisibility(
                    false,
                    source: "pageTurnCancel",
                    direction: event.direction
                )
            }
        }
        .task(id: identityDiagnosticKey) {
            let snapshot = await makeIdentitySnapshot()
            identityMonitor.record(snapshot)
        }
        .task(id: probeDiagnosticKey) {
            let snapshot = await makeProbeSnapshot()
            probeModel.update(snapshot)
            logProbeSnapshotIfEnabled(snapshot)
        }
        .task(id: probeCommandBindingKey) {
            probeModel.bindCommandHandler { command in
                await handleProbeCommand(command)
            }
        }
    }

    private var bridgeRefreshKey: String {
        let paginationState = readerViewModel.state.paginationState
        return [
            requestedEnabled ? "requested" : "passThrough",
            readerViewModel.state.pageURL.absoluteString,
            paginationState?.appliedHostIdentifier ?? "nil",
            paginationState?.mountedHostIdentifier ?? "nil",
            paginationState.map { String($0.appliedConfiguration?.mode.rawValue ?? -1) } ?? "nil",
            paginationState?.pageCount.map(String.init) ?? "nil",
            paginationState?.isAppliedToMountedHost == true ? "applied" : "notApplied",
            navigator.hasAttachedWebView ? "attached" : "detached",
        ].joined(separator: "|")
    }

    private var isStructurallyEligibleForActiveTurns: Bool {
        guard requestedEnabled,
              let paginationState = readerViewModel.state.paginationState,
              paginationState.isAppliedToMountedHost else {
            return false
        }
        return true
    }

    private var isActivePageTurnEnabled: Bool {
        isStructurallyEligibleForActiveTurns
            && bridge.supportsActivePageTurn
            && isGestureCaptureEnabled
    }

    private var isGestureCaptureEnabled: Bool {
        !interactionContext.blocksGestureCapture
    }

    private var identityDiagnosticKey: String {
        let paginationState = readerViewModel.state.paginationState
        return [
            readerViewModel.state.pageURL.absoluteString,
            requestedEnabled ? "requested" : "passThrough",
            isStructurallyEligibleForActiveTurns ? "eligible" : "ineligible",
            isActivePageTurnEnabled ? "active" : "inactive",
            bridge.supportsActivePageTurn ? "bridgeReady" : "bridgeBlocked",
            isGestureCaptureEnabled ? "gestureCaptureEnabled" : "gestureCaptureBlocked",
            interactionContext.blockingReason ?? "noBlock",
            bridge.pageProgressionDirection.rawValue,
            paginationState?.mountedHostIdentifier ?? "nil",
            paginationState?.appliedHostIdentifier ?? "nil",
            paginationState?.isAppliedToMountedHost == true ? "applied" : "notApplied",
            navigator.hasAttachedWebView ? "attached" : "detached",
            navigator.debugObjectID,
        ].joined(separator: "|")
    }

    private var probeDiagnosticKey: String {
        let paginationState = readerViewModel.state.paginationState
        return [
            readerViewModel.state.pageURL.absoluteString,
            requestedEnabled ? "requested" : "passThrough",
            isStructurallyEligibleForActiveTurns ? "eligible" : "ineligible",
            isActivePageTurnEnabled ? "active" : "inactive",
            bridge.supportsActivePageTurn ? "bridgeReady" : "bridgeBlocked",
            isGestureCaptureEnabled ? "gestureCaptureEnabled" : "gestureCaptureBlocked",
            interactionContext.blockingReason ?? "noBlock",
            bridge.pageProgressionDirection.rawValue,
            controller.phase.rawValue,
            String(hideNavigationDueToScroll),
            String(controller.lastInteractionEvent?.serial ?? -1),
            paginationState?.mountedHostIdentifier ?? "nil",
            paginationState?.appliedHostIdentifier ?? "nil",
            paginationState?.isAppliedToMountedHost == true ? "applied" : "notApplied",
            navigator.hasAttachedWebView ? "attached" : "detached",
        ].joined(separator: "|")
    }

    private var probeCommandBindingKey: String {
        [
            readerViewModel.state.pageURL.absoluteString,
            requestedEnabled ? "requested" : "passThrough",
            isStructurallyEligibleForActiveTurns ? "eligible" : "ineligible",
            bridge.supportsActivePageTurn ? "bridgeReady" : "bridgeBlocked",
            isGestureCaptureEnabled ? "gestureCaptureEnabled" : "gestureCaptureBlocked",
            interactionContext.blockingReason ?? "noBlock",
        ].joined(separator: "|")
    }

    private func makeIdentitySnapshot() async -> ReaderPageTurnIdentitySnapshot {
        let liveWebViewIdentifier = await navigator.withAttachedWebView { webView in
            String(describing: ObjectIdentifier(webView))
        } ?? nil
        let paginationState = readerViewModel.state.paginationState
        return ReaderPageTurnIdentitySnapshot(
            requestedEnabled: requestedEnabled,
            structurallyEligible: isStructurallyEligibleForActiveTurns,
            activeEnabled: isActivePageTurnEnabled,
            supportsActivePageTurn: bridge.supportsActivePageTurn,
            gestureCaptureEnabled: isGestureCaptureEnabled,
            gestureCaptureBlockReason: interactionContext.blockingReason,
            pageURL: readerViewModel.state.pageURL.absoluteString,
            pageProgressionDirection: bridge.pageProgressionDirection,
            mountedHostIdentifier: paginationState?.mountedHostIdentifier,
            appliedHostIdentifier: paginationState?.appliedHostIdentifier,
            isAppliedToMountedHost: paginationState?.isAppliedToMountedHost == true,
            navigatorAttached: navigator.hasAttachedWebView,
            navigatorObjectID: navigator.debugObjectID,
            liveWebViewIdentifier: liveWebViewIdentifier
        )
    }

    private func makeProbeSnapshot() async -> ReaderPageTurnProbeSnapshot {
        let liveWebViewIdentifier = await navigator.withAttachedWebView { webView in
            String(describing: ObjectIdentifier(webView))
        } ?? nil
        let paginationState = readerViewModel.state.paginationState
        let interaction = controller.lastInteractionEvent
        return ReaderPageTurnProbeSnapshot(
            pageURL: readerViewModel.state.pageURL.absoluteString,
            requestedEnabled: requestedEnabled,
            structurallyEligible: isStructurallyEligibleForActiveTurns,
            activeEnabled: isActivePageTurnEnabled,
            supportsActivePageTurn: bridge.supportsActivePageTurn,
            gestureCaptureEnabled: isGestureCaptureEnabled,
            gestureCaptureBlockReason: interactionContext.blockingReason,
            hideNavigationDueToScroll: hideNavigationDueToScroll,
            pageProgressionDirection: bridge.pageProgressionDirection.rawValue,
            phase: controller.phase.rawValue,
            mountedHostIdentifier: paginationState?.mountedHostIdentifier,
            appliedHostIdentifier: paginationState?.appliedHostIdentifier,
            liveWebViewIdentifier: liveWebViewIdentifier,
            interactionKind: interaction?.kind.rawValue,
            interactionQualified: interaction?.qualified,
            interactionDirection: interaction?.direction?.rawValue,
            interactionPrimaryAxisDelta: interaction.map { Double($0.primaryAxisDelta) },
            interactionSecondaryAxisDelta: interaction.map { Double($0.secondaryAxisDelta) },
            interactionProgress: interaction?.progress.map(Double.init),
            interactionVelocity: interaction?.velocity.map(Double.init),
            interactionShouldCommit: interaction?.shouldCommit,
            interactionRefusedOppositeDirectionFlick: interaction?.refusedOppositeDirectionFlick,
            interactionNote: interaction?.note
        )
    }

    private func logProbeSnapshotIfEnabled(_ snapshot: ReaderPageTurnProbeSnapshot) {
        let processInfo = ProcessInfo.processInfo
        guard processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1"
              || processInfo.arguments.contains("--ui-test-enable-page-turn-probe") else {
            return
        }
        debugPrint("# PAGETURN probe", snapshot.summary)
    }

    private func handleProbeCommand(_ command: ReaderPageTurnProbeCommand) async -> String {
        guard requestedEnabled else {
            return "blocked:notRequested"
        }
        guard isStructurallyEligibleForActiveTurns else {
            return "blocked:paginationInactive"
        }
        guard bridge.supportsActivePageTurn else {
            return "blocked:bridgeUnavailable"
        }
        guard isGestureCaptureEnabled else {
            return "blocked:\(interactionContext.blockingReason ?? "interaction")"
        }

        let direction: PageTurnDirection = switch command {
        case .hostForwardTurn:
            .forward
        case .hostBackwardTurn:
            .backward
        }

        let availability = await bridge.destinationAvailability(for: direction)
        guard availability != .unavailable else {
            return "blocked:destinationUnavailable:\(direction.rawValue)"
        }

        do {
            try await bridge.commitTurn(direction)
            return "committed:\(direction.rawValue)"
        } catch {
            return "error:\(direction.rawValue):\(error.localizedDescription)"
        }
    }

    private func syncHostNavigationVisibilityForPageTurnPhase() {
        guard isActivePageTurnEnabled,
              controller.phase != .idle,
              let direction = controller.visualState.direction else {
            return
        }

        applyHostNavigationVisibility(
            direction == .forward,
            source: "pageTurnPhase:\(controller.phase.rawValue)",
            direction: direction
        )
    }

    private func applyHostNavigationVisibility(
        _ shouldHide: Bool,
        source: String,
        direction: PageTurnDirection?
    ) {
        let directionValue = direction?.rawValue
        navigationVisibilityCoordinator.recordHostPageTurnEvent(
            shouldHide: shouldHide,
            source: source,
            direction: directionValue
        )

        guard hideNavigationDueToScroll != shouldHide else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            hideNavigationDueToScroll = shouldHide
        }
    }
}


public struct Reader: View {
    var forceReaderModeWhenAvailable = false
//    var obscuredInsets: EdgeInsets? = nil
    var bounces = true
    var additionalBottomSafeAreaInset: CGFloat? = nil
    var onAdditionalSafeAreaBarTap: (() -> Void)?
    let schemeHandlers: [(WKURLSchemeHandler, String)]
    let onNavigationCommitted: ((WebViewState) async throws -> Void)?
    let onNavigationFinished: ((WebViewState) -> Void)?
    let onNavigationFailed: ((WebViewState) -> Void)?
    let onURLChanged: ((WebViewState) async throws -> Void)?
    @Binding var hideNavigationDueToScroll: Bool
    @Binding var textSelection: String?
    var buildMenu: BuildMenuType?
    
    @EnvironmentObject private var readerContent: ReaderContent
    @EnvironmentObject private var scriptCaller: WebViewScriptCaller
    @EnvironmentObject private var readerViewModel: ReaderViewModel
    
    @State private var obscuredInsets: EdgeInsets? = nil
    @StateObject private var navigationVisibilityCoordinator = ReaderNavigationVisibilityCoordinator()
    @StateObject private var pageTurnProbeModel = ReaderPageTurnProbeModel()
    
    public init(
        forceReaderModeWhenAvailable: Bool = false,
//        obscuredInsets: EdgeInsets? = nil,
        bounces: Bool = true,
        additionalBottomSafeAreaInset: CGFloat? = nil,
        onAdditionalSafeAreaBarTap: (() -> Void)? = nil,
        schemeHandlers: [(WKURLSchemeHandler, String)] = [],
        onNavigationCommitted: ((WebViewState) async throws -> Void)? = nil,
        onNavigationFinished: ((WebViewState) -> Void)? = nil,
        onNavigationFailed: ((WebViewState) -> Void)? = nil,
        onURLChanged: ((WebViewState) async throws -> Void)? = nil,
        hideNavigationDueToScroll: Binding<Bool> = .constant(false),
        textSelection: Binding<String?>? = nil,
        buildMenu: BuildMenuType? = nil
    ) {
        self.forceReaderModeWhenAvailable = forceReaderModeWhenAvailable
//        self.obscuredInsets = obscuredInsets
        self.bounces = bounces
        self.additionalBottomSafeAreaInset = additionalBottomSafeAreaInset
        self.onAdditionalSafeAreaBarTap = onAdditionalSafeAreaBarTap
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
        let shouldRequestPageTurn = readerContent.pageURL.isEBookURL
            || readerViewModel.state.pageURL.isEBookURL
            || readerContent.content?.url.isEBookURL == true

        let readerHost = ReaderPageTurnHost(
            requestedEnabled: shouldRequestPageTurn,
            hideNavigationDueToScroll: $hideNavigationDueToScroll,
            navigationVisibilityCoordinator: navigationVisibilityCoordinator,
            probeModel: pageTurnProbeModel
        ) {
            ReaderWebView(
                obscuredInsets: obscuredInsets,
                bounces: bounces,
                additionalBottomSafeAreaInset: additionalBottomSafeAreaInset,
                schemeHandlers: schemeHandlers,
                onNavigationCommitted: onNavigationCommitted,
                onNavigationFinished: onNavigationFinished,
                onNavigationFailed: onNavigationFailed,
                onURLChanged: onURLChanged,
                hideNavigationDueToScroll: $hideNavigationDueToScroll,
                textSelection: $textSelection,
                buildMenu: buildMenu
            )
        }
#if os(iOS)
        let readerView = readerHost
            .ignoresSafeArea(.all, edges: .all)
            .modifier {
                if #available(iOS 26, *) {
                    $0.safeAreaBar(edge: .bottom, spacing: 0) {
                        if let additionalBottomSafeAreaInset, additionalBottomSafeAreaInset > 0 {
                            Color.white.opacity(0.0000000001)
                                .frame(height: additionalBottomSafeAreaInset)
                                .onTapGesture {
                                    onAdditionalSafeAreaBarTap?()
                                }
                        }
                    }
                } else { $0 }
            }
#else
        let readerView = readerHost
#endif
        return readerView
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .task { @MainActor in
                            obscuredInsets = geometry.safeAreaInsets
                        }
                        .task(id: geometry.safeAreaInsets) {
                            let safeAreaInsets = geometry.safeAreaInsets
                            obscuredInsets = EdgeInsets(
                                top: max(0, safeAreaInsets.top),
                                leading: max(0, safeAreaInsets.leading),
                                bottom: max(0, safeAreaInsets.bottom),
                                trailing: max(0, safeAreaInsets.trailing)
                            )
                        }
                }
            }
            .modifier(ReaderLoadingOverlayModifier())
            .environment(\.readerPageTurnProbeModel, pageTurnProbeModel)
            .modifier(
                ReaderMessageHandlersViewModifier(
                    forceReaderModeWhenAvailable: forceReaderModeWhenAvailable,
                    hideNavigationDueToScroll: $hideNavigationDueToScroll,
                    navigationVisibilityCoordinator: navigationVisibilityCoordinator
                )
            )
            .modifier(ReaderStateChangeModifier())
            .modifier(ThemeModifier())
            .modifier(PageMetadataModifier())
            .modifier(ReaderMediaPlayerViewModifier())
            .onReceive(readerContent.contentTitleSubject.receive(on: RunLoop.main)) { _ in
                Task { @MainActor in
                    guard scriptCaller.hasAsyncCaller else { return }
                    let displayTitle = readerContent.content?.titleForDisplay ?? readerContent.contentTitle
                    guard !displayTitle.isEmpty else { return }
                    debugPrint(
                        "# READERMODETITLE sync.readerTitle",
                        "pageURL=\(readerContent.pageURL.absoluteString)",
                        "title=\(displayTitle)"
                    )
                    do {
                        try await scriptCaller.evaluateJavaScript(
                            """
                            (function() {
                              const el = document.getElementById('reader-title');
                              if (el && el.textContent !== title) {
                                el.textContent = title;
                              }
                            })();
                            """,
                            arguments: ["title": displayTitle],
                            duplicateInMultiTargetFrames: true
                        )
                    } catch {
                        debugPrint("# READER title.sync.failed", error.localizedDescription)
                    }
                }
            }
    }
}
