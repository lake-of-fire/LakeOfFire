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
            let result = try await scriptCaller.evaluateJavaScript(
                """
                const px = '\(size)px';
                const docs = [document];
                const liveDoc = globalThis.reader?.view?.document;
                if (liveDoc && !docs.includes(liveDoc)) docs.push(liveDoc);
                for (const doc of docs) {
                    try { doc.documentElement?.style?.setProperty('font-size', px); } catch (_error) {}
                    try { doc.body?.style?.setProperty('font-size', px); } catch (_error) {}
                    try { doc.body?.setAttribute?.('data-manabi-diagnostic-font-size', px); } catch (_error) {}
                }
                globalThis.manabiDiagnosticFontSize = px;
                return {
                  requested: px,
                  shellDocumentFontSize: (() => {
                    try { return getComputedStyle(document.documentElement).fontSize; } catch (_error) { return null; }
                  })(),
                  shellBodyFontSize: (() => {
                    try { return getComputedStyle(document.body).fontSize; } catch (_error) { return null; }
                  })(),
                  liveDocumentFontSize: (() => {
                    try {
                      const doc = globalThis.reader?.view?.document;
                      return doc ? getComputedStyle(doc.documentElement || doc.body).fontSize : null;
                    } catch (_error) { return null; }
                  })(),
                  hasReaderView: !!globalThis.reader?.view
                };
                """,
                duplicateInMultiTargetFrames: true
            )
            Logger.shared.logger.info("# PAGETURN fontSize.apply reason=\(reason) result=\(String(describing: result))")
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

public struct ReaderPageTurnProbeSnapshot: Codable, Equatable, Sendable {
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
    public var hasView: Bool
    public var hasRenderer: Bool
    public var canNext: Bool
    public var canPrev: Bool
    public var hasSectionLayoutController: Bool
    public var bookDirection: String?
    public var isRightToLeft: Bool
    public var isVertical: Bool
    public var isVerticalRightToLeft: Bool
    public var currentSectionIndex: Int?
    public var currentSectionHref: String?
    public var currentPage: Int?
    public var livePageIndex: Int?
    public var liveChunkPageIndex: Int?
    public var viewportCenterChunkPageIndex: Int?
    public var pageCount: Int?
    public var layoutPageRecordCount: Int?
    public var layoutLiveRootExists: Bool?
    public var layoutLiveRootClassName: String?
    public var layoutLiveRootChildCount: Int?
    public var layoutLiveRootRectWidth: Int?
    public var layoutLiveRootRectHeight: Int?
    public var layoutLiveCurrentPageExists: Bool?
    public var layoutLiveCurrentPageClassName: String?
    public var layoutLiveCurrentPageRectWidth: Int?
    public var layoutLiveCurrentPageRectHeight: Int?
    public var layoutLiveCurrentPageContainsChunkBody: Bool?
    public var layoutLiveCurrentChunkExists: Bool?
    public var layoutLiveCurrentChunkTagName: String?
    public var layoutLiveCurrentChunkClassName: String?
    public var layoutLiveCurrentChunkDisplay: String?
    public var layoutLiveCurrentChunkPosition: String?
    public var layoutLiveCurrentChunkFlex: String?
    public var layoutLiveCurrentChunkRectWidth: Int?
    public var layoutLiveCurrentChunkRectHeight: Int?
    public var layoutLiveCurrentChunkInnerHTMLLength: Int?
    public var layoutLiveCurrentChunkContainsChunkBody: Bool?
    public var layoutLiveCurrentChunkChildCount: Int?
    public var layoutLiveCurrentChunkTextLength: Int?
    public var layoutCurrentChunkBodyChildCount: Int?
    public var layoutCurrentChunkBodyTextLength: Int?
    public var layoutCurrentChunkBodyDisplay: String?
    public var layoutCurrentChunkBodyPosition: String?
    public var layoutCurrentChunkBodyFlex: String?
    public var layoutColumnCount: Int?
    public var layoutCurrentPageIndex: Int?
    public var layoutCurrentPageChunkCount: Int?
    public var layoutMaxPageChunkCount: Int?
    public var layoutUnitCount: Int?
    public var layoutActiveBuildPageIndex: Int?
    public var layoutComplete: Bool?
    public var layoutSpreadCandidateDetected: Bool?
    public var layoutVisibleUnitKind: String?
    public var layoutVisibleUnitAxis: String?
    public var layoutVisiblePageCount: Int?
    public var layoutCurrentUnitIndex: Int?
    public var layoutLeadingPageIndex: Int?
    public var layoutTrailingPageIndex: Int?
    public var layoutHasLeadingSingleton: Bool?
    public var layoutHasTrailingSingleton: Bool?
    public var layoutPrimarySpacing: Double?
    public var layoutMultiUnitActive: Bool?
    public var layoutSpreadPagesAllowedForViewport: Bool?
    public var layoutWritingMode: String?
    public var layoutViewportWidth: Int?
    public var layoutViewportHeight: Int?
    public var layoutMeasuredGap: Double?
    public var layoutMetricSize: Int?
    public var layoutColumnInlineSize: Int?
    public var layoutCurrentChunkClientWidth: Int?
    public var layoutCurrentChunkClientHeight: Int?
    public var layoutCurrentChunkScrollWidth: Int?
    public var layoutCurrentChunkScrollHeight: Int?
    public var layoutCurrentChunkOverflow: Bool?
    public var computedFontSizeCSS: String?
    public var currentPageTextSample: String?
    public var nextPageTextSample: String?
    public var currentPageDisplayLabel: String?
    public var currentPhysicalPageLabel: String?
    public var loadEBookStarted: Bool
    public var loadEBookReady: Bool
    public var loadEBookAttemptCount: Int?
    public var loadEBookStartAgeMs: Int?
    public var loadEBookLastState: String?
    public var sameDocumentHostTurnPhase: String?
    public var sameDocumentHostTurnDirection: String?
    public var sameDocumentHostTurnCurrentPageIndex: Int?
    public var sameDocumentHostTurnTargetPageIndex: Int?
    public var sameDocumentHostTurnPageCount: Int?
    public var sameDocumentHostTurnDatasetCurrentPageIndex: Int?
    public var sameDocumentHostTurnResult: String?
    public var pageLabelDisplayMode: String?
    public var usesPhysicalPageLabels: Bool?
    public var canForward: Bool
    public var canBackward: Bool
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
    public var probeError: String?

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
        hasView: Bool,
        hasRenderer: Bool,
        canNext: Bool,
        canPrev: Bool,
        hasSectionLayoutController: Bool,
        bookDirection: String?,
        isRightToLeft: Bool,
        isVertical: Bool,
        isVerticalRightToLeft: Bool,
        currentSectionIndex: Int?,
        currentSectionHref: String?,
        currentPage: Int?,
        livePageIndex: Int?,
        liveChunkPageIndex: Int?,
        viewportCenterChunkPageIndex: Int?,
        pageCount: Int?,
        layoutPageRecordCount: Int?,
        layoutLiveRootExists: Bool?,
        layoutLiveRootClassName: String?,
        layoutLiveRootChildCount: Int?,
        layoutLiveRootRectWidth: Int?,
        layoutLiveRootRectHeight: Int?,
        layoutLiveCurrentPageExists: Bool?,
        layoutLiveCurrentPageClassName: String?,
        layoutLiveCurrentPageRectWidth: Int?,
        layoutLiveCurrentPageRectHeight: Int?,
        layoutLiveCurrentPageContainsChunkBody: Bool?,
        layoutLiveCurrentChunkExists: Bool?,
        layoutLiveCurrentChunkTagName: String?,
        layoutLiveCurrentChunkClassName: String?,
        layoutLiveCurrentChunkDisplay: String?,
        layoutLiveCurrentChunkPosition: String?,
        layoutLiveCurrentChunkFlex: String?,
        layoutLiveCurrentChunkRectWidth: Int?,
        layoutLiveCurrentChunkRectHeight: Int?,
        layoutLiveCurrentChunkInnerHTMLLength: Int?,
        layoutLiveCurrentChunkContainsChunkBody: Bool?,
        layoutLiveCurrentChunkChildCount: Int?,
        layoutLiveCurrentChunkTextLength: Int?,
        layoutCurrentChunkBodyChildCount: Int?,
        layoutCurrentChunkBodyTextLength: Int?,
        layoutCurrentChunkBodyDisplay: String?,
        layoutCurrentChunkBodyPosition: String?,
        layoutCurrentChunkBodyFlex: String?,
        layoutColumnCount: Int?,
        layoutCurrentPageIndex: Int?,
        layoutCurrentPageChunkCount: Int?,
        layoutMaxPageChunkCount: Int?,
        layoutUnitCount: Int?,
        layoutActiveBuildPageIndex: Int?,
        layoutComplete: Bool?,
        layoutSpreadCandidateDetected: Bool?,
        layoutVisibleUnitKind: String?,
        layoutVisibleUnitAxis: String?,
        layoutVisiblePageCount: Int?,
        layoutCurrentUnitIndex: Int?,
        layoutLeadingPageIndex: Int?,
        layoutTrailingPageIndex: Int?,
        layoutHasLeadingSingleton: Bool?,
        layoutHasTrailingSingleton: Bool?,
        layoutPrimarySpacing: Double?,
        layoutMultiUnitActive: Bool?,
        layoutSpreadPagesAllowedForViewport: Bool?,
        layoutWritingMode: String?,
        layoutViewportWidth: Int?,
        layoutViewportHeight: Int?,
        layoutMeasuredGap: Double?,
        layoutMetricSize: Int?,
        layoutColumnInlineSize: Int?,
        layoutCurrentChunkClientWidth: Int?,
        layoutCurrentChunkClientHeight: Int?,
        layoutCurrentChunkScrollWidth: Int?,
        layoutCurrentChunkScrollHeight: Int?,
        layoutCurrentChunkOverflow: Bool?,
        computedFontSizeCSS: String?,
        currentPageTextSample: String?,
        nextPageTextSample: String?,
        currentPageDisplayLabel: String?,
        currentPhysicalPageLabel: String?,
        loadEBookStarted: Bool,
        loadEBookReady: Bool,
        loadEBookAttemptCount: Int?,
        loadEBookStartAgeMs: Int?,
        loadEBookLastState: String?,
        sameDocumentHostTurnPhase: String?,
        sameDocumentHostTurnDirection: String?,
        sameDocumentHostTurnCurrentPageIndex: Int?,
        sameDocumentHostTurnTargetPageIndex: Int?,
        sameDocumentHostTurnPageCount: Int?,
        sameDocumentHostTurnDatasetCurrentPageIndex: Int?,
        sameDocumentHostTurnResult: String?,
        pageLabelDisplayMode: String?,
        usesPhysicalPageLabels: Bool?,
        canForward: Bool,
        canBackward: Bool,
        interactionKind: String?,
        interactionQualified: Bool?,
        interactionDirection: String?,
        interactionPrimaryAxisDelta: Double?,
        interactionSecondaryAxisDelta: Double?,
        interactionProgress: Double?,
        interactionVelocity: Double?,
        interactionShouldCommit: Bool?,
        interactionRefusedOppositeDirectionFlick: Bool?,
        interactionNote: String?,
        probeError: String?
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
        self.hasView = hasView
        self.hasRenderer = hasRenderer
        self.canNext = canNext
        self.canPrev = canPrev
        self.hasSectionLayoutController = hasSectionLayoutController
        self.bookDirection = bookDirection
        self.isRightToLeft = isRightToLeft
        self.isVertical = isVertical
        self.isVerticalRightToLeft = isVerticalRightToLeft
        self.currentSectionIndex = currentSectionIndex
        self.currentSectionHref = currentSectionHref
        self.currentPage = currentPage
        self.livePageIndex = livePageIndex
        self.liveChunkPageIndex = liveChunkPageIndex
        self.viewportCenterChunkPageIndex = viewportCenterChunkPageIndex
        self.pageCount = pageCount
        self.layoutPageRecordCount = layoutPageRecordCount
        self.layoutLiveRootExists = layoutLiveRootExists
        self.layoutLiveRootClassName = layoutLiveRootClassName
        self.layoutLiveRootChildCount = layoutLiveRootChildCount
        self.layoutLiveRootRectWidth = layoutLiveRootRectWidth
        self.layoutLiveRootRectHeight = layoutLiveRootRectHeight
        self.layoutLiveCurrentPageExists = layoutLiveCurrentPageExists
        self.layoutLiveCurrentPageClassName = layoutLiveCurrentPageClassName
        self.layoutLiveCurrentPageRectWidth = layoutLiveCurrentPageRectWidth
        self.layoutLiveCurrentPageRectHeight = layoutLiveCurrentPageRectHeight
        self.layoutLiveCurrentPageContainsChunkBody = layoutLiveCurrentPageContainsChunkBody
        self.layoutLiveCurrentChunkExists = layoutLiveCurrentChunkExists
        self.layoutLiveCurrentChunkTagName = layoutLiveCurrentChunkTagName
        self.layoutLiveCurrentChunkClassName = layoutLiveCurrentChunkClassName
        self.layoutLiveCurrentChunkDisplay = layoutLiveCurrentChunkDisplay
        self.layoutLiveCurrentChunkPosition = layoutLiveCurrentChunkPosition
        self.layoutLiveCurrentChunkFlex = layoutLiveCurrentChunkFlex
        self.layoutLiveCurrentChunkRectWidth = layoutLiveCurrentChunkRectWidth
        self.layoutLiveCurrentChunkRectHeight = layoutLiveCurrentChunkRectHeight
        self.layoutLiveCurrentChunkInnerHTMLLength = layoutLiveCurrentChunkInnerHTMLLength
        self.layoutLiveCurrentChunkContainsChunkBody = layoutLiveCurrentChunkContainsChunkBody
        self.layoutLiveCurrentChunkChildCount = layoutLiveCurrentChunkChildCount
        self.layoutLiveCurrentChunkTextLength = layoutLiveCurrentChunkTextLength
        self.layoutCurrentChunkBodyChildCount = layoutCurrentChunkBodyChildCount
        self.layoutCurrentChunkBodyTextLength = layoutCurrentChunkBodyTextLength
        self.layoutCurrentChunkBodyDisplay = layoutCurrentChunkBodyDisplay
        self.layoutCurrentChunkBodyPosition = layoutCurrentChunkBodyPosition
        self.layoutCurrentChunkBodyFlex = layoutCurrentChunkBodyFlex
        self.layoutColumnCount = layoutColumnCount
        self.layoutCurrentPageIndex = layoutCurrentPageIndex
        self.layoutCurrentPageChunkCount = layoutCurrentPageChunkCount
        self.layoutMaxPageChunkCount = layoutMaxPageChunkCount
        self.layoutUnitCount = layoutUnitCount
        self.layoutActiveBuildPageIndex = layoutActiveBuildPageIndex
        self.layoutComplete = layoutComplete
        self.layoutSpreadCandidateDetected = layoutSpreadCandidateDetected
        self.layoutVisibleUnitKind = layoutVisibleUnitKind
        self.layoutVisibleUnitAxis = layoutVisibleUnitAxis
        self.layoutVisiblePageCount = layoutVisiblePageCount
        self.layoutCurrentUnitIndex = layoutCurrentUnitIndex
        self.layoutLeadingPageIndex = layoutLeadingPageIndex
        self.layoutTrailingPageIndex = layoutTrailingPageIndex
        self.layoutHasLeadingSingleton = layoutHasLeadingSingleton
        self.layoutHasTrailingSingleton = layoutHasTrailingSingleton
        self.layoutPrimarySpacing = layoutPrimarySpacing
        self.layoutMultiUnitActive = layoutMultiUnitActive
        self.layoutSpreadPagesAllowedForViewport = layoutSpreadPagesAllowedForViewport
        self.layoutWritingMode = layoutWritingMode
        self.layoutViewportWidth = layoutViewportWidth
        self.layoutViewportHeight = layoutViewportHeight
        self.layoutMeasuredGap = layoutMeasuredGap
        self.layoutMetricSize = layoutMetricSize
        self.layoutColumnInlineSize = layoutColumnInlineSize
        self.layoutCurrentChunkClientWidth = layoutCurrentChunkClientWidth
        self.layoutCurrentChunkClientHeight = layoutCurrentChunkClientHeight
        self.layoutCurrentChunkScrollWidth = layoutCurrentChunkScrollWidth
        self.layoutCurrentChunkScrollHeight = layoutCurrentChunkScrollHeight
        self.layoutCurrentChunkOverflow = layoutCurrentChunkOverflow
        self.computedFontSizeCSS = computedFontSizeCSS
        self.currentPageTextSample = currentPageTextSample
        self.nextPageTextSample = nextPageTextSample
        self.currentPageDisplayLabel = currentPageDisplayLabel
        self.currentPhysicalPageLabel = currentPhysicalPageLabel
        self.loadEBookStarted = loadEBookStarted
        self.loadEBookReady = loadEBookReady
        self.loadEBookAttemptCount = loadEBookAttemptCount
        self.loadEBookStartAgeMs = loadEBookStartAgeMs
        self.loadEBookLastState = loadEBookLastState
        self.sameDocumentHostTurnPhase = sameDocumentHostTurnPhase
        self.sameDocumentHostTurnDirection = sameDocumentHostTurnDirection
        self.sameDocumentHostTurnCurrentPageIndex = sameDocumentHostTurnCurrentPageIndex
        self.sameDocumentHostTurnTargetPageIndex = sameDocumentHostTurnTargetPageIndex
        self.sameDocumentHostTurnPageCount = sameDocumentHostTurnPageCount
        self.sameDocumentHostTurnDatasetCurrentPageIndex = sameDocumentHostTurnDatasetCurrentPageIndex
        self.sameDocumentHostTurnResult = sameDocumentHostTurnResult
        self.pageLabelDisplayMode = pageLabelDisplayMode
        self.usesPhysicalPageLabels = usesPhysicalPageLabels
        self.canForward = canForward
        self.canBackward = canBackward
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
        self.probeError = probeError
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
            "hasView=\(hasView)",
            "hasRenderer=\(hasRenderer)",
            "canNext=\(canNext)",
            "canPrev=\(canPrev)",
            "hasSectionLayoutController=\(hasSectionLayoutController)",
            "bookDirection=\(bookDirection ?? "nil")",
            "isRightToLeft=\(isRightToLeft)",
            "isVertical=\(isVertical)",
            "isVerticalRightToLeft=\(isVerticalRightToLeft)",
            "currentSectionIndex=\(currentSectionIndex.map(String.init) ?? "nil")",
            "currentSectionHref=\(currentSectionHref ?? "nil")",
            "currentPage=\(currentPage.map(String.init) ?? "nil")",
            "livePageIndex=\(livePageIndex.map(String.init) ?? "nil")",
            "liveChunkPageIndex=\(liveChunkPageIndex.map(String.init) ?? "nil")",
            "viewportCenterChunkPageIndex=\(viewportCenterChunkPageIndex.map(String.init) ?? "nil")",
            "pageCount=\(pageCount.map(String.init) ?? "nil")",
            "layoutPageRecordCount=\(layoutPageRecordCount.map(String.init) ?? "nil")",
            "layoutLiveRootExists=\(layoutLiveRootExists.map(String.init) ?? "nil")",
            "layoutLiveRootClassName=\(layoutLiveRootClassName ?? "nil")",
            "layoutLiveRootChildCount=\(layoutLiveRootChildCount.map(String.init) ?? "nil")",
            "layoutLiveRootRectWidth=\(layoutLiveRootRectWidth.map(String.init) ?? "nil")",
            "layoutLiveRootRectHeight=\(layoutLiveRootRectHeight.map(String.init) ?? "nil")",
            "layoutLiveCurrentPageExists=\(layoutLiveCurrentPageExists.map(String.init) ?? "nil")",
            "layoutLiveCurrentPageClassName=\(layoutLiveCurrentPageClassName ?? "nil")",
            "layoutLiveCurrentPageRectWidth=\(layoutLiveCurrentPageRectWidth.map(String.init) ?? "nil")",
            "layoutLiveCurrentPageRectHeight=\(layoutLiveCurrentPageRectHeight.map(String.init) ?? "nil")",
            "layoutLiveCurrentPageContainsChunkBody=\(layoutLiveCurrentPageContainsChunkBody.map(String.init) ?? "nil")",
            "layoutLiveCurrentChunkExists=\(layoutLiveCurrentChunkExists.map(String.init) ?? "nil")",
            "layoutLiveCurrentChunkTagName=\(layoutLiveCurrentChunkTagName ?? "nil")",
            "layoutLiveCurrentChunkClassName=\(layoutLiveCurrentChunkClassName ?? "nil")",
            "layoutLiveCurrentChunkDisplay=\(layoutLiveCurrentChunkDisplay ?? "nil")",
            "layoutLiveCurrentChunkPosition=\(layoutLiveCurrentChunkPosition ?? "nil")",
            "layoutLiveCurrentChunkFlex=\(layoutLiveCurrentChunkFlex ?? "nil")",
            "layoutLiveCurrentChunkRectWidth=\(layoutLiveCurrentChunkRectWidth.map(String.init) ?? "nil")",
            "layoutLiveCurrentChunkRectHeight=\(layoutLiveCurrentChunkRectHeight.map(String.init) ?? "nil")",
            "layoutLiveCurrentChunkInnerHTMLLength=\(layoutLiveCurrentChunkInnerHTMLLength.map(String.init) ?? "nil")",
            "layoutLiveCurrentChunkContainsChunkBody=\(layoutLiveCurrentChunkContainsChunkBody.map(String.init) ?? "nil")",
            "layoutLiveCurrentChunkChildCount=\(layoutLiveCurrentChunkChildCount.map(String.init) ?? "nil")",
            "layoutLiveCurrentChunkTextLength=\(layoutLiveCurrentChunkTextLength.map(String.init) ?? "nil")",
            "layoutCurrentChunkBodyChildCount=\(layoutCurrentChunkBodyChildCount.map(String.init) ?? "nil")",
            "layoutCurrentChunkBodyTextLength=\(layoutCurrentChunkBodyTextLength.map(String.init) ?? "nil")",
            "layoutCurrentChunkBodyDisplay=\(layoutCurrentChunkBodyDisplay ?? "nil")",
            "layoutCurrentChunkBodyPosition=\(layoutCurrentChunkBodyPosition ?? "nil")",
            "layoutCurrentChunkBodyFlex=\(layoutCurrentChunkBodyFlex ?? "nil")",
            "layoutColumnCount=\(layoutColumnCount.map(String.init) ?? "nil")",
            "layoutCurrentPageIndex=\(layoutCurrentPageIndex.map(String.init) ?? "nil")",
            "layoutCurrentPageChunkCount=\(layoutCurrentPageChunkCount.map(String.init) ?? "nil")",
            "layoutMaxPageChunkCount=\(layoutMaxPageChunkCount.map(String.init) ?? "nil")",
            "layoutUnitCount=\(layoutUnitCount.map(String.init) ?? "nil")",
            "layoutActiveBuildPageIndex=\(layoutActiveBuildPageIndex.map(String.init) ?? "nil")",
            "layoutComplete=\(layoutComplete.map(String.init) ?? "nil")",
            "layoutSpreadCandidateDetected=\(layoutSpreadCandidateDetected.map(String.init) ?? "nil")",
            "layoutVisibleUnitKind=\(layoutVisibleUnitKind ?? "nil")",
            "layoutVisibleUnitAxis=\(layoutVisibleUnitAxis ?? "nil")",
            "layoutVisiblePageCount=\(layoutVisiblePageCount.map(String.init) ?? "nil")",
            "layoutCurrentUnitIndex=\(layoutCurrentUnitIndex.map(String.init) ?? "nil")",
            "layoutLeadingPageIndex=\(layoutLeadingPageIndex.map(String.init) ?? "nil")",
            "layoutTrailingPageIndex=\(layoutTrailingPageIndex.map(String.init) ?? "nil")",
            "layoutHasLeadingSingleton=\(layoutHasLeadingSingleton.map(String.init) ?? "nil")",
            "layoutHasTrailingSingleton=\(layoutHasTrailingSingleton.map(String.init) ?? "nil")",
            "layoutPrimarySpacing=\(layoutPrimarySpacing.map { String($0) } ?? "nil")",
            "layoutMultiUnitActive=\(layoutMultiUnitActive.map(String.init) ?? "nil")",
            "layoutSpreadPagesAllowedForViewport=\(layoutSpreadPagesAllowedForViewport.map(String.init) ?? "nil")",
            "layoutWritingMode=\(layoutWritingMode ?? "nil")",
            "layoutViewportWidth=\(layoutViewportWidth.map(String.init) ?? "nil")",
            "layoutViewportHeight=\(layoutViewportHeight.map(String.init) ?? "nil")",
            "layoutMeasuredGap=\(layoutMeasuredGap.map { String($0) } ?? "nil")",
            "layoutMetricSize=\(layoutMetricSize.map(String.init) ?? "nil")",
            "layoutColumnInlineSize=\(layoutColumnInlineSize.map(String.init) ?? "nil")",
            "layoutCurrentChunkClientWidth=\(layoutCurrentChunkClientWidth.map(String.init) ?? "nil")",
            "layoutCurrentChunkClientHeight=\(layoutCurrentChunkClientHeight.map(String.init) ?? "nil")",
            "layoutCurrentChunkScrollWidth=\(layoutCurrentChunkScrollWidth.map(String.init) ?? "nil")",
            "layoutCurrentChunkScrollHeight=\(layoutCurrentChunkScrollHeight.map(String.init) ?? "nil")",
            "layoutCurrentChunkOverflow=\(layoutCurrentChunkOverflow.map(String.init) ?? "nil")",
            "computedFontSizeCSS=\(computedFontSizeCSS ?? "nil")",
            "currentPageTextSample=\(currentPageTextSample ?? "nil")",
            "nextPageTextSample=\(nextPageTextSample ?? "nil")",
            "currentPageDisplayLabel=\(currentPageDisplayLabel ?? "nil")",
            "currentPhysicalPageLabel=\(currentPhysicalPageLabel ?? "nil")",
            "loadEBookStarted=\(loadEBookStarted)",
            "loadEBookReady=\(loadEBookReady)",
            "loadEBookAttemptCount=\(loadEBookAttemptCount.map(String.init) ?? "nil")",
            "loadEBookStartAgeMs=\(loadEBookStartAgeMs.map(String.init) ?? "nil")",
            "loadEBookLastState=\(loadEBookLastState ?? "nil")",
            "canForward=\(canForward)",
            "canBackward=\(canBackward)",
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
            "probeError=\(probeError ?? "nil")",
        ].joined(separator: ";")
    }
}

@MainActor
public final class ReaderPageTurnProbeModel: ObservableObject {
    @Published public private(set) var snapshot: ReaderPageTurnProbeSnapshot?
    @Published public private(set) var lastCommandResult: String?
    @Published public private(set) var lastRefreshTimedOut = false
    @Published public private(set) var lastRefreshDurationMs: Int?

    private var commandHandler: ((ReaderPageTurnProbeCommand) async -> String)?
    private var refreshHandler: (() async -> ReaderPageTurnProbeSnapshot?)?

    public init() {}

    func update(_ snapshot: ReaderPageTurnProbeSnapshot) {
        self.snapshot = snapshot
    }

    func bindCommandHandler(
        _ handler: @escaping (ReaderPageTurnProbeCommand) async -> String
    ) {
        commandHandler = handler
    }

    func bindRefreshHandler(
        _ handler: @escaping () async -> ReaderPageTurnProbeSnapshot?
    ) {
        refreshHandler = handler
    }

    public func perform(_ command: ReaderPageTurnProbeCommand) async {
        guard let commandHandler else {
            lastCommandResult = "unavailable:noHandler"
            return
        }
        lastCommandResult = await commandHandler(command)
    }

    @discardableResult
    public func enqueuePerform(_ command: ReaderPageTurnProbeCommand) -> String {
        guard let commandHandler else {
            let result = "unavailable:noHandler"
            lastCommandResult = result
            return result
        }
        let acceptedResult = "accepted:\(command.rawValue)"
        lastCommandResult = acceptedResult
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.lastCommandResult = await commandHandler(command)
        }
        return acceptedResult
    }

    @discardableResult
    public func refresh(timeoutNanoseconds: UInt64 = 2_000_000_000) async -> ReaderPageTurnProbeSnapshot? {
        guard let refreshHandler else {
            return snapshot
        }
        let refreshStartedAt = Date()
        lastRefreshTimedOut = false
        let resultBox = ReaderPageTurnProbeRefreshResultBox()
        let task = Task { @MainActor in
            let refreshedSnapshot = await refreshHandler()
            await resultBox.set(refreshedSnapshot)
        }
        let timeoutDate = Date().addingTimeInterval(TimeInterval(timeoutNanoseconds) / 1_000_000_000)
        while Date() < timeoutDate {
            let result = await resultBox.get()
            if result.completed {
                lastRefreshDurationMs = Int(Date().timeIntervalSince(refreshStartedAt) * 1000)
                if let refreshedSnapshot = result.snapshot {
                    snapshot = refreshedSnapshot
                }
                return result.snapshot ?? snapshot
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        task.cancel()
        lastRefreshTimedOut = true
        lastRefreshDurationMs = Int(Date().timeIntervalSince(refreshStartedAt) * 1000)
        return snapshot
    }
}

private actor ReaderPageTurnProbeCommandResultBox {
    private var value: String?

    func set(_ value: String) {
        self.value = value
    }

    func get() -> String? {
        value
    }
}

private actor ReaderPageTurnProbeRefreshResultBox {
    private var snapshot: ReaderPageTurnProbeSnapshot??

    func set(_ snapshot: ReaderPageTurnProbeSnapshot?) {
        self.snapshot = snapshot
    }

    func get() -> (completed: Bool, snapshot: ReaderPageTurnProbeSnapshot?) {
        guard let snapshot else {
            return (false, nil)
        }
        return (true, snapshot)
    }
}

private actor ReaderPageTurnNavigationProbeResultBox {
    private var probe: ReaderPageTurnNavigationProbe??

    func set(_ probe: ReaderPageTurnNavigationProbe?) {
        self.probe = probe
    }

    func get() -> (completed: Bool, probe: ReaderPageTurnNavigationProbe?) {
        guard let probe else {
            return (false, nil)
        }
        return (true, probe)
    }
}

private extension ReaderPageTurnProbeSnapshot {
    func hasMeaningfulNavigationChange(comparedTo probe: ReaderPageTurnNavigationProbe) -> Bool {
        if currentSectionIndex != probe.currentSectionIndex {
            return true
        }
        if currentSectionHref != probe.currentSectionHref {
            return true
        }
        if currentPage != probe.currentPage {
            return true
        }
        if livePageIndex != probe.livePageIndex {
            return true
        }
        if liveChunkPageIndex != probe.liveChunkPageIndex {
            return true
        }
        if viewportCenterChunkPageIndex != probe.viewportCenterChunkPageIndex {
            return true
        }
        if canForward != probe.canForward {
            return true
        }
        if canBackward != probe.canBackward {
            return true
        }
        return false
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

public enum ReaderPageTurnProbeCommand: String, Codable, CaseIterable, Sendable, Identifiable {
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
    var currentSectionIndex: Int?
    var currentSectionHref: String?
    var currentPage: Int?
    var livePageIndex: Int?
    var liveChunkPageIndex: Int?
    var viewportCenterChunkPageIndex: Int?
    var pageCount: Int?
    var layoutPageRecordCount: Int?
    var layoutLiveRootExists: Bool?
    var layoutLiveRootClassName: String?
    var layoutLiveRootChildCount: Int?
    var layoutLiveRootRectWidth: Int?
    var layoutLiveRootRectHeight: Int?
    var layoutLiveCurrentPageExists: Bool?
    var layoutLiveCurrentPageClassName: String?
    var layoutLiveCurrentPageRectWidth: Int?
    var layoutLiveCurrentPageRectHeight: Int?
    var layoutLiveCurrentPageContainsChunkBody: Bool?
    var layoutLiveCurrentChunkExists: Bool?
    var layoutLiveCurrentChunkTagName: String?
    var layoutLiveCurrentChunkClassName: String?
    var layoutLiveCurrentChunkDisplay: String?
    var layoutLiveCurrentChunkPosition: String?
    var layoutLiveCurrentChunkFlex: String?
    var layoutLiveCurrentChunkRectWidth: Int?
    var layoutLiveCurrentChunkRectHeight: Int?
    var layoutLiveCurrentChunkInnerHTMLLength: Int?
    var layoutLiveCurrentChunkContainsChunkBody: Bool?
    var layoutLiveCurrentChunkChildCount: Int?
    var layoutLiveCurrentChunkTextLength: Int?
    var layoutCurrentChunkBodyChildCount: Int?
    var layoutCurrentChunkBodyTextLength: Int?
    var layoutCurrentChunkBodyDisplay: String?
    var layoutCurrentChunkBodyPosition: String?
    var layoutCurrentChunkBodyFlex: String?
    var layoutColumnCount: Int?
    var layoutCurrentPageIndex: Int?
    var layoutCurrentPageChunkCount: Int?
    var layoutMaxPageChunkCount: Int?
    var layoutUnitCount: Int?
    var layoutActiveBuildPageIndex: Int?
    var layoutComplete: Bool?
    var layoutSpreadCandidateDetected: Bool?
    var layoutVisibleUnitKind: String?
    var layoutVisibleUnitAxis: String?
    var layoutVisiblePageCount: Int?
    var layoutCurrentUnitIndex: Int?
    var layoutLeadingPageIndex: Int?
    var layoutTrailingPageIndex: Int?
    var layoutHasLeadingSingleton: Bool?
    var layoutHasTrailingSingleton: Bool?
    var layoutPrimarySpacing: Double?
    var layoutMultiUnitActive: Bool?
    var layoutSpreadPagesAllowedForViewport: Bool?
    var layoutWritingMode: String?
    var layoutViewportWidth: Int?
    var layoutViewportHeight: Int?
    var layoutMeasuredGap: Double?
    var layoutMetricSize: Int?
    var layoutColumnInlineSize: Int?
    var layoutCurrentChunkClientWidth: Int?
    var layoutCurrentChunkClientHeight: Int?
    var layoutCurrentChunkScrollWidth: Int?
    var layoutCurrentChunkScrollHeight: Int?
    var layoutCurrentChunkOverflow: Bool?
    var computedFontSizeCSS: String?
    var currentPageTextSample: String?
    var nextPageTextSample: String?
    var currentPageDisplayLabel: String?
    var currentPhysicalPageLabel: String?
    var loadEBookStarted: Bool
    var loadEBookReady: Bool
    var loadEBookAttemptCount: Int?
    var loadEBookStartAgeMs: Int?
    var loadEBookLastState: String?
    var sameDocumentHostTurnPhase: String?
    var sameDocumentHostTurnDirection: String?
    var sameDocumentHostTurnCurrentPageIndex: Int?
    var sameDocumentHostTurnTargetPageIndex: Int?
    var sameDocumentHostTurnPageCount: Int?
    var sameDocumentHostTurnDatasetCurrentPageIndex: Int?
    var sameDocumentHostTurnResult: String?
    var pageLabelDisplayMode: String?
    var usesPhysicalPageLabels: Bool?
    var probeError: String?

    var resolvedPaginationMode: WebViewPaginationMode {
        if isVertical {
            return isVerticalRightToLeft ? .rightToLeft : .leftToRight
        }
        return isRightToLeft ? .rightToLeft : .leftToRight
    }

    var pageProgressionDirection: PageTurnPageProgressionDirection {
        resolvedPaginationMode == .rightToLeft ? .rightToLeft : .leftToRight
    }

    var canSemanticForward: Bool {
        canForward
    }

    var canSemanticBackward: Bool {
        canBackward
    }

    var logPayload: [String: String] {
        [
            "hasView": "\(hasView)",
            "hasRenderer": "\(hasRenderer)",
            "canNext": "\(canNext)",
            "canPrev": "\(canPrev)",
            "canForward": "\(canSemanticForward)",
            "canBackward": "\(canSemanticBackward)",
            "physicalCanForward": "\(canForward)",
            "physicalCanBackward": "\(canBackward)",
            "hasSectionLayoutController": "\(hasSectionLayoutController)",
            "bookDirection": bookDirection ?? "nil",
            "isRightToLeft": "\(isRightToLeft)",
            "isVertical": "\(isVertical)",
            "isVerticalRightToLeft": "\(isVerticalRightToLeft)",
            "currentSectionIndex": currentSectionIndex.map(String.init) ?? "nil",
            "currentSectionHref": currentSectionHref ?? "nil",
            "currentPage": currentPage.map(String.init) ?? "nil",
            "livePageIndex": livePageIndex.map(String.init) ?? "nil",
            "liveChunkPageIndex": liveChunkPageIndex.map(String.init) ?? "nil",
            "viewportCenterChunkPageIndex": viewportCenterChunkPageIndex.map(String.init) ?? "nil",
            "pageCount": pageCount.map(String.init) ?? "nil",
            "layoutPageRecordCount": layoutPageRecordCount.map(String.init) ?? "nil",
            "layoutLiveRootExists": layoutLiveRootExists.map(String.init) ?? "nil",
            "layoutLiveRootClassName": layoutLiveRootClassName ?? "nil",
            "layoutLiveRootChildCount": layoutLiveRootChildCount.map(String.init) ?? "nil",
            "layoutLiveRootRectWidth": layoutLiveRootRectWidth.map(String.init) ?? "nil",
            "layoutLiveRootRectHeight": layoutLiveRootRectHeight.map(String.init) ?? "nil",
            "layoutLiveCurrentPageExists": layoutLiveCurrentPageExists.map(String.init) ?? "nil",
            "layoutLiveCurrentPageClassName": layoutLiveCurrentPageClassName ?? "nil",
            "layoutLiveCurrentPageRectWidth": layoutLiveCurrentPageRectWidth.map(String.init) ?? "nil",
            "layoutLiveCurrentPageRectHeight": layoutLiveCurrentPageRectHeight.map(String.init) ?? "nil",
            "layoutLiveCurrentPageContainsChunkBody": layoutLiveCurrentPageContainsChunkBody.map(String.init) ?? "nil",
            "layoutLiveCurrentChunkExists": layoutLiveCurrentChunkExists.map(String.init) ?? "nil",
            "layoutLiveCurrentChunkTagName": layoutLiveCurrentChunkTagName ?? "nil",
            "layoutLiveCurrentChunkClassName": layoutLiveCurrentChunkClassName ?? "nil",
            "layoutLiveCurrentChunkDisplay": layoutLiveCurrentChunkDisplay ?? "nil",
            "layoutLiveCurrentChunkPosition": layoutLiveCurrentChunkPosition ?? "nil",
            "layoutLiveCurrentChunkFlex": layoutLiveCurrentChunkFlex ?? "nil",
            "layoutLiveCurrentChunkRectWidth": layoutLiveCurrentChunkRectWidth.map(String.init) ?? "nil",
            "layoutLiveCurrentChunkRectHeight": layoutLiveCurrentChunkRectHeight.map(String.init) ?? "nil",
            "layoutLiveCurrentChunkInnerHTMLLength": layoutLiveCurrentChunkInnerHTMLLength.map(String.init) ?? "nil",
            "layoutLiveCurrentChunkContainsChunkBody": layoutLiveCurrentChunkContainsChunkBody.map(String.init) ?? "nil",
            "layoutLiveCurrentChunkChildCount": layoutLiveCurrentChunkChildCount.map(String.init) ?? "nil",
            "layoutLiveCurrentChunkTextLength": layoutLiveCurrentChunkTextLength.map(String.init) ?? "nil",
            "layoutCurrentChunkBodyChildCount": layoutCurrentChunkBodyChildCount.map(String.init) ?? "nil",
            "layoutCurrentChunkBodyTextLength": layoutCurrentChunkBodyTextLength.map(String.init) ?? "nil",
            "layoutCurrentChunkBodyDisplay": layoutCurrentChunkBodyDisplay ?? "nil",
            "layoutCurrentChunkBodyPosition": layoutCurrentChunkBodyPosition ?? "nil",
            "layoutCurrentChunkBodyFlex": layoutCurrentChunkBodyFlex ?? "nil",
            "layoutColumnCount": layoutColumnCount.map(String.init) ?? "nil",
            "layoutCurrentPageIndex": layoutCurrentPageIndex.map(String.init) ?? "nil",
            "layoutCurrentPageChunkCount": layoutCurrentPageChunkCount.map(String.init) ?? "nil",
            "layoutMaxPageChunkCount": layoutMaxPageChunkCount.map(String.init) ?? "nil",
            "layoutUnitCount": layoutUnitCount.map(String.init) ?? "nil",
            "layoutActiveBuildPageIndex": layoutActiveBuildPageIndex.map(String.init) ?? "nil",
            "layoutComplete": layoutComplete.map(String.init) ?? "nil",
            "layoutSpreadCandidateDetected": layoutSpreadCandidateDetected.map(String.init) ?? "nil",
            "layoutVisibleUnitKind": layoutVisibleUnitKind ?? "nil",
            "layoutVisibleUnitAxis": layoutVisibleUnitAxis ?? "nil",
            "layoutVisiblePageCount": layoutVisiblePageCount.map(String.init) ?? "nil",
            "layoutCurrentUnitIndex": layoutCurrentUnitIndex.map(String.init) ?? "nil",
            "layoutLeadingPageIndex": layoutLeadingPageIndex.map(String.init) ?? "nil",
            "layoutTrailingPageIndex": layoutTrailingPageIndex.map(String.init) ?? "nil",
            "layoutHasLeadingSingleton": layoutHasLeadingSingleton.map(String.init) ?? "nil",
            "layoutHasTrailingSingleton": layoutHasTrailingSingleton.map(String.init) ?? "nil",
            "layoutPrimarySpacing": layoutPrimarySpacing.map { String($0) } ?? "nil",
            "layoutMultiUnitActive": layoutMultiUnitActive.map(String.init) ?? "nil",
            "layoutSpreadPagesAllowedForViewport": layoutSpreadPagesAllowedForViewport.map(String.init) ?? "nil",
            "layoutWritingMode": layoutWritingMode ?? "nil",
            "layoutViewportWidth": layoutViewportWidth.map(String.init) ?? "nil",
            "layoutViewportHeight": layoutViewportHeight.map(String.init) ?? "nil",
            "layoutMeasuredGap": layoutMeasuredGap.map { String($0) } ?? "nil",
            "layoutMetricSize": layoutMetricSize.map(String.init) ?? "nil",
            "layoutColumnInlineSize": layoutColumnInlineSize.map(String.init) ?? "nil",
            "layoutCurrentChunkClientWidth": layoutCurrentChunkClientWidth.map(String.init) ?? "nil",
            "layoutCurrentChunkClientHeight": layoutCurrentChunkClientHeight.map(String.init) ?? "nil",
            "layoutCurrentChunkScrollWidth": layoutCurrentChunkScrollWidth.map(String.init) ?? "nil",
            "layoutCurrentChunkScrollHeight": layoutCurrentChunkScrollHeight.map(String.init) ?? "nil",
            "layoutCurrentChunkOverflow": layoutCurrentChunkOverflow.map(String.init) ?? "nil",
            "computedFontSizeCSS": computedFontSizeCSS ?? "nil",
            "currentPageTextSample": currentPageTextSample ?? "nil",
            "nextPageTextSample": nextPageTextSample ?? "nil",
            "currentPageDisplayLabel": currentPageDisplayLabel ?? "nil",
            "currentPhysicalPageLabel": currentPhysicalPageLabel ?? "nil",
            "loadEBookStarted": "\(loadEBookStarted)",
            "loadEBookReady": "\(loadEBookReady)",
            "loadEBookAttemptCount": loadEBookAttemptCount.map(String.init) ?? "nil",
            "loadEBookStartAgeMs": loadEBookStartAgeMs.map(String.init) ?? "nil",
            "loadEBookLastState": loadEBookLastState ?? "nil",
            "sameDocumentHostTurnPhase": sameDocumentHostTurnPhase ?? "nil",
            "sameDocumentHostTurnDirection": sameDocumentHostTurnDirection ?? "nil",
            "sameDocumentHostTurnCurrentPageIndex": sameDocumentHostTurnCurrentPageIndex.map(String.init) ?? "nil",
            "sameDocumentHostTurnTargetPageIndex": sameDocumentHostTurnTargetPageIndex.map(String.init) ?? "nil",
            "sameDocumentHostTurnPageCount": sameDocumentHostTurnPageCount.map(String.init) ?? "nil",
            "sameDocumentHostTurnDatasetCurrentPageIndex": sameDocumentHostTurnDatasetCurrentPageIndex.map(String.init) ?? "nil",
            "sameDocumentHostTurnResult": sameDocumentHostTurnResult ?? "nil",
            "pageLabelDisplayMode": pageLabelDisplayMode ?? "nil",
            "usesPhysicalPageLabels": usesPhysicalPageLabels.map(String.init) ?? "nil",
            "probeError": probeError ?? "nil",
            "resolvedPaginationMode": resolvedPaginationMode.rawValue.description,
            "pageProgressionDirection": pageProgressionDirection.rawValue,
            "supportsActivePageTurn": "\(supportsActivePageTurn)",
        ]
    }

    func hasMeaningfulNavigationChange(comparedTo baseline: Self) -> Bool {
        if currentSectionIndex != baseline.currentSectionIndex {
            return true
        }
        if currentSectionHref != baseline.currentSectionHref {
            return true
        }
        if currentPage != baseline.currentPage {
            return true
        }
        if livePageIndex != baseline.livePageIndex {
            return true
        }
        if liveChunkPageIndex != baseline.liveChunkPageIndex {
            return true
        }
        if viewportCenterChunkPageIndex != baseline.viewportCenterChunkPageIndex {
            return true
        }
        if layoutCurrentUnitIndex != baseline.layoutCurrentUnitIndex {
            return true
        }
        if layoutLeadingPageIndex != baseline.layoutLeadingPageIndex {
            return true
        }
        if layoutTrailingPageIndex != baseline.layoutTrailingPageIndex {
            return true
        }
        if layoutVisibleUnitKind != baseline.layoutVisibleUnitKind {
            return true
        }
        if currentPageTextSample != baseline.currentPageTextSample {
            return true
        }
        if currentPageDisplayLabel != baseline.currentPageDisplayLabel {
            return true
        }
        if currentPhysicalPageLabel != baseline.currentPhysicalPageLabel {
            return true
        }
        if nextPageTextSample != baseline.nextPageTextSample {
            return true
        }
        if sameDocumentHostTurnCurrentPageIndex != baseline.sameDocumentHostTurnCurrentPageIndex {
            return true
        }
        if sameDocumentHostTurnTargetPageIndex != baseline.sameDocumentHostTurnTargetPageIndex {
            return true
        }
        if sameDocumentHostTurnResult != baseline.sameDocumentHostTurnResult {
            return true
        }
        if canPrev != baseline.canPrev {
            return true
        }
        if canNext != baseline.canNext {
            return true
        }
        if canBackward != baseline.canBackward {
            return true
        }
        if canForward != baseline.canForward {
            return true
        }
        return false
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
    if let string = value as? String,
       let data = string.data(using: .utf8),
       let object = try? JSONSerialization.jsonObject(with: data),
       let dictionary = object as? [String: Any] {
        return dictionary
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
    @Published private(set) var currentSectionIndex: Int?
    @Published private(set) var currentSectionHref: String?
    @Published private(set) var currentPage: Int?
    @Published private(set) var pageCount: Int?
    @Published private(set) var layoutPageRecordCount: Int?
    @Published private(set) var layoutLiveRootExists: Bool?
    @Published private(set) var layoutLiveRootClassName: String?
    @Published private(set) var layoutLiveRootChildCount: Int?
    @Published private(set) var layoutLiveRootRectWidth: Int?
    @Published private(set) var layoutLiveRootRectHeight: Int?
    @Published private(set) var layoutLiveCurrentPageExists: Bool?
    @Published private(set) var layoutLiveCurrentPageClassName: String?
    @Published private(set) var layoutLiveCurrentPageRectWidth: Int?
    @Published private(set) var layoutLiveCurrentPageRectHeight: Int?
    @Published private(set) var layoutLiveCurrentPageContainsChunkBody: Bool?
    @Published private(set) var layoutLiveCurrentChunkExists: Bool?
    @Published private(set) var layoutLiveCurrentChunkTagName: String?
    @Published private(set) var layoutLiveCurrentChunkClassName: String?
    @Published private(set) var layoutLiveCurrentChunkDisplay: String?
    @Published private(set) var layoutLiveCurrentChunkPosition: String?
    @Published private(set) var layoutLiveCurrentChunkFlex: String?
    @Published private(set) var layoutLiveCurrentChunkRectWidth: Int?
    @Published private(set) var layoutLiveCurrentChunkRectHeight: Int?
    @Published private(set) var layoutLiveCurrentChunkInnerHTMLLength: Int?
    @Published private(set) var layoutLiveCurrentChunkContainsChunkBody: Bool?
    @Published private(set) var layoutLiveCurrentChunkChildCount: Int?
    @Published private(set) var layoutLiveCurrentChunkTextLength: Int?
    @Published private(set) var layoutCurrentChunkBodyChildCount: Int?
    @Published private(set) var layoutCurrentChunkBodyTextLength: Int?
    @Published private(set) var layoutCurrentChunkBodyDisplay: String?
    @Published private(set) var layoutCurrentChunkBodyPosition: String?
    @Published private(set) var layoutCurrentChunkBodyFlex: String?
    @Published private(set) var layoutColumnCount: Int?
    @Published private(set) var layoutCurrentPageIndex: Int?
    @Published private(set) var layoutCurrentPageChunkCount: Int?
    @Published private(set) var layoutMaxPageChunkCount: Int?
    @Published private(set) var layoutUnitCount: Int?
    @Published private(set) var layoutActiveBuildPageIndex: Int?
    @Published private(set) var layoutComplete: Bool?
    @Published private(set) var layoutSpreadCandidateDetected: Bool?
    @Published private(set) var layoutVisibleUnitKind: String?
    @Published private(set) var layoutVisibleUnitAxis: String?
    @Published private(set) var layoutVisiblePageCount: Int?
    @Published private(set) var layoutCurrentUnitIndex: Int?
    @Published private(set) var layoutLeadingPageIndex: Int?
    @Published private(set) var layoutTrailingPageIndex: Int?
    @Published private(set) var layoutHasLeadingSingleton: Bool?
    @Published private(set) var layoutHasTrailingSingleton: Bool?
    @Published private(set) var layoutPrimarySpacing: Double?
    @Published private(set) var layoutMultiUnitActive: Bool?
    @Published private(set) var layoutSpreadPagesAllowedForViewport: Bool?
    @Published private(set) var layoutWritingMode: String?
    @Published private(set) var layoutViewportWidth: Int?
    @Published private(set) var layoutViewportHeight: Int?
    @Published private(set) var layoutMeasuredGap: Double?
    @Published private(set) var layoutMetricSize: Int?
    @Published private(set) var layoutColumnInlineSize: Int?
    @Published private(set) var layoutCurrentChunkClientWidth: Int?
    @Published private(set) var layoutCurrentChunkClientHeight: Int?
    @Published private(set) var layoutCurrentChunkScrollWidth: Int?
    @Published private(set) var layoutCurrentChunkScrollHeight: Int?
    @Published private(set) var layoutCurrentChunkOverflow: Bool?
    @Published private(set) var computedFontSizeCSS: String?
    @Published private(set) var currentPageTextSample: String?
    @Published private(set) var nextPageTextSample: String?
    @Published private(set) var currentPageDisplayLabel: String?
    @Published private(set) var currentPhysicalPageLabel: String?
    @Published private(set) var loadEBookStarted = false
    @Published private(set) var loadEBookReady = false
    @Published private(set) var loadEBookAttemptCount: Int?
    @Published private(set) var loadEBookStartAgeMs: Int?
    @Published private(set) var loadEBookLastState: String?
    @Published private(set) var sameDocumentHostTurnPhase: String?
    @Published private(set) var sameDocumentHostTurnDirection: String?
    @Published private(set) var sameDocumentHostTurnCurrentPageIndex: Int?
    @Published private(set) var sameDocumentHostTurnTargetPageIndex: Int?
    @Published private(set) var sameDocumentHostTurnPageCount: Int?
    @Published private(set) var sameDocumentHostTurnDatasetCurrentPageIndex: Int?
    @Published private(set) var sameDocumentHostTurnResult: String?
    @Published private(set) var pageLabelDisplayMode: String?
    @Published private(set) var usesPhysicalPageLabels: Bool?
    @Published private(set) var hasView = false
    @Published private(set) var hasRenderer = false
    @Published private(set) var canNext = false
    @Published private(set) var canPrev = false
    @Published private(set) var hasSectionLayoutController = false
    @Published private(set) var bookDirection: String?
    @Published private(set) var isRightToLeft = false
    @Published private(set) var isVertical = false
    @Published private(set) var isVerticalRightToLeft = false
    @Published private(set) var livePageIndex: Int?
    @Published private(set) var liveChunkPageIndex: Int?
    @Published private(set) var viewportCenterChunkPageIndex: Int?
    @Published private(set) var canForward = false
    @Published private(set) var canBackward = false
    @Published private(set) var lastProbeError: String?
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

    private var hasFallbackTurnReadiness: Bool {
        guard hasSectionLayoutController, loadEBookStarted else {
            return false
        }
        let normalizedCurrentPageText = currentPageTextSample?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !normalizedCurrentPageText.isEmpty
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
            currentSectionIndex = nil
            currentSectionHref = nil
            currentPage = nil
            livePageIndex = nil
            liveChunkPageIndex = nil
            viewportCenterChunkPageIndex = nil
            pageCount = nil
            layoutPageRecordCount = nil
            layoutLiveRootExists = nil
            layoutLiveRootClassName = nil
            layoutLiveRootChildCount = nil
            layoutLiveRootRectWidth = nil
            layoutLiveRootRectHeight = nil
            layoutLiveCurrentPageExists = nil
            layoutLiveCurrentPageClassName = nil
            layoutLiveCurrentPageRectWidth = nil
            layoutLiveCurrentPageRectHeight = nil
            layoutLiveCurrentPageContainsChunkBody = nil
            layoutLiveCurrentChunkExists = nil
            layoutLiveCurrentChunkTagName = nil
            layoutLiveCurrentChunkClassName = nil
            layoutLiveCurrentChunkDisplay = nil
            layoutLiveCurrentChunkPosition = nil
            layoutLiveCurrentChunkFlex = nil
            layoutLiveCurrentChunkRectWidth = nil
            layoutLiveCurrentChunkRectHeight = nil
            layoutLiveCurrentChunkInnerHTMLLength = nil
            layoutLiveCurrentChunkContainsChunkBody = nil
            layoutLiveCurrentChunkChildCount = nil
            layoutLiveCurrentChunkTextLength = nil
            layoutCurrentChunkBodyChildCount = nil
            layoutCurrentChunkBodyTextLength = nil
            layoutCurrentChunkBodyDisplay = nil
            layoutCurrentChunkBodyPosition = nil
            layoutCurrentChunkBodyFlex = nil
            layoutColumnCount = nil
            layoutCurrentPageIndex = nil
            layoutCurrentPageChunkCount = nil
            layoutMaxPageChunkCount = nil
            layoutUnitCount = nil
            layoutActiveBuildPageIndex = nil
            layoutComplete = nil
            layoutSpreadCandidateDetected = nil
            layoutPrimarySpacing = nil
            layoutWritingMode = nil
            layoutViewportWidth = nil
            layoutViewportHeight = nil
            layoutMeasuredGap = nil
            layoutMetricSize = nil
            layoutColumnInlineSize = nil
            layoutCurrentChunkClientWidth = nil
            layoutCurrentChunkClientHeight = nil
            layoutCurrentChunkScrollWidth = nil
            layoutCurrentChunkScrollHeight = nil
            layoutCurrentChunkOverflow = nil
            computedFontSizeCSS = nil
            currentPageTextSample = nil
            nextPageTextSample = nil
            currentPageDisplayLabel = nil
            currentPhysicalPageLabel = nil
            loadEBookStarted = false
            loadEBookReady = false
            loadEBookAttemptCount = nil
            loadEBookStartAgeMs = nil
            loadEBookLastState = nil
            pageLabelDisplayMode = nil
            usesPhysicalPageLabels = nil
            canForward = false
            canBackward = false
            lastProbeError = nil
            return
        }

        let paginationState = webViewState.paginationState
        let nextKey = [
            webViewState.pageURL.absoluteString,
            webViewState.isLoading ? "loading" : "loaded",
            webViewState.isProvisionallyNavigating ? "provisional" : "committed",
            webViewState.pageTitle ?? "nil",
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
            let maxAttempts = 120
            let retryDelayNanoseconds: UInt64 = 500_000_000
            var lastProbe: ReaderPageTurnNavigationProbe?

            for attempt in 1...maxAttempts {
                let probe = await self.fetchNavigationProbe()
                guard !Task.isCancelled else { return }
                lastProbe = probe
                self.applyNavigationProbe(probe)
                if ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1",
                   let probe {
                    Logger.shared.logger.info("# PAGETURN navProbe attempt=\(attempt) \(probe.logPayload)")
                }
                if probe?.supportsActivePageTurn == true {
                    break
                }
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
                }
            }
            if ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1",
               lastProbe?.supportsActivePageTurn != true {
                Logger.shared.logger.warning("# PAGETURN navProbe.unresolved attempts=\(maxAttempts) last=\(lastProbe?.logPayload ?? [:])")
            }
            applyNavigationProbe(lastProbe)
        }
    }

    func destinationAvailability(for direction: PageTurnDirection) async -> PageTurnDestinationAvailability {
        guard supportsActivePageTurn || hasFallbackTurnReadiness else {
            return .unavailable
        }
        guard supportsActivePageTurn else {
            return .both
        }
        let isAvailable = switch direction {
        case .forward:
            canForward
        case .backward:
            canBackward
        }
        guard isAvailable else {
            return .unavailable
        }
        guard usesSpreadAwareNavigationSemantics,
              let destinationPageIndices = destinationPageIndices(for: direction) else {
            return .both
        }
        if destinationPageIndices.count > 1 {
            return .both
        }
        guard let destinationPageIndex = destinationPageIndices.first else {
            return .unavailable
        }
        return destinationPageIndex == 0 ? .first : .second
    }

    func commitTurn(_ direction: PageTurnDirection) async throws {
        guard (supportsActivePageTurn || hasFallbackTurnReadiness), let scriptCaller else { return }
        let fallbackFunctionName: String = {
            switch direction {
            case .forward:
                return "next"
            case .backward:
                return "prev"
            }
        }()
        let semanticFunctionName: (ReaderPageTurnNavigationProbe?) -> String = { _ in
            switch direction {
            case .forward:
                return "next"
            case .backward:
                return "prev"
            }
        }
        let semanticActionName: (ReaderPageTurnNavigationProbe?) -> String = { _ in
            switch direction {
            case .forward:
                return "goRight"
            case .backward:
                return "goLeft"
            }
        }
        let activeTurnScript: (ReaderPageTurnNavigationProbe?) -> String = { probe in
            let functionName = semanticFunctionName(probe)
            return """
            (() => {
              const view = globalThis.reader?.view;
              const renderer = view?.renderer;
              if (!view) {
                return;
              }
              if (typeof renderer?.hostTurn === 'function') {
                void Promise.resolve(renderer.hostTurn('\(direction.rawValue)')).catch(() => {});
                return;
              }
              if (typeof view.\(functionName) !== 'function') {
                return;
              }
              void Promise.resolve(view.\(functionName)()).catch(() => {});
            })();
            """
        }

        let shouldLogDiagnostics = ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1"
        let baselineProbe = await fetchNavigationProbe()
        if let baselineProbe {
            applyNavigationProbe(baselineProbe)
        }
        let beforePayload = shouldLogDiagnostics ? currentNavigationDebugPayload() : [:]

        let initialScript: String = if !supportsActivePageTurn && hasFallbackTurnReadiness {
            """
            (() => {
              const view = globalThis.reader?.view;
              if (view && typeof view.\(semanticActionName(baselineProbe)) === 'function') {
                void Promise.resolve(view.\(semanticActionName(baselineProbe))()).catch(() => {});
                return;
              }
              if (view && typeof view.\(fallbackFunctionName) === 'function') {
                void Promise.resolve(view.\(fallbackFunctionName)()).catch(() => {});
                return;
              }
              const controller = view?.document?.defaultView?.manabiEbookSectionLayoutController
                ?? globalThis.manabiEbookSectionLayoutController;
              if (!controller) return;
              let diagnostics = typeof controller.layoutDiagnostics === 'function'
                ? controller.layoutDiagnostics()
                : null;
              const currentPageIndex = Number.isFinite(diagnostics?.currentPageIndex)
                ? diagnostics.currentPageIndex
                : null;
              if (
                Number.isFinite(currentPageIndex) &&
                typeof controller.ensurePageBuilt === 'function'
              ) {
                try {
                  controller.ensurePageBuilt(currentPageIndex + (\(direction == .forward ? "1" : "0")), {
                    reason: 'host-page-turn-fallback-\(direction.rawValue)',
                  });
                } catch (_error) {}
                diagnostics = typeof controller.layoutDiagnostics === 'function'
                  ? controller.layoutDiagnostics()
                  : diagnostics;
              }
              const pageCount = typeof controller.pageCount === 'function'
                ? controller.pageCount()
                : diagnostics?.pageCount;
              if (!Number.isFinite(currentPageIndex) || !Number.isFinite(pageCount)) return;
              const targetPageIndex = currentPageIndex + (\(direction == .forward ? "1" : "-1"));
              if (targetPageIndex < 0 || targetPageIndex >= pageCount) return;
              const location = typeof controller.captureLocationForPage === 'function'
                ? controller.captureLocationForPage(targetPageIndex)
                : null;
              const anchor = typeof controller.sourceRangeForLocation === 'function'
                ? controller.sourceRangeForLocation(location)
                : null;
              if (typeof controller.requestRebuild === 'function') {
                controller.requestRebuild({
                  reason: 'host-page-turn-fallback-\(direction.rawValue)',
                  anchor,
                });
              }
            })();
            """
        } else {
            activeTurnScript(baselineProbe)
        }

        await issueJavaScriptAcrossReaderPageTurnFrames(initialScript, scriptCaller: scriptCaller)
        var afterProbe = try await waitForCommittedTurnProbe(
            direction: direction,
            baselineProbe: baselineProbe,
            timeoutNanoseconds: 8_000_000_000,
            pollNanoseconds: 250_000_000
        )
        if let baselineProbe,
           let activatedProbe = afterProbe,
           !activatedProbe.hasLocationOrContentAdvance(comparedTo: baselineProbe),
           (
            (baselineProbe.supportsActivePageTurn != true && activatedProbe.supportsActivePageTurn)
            || activatedProbe.materiallyExpandedPagination(comparedTo: baselineProbe)
           ) {
            let followupScript = activeTurnScript(activatedProbe)
            await issueJavaScriptAcrossReaderPageTurnFrames(followupScript, scriptCaller: scriptCaller)
            let secondProbe = try await waitForCommittedTurnProbe(
                direction: direction,
                baselineProbe: activatedProbe,
                timeoutNanoseconds: 6_000_000_000,
                pollNanoseconds: 250_000_000
            )
            if secondProbe != nil {
                afterProbe = secondProbe
            }
        }
        if shouldLogDiagnostics {
            Logger.shared.logger.info(
                "# PAGETURN commitTurn direction=\(direction.rawValue) function=\(semanticFunctionName(afterProbe ?? baselineProbe)) action=\(semanticActionName(afterProbe ?? baselineProbe)) mode=unsafe before=\(beforePayload) after=\(afterProbe?.logPayload ?? [:])"
            )
        }
        guard afterProbe != nil else {
            throw NSError(
                domain: "ReaderPageTurnBridge",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "commitTurn timed out for \(direction.rawValue)"]
            )
        }
        publishTurnEvent(.committed, direction: direction)
    }

    private func currentNavigationDebugPayload() -> [String: String] {
        let pageLabelPolicy = resolvedPageLabelPolicy(visibleUnit: resolvedVisibleUnit())
        let pageLabelDisplayMode = pageLabelPolicy.displayMode.rawValue
        let usesPhysicalPageLabels = pageLabelPolicy.usesPhysicalPageLabels
        var payload: [String: String] = [
            "currentSectionIndex": currentSectionIndex.map(String.init) ?? "nil",
            "currentSectionHref": currentSectionHref ?? "nil",
            "currentPage": currentPage.map(String.init) ?? "nil",
            "pageCount": pageCount.map(String.init) ?? "nil",
            "canForward": "\(canForward)",
            "canBackward": "\(canBackward)",
            "supportsActivePageTurn": "\(supportsActivePageTurn)",
            "resolvedPaginationMode": "\(resolvedPaginationMode.rawValue)",
            "pageProgressionDirection": pageProgressionDirection.rawValue,
        ]
        payload.merge([
            "layoutMeasuredGap": layoutMeasuredGap.map { String($0) } ?? "nil",
            "layoutPrimarySpacing": layoutPrimarySpacing.map { String($0) } ?? "nil",
            "currentPageDisplayLabel": currentPageDisplayLabel ?? "nil",
            "currentPhysicalPageLabel": currentPhysicalPageLabel ?? "nil",
            "pageLabelDisplayMode": pageLabelDisplayMode,
            "usesPhysicalPageLabels": String(usesPhysicalPageLabels),
        ], uniquingKeysWith: { _, rhs in rhs })
        return payload
    }

    private func currentCachedNavigationProbe() -> ReaderPageTurnNavigationProbe {
        let pageLabelPolicy = resolvedPageLabelPolicy(visibleUnit: resolvedVisibleUnit())
        let pageLabelDisplayMode = pageLabelPolicy.displayMode.rawValue
        let usesPhysicalPageLabels = pageLabelPolicy.usesPhysicalPageLabels
        return ReaderPageTurnNavigationProbe(
            hasView: hasView,
            hasRenderer: hasRenderer,
            canNext: canNext,
            canPrev: canPrev,
            canForward: canForward,
            canBackward: canBackward,
            hasSectionLayoutController: hasSectionLayoutController,
            bookDirection: bookDirection,
            isRightToLeft: isRightToLeft,
            isVertical: isVertical,
            isVerticalRightToLeft: isVerticalRightToLeft,
            currentSectionIndex: currentSectionIndex,
            currentSectionHref: currentSectionHref,
            currentPage: currentPage,
            pageCount: pageCount,
            layoutPageRecordCount: layoutPageRecordCount,
            layoutLiveRootExists: layoutLiveRootExists,
            layoutLiveRootClassName: layoutLiveRootClassName,
            layoutLiveRootChildCount: layoutLiveRootChildCount,
            layoutLiveRootRectWidth: layoutLiveRootRectWidth,
            layoutLiveRootRectHeight: layoutLiveRootRectHeight,
            layoutLiveCurrentPageExists: layoutLiveCurrentPageExists,
            layoutLiveCurrentPageClassName: layoutLiveCurrentPageClassName,
            layoutLiveCurrentPageRectWidth: layoutLiveCurrentPageRectWidth,
            layoutLiveCurrentPageRectHeight: layoutLiveCurrentPageRectHeight,
            layoutLiveCurrentPageContainsChunkBody: layoutLiveCurrentPageContainsChunkBody,
            layoutLiveCurrentChunkExists: layoutLiveCurrentChunkExists,
            layoutLiveCurrentChunkTagName: layoutLiveCurrentChunkTagName,
            layoutLiveCurrentChunkClassName: layoutLiveCurrentChunkClassName,
            layoutLiveCurrentChunkDisplay: layoutLiveCurrentChunkDisplay,
            layoutLiveCurrentChunkPosition: layoutLiveCurrentChunkPosition,
            layoutLiveCurrentChunkFlex: layoutLiveCurrentChunkFlex,
            layoutLiveCurrentChunkRectWidth: layoutLiveCurrentChunkRectWidth,
            layoutLiveCurrentChunkRectHeight: layoutLiveCurrentChunkRectHeight,
            layoutLiveCurrentChunkInnerHTMLLength: layoutLiveCurrentChunkInnerHTMLLength,
            layoutLiveCurrentChunkContainsChunkBody: layoutLiveCurrentChunkContainsChunkBody,
            layoutLiveCurrentChunkChildCount: layoutLiveCurrentChunkChildCount,
            layoutLiveCurrentChunkTextLength: layoutLiveCurrentChunkTextLength,
            layoutCurrentChunkBodyChildCount: layoutCurrentChunkBodyChildCount,
            layoutCurrentChunkBodyTextLength: layoutCurrentChunkBodyTextLength,
            layoutCurrentChunkBodyDisplay: layoutCurrentChunkBodyDisplay,
            layoutCurrentChunkBodyPosition: layoutCurrentChunkBodyPosition,
            layoutCurrentChunkBodyFlex: layoutCurrentChunkBodyFlex,
            layoutColumnCount: layoutColumnCount,
            layoutCurrentPageIndex: layoutCurrentPageIndex,
            layoutCurrentPageChunkCount: layoutCurrentPageChunkCount,
            layoutMaxPageChunkCount: layoutMaxPageChunkCount,
            layoutUnitCount: layoutUnitCount,
            layoutActiveBuildPageIndex: layoutActiveBuildPageIndex,
            layoutComplete: layoutComplete,
            layoutSpreadCandidateDetected: layoutSpreadCandidateDetected,
            layoutVisibleUnitKind: layoutVisibleUnitKind,
            layoutVisibleUnitAxis: layoutVisibleUnitAxis,
            layoutVisiblePageCount: layoutVisiblePageCount,
            layoutCurrentUnitIndex: layoutCurrentUnitIndex,
            layoutLeadingPageIndex: layoutLeadingPageIndex,
            layoutTrailingPageIndex: layoutTrailingPageIndex,
            layoutHasLeadingSingleton: layoutHasLeadingSingleton,
            layoutHasTrailingSingleton: layoutHasTrailingSingleton,
            layoutPrimarySpacing: layoutPrimarySpacing,
            layoutMultiUnitActive: layoutMultiUnitActive,
            layoutSpreadPagesAllowedForViewport: layoutSpreadPagesAllowedForViewport,
            layoutWritingMode: layoutWritingMode,
            layoutViewportWidth: layoutViewportWidth,
            layoutViewportHeight: layoutViewportHeight,
            layoutMeasuredGap: layoutMeasuredGap,
            layoutMetricSize: layoutMetricSize,
            layoutColumnInlineSize: layoutColumnInlineSize,
            layoutCurrentChunkClientWidth: layoutCurrentChunkClientWidth,
            layoutCurrentChunkClientHeight: layoutCurrentChunkClientHeight,
            layoutCurrentChunkScrollWidth: layoutCurrentChunkScrollWidth,
            layoutCurrentChunkScrollHeight: layoutCurrentChunkScrollHeight,
            layoutCurrentChunkOverflow: layoutCurrentChunkOverflow,
            computedFontSizeCSS: computedFontSizeCSS,
            currentPageTextSample: currentPageTextSample,
            nextPageTextSample: nextPageTextSample,
            currentPageDisplayLabel: currentPageDisplayLabel,
            currentPhysicalPageLabel: currentPhysicalPageLabel,
            loadEBookStarted: loadEBookStarted,
            loadEBookReady: loadEBookReady,
            loadEBookAttemptCount: loadEBookAttemptCount,
            loadEBookStartAgeMs: loadEBookStartAgeMs,
            loadEBookLastState: loadEBookLastState,
            pageLabelDisplayMode: pageLabelDisplayMode,
            usesPhysicalPageLabels: usesPhysicalPageLabels,
            probeError: lastProbeError
        )
    }

    private var usesSpreadAwareNavigationSemantics: Bool {
        layoutVisibleUnitKind == "pageSpread"
            || layoutVisibleUnitKind == "paginatedRowSet"
            || layoutSpreadPagesAllowedForViewport == true
            || layoutMultiUnitActive == true
            || layoutHasLeadingSingleton == true
            || layoutHasTrailingSingleton == true
    }

    private func currentVisiblePageIndices() -> [Int]? {
        let totalPages = pageCount ?? 0
        guard totalPages > 0 else { return nil }

        let leading = max(0, min(totalPages - 1, layoutLeadingPageIndex ?? currentPage ?? 0))
        let trailing = max(
            leading,
            min(
                totalPages - 1,
                layoutTrailingPageIndex
                    ?? (leading + max(0, (layoutVisiblePageCount ?? 1) - 1))
            )
        )
        if trailing > leading {
            return [leading, trailing]
        }
        return [leading]
    }

    private func destinationPageIndices(for direction: PageTurnDirection) -> [Int]? {
        guard let currentIndices = currentVisiblePageIndices(),
              let totalPages = pageCount,
              totalPages > 0 else {
            return nil
        }

        let leading = currentIndices.first ?? 0
        let trailing = currentIndices.last ?? leading

        switch direction {
        case .forward:
            let targetLeading = trailing + 1
            guard targetLeading < totalPages else { return nil }
            if targetLeading == totalPages - 1 {
                return [targetLeading]
            }
            return [targetLeading, min(totalPages - 1, targetLeading + 1)]

        case .backward:
            let targetTrailing = leading - 1
            guard targetTrailing >= 0 else { return nil }
            if targetTrailing == 0 {
                return [0]
            }
            return [max(0, targetTrailing - 1), targetTrailing]
        }
    }

    private func resolvedSnapshotChromeContent(for request: PageTurnSnapshotRequest) async -> PageTurnSnapshotChromeContent? {
        guard request.includeChrome else { return nil }
        let titlePrimary = lastKnownState.pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleSecondary = await resolvedSnapshotSectionTitle()
        return PageTurnSnapshotChromeContent(
            headerLabels: await resolvedSnapshotHeaderLabels(for: request),
            titlePrimary: (titlePrimary?.isEmpty == false) ? titlePrimary : nil,
            titleSecondary: (titleSecondary?.isEmpty == false) ? titleSecondary : nil
        )
    }

    private func resolvedSnapshotSectionTitle() async -> String? {
        if let scriptCaller, scriptCaller.hasAsyncCaller {
            let script = """
            (() => {
              const tocItem = globalThis.reader?.view?.renderer?.tocItem ?? null;
              const label = typeof tocItem?.label === 'string' ? tocItem.label.trim() : '';
              if (label) {
                return label;
              }
              const href = typeof tocItem?.href === 'string' ? tocItem.href.trim() : '';
              if (href) {
                return href.split('/').filter(Boolean).pop() ?? href;
              }
              return null;
            })()
            """
            if let title = try? await scriptCaller.evaluateJavaScript(script) as? String,
               let title,
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return title.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return currentSectionHref?
            .split(separator: "/")
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolvedSnapshotHeaderLabels(for request: PageTurnSnapshotRequest) async -> [String] {
        let visibleUnit = request.visibleUnit
        let currentIndex = max(0, currentPage ?? visibleUnit.currentUnitIndex ?? 0)
        let step = max(1, visibleUnit.usesMultiUnitSurface ? visibleUnit.visiblePageCount : 1)
        let destinationBaseIndex: Int
        switch request.intent {
        case .dragDestination:
            switch request.direction {
            case .forward:
                destinationBaseIndex = currentIndex + step
            case .backward:
                destinationBaseIndex = max(0, currentIndex - step)
            }
        case .dragSource, .turnSource:
            destinationBaseIndex = currentIndex
        }

        if request.pageLabelPolicy.displayMode == .multipleLabels,
           visibleUnit.usesMultiUnitSurface {
            let pageIndices: [Int]
            switch request.intent {
            case .dragDestination:
                pageIndices = destinationPageIndices(for: request.direction)
                    ?? [destinationBaseIndex]
            case .dragSource, .turnSource:
                let leading = max(0, visibleUnit.leadingPageIndex ?? destinationBaseIndex)
                let trailing = max(leading, visibleUnit.trailingPageIndex ?? (leading + 1))
                pageIndices = trailing > leading ? [leading, trailing] : [leading]
            }
            let resolvedLabels = await resolvePageTargetLabels(
                for: pageIndices,
                usePhysicalLabels: request.pageLabelPolicy.usesPhysicalPageLabels
            )
            if !resolvedLabels.isEmpty {
                return resolvedLabels
            }
            return pageIndices.map(fallbackHeaderLabel(for:))
        }

        if request.pageLabelPolicy.usesPhysicalPageLabels,
           let currentPhysicalPageLabel,
           !currentPhysicalPageLabel.isEmpty,
           request.intent != .dragDestination {
            return [currentPhysicalPageLabel]
        }
        if let currentPageDisplayLabel,
           !currentPageDisplayLabel.isEmpty,
           request.intent != .dragDestination {
            return [currentPageDisplayLabel]
        }
        let pageIndices = switch request.intent {
        case .dragDestination:
            destinationPageIndices(for: request.direction) ?? [destinationBaseIndex]
        case .dragSource, .turnSource:
            [destinationBaseIndex]
        }
        let resolvedLabels = await resolvePageTargetLabels(
            for: pageIndices,
            usePhysicalLabels: request.pageLabelPolicy.usesPhysicalPageLabels
        )
        if let label = resolvedLabels.first {
            return [label]
        }
        return [fallbackHeaderLabel(for: destinationBaseIndex)]
    }

    private func resolvePageTargetLabels(
        for pageIndices: [Int],
        usePhysicalLabels: Bool
    ) async -> [String] {
        var seenPageIndices = Set<Int>()
        let normalizedPageIndices = pageIndices.filter { pageIndex in
            guard pageIndex >= 0 else { return false }
            return seenPageIndices.insert(pageIndex).inserted
        }
        guard !normalizedPageIndices.isEmpty,
              let scriptCaller,
              scriptCaller.hasAsyncCaller else {
            return []
        }

        let pageIndicesLiteral = normalizedPageIndices.map(String.init).joined(separator: ", ")
        let script = """
        (() => {
          const pageIndices = [\(pageIndicesLiteral)];
          const navHUD = globalThis.navHUD;
          const pageTargets = Array.isArray(navHUD?.pageTargets) ? navHUD.pageTargets : [];
          const usePhysicalLabels = \(usePhysicalLabels ? "true" : "false");
          const totalPages = Number.isFinite(navHUD?.fallbackTotalPageCount) && navHUD.fallbackTotalPageCount > 0
            ? navHUD.fallbackTotalPageCount
            : (pageTargets.length > 0 ? pageTargets.length : null);
          const labels = pageIndices.map((pageIndex) => {
            if (!Number.isFinite(pageIndex) || pageIndex < 0) {
              return null;
            }
            const item = pageTargets[pageIndex] ?? null;
            const physicalLabel = typeof item?.label === 'string' ? item.label.trim() : '';
            if (usePhysicalLabels && physicalLabel) {
              return physicalLabel;
            }
            if (typeof navHUD?.getPrimaryDisplayLabel === 'function') {
              const computedLabel = navHUD.getPrimaryDisplayLabel({
                pageItem: item,
                pageNumber: pageIndex + 1,
                pageCount: totalPages,
                location: totalPages ? { current: pageIndex, total: totalPages } : null,
              });
              if (typeof computedLabel === 'string' && computedLabel.trim().length > 0) {
                return computedLabel.trim();
              }
            }
            if (typeof totalPages === 'number' && totalPages > 0) {
              return `Page ${pageIndex + 1} of ${totalPages}`;
            }
            return `Page ${pageIndex + 1}`;
          }).filter((label) => typeof label === 'string' && label.length > 0);
          return JSON.stringify(labels);
        })()
        """

        guard let result = try? await scriptCaller.evaluateJavaScript(script),
              let rawJSONString = result as? String,
              let jsonData = rawJSONString.data(using: .utf8),
              let labels = try? JSONDecoder().decode([String].self, from: jsonData) else {
            return []
        }
        return labels
    }

    private func fallbackHeaderLabel(for pageIndex: Int) -> String {
        "Page \(max(1, pageIndex + 1))"
    }

    func cancelTurn(_ direction: PageTurnDirection) async {
        publishTurnEvent(.cancelled, direction: direction)
    }

    func snapshot(for request: PageTurnSnapshotRequest) async throws -> PageTurnSnapshotArtifact {
        let image = await navigator?.withAttachedWebView { webView in
            await captureReaderPageTurnSnapshot(from: webView, contentRect: request.contentRect)
        } ?? nil
        let chromeContent = await resolvedSnapshotChromeContent(for: request)

        return PageTurnSnapshotArtifact(
            image: image ?? makePlaceholderSnapshotImage(size: request.contentRect.size),
            pageID: lastKnownState.pageURL.absoluteString,
            visibleUnit: request.visibleUnit,
            pageLabelPolicy: request.pageLabelPolicy,
            chrome: chromeContent,
            contentRect: request.contentRect,
            layoutGeneration: request.layoutGeneration,
            includesChrome: false
        )
    }

    private func fetchNavigationProbe(preferredFrameOverride: WKFrameInfo? = nil) async -> ReaderPageTurnNavigationProbe? {
        guard let scriptCaller, scriptCaller.hasAsyncCaller else { return nil }
        let probeScript =
            """
            try {
              if (typeof globalThis.manabiGetPageTurnProbeSnapshotJSON === 'function') {
                return await globalThis.manabiGetPageTurnProbeSnapshotJSON();
              }
              return JSON.stringify({
                hasView: !!globalThis.reader?.view,
                hasRenderer: !!globalThis.reader?.view?.renderer,
                canNext: typeof globalThis.reader?.view?.next === 'function',
                canPrev: typeof globalThis.reader?.view?.prev === 'function',
                canForward: false,
                canBackward: false,
                hasSectionLayoutController: !!(
                  globalThis.reader?.view?.document?.defaultView?.manabiEbookSectionLayoutController
                  ?? globalThis.manabiEbookSectionLayoutController
                ),
                bookDirection: globalThis.reader?.book?.dir ?? globalThis.reader?.view?.book?.dir ?? null,
                isRightToLeft: !!(
                  globalThis.manabiGetWritingDirectionSnapshot?.()?.rtl
                  ?? ((globalThis.reader?.book?.dir ?? globalThis.reader?.view?.book?.dir ?? '').toLowerCase() === 'rtl')
                ),
                isVertical: globalThis.manabiGetWritingDirectionSnapshot?.()?.vertical === true,
                isVerticalRightToLeft: globalThis.manabiGetWritingDirectionSnapshot?.()?.verticalRTL === true,
                currentSectionIndex: Number.isFinite(globalThis.reader?.view?.renderer?.currentIndex)
                  ? globalThis.reader.view.renderer.currentIndex
                  : null,
                currentSectionHref: Number.isFinite(globalThis.reader?.view?.renderer?.currentIndex)
                  ? (
                      globalThis.reader?.view?.renderer?.sections?.[globalThis.reader.view.renderer.currentIndex]?.href
                      ?? globalThis.reader?.view?.renderer?.sections?.[globalThis.reader.view.renderer.currentIndex]?.url
                      ?? null
                    )
                  : null,
                currentPage: null,
                livePageIndex: null,
                liveChunkPageIndex: null,
                viewportCenterChunkPageIndex: null,
                pageCount: null,
                computedFontSizeCSS: globalThis.getComputedStyle?.(globalThis.document?.body ?? null)?.fontSize ?? null,
                currentPageTextSample: null,
                nextPageTextSample: null,
                loadEBookStarted: !!globalThis.manabiLoadEBookStarted,
                loadEBookReady: !!globalThis.manabiLoadEBookReady,
                loadEBookAttemptCount: Number(globalThis.manabiLoadEBookAttemptCount || 0) || 0,
                loadEBookStartAgeMs: (() => {
                  const startedAt = Number(globalThis.manabiLoadEBookStartedAt || 0);
                  return startedAt > 0 ? Math.max(0, Date.now() - startedAt) : null;
                })(),
                loadEBookLastState: globalThis.manabiLoadEBookLastState ?? null,
                probeError: 'probe-helper-missing',
              });
            } catch (error) {
              return JSON.stringify({
                hasView: !!globalThis.reader?.view,
                hasRenderer: !!globalThis.reader?.view?.renderer,
                canNext: typeof globalThis.reader?.view?.next === 'function',
                canPrev: typeof globalThis.reader?.view?.prev === 'function',
                canForward: false,
                canBackward: false,
                hasSectionLayoutController: !!(
                  globalThis.reader?.view?.document?.defaultView?.manabiEbookSectionLayoutController
                  ?? globalThis.manabiEbookSectionLayoutController
                ),
                bookDirection: globalThis.reader?.book?.dir ?? globalThis.reader?.view?.book?.dir ?? null,
                isRightToLeft: !!(
                  globalThis.manabiGetWritingDirectionSnapshot?.()?.rtl
                  ?? ((globalThis.reader?.book?.dir ?? globalThis.reader?.view?.book?.dir ?? '').toLowerCase() === 'rtl')
                ),
                isVertical: globalThis.manabiGetWritingDirectionSnapshot?.()?.vertical === true,
                isVerticalRightToLeft: globalThis.manabiGetWritingDirectionSnapshot?.()?.verticalRTL === true,
                currentSectionIndex: Number.isFinite(globalThis.reader?.view?.renderer?.currentIndex)
                  ? globalThis.reader.view.renderer.currentIndex
                  : null,
                currentSectionHref: Number.isFinite(globalThis.reader?.view?.renderer?.currentIndex)
                  ? (
                      globalThis.reader?.view?.renderer?.sections?.[globalThis.reader.view.renderer.currentIndex]?.href
                      ?? globalThis.reader?.view?.renderer?.sections?.[globalThis.reader.view.renderer.currentIndex]?.url
                      ?? null
                    )
                  : null,
                currentPage: null,
                livePageIndex: null,
                liveChunkPageIndex: null,
                viewportCenterChunkPageIndex: null,
                pageCount: null,
                computedFontSizeCSS: globalThis.getComputedStyle?.(globalThis.document?.body ?? null)?.fontSize ?? null,
                currentPageTextSample: null,
                nextPageTextSample: null,
                loadEBookStarted: !!globalThis.manabiLoadEBookStarted,
                loadEBookReady: !!globalThis.manabiLoadEBookReady,
                loadEBookAttemptCount: Number(globalThis.manabiLoadEBookAttemptCount || 0) || 0,
                loadEBookStartAgeMs: (() => {
                  const startedAt = Number(globalThis.manabiLoadEBookStartedAt || 0);
                  return startedAt > 0 ? Math.max(0, Date.now() - startedAt) : null;
                })(),
                loadEBookLastState: globalThis.manabiLoadEBookLastState ?? null,
                probeError: `probe-script-wrapper:${String(error)}`,
              });
            }
            """

        var lastEvaluationError: NSError?
        var resolvedResult: Any?
        for frame in readerPageTurnCandidateFrames(preferredFrameOverride: preferredFrameOverride, scriptCaller: scriptCaller) {
            do {
                resolvedResult = try await scriptCaller.evaluateJavaScript(probeScript, in: frame)
                lastEvaluationError = nil
                break
            } catch {
                lastEvaluationError = error as NSError
            }
        }
        if let lastEvaluationError {
            lastProbeError = "eval-error:\(lastEvaluationError.domain):\(lastEvaluationError.code):\(lastEvaluationError.localizedDescription)"
            return nil
        }
        let result = resolvedResult

        guard let dictionary = readerPageTurnObject(result) else {
            lastProbeError = "nil-result:\(String(describing: type(of: result)))"
            if ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" {
                Logger.shared.logger.warning("# PAGETURN navProbe.nilResult resultType=\(String(describing: type(of: result)))")
            }
            return nil
        }
        let probe = ReaderPageTurnNavigationProbe(
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
            isVerticalRightToLeft: readerPageTurnBool(dictionary["isVerticalRightToLeft"]),
            currentSectionIndex: dictionary["currentSectionIndex"] as? Int ?? (dictionary["currentSectionIndex"] as? NSNumber)?.intValue,
            currentSectionHref: dictionary["currentSectionHref"] as? String,
            currentPage: dictionary["currentPage"] as? Int ?? (dictionary["currentPage"] as? NSNumber)?.intValue,
            livePageIndex: dictionary["livePageIndex"] as? Int ?? (dictionary["livePageIndex"] as? NSNumber)?.intValue,
            liveChunkPageIndex: dictionary["liveChunkPageIndex"] as? Int ?? (dictionary["liveChunkPageIndex"] as? NSNumber)?.intValue,
            viewportCenterChunkPageIndex: dictionary["viewportCenterChunkPageIndex"] as? Int ?? (dictionary["viewportCenterChunkPageIndex"] as? NSNumber)?.intValue,
            pageCount: dictionary["pageCount"] as? Int ?? (dictionary["pageCount"] as? NSNumber)?.intValue,
            layoutPageRecordCount: dictionary["layoutPageRecordCount"] as? Int ?? (dictionary["layoutPageRecordCount"] as? NSNumber)?.intValue,
            layoutLiveRootExists: dictionary["layoutLiveRootExists"] as? Bool ?? (dictionary["layoutLiveRootExists"] as? NSNumber)?.boolValue,
            layoutLiveRootClassName: dictionary["layoutLiveRootClassName"] as? String,
            layoutLiveRootChildCount: dictionary["layoutLiveRootChildCount"] as? Int ?? (dictionary["layoutLiveRootChildCount"] as? NSNumber)?.intValue,
            layoutLiveRootRectWidth: dictionary["layoutLiveRootRectWidth"] as? Int ?? (dictionary["layoutLiveRootRectWidth"] as? NSNumber)?.intValue,
            layoutLiveRootRectHeight: dictionary["layoutLiveRootRectHeight"] as? Int ?? (dictionary["layoutLiveRootRectHeight"] as? NSNumber)?.intValue,
            layoutLiveCurrentPageExists: dictionary["layoutLiveCurrentPageExists"] as? Bool ?? (dictionary["layoutLiveCurrentPageExists"] as? NSNumber)?.boolValue,
            layoutLiveCurrentPageClassName: dictionary["layoutLiveCurrentPageClassName"] as? String,
            layoutLiveCurrentPageRectWidth: dictionary["layoutLiveCurrentPageRectWidth"] as? Int ?? (dictionary["layoutLiveCurrentPageRectWidth"] as? NSNumber)?.intValue,
            layoutLiveCurrentPageRectHeight: dictionary["layoutLiveCurrentPageRectHeight"] as? Int ?? (dictionary["layoutLiveCurrentPageRectHeight"] as? NSNumber)?.intValue,
            layoutLiveCurrentPageContainsChunkBody: dictionary["layoutLiveCurrentPageContainsChunkBody"] as? Bool ?? (dictionary["layoutLiveCurrentPageContainsChunkBody"] as? NSNumber)?.boolValue,
            layoutLiveCurrentChunkExists: dictionary["layoutLiveCurrentChunkExists"] as? Bool ?? (dictionary["layoutLiveCurrentChunkExists"] as? NSNumber)?.boolValue,
            layoutLiveCurrentChunkTagName: dictionary["layoutLiveCurrentChunkTagName"] as? String,
            layoutLiveCurrentChunkClassName: dictionary["layoutLiveCurrentChunkClassName"] as? String,
            layoutLiveCurrentChunkDisplay: dictionary["layoutLiveCurrentChunkDisplay"] as? String,
            layoutLiveCurrentChunkPosition: dictionary["layoutLiveCurrentChunkPosition"] as? String,
            layoutLiveCurrentChunkFlex: dictionary["layoutLiveCurrentChunkFlex"] as? String,
            layoutLiveCurrentChunkRectWidth: dictionary["layoutLiveCurrentChunkRectWidth"] as? Int ?? (dictionary["layoutLiveCurrentChunkRectWidth"] as? NSNumber)?.intValue,
            layoutLiveCurrentChunkRectHeight: dictionary["layoutLiveCurrentChunkRectHeight"] as? Int ?? (dictionary["layoutLiveCurrentChunkRectHeight"] as? NSNumber)?.intValue,
            layoutLiveCurrentChunkInnerHTMLLength: dictionary["layoutLiveCurrentChunkInnerHTMLLength"] as? Int ?? (dictionary["layoutLiveCurrentChunkInnerHTMLLength"] as? NSNumber)?.intValue,
            layoutLiveCurrentChunkContainsChunkBody: dictionary["layoutLiveCurrentChunkContainsChunkBody"] as? Bool ?? (dictionary["layoutLiveCurrentChunkContainsChunkBody"] as? NSNumber)?.boolValue,
            layoutLiveCurrentChunkChildCount: dictionary["layoutLiveCurrentChunkChildCount"] as? Int ?? (dictionary["layoutLiveCurrentChunkChildCount"] as? NSNumber)?.intValue,
            layoutLiveCurrentChunkTextLength: dictionary["layoutLiveCurrentChunkTextLength"] as? Int ?? (dictionary["layoutLiveCurrentChunkTextLength"] as? NSNumber)?.intValue,
            layoutCurrentChunkBodyChildCount: dictionary["layoutCurrentChunkBodyChildCount"] as? Int ?? (dictionary["layoutCurrentChunkBodyChildCount"] as? NSNumber)?.intValue,
            layoutCurrentChunkBodyTextLength: dictionary["layoutCurrentChunkBodyTextLength"] as? Int ?? (dictionary["layoutCurrentChunkBodyTextLength"] as? NSNumber)?.intValue,
            layoutCurrentChunkBodyDisplay: dictionary["layoutCurrentChunkBodyDisplay"] as? String,
            layoutCurrentChunkBodyPosition: dictionary["layoutCurrentChunkBodyPosition"] as? String,
            layoutCurrentChunkBodyFlex: dictionary["layoutCurrentChunkBodyFlex"] as? String,
            layoutColumnCount: dictionary["layoutColumnCount"] as? Int ?? (dictionary["layoutColumnCount"] as? NSNumber)?.intValue,
            layoutCurrentPageIndex: dictionary["layoutCurrentPageIndex"] as? Int ?? (dictionary["layoutCurrentPageIndex"] as? NSNumber)?.intValue,
            layoutCurrentPageChunkCount: dictionary["layoutCurrentPageChunkCount"] as? Int ?? (dictionary["layoutCurrentPageChunkCount"] as? NSNumber)?.intValue,
            layoutMaxPageChunkCount: dictionary["layoutMaxPageChunkCount"] as? Int ?? (dictionary["layoutMaxPageChunkCount"] as? NSNumber)?.intValue,
            layoutUnitCount: dictionary["layoutUnitCount"] as? Int ?? (dictionary["layoutUnitCount"] as? NSNumber)?.intValue,
            layoutActiveBuildPageIndex: dictionary["layoutActiveBuildPageIndex"] as? Int ?? (dictionary["layoutActiveBuildPageIndex"] as? NSNumber)?.intValue,
            layoutComplete: dictionary["layoutComplete"] as? Bool ?? (dictionary["layoutComplete"] as? NSNumber)?.boolValue,
            layoutSpreadCandidateDetected: dictionary["layoutSpreadCandidateDetected"] as? Bool ?? (dictionary["layoutSpreadCandidateDetected"] as? NSNumber)?.boolValue,
            layoutVisibleUnitKind: dictionary["layoutVisibleUnitKind"] as? String,
            layoutVisibleUnitAxis: dictionary["layoutVisibleUnitAxis"] as? String,
            layoutVisiblePageCount: dictionary["layoutVisiblePageCount"] as? Int ?? (dictionary["layoutVisiblePageCount"] as? NSNumber)?.intValue,
            layoutCurrentUnitIndex: dictionary["layoutCurrentUnitIndex"] as? Int ?? (dictionary["layoutCurrentUnitIndex"] as? NSNumber)?.intValue,
            layoutLeadingPageIndex: dictionary["layoutLeadingPageIndex"] as? Int ?? (dictionary["layoutLeadingPageIndex"] as? NSNumber)?.intValue,
            layoutTrailingPageIndex: dictionary["layoutTrailingPageIndex"] as? Int ?? (dictionary["layoutTrailingPageIndex"] as? NSNumber)?.intValue,
            layoutHasLeadingSingleton: dictionary["layoutHasLeadingSingleton"] as? Bool ?? (dictionary["layoutHasLeadingSingleton"] as? NSNumber)?.boolValue,
            layoutHasTrailingSingleton: dictionary["layoutHasTrailingSingleton"] as? Bool ?? (dictionary["layoutHasTrailingSingleton"] as? NSNumber)?.boolValue,
            layoutMultiUnitActive: dictionary["layoutMultiUnitActive"] as? Bool ?? (dictionary["layoutMultiUnitActive"] as? NSNumber)?.boolValue,
            layoutSpreadPagesAllowedForViewport: dictionary["layoutSpreadPagesAllowedForViewport"] as? Bool ?? (dictionary["layoutSpreadPagesAllowedForViewport"] as? NSNumber)?.boolValue,
            layoutWritingMode: dictionary["layoutWritingMode"] as? String,
            layoutViewportWidth: dictionary["layoutViewportWidth"] as? Int ?? (dictionary["layoutViewportWidth"] as? NSNumber)?.intValue,
            layoutViewportHeight: dictionary["layoutViewportHeight"] as? Int ?? (dictionary["layoutViewportHeight"] as? NSNumber)?.intValue,
            layoutMeasuredGap: dictionary["layoutMeasuredGap"] as? Double ?? (dictionary["layoutMeasuredGap"] as? NSNumber)?.doubleValue,
            layoutMetricSize: dictionary["layoutMetricSize"] as? Int ?? (dictionary["layoutMetricSize"] as? NSNumber)?.intValue,
            layoutColumnInlineSize: dictionary["layoutColumnInlineSize"] as? Int ?? (dictionary["layoutColumnInlineSize"] as? NSNumber)?.intValue,
            layoutCurrentChunkClientWidth: dictionary["layoutCurrentChunkClientWidth"] as? Int ?? (dictionary["layoutCurrentChunkClientWidth"] as? NSNumber)?.intValue,
            layoutCurrentChunkClientHeight: dictionary["layoutCurrentChunkClientHeight"] as? Int ?? (dictionary["layoutCurrentChunkClientHeight"] as? NSNumber)?.intValue,
            layoutCurrentChunkScrollWidth: dictionary["layoutCurrentChunkScrollWidth"] as? Int ?? (dictionary["layoutCurrentChunkScrollWidth"] as? NSNumber)?.intValue,
            layoutCurrentChunkScrollHeight: dictionary["layoutCurrentChunkScrollHeight"] as? Int ?? (dictionary["layoutCurrentChunkScrollHeight"] as? NSNumber)?.intValue,
            layoutCurrentChunkOverflow: dictionary["layoutCurrentChunkOverflow"] as? Bool ?? (dictionary["layoutCurrentChunkOverflow"] as? NSNumber)?.boolValue,
            computedFontSizeCSS: dictionary["computedFontSizeCSS"] as? String,
            currentPageTextSample: dictionary["currentPageTextSample"] as? String,
            nextPageTextSample: dictionary["nextPageTextSample"] as? String,
            currentPageDisplayLabel: dictionary["currentPageDisplayLabel"] as? String,
            currentPhysicalPageLabel: dictionary["currentPhysicalPageLabel"] as? String,
            loadEBookStarted: readerPageTurnBool(dictionary["loadEBookStarted"]),
            loadEBookReady: readerPageTurnBool(dictionary["loadEBookReady"]),
            loadEBookAttemptCount: dictionary["loadEBookAttemptCount"] as? Int ?? (dictionary["loadEBookAttemptCount"] as? NSNumber)?.intValue,
            loadEBookStartAgeMs: dictionary["loadEBookStartAgeMs"] as? Int ?? (dictionary["loadEBookStartAgeMs"] as? NSNumber)?.intValue,
            loadEBookLastState: dictionary["loadEBookLastState"] as? String,
            sameDocumentHostTurnPhase: dictionary["sameDocumentHostTurnPhase"] as? String,
            sameDocumentHostTurnDirection: dictionary["sameDocumentHostTurnDirection"] as? String,
            sameDocumentHostTurnCurrentPageIndex: dictionary["sameDocumentHostTurnCurrentPageIndex"] as? Int ?? (dictionary["sameDocumentHostTurnCurrentPageIndex"] as? NSNumber)?.intValue,
            sameDocumentHostTurnTargetPageIndex: dictionary["sameDocumentHostTurnTargetPageIndex"] as? Int ?? (dictionary["sameDocumentHostTurnTargetPageIndex"] as? NSNumber)?.intValue,
            sameDocumentHostTurnPageCount: dictionary["sameDocumentHostTurnPageCount"] as? Int ?? (dictionary["sameDocumentHostTurnPageCount"] as? NSNumber)?.intValue,
            sameDocumentHostTurnDatasetCurrentPageIndex: dictionary["sameDocumentHostTurnDatasetCurrentPageIndex"] as? Int ?? (dictionary["sameDocumentHostTurnDatasetCurrentPageIndex"] as? NSNumber)?.intValue,
            sameDocumentHostTurnResult: dictionary["sameDocumentHostTurnResult"] as? String,
            probeError: dictionary["probeError"] as? String
        )
        lastProbeError = probe.probeError
        if ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" {
            Logger.shared.logger.info("# PAGETURN navProbe.fetch \(probe.logPayload)")
        }
        return probe
    }

    func refreshNavigationState(preferredFrameOverride: WKFrameInfo? = nil) async -> ReaderPageTurnNavigationProbe? {
        let probe = await fetchNavigationProbe(preferredFrameOverride: preferredFrameOverride)
        applyNavigationProbe(probe)
        return probe
    }

    func refreshNavigationStateBounded(
        preferredFrameOverride: WKFrameInfo? = nil,
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        pollNanoseconds: UInt64 = 100_000_000
    ) async -> ReaderPageTurnNavigationProbe? {
        let resultBox = ReaderPageTurnNavigationProbeResultBox()
        let task = Task { @MainActor in
            let probe = await refreshNavigationState(preferredFrameOverride: preferredFrameOverride)
            await resultBox.set(probe)
        }
        let timeoutDate = Date().addingTimeInterval(TimeInterval(timeoutNanoseconds) / 1_000_000_000)
        while Date() < timeoutDate {
            let result = await resultBox.get()
            if result.completed {
                return result.probe
            }
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
        task.cancel()
        return nil
    }

    func moveToTextStartForDiagnostics() async -> Bool {
        guard let scriptCaller else { return false }
        let frame = readerPageTurnFrameInfo()
        let script = """
        const view = globalThis.reader?.view;
        const renderer = view?.renderer;
        try {
          if (!view) {
            return 'error:noView';
          }
          if (typeof view.goToTextStart === 'function') {
            await view.goToTextStart();
            return 'ok:goToTextStart';
          }
          if (typeof renderer?.firstSection === 'function') {
            await renderer.firstSection();
            return 'ok:firstSection';
          }
          if (typeof view.goTo === 'function') {
            await view.goTo(0);
            return 'ok:goToZero';
          }
          return 'error:noMethod';
        } catch (error) {
          return `error:${String(error)}`;
        }
        """
        do {
            let result = try await scriptCaller.evaluateJavaScript(script, in: frame)
            let status = result as? String ?? String(describing: result)
            let didMove = status.hasPrefix("ok:")
            if didMove {
                _ = await refreshNavigationState()
            } else if ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" {
                Logger.shared.logger.warning("# PAGETURN autoSequence.reanchor.error status=\(status)")
            }
            return didMove
        } catch {
            if ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" {
                Logger.shared.logger.warning("# PAGETURN autoSequence.reanchor.error error=\(error.localizedDescription)")
            }
            return false
        }
    }

    private func applyNavigationProbe(_ probe: ReaderPageTurnNavigationProbe?) {
        supportsActivePageTurn = probe?.supportsActivePageTurn ?? false
        pageProgressionDirection = probe?.pageProgressionDirection ?? .leftToRight
        resolvedPaginationMode = probe?.resolvedPaginationMode ?? .leftToRight
        hasView = probe?.hasView ?? false
        hasRenderer = probe?.hasRenderer ?? false
        canNext = probe?.canNext ?? false
        canPrev = probe?.canPrev ?? false
        hasSectionLayoutController = probe?.hasSectionLayoutController ?? false
        bookDirection = probe?.bookDirection
        isRightToLeft = probe?.isRightToLeft ?? false
        isVertical = probe?.isVertical ?? false
        isVerticalRightToLeft = probe?.isVerticalRightToLeft ?? false
        currentSectionIndex = probe?.currentSectionIndex
        currentSectionHref = probe?.currentSectionHref
        currentPage = probe?.currentPage
        livePageIndex = probe?.livePageIndex
        liveChunkPageIndex = probe?.liveChunkPageIndex
        viewportCenterChunkPageIndex = probe?.viewportCenterChunkPageIndex
        pageCount = probe?.pageCount
        layoutPageRecordCount = probe?.layoutPageRecordCount
        layoutLiveRootExists = probe?.layoutLiveRootExists
        layoutLiveRootClassName = probe?.layoutLiveRootClassName
        layoutLiveRootChildCount = probe?.layoutLiveRootChildCount
        layoutLiveRootRectWidth = probe?.layoutLiveRootRectWidth
        layoutLiveRootRectHeight = probe?.layoutLiveRootRectHeight
        layoutLiveCurrentPageExists = probe?.layoutLiveCurrentPageExists
        layoutLiveCurrentPageClassName = probe?.layoutLiveCurrentPageClassName
        layoutLiveCurrentPageRectWidth = probe?.layoutLiveCurrentPageRectWidth
        layoutLiveCurrentPageRectHeight = probe?.layoutLiveCurrentPageRectHeight
        layoutLiveCurrentPageContainsChunkBody = probe?.layoutLiveCurrentPageContainsChunkBody
        layoutLiveCurrentChunkExists = probe?.layoutLiveCurrentChunkExists
        layoutLiveCurrentChunkTagName = probe?.layoutLiveCurrentChunkTagName
        layoutLiveCurrentChunkClassName = probe?.layoutLiveCurrentChunkClassName
        layoutLiveCurrentChunkDisplay = probe?.layoutLiveCurrentChunkDisplay
        layoutLiveCurrentChunkPosition = probe?.layoutLiveCurrentChunkPosition
        layoutLiveCurrentChunkFlex = probe?.layoutLiveCurrentChunkFlex
        layoutLiveCurrentChunkRectWidth = probe?.layoutLiveCurrentChunkRectWidth
        layoutLiveCurrentChunkRectHeight = probe?.layoutLiveCurrentChunkRectHeight
        layoutLiveCurrentChunkInnerHTMLLength = probe?.layoutLiveCurrentChunkInnerHTMLLength
        layoutLiveCurrentChunkContainsChunkBody = probe?.layoutLiveCurrentChunkContainsChunkBody
        layoutLiveCurrentChunkChildCount = probe?.layoutLiveCurrentChunkChildCount
        layoutLiveCurrentChunkTextLength = probe?.layoutLiveCurrentChunkTextLength
        layoutCurrentChunkBodyChildCount = probe?.layoutCurrentChunkBodyChildCount
        layoutCurrentChunkBodyTextLength = probe?.layoutCurrentChunkBodyTextLength
        layoutCurrentChunkBodyDisplay = probe?.layoutCurrentChunkBodyDisplay
        layoutCurrentChunkBodyPosition = probe?.layoutCurrentChunkBodyPosition
        layoutCurrentChunkBodyFlex = probe?.layoutCurrentChunkBodyFlex
        layoutColumnCount = probe?.layoutColumnCount
        layoutCurrentPageIndex = probe?.layoutCurrentPageIndex
        layoutCurrentPageChunkCount = probe?.layoutCurrentPageChunkCount
        layoutMaxPageChunkCount = probe?.layoutMaxPageChunkCount
        layoutUnitCount = probe?.layoutUnitCount
        layoutActiveBuildPageIndex = probe?.layoutActiveBuildPageIndex
        layoutComplete = probe?.layoutComplete
        layoutSpreadCandidateDetected = probe?.layoutSpreadCandidateDetected
        layoutVisibleUnitKind = probe?.layoutVisibleUnitKind
        layoutVisibleUnitAxis = probe?.layoutVisibleUnitAxis
        layoutVisiblePageCount = probe?.layoutVisiblePageCount
        layoutCurrentUnitIndex = probe?.layoutCurrentUnitIndex
        layoutLeadingPageIndex = probe?.layoutLeadingPageIndex
        layoutTrailingPageIndex = probe?.layoutTrailingPageIndex
        layoutHasLeadingSingleton = probe?.layoutHasLeadingSingleton
        layoutHasTrailingSingleton = probe?.layoutHasTrailingSingleton
        layoutPrimarySpacing = probe?.layoutPrimarySpacing
        layoutMultiUnitActive = probe?.layoutMultiUnitActive
        layoutSpreadPagesAllowedForViewport = probe?.layoutSpreadPagesAllowedForViewport
        layoutWritingMode = probe?.layoutWritingMode
        layoutViewportWidth = probe?.layoutViewportWidth
        layoutViewportHeight = probe?.layoutViewportHeight
        layoutMeasuredGap = probe?.layoutMeasuredGap
        layoutMetricSize = probe?.layoutMetricSize
        layoutColumnInlineSize = probe?.layoutColumnInlineSize
        layoutCurrentChunkClientWidth = probe?.layoutCurrentChunkClientWidth
        layoutCurrentChunkClientHeight = probe?.layoutCurrentChunkClientHeight
        layoutCurrentChunkScrollWidth = probe?.layoutCurrentChunkScrollWidth
        layoutCurrentChunkScrollHeight = probe?.layoutCurrentChunkScrollHeight
        layoutCurrentChunkOverflow = probe?.layoutCurrentChunkOverflow
        computedFontSizeCSS = probe?.computedFontSizeCSS
        currentPageTextSample = probe?.currentPageTextSample
        nextPageTextSample = probe?.nextPageTextSample
        currentPageDisplayLabel = probe?.currentPageDisplayLabel
        currentPhysicalPageLabel = probe?.currentPhysicalPageLabel
        loadEBookStarted = probe?.loadEBookStarted ?? false
        loadEBookReady = probe?.loadEBookReady ?? false
        loadEBookAttemptCount = probe?.loadEBookAttemptCount
        loadEBookStartAgeMs = probe?.loadEBookStartAgeMs
        loadEBookLastState = probe?.loadEBookLastState
        sameDocumentHostTurnPhase = probe?.sameDocumentHostTurnPhase
        sameDocumentHostTurnDirection = probe?.sameDocumentHostTurnDirection
        sameDocumentHostTurnCurrentPageIndex = probe?.sameDocumentHostTurnCurrentPageIndex
        sameDocumentHostTurnTargetPageIndex = probe?.sameDocumentHostTurnTargetPageIndex
        sameDocumentHostTurnPageCount = probe?.sameDocumentHostTurnPageCount
        sameDocumentHostTurnDatasetCurrentPageIndex = probe?.sameDocumentHostTurnDatasetCurrentPageIndex
        sameDocumentHostTurnResult = probe?.sameDocumentHostTurnResult
        pageLabelDisplayMode = probe?.pageLabelDisplayMode
        usesPhysicalPageLabels = probe?.usesPhysicalPageLabels
        canForward = probe?.canSemanticForward ?? false
        canBackward = probe?.canSemanticBackward ?? false
    }

    private func readerPageTurnFrameInfo() -> WKFrameInfo? {
        let pageURL = lastKnownState.pageURL
        if let directFrame = scriptCaller?.frame(forUUID: "ebook-viewer-frame:\(pageURL.absoluteString)") {
            return directFrame
        }
        if let canonicalFrame = scriptCaller?.frame(for: pageURL.canonicalReaderContentURL()) {
            return canonicalFrame
        }
        if let pageURLFrame = scriptCaller?.frame(for: lastKnownState.pageURL) {
            return pageURLFrame
        }
        return scriptCaller?.mainFrameInfo
    }

    private func readerPageTurnCandidateFrames(
        preferredFrameOverride: WKFrameInfo? = nil,
        scriptCaller: WebViewScriptCaller
    ) -> [WKFrameInfo?] {
        let preferredFrame = preferredFrameOverride ?? readerPageTurnFrameInfo()
        var frames = [WKFrameInfo?]()
        frames.append(preferredFrame)
        let mainFrame = scriptCaller.mainFrameInfo
        if mainFrame !== preferredFrame {
            frames.append(mainFrame)
        }
        frames.append(nil)
        return frames
    }

    private func evaluateJavaScriptAcrossReaderPageTurnFrames(
        _ script: String,
        preferredFrameOverride: WKFrameInfo? = nil,
        scriptCaller: WebViewScriptCaller
    ) async throws -> Any? {
        var lastError: Error?
        for frame in readerPageTurnCandidateFrames(preferredFrameOverride: preferredFrameOverride, scriptCaller: scriptCaller) {
            do {
                return try await scriptCaller.evaluateJavaScript(script, in: frame)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NSError(
            domain: "ReaderPageTurnBridge",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "No candidate frame succeeded"]
        )
    }

    private func issueJavaScriptAcrossReaderPageTurnFrames(
        _ script: String,
        preferredFrameOverride: WKFrameInfo? = nil,
        scriptCaller: WebViewScriptCaller
    ) async {
        for frame in readerPageTurnCandidateFrames(
            preferredFrameOverride: preferredFrameOverride,
            scriptCaller: scriptCaller
        ) {
            _ = try? await scriptCaller.evaluateJavaScript(script, in: frame)
        }
    }

    private func waitForCommittedTurnProbe(
        direction: PageTurnDirection,
        baselineProbe: ReaderPageTurnNavigationProbe?,
        timeoutNanoseconds: UInt64,
        pollNanoseconds: UInt64
    ) async throws -> ReaderPageTurnNavigationProbe? {
        let timeoutDate = Date().addingTimeInterval(TimeInterval(timeoutNanoseconds) / 1_000_000_000)
        while Date() < timeoutDate {
            let refreshedProbe = await refreshNavigationStateBounded(
                timeoutNanoseconds: min(pollNanoseconds * 3, 1_500_000_000),
                pollNanoseconds: min(pollNanoseconds, 100_000_000)
            )
            let probe = refreshedProbe ?? currentCachedNavigationProbe()
            if let baselineProbe {
                if probe.hasMeaningfulNavigationChange(comparedTo: baselineProbe) {
                    return probe
                }
            } else {
                let didAdvance = switch direction {
                case .forward:
                    probe.canBackward || probe.currentPage != nil || probe.currentSectionIndex != nil
                case .backward:
                    probe.currentPage != nil || probe.currentSectionIndex != nil
                }
                if didAdvance {
                    return probe
                }
            }
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
        return nil
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
        && (canNext || canPrev)
        && hasSectionLayoutController
    }

    func hasLocationOrContentAdvance(comparedTo baseline: Self) -> Bool {
        hasMeaningfulNavigationChange(comparedTo: baseline)
    }

    func materiallyExpandedPagination(comparedTo baseline: Self) -> Bool {
        if (pageCount ?? 0) > (baseline.pageCount ?? 0) {
            return true
        }
        if (layoutPageRecordCount ?? 0) > (baseline.layoutPageRecordCount ?? 0) {
            return true
        }
        if (layoutActiveBuildPageIndex ?? 0) > (baseline.layoutActiveBuildPageIndex ?? 0) {
            return true
        }
        return false
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

        Logger.shared.logger.info("# PAGETURN identity \(snapshot.dictionaryRepresentation)")

        guard let previousSnapshot else { return }

        if previousSnapshot.pageURL == snapshot.pageURL,
           previousSnapshot.navigatorObjectID == snapshot.navigatorObjectID,
           previousSnapshot.liveWebViewIdentifier != nil,
           snapshot.liveWebViewIdentifier != nil,
           previousSnapshot.liveWebViewIdentifier != snapshot.liveWebViewIdentifier {
            let warningPayload: [String: Any] = [
                "kind": "liveWebViewChanged",
                "pageURL": snapshot.pageURL,
                "previousLiveWebViewIdentifier": previousSnapshot.liveWebViewIdentifier ?? "nil",
                "nextLiveWebViewIdentifier": snapshot.liveWebViewIdentifier ?? "nil",
                "previousActiveEnabled": previousSnapshot.activeEnabled,
                "nextActiveEnabled": snapshot.activeEnabled,
                "previousMountedHostIdentifier": previousSnapshot.mountedHostIdentifier ?? "nil",
                "nextMountedHostIdentifier": snapshot.mountedHostIdentifier ?? "nil",
            ]
            Logger.shared.logger.warning(
                "# PAGETURN identity.warning \(warningPayload)"
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
    @State private var autoProbeSequenceDidRun = false

    @Environment(\.webViewNavigator) private var navigator
    @Environment(\.colorScheme) private var colorScheme
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
        .task(id: layoutSemanticsKey) {
            refreshLayoutSemantics()
        }
        .task(id: bridge.pageProgressionDirection) {
            controller.setPageProgressionDirection(bridge.pageProgressionDirection)
        }
        .task(id: readerViewModel.pageTurnBootstrapSerial) {
            guard readerViewModel.pageTurnBootstrapSerial > 0 else { return }
            _ = await bridge.refreshNavigationState()
            controller.setPageProgressionDirection(bridge.pageProgressionDirection)
            let snapshot = await makeProbeSnapshot()
            probeModel.update(snapshot)
            logProbeSnapshotIfEnabled(snapshot)
        }
        .task(id: bridgeBootstrapPollingKey) {
            guard shouldPollBridgeBootstrap else { return }
            let maxAttempts = 120
            let pollNanoseconds: UInt64 = 500_000_000
            for _ in 1...maxAttempts {
                guard shouldPollBridgeBootstrap else { break }
                _ = await bridge.refreshNavigationState()
                controller.setPageProgressionDirection(bridge.pageProgressionDirection)
                let snapshot = await makeProbeSnapshot()
                probeModel.update(snapshot)
                logProbeSnapshotIfEnabled(snapshot)
                if snapshot.supportsActivePageTurn {
                    break
                }
                try? await Task.sleep(nanoseconds: pollNanoseconds)
            }
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
            await runAutomaticProbeSequenceIfNeeded(snapshot)
        }
        .task(id: probeCommandBindingKey) {
            probeModel.bindCommandHandler { command in
                await handleProbeCommand(command)
            }
            probeModel.bindRefreshHandler {
                await refreshAndPublishProbeSnapshot()
            }
        }
        .task(id: bridgeRefreshKey) {
            readerViewModel.setPageTurnProbeRefreshHandler { frameInfo in
                _ = await refreshAndPublishProbeSnapshot(preferredFrameOverride: frameInfo)
            }
        }
        .onDisappear {
            readerViewModel.setPageTurnProbeRefreshHandler(nil)
        }
    }

    private var bridgeRefreshKey: String {
        let paginationState = readerViewModel.state.paginationState
        return [
            requestedEnabled ? "requested" : "passThrough",
            readerViewModel.state.pageURL.absoluteString,
            String(readerViewModel.pageTurnBootstrapSerial),
            readerViewModel.state.isLoading ? "loading" : "loaded",
            readerViewModel.state.isProvisionallyNavigating ? "provisional" : "committed",
            readerViewModel.state.pageTitle ?? "nil",
            paginationState?.appliedHostIdentifier ?? "nil",
            paginationState?.mountedHostIdentifier ?? "nil",
            paginationState.map { String($0.appliedConfiguration?.mode.rawValue ?? -1) } ?? "nil",
            paginationState?.pageCount.map(String.init) ?? "nil",
            paginationState?.isAppliedToMountedHost == true ? "applied" : "notApplied",
            navigator.hasAttachedWebView ? "attached" : "detached",
        ].joined(separator: "|")
    }

    private var shouldPollBridgeBootstrap: Bool {
        requestedEnabled
            && isStructurallyEligibleForActiveTurns
            && !bridge.supportsActivePageTurn
    }

    private var bridgeBootstrapPollingKey: String {
        [
            requestedEnabled ? "requested" : "passThrough",
            isStructurallyEligibleForActiveTurns ? "eligible" : "ineligible",
            bridge.supportsActivePageTurn ? "bridgeReady" : "bridgePending",
            readerViewModel.state.pageURL.absoluteString,
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

    private var layoutSemanticsKey: String {
        let visibleUnitKind = bridge.layoutVisibleUnitKind ?? "nil"
        let visibleUnitAxis = bridge.layoutVisibleUnitAxis ?? "nil"
        let visiblePageCount = bridge.layoutVisiblePageCount.map(String.init) ?? "nil"
        let currentUnitIndex = bridge.layoutCurrentUnitIndex.map(String.init) ?? "nil"
        let leadingPageIndex = bridge.layoutLeadingPageIndex.map(String.init) ?? "nil"
        let trailingPageIndex = bridge.layoutTrailingPageIndex.map(String.init) ?? "nil"
        let hasLeadingSingleton = bridge.layoutHasLeadingSingleton.map(String.init) ?? "nil"
        let hasTrailingSingleton = bridge.layoutHasTrailingSingleton.map(String.init) ?? "nil"
        let primarySpacing = String(describing: resolvedPrimarySpacing())
        let measuredGap = bridge.layoutMeasuredGap.map { String($0) } ?? "nil"
        let multiUnitActive = bridge.layoutMultiUnitActive.map(String.init) ?? "nil"
        let spreadPagesAllowed = bridge.layoutSpreadPagesAllowedForViewport.map(String.init) ?? "nil"
        let columnCount = bridge.layoutColumnCount.map(String.init) ?? "nil"
        let columnInlineSize = bridge.layoutColumnInlineSize.map(String.init) ?? "nil"
        let axisOrientation = bridge.isVertical ? "vertical" : "horizontal"
        let writingMode = bridge.layoutWritingMode ?? "nil"
        return [
            visibleUnitKind,
            visibleUnitAxis,
            visiblePageCount,
            currentUnitIndex,
            leadingPageIndex,
            trailingPageIndex,
            hasLeadingSingleton,
            hasTrailingSingleton,
            primarySpacing,
            measuredGap,
            multiUnitActive,
            spreadPagesAllowed,
            columnCount,
            columnInlineSize,
            axisOrientation,
            writingMode,
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

    private func refreshLayoutSemantics() {
        let visibleUnit = resolvedVisibleUnit()
        let pageLabelPolicy = resolvedPageLabelPolicy(visibleUnit: visibleUnit)
        let platformFamily = readerPageTurnPlatformFamily()
        let chromeVisibility = PageTurnChromeVisibility(
            showTitle: true,
            showHeader: platformFamily != .iPhone
        )
        navigator.paginationStateEnrichment = WebViewPaginationStateEnrichment(
            visibleUnit: resolvedWebViewVisibleUnit(from: visibleUnit),
            pageLabelPolicy: resolvedWebViewPageLabelPolicy(from: pageLabelPolicy)
        )
        layoutModel.update(
            containerBounds: layoutModel.inputs.containerBounds,
            safeAreaInsets: layoutModel.inputs.safeAreaInsets,
            platformFamily: platformFamily,
            appearance: colorScheme == .dark ? .dark : .light,
            chromeVisibility: chromeVisibility,
            visibleUnit: visibleUnit,
            pageLabelPolicy: pageLabelPolicy,
            provider: .readerDefault
        )
    }

    private func resolvedVisibleUnit() -> PageTurnVisibleUnit {
        if !hasLiveVisibleUnitSemantics(),
           let enrichedVisibleUnit = readerViewModel.state.paginationState?.visibleUnit {
            return resolvedPageTurnVisibleUnit(from: enrichedVisibleUnit)
        }
        let kind = resolvedVisibleUnitKind()
        let axis = resolvedVisibleUnitAxis()
        let visiblePageCount = max(1, bridge.layoutVisiblePageCount ?? bridge.layoutColumnCount ?? 1)
        return PageTurnVisibleUnit(
            kind: kind,
            axis: axis,
            visiblePageCount: visiblePageCount,
            primarySpacing: resolvedPrimarySpacing(),
            currentUnitIndex: bridge.layoutCurrentUnitIndex,
            leadingPageIndex: bridge.layoutLeadingPageIndex,
            trailingPageIndex: bridge.layoutTrailingPageIndex,
            hasLeadingSingleton: bridge.layoutHasLeadingSingleton ?? false,
            hasTrailingSingleton: bridge.layoutHasTrailingSingleton ?? false
        )
    }

    private func hasLiveVisibleUnitSemantics() -> Bool {
        bridge.layoutVisibleUnitKind != nil
            || bridge.layoutVisibleUnitAxis != nil
            || bridge.layoutVisiblePageCount != nil
            || bridge.layoutCurrentUnitIndex != nil
            || bridge.layoutLeadingPageIndex != nil
            || bridge.layoutTrailingPageIndex != nil
            || bridge.layoutHasLeadingSingleton != nil
            || bridge.layoutHasTrailingSingleton != nil
            || bridge.layoutSpreadPagesAllowedForViewport != nil
    }

    private func resolvedVisibleUnitKind() -> PageTurnVisibleUnitKind {
        switch bridge.layoutVisibleUnitKind {
        case "pageSpread":
            return .pageSpread
        case "paginatedRowSet":
            return .paginatedRowSet
        default:
            return .singlePage
        }
    }

    private func resolvedVisibleUnitAxis() -> PageTurnVisibleUnitAxis {
        switch bridge.layoutVisibleUnitAxis {
        case "vertical":
            return .vertical
        default:
            return .horizontal
        }
    }

    private func resolvedPageLabelPolicy(visibleUnit: PageTurnVisibleUnit) -> PageTurnPageLabelPolicy {
        let columnCount = max(1, visibleUnit.visiblePageCount)
        let usesPhysicalPageLabels =
            bridge.currentPhysicalPageLabel != nil
            || readerViewModel.state.paginationState?.pageLabelPolicy?.usesPhysicalPageLabels == true
        let preferredDisplayMode = preferredPageLabelDisplayMode(for: visibleUnit)
        return PageTurnPageLabelPolicy.derived(
            columnCount: columnCount,
            usesPhysicalPageLabels: usesPhysicalPageLabels,
            allowsMultipleLabelsInTwoColumnLayout: preferredDisplayMode == .multipleLabels
        )
    }

    private func preferredPageLabelDisplayMode(
        for visibleUnit: PageTurnVisibleUnit
    ) -> WebViewPaginationPageLabelDisplayMode {
        if !visibleUnit.usesMultiUnitSurface {
            return .singleLabel
        }
        if let enrichedPolicy = readerViewModel.state.paginationState?.pageLabelPolicy {
            return enrichedPolicy.displayMode
        }
        return .multipleLabels
    }

    private func resolvedPageTurnVisibleUnit(from visibleUnit: WebViewPaginationVisibleUnit) -> PageTurnVisibleUnit {
        let kind: PageTurnVisibleUnitKind = switch visibleUnit.kind {
        case .singlePage: .singlePage
        case .pageSpread: .pageSpread
        case .paginatedRowSet: .paginatedRowSet
        }
        let axis: PageTurnVisibleUnitAxis = switch visibleUnit.axis {
        case .horizontal: .horizontal
        case .vertical: .vertical
        }
        return PageTurnVisibleUnit(
            kind: kind,
            axis: axis,
            visiblePageCount: visibleUnit.visiblePageCount,
            primarySpacing: max(0, visibleUnit.primarySpacing),
            currentUnitIndex: visibleUnit.currentUnitIndex,
            leadingPageIndex: visibleUnit.leadingPageIndex,
            trailingPageIndex: visibleUnit.trailingPageIndex,
            hasLeadingSingleton: visibleUnit.hasLeadingSingleton,
            hasTrailingSingleton: visibleUnit.hasTrailingSingleton
        )
    }

    private func resolvedPrimarySpacing() -> CGFloat {
        if let measuredGap = bridge.layoutMeasuredGap {
            return max(0, measuredGap)
        }
        if let appliedGap = readerViewModel.state.paginationState?.appliedConfiguration?.gapBetweenPages {
            return max(0, appliedGap)
        }
        if let desiredGap = readerViewModel.state.paginationState?.desiredConfiguration.gapBetweenPages {
            return max(0, desiredGap)
        }
        return 0
    }

    private func resolvedWebViewVisibleUnit(from visibleUnit: PageTurnVisibleUnit) -> WebViewPaginationVisibleUnit {
        let kind: WebViewPaginationVisibleUnitKind
        switch visibleUnit.kind {
        case .singlePage:
            kind = .singlePage
        case .pageSpread:
            kind = .pageSpread
        case .paginatedRowSet:
            kind = .paginatedRowSet
        }
        let axis: WebViewPaginationVisibleUnitAxis = switch visibleUnit.axis {
        case .horizontal: .horizontal
        case .vertical: .vertical
        }
        let spreadPagesAllowedForViewport = visibleUnit.kind != .singlePage
            || visibleUnit.hasLeadingSingleton
            || visibleUnit.hasTrailingSingleton
        return WebViewPaginationVisibleUnit(
            kind: kind,
            axis: axis,
            visiblePageCount: visibleUnit.visiblePageCount,
            primarySpacing: max(0, visibleUnit.primarySpacing),
            currentUnitIndex: visibleUnit.currentUnitIndex,
            leadingPageIndex: visibleUnit.leadingPageIndex,
            trailingPageIndex: visibleUnit.trailingPageIndex,
            hasLeadingSingleton: visibleUnit.hasLeadingSingleton,
            hasTrailingSingleton: visibleUnit.hasTrailingSingleton,
            spreadPagesAllowedForViewport: spreadPagesAllowedForViewport
        )
    }

    private func resolvedWebViewPageLabelPolicy(from pageLabelPolicy: PageTurnPageLabelPolicy) -> WebViewPaginationPageLabelPolicy {
        let displayMode: WebViewPaginationPageLabelDisplayMode = switch pageLabelPolicy.displayMode {
        case .singleLabel: .singleLabel
        case .multipleLabels: .multipleLabels
        }
        return WebViewPaginationPageLabelPolicy(
            displayMode: displayMode,
            usesPhysicalPageLabels: pageLabelPolicy.usesPhysicalPageLabels
        )
    }

    private func makeProbeSnapshot() async -> ReaderPageTurnProbeSnapshot {
        let liveWebViewIdentifier = await navigator.withAttachedWebView { webView in
            String(describing: ObjectIdentifier(webView))
        } ?? nil
        let paginationState = readerViewModel.state.paginationState
        let interaction = controller.lastInteractionEvent
        let pageLabelPolicy = resolvedPageLabelPolicy(visibleUnit: resolvedVisibleUnit())
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
            hasView: bridge.hasView,
            hasRenderer: bridge.hasRenderer,
            canNext: bridge.canNext,
            canPrev: bridge.canPrev,
            hasSectionLayoutController: bridge.hasSectionLayoutController,
            bookDirection: bridge.bookDirection,
            isRightToLeft: bridge.isRightToLeft,
            isVertical: bridge.isVertical,
            isVerticalRightToLeft: bridge.isVerticalRightToLeft,
            currentSectionIndex: bridge.currentSectionIndex,
            currentSectionHref: bridge.currentSectionHref,
            currentPage: bridge.currentPage,
            livePageIndex: bridge.livePageIndex,
            liveChunkPageIndex: bridge.liveChunkPageIndex,
            viewportCenterChunkPageIndex: bridge.viewportCenterChunkPageIndex,
            pageCount: bridge.pageCount,
            layoutPageRecordCount: bridge.layoutPageRecordCount,
            layoutLiveRootExists: bridge.layoutLiveRootExists,
            layoutLiveRootClassName: bridge.layoutLiveRootClassName,
            layoutLiveRootChildCount: bridge.layoutLiveRootChildCount,
            layoutLiveRootRectWidth: bridge.layoutLiveRootRectWidth,
            layoutLiveRootRectHeight: bridge.layoutLiveRootRectHeight,
            layoutLiveCurrentPageExists: bridge.layoutLiveCurrentPageExists,
            layoutLiveCurrentPageClassName: bridge.layoutLiveCurrentPageClassName,
            layoutLiveCurrentPageRectWidth: bridge.layoutLiveCurrentPageRectWidth,
            layoutLiveCurrentPageRectHeight: bridge.layoutLiveCurrentPageRectHeight,
            layoutLiveCurrentPageContainsChunkBody: bridge.layoutLiveCurrentPageContainsChunkBody,
            layoutLiveCurrentChunkExists: bridge.layoutLiveCurrentChunkExists,
            layoutLiveCurrentChunkTagName: bridge.layoutLiveCurrentChunkTagName,
            layoutLiveCurrentChunkClassName: bridge.layoutLiveCurrentChunkClassName,
            layoutLiveCurrentChunkDisplay: bridge.layoutLiveCurrentChunkDisplay,
            layoutLiveCurrentChunkPosition: bridge.layoutLiveCurrentChunkPosition,
            layoutLiveCurrentChunkFlex: bridge.layoutLiveCurrentChunkFlex,
            layoutLiveCurrentChunkRectWidth: bridge.layoutLiveCurrentChunkRectWidth,
            layoutLiveCurrentChunkRectHeight: bridge.layoutLiveCurrentChunkRectHeight,
            layoutLiveCurrentChunkInnerHTMLLength: bridge.layoutLiveCurrentChunkInnerHTMLLength,
            layoutLiveCurrentChunkContainsChunkBody: bridge.layoutLiveCurrentChunkContainsChunkBody,
            layoutLiveCurrentChunkChildCount: bridge.layoutLiveCurrentChunkChildCount,
            layoutLiveCurrentChunkTextLength: bridge.layoutLiveCurrentChunkTextLength,
            layoutCurrentChunkBodyChildCount: bridge.layoutCurrentChunkBodyChildCount,
            layoutCurrentChunkBodyTextLength: bridge.layoutCurrentChunkBodyTextLength,
            layoutCurrentChunkBodyDisplay: bridge.layoutCurrentChunkBodyDisplay,
            layoutCurrentChunkBodyPosition: bridge.layoutCurrentChunkBodyPosition,
            layoutCurrentChunkBodyFlex: bridge.layoutCurrentChunkBodyFlex,
            layoutColumnCount: bridge.layoutColumnCount,
            layoutCurrentPageIndex: bridge.layoutCurrentPageIndex,
            layoutCurrentPageChunkCount: bridge.layoutCurrentPageChunkCount,
            layoutMaxPageChunkCount: bridge.layoutMaxPageChunkCount,
            layoutUnitCount: bridge.layoutUnitCount,
            layoutActiveBuildPageIndex: bridge.layoutActiveBuildPageIndex,
            layoutComplete: bridge.layoutComplete,
            layoutSpreadCandidateDetected: bridge.layoutSpreadCandidateDetected,
            layoutVisibleUnitKind: bridge.layoutVisibleUnitKind,
            layoutVisibleUnitAxis: bridge.layoutVisibleUnitAxis,
            layoutVisiblePageCount: bridge.layoutVisiblePageCount,
            layoutCurrentUnitIndex: bridge.layoutCurrentUnitIndex,
            layoutLeadingPageIndex: bridge.layoutLeadingPageIndex,
            layoutTrailingPageIndex: bridge.layoutTrailingPageIndex,
            layoutHasLeadingSingleton: bridge.layoutHasLeadingSingleton,
            layoutHasTrailingSingleton: bridge.layoutHasTrailingSingleton,
            layoutPrimarySpacing: resolvedPrimarySpacing(),
            layoutMultiUnitActive: bridge.layoutMultiUnitActive,
            layoutSpreadPagesAllowedForViewport: bridge.layoutSpreadPagesAllowedForViewport,
            layoutWritingMode: bridge.layoutWritingMode,
            layoutViewportWidth: bridge.layoutViewportWidth,
            layoutViewportHeight: bridge.layoutViewportHeight,
            layoutMeasuredGap: bridge.layoutMeasuredGap,
            layoutMetricSize: bridge.layoutMetricSize,
            layoutColumnInlineSize: bridge.layoutColumnInlineSize,
            layoutCurrentChunkClientWidth: bridge.layoutCurrentChunkClientWidth,
            layoutCurrentChunkClientHeight: bridge.layoutCurrentChunkClientHeight,
            layoutCurrentChunkScrollWidth: bridge.layoutCurrentChunkScrollWidth,
            layoutCurrentChunkScrollHeight: bridge.layoutCurrentChunkScrollHeight,
            layoutCurrentChunkOverflow: bridge.layoutCurrentChunkOverflow,
            computedFontSizeCSS: bridge.computedFontSizeCSS,
            currentPageTextSample: bridge.currentPageTextSample,
            nextPageTextSample: bridge.nextPageTextSample,
            currentPageDisplayLabel: bridge.currentPageDisplayLabel,
            currentPhysicalPageLabel: bridge.currentPhysicalPageLabel,
            loadEBookStarted: bridge.loadEBookStarted,
            loadEBookReady: bridge.loadEBookReady,
            loadEBookAttemptCount: bridge.loadEBookAttemptCount,
            loadEBookStartAgeMs: bridge.loadEBookStartAgeMs,
            loadEBookLastState: bridge.loadEBookLastState,
            sameDocumentHostTurnPhase: bridge.sameDocumentHostTurnPhase,
            sameDocumentHostTurnDirection: bridge.sameDocumentHostTurnDirection,
            sameDocumentHostTurnCurrentPageIndex: bridge.sameDocumentHostTurnCurrentPageIndex,
            sameDocumentHostTurnTargetPageIndex: bridge.sameDocumentHostTurnTargetPageIndex,
            sameDocumentHostTurnPageCount: bridge.sameDocumentHostTurnPageCount,
            sameDocumentHostTurnDatasetCurrentPageIndex: bridge.sameDocumentHostTurnDatasetCurrentPageIndex,
            sameDocumentHostTurnResult: bridge.sameDocumentHostTurnResult,
            pageLabelDisplayMode: pageLabelPolicy.displayMode.rawValue,
            usesPhysicalPageLabels: pageLabelPolicy.usesPhysicalPageLabels,
            canForward: bridge.canForward,
            canBackward: bridge.canBackward,
            interactionKind: interaction?.kind.rawValue,
            interactionQualified: interaction?.qualified,
            interactionDirection: interaction?.direction?.rawValue,
            interactionPrimaryAxisDelta: interaction.map { Double($0.primaryAxisDelta) },
            interactionSecondaryAxisDelta: interaction.map { Double($0.secondaryAxisDelta) },
            interactionProgress: interaction?.progress.map(Double.init),
            interactionVelocity: interaction?.velocity.map(Double.init),
            interactionShouldCommit: interaction?.shouldCommit,
            interactionRefusedOppositeDirectionFlick: interaction?.refusedOppositeDirectionFlick,
            interactionNote: interaction?.note,
            probeError: bridge.lastProbeError
        )
    }

    private func logProbeSnapshotIfEnabled(_ snapshot: ReaderPageTurnProbeSnapshot) {
        let processInfo = ProcessInfo.processInfo
        guard processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1"
              || processInfo.arguments.contains("--ui-test-enable-page-turn-probe") else {
            return
        }
        Logger.shared.logger.info("# PAGETURN probe \(snapshot.summary)")
    }

    private func refreshAndPublishProbeSnapshot(
        preferredFrameOverride: WKFrameInfo? = nil
    ) async -> ReaderPageTurnProbeSnapshot {
        _ = await bridge.refreshNavigationState(preferredFrameOverride: preferredFrameOverride)
        controller.setPageProgressionDirection(bridge.pageProgressionDirection)
        let snapshot = await makeProbeSnapshot()
        probeModel.update(snapshot)
        logProbeSnapshotIfEnabled(snapshot)
        return snapshot
    }

    private var shouldRunAutomaticProbeSequence: Bool {
        ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_AUTO_VERIFY_SEQUENCE"] == "1"
    }

    private func runAutomaticProbeSequenceIfNeeded(_ snapshot: ReaderPageTurnProbeSnapshot) async {
        guard shouldRunAutomaticProbeSequence,
              !autoProbeSequenceDidRun,
              snapshot.activeEnabled,
              snapshot.supportsActivePageTurn else {
            return
        }

        var preparedSnapshot = snapshot
        let shouldReanchorToStart =
            !preparedSnapshot.canForward
            || preparedSnapshot.currentSectionIndex != 0
            || preparedSnapshot.canBackward
        if shouldReanchorToStart {
            let didMoveToStart = await bridge.moveToTextStartForDiagnostics()
            if didMoveToStart {
                let refreshedSnapshot = await makeProbeSnapshot()
                probeModel.update(refreshedSnapshot)
                logProbeSnapshotIfEnabled(refreshedSnapshot)
                preparedSnapshot = refreshedSnapshot
                Logger.shared.logger.info("# PAGETURN autoSequence.reanchor didMoveToStart=true currentSectionIndex=\(preparedSnapshot.currentSectionIndex.map(String.init) ?? "nil") currentPage=\(preparedSnapshot.currentPage.map(String.init) ?? "nil") canForward=\(preparedSnapshot.canForward) canBackward=\(preparedSnapshot.canBackward)")
            } else {
                Logger.shared.logger.warning("# PAGETURN autoSequence.reanchor didMoveToStart=false currentSectionIndex=\(preparedSnapshot.currentSectionIndex.map(String.init) ?? "nil") currentPage=\(preparedSnapshot.currentPage.map(String.init) ?? "nil") canForward=\(preparedSnapshot.canForward) canBackward=\(preparedSnapshot.canBackward)")
            }
        }

        if let stabilizedSnapshot = await waitForStableAutomaticProbeBaseline(
            preferredSectionIndex: shouldReanchorToStart ? 0 : preparedSnapshot.currentSectionIndex,
            preferredPage: shouldReanchorToStart ? 0 : preparedSnapshot.currentPage,
            preferredCanBackward: shouldReanchorToStart ? false : preparedSnapshot.canBackward,
            minimumPageCount: 2
        ) {
            probeModel.update(stabilizedSnapshot)
            logProbeSnapshotIfEnabled(stabilizedSnapshot)
            preparedSnapshot = stabilizedSnapshot
            Logger.shared.logger.info(
                "# PAGETURN autoSequence.stabilized sectionIndex=\(preparedSnapshot.currentSectionIndex.map(String.init) ?? "nil") currentPage=\(preparedSnapshot.currentPage.map(String.init) ?? "nil") pageCount=\(preparedSnapshot.pageCount.map(String.init) ?? "nil") canForward=\(preparedSnapshot.canForward) canBackward=\(preparedSnapshot.canBackward)"
            )
        }

        guard preparedSnapshot.canForward else {
            return
        }

        autoProbeSequenceDidRun = true
        let baselineSectionIndex = preparedSnapshot.currentSectionIndex
        let baselineSectionHref = preparedSnapshot.currentSectionHref
        let baselinePage = preparedSnapshot.currentPage
        let baselineCanBackward = preparedSnapshot.canBackward
        Logger.shared.logger.info("# PAGETURN autoSequence.begin sectionIndex=\(baselineSectionIndex.map(String.init) ?? "nil") sectionHref=\(baselineSectionHref ?? "nil") currentPage=\(baselinePage.map(String.init) ?? "nil") pageCount=\(preparedSnapshot.pageCount.map(String.init) ?? "nil") canForward=\(preparedSnapshot.canForward) canBackward=\(baselineCanBackward)")

        let forwardResult = await handleProbeCommand(.hostForwardTurn)
        guard let initialForwardSnapshot = await waitForAutomaticProbeTransition(
            expectedCommandPrefix: "committed:forward",
            fallbackCommandResult: forwardResult,
            baselineSectionIndex: baselineSectionIndex,
            baselineSectionHref: baselineSectionHref,
            baselinePage: baselinePage,
            baselineCanBackward: baselineCanBackward
        ) else {
            Logger.shared.logger.warning("# PAGETURN autoSequence.forward.unresolved baselinePage=\(baselinePage.map(String.init) ?? "nil") result=\(forwardResult)")
            return
        }

        let forwardSnapshot: ReaderPageTurnProbeSnapshot
        if let stabilizedForwardSnapshot = await waitForStableAutomaticProbeBaseline(
            preferredSectionIndex: initialForwardSnapshot.currentSectionIndex,
            preferredPage: initialForwardSnapshot.currentPage,
            preferredCanBackward: initialForwardSnapshot.canBackward
        ) {
            probeModel.update(stabilizedForwardSnapshot)
            logProbeSnapshotIfEnabled(stabilizedForwardSnapshot)
            forwardSnapshot = stabilizedForwardSnapshot
            Logger.shared.logger.info(
                "# PAGETURN autoSequence.forward.stabilized sectionIndex=\(forwardSnapshot.currentSectionIndex.map(String.init) ?? "nil") currentPage=\(forwardSnapshot.currentPage.map(String.init) ?? "nil") pageCount=\(forwardSnapshot.pageCount.map(String.init) ?? "nil") canForward=\(forwardSnapshot.canForward) canBackward=\(forwardSnapshot.canBackward)"
            )
        } else {
            forwardSnapshot = initialForwardSnapshot
        }

        Logger.shared.logger.info("# PAGETURN autoSequence.forward.success previousPage=\(baselinePage.map(String.init) ?? "nil") currentPage=\(forwardSnapshot.currentPage.map(String.init) ?? "nil") canBackward=\(forwardSnapshot.canBackward)")

        guard forwardSnapshot.canBackward else {
            Logger.shared.logger.warning("# PAGETURN autoSequence.backward.skipped reason=canBackwardFalse currentPage=\(forwardSnapshot.currentPage.map(String.init) ?? "nil")")
            return
        }

        let backwardResult = await handleProbeCommand(.hostBackwardTurn)
        guard let backwardSnapshot = await waitForAutomaticProbeReturn(
            expectedCommandPrefix: "committed:backward",
            fallbackCommandResult: backwardResult,
            expectedSectionIndex: baselineSectionIndex,
            expectedSectionHref: baselineSectionHref,
            expectedPage: baselinePage,
            expectedCanBackward: baselineCanBackward
        ) else {
            Logger.shared.logger.warning("# PAGETURN autoSequence.backward.unresolved expectedPage=\(baselinePage.map(String.init) ?? "nil") result=\(backwardResult)")
            return
        }

        Logger.shared.logger.info("# PAGETURN autoSequence.backward.success restoredPage=\(backwardSnapshot.currentPage.map(String.init) ?? "nil") canBackward=\(backwardSnapshot.canBackward)")
    }

    private func waitForStableAutomaticProbeBaseline(
        preferredSectionIndex: Int?,
        preferredPage: Int?,
        preferredCanBackward: Bool,
        minimumPageCount: Int? = nil,
        timeoutNanoseconds: UInt64 = 3_000_000_000,
        pollNanoseconds: UInt64 = 250_000_000,
        requiredStableSamples: Int = 2
    ) async -> ReaderPageTurnProbeSnapshot? {
        let timeoutDate = Date().addingTimeInterval(TimeInterval(timeoutNanoseconds) / 1_000_000_000)
        var lastSnapshot: ReaderPageTurnProbeSnapshot?
        var stableSampleCount = 0
        while Date() < timeoutDate {
            _ = await bridge.refreshNavigationState()
            let snapshot = await makeProbeSnapshot()
            probeModel.update(snapshot)
            if let preferredSectionIndex, snapshot.currentSectionIndex != preferredSectionIndex {
                lastSnapshot = snapshot
                stableSampleCount = 0
                try? await Task.sleep(nanoseconds: pollNanoseconds)
                continue
            }
            if let preferredPage, snapshot.currentPage != preferredPage {
                lastSnapshot = snapshot
                stableSampleCount = 0
                try? await Task.sleep(nanoseconds: pollNanoseconds)
                continue
            }
            if snapshot.canBackward != preferredCanBackward {
                lastSnapshot = snapshot
                stableSampleCount = 0
                try? await Task.sleep(nanoseconds: pollNanoseconds)
                continue
            }
            if let minimumPageCount, (snapshot.pageCount ?? 0) < minimumPageCount {
                lastSnapshot = snapshot
                stableSampleCount = 0
                try? await Task.sleep(nanoseconds: pollNanoseconds)
                continue
            }

            if let lastSnapshot,
               lastSnapshot.currentSectionIndex == snapshot.currentSectionIndex,
               lastSnapshot.currentSectionHref == snapshot.currentSectionHref,
               lastSnapshot.currentPage == snapshot.currentPage,
               lastSnapshot.pageCount == snapshot.pageCount,
               lastSnapshot.canForward == snapshot.canForward,
               lastSnapshot.canBackward == snapshot.canBackward,
               lastSnapshot.canNext == snapshot.canNext,
               lastSnapshot.canPrev == snapshot.canPrev,
               lastSnapshot.currentPageTextSample == snapshot.currentPageTextSample,
               lastSnapshot.nextPageTextSample == snapshot.nextPageTextSample {
                stableSampleCount += 1
            } else {
                stableSampleCount = 1
            }
            lastSnapshot = snapshot
            if stableSampleCount >= requiredStableSamples {
                return snapshot
            }
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
        return lastSnapshot
    }

    private func waitForAutomaticProbeTransition(
        expectedCommandPrefix: String,
        fallbackCommandResult: String,
        baselineSectionIndex: Int?,
        baselineSectionHref: String?,
        baselinePage: Int?,
        baselineCanBackward: Bool,
        timeoutNanoseconds: UInt64 = 8_000_000_000,
        pollNanoseconds: UInt64 = 250_000_000
    ) async -> ReaderPageTurnProbeSnapshot? {
        let timeoutDate = Date().addingTimeInterval(TimeInterval(timeoutNanoseconds) / 1_000_000_000)
        while Date() < timeoutDate {
            _ = await bridge.refreshNavigationState()
            let snapshot = await makeProbeSnapshot()
            probeModel.update(snapshot)
            logProbeSnapshotIfEnabled(snapshot)
            if probeModel.lastCommandResult?.hasPrefix(expectedCommandPrefix) == true || fallbackCommandResult.hasPrefix(expectedCommandPrefix) {
                if let baselineSectionIndex, let currentSectionIndex = snapshot.currentSectionIndex, currentSectionIndex != baselineSectionIndex {
                    return snapshot
                }
                if let baselineSectionHref, let currentSectionHref = snapshot.currentSectionHref, currentSectionHref != baselineSectionHref {
                    return snapshot
                }
                if let baselinePage, let currentPage = snapshot.currentPage, currentPage != baselinePage {
                    return snapshot
                }
                if snapshot.canBackward != baselineCanBackward {
                    return snapshot
                }
            }
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
        return nil
    }

    private func waitForAutomaticProbeReturn(
        expectedCommandPrefix: String,
        fallbackCommandResult: String,
        expectedSectionIndex: Int?,
        expectedSectionHref: String?,
        expectedPage: Int?,
        expectedCanBackward: Bool,
        timeoutNanoseconds: UInt64 = 8_000_000_000,
        pollNanoseconds: UInt64 = 250_000_000
    ) async -> ReaderPageTurnProbeSnapshot? {
        let timeoutDate = Date().addingTimeInterval(TimeInterval(timeoutNanoseconds) / 1_000_000_000)
        while Date() < timeoutDate {
            _ = await bridge.refreshNavigationState()
            let snapshot = await makeProbeSnapshot()
            probeModel.update(snapshot)
            logProbeSnapshotIfEnabled(snapshot)
            if probeModel.lastCommandResult?.hasPrefix(expectedCommandPrefix) == true || fallbackCommandResult.hasPrefix(expectedCommandPrefix) {
                if let expectedSectionIndex, snapshot.currentSectionIndex == expectedSectionIndex {
                    return snapshot
                }
                if let expectedSectionHref, snapshot.currentSectionHref == expectedSectionHref {
                    return snapshot
                }
                if let expectedPage, snapshot.currentPage == expectedPage {
                    return snapshot
                }
                if snapshot.canBackward == expectedCanBackward {
                    return snapshot
                }
            }
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
        return nil
    }

    @MainActor
    private func handleProbeCommand(_ command: ReaderPageTurnProbeCommand) async -> String {
        let diagnosticsEnabled = ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1"
        let timeoutNanoseconds: UInt64 = 12_000_000_000
        let pollNanoseconds: UInt64 = 200_000_000
        let timeoutResult = "error:timeout:\(command.rawValue)"
        if diagnosticsEnabled {
            Logger.shared.logger.info("# PAGETURN probeCommand.start command=\(command.rawValue)")
        }
        let resultBox = ReaderPageTurnProbeCommandResultBox()
        let task = Task { @MainActor in
            let result = await performProbeCommand(command, diagnosticsEnabled: diagnosticsEnabled)
            await resultBox.set(result)
        }
        let timeoutDate = Date().addingTimeInterval(TimeInterval(timeoutNanoseconds) / 1_000_000_000)
        while Date() < timeoutDate {
            if let result = await resultBox.get() {
                return result
            }
            try? await Task.sleep(nanoseconds: pollNanoseconds)
        }
        task.cancel()
        if diagnosticsEnabled {
            Logger.shared.logger.warning("# PAGETURN probeCommand command=\(command.rawValue) result=\(timeoutResult)")
        }
        return timeoutResult
    }

    @MainActor
    private func performProbeCommand(_ command: ReaderPageTurnProbeCommand, diagnosticsEnabled: Bool) async -> String {
        let baselineSnapshot = diagnosticsEnabled ? probeModel.snapshot : nil
        guard requestedEnabled else {
            return "blocked:notRequested"
        }
        guard isStructurallyEligibleForActiveTurns else {
            return "blocked:paginationInactive"
        }
        if !bridge.supportsActivePageTurn {
            _ = await bridge.refreshNavigationState()
        }
        let hasFallbackTurnReadiness =
            bridge.hasSectionLayoutController
            && !(bridge.currentPageTextSample?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && bridge.loadEBookStarted
        guard bridge.supportsActivePageTurn || hasFallbackTurnReadiness else {
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
            if diagnosticsEnabled {
                Logger.shared.logger.warning("# PAGETURN probeCommand command=\(command.rawValue) result=blocked:destinationUnavailable:\(direction.rawValue)")
            }
            return "blocked:destinationUnavailable:\(direction.rawValue)"
        }

        do {
            try await bridge.commitTurn(direction)
            let afterProbe = diagnosticsEnabled
                ? await refreshProbeForCommandClassification(baselineSnapshot: baselineSnapshot)
                : nil
            _ = await bridge.refreshNavigationState()
            let publishedSnapshot = await makeProbeSnapshot()
            probeModel.update(publishedSnapshot)
            logProbeSnapshotIfEnabled(publishedSnapshot)
            let result: String
            if let baselineSnapshot, let afterProbe,
               !baselineSnapshot.hasMeaningfulNavigationChange(comparedTo: afterProbe) {
                result = "committed-nochange:\(direction.rawValue)"
            } else {
                result = "committed:\(direction.rawValue)"
            }
            if diagnosticsEnabled {
                Logger.shared.logger.info("# PAGETURN probeCommand command=\(command.rawValue) result=\(result)")
            }
            return result
        } catch {
            let result = "error:\(direction.rawValue):\(error.localizedDescription)"
            if diagnosticsEnabled {
                Logger.shared.logger.warning("# PAGETURN probeCommand command=\(command.rawValue) result=\(result)")
            }
            return result
        }
    }

    @MainActor
    private func refreshProbeForCommandClassification(
        baselineSnapshot: ReaderPageTurnProbeSnapshot?,
        timeoutNanoseconds: UInt64 = 3_000_000_000,
        pollNanoseconds: UInt64 = 200_000_000
    ) async -> ReaderPageTurnNavigationProbe? {
        let firstProbe = await bridge.refreshNavigationStateBounded(
            timeoutNanoseconds: min(pollNanoseconds * 3, 1_500_000_000),
            pollNanoseconds: min(pollNanoseconds, 100_000_000)
        )
        guard let baselineSnapshot else {
            return firstProbe
        }
        if let firstProbe, baselineSnapshot.hasMeaningfulNavigationChange(comparedTo: firstProbe) {
            return firstProbe
        }

        let timeoutDate = Date().addingTimeInterval(TimeInterval(timeoutNanoseconds) / 1_000_000_000)
        var latestProbe = firstProbe
        while Date() < timeoutDate {
            try? await Task.sleep(nanoseconds: pollNanoseconds)
            let probe = await bridge.refreshNavigationStateBounded(
                timeoutNanoseconds: min(pollNanoseconds * 3, 1_500_000_000),
                pollNanoseconds: min(pollNanoseconds, 100_000_000)
            )
            latestProbe = probe ?? latestProbe
            if let probe, baselineSnapshot.hasMeaningfulNavigationChange(comparedTo: probe) {
                return probe
            }
        }

        return latestProbe
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
    let onPageTurnProbeSummaryChanged: ((String) -> Void)?
    @Binding var hideNavigationDueToScroll: Bool
    @Binding var textSelection: String?
    var buildMenu: BuildMenuType?
    
    @EnvironmentObject private var readerContent: ReaderContent
    @EnvironmentObject private var scriptCaller: WebViewScriptCaller
    @EnvironmentObject private var readerViewModel: ReaderViewModel
    @Environment(\.readerPageTurnInteractionContext) private var readerPageTurnInteractionContext
    
    @State private var obscuredInsets: EdgeInsets? = nil
    @StateObject private var navigationVisibilityCoordinator = ReaderNavigationVisibilityCoordinator()
    @StateObject private var pageTurnProbeModel: ReaderPageTurnProbeModel
    
    public init(
        forceReaderModeWhenAvailable: Bool = false,
//        obscuredInsets: EdgeInsets? = nil,
        bounces: Bool = true,
        additionalBottomSafeAreaInset: CGFloat? = nil,
        onAdditionalSafeAreaBarTap: (() -> Void)? = nil,
        schemeHandlers: [(WKURLSchemeHandler, String)] = [],
        pageTurnProbeModel: ReaderPageTurnProbeModel? = nil,
        onNavigationCommitted: ((WebViewState) async throws -> Void)? = nil,
        onNavigationFinished: ((WebViewState) -> Void)? = nil,
        onNavigationFailed: ((WebViewState) -> Void)? = nil,
        onURLChanged: ((WebViewState) async throws -> Void)? = nil,
        onPageTurnProbeSummaryChanged: ((String) -> Void)? = nil,
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
        _pageTurnProbeModel = StateObject(wrappedValue: pageTurnProbeModel ?? ReaderPageTurnProbeModel())
        self.onNavigationCommitted = onNavigationCommitted
        self.onNavigationFinished = onNavigationFinished
        self.onNavigationFailed = onNavigationFailed
        self.onURLChanged = onURLChanged
        self.onPageTurnProbeSummaryChanged = onPageTurnProbeSummaryChanged
        _hideNavigationDueToScroll = hideNavigationDueToScroll
        _textSelection = textSelection ?? .constant(nil)
        self.buildMenu = buildMenu
    }

    private var isPageTurnProbeEnabled: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("--ui-test-enable-page-turn-probe")
            || processInfo.environment["XCTestConfigurationFilePath"] != nil
            || processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1"
    }

    private var pageTurnProbeSummary: String {
        return [
            pageTurnProbeModel.snapshot?.summary ?? "pageTurnProbe=nil",
            "lastCommandResult=\(pageTurnProbeModel.lastCommandResult ?? "nil")",
            "lookupPresented=\(readerPageTurnInteractionContext.lookupPresented)",
            "mediaPresented=\(readerPageTurnInteractionContext.mediaPresented)",
            "hasSelection=\(readerPageTurnInteractionContext.hasSelection)",
            "gestureCaptureBlocked=\(readerPageTurnInteractionContext.blocksGestureCapture)",
            "gestureCaptureBlockReason=\(readerPageTurnInteractionContext.blockingReason ?? "nil")",
            "hideNav=\(hideNavigationDueToScroll)",
        ].joined(separator: ";")
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
            .task(id: pageTurnProbeSummary) {
                guard isPageTurnProbeEnabled else { return }
                onPageTurnProbeSummaryChanged?(pageTurnProbeSummary)
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
