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
    public var showTitleChrome: Bool?
    public var showHeaderChrome: Bool?
    public var pageProgressionDirection: String
    public var phase: String
    public var navigationStyle: String?
    public var transitionFamily: String?
    public var movementKind: String?
    public var layoutState: String?
    public var updateReason: String?
    public var navigationEvent: String?
    public var contentHostState: String?
    public var contentHostSequenceMountedHostIdentifier: String?
    public var contentHostSequenceAppliedHostIdentifier: String?
    public var contentHostSequenceIsAppliedToMountedHost: Bool?
    public var contentHostSequenceIsStable: Bool?
    public var contentHostSequenceSerial: Int?
    public var preloadStrategy: String?
    public var currentContentLocation: String?
    public var contentLoadingClass: String?
    public var snapshotLoadingClass: String?
    public var mountedHostIdentifier: String?
    public var appliedHostIdentifier: String?
    public var liveWebViewIdentifier: String?
    public var pageOffsetsDisplayed: [Int]?
    public var currentSpreadSlots: [String]?
    public var destinationSpreadSlots: [String]?
    public var requestedLocationKind: String?
    public var requestedLocationValue: String?
    public var requestedLocationSource: String?
    public var requestedLocationSurroundingContext: String?
    public var requestedLocationIsPageChange: Bool?
    public var requestedLocationFractionalCompletion: Double?
    public var readingProgressCFI: String?
    public var readingProgressFractionalCompletion: Double?
    public var readingProgressHighWaterMarkFractionalCompletion: Double?
    public var readingProgressSuppressionReason: String?
    public var readingProgressReason: String?
    public var readingProgressSectionIndex: Int?
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
    public var layoutChromeGutterWidth: Double?
    public var layoutReadableFrameWidth: Double?
    public var layoutMaxContentWidth: Double?
    public var layoutSemanticSideInset: Double?
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
    public var progressScrubberVisible: Bool?
    public var progressScrubberActive: Bool?
    public var historyCanGoBack: Bool?
    public var historyCanGoForward: Bool?
    public var historyDepth: Int?
    public var historyCurrentIndex: Int?
    public var historyPendingReplaceStateSuppressionCount: Int?
    public var historySuppressedReplaceStateCount: Int?
    public var historyLastSuppressedReplaceStateReason: String?
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
    public var forwardDestinationAvailability: String?
    public var backwardDestinationAvailability: String?
    public var paginationComplete: Bool?
    public var configurationKey: String?
    public var publicationSource: String?
    public var pageLabelDisplayMode: String?
    public var pageNumberMode: String?
    public var usesPhysicalPageLabels: Bool?
    public var allowsMultipleColumns: Bool?
    public var allowsMultipleLabelsInMultiUnitLayout: Bool?
    public var visiblePageIndices: [Int]?
    public var pageScrollerAnimationIsRunning: Bool?
    public var liveResizeActive: Bool?
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
        showTitleChrome: Bool?,
        showHeaderChrome: Bool?,
        pageProgressionDirection: String,
        phase: String,
        navigationStyle: String?,
        transitionFamily: String?,
        movementKind: String?,
        layoutState: String?,
        updateReason: String?,
        navigationEvent: String?,
        contentHostState: String?,
        contentHostSequenceMountedHostIdentifier: String?,
        contentHostSequenceAppliedHostIdentifier: String?,
        contentHostSequenceIsAppliedToMountedHost: Bool?,
        contentHostSequenceIsStable: Bool?,
        contentHostSequenceSerial: Int?,
        preloadStrategy: String?,
        currentContentLocation: String?,
        contentLoadingClass: String?,
        snapshotLoadingClass: String?,
        mountedHostIdentifier: String?,
        appliedHostIdentifier: String?,
        liveWebViewIdentifier: String?,
        pageOffsetsDisplayed: [Int]?,
        currentSpreadSlots: [String]?,
        destinationSpreadSlots: [String]?,
        requestedLocationKind: String?,
        requestedLocationValue: String?,
        requestedLocationSource: String?,
        requestedLocationSurroundingContext: String?,
        requestedLocationIsPageChange: Bool?,
        requestedLocationFractionalCompletion: Double?,
        readingProgressCFI: String?,
        readingProgressFractionalCompletion: Double?,
        readingProgressHighWaterMarkFractionalCompletion: Double?,
        readingProgressSuppressionReason: String?,
        readingProgressReason: String?,
        readingProgressSectionIndex: Int?,
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
        layoutChromeGutterWidth: Double?,
        layoutReadableFrameWidth: Double?,
        layoutMaxContentWidth: Double?,
        layoutSemanticSideInset: Double?,
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
        progressScrubberVisible: Bool?,
        progressScrubberActive: Bool?,
        historyCanGoBack: Bool?,
        historyCanGoForward: Bool?,
        historyDepth: Int?,
        historyCurrentIndex: Int?,
        historyPendingReplaceStateSuppressionCount: Int?,
        historySuppressedReplaceStateCount: Int?,
        historyLastSuppressedReplaceStateReason: String?,
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
        forwardDestinationAvailability: String?,
        backwardDestinationAvailability: String?,
        paginationComplete: Bool?,
        configurationKey: String?,
        publicationSource: String?,
        pageLabelDisplayMode: String?,
        pageNumberMode: String?,
        usesPhysicalPageLabels: Bool?,
        allowsMultipleColumns: Bool?,
        allowsMultipleLabelsInMultiUnitLayout: Bool?,
        visiblePageIndices: [Int]?,
        pageScrollerAnimationIsRunning: Bool?,
        liveResizeActive: Bool?,
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
        self.showTitleChrome = showTitleChrome
        self.showHeaderChrome = showHeaderChrome
        self.pageProgressionDirection = pageProgressionDirection
        self.phase = phase
        self.navigationStyle = navigationStyle
        self.transitionFamily = transitionFamily
        self.movementKind = movementKind
        self.layoutState = layoutState
        self.updateReason = updateReason
        self.navigationEvent = navigationEvent
        self.contentHostState = contentHostState
        self.contentHostSequenceMountedHostIdentifier = contentHostSequenceMountedHostIdentifier
        self.contentHostSequenceAppliedHostIdentifier = contentHostSequenceAppliedHostIdentifier
        self.contentHostSequenceIsAppliedToMountedHost = contentHostSequenceIsAppliedToMountedHost
        self.contentHostSequenceIsStable = contentHostSequenceIsStable
        self.contentHostSequenceSerial = contentHostSequenceSerial
        self.preloadStrategy = preloadStrategy
        self.currentContentLocation = currentContentLocation
        self.contentLoadingClass = contentLoadingClass
        self.snapshotLoadingClass = snapshotLoadingClass
        self.mountedHostIdentifier = mountedHostIdentifier
        self.appliedHostIdentifier = appliedHostIdentifier
        self.liveWebViewIdentifier = liveWebViewIdentifier
        self.pageOffsetsDisplayed = pageOffsetsDisplayed
        self.currentSpreadSlots = currentSpreadSlots
        self.destinationSpreadSlots = destinationSpreadSlots
        self.requestedLocationKind = requestedLocationKind
        self.requestedLocationValue = requestedLocationValue
        self.requestedLocationSource = requestedLocationSource
        self.requestedLocationSurroundingContext = requestedLocationSurroundingContext
        self.requestedLocationIsPageChange = requestedLocationIsPageChange
        self.requestedLocationFractionalCompletion = requestedLocationFractionalCompletion
        self.readingProgressCFI = readingProgressCFI
        self.readingProgressFractionalCompletion = readingProgressFractionalCompletion
        self.readingProgressHighWaterMarkFractionalCompletion = readingProgressHighWaterMarkFractionalCompletion
        self.readingProgressSuppressionReason = readingProgressSuppressionReason
        self.readingProgressReason = readingProgressReason
        self.readingProgressSectionIndex = readingProgressSectionIndex
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
        self.layoutChromeGutterWidth = layoutChromeGutterWidth
        self.layoutReadableFrameWidth = layoutReadableFrameWidth
        self.layoutMaxContentWidth = layoutMaxContentWidth
        self.layoutSemanticSideInset = layoutSemanticSideInset
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
        self.progressScrubberVisible = progressScrubberVisible
        self.progressScrubberActive = progressScrubberActive
        self.historyCanGoBack = historyCanGoBack
        self.historyCanGoForward = historyCanGoForward
        self.historyDepth = historyDepth
        self.historyCurrentIndex = historyCurrentIndex
        self.historyPendingReplaceStateSuppressionCount = historyPendingReplaceStateSuppressionCount
        self.historySuppressedReplaceStateCount = historySuppressedReplaceStateCount
        self.historyLastSuppressedReplaceStateReason = historyLastSuppressedReplaceStateReason
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
        self.forwardDestinationAvailability = forwardDestinationAvailability
        self.backwardDestinationAvailability = backwardDestinationAvailability
        self.paginationComplete = paginationComplete
        self.configurationKey = configurationKey
        self.publicationSource = publicationSource
        self.pageLabelDisplayMode = pageLabelDisplayMode
        self.pageNumberMode = pageNumberMode
        self.usesPhysicalPageLabels = usesPhysicalPageLabels
        self.allowsMultipleColumns = allowsMultipleColumns
        self.allowsMultipleLabelsInMultiUnitLayout = allowsMultipleLabelsInMultiUnitLayout
        self.visiblePageIndices = visiblePageIndices
        self.pageScrollerAnimationIsRunning = pageScrollerAnimationIsRunning
        self.liveResizeActive = liveResizeActive
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
        var fields: [String] = []
        func add(_ key: String, _ value: String) {
            fields.append("\(key)=\(value)")
        }

        add("pageURL", pageURL)
        add("requested", String(requestedEnabled))
        add("eligible", String(structurallyEligible))
        add("active", String(activeEnabled))
        add("supports", String(supportsActivePageTurn))
        add("gestureCaptureEnabled", String(gestureCaptureEnabled))
        add("gestureCaptureBlockReason", gestureCaptureBlockReason ?? "nil")
        add("hideNav", String(hideNavigationDueToScroll))
        add("showTitleChrome", showTitleChrome.map(String.init) ?? "nil")
        add("showHeaderChrome", showHeaderChrome.map(String.init) ?? "nil")
        add("progression", pageProgressionDirection)
        add("phase", phase)
        add("navigationStyle", navigationStyle ?? "nil")
        add("transitionFamily", transitionFamily ?? "nil")
        add("movementKind", movementKind ?? "nil")
        add("layoutState", layoutState ?? "nil")
        add("updateReason", updateReason ?? "nil")
        add("navigationEvent", navigationEvent ?? "nil")
        add("contentHostState", contentHostState ?? "nil")
        add("contentHostSequenceMountedHost", contentHostSequenceMountedHostIdentifier ?? "nil")
        add("contentHostSequenceAppliedHost", contentHostSequenceAppliedHostIdentifier ?? "nil")
        add("contentHostSequenceAppliedToMountedHost", contentHostSequenceIsAppliedToMountedHost.map(String.init) ?? "nil")
        add("contentHostSequenceStable", contentHostSequenceIsStable.map(String.init) ?? "nil")
        add("contentHostSequenceSerial", contentHostSequenceSerial.map(String.init) ?? "nil")
        add("preloadStrategy", preloadStrategy ?? "nil")
        add("currentContentLocation", currentContentLocation ?? "nil")
        add("contentLoadingClass", contentLoadingClass ?? "nil")
        add("snapshotLoadingClass", snapshotLoadingClass ?? "nil")
        add("mountedHost", mountedHostIdentifier ?? "nil")
        add("appliedHost", appliedHostIdentifier ?? "nil")
        add("liveWebView", liveWebViewIdentifier ?? "nil")
        add("pageOffsetsDisplayed", pageOffsetsDisplayed?.map(String.init).joined(separator: ",") ?? "nil")
        add("currentSpreadSlots", currentSpreadSlots?.joined(separator: ",") ?? "nil")
        add("destinationSpreadSlots", destinationSpreadSlots?.joined(separator: ",") ?? "nil")
        add("requestedLocationKind", requestedLocationKind ?? "nil")
        add("requestedLocationValue", requestedLocationValue ?? "nil")
        add("requestedLocationSource", requestedLocationSource ?? "nil")
        add("requestedLocationContext", requestedLocationSurroundingContext ?? "nil")
        add("requestedLocationIsPageChange", requestedLocationIsPageChange.map { String($0) } ?? "nil")
        add("requestedLocationFractionalCompletion", requestedLocationFractionalCompletion.map { String($0) } ?? "nil")
        add("readingProgressCFI", readingProgressCFI ?? "nil")
        add("readingProgressFractionalCompletion", readingProgressFractionalCompletion.map { String($0) } ?? "nil")
        add("readingProgressHighWaterMarkFractionalCompletion", readingProgressHighWaterMarkFractionalCompletion.map { String($0) } ?? "nil")
        add("readingProgressSuppressionReason", readingProgressSuppressionReason ?? "nil")
        add("readingProgressReason", readingProgressReason ?? "nil")
        add("readingProgressSectionIndex", readingProgressSectionIndex.map { String($0) } ?? "nil")
        add("hasView", String(hasView))
        add("hasRenderer", String(hasRenderer))
        add("canNext", String(canNext))
        add("canPrev", String(canPrev))
        add("hasSectionLayoutController", String(hasSectionLayoutController))
        add("bookDirection", bookDirection ?? "nil")
        add("isRightToLeft", String(isRightToLeft))
        add("isVertical", String(isVertical))
        add("isVerticalRightToLeft", String(isVerticalRightToLeft))
        add("currentSectionIndex", currentSectionIndex.map(String.init) ?? "nil")
        add("currentSectionHref", currentSectionHref ?? "nil")
        add("currentPage", currentPage.map(String.init) ?? "nil")
        add("livePageIndex", livePageIndex.map(String.init) ?? "nil")
        add("liveChunkPageIndex", liveChunkPageIndex.map(String.init) ?? "nil")
        add("viewportCenterChunkPageIndex", viewportCenterChunkPageIndex.map(String.init) ?? "nil")
        add("pageCount", pageCount.map(String.init) ?? "nil")
        add("layoutPageRecordCount", layoutPageRecordCount.map(String.init) ?? "nil")
        add("layoutLiveRootExists", layoutLiveRootExists.map(String.init) ?? "nil")
        add("layoutLiveRootClassName", layoutLiveRootClassName ?? "nil")
        add("layoutLiveRootChildCount", layoutLiveRootChildCount.map(String.init) ?? "nil")
        add("layoutLiveRootRectWidth", layoutLiveRootRectWidth.map(String.init) ?? "nil")
        add("layoutLiveRootRectHeight", layoutLiveRootRectHeight.map(String.init) ?? "nil")
        add("layoutLiveCurrentPageExists", layoutLiveCurrentPageExists.map(String.init) ?? "nil")
        add("layoutLiveCurrentPageClassName", layoutLiveCurrentPageClassName ?? "nil")
        add("layoutLiveCurrentPageRectWidth", layoutLiveCurrentPageRectWidth.map(String.init) ?? "nil")
        add("layoutLiveCurrentPageRectHeight", layoutLiveCurrentPageRectHeight.map(String.init) ?? "nil")
        add("layoutLiveCurrentPageContainsChunkBody", layoutLiveCurrentPageContainsChunkBody.map(String.init) ?? "nil")
        add("layoutLiveCurrentChunkExists", layoutLiveCurrentChunkExists.map(String.init) ?? "nil")
        add("layoutLiveCurrentChunkTagName", layoutLiveCurrentChunkTagName ?? "nil")
        add("layoutLiveCurrentChunkClassName", layoutLiveCurrentChunkClassName ?? "nil")
        add("layoutLiveCurrentChunkDisplay", layoutLiveCurrentChunkDisplay ?? "nil")
        add("layoutLiveCurrentChunkPosition", layoutLiveCurrentChunkPosition ?? "nil")
        add("layoutLiveCurrentChunkFlex", layoutLiveCurrentChunkFlex ?? "nil")
        add("layoutLiveCurrentChunkRectWidth", layoutLiveCurrentChunkRectWidth.map(String.init) ?? "nil")
        add("layoutLiveCurrentChunkRectHeight", layoutLiveCurrentChunkRectHeight.map(String.init) ?? "nil")
        add("layoutLiveCurrentChunkInnerHTMLLength", layoutLiveCurrentChunkInnerHTMLLength.map(String.init) ?? "nil")
        add("layoutLiveCurrentChunkContainsChunkBody", layoutLiveCurrentChunkContainsChunkBody.map(String.init) ?? "nil")
        add("layoutLiveCurrentChunkChildCount", layoutLiveCurrentChunkChildCount.map(String.init) ?? "nil")
        add("layoutLiveCurrentChunkTextLength", layoutLiveCurrentChunkTextLength.map(String.init) ?? "nil")
        add("layoutCurrentChunkBodyChildCount", layoutCurrentChunkBodyChildCount.map(String.init) ?? "nil")
        add("layoutCurrentChunkBodyTextLength", layoutCurrentChunkBodyTextLength.map(String.init) ?? "nil")
        add("layoutCurrentChunkBodyDisplay", layoutCurrentChunkBodyDisplay ?? "nil")
        add("layoutCurrentChunkBodyPosition", layoutCurrentChunkBodyPosition ?? "nil")
        add("layoutCurrentChunkBodyFlex", layoutCurrentChunkBodyFlex ?? "nil")
        add("layoutColumnCount", layoutColumnCount.map(String.init) ?? "nil")
        add("layoutCurrentPageIndex", layoutCurrentPageIndex.map(String.init) ?? "nil")
        add("layoutCurrentPageChunkCount", layoutCurrentPageChunkCount.map(String.init) ?? "nil")
        add("layoutMaxPageChunkCount", layoutMaxPageChunkCount.map(String.init) ?? "nil")
        add("layoutUnitCount", layoutUnitCount.map(String.init) ?? "nil")
        add("layoutActiveBuildPageIndex", layoutActiveBuildPageIndex.map(String.init) ?? "nil")
        add("layoutComplete", layoutComplete.map(String.init) ?? "nil")
        add("layoutSpreadCandidateDetected", layoutSpreadCandidateDetected.map(String.init) ?? "nil")
        add("layoutVisibleUnitKind", layoutVisibleUnitKind ?? "nil")
        add("layoutVisibleUnitAxis", layoutVisibleUnitAxis ?? "nil")
        add("layoutVisiblePageCount", layoutVisiblePageCount.map(String.init) ?? "nil")
        add("layoutCurrentUnitIndex", layoutCurrentUnitIndex.map(String.init) ?? "nil")
        add("layoutLeadingPageIndex", layoutLeadingPageIndex.map(String.init) ?? "nil")
        add("layoutTrailingPageIndex", layoutTrailingPageIndex.map(String.init) ?? "nil")
        add("layoutHasLeadingSingleton", layoutHasLeadingSingleton.map(String.init) ?? "nil")
        add("layoutHasTrailingSingleton", layoutHasTrailingSingleton.map(String.init) ?? "nil")
        add("layoutPrimarySpacing", layoutPrimarySpacing.map { String($0) } ?? "nil")
        add("layoutChromeGutterWidth", layoutChromeGutterWidth.map { String($0) } ?? "nil")
        add("layoutReadableFrameWidth", layoutReadableFrameWidth.map { String($0) } ?? "nil")
        add("layoutMaxContentWidth", layoutMaxContentWidth.map { String($0) } ?? "nil")
        add("layoutSemanticSideInset", layoutSemanticSideInset.map { String($0) } ?? "nil")
        add("layoutMultiUnitActive", layoutMultiUnitActive.map(String.init) ?? "nil")
        add("layoutSpreadPagesAllowedForViewport", layoutSpreadPagesAllowedForViewport.map(String.init) ?? "nil")
        add("layoutWritingMode", layoutWritingMode ?? "nil")
        add("layoutViewportWidth", layoutViewportWidth.map(String.init) ?? "nil")
        add("layoutViewportHeight", layoutViewportHeight.map(String.init) ?? "nil")
        add("layoutMeasuredGap", layoutMeasuredGap.map { String($0) } ?? "nil")
        add("layoutMetricSize", layoutMetricSize.map { String($0) } ?? "nil")
        add("layoutColumnInlineSize", layoutColumnInlineSize.map { String($0) } ?? "nil")
        add("layoutCurrentChunkClientWidth", layoutCurrentChunkClientWidth.map(String.init) ?? "nil")
        add("layoutCurrentChunkClientHeight", layoutCurrentChunkClientHeight.map(String.init) ?? "nil")
        add("layoutCurrentChunkScrollWidth", layoutCurrentChunkScrollWidth.map(String.init) ?? "nil")
        add("layoutCurrentChunkScrollHeight", layoutCurrentChunkScrollHeight.map(String.init) ?? "nil")
        add("layoutCurrentChunkOverflow", layoutCurrentChunkOverflow.map(String.init) ?? "nil")
        add("computedFontSizeCSS", computedFontSizeCSS ?? "nil")
        add("currentPageTextSample", currentPageTextSample ?? "nil")
        add("nextPageTextSample", nextPageTextSample ?? "nil")
        add("currentPageDisplayLabel", currentPageDisplayLabel ?? "nil")
        add("currentPhysicalPageLabel", currentPhysicalPageLabel ?? "nil")
        add("progressScrubberVisible", progressScrubberVisible.map(String.init) ?? "nil")
        add("progressScrubberActive", progressScrubberActive.map(String.init) ?? "nil")
        add("historyCanGoBack", historyCanGoBack.map(String.init) ?? "nil")
        add("historyCanGoForward", historyCanGoForward.map(String.init) ?? "nil")
        add("historyDepth", historyDepth.map(String.init) ?? "nil")
        add("historyCurrentIndex", historyCurrentIndex.map(String.init) ?? "nil")
        add("historyPendingReplaceStateSuppressionCount", historyPendingReplaceStateSuppressionCount.map(String.init) ?? "nil")
        add("historySuppressedReplaceStateCount", historySuppressedReplaceStateCount.map(String.init) ?? "nil")
        add("historyLastSuppressedReplaceStateReason", historyLastSuppressedReplaceStateReason ?? "nil")
        add("loadEBookStarted", String(loadEBookStarted))
        add("loadEBookReady", String(loadEBookReady))
        add("loadEBookAttemptCount", loadEBookAttemptCount.map(String.init) ?? "nil")
        add("loadEBookStartAgeMs", loadEBookStartAgeMs.map(String.init) ?? "nil")
        add("loadEBookLastState", loadEBookLastState ?? "nil")
        add("forwardDestinationAvailability", forwardDestinationAvailability ?? "nil")
        add("backwardDestinationAvailability", backwardDestinationAvailability ?? "nil")
        add("paginationComplete", paginationComplete.map(String.init) ?? "nil")
        add("configurationKey", configurationKey ?? "nil")
        add("publicationSource", publicationSource ?? "nil")
        add("pageLabelDisplayMode", pageLabelDisplayMode ?? "nil")
        add("pageNumberMode", pageNumberMode ?? "nil")
        add("usesPhysicalPageLabels", usesPhysicalPageLabels.map(String.init) ?? "nil")
        add("allowsMultipleColumns", allowsMultipleColumns.map(String.init) ?? "nil")
        add("allowsMultipleLabelsInMultiUnitLayout", allowsMultipleLabelsInMultiUnitLayout.map(String.init) ?? "nil")
        add("visiblePageIndices", visiblePageIndices?.map(String.init).joined(separator: ",") ?? "nil")
        add("pageScrollerAnimationIsRunning", pageScrollerAnimationIsRunning.map(String.init) ?? "nil")
        add("liveResizeActive", liveResizeActive.map(String.init) ?? "nil")
        add("canForward", String(canForward))
        add("canBackward", String(canBackward))
        add("interactionKind", interactionKind ?? "nil")
        add("interactionQualified", interactionQualified.map(String.init) ?? "nil")
        add("interactionDirection", interactionDirection ?? "nil")
        add("interactionPrimary", interactionPrimaryAxisDelta.map { String(format: "%.3f", $0) } ?? "nil")
        add("interactionSecondary", interactionSecondaryAxisDelta.map { String(format: "%.3f", $0) } ?? "nil")
        add("interactionProgress", interactionProgress.map { String(format: "%.3f", $0) } ?? "nil")
        add("interactionVelocity", interactionVelocity.map { String(format: "%.3f", $0) } ?? "nil")
        add("interactionCommit", interactionShouldCommit.map(String.init) ?? "nil")
        add("interactionOppositeFlickRefused", interactionRefusedOppositeDirectionFlick.map(String.init) ?? "nil")
        add("interactionNote", interactionNote ?? "nil")
        add("probeError", probeError ?? "nil")
        return fields.joined(separator: ";")
    }
}

struct ReaderPageTurnNavigationObservation: Equatable {
    let supportsActivePageTurn: Bool
    let currentSpread: WebViewPaginationSpread?
    let destinationSpread: WebViewPaginationSpread?
    let pageOffsetsDisplayed: [Int]?
    let pageCount: Int?
    let layoutLeadingPageIndex: Int?
    let currentPage: Int?
    let layoutTrailingPageIndex: Int?
    let layoutVisiblePageCount: Int?
    let currentSectionIndex: Int?
    let currentSectionHref: String?
    let livePageIndex: Int?
    let liveChunkPageIndex: Int?
    let viewportCenterChunkPageIndex: Int?
    let canForward: Bool
    let canBackward: Bool
    let layoutActiveBuildPageIndex: Int?

    init(
        currentSpread: WebViewPaginationSpread? = nil,
        destinationSpread: WebViewPaginationSpread? = nil,
        pageOffsetsDisplayed: [Int]? = nil,
        pageCount: Int? = nil,
        layoutLeadingPageIndex: Int? = nil,
        currentPage: Int? = nil,
        layoutTrailingPageIndex: Int? = nil,
        layoutVisiblePageCount: Int? = nil,
        currentSectionIndex: Int? = nil,
        currentSectionHref: String? = nil,
        livePageIndex: Int? = nil,
        liveChunkPageIndex: Int? = nil,
        viewportCenterChunkPageIndex: Int? = nil,
        supportsActivePageTurn: Bool = false,
        canForward: Bool = false,
        canBackward: Bool = false,
        layoutActiveBuildPageIndex: Int? = nil
    ) {
        self.supportsActivePageTurn = supportsActivePageTurn
        self.currentSpread = currentSpread
        self.destinationSpread = destinationSpread
        self.pageOffsetsDisplayed = pageOffsetsDisplayed
        self.pageCount = pageCount
        self.layoutLeadingPageIndex = layoutLeadingPageIndex
        self.currentPage = currentPage
        self.layoutTrailingPageIndex = layoutTrailingPageIndex
        self.layoutVisiblePageCount = layoutVisiblePageCount
        self.currentSectionIndex = currentSectionIndex
        self.currentSectionHref = currentSectionHref
        self.livePageIndex = livePageIndex
        self.liveChunkPageIndex = liveChunkPageIndex
        self.viewportCenterChunkPageIndex = viewportCenterChunkPageIndex
        self.canForward = canForward
        self.canBackward = canBackward
        self.layoutActiveBuildPageIndex = layoutActiveBuildPageIndex
    }

    init(snapshot: ReaderPageTurnProbeSnapshot) {
        self.init(
            pageOffsetsDisplayed: snapshot.pageOffsetsDisplayed,
            pageCount: snapshot.pageCount,
            layoutLeadingPageIndex: snapshot.layoutLeadingPageIndex,
            currentPage: snapshot.currentPage,
            layoutTrailingPageIndex: snapshot.layoutTrailingPageIndex,
            layoutVisiblePageCount: snapshot.layoutVisiblePageCount,
            currentSectionIndex: snapshot.currentSectionIndex,
            currentSectionHref: snapshot.currentSectionHref,
            livePageIndex: snapshot.livePageIndex,
            liveChunkPageIndex: snapshot.liveChunkPageIndex,
            viewportCenterChunkPageIndex: snapshot.viewportCenterChunkPageIndex,
            supportsActivePageTurn: snapshot.supportsActivePageTurn,
            canForward: snapshot.canForward,
            canBackward: snapshot.canBackward,
            layoutActiveBuildPageIndex: snapshot.layoutActiveBuildPageIndex
        )
    }

    fileprivate init(probe: ReaderPageTurnNavigationProbe) {
        self.init(
            currentSpread: probe.currentSpread,
            destinationSpread: probe.destinationSpread,
            pageOffsetsDisplayed: probe.pageOffsetsDisplayed,
            pageCount: probe.pageCount,
            layoutLeadingPageIndex: probe.layoutLeadingPageIndex,
            currentPage: probe.currentPage,
            layoutTrailingPageIndex: probe.layoutTrailingPageIndex,
            layoutVisiblePageCount: probe.layoutVisiblePageCount,
            currentSectionIndex: probe.currentSectionIndex,
            currentSectionHref: probe.currentSectionHref,
            livePageIndex: probe.livePageIndex,
            liveChunkPageIndex: probe.liveChunkPageIndex,
            viewportCenterChunkPageIndex: probe.viewportCenterChunkPageIndex,
            supportsActivePageTurn: probe.supportsActivePageTurn,
            canForward: probe.canForward,
            canBackward: probe.canBackward,
            layoutActiveBuildPageIndex: probe.layoutActiveBuildPageIndex
        )
    }

    var resolvedGraph: ReaderPageTurnResolvedGraph {
        ReaderPageTurnSpreadGraph(
            currentSpread: currentSpread,
            destinationSpread: destinationSpread,
            pageOffsetsDisplayed: pageOffsetsDisplayed,
            pageCount: pageCount,
            layoutLeadingPageIndex: layoutLeadingPageIndex,
            currentPage: currentPage,
            layoutTrailingPageIndex: layoutTrailingPageIndex,
            layoutVisiblePageCount: layoutVisiblePageCount
        ).resolvedGraph
    }
}

enum ReaderPageTurnNavigationComparison {
    private static func probeHasLivePageMetrics(
        _ probe: ReaderPageTurnNavigationObservation
    ) -> Bool {
        probe.livePageIndex != nil
            || probe.liveChunkPageIndex != nil
            || probe.viewportCenterChunkPageIndex != nil
    }

    private static func hasEquivalentScalarPaginationWindow(
        snapshot: ReaderPageTurnProbeSnapshot,
        comparedTo probe: ReaderPageTurnNavigationObservation
    ) -> Bool {
        snapshot.pageOffsetsDisplayed == probe.pageOffsetsDisplayed
            && snapshot.pageCount == probe.pageCount
            && snapshot.layoutLeadingPageIndex == probe.layoutLeadingPageIndex
            && snapshot.currentPage == probe.currentPage
            && snapshot.layoutTrailingPageIndex == probe.layoutTrailingPageIndex
            && snapshot.layoutVisiblePageCount == probe.layoutVisiblePageCount
            && snapshot.currentSectionIndex == probe.currentSectionIndex
            && snapshot.currentSectionHref == probe.currentSectionHref
            && snapshot.canForward == probe.canForward
            && snapshot.canBackward == probe.canBackward
    }

    private static func optionalResolvedValueChanged<T: Equatable>(
        _ snapshotValue: T?,
        comparedTo probeValue: T?
    ) -> Bool {
        guard let snapshotValue, let probeValue else {
            return false
        }
        return snapshotValue != probeValue
    }

    static func hasMeaningfulNavigationChange(
        snapshot: ReaderPageTurnProbeSnapshot,
        comparedTo probe: ReaderPageTurnNavigationObservation
    ) -> Bool {
        if !probeHasLivePageMetrics(probe),
           probe.currentSpread == nil,
           probe.destinationSpread == nil,
           hasEquivalentScalarPaginationWindow(snapshot: snapshot, comparedTo: probe) {
            return false
        }
        return hasMeaningfulNavigationChange(
            snapshot: ReaderPageTurnNavigationObservation(snapshot: snapshot),
            comparedTo: probe
        )
    }

    fileprivate static func hasMeaningfulNavigationChange(
        snapshot: ReaderPageTurnProbeSnapshot,
        comparedTo probe: ReaderPageTurnNavigationProbe
    ) -> Bool {
        hasMeaningfulNavigationChange(snapshot: snapshot, comparedTo: ReaderPageTurnNavigationObservation(probe: probe))
    }

    static func hasMeaningfulNavigationChange(
        snapshot: ReaderPageTurnNavigationObservation,
        comparedTo probe: ReaderPageTurnNavigationObservation
    ) -> Bool {
        let resolvedGraph = snapshot.resolvedGraph
        let probeResolvedGraph = probe.resolvedGraph
        if resolvedGraph.hasMeaningfulNavigationChange(comparedTo: probeResolvedGraph) {
            return true
        }
        if resolvedGraph.forwardDestinationAvailability != probeResolvedGraph.forwardDestinationAvailability {
            return true
        }
        if resolvedGraph.backwardDestinationAvailability != probeResolvedGraph.backwardDestinationAvailability {
            return true
        }
        if resolvedGraph.relativeSpreadOffset(comparedTo: probeResolvedGraph) != nil {
            return true
        }
        if snapshot.currentSectionIndex != probe.currentSectionIndex {
            return true
        }
        if snapshot.currentSectionHref != probe.currentSectionHref {
            return true
        }
        if optionalResolvedValueChanged(snapshot.livePageIndex, comparedTo: probe.livePageIndex) {
            return true
        }
        if optionalResolvedValueChanged(snapshot.liveChunkPageIndex, comparedTo: probe.liveChunkPageIndex) {
            return true
        }
        if optionalResolvedValueChanged(
            snapshot.viewportCenterChunkPageIndex,
            comparedTo: probe.viewportCenterChunkPageIndex
        ) {
            return true
        }
        if snapshot.canForward != probe.canForward {
            return true
        }
        if snapshot.canBackward != probe.canBackward {
            return true
        }
        return false
    }

    static func showsMeaningfulSettle(
        probe: ReaderPageTurnNavigationObservation,
        comparedTo baseline: ReaderPageTurnNavigationObservation
    ) -> Bool {
        let probeResolvedGraph = probe.resolvedGraph
        let baselineResolvedGraph = baseline.resolvedGraph
        if probeResolvedGraph.hasMeaningfulNavigationChange(comparedTo: baselineResolvedGraph) {
            return true
        }
        if probeResolvedGraph.forwardDestinationAvailability != baselineResolvedGraph.forwardDestinationAvailability {
            return true
        }
        if probeResolvedGraph.backwardDestinationAvailability != baselineResolvedGraph.backwardDestinationAvailability {
            return true
        }
        if probeResolvedGraph.relativeSpreadOffset(comparedTo: baselineResolvedGraph) != nil {
            return true
        }
        if probe.currentSectionIndex != baseline.currentSectionIndex { return true }
        if probe.currentSectionHref != baseline.currentSectionHref { return true }
        if probe.currentPage != baseline.currentPage { return true }
        if probe.pageOffsetsDisplayed != baseline.pageOffsetsDisplayed { return true }
        if probe.currentSpread != baseline.currentSpread { return true }
        if probe.destinationSpread != baseline.destinationSpread { return true }
        if (probe.pageCount ?? 0) > (baseline.pageCount ?? 0) { return true }
        if (probe.layoutActiveBuildPageIndex ?? 0) > (baseline.layoutActiveBuildPageIndex ?? 0) { return true }
        return false
    }

    static func hasSettledCommittedTurn(
        probe: ReaderPageTurnNavigationObservation,
        direction: PageTurnDirection
    ) -> Bool {
        let resolvedGraph = probe.resolvedGraph
        let hasResolvedVisibleState =
            !(resolvedGraph.currentVisiblePageIndices?.isEmpty ?? true)
            || resolvedGraph.currentPageIndex != nil
            || probe.currentSectionIndex != nil
        guard hasResolvedVisibleState else {
            return false
        }
        switch direction {
        case .forward:
            return resolvedGraph.canMoveBackward || probe.canBackward || probe.currentSectionIndex != nil
        case .backward:
            return resolvedGraph.currentPageIndex != nil || probe.currentSectionIndex != nil
        }
    }

    static func shouldRetryCommittedTurnAfterActivation(
        baseline: ReaderPageTurnNavigationObservation,
        activatedProbe: ReaderPageTurnNavigationObservation
    ) -> Bool {
        guard !hasMeaningfulNavigationChange(snapshot: activatedProbe, comparedTo: baseline) else {
            return false
        }
        return (!baseline.supportsActivePageTurn && activatedProbe.supportsActivePageTurn)
            || materiallyExpandedPagination(probe: activatedProbe, comparedTo: baseline)
    }

    static func classifyCommittedTurn(
        direction: PageTurnDirection,
        baseline: ReaderPageTurnNavigationObservation?,
        after: ReaderPageTurnNavigationObservation?
    ) -> ReaderPageTurnNavigationEventKind {
        guard let after else {
            return direction == .forward ? .nextPage : .previousPage
        }
        if let baseline {
            guard hasMeaningfulNavigationChange(snapshot: after, comparedTo: baseline) else {
                return .noPageChange
            }
            let baselineResolvedGraph = baseline.resolvedGraph
            let afterResolvedGraph = after.resolvedGraph
            return afterResolvedGraph.resolvedNavigationEventKind(
                comparedTo: baselineResolvedGraph,
                direction: direction
            )
        }
        return direction == .forward ? .nextPage : .previousPage
    }

    static func materiallyExpandedPagination(
        probe: ReaderPageTurnNavigationObservation,
        comparedTo baseline: ReaderPageTurnNavigationObservation
    ) -> Bool {
        if (probe.pageCount ?? 0) > (baseline.pageCount ?? 0) {
            return true
        }
        if (probe.layoutActiveBuildPageIndex ?? 0) > (baseline.layoutActiveBuildPageIndex ?? 0) {
            return true
        }
        return false
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
        ReaderPageTurnNavigationComparison.hasMeaningfulNavigationChange(
            snapshot: self,
            comparedTo: probe
        )
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

public enum ReaderPageTurnUpdateReason: String, Codable, CaseIterable, Sendable, Identifiable {
    case userInteraction
    case configurationChange
    case locationFulfillment

    public var id: String { rawValue }
}

public enum ReaderPageTurnContentHostState: String, Codable, CaseIterable, Sendable, Identifiable {
    case initial
    case waitingOnContentView
    case preparingContentView
    case placeholderViewAvailable
    case contentViewAvailable
    case preparingForReuse

    public var id: String { rawValue }
}

public enum ReaderPageTurnNavigationEventKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case nextPage
    case previousPage
    case noPageChange
    case attemptedPastEnd

    public var id: String { rawValue }
}

public struct ReaderPageTurnInteractionContext: Equatable, Sendable {
    public var ignorePageTurns: Bool
    public var lineGuideEnabled: Bool
    public var lookupPresented: Bool
    public var mediaPresented: Bool
    public var hasSelection: Bool
    public var requiresEdgeTouch: Bool
    public var centerTapAreaLength: Double?
    public var allowsBothMarginsAdvancePage: Bool

    public init(
        ignorePageTurns: Bool = false,
        lineGuideEnabled: Bool = false,
        lookupPresented: Bool = false,
        mediaPresented: Bool = false,
        hasSelection: Bool = false,
        requiresEdgeTouch: Bool = false,
        centerTapAreaLength: Double? = nil,
        allowsBothMarginsAdvancePage: Bool = false
    ) {
        self.ignorePageTurns = ignorePageTurns
        self.lineGuideEnabled = lineGuideEnabled
        self.lookupPresented = lookupPresented
        self.mediaPresented = mediaPresented
        self.hasSelection = hasSelection
        self.requiresEdgeTouch = requiresEdgeTouch
        self.centerTapAreaLength = centerTapAreaLength
        self.allowsBothMarginsAdvancePage = allowsBothMarginsAdvancePage
    }

    public var blocksGestureCapture: Bool {
        blockingReason != nil
    }

    public var blockingReason: String? {
        if ignorePageTurns {
            return "ignorePageTurns"
        }
        if lineGuideEnabled {
            return "lineGuide"
        }
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
    var pageNavigationStyle: PageTurnNavigationStyle?
    var transitionFamily: PageTurnTransitionFamily?
    var movementKind: PageTurnMovementKind?
    var layoutState: PageTurnLayoutState?
    var updateReason: ReaderPageTurnUpdateReason?
    var navigationEvent: ReaderPageTurnNavigationEventKind?
    var contentHostState: ReaderPageTurnContentHostState?
    var preloadStrategy: PageTurnPreloadStrategy?
    var currentContentLocation: PageTurnCurrentContentLocation?
    var pageOffsetsDisplayed: [Int]?
    var currentSpread: WebViewPaginationSpread?
    var destinationSpread: WebViewPaginationSpread?
    var spreadSequence: WebViewPaginationSpreadSequence?
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
    var layoutChromeGutterWidth: Double?
    var layoutReadableFrameWidth: Double?
    var layoutMaxContentWidth: Double?
    var layoutSemanticSideInset: Double?
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
    var progressScrubberVisible: Bool?
    var progressScrubberActive: Bool?
    var historyCanGoBack: Bool?
    var historyCanGoForward: Bool?
    var historyDepth: Int?
    var historyCurrentIndex: Int?
    var historyPendingReplaceStateSuppressionCount: Int?
    var historySuppressedReplaceStateCount: Int?
    var historyLastSuppressedReplaceStateReason: String?
    var showTitleChrome: Bool?
    var showHeaderChrome: Bool?
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
    var forwardDestinationAvailability: String?
    var backwardDestinationAvailability: String?
    var paginationComplete: Bool?
    var configurationKey: String?
    var publicationSource: WebViewPaginationPublicationSource?
    var pageLabelDisplayMode: String?
    var pageNumberMode: WebViewPaginationPageNumberMode?
    var usesPhysicalPageLabels: Bool?
    var allowsMultipleColumns: Bool?
    var allowsMultipleLabelsInMultiUnitLayout: Bool?
    var visiblePageIndices: [Int]?
    var pageScrollerAnimationIsRunning: Bool?
    var liveResizeActive: Bool?
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

    private func localSemanticAvailability(for direction: PageTurnDirection) -> PageTurnDestinationAvailability {
        let availability = spreadGraph.destinationAvailability(for: direction)
        return availability == .unavailable ? .unavailable : availability
    }

    var canSemanticForward: Bool {
        canForward || localSemanticAvailability(for: .forward) != .unavailable
    }

    var canSemanticBackward: Bool {
        canBackward || localSemanticAvailability(for: .backward) != .unavailable
    }

    var logPayload: [String: String] {
        [
            "pageNavigationStyle": pageNavigationStyle?.rawValue ?? "nil",
            "transitionFamily": transitionFamily?.rawValue ?? "nil",
            "movementKind": movementKind?.rawValue ?? "nil",
            "layoutState": layoutState?.rawValue ?? "nil",
            "updateReason": updateReason?.rawValue ?? "nil",
            "navigationEvent": navigationEvent?.rawValue ?? "nil",
            "contentHostState": contentHostState?.rawValue ?? "nil",
            "preloadStrategy": preloadStrategy?.rawValue ?? "nil",
            "currentContentLocation": currentContentLocation?.rawValue ?? "nil",
            "pageOffsetsDisplayed": pageOffsetsDisplayed?.map(String.init).joined(separator: ",") ?? "nil",
            "currentSpreadSlots": currentSpread?.slots.map { "\($0.kind.rawValue):\($0.pageIndex.map(String.init) ?? "nil")" }.joined(separator: ",") ?? "nil",
            "destinationSpreadSlots": destinationSpread?.slots.map { "\($0.kind.rawValue):\($0.pageIndex.map(String.init) ?? "nil")" }.joined(separator: ",") ?? "nil",
            "spreadSequenceCount": spreadSequence.map { String($0.spreads.count) } ?? "nil",
            "spreadSequenceCurrentIndex": spreadSequence?.currentIndex.map(String.init) ?? "nil",
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
            "layoutChromeGutterWidth": layoutChromeGutterWidth.map { String($0) } ?? "nil",
            "layoutReadableFrameWidth": layoutReadableFrameWidth.map { String($0) } ?? "nil",
            "layoutMaxContentWidth": layoutMaxContentWidth.map { String($0) } ?? "nil",
            "layoutSemanticSideInset": layoutSemanticSideInset.map { String($0) } ?? "nil",
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
            "progressScrubberVisible": progressScrubberVisible.map(String.init) ?? "nil",
            "progressScrubberActive": progressScrubberActive.map(String.init) ?? "nil",
            "historyCanGoBack": historyCanGoBack.map(String.init) ?? "nil",
            "historyCanGoForward": historyCanGoForward.map(String.init) ?? "nil",
            "historyDepth": historyDepth.map(String.init) ?? "nil",
            "historyCurrentIndex": historyCurrentIndex.map(String.init) ?? "nil",
            "historyPendingReplaceStateSuppressionCount": historyPendingReplaceStateSuppressionCount.map(String.init) ?? "nil",
            "historySuppressedReplaceStateCount": historySuppressedReplaceStateCount.map(String.init) ?? "nil",
            "historyLastSuppressedReplaceStateReason": historyLastSuppressedReplaceStateReason ?? "nil",
            "showTitleChrome": showTitleChrome.map(String.init) ?? "nil",
            "showHeaderChrome": showHeaderChrome.map(String.init) ?? "nil",
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
            "forwardDestinationAvailability": forwardDestinationAvailability ?? "nil",
            "backwardDestinationAvailability": backwardDestinationAvailability ?? "nil",
            "paginationComplete": paginationComplete.map(String.init) ?? "nil",
            "configurationKey": configurationKey ?? "nil",
            "publicationSource": publicationSource?.rawValue ?? "nil",
            "pageLabelDisplayMode": pageLabelDisplayMode ?? "nil",
            "pageNumberMode": pageNumberMode?.rawValue ?? "nil",
            "usesPhysicalPageLabels": usesPhysicalPageLabels.map(String.init) ?? "nil",
            "allowsMultipleColumns": allowsMultipleColumns.map(String.init) ?? "nil",
            "allowsMultipleLabelsInMultiUnitLayout": allowsMultipleLabelsInMultiUnitLayout.map(String.init) ?? "nil",
            "visiblePageIndices": visiblePageIndices?.map(String.init).joined(separator: ",") ?? "nil",
            "pageScrollerAnimationIsRunning": pageScrollerAnimationIsRunning.map(String.init) ?? "nil",
            "liveResizeActive": liveResizeActive.map(String.init) ?? "nil",
            "probeError": probeError ?? "nil",
            "resolvedPaginationMode": resolvedPaginationMode.rawValue.description,
            "pageProgressionDirection": pageProgressionDirection.rawValue,
            "supportsActivePageTurn": "\(supportsActivePageTurn)",
        ]
    }

    func hasMeaningfulNavigationChange(comparedTo baseline: Self) -> Bool {
        let resolvedGraph = ReaderPageTurnSpreadGraph(
            currentSpread: currentSpread,
            destinationSpread: destinationSpread,
            pageOffsetsDisplayed: pageOffsetsDisplayed,
            pageCount: pageCount,
            layoutLeadingPageIndex: layoutLeadingPageIndex,
            currentPage: currentPage,
            layoutTrailingPageIndex: layoutTrailingPageIndex,
            layoutVisiblePageCount: layoutVisiblePageCount
        ).resolvedGraph
        let baselineResolvedGraph = ReaderPageTurnSpreadGraph(
            currentSpread: baseline.currentSpread,
            destinationSpread: baseline.destinationSpread,
            pageOffsetsDisplayed: baseline.pageOffsetsDisplayed,
            pageCount: baseline.pageCount,
            layoutLeadingPageIndex: baseline.layoutLeadingPageIndex,
            currentPage: baseline.currentPage,
            layoutTrailingPageIndex: baseline.layoutTrailingPageIndex,
            layoutVisiblePageCount: baseline.layoutVisiblePageCount
        ).resolvedGraph

        if resolvedGraph.hasMeaningfulNavigationChange(comparedTo: baselineResolvedGraph) {
            return true
        }
        if currentSectionIndex != baseline.currentSectionIndex {
            return true
        }
        if currentSectionHref != baseline.currentSectionHref {
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

private extension WebViewPageNavigationStyle {
    var pageTurnNavigationStyle: PageTurnNavigationStyle {
        switch self {
        case .paged:
            return .paged
        case .verticalScroll:
            return .verticalScroll
        case .horizontalScroll:
            return .horizontalScroll
        }
    }
}

private extension PageTurnNavigationStyle {
    var webViewPaginationNavigationStyle: WebViewPageNavigationStyle {
        switch self {
        case .paged:
            return .paged
        case .verticalScroll:
            return .verticalScroll
        case .horizontalScroll:
            return .horizontalScroll
        }
    }
}

private extension ReaderPageTurnRequestedLocationState {
    var pageTurnRequestedLocation: PageTurnRequestedLocation? {
        guard let kind = PageTurnRequestedLocationKind(rawValue: kind) else {
            return nil
        }
        return PageTurnRequestedLocation(
            kind: kind,
            value: value,
            surroundingContext: surroundingContext,
            isRequestedPageChange: isRequestedPageChange
        )
    }

    var webViewPaginationRequestedLocation: WebViewPaginationRequestedLocation? {
        guard let kind = WebViewPaginationRequestedLocationKind(rawValue: kind) else {
            return nil
        }
        return WebViewPaginationRequestedLocation(
            kind: kind,
            value: value,
            surroundingContext: surroundingContext,
            isRequestedPageChange: isRequestedPageChange
        )
    }
}

private extension ReaderPageTurnContentHostState {
    var webViewPaginationContentHostState: WebViewPaginationContentHostState {
        switch self {
        case .initial:
            return .initial
        case .waitingOnContentView:
            return .waitingOnContentView
        case .preparingContentView:
            return .preparingContentView
        case .placeholderViewAvailable:
            return .placeholderViewAvailable
        case .contentViewAvailable:
            return .contentViewAvailable
        case .preparingForReuse:
            return .preparingForReuse
        }
    }

    var pageTurnContentHostState: PageTurnContentHostState {
        switch self {
        case .initial:
            return .initial
        case .waitingOnContentView:
            return .waitingOnContentView
        case .preparingContentView:
            return .preparingContentView
        case .placeholderViewAvailable:
            return .placeholderViewAvailable
        case .contentViewAvailable:
            return .contentViewAvailable
        case .preparingForReuse:
            return .preparingForReuse
        }
    }
}

private extension PageTurnPreloadStrategy {
    var webViewPaginationPreloadStrategy: WebViewPaginationPreloadStrategy {
        switch self {
        case .conservative:
            return .conservative
        case .standard:
            return .standard
        case .aggressive:
            return .aggressive
        }
    }
}

private extension PageTurnCurrentContentLocation {
    var webViewPaginationCurrentContentLocation: WebViewPaginationCurrentContentLocation {
        switch self {
        case .center:
            return .center
        case .leading:
            return .leading
        case .trailing:
            return .trailing
        }
    }
}

private extension ReaderPageTurnNavigationEventKind {
    var pageTurnNavigationEventKind: PageTurnNavigationEventKind {
        switch self {
        case .nextPage:
            return .nextPage
        case .previousPage:
            return .previousPage
        case .noPageChange:
            return .noPageChange
        case .attemptedPastEnd:
            return .attemptedPastEnd
        }
    }
}

private extension WebViewPaginationSpreadSlotKind {
    var pageTurnSpreadSlotKind: PageTurnSpreadSlotKind {
        switch self {
        case .blank:
            return .blank
        case .page:
            return .page
        }
    }
}

private extension WebViewPaginationSpread {
    var pageTurnSpread: PageTurnSpread {
        PageTurnSpread(
            index: index,
            slots: slots.map {
                .init(kind: $0.kind.pageTurnSpreadSlotKind, pageIndex: $0.pageIndex)
            }
        )
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
fileprivate func readerPageTurnSpreadSlot(_ value: Any?) -> WebViewPaginationSpreadSlot? {
    guard let dictionary = readerPageTurnObject(value),
          let kindRawValue = dictionary["kind"] as? String,
          let kind = WebViewPaginationSpreadSlotKind(rawValue: kindRawValue) else {
        return nil
    }
    let pageIndex = dictionary["pageIndex"] as? Int ?? (dictionary["pageIndex"] as? NSNumber)?.intValue
    return WebViewPaginationSpreadSlot(kind: kind, pageIndex: pageIndex)
}

@MainActor
fileprivate func readerPageTurnSpread(_ value: Any?) -> WebViewPaginationSpread? {
    guard let dictionary = readerPageTurnObject(value),
          let slotValues = dictionary["slots"] as? [Any] else {
        return nil
    }
    let slots = slotValues.compactMap(readerPageTurnSpreadSlot)
    guard !slots.isEmpty else { return nil }
    let index = dictionary["index"] as? Int ?? (dictionary["index"] as? NSNumber)?.intValue
    return WebViewPaginationSpread(index: index, slots: slots)
}

@MainActor
fileprivate func readerPageTurnSpreadSequence(_ value: Any?) -> WebViewPaginationSpreadSequence? {
    guard let dictionary = readerPageTurnObject(value),
          let spreadValues = dictionary["spreads"] as? [Any] else {
        return nil
    }
    let spreads = spreadValues.compactMap(readerPageTurnSpread)
    guard !spreads.isEmpty else { return nil }
    let currentIndex = dictionary["currentIndex"] as? Int ?? (dictionary["currentIndex"] as? NSNumber)?.intValue
    return WebViewPaginationSpreadSequence(spreads: spreads, currentIndex: currentIndex)
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

public enum ReaderResolvedPagination {
    private static func normalizedPageLabel(_ label: String?) -> String? {
        guard let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    public static func currentPageDisplayLabel(
        bridgeLabel: String?,
        paginationState: WebViewPaginationState?
    ) -> String? {
        normalizedPageLabel(bridgeLabel) ?? normalizedPageLabel(paginationState?.currentPageDisplayLabel)
    }

    public static func currentPhysicalPageLabel(
        bridgeLabel: String?,
        paginationState: WebViewPaginationState?
    ) -> String? {
        normalizedPageLabel(bridgeLabel) ?? normalizedPageLabel(paginationState?.currentPhysicalPageLabel)
    }

    public static func pageLabelDisplayMode(
        bridgePageLabelDisplayMode: String?,
        paginationPageLabelPolicy: WebViewPaginationPageLabelPolicy?
    ) -> PageTurnPageLabelDisplayMode {
        if let paginationPageLabelPolicy {
            switch paginationPageLabelPolicy.displayMode {
            case .singleLabel:
                return .singleLabel
            case .multipleLabels:
                return .multipleLabels
            }
        }
        switch bridgePageLabelDisplayMode {
        case WebViewPaginationPageLabelDisplayMode.multipleLabels.rawValue:
            return .multipleLabels
        default:
            return .singleLabel
        }
    }

    public static func usesPhysicalPageLabels(
        bridgeCurrentPhysicalPageLabel: String?,
        paginationPageLabelPolicy: WebViewPaginationPageLabelPolicy?
    ) -> Bool {
        normalizedPageLabel(bridgeCurrentPhysicalPageLabel) != nil
            || paginationPageLabelPolicy?.usesPhysicalPageLabels == true
    }

    public static func allowsMultipleLabelsInMultiUnitLayout(
        bridgeAllowsMultipleLabelsInMultiUnitLayout: Bool?,
        paginationPageLabelPolicy: WebViewPaginationPageLabelPolicy?
    ) -> Bool {
        paginationPageLabelPolicy?.allowsMultipleLabelsInMultiUnitLayout
            ?? bridgeAllowsMultipleLabelsInMultiUnitLayout
            ?? false
    }

    public static func currentContentLocation(
        bridgeCurrentContentLocation: PageTurnCurrentContentLocation?,
        paginationCurrentContentLocation: WebViewPaginationCurrentContentLocation?,
        resolvedGraph: ReaderPageTurnResolvedGraph?
    ) -> PageTurnCurrentContentLocation {
        if let paginationCurrentContentLocation {
            switch paginationCurrentContentLocation {
            case .center:
                return .center
            case .leading:
                return .leading
            case .trailing:
                return .trailing
            }
        }
        return bridgeCurrentContentLocation ?? resolvedGraph?.currentContentLocation ?? .leading
    }

    public static func preferredSpreadSequence(
        bridgeSpreadSequence: WebViewPaginationSpreadSequence?,
        paginationSpreadSequence: WebViewPaginationSpreadSequence?
    ) -> WebViewPaginationSpreadSequence? {
        paginationSpreadSequence ?? bridgeSpreadSequence
    }

    public static func destinationSpread(
        direction: PageTurnDirection?,
        paginationDestinationSpread: WebViewPaginationSpread? = nil,
        resolvedGraph: ReaderPageTurnResolvedGraph?
    ) -> WebViewPaginationSpread? {
        if let paginationDestinationSpread {
            return paginationDestinationSpread
        }
        guard let direction else { return nil }
        return resolvedGraph?.spreadSequence.node(for: direction)?.spread
    }

    public static func currentSpread(
        bridgeCurrentSpread: WebViewPaginationSpread?,
        paginationCurrentSpread: WebViewPaginationSpread?,
        resolvedGraph: ReaderPageTurnResolvedGraph?
    ) -> WebViewPaginationSpread? {
        bridgeCurrentSpread ?? paginationCurrentSpread ?? resolvedGraph?.spreadSequence.current?.spread
    }

    public static func pageOffsetsDisplayed(
        paginationPageOffsetsDisplayed: [Int]?,
        resolvedCurrentSpread: WebViewPaginationSpread?,
        resolvedGraph: ReaderPageTurnResolvedGraph?
    ) -> [Int]? {
        paginationPageOffsetsDisplayed
            ?? resolvedCurrentSpread?.pageIndices
            ?? resolvedGraph?.currentVisiblePageIndices
    }

    public static func livePageOffsetsDisplayed(
        bridgePageOffsetsDisplayed: [Int]?,
        paginationPageOffsetsDisplayed: [Int]?,
        resolvedCurrentSpread: WebViewPaginationSpread?,
        resolvedGraph: ReaderPageTurnResolvedGraph?
    ) -> [Int]? {
        bridgePageOffsetsDisplayed
            ?? pageOffsetsDisplayed(
                paginationPageOffsetsDisplayed: paginationPageOffsetsDisplayed,
                resolvedCurrentSpread: resolvedCurrentSpread,
                resolvedGraph: resolvedGraph
            )
    }

    public static func currentPageIndex(
        bridgeCurrentPage: Int?,
        paginationCurrentPageIndex: Int? = nil,
        resolvedGraph: ReaderPageTurnResolvedGraph?
    ) -> Int? {
        bridgeCurrentPage ?? paginationCurrentPageIndex ?? resolvedGraph?.currentPageIndex
    }

    public static func visiblePageIndices(
        bridgeVisiblePageIndices: [Int]?,
        paginationVisiblePageIndices: [Int]? = nil,
        resolvedGraph: ReaderPageTurnResolvedGraph?
    ) -> [Int]? {
        bridgeVisiblePageIndices ?? paginationVisiblePageIndices ?? resolvedGraph?.currentVisiblePageIndices
    }

    public static func canMoveForward(
        bridgeCanMoveForward: Bool?,
        paginationCanMoveForward: Bool? = nil,
        resolvedGraph: ReaderPageTurnResolvedGraph?
    ) -> Bool? {
        bridgeCanMoveForward ?? paginationCanMoveForward ?? resolvedGraph?.canMoveForward
    }

    public static func canMoveBackward(
        bridgeCanMoveBackward: Bool?,
        paginationCanMoveBackward: Bool? = nil,
        resolvedGraph: ReaderPageTurnResolvedGraph?
    ) -> Bool? {
        bridgeCanMoveBackward ?? paginationCanMoveBackward ?? resolvedGraph?.canMoveBackward
    }

    public static func destinationAvailability(
        bridgeAvailability: String?,
        paginationAvailability: String? = nil,
        resolvedGraphAvailability: PageTurnDestinationAvailability?
    ) -> PageTurnDestinationAvailability? {
        bridgeAvailability
            .flatMap(PageTurnDestinationAvailability.init(rawValue:))
            ?? paginationAvailability.flatMap(PageTurnDestinationAvailability.init(rawValue:))
            ?? resolvedGraphAvailability
    }

    public static func pageCount(
        bridgePageCount: Int?,
        paginationPageCount: Int?
    ) -> Int? {
        bridgePageCount ?? paginationPageCount
    }

    public static func paginationComplete(
        bridgePaginationComplete: Bool?,
        paginationComplete: Bool?
    ) -> Bool? {
        paginationComplete ?? bridgePaginationComplete
    }

    public static func configurationKey(
        bridgeConfigurationKey: String?,
        paginationConfigurationKey: String?
    ) -> String? {
        paginationConfigurationKey ?? bridgeConfigurationKey
    }

    public static func publicationSource(
        bridgePublicationSource: WebViewPaginationPublicationSource?,
        paginationPublicationSource: WebViewPaginationPublicationSource?
    ) -> WebViewPaginationPublicationSource? {
        paginationPublicationSource ?? bridgePublicationSource
    }

    public static func pageNumberMode(
        bridgePageNumberMode: WebViewPaginationPageNumberMode?,
        paginationPageNumberMode: WebViewPaginationPageNumberMode?
    ) -> WebViewPaginationPageNumberMode? {
        paginationPageNumberMode ?? bridgePageNumberMode
    }

    public static func allowsMultipleColumns(
        bridgeAllowsMultipleColumns: Bool?,
        paginationAllowsMultipleColumns: Bool?
    ) -> Bool? {
        paginationAllowsMultipleColumns ?? bridgeAllowsMultipleColumns
    }
}

struct ReaderResolvedProbeVisibleState: Equatable {
    let pageOffsetsDisplayed: [Int]?
    let currentSpread: WebViewPaginationSpread?
    let destinationSpread: WebViewPaginationSpread?
    let currentPage: Int?
    let pageCount: Int?
    let currentPageDisplayLabel: String?
    let currentPhysicalPageLabel: String?
    let forwardDestinationAvailability: String
    let backwardDestinationAvailability: String
    let visiblePageIndices: [Int]?
    let canForward: Bool
    let canBackward: Bool

    static func resolve(
        probePageOffsetsDisplayed: [Int]?,
        probeCurrentSpread: WebViewPaginationSpread?,
        probeDestinationSpread: WebViewPaginationSpread?,
        probeCurrentPage: Int?,
        probePageCount: Int?,
        probeCurrentPageDisplayLabel: String?,
        probeCurrentPhysicalPageLabel: String?,
        probeForwardDestinationAvailability: String?,
        probeBackwardDestinationAvailability: String?,
        probeVisiblePageIndices: [Int]?,
        probeCanSemanticForward: Bool,
        probeCanSemanticBackward: Bool,
        probeResolvedGraph: ReaderPageTurnResolvedGraph?,
        currentResolvedGraph: ReaderPageTurnResolvedGraph,
        probeTurnDirection: PageTurnDirection?,
        paginationState: WebViewPaginationState?,
        existingPageCount: Int?,
        localForwardAvailability: PageTurnDestinationAvailability,
        localBackwardAvailability: PageTurnDestinationAvailability,
        supportsActivePageTurn: Bool
    ) -> ReaderResolvedProbeVisibleState {
        let pageOffsetsDisplayed = probePageOffsetsDisplayed
            ?? probeResolvedGraph?.currentVisiblePageIndices
            ?? currentResolvedGraph.currentVisiblePageIndices
        let currentSpread = probeCurrentSpread ?? probeResolvedGraph?.spreadSequence.current?.spread
        let destinationSpread = probeDestinationSpread
            ?? ReaderResolvedPagination.destinationSpread(
                direction: probeTurnDirection,
                resolvedGraph: probeResolvedGraph
            )
        let currentPage = probeCurrentPage
            ?? probeResolvedGraph?.currentPageIndex
            ?? currentResolvedGraph.currentPageIndex
        let pageCount = probePageCount ?? existingPageCount
        let currentPageDisplayLabel = ReaderResolvedPagination.currentPageDisplayLabel(
            bridgeLabel: probeCurrentPageDisplayLabel,
            paginationState: paginationState
        )
        let currentPhysicalPageLabel = ReaderResolvedPagination.currentPhysicalPageLabel(
            bridgeLabel: probeCurrentPhysicalPageLabel,
            paginationState: paginationState
        )
        let forwardDestinationAvailability = probeForwardDestinationAvailability ?? localForwardAvailability.rawValue
        let backwardDestinationAvailability = probeBackwardDestinationAvailability ?? localBackwardAvailability.rawValue
        let visiblePageIndices = probeVisiblePageIndices
            ?? probeResolvedGraph?.currentVisiblePageIndices
            ?? currentResolvedGraph.currentVisiblePageIndices
        let canForward = supportsActivePageTurn && (
            probeCanSemanticForward
            || (probeResolvedGraph?.canMoveForward ?? (localForwardAvailability != .unavailable))
        )
        let canBackward = supportsActivePageTurn && (
            probeCanSemanticBackward
            || (probeResolvedGraph?.canMoveBackward ?? (localBackwardAvailability != .unavailable))
        )
        return ReaderResolvedProbeVisibleState(
            pageOffsetsDisplayed: pageOffsetsDisplayed,
            currentSpread: currentSpread,
            destinationSpread: destinationSpread,
            currentPage: currentPage,
            pageCount: pageCount,
            currentPageDisplayLabel: currentPageDisplayLabel,
            currentPhysicalPageLabel: currentPhysicalPageLabel,
            forwardDestinationAvailability: forwardDestinationAvailability,
            backwardDestinationAvailability: backwardDestinationAvailability,
            visiblePageIndices: visiblePageIndices,
            canForward: canForward,
            canBackward: canBackward
        )
    }
}

struct ReaderResolvedBridgeSpreadState: Equatable {
    let pageOffsetsDisplayed: [Int]?
    let currentSpread: WebViewPaginationSpread?
    let destinationSpread: WebViewPaginationSpread?
    let spreadSequence: WebViewPaginationSpreadSequence?
    let pageCount: Int?
    let visiblePageIndices: [Int]?
    let canForward: Bool
    let canBackward: Bool
    let forwardDestinationAvailability: String?
    let backwardDestinationAvailability: String?

    static func resolve(
        runtimeOwnedSpreadStateAvailable: Bool,
        runtimeOwnedDestinationSpreadAvailable: Bool,
        existingPageOffsetsDisplayed: [Int]?,
        existingCurrentSpread: WebViewPaginationSpread?,
        existingDestinationSpread: WebViewPaginationSpread?,
        existingSpreadSequence: WebViewPaginationSpreadSequence?,
        existingPageCount: Int?,
        existingVisiblePageIndices: [Int]?,
        existingCanForward: Bool,
        existingCanBackward: Bool,
        existingForwardDestinationAvailability: String?,
        existingBackwardDestinationAvailability: String?,
        paginationContext: ReaderResolvedPaginationContext,
        supportsActivePageTurn: Bool
    ) -> ReaderResolvedBridgeSpreadState {
        let resolvedGraph = paginationContext.resolvedGraph
        return ReaderResolvedBridgeSpreadState(
            pageOffsetsDisplayed: runtimeOwnedSpreadStateAvailable
                ? existingPageOffsetsDisplayed
                : paginationContext.pageOffsetsDisplayed,
            currentSpread: runtimeOwnedSpreadStateAvailable
                ? existingCurrentSpread
                : paginationContext.currentSpread,
            destinationSpread: runtimeOwnedDestinationSpreadAvailable
                ? existingDestinationSpread
                : paginationContext.destinationSpread(direction: nil as PageTurnDirection?),
            spreadSequence: paginationContext.preferredSpreadSequence ?? existingSpreadSequence,
            pageCount: runtimeOwnedSpreadStateAvailable
                ? existingPageCount
                : paginationContext.pageCount,
            visiblePageIndices: runtimeOwnedSpreadStateAvailable
                ? existingVisiblePageIndices
                : paginationContext.visiblePageIndices,
            canForward: runtimeOwnedSpreadStateAvailable
                ? existingCanForward
                : (supportsActivePageTurn && (paginationContext.canMoveForward ?? resolvedGraph.canMoveForward)),
            canBackward: runtimeOwnedSpreadStateAvailable
                ? existingCanBackward
                : (supportsActivePageTurn && (paginationContext.canMoveBackward ?? resolvedGraph.canMoveBackward)),
            forwardDestinationAvailability: runtimeOwnedSpreadStateAvailable
                ? existingForwardDestinationAvailability
                : (paginationContext.destinationAvailability(for: .forward)?.rawValue
                    ?? resolvedGraph.forwardDestinationAvailability.rawValue),
            backwardDestinationAvailability: runtimeOwnedSpreadStateAvailable
                ? existingBackwardDestinationAvailability
                : (paginationContext.destinationAvailability(for: .backward)?.rawValue
                    ?? resolvedGraph.backwardDestinationAvailability.rawValue)
        )
    }
}

public enum ReaderResolvedPaginationEnrichment {
    public static func resolve(
        runtimeOwnedSpreadStateAvailable: Bool,
        runtimeOwnedDestinationSpreadAvailable: Bool,
        visibleUnit: WebViewPaginationVisibleUnit?,
        pageLabelPolicy: WebViewPaginationPageLabelPolicy?,
        currentPageDisplayLabel: String?,
        currentPhysicalPageLabel: String?,
        pageNavigationStyle: WebViewPageNavigationStyle?,
        allowsMultipleColumns: Bool?,
        pageNumberMode: WebViewPaginationPageNumberMode?,
        contentHostState: WebViewPaginationContentHostState?,
        preloadStrategy: WebViewPaginationPreloadStrategy?,
        currentContentLocation: WebViewPaginationCurrentContentLocation?,
        requestedLocation: WebViewPaginationRequestedLocation?,
        pageOffsetsDisplayed: [Int]?,
        pageOffsetRange: WebViewPaginationPageOffsetRange?,
        currentPageIndex: Int?,
        visiblePageIndices: [Int]?,
        canMoveForward: Bool?,
        canMoveBackward: Bool?,
        forwardDestinationAvailability: String?,
        backwardDestinationAvailability: String?,
        currentSpread: WebViewPaginationSpread?,
        destinationSpread: WebViewPaginationSpread?
    ) -> WebViewPaginationStateEnrichment {
        WebViewPaginationStateEnrichment(
            visibleUnit: runtimeOwnedSpreadStateAvailable ? nil : visibleUnit,
            pageLabelPolicy: pageLabelPolicy,
            currentPageDisplayLabel: currentPageDisplayLabel,
            currentPhysicalPageLabel: currentPhysicalPageLabel,
            pageNavigationStyle: runtimeOwnedSpreadStateAvailable ? nil : pageNavigationStyle,
            allowsMultipleColumns: runtimeOwnedSpreadStateAvailable ? nil : allowsMultipleColumns,
            pageNumberMode: pageNumberMode,
            contentHostState: contentHostState,
            preloadStrategy: preloadStrategy,
            currentContentLocation: runtimeOwnedSpreadStateAvailable ? nil : currentContentLocation,
            requestedLocation: requestedLocation,
            pageOffsetsDisplayed: runtimeOwnedSpreadStateAvailable ? nil : pageOffsetsDisplayed,
            pageOffsetRange: runtimeOwnedSpreadStateAvailable ? nil : pageOffsetRange,
            currentPageIndex: runtimeOwnedSpreadStateAvailable ? nil : currentPageIndex,
            visiblePageIndices: runtimeOwnedSpreadStateAvailable ? nil : visiblePageIndices,
            canMoveForward: runtimeOwnedSpreadStateAvailable ? nil : canMoveForward,
            canMoveBackward: runtimeOwnedSpreadStateAvailable ? nil : canMoveBackward,
            forwardDestinationAvailability: runtimeOwnedSpreadStateAvailable ? nil : forwardDestinationAvailability,
            backwardDestinationAvailability: runtimeOwnedSpreadStateAvailable ? nil : backwardDestinationAvailability,
            currentSpread: runtimeOwnedSpreadStateAvailable ? nil : currentSpread,
            destinationSpread: runtimeOwnedDestinationSpreadAvailable ? nil : destinationSpread
        )
    }
}

struct ReaderResolvedPaginationContext {
    let paginationState: WebViewPaginationState?
    let bridgeSpreadSequence: WebViewPaginationSpreadSequence?
    let bridgeCurrentSpread: WebViewPaginationSpread?
    let bridgeDestinationSpread: WebViewPaginationSpread?
    let bridgePageOffsetsDisplayed: [Int]?
    let bridgeVisiblePageIndices: [Int]?
    let bridgePageCount: Int?
    let bridgeCurrentPage: Int?
    let bridgeCanMoveForward: Bool?
    let bridgeCanMoveBackward: Bool?
    let bridgeCurrentContentLocation: PageTurnCurrentContentLocation?
    let bridgeForwardDestinationAvailability: String?
    let bridgeBackwardDestinationAvailability: String?
    let bridgePaginationComplete: Bool?
    let bridgeConfigurationKey: String?
    let bridgePublicationSource: WebViewPaginationPublicationSource?
    let bridgePageNumberMode: WebViewPaginationPageNumberMode?
    let bridgeAllowsMultipleColumns: Bool?
    let paginationCurrentPageIndex: Int?
    let paginationVisiblePageIndices: [Int]?
    let paginationCanMoveForward: Bool?
    let paginationCanMoveBackward: Bool?
    let paginationCurrentContentLocation: WebViewPaginationCurrentContentLocation?
    let paginationSpreadSequence: WebViewPaginationSpreadSequence?
    let paginationForwardDestinationAvailability: String?
    let paginationBackwardDestinationAvailability: String?
    let paginationComplete: Bool?
    let paginationConfigurationKey: String?
    let paginationPublicationSource: WebViewPaginationPublicationSource?
    let paginationPageNumberMode: WebViewPaginationPageNumberMode?
    let paginationAllowsMultipleColumns: Bool?
    let layoutLeadingPageIndex: Int?
    let layoutTrailingPageIndex: Int?
    let layoutVisiblePageCount: Int?

    init(
        paginationState: WebViewPaginationState?,
        bridgeSpreadSequence: WebViewPaginationSpreadSequence?,
        bridgeCurrentSpread: WebViewPaginationSpread?,
        bridgeDestinationSpread: WebViewPaginationSpread?,
        bridgePageOffsetsDisplayed: [Int]?,
        bridgeVisiblePageIndices: [Int]?,
        bridgePageCount: Int?,
        bridgeCurrentPage: Int?,
        bridgeCanMoveForward: Bool?,
        bridgeCanMoveBackward: Bool?,
        bridgeCurrentContentLocation: PageTurnCurrentContentLocation?,
        bridgeForwardDestinationAvailability: String?,
        bridgeBackwardDestinationAvailability: String?,
        bridgePaginationComplete: Bool?,
        bridgeConfigurationKey: String?,
        bridgePublicationSource: WebViewPaginationPublicationSource?,
        bridgePageNumberMode: WebViewPaginationPageNumberMode?,
        bridgeAllowsMultipleColumns: Bool?,
        paginationCurrentPageIndex: Int?,
        paginationVisiblePageIndices: [Int]?,
        paginationCanMoveForward: Bool?,
        paginationCanMoveBackward: Bool?,
        paginationCurrentContentLocation: WebViewPaginationCurrentContentLocation?,
        paginationSpreadSequence: WebViewPaginationSpreadSequence?,
        paginationForwardDestinationAvailability: String?,
        paginationBackwardDestinationAvailability: String?,
        paginationComplete: Bool?,
        paginationConfigurationKey: String?,
        paginationPublicationSource: WebViewPaginationPublicationSource?,
        paginationPageNumberMode: WebViewPaginationPageNumberMode?,
        paginationAllowsMultipleColumns: Bool?,
        layoutLeadingPageIndex: Int?,
        layoutTrailingPageIndex: Int?,
        layoutVisiblePageCount: Int?
    ) {
        self.paginationState = paginationState
        self.bridgeSpreadSequence = bridgeSpreadSequence
        self.bridgeCurrentSpread = bridgeCurrentSpread
        self.bridgeDestinationSpread = bridgeDestinationSpread
        self.bridgePageOffsetsDisplayed = bridgePageOffsetsDisplayed
        self.bridgeVisiblePageIndices = bridgeVisiblePageIndices
        self.bridgePageCount = bridgePageCount
        self.bridgeCurrentPage = bridgeCurrentPage
        self.bridgeCanMoveForward = bridgeCanMoveForward
        self.bridgeCanMoveBackward = bridgeCanMoveBackward
        self.bridgeCurrentContentLocation = bridgeCurrentContentLocation
        self.bridgeForwardDestinationAvailability = bridgeForwardDestinationAvailability
        self.bridgeBackwardDestinationAvailability = bridgeBackwardDestinationAvailability
        self.bridgePaginationComplete = bridgePaginationComplete
        self.bridgeConfigurationKey = bridgeConfigurationKey
        self.bridgePublicationSource = bridgePublicationSource
        self.bridgePageNumberMode = bridgePageNumberMode
        self.bridgeAllowsMultipleColumns = bridgeAllowsMultipleColumns
        self.paginationCurrentPageIndex = paginationCurrentPageIndex
        self.paginationVisiblePageIndices = paginationVisiblePageIndices
        self.paginationCanMoveForward = paginationCanMoveForward
        self.paginationCanMoveBackward = paginationCanMoveBackward
        self.paginationCurrentContentLocation = paginationCurrentContentLocation
        self.paginationSpreadSequence = paginationSpreadSequence
        self.paginationForwardDestinationAvailability = paginationForwardDestinationAvailability
        self.paginationBackwardDestinationAvailability = paginationBackwardDestinationAvailability
        self.paginationComplete = paginationComplete
        self.paginationConfigurationKey = paginationConfigurationKey
        self.paginationPublicationSource = paginationPublicationSource
        self.paginationPageNumberMode = paginationPageNumberMode
        self.paginationAllowsMultipleColumns = paginationAllowsMultipleColumns
        self.layoutLeadingPageIndex = layoutLeadingPageIndex
        self.layoutTrailingPageIndex = layoutTrailingPageIndex
        self.layoutVisiblePageCount = layoutVisiblePageCount
    }

    private var seedCurrentSpread: WebViewPaginationSpread? {
        paginationSpreadSequence?.currentSpread ?? paginationState?.currentSpread ?? bridgeCurrentSpread
    }

    private var seedDestinationSpread: WebViewPaginationSpread? {
        paginationState?.destinationSpread ?? bridgeDestinationSpread
    }

    private var preferredRuntimeSpreadSequence: WebViewPaginationSpreadSequence? {
        ReaderResolvedPagination.preferredSpreadSequence(
            bridgeSpreadSequence: bridgeSpreadSequence,
            paginationSpreadSequence: paginationSpreadSequence
        )
    }

    var preferredSpreadSequence: WebViewPaginationSpreadSequence? {
        preferredRuntimeSpreadSequence
    }

    var pageCount: Int? {
        paginationState?.pageCount
            ?? bridgePageCount
            ?? preferredRuntimeSpreadSequence?.spreads
                .flatMap(\.pageIndices)
                .max()
                .map { $0 + 1 }
    }

    var currentContentLocation: PageTurnCurrentContentLocation {
        ReaderResolvedPagination.currentContentLocation(
            bridgeCurrentContentLocation: bridgeCurrentContentLocation,
            paginationCurrentContentLocation: paginationCurrentContentLocation,
            resolvedGraph: resolvedGraph
        )
    }

    var metadataPaginationComplete: Bool? {
        ReaderResolvedPagination.paginationComplete(
            bridgePaginationComplete: bridgePaginationComplete,
            paginationComplete: paginationComplete
        )
    }

    var metadataConfigurationKey: String? {
        ReaderResolvedPagination.configurationKey(
            bridgeConfigurationKey: bridgeConfigurationKey,
            paginationConfigurationKey: paginationConfigurationKey
        )
    }

    var metadataPublicationSource: WebViewPaginationPublicationSource? {
        ReaderResolvedPagination.publicationSource(
            bridgePublicationSource: bridgePublicationSource,
            paginationPublicationSource: paginationPublicationSource
        )
    }

    var metadataPageNumberMode: WebViewPaginationPageNumberMode? {
        ReaderResolvedPagination.pageNumberMode(
            bridgePageNumberMode: bridgePageNumberMode,
            paginationPageNumberMode: paginationPageNumberMode
        )
    }

    var metadataAllowsMultipleColumns: Bool? {
        ReaderResolvedPagination.allowsMultipleColumns(
            bridgeAllowsMultipleColumns: bridgeAllowsMultipleColumns,
            paginationAllowsMultipleColumns: paginationAllowsMultipleColumns
        )
    }

    private var seedGraph: ReaderPageTurnResolvedGraph {
        ReaderPageTurnSpreadGraph(
            currentSpread: seedCurrentSpread,
            destinationSpread: seedDestinationSpread,
            pageOffsetsDisplayed: ReaderResolvedPagination.livePageOffsetsDisplayed(
                bridgePageOffsetsDisplayed: bridgePageOffsetsDisplayed,
                paginationPageOffsetsDisplayed: paginationState?.pageOffsetsDisplayed,
                resolvedCurrentSpread: seedCurrentSpread,
                resolvedGraph: nil
            ),
            pageCount: pageCount,
            layoutLeadingPageIndex: layoutLeadingPageIndex,
            currentPage: bridgeCurrentPage,
            layoutTrailingPageIndex: layoutTrailingPageIndex,
            layoutVisiblePageCount: layoutVisiblePageCount
        ).resolvedGraph
    }

    public var currentSpread: WebViewPaginationSpread? {
        paginationSpreadSequence?.currentSpread
            ?? paginationState?.currentSpread
            ?? bridgeCurrentSpread
            ?? seedGraph.spreadSequence.current?.spread
    }

    public var pageOffsetsDisplayed: [Int]? {
        paginationState?.pageOffsetsDisplayed
            ?? bridgePageOffsetsDisplayed
            ?? currentSpread?.pageIndices
            ?? seedGraph.currentVisiblePageIndices
    }

    public var currentPageIndex: Int? {
        paginationCurrentPageIndex ?? bridgeCurrentPage ?? seedGraph.currentPageIndex
    }

    public var visiblePageIndices: [Int]? {
        paginationVisiblePageIndices ?? bridgeVisiblePageIndices ?? seedGraph.currentVisiblePageIndices
    }

    public var canMoveForward: Bool? {
        paginationCanMoveForward ?? bridgeCanMoveForward ?? seedGraph.canMoveForward
    }

    public var canMoveBackward: Bool? {
        paginationCanMoveBackward ?? bridgeCanMoveBackward ?? seedGraph.canMoveBackward
    }

    public func destinationAvailability(for direction: PageTurnDirection) -> PageTurnDestinationAvailability? {
        switch direction {
        case .forward:
            return paginationForwardDestinationAvailability
                .flatMap(PageTurnDestinationAvailability.init(rawValue:))
                ?? bridgeForwardDestinationAvailability.flatMap(PageTurnDestinationAvailability.init(rawValue:))
                ?? seedGraph.forwardDestinationAvailability
        case .backward:
            return paginationBackwardDestinationAvailability
                .flatMap(PageTurnDestinationAvailability.init(rawValue:))
                ?? bridgeBackwardDestinationAvailability.flatMap(PageTurnDestinationAvailability.init(rawValue:))
                ?? seedGraph.backwardDestinationAvailability
        }
    }

    public func destinationSpread(direction: PageTurnDirection?) -> WebViewPaginationSpread? {
        ReaderResolvedPagination.destinationSpread(
            direction: direction,
            paginationDestinationSpread: seedDestinationSpread,
            resolvedGraph: resolvedGraph
        )
    }

    public var resolvedGraph: ReaderPageTurnResolvedGraph {
        ReaderPageTurnSpreadGraph(
            currentSpread: currentSpread,
            destinationSpread: seedDestinationSpread,
            pageOffsetsDisplayed: pageOffsetsDisplayed,
            pageCount: pageCount,
            layoutLeadingPageIndex: layoutLeadingPageIndex,
            currentPage: currentPageIndex,
            layoutTrailingPageIndex: layoutTrailingPageIndex,
            layoutVisiblePageCount: layoutVisiblePageCount
        ).resolvedGraph(runtimeSpreadSequence: preferredRuntimeSpreadSequence)
    }
}

fileprivate struct ReaderPageTurnNavigationEvent: Equatable {
    var serial: Int
    var kind: ReaderPageTurnNavigationEventKind
    var direction: PageTurnDirection
}

@MainActor
fileprivate final class ReaderPageTurnBridge: ObservableObject, PageTurnSnapshotProvider, PageTurnTurnDriver, @unchecked Sendable {
    @Published private(set) var supportsActivePageTurn = false
    @Published private(set) var probeConfirmedActivePageTurn = false
    @Published private(set) var pageProgressionDirection: PageTurnPageProgressionDirection = .leftToRight
    @Published private(set) var resolvedPaginationMode: WebViewPaginationMode = .leftToRight
    @Published private(set) var pageNavigationStyle: PageTurnNavigationStyle = .paged
    @Published private(set) var transitionFamily: PageTurnTransitionFamily = .slide
    @Published private(set) var movementKind: PageTurnMovementKind?
    @Published private(set) var layoutState: PageTurnLayoutState = .done
    @Published private(set) var updateReason: ReaderPageTurnUpdateReason?
    @Published private(set) var contentHostState: ReaderPageTurnContentHostState = .initial
    @Published private(set) var contentHostSequence: PageTurnContentHostSequence = .init()
    @Published private(set) var preloadStrategy: PageTurnPreloadStrategy = .standard
    @Published private(set) var currentContentLocation: PageTurnCurrentContentLocation = .leading
    @Published private(set) var paginationComplete: Bool?
    @Published private(set) var configurationKey: String?
    @Published private(set) var publicationSource: WebViewPaginationPublicationSource?
    @Published private(set) var pageNumberMode: WebViewPaginationPageNumberMode?
    @Published private(set) var allowsMultipleColumns: Bool?
    @Published private(set) var pageOffsetsDisplayed: [Int]?
    @Published private(set) var currentSpread: WebViewPaginationSpread?
    @Published private(set) var destinationSpread: WebViewPaginationSpread?
    @Published private(set) var spreadSequence: WebViewPaginationSpreadSequence?
    @Published private(set) var layoutReadableFrameWidth: Double?
    @Published private(set) var layoutMaxContentWidth: Double?
    @Published private(set) var layoutSemanticSideInset: Double?
    @Published private(set) var visiblePageIndices: [Int]?
    @Published private(set) var pageScrollerAnimationIsRunning: Bool?
    @Published private(set) var liveResizeActive: Bool?
    @Published private(set) var currentSectionIndex: Int?
    @Published private(set) var currentSectionHref: String?
    @Published private(set) var currentPage: Int?
    @Published private(set) var pageCount: Int?
    @Published private(set) var historyCanGoBack: Bool?
    @Published private(set) var historyCanGoForward: Bool?
    @Published private(set) var historyDepth: Int?
    @Published private(set) var historyCurrentIndex: Int?
    @Published private(set) var historyPendingReplaceStateSuppressionCount: Int?
    @Published private(set) var historySuppressedReplaceStateCount: Int?
    @Published private(set) var historyLastSuppressedReplaceStateReason: String?
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
    @Published private(set) var layoutChromeGutterWidth: Double?
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
    @Published private(set) var progressScrubberVisible: Bool?
    @Published private(set) var progressScrubberActive: Bool?
    @Published private(set) var showTitleChrome: Bool?
    @Published private(set) var showHeaderChrome: Bool?
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
    @Published private(set) var forwardDestinationAvailability: String?
    @Published private(set) var backwardDestinationAvailability: String?
    @Published private(set) var pageLabelDisplayMode: String?
    @Published private(set) var usesPhysicalPageLabels: Bool?
    @Published private(set) var allowsMultipleLabelsInMultiUnitLayout: Bool?
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
    @Published private(set) var lastNavigationEvent: ReaderPageTurnNavigationEvent?

    private var navigator: WebViewNavigator?
    private var scriptCaller: WebViewScriptCaller?
    private var lastKnownState: WebViewState = .empty
    private var capabilityRefreshTask: Task<Void, Never>?
    private var lastCapabilityKey: String?
    private var publicationSerial = 0
    private var nextTurnEventSerial = 0
    private var nextNavigationEventSerial = 0
    private var nextContentHostSequenceSerial = 0
    private var requestedLocationState: ReaderPageTurnRequestedLocationState?

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

    var preloadTaskID: String {
        let visiblePageCountString: String
        if let visiblePageCount = visiblePageIndices?.count ?? Optional(resolvedGraph.visiblePageCount), visiblePageCount > 0 {
            visiblePageCountString = String(visiblePageCount)
        } else {
            visiblePageCountString = "nil"
        }
        let pageCountString = pageCount.map(String.init) ?? "nil"
        let resolvedCurrentContentLocation = currentContentLocation
        return [
            preloadStrategy.rawValue,
            resolvedCurrentContentLocation.rawValue,
            visiblePageCountString,
            pageCountString,
        ].joined(separator: "|")
    }

    private var spreadGraph: ReaderPageTurnSpreadGraph {
        ReaderPageTurnSpreadGraph(
            currentSpread: currentSpread,
            destinationSpread: destinationSpread,
            pageOffsetsDisplayed: pageOffsetsDisplayed,
            pageCount: pageCount,
            layoutLeadingPageIndex: layoutLeadingPageIndex,
            currentPage: currentPage,
            layoutTrailingPageIndex: layoutTrailingPageIndex,
            layoutVisiblePageCount: layoutVisiblePageCount
        )
    }

    private var movementGraph: ReaderPageTurnMovementGraph {
        spreadGraph.movementGraph
    }

    private var preferredRuntimeSpreadSequence: WebViewPaginationSpreadSequence? {
        ReaderResolvedPagination.preferredSpreadSequence(
            bridgeSpreadSequence: spreadSequence,
            paginationSpreadSequence: lastKnownState.paginationState?.spreadSequence
        )
    }

    private var resolvedGraph: ReaderPageTurnResolvedGraph {
        spreadGraph.resolvedGraph(runtimeSpreadSequence: preferredRuntimeSpreadSequence)
    }

    private func spreadGraph(for probe: ReaderPageTurnNavigationProbe?) -> ReaderPageTurnSpreadGraph? {
        guard let probe else { return nil }
        return ReaderPageTurnSpreadGraph(
            currentSpread: probe.currentSpread,
            destinationSpread: probe.destinationSpread,
            pageOffsetsDisplayed: probe.pageOffsetsDisplayed,
            pageCount: probe.pageCount,
            layoutLeadingPageIndex: probe.layoutLeadingPageIndex,
            currentPage: probe.currentPage,
            layoutTrailingPageIndex: probe.layoutTrailingPageIndex,
            layoutVisiblePageCount: probe.layoutVisiblePageCount
        )
    }

    private func resolvedGraph(for probe: ReaderPageTurnNavigationProbe?) -> ReaderPageTurnResolvedGraph? {
        guard let probe else { return nil }
        let preferredSpreadSequence = ReaderResolvedPagination.preferredSpreadSequence(
            bridgeSpreadSequence: probe.spreadSequence,
            paginationSpreadSequence: lastKnownState.paginationState?.spreadSequence
        )
        return spreadGraph(for: probe)?.resolvedGraph(runtimeSpreadSequence: preferredSpreadSequence)
    }

    private func localSemanticAvailability(for direction: PageTurnDirection) -> PageTurnDestinationAvailability {
        let availability = resolvedGraph.destinationAvailability(for: direction)
        return availability == .unavailable ? .unavailable : availability
    }

    private func resolvedPaginationGraph(
        paginationState: WebViewPaginationState?
    ) -> ReaderPageTurnResolvedGraph? {
        guard let paginationState else { return nil }
        return ReaderPageTurnSpreadGraph(
            currentSpread: paginationState.currentSpread,
            destinationSpread: paginationState.destinationSpread,
            pageOffsetsDisplayed: paginationState.pageOffsetsDisplayed,
            pageCount: paginationState.pageCount,
            layoutLeadingPageIndex: nil,
            currentPage: nil,
            layoutTrailingPageIndex: nil,
            layoutVisiblePageCount: nil
        ).resolvedGraph(runtimeSpreadSequence: paginationState.spreadSequence)
    }

    private func bridgeResolvedPaginationContext(
        paginationState: WebViewPaginationState?
    ) -> ReaderResolvedPaginationContext {
        ReaderResolvedPaginationContext(
            paginationState: paginationState,
            bridgeSpreadSequence: spreadSequence,
            bridgeCurrentSpread: currentSpread,
            bridgeDestinationSpread: destinationSpread,
            bridgePageOffsetsDisplayed: pageOffsetsDisplayed,
            bridgeVisiblePageIndices: visiblePageIndices,
            bridgePageCount: pageCount,
            bridgeCurrentPage: currentPage,
            bridgeCanMoveForward: canForward,
            bridgeCanMoveBackward: canBackward,
            bridgeCurrentContentLocation: currentContentLocation,
            bridgeForwardDestinationAvailability: forwardDestinationAvailability,
            bridgeBackwardDestinationAvailability: backwardDestinationAvailability,
            bridgePaginationComplete: paginationComplete,
            bridgeConfigurationKey: configurationKey,
            bridgePublicationSource: publicationSource,
            bridgePageNumberMode: pageNumberMode,
            bridgeAllowsMultipleColumns: allowsMultipleColumns,
            paginationCurrentPageIndex: paginationState?.currentPageIndex,
            paginationVisiblePageIndices: paginationState?.visiblePageIndices,
            paginationCanMoveForward: paginationState?.canMoveForward,
            paginationCanMoveBackward: paginationState?.canMoveBackward,
            paginationCurrentContentLocation: paginationState?.currentContentLocation,
            paginationSpreadSequence: paginationState?.spreadSequence,
            paginationForwardDestinationAvailability: paginationState?.forwardDestinationAvailability,
            paginationBackwardDestinationAvailability: paginationState?.backwardDestinationAvailability,
            paginationComplete: paginationState?.paginationComplete,
            paginationConfigurationKey: paginationState?.configurationKey,
            paginationPublicationSource: paginationState?.publicationSource,
            paginationPageNumberMode: paginationState?.pageNumberMode,
            paginationAllowsMultipleColumns: paginationState?.allowsMultipleColumns,
            layoutLeadingPageIndex: layoutLeadingPageIndex,
            layoutTrailingPageIndex: layoutTrailingPageIndex,
            layoutVisiblePageCount: layoutVisiblePageCount
        )
    }

    private func resetPublishedContextStateForIneligibleTurns() {
        capabilityRefreshTask?.cancel()
        capabilityRefreshTask = nil
        lastCapabilityKey = nil
        supportsActivePageTurn = false
        probeConfirmedActivePageTurn = false
        pageProgressionDirection = .leftToRight
        resolvedPaginationMode = .leftToRight
        pageNavigationStyle = .paged
        transitionFamily = .slide
        movementKind = nil
        layoutState = .done
        updateReason = nil
        contentHostState = .initial
        contentHostSequence = .init()
        preloadStrategy = .standard
        currentContentLocation = .leading
        paginationComplete = nil
        configurationKey = nil
        publicationSource = nil
        pageNumberMode = nil
        allowsMultipleColumns = nil
        pageOffsetsDisplayed = nil
        currentSpread = nil
        destinationSpread = nil
        spreadSequence = nil
        layoutReadableFrameWidth = nil
        layoutMaxContentWidth = nil
        layoutSemanticSideInset = nil
        visiblePageIndices = nil
        pageScrollerAnimationIsRunning = nil
        liveResizeActive = nil
        lastNavigationEvent = nil
        currentSectionIndex = nil
        currentSectionHref = nil
        currentPage = nil
        livePageIndex = nil
        liveChunkPageIndex = nil
        viewportCenterChunkPageIndex = nil
        pageCount = nil
        historyCanGoBack = nil
        historyCanGoForward = nil
        historyDepth = nil
        historyCurrentIndex = nil
        historyPendingReplaceStateSuppressionCount = nil
        historySuppressedReplaceStateCount = nil
        historyLastSuppressedReplaceStateReason = nil
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
        layoutChromeGutterWidth = nil
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
        progressScrubberVisible = nil
        progressScrubberActive = nil
        showTitleChrome = nil
        showHeaderChrome = nil
        loadEBookStarted = false
        loadEBookReady = false
        loadEBookAttemptCount = nil
        loadEBookStartAgeMs = nil
        loadEBookLastState = nil
        forwardDestinationAvailability = nil
        backwardDestinationAvailability = nil
        pageLabelDisplayMode = nil
        usesPhysicalPageLabels = nil
        allowsMultipleLabelsInMultiUnitLayout = nil
        canForward = false
        canBackward = false
        lastProbeError = nil
    }

    private func publishCurrentPageLabelState(
        currentPageDisplayLabel: String?,
        currentPhysicalPageLabel: String?,
        pageLabelDisplayMode: String?,
        usesPhysicalPageLabels: Bool?,
        allowsMultipleLabelsInMultiUnitLayout: Bool?
    ) {
        self.currentPageDisplayLabel = currentPageDisplayLabel
        self.currentPhysicalPageLabel = currentPhysicalPageLabel
        self.pageLabelDisplayMode = pageLabelDisplayMode
        self.usesPhysicalPageLabels = usesPhysicalPageLabels
        self.allowsMultipleLabelsInMultiUnitLayout = allowsMultipleLabelsInMultiUnitLayout
    }

    private func publishPaginationMetadata(
        currentContentLocation: PageTurnCurrentContentLocation,
        paginationComplete: Bool?,
        configurationKey: String?,
        publicationSource: WebViewPaginationPublicationSource?,
        pageNumberMode: WebViewPaginationPageNumberMode?,
        allowsMultipleColumns: Bool?
    ) {
        self.currentContentLocation = currentContentLocation
        self.paginationComplete = paginationComplete
        self.configurationKey = configurationKey
        self.publicationSource = publicationSource
        self.pageNumberMode = pageNumberMode
        self.allowsMultipleColumns = allowsMultipleColumns
    }

    private func publishProbeDiagnosticsState(_ probe: ReaderPageTurnNavigationProbe) {
        hasView = probe.hasView
        hasRenderer = probe.hasRenderer
        hasSectionLayoutController = probe.hasSectionLayoutController
        loadEBookStarted = probe.loadEBookStarted
        loadEBookReady = probe.loadEBookReady
        loadEBookAttemptCount = probe.loadEBookAttemptCount
        loadEBookStartAgeMs = probe.loadEBookStartAgeMs
        loadEBookLastState = probe.loadEBookLastState
        lastProbeError = probe.probeError
    }

    private func resolvedLocalActiveTurnSupport(
        navigator: WebViewNavigator?,
        webViewState: WebViewState,
        paginationState: WebViewPaginationState?
    ) -> Bool {
        guard navigator?.hasAttachedWebView == true,
              let paginationState,
              paginationState.isAppliedToMountedHost,
              paginationState.paginationComplete == true,
              !webViewState.isLoading,
              !webViewState.isProvisionallyNavigating else {
            return false
        }

        let resolvedGraph = resolvedPaginationGraph(paginationState: paginationState)
        return (resolvedGraph?.visiblePageCount ?? 0) > 0 || ((paginationState.pageCount ?? 0) > 0)
    }

    var contentHostSequenceTaskID: String {
        [
            contentHostSequence.mountedHostIdentifier ?? "nil",
            contentHostSequence.appliedHostIdentifier ?? "nil",
            contentHostSequence.isAppliedToMountedHost ? "applied" : "notApplied",
            contentHostSequence.isStable ? "stable" : "unstable",
            String(contentHostSequence.serial),
        ].joined(separator: "|")
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
            resetPublishedContextStateForIneligibleTurns()
            return
        }

        let paginationState = webViewState.paginationState
        let localSupportsActivePageTurn = resolvedLocalActiveTurnSupport(
            navigator: navigator,
            webViewState: webViewState,
            paginationState: paginationState
        )
        let paginationContext = bridgeResolvedPaginationContext(paginationState: paginationState)
        let resolvedGraph = paginationContext.resolvedGraph
        let runtimeOwnedSpreadStateAvailable = paginationState?.spreadSequence != nil
        let runtimeOwnedDestinationSpreadAvailable = paginationState?.destinationSpread != nil
        let publishedSpreadState = ReaderResolvedBridgeSpreadState.resolve(
            runtimeOwnedSpreadStateAvailable: runtimeOwnedSpreadStateAvailable,
            runtimeOwnedDestinationSpreadAvailable: runtimeOwnedDestinationSpreadAvailable,
            existingPageOffsetsDisplayed: pageOffsetsDisplayed,
            existingCurrentSpread: currentSpread,
            existingDestinationSpread: destinationSpread,
            existingSpreadSequence: spreadSequence,
            existingPageCount: pageCount,
            existingVisiblePageIndices: visiblePageIndices,
            existingCanForward: canForward,
            existingCanBackward: canBackward,
            existingForwardDestinationAvailability: forwardDestinationAvailability,
            existingBackwardDestinationAvailability: backwardDestinationAvailability,
            paginationContext: paginationContext,
            supportsActivePageTurn: localSupportsActivePageTurn
        )
        publicationSerial += 1
        updateReason = .configurationChange
        pageNavigationStyle = paginationState?.pageNavigationStyle?.pageTurnNavigationStyle ?? .paged
        transitionFamily = readerResolvedPageTurnTransitionFamily(
            navigationStyle: pageNavigationStyle,
            transitionFamily: .slide
        )
        layoutState = .aboutToChange
        let nextContentHostState = resolvedContentHostState(
            webViewState: webViewState,
            paginationState: paginationState,
            supportsActivePageTurn: localSupportsActivePageTurn
        )
        contentHostState = nextContentHostState
        contentHostSequence = resolvedContentHostSequence(
            webViewState: webViewState,
            paginationState: paginationState
        )
        preloadStrategy = resolvedPreloadStrategy(
            webViewState: webViewState,
            paginationState: paginationState,
            requestedLocationState: requestedLocationState,
            contentHostState: nextContentHostState,
            supportsActivePageTurn: localSupportsActivePageTurn
        )
        supportsActivePageTurn = localSupportsActivePageTurn
        probeConfirmedActivePageTurn = false
        publishPaginationMetadata(
            currentContentLocation: paginationContext.currentContentLocation,
            paginationComplete: paginationContext.metadataPaginationComplete,
            configurationKey: paginationContext.metadataConfigurationKey,
            publicationSource: paginationContext.metadataPublicationSource,
            pageNumberMode: paginationContext.metadataPageNumberMode,
            allowsMultipleColumns: paginationContext.metadataAllowsMultipleColumns
        )
        publishCurrentPageLabelState(
            currentPageDisplayLabel: ReaderResolvedPagination.currentPageDisplayLabel(
                bridgeLabel: nil,
                paginationState: paginationContext.paginationState
            ),
            currentPhysicalPageLabel: ReaderResolvedPagination.currentPhysicalPageLabel(
                bridgeLabel: nil,
                paginationState: paginationContext.paginationState
            ),
            pageLabelDisplayMode: paginationState?.pageLabelPolicy?.displayMode.rawValue,
            usesPhysicalPageLabels: paginationState?.pageLabelPolicy?.usesPhysicalPageLabels,
            allowsMultipleLabelsInMultiUnitLayout: paginationState?.pageLabelPolicy?.allowsMultipleLabelsInMultiUnitLayout
        )
        pageOffsetsDisplayed = publishedSpreadState.pageOffsetsDisplayed
        currentSpread = publishedSpreadState.currentSpread
        destinationSpread = publishedSpreadState.destinationSpread
        spreadSequence = publishedSpreadState.spreadSequence
        pageCount = publishedSpreadState.pageCount
        visiblePageIndices = publishedSpreadState.visiblePageIndices
        canForward = publishedSpreadState.canForward
        canBackward = publishedSpreadState.canBackward
        forwardDestinationAvailability = publishedSpreadState.forwardDestinationAvailability
        backwardDestinationAvailability = publishedSpreadState.backwardDestinationAvailability
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
        let capturedPublicationSerial = publicationSerial
        capabilityRefreshTask = Task { [weak self] in
            guard let self else { return }
            let maxAttempts = 120
            let retryDelayNanoseconds: UInt64 = 500_000_000
            var lastProbe: ReaderPageTurnNavigationProbe?

            for attempt in 1...maxAttempts {
                let probe = await self.fetchNavigationProbe()
                guard !Task.isCancelled else { return }
                guard self.publicationSerial == capturedPublicationSerial else { return }
                lastProbe = probe
                self.applyNavigationProbe(probe, publicationSerial: capturedPublicationSerial)
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
            applyNavigationProbe(lastProbe, publicationSerial: capturedPublicationSerial)
        }
    }

    func updateRequestedLocationState(_ state: ReaderPageTurnRequestedLocationState?) {
        requestedLocationState = state
    }

    func destinationAvailability(for direction: PageTurnDirection) async -> PageTurnDestinationAvailability {
        resolvedDestinationAvailability(for: direction)
    }

    private func resolvedDestinationAvailability(for direction: PageTurnDirection) -> PageTurnDestinationAvailability {
        guard supportsActivePageTurn || hasFallbackTurnReadiness else {
            return .unavailable
        }
        let localAvailability = localSemanticAvailability(for: direction)
        guard supportsActivePageTurn else {
            return localAvailability
        }
        let isAvailable = switch direction {
        case .forward:
            canForward || canNext
        case .backward:
            canBackward || canPrev
        }
        guard isAvailable else {
            return localAvailability
        }
        guard resolvedGraph.usesSpreadAwareNavigationSemantics else {
            return localAvailability == .unavailable ? .both : localAvailability
        }
        return localAvailability == .unavailable ? .both : localAvailability
    }

    func commitTurn(_ direction: PageTurnDirection) async throws {
        updateReason = .userInteraction
        guard (supportsActivePageTurn || hasFallbackTurnReadiness), let scriptCaller else { return }
        guard resolvedDestinationAvailability(for: direction) != .unavailable else {
            movementKind = nil
            publishNavigationEvent(.attemptedPastEnd, direction: direction)
            throw NSError(
                domain: "ReaderPageTurnBridge",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Destination unavailable for \(direction.rawValue)"]
            )
        }
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
            applyNavigationProbe(baselineProbe, publicationSerial: publicationSerial)
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
           ReaderPageTurnNavigationComparison.shouldRetryCommittedTurnAfterActivation(
            baseline: ReaderPageTurnNavigationObservation(probe: baselineProbe),
            activatedProbe: ReaderPageTurnNavigationObservation(probe: activatedProbe)
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
        let navigationEventKind = ReaderPageTurnNavigationComparison.classifyCommittedTurn(
            direction: direction,
            baseline: baselineProbe.map(ReaderPageTurnNavigationObservation.init(probe:)),
            after: afterProbe.map(ReaderPageTurnNavigationObservation.init(probe:))
        )
        movementKind = resolvedMovementKind(
            for: direction,
            baselineProbe: baselineProbe,
            afterProbe: afterProbe,
            navigationEventKind: navigationEventKind
        )
        publishNavigationEvent(navigationEventKind, direction: direction)
        publishTurnEvent(.committed, direction: direction)
    }

    private func currentNavigationDebugPayload() -> [String: String] {
        currentCachedNavigationProbe().logPayload
    }

    private func currentCachedNavigationProbe() -> ReaderPageTurnNavigationProbe {
        return ReaderPageTurnNavigationProbe(
            pageNavigationStyle: pageNavigationStyle,
            transitionFamily: transitionFamily,
            movementKind: movementKind,
            layoutState: layoutState,
            updateReason: updateReason,
            navigationEvent: lastNavigationEvent?.kind,
            contentHostState: contentHostState,
            preloadStrategy: preloadStrategy,
            currentContentLocation: currentContentLocation,
            pageOffsetsDisplayed: pageOffsetsDisplayed,
            currentSpread: currentSpread,
            destinationSpread: destinationSpread,
            spreadSequence: spreadSequence,
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
            livePageIndex: livePageIndex,
            liveChunkPageIndex: liveChunkPageIndex,
            viewportCenterChunkPageIndex: viewportCenterChunkPageIndex,
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
            layoutChromeGutterWidth: layoutChromeGutterWidth,
            layoutReadableFrameWidth: layoutReadableFrameWidth,
            layoutMaxContentWidth: layoutMaxContentWidth,
            layoutSemanticSideInset: layoutSemanticSideInset,
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
            progressScrubberVisible: progressScrubberVisible,
            progressScrubberActive: progressScrubberActive,
            historyCanGoBack: historyCanGoBack,
            historyCanGoForward: historyCanGoForward,
            historyDepth: historyDepth,
            historyCurrentIndex: historyCurrentIndex,
            historyPendingReplaceStateSuppressionCount: historyPendingReplaceStateSuppressionCount,
            historySuppressedReplaceStateCount: historySuppressedReplaceStateCount,
            historyLastSuppressedReplaceStateReason: historyLastSuppressedReplaceStateReason,
            showTitleChrome: showTitleChrome,
            showHeaderChrome: showHeaderChrome,
            loadEBookStarted: loadEBookStarted,
            loadEBookReady: loadEBookReady,
            loadEBookAttemptCount: loadEBookAttemptCount,
            loadEBookStartAgeMs: loadEBookStartAgeMs,
            loadEBookLastState: loadEBookLastState,
            sameDocumentHostTurnPhase: sameDocumentHostTurnPhase,
            sameDocumentHostTurnDirection: sameDocumentHostTurnDirection,
            sameDocumentHostTurnCurrentPageIndex: sameDocumentHostTurnCurrentPageIndex,
            sameDocumentHostTurnTargetPageIndex: sameDocumentHostTurnTargetPageIndex,
            sameDocumentHostTurnPageCount: sameDocumentHostTurnPageCount,
            sameDocumentHostTurnDatasetCurrentPageIndex: sameDocumentHostTurnDatasetCurrentPageIndex,
            sameDocumentHostTurnResult: sameDocumentHostTurnResult,
            forwardDestinationAvailability: forwardDestinationAvailability,
            backwardDestinationAvailability: backwardDestinationAvailability,
            paginationComplete: paginationComplete,
            configurationKey: configurationKey,
            publicationSource: publicationSource,
            pageLabelDisplayMode: pageLabelDisplayMode,
            pageNumberMode: pageNumberMode,
            usesPhysicalPageLabels: usesPhysicalPageLabels,
            allowsMultipleColumns: allowsMultipleColumns,
            allowsMultipleLabelsInMultiUnitLayout: allowsMultipleLabelsInMultiUnitLayout,
            visiblePageIndices: visiblePageIndices,
            pageScrollerAnimationIsRunning: pageScrollerAnimationIsRunning,
            liveResizeActive: liveResizeActive,
            probeError: lastProbeError
        )
    }

    private func resolvedContentHostState(
        webViewState: WebViewState,
        paginationState: WebViewPaginationState?,
        supportsActivePageTurn: Bool
    ) -> ReaderPageTurnContentHostState {
        if !webViewState.hasReaderRenderReady && !loadEBookStarted {
            return .initial
        }
        if webViewState.isProvisionallyNavigating {
            return .preparingForReuse
        }
        if webViewState.isLoading, paginationState?.mountedHostIdentifier == nil {
            return .waitingOnContentView
        }
        if paginationState?.mountedHostIdentifier == nil {
            return .waitingOnContentView
        }
        if paginationState?.appliedHostIdentifier == nil {
            return .preparingContentView
        }
        if paginationState?.isAppliedToMountedHost != true {
            return .placeholderViewAvailable
        }
        if paginationState?.paginationComplete == false {
            return .placeholderViewAvailable
        }
        if paginationState?.isAppliedToMountedHost == true {
            return supportsActivePageTurn ? .contentViewAvailable : .placeholderViewAvailable
        }
        return .placeholderViewAvailable
    }

    private func resolvedPreloadStrategy(
        webViewState: WebViewState,
        paginationState: WebViewPaginationState?,
        requestedLocationState: ReaderPageTurnRequestedLocationState?,
        contentHostState: ReaderPageTurnContentHostState,
        supportsActivePageTurn: Bool
    ) -> PageTurnPreloadStrategy {
        let resolvedGraph = resolvedPaginationGraph(paginationState: paginationState)
        let hasResolvedNeighborWindow =
            resolvedGraph?.spreadSequence.backward != nil
            || resolvedGraph?.spreadSequence.forward != nil
        if webViewState.isProvisionallyNavigating || contentHostState == .preparingForReuse {
            return .conservative
        }
        if requestedLocationState != nil || webViewState.isLoading {
            return .conservative
        }
        if supportsActivePageTurn,
           paginationState?.paginationComplete == true,
           (resolvedGraph?.visiblePageCount ?? 0) > 1 || hasResolvedNeighborWindow {
            return .aggressive
        }
        return .standard
    }

    private func resolvedCurrentContentLocation(
        paginationState: WebViewPaginationState?
    ) -> PageTurnCurrentContentLocation {
        ReaderResolvedPagination.currentContentLocation(
            bridgeCurrentContentLocation: currentContentLocation,
            paginationCurrentContentLocation: paginationState?.currentContentLocation,
            resolvedGraph: resolvedGraph
        )
    }

    private func resolvedContentHostSequence(
        webViewState: WebViewState,
        paginationState: WebViewPaginationState?
    ) -> PageTurnContentHostSequence {
        let mountedHostIdentifier = paginationState?.mountedHostIdentifier
        let appliedHostIdentifier = paginationState?.appliedHostIdentifier
        let isAppliedToMountedHost = paginationState?.isAppliedToMountedHost ?? false
        let isStable =
            mountedHostIdentifier != nil
            && isAppliedToMountedHost
            && paginationState?.paginationComplete == true
            && !webViewState.isLoading
            && !webViewState.isProvisionallyNavigating

        let hostIdentityChanged =
            contentHostSequence.mountedHostIdentifier != mountedHostIdentifier
            || contentHostSequence.appliedHostIdentifier != appliedHostIdentifier
            || contentHostSequence.isAppliedToMountedHost != isAppliedToMountedHost

        if hostIdentityChanged {
            nextContentHostSequenceSerial += 1
        }

        return PageTurnContentHostSequence(
            mountedHostIdentifier: mountedHostIdentifier,
            appliedHostIdentifier: appliedHostIdentifier,
            isAppliedToMountedHost: isAppliedToMountedHost,
            isStable: isStable,
            serial: nextContentHostSequenceSerial
        )
    }

    private func resolvedProbePrimarySpacing(_ probe: ReaderPageTurnNavigationProbe) -> Double {
        if let measuredGap = probe.layoutMeasuredGap ?? layoutMeasuredGap {
            return max(0, measuredGap)
        }
        if let currentSpacing = probe.layoutPrimarySpacing ?? layoutPrimarySpacing {
            return max(0, currentSpacing)
        }
        return 0
    }

    private func resolvedProbeChromeGutterWidth(_ probe: ReaderPageTurnNavigationProbe) -> Double {
        let visiblePageCount = max(1, probe.layoutVisiblePageCount ?? probe.layoutColumnCount ?? 1)
        guard visiblePageCount > 1 else { return 0 }
        return min(max(resolvedProbePrimarySpacing(probe), 12), 48)
    }

    func updateResolvedPageLabelPolicy(_ pageLabelPolicy: PageTurnPageLabelPolicy) {
        pageLabelDisplayMode = pageLabelPolicy.displayMode.rawValue
        usesPhysicalPageLabels = pageLabelPolicy.usesPhysicalPageLabels
        allowsMultipleLabelsInMultiUnitLayout = pageLabelPolicy.allowsMultipleLabelsInMultiUnitLayout
    }

    func updateResolvedChromeVisibility(_ chromeVisibility: PageTurnChromeVisibility) {
        showTitleChrome = chromeVisibility.showTitle
        showHeaderChrome = chromeVisibility.showHeader
    }

    func updateResolvedPageTurnPresentation(
        navigationStyle: PageTurnNavigationStyle,
        transitionFamily: PageTurnTransitionFamily,
        layoutState: PageTurnLayoutState,
        updateReason: ReaderPageTurnUpdateReason,
        pageNumberMode: WebViewPaginationPageNumberMode,
        allowsMultipleColumns: Bool
    ) {
        self.pageNavigationStyle = navigationStyle
        self.transitionFamily = transitionFamily
        self.layoutState = layoutState
        self.updateReason = updateReason
        self.pageNumberMode = pageNumberMode
        self.allowsMultipleColumns = allowsMultipleColumns
    }

    private func resolvedMovementKind(
        for direction: PageTurnDirection,
        baselineProbe: ReaderPageTurnNavigationProbe?,
        afterProbe: ReaderPageTurnNavigationProbe?,
        navigationEventKind: ReaderPageTurnNavigationEventKind
    ) -> PageTurnMovementKind? {
        guard navigationEventKind != .noPageChange else {
            return nil
        }
        let effectiveDirection: PageTurnDirection = switch navigationEventKind {
        case .nextPage:
            .forward
        case .previousPage:
            .backward
        case .attemptedPastEnd, .noPageChange:
            direction
        }
        let sectionChanged =
            baselineProbe?.currentSectionIndex != afterProbe?.currentSectionIndex
            || baselineProbe?.currentSectionHref != afterProbe?.currentSectionHref
        if sectionChanged {
            return effectiveDirection == .forward ? .chapterForward : .chapterBackward
        }
        return effectiveDirection == .forward ? .spreadForward : .spreadBackward
    }

    private func currentVisiblePageIndices() -> [Int]? {
        resolvedGraph.spreadSequence.current?.pageIndices ?? resolvedGraph.currentVisiblePageIndices
    }

    private func destinationPageIndices(for direction: PageTurnDirection) -> [Int]? {
        resolvedGraph.spreadSequence.node(for: direction)?.pageIndices ?? resolvedGraph.destinationPageIndices(for: direction)
    }

    private func resolvedSnapshotChromeContent(for request: PageTurnSnapshotRequest) async -> PageTurnSnapshotChromeContent? {
        guard request.includeChrome else { return nil }
        let titlePrimary = lastKnownState.pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleSecondary = await resolvedSnapshotSectionTitle()
        let snapshotVisibleUnit = request.visibleUnit
        let snapshotPageLabelPolicy = request.pageLabelPolicy
        let paginationContext = bridgeResolvedPaginationContext(paginationState: lastKnownState.paginationState)
        let snapshotGraph = ReaderPageTurnSpreadGraph(
            currentSpread: ReaderResolvedPagination.currentSpread(
                bridgeCurrentSpread: currentSpread,
                paginationCurrentSpread: lastKnownState.paginationState?.currentSpread,
                resolvedGraph: resolvedGraph
            ),
            destinationSpread: ReaderResolvedPagination.destinationSpread(
                direction: request.intent == .dragDestination ? request.direction : nil,
                resolvedGraph: resolvedGraph
            ),
            pageOffsetsDisplayed: currentVisiblePageIndices(),
            pageCount: pageCount,
            layoutLeadingPageIndex: snapshotVisibleUnit.leadingPageIndex ?? layoutLeadingPageIndex,
            currentPage: currentPage ?? snapshotVisibleUnit.currentUnitIndex,
            layoutTrailingPageIndex: snapshotVisibleUnit.trailingPageIndex ?? layoutTrailingPageIndex,
            layoutVisiblePageCount: snapshotVisibleUnit.visiblePageCount
        ).resolvedGraph
        let pageIndices = switch request.intent {
        case .dragDestination:
            snapshotGraph.spreadSequence.node(for: request.direction)?.pageIndices
                ?? snapshotGraph.destinationPageIndices(for: request.direction)
                ?? snapshotGraph.currentVisiblePageIndices
                ?? []
        case .dragSource, .turnSource:
            snapshotGraph.spreadSequence.current?.pageIndices
                ?? snapshotGraph.currentVisiblePageIndices
                ?? []
        }
        let currentPageNumber = pageIndices.first.map { $0 + 1 }
        let trailingPageNumber = pageIndices.last.map { $0 + 1 }
        let totalPages = paginationContext.pageCount
        let displayLabel: String? = {
            if let currentPageNumber, let trailingPageNumber, trailingPageNumber > currentPageNumber {
                if let totalPages {
                    return "\(currentPageNumber)-\(trailingPageNumber) of \(totalPages)"
                }
                return "\(currentPageNumber)-\(trailingPageNumber)"
            }
            if request.intent != .dragDestination,
               let currentPageDisplayLabel = currentPageDisplayLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
               !currentPageDisplayLabel.isEmpty {
                return currentPageDisplayLabel
            }
            if let currentPageNumber {
                if let totalPages {
                    return "Page \(currentPageNumber) of \(totalPages)"
                }
                return "Page \(currentPageNumber)"
            }
            return nil
        }()
        let leadingLabel = currentPageNumber.map { "Page \($0)" }
        let trailingLabel: String?
        if let trailingPageNumber, trailingPageNumber != currentPageNumber {
            trailingLabel = "Page \(trailingPageNumber)"
        } else {
            trailingLabel = nil
        }
        let validatedPageCount = [
            totalPages,
            snapshotGraph.pageOffsetRange.map { $0.upperBound + 1 },
            pageIndices.max().map { $0 + 1 }
        ].compactMap { $0 }.max()
        let pageRange = snapshotGraph.pageOffsetRange.map { ($0.lowerBound + 1)...($0.upperBound + 1) }
        let chromeTopInset = max(0, request.contentRect.minY)
        let horizontalInset = max(0, request.contentRect.minX)
        let hudWidth = max(0, request.contentRect.width)
        return ReaderPageTurnSnapshotChrome.resolve(
            headerLabels: await resolvedSnapshotHeaderLabels(for: request),
            titlePrimary: titlePrimary,
            titleSecondary: titleSecondary,
            pageLabelDisplayMode: snapshotPageLabelPolicy.displayMode,
            displayLabel: displayLabel,
            currentPageNumber: currentPageNumber,
            trailingPageNumber: trailingPageNumber,
            totalPages: totalPages,
            validatedPageCount: validatedPageCount,
            pageRange: pageRange,
            progressScrubberVisible: progressScrubberVisible,
            progressScrubberActive: progressScrubberActive,
            hideNavigationDueToScroll: false,
            chromeTopInset: chromeTopInset,
            horizontalInset: horizontalInset,
            hudWidth: hudWidth
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
        let sourcePageIndices = resolvedGraph.spreadSequence.current?.pageIndices ?? currentVisiblePageIndices() ?? {
            let leading = max(0, visibleUnit.leadingPageIndex ?? currentIndex)
            let trailing = max(leading, visibleUnit.trailingPageIndex ?? (leading + max(0, step - 1)))
            return trailing > leading ? [leading, trailing] : [leading]
        }()
        let resolvedDestinationPageIndices = resolvedGraph.spreadSequence.node(for: request.direction)?.pageIndices
            ?? destinationPageIndices(for: request.direction)
        let fallbackDestinationPageIndices: [Int] = switch request.intent {
        case .dragDestination:
            if let resolvedDestinationPageIndices, !resolvedDestinationPageIndices.isEmpty {
                resolvedDestinationPageIndices
            } else {
                switch request.direction {
                case .forward:
                    [currentIndex + step]
                case .backward:
                    [max(0, currentIndex - step)]
                }
            }
        case .dragSource, .turnSource:
            [sourcePageIndices.first ?? currentIndex]
        }
        let destinationBaseIndex = fallbackDestinationPageIndices.first ?? currentIndex

        if request.pageLabelPolicy.displayMode == .multipleLabels,
           visibleUnit.usesMultiUnitSurface {
            let pageIndices: [Int]
            switch request.intent {
            case .dragDestination:
                pageIndices = resolvedDestinationPageIndices ?? fallbackDestinationPageIndices
            case .dragSource, .turnSource:
                pageIndices = sourcePageIndices
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
           let currentPhysicalPageLabel = ReaderResolvedPagination.currentPhysicalPageLabel(
                bridgeLabel: currentPhysicalPageLabel,
                paginationState: lastKnownState.paginationState
           ),
           request.intent != .dragDestination {
            return [currentPhysicalPageLabel]
        }
        if let currentPageDisplayLabel = ReaderResolvedPagination.currentPageDisplayLabel(
            bridgeLabel: currentPageDisplayLabel,
            paginationState: lastKnownState.paginationState
        ),
           request.intent != .dragDestination {
            return [currentPageDisplayLabel]
        }
        let pageIndices = switch request.intent {
        case .dragDestination:
            resolvedDestinationPageIndices ?? fallbackDestinationPageIndices
        case .dragSource, .turnSource:
            fallbackDestinationPageIndices
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
        updateReason = .userInteraction
        movementKind = nil
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
        let runtimeSpreadSequence = readerPageTurnSpreadSequence(dictionary["spreadSequence"])
        var probe = ReaderPageTurnNavigationProbe(
            pageNavigationStyle: pageNavigationStyle,
            transitionFamily: transitionFamily,
            layoutState: layoutState,
            updateReason: updateReason,
            navigationEvent: lastNavigationEvent?.kind,
            contentHostState: contentHostState,
            preloadStrategy: preloadStrategy,
            currentContentLocation: currentContentLocation,
            pageOffsetsDisplayed: pageOffsetsDisplayed,
            currentSpread: currentSpread,
            destinationSpread: destinationSpread,
            spreadSequence: runtimeSpreadSequence,
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
            layoutPrimarySpacing: nil,
            layoutChromeGutterWidth: nil,
            layoutReadableFrameWidth: layoutReadableFrameWidth,
            layoutMaxContentWidth: layoutMaxContentWidth,
            layoutSemanticSideInset: layoutSemanticSideInset,
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
            progressScrubberVisible: dictionary["progressScrubberVisible"] as? Bool ?? (dictionary["progressScrubberVisible"] as? NSNumber)?.boolValue,
            progressScrubberActive: dictionary["progressScrubberActive"] as? Bool ?? (dictionary["progressScrubberActive"] as? NSNumber)?.boolValue,
            historyCanGoBack: dictionary["historyCanGoBack"] as? Bool ?? (dictionary["historyCanGoBack"] as? NSNumber)?.boolValue,
            historyCanGoForward: dictionary["historyCanGoForward"] as? Bool ?? (dictionary["historyCanGoForward"] as? NSNumber)?.boolValue,
            historyDepth: dictionary["historyDepth"] as? Int ?? (dictionary["historyDepth"] as? NSNumber)?.intValue,
            historyCurrentIndex: dictionary["historyCurrentIndex"] as? Int ?? (dictionary["historyCurrentIndex"] as? NSNumber)?.intValue,
            historyPendingReplaceStateSuppressionCount: dictionary["historyPendingReplaceStateSuppressionCount"] as? Int ?? (dictionary["historyPendingReplaceStateSuppressionCount"] as? NSNumber)?.intValue,
            historySuppressedReplaceStateCount: dictionary["historySuppressedReplaceStateCount"] as? Int ?? (dictionary["historySuppressedReplaceStateCount"] as? NSNumber)?.intValue,
            historyLastSuppressedReplaceStateReason: dictionary["historyLastSuppressedReplaceStateReason"] as? String,
            showTitleChrome: nil,
            showHeaderChrome: nil,
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
            forwardDestinationAvailability: nil,
            backwardDestinationAvailability: nil,
            paginationComplete: paginationComplete,
            configurationKey: configurationKey,
            publicationSource: publicationSource,
            pageLabelDisplayMode: dictionary["pageLabelDisplayMode"] as? String,
            pageNumberMode: pageNumberMode,
            usesPhysicalPageLabels: dictionary["usesPhysicalPageLabels"] as? Bool ?? (dictionary["usesPhysicalPageLabels"] as? NSNumber)?.boolValue,
            allowsMultipleColumns: allowsMultipleColumns,
            allowsMultipleLabelsInMultiUnitLayout: dictionary["allowsMultipleLabelsInMultiUnitLayout"] as? Bool ?? (dictionary["allowsMultipleLabelsInMultiUnitLayout"] as? NSNumber)?.boolValue,
            visiblePageIndices: visiblePageIndices,
            pageScrollerAnimationIsRunning: pageScrollerAnimationIsRunning,
            liveResizeActive: liveResizeActive,
            probeError: dictionary["probeError"] as? String
        )
        probe.showTitleChrome = showTitleChrome
        probe.showHeaderChrome = showHeaderChrome
        probe.layoutPrimarySpacing = resolvedProbePrimarySpacing(probe)
        probe.layoutChromeGutterWidth = resolvedProbeChromeGutterWidth(probe)
        probe.forwardDestinationAvailability = probe.resolvedDestinationAvailability(for: .forward).rawValue
        probe.backwardDestinationAvailability = probe.resolvedDestinationAvailability(for: .backward).rawValue
        lastProbeError = probe.probeError
        if ProcessInfo.processInfo.environment["MANABI_PAGE_TURN_INTERACTION_DIAGNOSTIC"] == "1" {
            Logger.shared.logger.info("# PAGETURN navProbe.fetch \(probe.logPayload)")
        }
        return probe
    }

    func refreshNavigationState(preferredFrameOverride: WKFrameInfo? = nil) async -> ReaderPageTurnNavigationProbe? {
        let probe = await fetchNavigationProbe(preferredFrameOverride: preferredFrameOverride)
        applyNavigationProbe(probe, publicationSerial: publicationSerial)
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

    private func applyNavigationProbe(
        _ probe: ReaderPageTurnNavigationProbe?,
        publicationSerial: Int
    ) {
        guard self.publicationSerial == publicationSerial else { return }

        guard let probe else {
            probeConfirmedActivePageTurn = false
            return
        }

        let shouldPublishVisibleFields = shouldPublishVisibleProbeFields(probe)

        let localSupportsActivePageTurn = resolvedLocalActiveTurnSupport(
            navigator: navigator,
            webViewState: lastKnownState,
            paginationState: lastKnownState.paginationState
        )
        let probeResolvedGraph = resolvedGraph(for: probe)
        probeConfirmedActivePageTurn = probe.supportsActivePageTurn
        supportsActivePageTurn = probeConfirmedActivePageTurn || localSupportsActivePageTurn
        pageProgressionDirection = probe.pageProgressionDirection
        resolvedPaginationMode = probe.resolvedPaginationMode
        pageNavigationStyle = probe.pageNavigationStyle ?? pageNavigationStyle
        transitionFamily = probe.transitionFamily ?? transitionFamily
        updateReason = probe.updateReason ?? updateReason
        contentHostState = probe.contentHostState ?? contentHostState
        contentHostSequence = resolvedContentHostSequence(
            webViewState: lastKnownState,
            paginationState: lastKnownState.paginationState
        )
        let localForwardAvailability = probeResolvedGraph?.forwardDestinationAvailability ?? resolvedGraph.forwardDestinationAvailability
        let localBackwardAvailability = probeResolvedGraph?.backwardDestinationAvailability ?? resolvedGraph.backwardDestinationAvailability
        preloadStrategy = probe.preloadStrategy ?? preloadStrategy
        publishPaginationMetadata(
            currentContentLocation: probe.currentContentLocation
                ?? probeResolvedGraph?.currentContentLocation
                ?? resolvedGraph.currentContentLocation,
            paginationComplete: probe.paginationComplete ?? paginationComplete,
            configurationKey: probe.configurationKey ?? configurationKey,
            publicationSource: probe.publicationSource ?? publicationSource,
            pageNumberMode: probe.pageNumberMode ?? pageNumberMode,
            allowsMultipleColumns: probe.allowsMultipleColumns ?? allowsMultipleColumns
        )
        publishProbeDiagnosticsState(probe)
        let probeTurnDirection = probe.sameDocumentHostTurnDirection.flatMap(PageTurnDirection.init(rawValue:))
        publishCurrentPageLabelState(
            currentPageDisplayLabel: currentPageDisplayLabel,
            currentPhysicalPageLabel: currentPhysicalPageLabel,
            pageLabelDisplayMode: probe.pageLabelDisplayMode,
            usesPhysicalPageLabels: probe.usesPhysicalPageLabels,
            allowsMultipleLabelsInMultiUnitLayout: probe.allowsMultipleLabelsInMultiUnitLayout
        )

        if shouldPublishVisibleFields {
            publishVisibleProbeFields(
                probe,
                probeResolvedGraph: probeResolvedGraph,
                probeTurnDirection: probeTurnDirection,
                localForwardAvailability: localForwardAvailability,
                localBackwardAvailability: localBackwardAvailability,
                supportsActivePageTurn: supportsActivePageTurn
            )
        } else {
            layoutState = requestedLocationState == nil ? .changing : .aboutToChange
        }

        if shouldPublishVisibleFields {
            layoutState = supportsActivePageTurn ? .done : .changing
            contentHostState = supportsActivePageTurn ? .contentViewAvailable : contentHostState
        }
    }

    private func publishVisibleProbeFields(
        _ probe: ReaderPageTurnNavigationProbe,
        probeResolvedGraph: ReaderPageTurnResolvedGraph?,
        probeTurnDirection: PageTurnDirection?,
        localForwardAvailability: PageTurnDestinationAvailability,
        localBackwardAvailability: PageTurnDestinationAvailability,
        supportsActivePageTurn: Bool
    ) {
        let runtimeOwnedSpreadStateAvailable = lastKnownState.paginationState?.spreadSequence != nil
        let runtimeOwnedDestinationSpreadAvailable = lastKnownState.paginationState?.destinationSpread != nil
        let visibleState = ReaderResolvedProbeVisibleState.resolve(
            probePageOffsetsDisplayed: probe.pageOffsetsDisplayed,
            probeCurrentSpread: probe.currentSpread,
            probeDestinationSpread: probe.destinationSpread,
            probeCurrentPage: probe.currentPage,
            probePageCount: probe.pageCount,
            probeCurrentPageDisplayLabel: probe.currentPageDisplayLabel,
            probeCurrentPhysicalPageLabel: probe.currentPhysicalPageLabel,
            probeForwardDestinationAvailability: probe.forwardDestinationAvailability,
            probeBackwardDestinationAvailability: probe.backwardDestinationAvailability,
            probeVisiblePageIndices: probe.visiblePageIndices,
            probeCanSemanticForward: probe.canSemanticForward,
            probeCanSemanticBackward: probe.canSemanticBackward,
            probeResolvedGraph: probeResolvedGraph,
            currentResolvedGraph: resolvedGraph,
            probeTurnDirection: probeTurnDirection,
            paginationState: lastKnownState.paginationState,
            existingPageCount: pageCount,
            localForwardAvailability: localForwardAvailability,
            localBackwardAvailability: localBackwardAvailability,
            supportsActivePageTurn: supportsActivePageTurn
        )
        layoutState = probe.layoutState ?? .done
        if !runtimeOwnedSpreadStateAvailable {
            pageOffsetsDisplayed = visibleState.pageOffsetsDisplayed
            currentSpread = visibleState.currentSpread
            currentPage = visibleState.currentPage
            pageCount = visibleState.pageCount
            visiblePageIndices = visibleState.visiblePageIndices
            forwardDestinationAvailability = visibleState.forwardDestinationAvailability
            backwardDestinationAvailability = visibleState.backwardDestinationAvailability
            canForward = visibleState.canForward
            canBackward = visibleState.canBackward
        }
        if !runtimeOwnedDestinationSpreadAvailable {
            destinationSpread = visibleState.destinationSpread
        }
        if !runtimeOwnedSpreadStateAvailable {
            spreadSequence = spreadSequence ?? probe.spreadSequence
        }
        canNext = probe.canNext
        canPrev = probe.canPrev
        bookDirection = probe.bookDirection
        isRightToLeft = probe.isRightToLeft
        isVertical = probe.isVertical
        isVerticalRightToLeft = probe.isVerticalRightToLeft
        currentSectionIndex = probe.currentSectionIndex
        currentSectionHref = probe.currentSectionHref
        livePageIndex = probe.livePageIndex
        liveChunkPageIndex = probe.liveChunkPageIndex
        viewportCenterChunkPageIndex = probe.viewportCenterChunkPageIndex
        historyCanGoBack = probe.historyCanGoBack
        historyCanGoForward = probe.historyCanGoForward
        historyDepth = probe.historyDepth
        historyCurrentIndex = probe.historyCurrentIndex
        historyPendingReplaceStateSuppressionCount = probe.historyPendingReplaceStateSuppressionCount
        historySuppressedReplaceStateCount = probe.historySuppressedReplaceStateCount
        historyLastSuppressedReplaceStateReason = probe.historyLastSuppressedReplaceStateReason
        layoutPageRecordCount = probe.layoutPageRecordCount
        layoutLiveRootExists = probe.layoutLiveRootExists
        layoutLiveRootClassName = probe.layoutLiveRootClassName
        layoutLiveRootChildCount = probe.layoutLiveRootChildCount
        layoutLiveRootRectWidth = probe.layoutLiveRootRectWidth
        layoutLiveRootRectHeight = probe.layoutLiveRootRectHeight
        layoutLiveCurrentPageExists = probe.layoutLiveCurrentPageExists
        layoutLiveCurrentPageClassName = probe.layoutLiveCurrentPageClassName
        layoutLiveCurrentPageRectWidth = probe.layoutLiveCurrentPageRectWidth
        layoutLiveCurrentPageRectHeight = probe.layoutLiveCurrentPageRectHeight
        layoutLiveCurrentPageContainsChunkBody = probe.layoutLiveCurrentPageContainsChunkBody
        layoutLiveCurrentChunkExists = probe.layoutLiveCurrentChunkExists
        layoutLiveCurrentChunkTagName = probe.layoutLiveCurrentChunkTagName
        layoutLiveCurrentChunkClassName = probe.layoutLiveCurrentChunkClassName
        layoutLiveCurrentChunkDisplay = probe.layoutLiveCurrentChunkDisplay
        layoutLiveCurrentChunkPosition = probe.layoutLiveCurrentChunkPosition
        layoutLiveCurrentChunkFlex = probe.layoutLiveCurrentChunkFlex
        layoutLiveCurrentChunkRectWidth = probe.layoutLiveCurrentChunkRectWidth
        layoutLiveCurrentChunkRectHeight = probe.layoutLiveCurrentChunkRectHeight
        layoutLiveCurrentChunkInnerHTMLLength = probe.layoutLiveCurrentChunkInnerHTMLLength
        layoutLiveCurrentChunkContainsChunkBody = probe.layoutLiveCurrentChunkContainsChunkBody
        layoutLiveCurrentChunkChildCount = probe.layoutLiveCurrentChunkChildCount
        layoutLiveCurrentChunkTextLength = probe.layoutLiveCurrentChunkTextLength
        layoutCurrentChunkBodyChildCount = probe.layoutCurrentChunkBodyChildCount
        layoutCurrentChunkBodyTextLength = probe.layoutCurrentChunkBodyTextLength
        layoutCurrentChunkBodyDisplay = probe.layoutCurrentChunkBodyDisplay
        layoutCurrentChunkBodyPosition = probe.layoutCurrentChunkBodyPosition
        layoutCurrentChunkBodyFlex = probe.layoutCurrentChunkBodyFlex
        layoutColumnCount = probe.layoutColumnCount
        layoutCurrentPageIndex = probe.layoutCurrentPageIndex
        layoutCurrentPageChunkCount = probe.layoutCurrentPageChunkCount
        layoutMaxPageChunkCount = probe.layoutMaxPageChunkCount
        layoutUnitCount = probe.layoutUnitCount
        layoutActiveBuildPageIndex = probe.layoutActiveBuildPageIndex
        layoutComplete = probe.layoutComplete
        layoutSpreadCandidateDetected = probe.layoutSpreadCandidateDetected
        layoutVisibleUnitKind = probe.layoutVisibleUnitKind
        layoutVisibleUnitAxis = probe.layoutVisibleUnitAxis
        layoutVisiblePageCount = probe.layoutVisiblePageCount
        layoutCurrentUnitIndex = probe.layoutCurrentUnitIndex
        layoutLeadingPageIndex = probe.layoutLeadingPageIndex
        layoutTrailingPageIndex = probe.layoutTrailingPageIndex
        layoutHasLeadingSingleton = probe.layoutHasLeadingSingleton
        layoutHasTrailingSingleton = probe.layoutHasTrailingSingleton
        layoutPrimarySpacing = probe.layoutPrimarySpacing
        layoutChromeGutterWidth = probe.layoutChromeGutterWidth
        layoutReadableFrameWidth = probe.layoutReadableFrameWidth
        layoutMaxContentWidth = probe.layoutMaxContentWidth
        layoutSemanticSideInset = probe.layoutSemanticSideInset
        layoutMultiUnitActive = probe.layoutMultiUnitActive
        layoutSpreadPagesAllowedForViewport = probe.layoutSpreadPagesAllowedForViewport
        layoutWritingMode = probe.layoutWritingMode
        layoutViewportWidth = probe.layoutViewportWidth
        layoutViewportHeight = probe.layoutViewportHeight
        layoutMeasuredGap = probe.layoutMeasuredGap
        layoutMetricSize = probe.layoutMetricSize
        layoutColumnInlineSize = probe.layoutColumnInlineSize
        layoutCurrentChunkClientWidth = probe.layoutCurrentChunkClientWidth
        layoutCurrentChunkClientHeight = probe.layoutCurrentChunkClientHeight
        layoutCurrentChunkScrollWidth = probe.layoutCurrentChunkScrollWidth
        layoutCurrentChunkScrollHeight = probe.layoutCurrentChunkScrollHeight
        layoutCurrentChunkOverflow = probe.layoutCurrentChunkOverflow
        computedFontSizeCSS = probe.computedFontSizeCSS
        currentPageTextSample = probe.currentPageTextSample
        nextPageTextSample = probe.nextPageTextSample
        self.currentPageDisplayLabel = visibleState.currentPageDisplayLabel
        self.currentPhysicalPageLabel = visibleState.currentPhysicalPageLabel
        progressScrubberVisible = probe.progressScrubberVisible
        progressScrubberActive = probe.progressScrubberActive
        showTitleChrome = probe.showTitleChrome
        showHeaderChrome = probe.showHeaderChrome
        sameDocumentHostTurnPhase = probe.sameDocumentHostTurnPhase
        sameDocumentHostTurnDirection = probe.sameDocumentHostTurnDirection
        sameDocumentHostTurnCurrentPageIndex = probe.sameDocumentHostTurnCurrentPageIndex
        sameDocumentHostTurnTargetPageIndex = probe.sameDocumentHostTurnTargetPageIndex
        sameDocumentHostTurnPageCount = probe.sameDocumentHostTurnPageCount
        sameDocumentHostTurnDatasetCurrentPageIndex = probe.sameDocumentHostTurnDatasetCurrentPageIndex
        sameDocumentHostTurnResult = probe.sameDocumentHostTurnResult
        pageScrollerAnimationIsRunning = probe.pageScrollerAnimationIsRunning
        liveResizeActive = probe.liveResizeActive
    }

    private func shouldPublishVisibleProbeFields(_ probe: ReaderPageTurnNavigationProbe) -> Bool {
        guard let navigator, navigator.hasAttachedWebView else { return false }
        if probe.probeError != nil { return false }
        if !contentHostSequence.isStable { return false }
        switch probe.contentHostState {
        case .some(.initial), .some(.waitingOnContentView), .some(.preparingContentView), .some(.preparingForReuse):
            return false
        default:
            break
        }
        if let expectedConfigurationKey = lastKnownState.paginationState?.configurationKey,
           let probeConfigurationKey = probe.configurationKey,
           expectedConfigurationKey != probeConfigurationKey {
            return false
        }
        if requestedLocationState != nil && !probeShowsMeaningfulSettle(probe) {
            return false
        }
        return true
    }

    private func probeShowsMeaningfulSettle(_ probe: ReaderPageTurnNavigationProbe) -> Bool {
        ReaderPageTurnNavigationComparison.showsMeaningfulSettle(
            probe: ReaderPageTurnNavigationObservation(probe: probe),
            comparedTo: ReaderPageTurnNavigationObservation(
                currentSpread: currentSpread,
                destinationSpread: destinationSpread,
                pageOffsetsDisplayed: pageOffsetsDisplayed,
                pageCount: pageCount,
                layoutLeadingPageIndex: layoutLeadingPageIndex,
                currentPage: currentPage,
                layoutTrailingPageIndex: layoutTrailingPageIndex,
                layoutVisiblePageCount: layoutVisiblePageCount,
                currentSectionIndex: currentSectionIndex,
                currentSectionHref: currentSectionHref,
                supportsActivePageTurn: supportsActivePageTurn,
                canForward: canForward,
                canBackward: canBackward,
                layoutActiveBuildPageIndex: layoutActiveBuildPageIndex
            )
        )
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
                if probe.hasSettledCommittedTurn(direction: direction) {
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

    private func publishNavigationEvent(_ kind: ReaderPageTurnNavigationEventKind, direction: PageTurnDirection) {
        nextNavigationEventSerial += 1
        lastNavigationEvent = ReaderPageTurnNavigationEvent(
            serial: nextNavigationEventSerial,
            kind: kind,
            direction: direction
        )
    }

    func publishAttemptedPastEndForDiagnostics(direction: PageTurnDirection) {
        movementKind = nil
        publishNavigationEvent(.attemptedPastEnd, direction: direction)
    }

}

fileprivate extension ReaderPageTurnNavigationProbe {
    var supportsActivePageTurn: Bool {
        hasView
        && hasRenderer
        && (canNext || canPrev)
        && hasSectionLayoutController
    }

    private var spreadGraph: ReaderPageTurnSpreadGraph {
        ReaderPageTurnSpreadGraph(
            currentSpread: currentSpread,
            destinationSpread: destinationSpread,
            pageOffsetsDisplayed: pageOffsetsDisplayed,
            pageCount: pageCount,
            layoutLeadingPageIndex: layoutLeadingPageIndex,
            currentPage: currentPage,
            layoutTrailingPageIndex: layoutTrailingPageIndex,
            layoutVisiblePageCount: layoutVisiblePageCount
        )
    }

    private var movementGraph: ReaderPageTurnMovementGraph {
        spreadGraph.movementGraph
    }

    private var resolvedGraph: ReaderPageTurnResolvedGraph {
        spreadGraph.resolvedGraph
    }

    private func currentVisiblePageIndices() -> [Int]? {
        resolvedGraph.spreadSequence.current?.pageIndices ?? resolvedGraph.currentVisiblePageIndices
    }

    private func destinationPageIndices(for direction: PageTurnDirection) -> [Int]? {
        resolvedGraph.spreadSequence.node(for: direction)?.pageIndices ?? resolvedGraph.destinationPageIndices(for: direction)
    }

    func resolvedDestinationAvailability(for direction: PageTurnDirection) -> PageTurnDestinationAvailability {
        guard supportsActivePageTurn || (hasSectionLayoutController && (currentPageTextSample?.isEmpty == false)) else {
            return .unavailable
        }
        guard supportsActivePageTurn else {
            return .both
        }
        let isAvailable = switch direction {
        case .forward:
            canSemanticForward || canNext
        case .backward:
            canSemanticBackward || canPrev
        }
        guard isAvailable else {
            return .unavailable
        }
        guard resolvedGraph.usesSpreadAwareNavigationSemantics else {
            return .both
        }
        let availability = movementGraph.destinationAvailability(for: direction)
        return availability == .unavailable ? .both : availability
    }

    func hasLocationOrContentAdvance(comparedTo baseline: Self) -> Bool {
        hasMeaningfulNavigationChange(comparedTo: baseline)
    }

    func hasSettledCommittedTurn(direction: PageTurnDirection) -> Bool {
        ReaderPageTurnNavigationComparison.hasSettledCommittedTurn(
            probe: ReaderPageTurnNavigationObservation(probe: self),
            direction: direction
        )
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

struct ReaderPageTurnChromeGeometry {
    static func topInset(
        contentRect: CGRect,
        safeAreaInsets: PageTurnEdgeInsets
    ) -> CGFloat {
        max(safeAreaInsets.top, contentRect.minY)
    }

    static func horizontalInset(
        containerBounds: CGRect,
        contentRect: CGRect,
        safeAreaInsets: PageTurnEdgeInsets
    ) -> CGFloat {
        let contentInsets = max(contentRect.minX, 0)
            + max(containerBounds.width - contentRect.maxX, 0)
        let safeAreaTotal = max(safeAreaInsets.leading + safeAreaInsets.trailing, 0)
        return max(contentInsets, safeAreaTotal)
    }
}

struct ReaderPageTurnChromePolicy {
    static func titleVisibility(
        hideNavigationDueToScroll: Bool,
        hasTitleChromeContent: Bool
    ) -> Bool {
        !hideNavigationDueToScroll && hasTitleChromeContent
    }

    static func headerVisibility(
        hideNavigationDueToScroll: Bool,
        hasHeaderChromeContent: Bool
    ) -> Bool {
        !hideNavigationDueToScroll && hasHeaderChromeContent
    }

    static func pageNumberHUDVisibility(
        displayLabel: String?,
        currentPage: Int?,
        totalPages: Int?,
        hideNavigationDueToScroll: Bool
    ) -> Bool {
        guard !hideNavigationDueToScroll else { return false }
        if let displayLabel, !displayLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if currentPage != nil {
            return true
        }
        if let totalPages, totalPages > 1 {
            return true
        }
        return false
    }

    static func scrubberVisibility(
        override: Bool?,
        pageRange: ClosedRange<Int>?,
        totalPages: Int?,
        hideNavigationDueToScroll: Bool
    ) -> Bool {
        if let override {
            return override
        }
        guard !hideNavigationDueToScroll else { return false }
        guard let pageRange else { return false }
        let validatedPageCount = max(totalPages ?? 0, pageRange.upperBound)
        return validatedPageCount > 1
    }

    static func suppressesStandalonePageNumberHUD(
        scrubberVisible: Bool,
        scrubberFollowsThumb: Bool
    ) -> Bool {
        scrubberVisible && scrubberFollowsThumb
    }
}

struct ReaderPageTurnSnapshotChrome {
    static func resolve(
        headerLabels: [String],
        titlePrimary: String?,
        titleSecondary: String?,
        pageLabelDisplayMode: PageTurnPageLabelDisplayMode,
        displayLabel: String?,
        currentPageNumber: Int?,
        trailingPageNumber: Int?,
        totalPages: Int?,
        validatedPageCount: Int?,
        pageRange: ClosedRange<Int>?,
        progressScrubberVisible: Bool?,
        progressScrubberActive: Bool?,
        hideNavigationDueToScroll: Bool,
        chromeTopInset: CGFloat,
        horizontalInset: CGFloat,
        hudWidth: CGFloat
    ) -> PageTurnSnapshotChromeContent {
        let usesExplicitScrubberVisibilityOverride = progressScrubberVisible == true
        let scrubberIsVisible = ReaderPageTurnChromePolicy.scrubberVisibility(
            override: progressScrubberVisible,
            pageRange: pageRange,
            totalPages: totalPages,
            hideNavigationDueToScroll: hideNavigationDueToScroll
        )
        let scrubberFollowsThumb = progressScrubberActive ?? false
        let suppressesStandalonePageNumberHUD = ReaderPageTurnChromePolicy.suppressesStandalonePageNumberHUD(
            scrubberVisible: usesExplicitScrubberVisibilityOverride && scrubberIsVisible,
            scrubberFollowsThumb: scrubberFollowsThumb
        )
        let leadingLabel = currentPageNumber.map { "Page \($0)" }
        let trailingLabel: String?
        if let trailingPageNumber, trailingPageNumber != currentPageNumber {
            trailingLabel = "Page \(trailingPageNumber)"
        } else {
            trailingLabel = nil
        }
        return PageTurnSnapshotChromeContent(
            headerLabels: headerLabels,
            titlePrimary: (titlePrimary?.isEmpty == false) ? titlePrimary : nil,
            titleSecondary: (titleSecondary?.isEmpty == false) ? titleSecondary : nil,
            pageNumberHUD: .init(
                isVisible: !suppressesStandalonePageNumberHUD && ReaderPageTurnChromePolicy.pageNumberHUDVisibility(
                    displayLabel: displayLabel,
                    currentPage: currentPageNumber,
                    totalPages: totalPages,
                    hideNavigationDueToScroll: hideNavigationDueToScroll
                ),
                displayLabel: displayLabel,
                leadingLabel: pageLabelDisplayMode == .multipleLabels ? leadingLabel : nil,
                trailingLabel: pageLabelDisplayMode == .multipleLabels ? trailingLabel : nil,
                currentPage: currentPageNumber,
                totalPages: totalPages,
                validatedPageCount: validatedPageCount,
                topInset: chromeTopInset,
                width: hudWidth
            ),
            scrubberState: .init(
                isVisible: scrubberIsVisible,
                leadingPageNumber: currentPageNumber,
                trailingPageNumber: trailingPageNumber,
                pageRange: pageRange,
                calloutWidth: hudWidth,
                leftRightInset: horizontalInset,
                verticalInset: chromeTopInset,
                followsThumb: scrubberFollowsThumb
            )
        )
    }
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
fileprivate func readerPageTurnForceReducedMotionForUITests() -> Bool {
    ProcessInfo.processInfo.arguments.contains("--ui-test-force-reduced-motion")
}

@MainActor
fileprivate func readerResolvedPageTurnTransitionFamily(
    navigationStyle: PageTurnNavigationStyle = .paged,
    transitionFamily: PageTurnTransitionFamily = .slide
) -> PageTurnTransitionFamily {
    let reducedMotionRequested = readerPageTurnForceReducedMotionForUITests()
    return readerPageTurnStyle(
        navigationStyle: navigationStyle,
        transitionFamily: transitionFamily
    ).resolvedTransitionFamily(reducedMotionRequested: reducedMotionRequested)
}

@MainActor
fileprivate func readerPageTurnStyle(
    navigationStyle: PageTurnNavigationStyle = .paged,
    transitionFamily: PageTurnTransitionFamily = .slide
) -> PageTurnStyle {
    let style: PageTurnStyle = switch readerPageTurnPlatformFamily() {
    case .macOS:
        .macOSDefault()
    case .iPhone:
        .iPhoneDefault(
            displayCornerRadiusProvider: { rect in
                min(rect.width, rect.height) * 0.08
            }
        )
    case .iPad:
        .iPadDefault(
            displayCornerRadiusProvider: { rect in
                min(rect.width, rect.height) * 0.05
            }
        )
    }

    var resolvedStyle = style
    resolvedStyle.navigationStyle = navigationStyle
    resolvedStyle.transitionFamily = transitionFamily
    resolvedStyle.transitionFamily = resolvedStyle.resolvedTransitionFamily(
        reducedMotionRequested: readerPageTurnForceReducedMotionForUITests()
    )

    return resolvedStyle
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
    @AppStorage("readerAllowMultipleColumns") private var readerAllowMultipleColumns = true
#if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
#endif

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
            style: readerPageTurnStyle(
                navigationStyle: bridge.pageNavigationStyle,
                transitionFamily: bridge.transitionFamily
            )
        )
        .environment(\.readerResolvedPaginationMode, bridge.resolvedPaginationMode)
        .task(id: bridgeRefreshKey) {
            bridge.updateContext(
                navigator: navigator,
                scriptCaller: scriptCaller,
                webViewState: readerViewModel.state,
                isEligibleForActiveTurns: isStructurallyEligibleForActiveTurns
            )
            syncControllerFromBridge()
        }
        .task(id: layoutSemanticsKey) {
            refreshLayoutSemantics()
        }
        .task(id: bridge.pageProgressionDirection) {
            controller.setPageProgressionDirection(bridge.pageProgressionDirection)
        }
        .task(id: bridge.pageNavigationStyle) {
            controller.setNavigationStyle(bridge.pageNavigationStyle)
        }
        .task(id: bridge.transitionFamily) {
            controller.setTransitionFamily(bridge.transitionFamily)
        }
        .task(id: bridge.movementKind) {
            controller.setMovementKind(bridge.movementKind)
        }
        .task(id: bridge.layoutState) {
            controller.setLayoutState(bridge.layoutState)
        }
        .task(id: resolvedCurrentSpreadTaskID()) {
            controller.setCurrentSpread(resolvedControllerCurrentSpread()?.pageTurnSpread)
        }
        .task(id: resolvedDestinationSpreadTaskID()) {
            controller.setDestinationSpread(resolvedControllerDestinationSpread()?.pageTurnSpread)
        }
        .task(id: bridge.contentHostState) {
            controller.setContentHostState(bridge.contentHostState.pageTurnContentHostState)
        }
        .task(id: bridge.contentHostSequenceTaskID) {
            controller.setContentHostSequence(bridge.contentHostSequence)
        }
        .task(id: bridge.preloadTaskID) {
            controller.setPreloadState(resolvedPreloadState())
        }
        .task(id: bridge.lastNavigationEvent?.serial) {
            controller.setNavigationEventKind(bridge.lastNavigationEvent?.kind.pageTurnNavigationEventKind)
        }
        .task(id: interactionContext) {
            controller.setInteractionPolicy(resolvedInteractionPolicy())
        }
        .task(id: readerViewModel.pageTurnBootstrapSerial) {
            guard readerViewModel.pageTurnBootstrapSerial > 0 else { return }
            _ = await bridge.refreshNavigationState()
            syncControllerFromBridge()
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
                syncControllerFromBridge()
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
            && !bridge.probeConfirmedActivePageTurn
    }

    private var bridgeBootstrapPollingKey: String {
        [
            requestedEnabled ? "requested" : "passThrough",
            isStructurallyEligibleForActiveTurns ? "eligible" : "ineligible",
            bridge.probeConfirmedActivePageTurn ? "probeReady" : "probePending",
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
            bridge.probeConfirmedActivePageTurn ? "probeReady" : "probeBlocked",
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
            bridge.probeConfirmedActivePageTurn ? "probeReady" : "probeBlocked",
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
            bridge.probeConfirmedActivePageTurn ? "probeReady" : "probeBlocked",
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
        let chromeGutterWidth = String(describing: resolvedChromeGutterWidth())
        let measuredGap = bridge.layoutMeasuredGap.map { String($0) } ?? "nil"
        let multiUnitActive = bridge.layoutMultiUnitActive.map(String.init) ?? "nil"
        let spreadPagesAllowed = bridge.layoutSpreadPagesAllowedForViewport.map(String.init) ?? "nil"
        let columnCount = bridge.layoutColumnCount.map(String.init) ?? "nil"
        let columnInlineSize = bridge.layoutColumnInlineSize.map(String.init) ?? "nil"
        let viewportWidth = bridge.layoutViewportWidth.map(String.init) ?? "nil"
        let viewportHeight = bridge.layoutViewportHeight.map(String.init) ?? "nil"
        let chromeVisibility = resolvedChromeVisibility()
        let chromeTitleVisible = chromeVisibility.showTitle ? "titleVisible" : "titleHidden"
        let chromeHeaderVisible = chromeVisibility.showHeader ? "headerVisible" : "headerHidden"
        let axisOrientation = bridge.isVertical ? "vertical" : "horizontal"
        let writingMode = bridge.layoutWritingMode ?? "nil"
        let appearance = colorScheme == .dark ? "dark" : "light"
        let navigationStyle = bridge.pageNavigationStyle.rawValue
        let transitionFamily = bridge.transitionFamily.rawValue
        let currentSpreadKey = resolvedCurrentSpreadTaskID()
        let currentPageDisplayLabel = resolvedCurrentPageDisplayLabel() ?? "nil"
        let currentPhysicalPageLabel = resolvedCurrentPhysicalPageLabel() ?? "nil"
        let allowsMultipleColumns = readerAllowMultipleColumns ? "multiColumnOn" : "multiColumnOff"
        let pageScrollerAnimation = (bridge.pageScrollerAnimationIsRunning ?? false) ? "pageScrollerAnimating" : "pageScrollerIdle"
        let liveResizeState = (bridge.liveResizeActive ?? false) ? "liveResizeActive" : "liveResizeInactive"
        let requestedLocationState = effectiveRequestedLocationState(
            readerViewModel.pageTurnRequestedLocationState,
            currentSpread: resolvedControllerCurrentSpread()
        )
        let requestedLocationKey = [
            requestedLocationState?.source.rawValue ?? "nil",
            requestedLocationState?.kind ?? "nil",
            requestedLocationState?.value ?? "nil",
            requestedLocationState?.surroundingContext ?? "nil",
        ].joined(separator: ":")
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
            chromeGutterWidth,
            measuredGap,
            multiUnitActive,
            spreadPagesAllowed,
            columnCount,
            columnInlineSize,
            viewportWidth,
            viewportHeight,
            chromeTitleVisible,
            chromeHeaderVisible,
            axisOrientation,
            writingMode,
            appearance,
            navigationStyle,
            transitionFamily,
            currentSpreadKey,
            currentPageDisplayLabel,
            currentPhysicalPageLabel,
            allowsMultipleColumns,
            pageScrollerAnimation,
            liveResizeState,
            requestedLocationKey,
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
        let paginationState = readerViewModel.state.paginationState
        let visibleUnit = resolvedVisibleUnit()
        let interactionDirection = controller.lastInteractionEvent?.direction
        let currentContext = resolvedPaginationContext(paginationState: paginationState)
        let pageLabelPolicy = resolvedPageLabelPolicy(visibleUnit: visibleUnit)
        bridge.updateResolvedPageLabelPolicy(pageLabelPolicy)
        let platformFamily = readerPageTurnPlatformFamily()
        let chromeVisibility = resolvedChromeVisibility(platformFamily: platformFamily)
        bridge.updateResolvedChromeVisibility(chromeVisibility)
        let allowsMultipleColumns = readerAllowMultipleColumns
        let pageNumberMode: WebViewPaginationPageNumberMode = pageLabelPolicy.usesPhysicalPageLabels ? .printEdition : .digitalBook
        let currentSpread = currentContext.currentSpread ?? resolvedWebViewCurrentSpread(from: visibleUnit)
        let resolvedPageCount = currentContext.pageCount
        let spreadGraph = ReaderPageTurnSpreadGraph(
            currentSpread: currentSpread,
            destinationSpread: nil,
            pageOffsetsDisplayed: currentContext.pageOffsetsDisplayed ?? currentSpread?.pageIndices,
            pageCount: resolvedPageCount,
            layoutLeadingPageIndex: visibleUnit.leadingPageIndex,
            currentPage: currentContext.currentPageIndex,
            layoutTrailingPageIndex: visibleUnit.trailingPageIndex,
            layoutVisiblePageCount: visibleUnit.visiblePageCount
        )
        let resolvedGraph = spreadGraph.resolvedGraph
        let resolvedCurrentSpread = currentContext.currentSpread
        let resolvedDestinationSpread = currentContext.destinationSpread(direction: interactionDirection)
        let pageOffsetsDisplayed = currentContext.pageOffsetsDisplayed
        let currentPageIndex = currentContext.currentPageIndex
        let visiblePageIndices = currentContext.visiblePageIndices
        let canMoveForward = currentContext.canMoveForward
        let canMoveBackward = currentContext.canMoveBackward
        let forwardDestinationAvailability = currentContext.destinationAvailability(for: PageTurnDirection.forward)
        let backwardDestinationAvailability = currentContext.destinationAvailability(for: PageTurnDirection.backward)
        let context = ReaderResolvedPaginationContext(
            paginationState: paginationState,
            bridgeSpreadSequence: bridge.spreadSequence,
            bridgeCurrentSpread: nil,
            bridgeDestinationSpread: nil,
            bridgePageOffsetsDisplayed: nil,
            bridgeVisiblePageIndices: bridge.visiblePageIndices,
            bridgePageCount: bridge.pageCount,
            bridgeCurrentPage: bridge.currentPage,
            bridgeCanMoveForward: bridge.canForward,
            bridgeCanMoveBackward: bridge.canBackward,
            bridgeCurrentContentLocation: bridge.currentContentLocation,
            bridgeForwardDestinationAvailability: bridge.forwardDestinationAvailability,
            bridgeBackwardDestinationAvailability: bridge.backwardDestinationAvailability,
            bridgePaginationComplete: bridge.paginationComplete,
            bridgeConfigurationKey: bridge.configurationKey,
            bridgePublicationSource: bridge.publicationSource,
            bridgePageNumberMode: bridge.pageNumberMode,
            bridgeAllowsMultipleColumns: bridge.allowsMultipleColumns,
            paginationCurrentPageIndex: paginationState?.currentPageIndex,
            paginationVisiblePageIndices: paginationState?.visiblePageIndices,
            paginationCanMoveForward: paginationState?.canMoveForward,
            paginationCanMoveBackward: paginationState?.canMoveBackward,
            paginationCurrentContentLocation: paginationState?.currentContentLocation,
            paginationSpreadSequence: paginationState?.spreadSequence,
            paginationForwardDestinationAvailability: paginationState?.forwardDestinationAvailability,
            paginationBackwardDestinationAvailability: paginationState?.backwardDestinationAvailability,
            paginationComplete: paginationState?.paginationComplete,
            paginationConfigurationKey: paginationState?.configurationKey,
            paginationPublicationSource: paginationState?.publicationSource,
            paginationPageNumberMode: paginationState?.pageNumberMode,
            paginationAllowsMultipleColumns: paginationState?.allowsMultipleColumns,
            layoutLeadingPageIndex: visibleUnit.leadingPageIndex,
            layoutTrailingPageIndex: visibleUnit.trailingPageIndex,
            layoutVisiblePageCount: visibleUnit.visiblePageCount
        )
        let pageOffsetRange = resolvedGraph.pageOffsetRange
        let runtimeOwnedSpreadStateAvailable = paginationState?.spreadSequence != nil
        let runtimeOwnedDestinationSpreadAvailable = paginationState?.destinationSpread != nil
        let requestedLocation = effectiveRequestedLocationState(
            readerViewModel.pageTurnRequestedLocationState,
            currentSpread: resolvedCurrentSpread
        )
        let style = readerPageTurnStyle(
            navigationStyle: bridge.pageNavigationStyle,
            transitionFamily: bridge.transitionFamily
        )
        bridge.updateResolvedPageTurnPresentation(
            navigationStyle: style.navigationStyle,
            transitionFamily: style.transitionFamily,
            layoutState: bridge.supportsActivePageTurn ? .done : .changing,
            updateReason: requestedLocation == nil ? .configurationChange : .locationFulfillment,
            pageNumberMode: pageNumberMode,
            allowsMultipleColumns: allowsMultipleColumns
        )
        bridge.updateRequestedLocationState(requestedLocation)
        navigator.paginationStateEnrichment = ReaderResolvedPaginationEnrichment.resolve(
            runtimeOwnedSpreadStateAvailable: runtimeOwnedSpreadStateAvailable,
            runtimeOwnedDestinationSpreadAvailable: runtimeOwnedDestinationSpreadAvailable,
            visibleUnit: resolvedWebViewVisibleUnit(from: visibleUnit),
            pageLabelPolicy: resolvedWebViewPageLabelPolicy(from: pageLabelPolicy),
            currentPageDisplayLabel: resolvedCurrentPageDisplayLabel(),
            currentPhysicalPageLabel: resolvedCurrentPhysicalPageLabel(),
            pageNavigationStyle: style.navigationStyle.webViewPaginationNavigationStyle,
            allowsMultipleColumns: allowsMultipleColumns,
            pageNumberMode: pageNumberMode,
            contentHostState: bridge.contentHostState.webViewPaginationContentHostState,
            preloadStrategy: bridge.preloadStrategy.webViewPaginationPreloadStrategy,
            currentContentLocation: context.currentContentLocation.webViewPaginationCurrentContentLocation,
            requestedLocation: requestedLocation?.webViewPaginationRequestedLocation,
            pageOffsetsDisplayed: pageOffsetsDisplayed,
            pageOffsetRange: pageOffsetRange,
            currentPageIndex: currentPageIndex,
            visiblePageIndices: visiblePageIndices,
            canMoveForward: canMoveForward,
            canMoveBackward: canMoveBackward,
            forwardDestinationAvailability: forwardDestinationAvailability?.rawValue,
            backwardDestinationAvailability: backwardDestinationAvailability?.rawValue,
            currentSpread: resolvedCurrentSpread,
            destinationSpread: resolvedDestinationSpread
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
        let readableFrame = PageTurnReadableFrame(
            semanticSideInset: max(0, layoutModel.inputs.contentRect.minX - layoutModel.inputs.containerBounds.minX),
            pageContentWidthWithinMargins: layoutModel.inputs.contentRect.width,
            maxContentWidth: max(0, layoutModel.inputs.containerBounds.width - layoutModel.inputs.safeAreaInsets.leading - layoutModel.inputs.safeAreaInsets.trailing)
        )
        controller.setReadableFrame(readableFrame)
        controller.setRequestedLocation(requestedLocation?.pageTurnRequestedLocation)
        controller.setCurrentSpread(resolvedCurrentSpread?.pageTurnSpread)
        controller.setDestinationSpread(resolvedDestinationSpread?.pageTurnSpread)
        controller.setPreloadState(resolvedPreloadState())
        controller.setPageNumberHUD(
            resolvedPageNumberHUDState(
                visibleUnit: visibleUnit,
                pageLabelPolicy: pageLabelPolicy,
                resolvedGraph: resolvedGraph
            )
        )
        controller.setScrubberState(
            resolvedScrubberState(
                resolvedGraph: resolvedGraph
            )
        )
        controller.setInteractionPolicy(resolvedInteractionPolicy())
        controller.setHostEnvironment(
            .init(
                contentRect: layoutModel.inputs.contentRect,
                hostInsets: style.contentInsets,
                contentInsets: style.contentInsets,
                safeAreaInsets: layoutModel.inputs.safeAreaInsets,
                closeBookInteracting: false,
                scenePhase: resolvedScenePhase,
                horizontalSizeClass: resolvedHorizontalSizeClass,
                verticalSizeClass: resolvedVerticalSizeClass,
                compactNavigationSheetPresented: false
            )
        )
        controller.setVisiblePagesState(
            resolvedVisiblePagesState(
                visibleUnit: visibleUnit,
                context: context
            )
        )
    }

    private func syncControllerFromBridge() {
        let context = resolvedPaginationContext()
        let resolvedCurrentSpread = resolvedControllerCurrentSpread(context: context)
        let resolvedDestinationSpread = resolvedControllerDestinationSpread(context: context)
        controller.setPageProgressionDirection(bridge.pageProgressionDirection)
        controller.setNavigationStyle(bridge.pageNavigationStyle)
        controller.setTransitionFamily(bridge.transitionFamily)
        controller.setMovementKind(bridge.movementKind)
        controller.setLayoutState(bridge.layoutState)
        controller.setCurrentSpread(resolvedCurrentSpread?.pageTurnSpread)
        controller.setDestinationSpread(resolvedDestinationSpread?.pageTurnSpread)
        controller.setContentHostState(bridge.contentHostState.pageTurnContentHostState)
        controller.setContentHostSequence(bridge.contentHostSequence)
        controller.setPreloadState(resolvedPreloadState())
        controller.setNavigationEventKind(bridge.lastNavigationEvent?.kind.pageTurnNavigationEventKind)
        controller.setInteractionPolicy(resolvedInteractionPolicy())
    }

    private func resolvedPaginationContext(
        paginationState: WebViewPaginationState? = nil
    ) -> ReaderResolvedPaginationContext {
        ReaderResolvedPaginationContext(
            paginationState: paginationState ?? readerViewModel.state.paginationState,
            bridgeSpreadSequence: bridge.spreadSequence,
            bridgeCurrentSpread: bridge.currentSpread,
            bridgeDestinationSpread: bridge.destinationSpread,
            bridgePageOffsetsDisplayed: bridge.pageOffsetsDisplayed,
            bridgeVisiblePageIndices: bridge.visiblePageIndices,
            bridgePageCount: bridge.pageCount,
            bridgeCurrentPage: bridge.currentPage,
            bridgeCanMoveForward: bridge.canForward,
            bridgeCanMoveBackward: bridge.canBackward,
            bridgeCurrentContentLocation: bridge.currentContentLocation,
            bridgeForwardDestinationAvailability: bridge.forwardDestinationAvailability,
            bridgeBackwardDestinationAvailability: bridge.backwardDestinationAvailability,
            bridgePaginationComplete: bridge.paginationComplete,
            bridgeConfigurationKey: bridge.configurationKey,
            bridgePublicationSource: bridge.publicationSource,
            bridgePageNumberMode: bridge.pageNumberMode,
            bridgeAllowsMultipleColumns: bridge.allowsMultipleColumns,
            paginationCurrentPageIndex: (paginationState ?? readerViewModel.state.paginationState)?.currentPageIndex,
            paginationVisiblePageIndices: (paginationState ?? readerViewModel.state.paginationState)?.visiblePageIndices,
            paginationCanMoveForward: (paginationState ?? readerViewModel.state.paginationState)?.canMoveForward,
            paginationCanMoveBackward: (paginationState ?? readerViewModel.state.paginationState)?.canMoveBackward,
            paginationCurrentContentLocation: (paginationState ?? readerViewModel.state.paginationState)?.currentContentLocation,
            paginationSpreadSequence: (paginationState ?? readerViewModel.state.paginationState)?.spreadSequence,
            paginationForwardDestinationAvailability: (paginationState ?? readerViewModel.state.paginationState)?.forwardDestinationAvailability,
            paginationBackwardDestinationAvailability: (paginationState ?? readerViewModel.state.paginationState)?.backwardDestinationAvailability,
            paginationComplete: (paginationState ?? readerViewModel.state.paginationState)?.paginationComplete,
            paginationConfigurationKey: (paginationState ?? readerViewModel.state.paginationState)?.configurationKey,
            paginationPublicationSource: (paginationState ?? readerViewModel.state.paginationState)?.publicationSource,
            paginationPageNumberMode: (paginationState ?? readerViewModel.state.paginationState)?.pageNumberMode,
            paginationAllowsMultipleColumns: (paginationState ?? readerViewModel.state.paginationState)?.allowsMultipleColumns,
            layoutLeadingPageIndex: bridge.layoutLeadingPageIndex,
            layoutTrailingPageIndex: bridge.layoutTrailingPageIndex,
            layoutVisiblePageCount: bridge.layoutVisiblePageCount
        )
    }

    private func resolvedBridgeGraph() -> ReaderPageTurnResolvedGraph {
        resolvedPaginationContext().resolvedGraph
    }

    private func resolvedControllerCurrentSpread(
        context: ReaderResolvedPaginationContext? = nil
    ) -> WebViewPaginationSpread? {
        (context ?? resolvedPaginationContext()).currentSpread
    }

    private func resolvedControllerDestinationSpread(
        context: ReaderResolvedPaginationContext? = nil
    ) -> WebViewPaginationSpread? {
        (context ?? resolvedPaginationContext()).destinationSpread(direction: controller.lastInteractionEvent?.direction)
    }

    private func resolvedCurrentSpreadTaskID() -> String {
        let context = resolvedPaginationContext()
        return spreadTaskID(for: resolvedControllerCurrentSpread(context: context))
    }

    private func resolvedDestinationSpreadTaskID() -> String {
        let context = resolvedPaginationContext()
        return spreadTaskID(for: resolvedControllerDestinationSpread(context: context))
    }

    private func spreadTaskID(for spread: WebViewPaginationSpread?) -> String {
        spread?.slots
            .map { "\($0.kind.rawValue):\($0.pageIndex.map(String.init) ?? "nil")" }
            .joined(separator: ",")
            ?? "nil"
    }

    private func resolvedPreloadState() -> PageTurnPreloadState {
        let context = resolvedPaginationContext()
        return .init(
            strategy: bridge.preloadStrategy,
            currentContentLocation: context.currentContentLocation,
            visibleContentCount: context.visiblePageIndices?.count ?? context.resolvedGraph.visiblePageCount,
            totalControllerCount: context.pageCount
        )
    }

    private func resolvedVisiblePagesState(
        visibleUnit: PageTurnVisibleUnit,
        context: ReaderResolvedPaginationContext
    ) -> PageTurnVisiblePagesState {
        let pageIndices = context.visiblePageIndices ?? context.resolvedGraph.currentVisiblePageIndices
        let currentPageIndex = context.currentPageIndex ?? visibleUnit.leadingPageIndex
        return .init(
            visiblePageIndices: pageIndices ?? [],
            currentPageIndex: currentPageIndex,
            pageScrollerAnimationIsRunning: bridge.pageScrollerAnimationIsRunning ?? false,
            liveResizeActive: bridge.liveResizeActive ?? false
        )
    }

    private func resolvedInteractionPolicy() -> PageTurnInteractionPolicy {
        .init(
            ignorePageTurns: interactionContext.ignorePageTurns,
            lineGuideEnabled: interactionContext.lineGuideEnabled,
            requiresEdgeTouch: interactionContext.requiresEdgeTouch,
            centerTapAreaLength: interactionContext.centerTapAreaLength.map { CGFloat($0) },
            allowsBothMarginsAdvancePage: interactionContext.allowsBothMarginsAdvancePage
        )
    }

    private func resolvedPageNumberHUDState(
        visibleUnit: PageTurnVisibleUnit,
        pageLabelPolicy: PageTurnPageLabelPolicy,
        resolvedGraph: ReaderPageTurnResolvedGraph
    ) -> PageTurnPageNumberHUDState {
        let paginationContext = resolvedPaginationContext()
        let pageIndices = resolvedGraph.currentVisiblePageIndices
            ?? [visibleUnit.leadingPageIndex ?? paginationContext.currentPageIndex].compactMap { $0 }
        let leadingPage = pageIndices.first.map { $0 + 1 }
        let trailingPage = pageIndices.last.map { $0 + 1 }
        let totalPages = paginationContext.pageCount
        let displayLabel: String?
        if let leadingPage, let trailingPage, trailingPage > leadingPage {
            if let totalPages {
                displayLabel = "\(leadingPage)-\(trailingPage) of \(totalPages)"
            } else {
                displayLabel = "\(leadingPage)-\(trailingPage)"
            }
        } else if let currentPageDisplayLabel = resolvedCurrentPageDisplayLabel(), !currentPageDisplayLabel.isEmpty {
            displayLabel = currentPageDisplayLabel
        } else if let leadingPage {
            if let totalPages {
                displayLabel = "Page \(leadingPage) of \(totalPages)"
            } else {
                displayLabel = "Page \(leadingPage)"
            }
        } else {
            displayLabel = nil
        }

        let leadingLabel = leadingPage.map { "Page \($0)" }
        let trailingLabel: String?
        if let trailingPage, trailingPage != leadingPage {
            trailingLabel = "Page \(trailingPage)"
        } else {
            trailingLabel = nil
        }

        let validatedPageCount = [
            totalPages,
            resolvedGraph.pageOffsetRange.map { $0.upperBound + 1 },
            pageIndices.max().map { $0 + 1 }
        ].compactMap { $0 }.max()
        let chromeTopInset = ReaderPageTurnChromeGeometry.topInset(
            contentRect: layoutModel.inputs.contentRect,
            safeAreaInsets: layoutModel.inputs.safeAreaInsets
        )
        let isVisible = ReaderPageTurnChromePolicy.pageNumberHUDVisibility(
            displayLabel: displayLabel,
            currentPage: leadingPage,
            totalPages: totalPages,
            hideNavigationDueToScroll: hideNavigationDueToScroll
        )

        return .init(
            isVisible: isVisible,
            displayLabel: displayLabel,
            leadingLabel: pageLabelPolicy.displayMode == .multipleLabels ? leadingLabel : nil,
            trailingLabel: pageLabelPolicy.displayMode == .multipleLabels ? trailingLabel : nil,
            currentPage: leadingPage,
            totalPages: totalPages,
            validatedPageCount: validatedPageCount,
            topInset: chromeTopInset,
            width: resolvedPageNumberHUDWidth(for: visibleUnit)
        )
    }

    private func resolvedScrubberState(
        resolvedGraph: ReaderPageTurnResolvedGraph
    ) -> PageTurnScrubberState {
        let pageIndices = resolvedGraph.currentVisiblePageIndices
        let pageOffsetRange = resolvedGraph.pageOffsetRange
        let resolvedPageIndices = pageIndices ?? []
        let pageRange = pageOffsetRange.map { ($0.lowerBound + 1)...($0.upperBound + 1) }
        let chromeTopInset = ReaderPageTurnChromeGeometry.topInset(
            contentRect: layoutModel.inputs.contentRect,
            safeAreaInsets: layoutModel.inputs.safeAreaInsets
        )
        let horizontalInset = ReaderPageTurnChromeGeometry.horizontalInset(
            containerBounds: layoutModel.inputs.containerBounds,
            contentRect: layoutModel.inputs.contentRect,
            safeAreaInsets: layoutModel.inputs.safeAreaInsets
        )
        let paginationContext = resolvedPaginationContext()
        return .init(
            isVisible: ReaderPageTurnChromePolicy.scrubberVisibility(
                override: bridge.progressScrubberVisible,
                pageRange: pageRange,
                totalPages: paginationContext.pageCount,
                hideNavigationDueToScroll: hideNavigationDueToScroll
            ),
            leadingPageNumber: resolvedPageIndices.first.map { $0 + 1 },
            trailingPageNumber: resolvedPageIndices.last.map { $0 + 1 },
            pageRange: pageRange,
            calloutWidth: resolvedPageNumberHUDWidth(for: resolvedVisibleUnit()),
            leftRightInset: horizontalInset,
            verticalInset: chromeTopInset,
            followsThumb: bridge.progressScrubberActive ?? false
        )
    }

    private func resolvedChromeVisibility(platformFamily: PageTurnPlatformFamily? = nil) -> PageTurnChromeVisibility {
        _ = platformFamily ?? readerPageTurnPlatformFamily()
        let titlePrimary = readerViewModel.state.pageTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasTitleChromeContent = (titlePrimary?.isEmpty == false)
            || !(bridge.currentSectionHref?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasHeaderChromeContent = !(resolvedCurrentPageDisplayLabel()?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            || !(resolvedCurrentPhysicalPageLabel()?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let fallbackShowTitle = ReaderPageTurnChromePolicy.titleVisibility(
            hideNavigationDueToScroll: hideNavigationDueToScroll,
            hasTitleChromeContent: hasTitleChromeContent
        )
        let fallbackShowHeader = ReaderPageTurnChromePolicy.headerVisibility(
            hideNavigationDueToScroll: hideNavigationDueToScroll,
            hasHeaderChromeContent: hasHeaderChromeContent
        )
        return PageTurnChromeVisibility(
            showTitle: bridge.showTitleChrome ?? fallbackShowTitle,
            showHeader: bridge.showHeaderChrome ?? fallbackShowHeader
        )
    }

    private func resolvedVisibleUnit() -> PageTurnVisibleUnit {
        if !hasLiveVisibleUnitSemantics(),
           let enrichedVisibleUnit = readerViewModel.state.paginationState?.visibleUnit {
            return adjustedVisibleUnitForColumnPolicy(resolvedPageTurnVisibleUnit(from: enrichedVisibleUnit))
        }
        let kind = resolvedVisibleUnitKind()
        let axis = resolvedVisibleUnitAxis()
        let visiblePageCount = max(1, bridge.layoutVisiblePageCount ?? bridge.layoutColumnCount ?? 1)
        return adjustedVisibleUnitForColumnPolicy(PageTurnVisibleUnit(
            kind: kind,
            axis: axis,
            visiblePageCount: visiblePageCount,
            primarySpacing: resolvedPrimarySpacing(),
            chromeGutterWidth: resolvedChromeGutterWidth(),
            currentUnitIndex: bridge.layoutCurrentUnitIndex,
            leadingPageIndex: bridge.layoutLeadingPageIndex,
            trailingPageIndex: bridge.layoutTrailingPageIndex,
            hasLeadingSingleton: bridge.layoutHasLeadingSingleton ?? false,
            hasTrailingSingleton: bridge.layoutHasTrailingSingleton ?? false
        ))
    }

    private func adjustedVisibleUnitForColumnPolicy(_ visibleUnit: PageTurnVisibleUnit) -> PageTurnVisibleUnit {
        guard !readerAllowMultipleColumns, visibleUnit.visiblePageCount > 1 else {
            return visibleUnit
        }

        let focusedPageIndex = visibleUnit.leadingPageIndex
            ?? visibleUnit.currentUnitIndex
            ?? resolvedPaginationContext().currentPageIndex

        return PageTurnVisibleUnit(
            kind: .singlePage,
            axis: visibleUnit.axis,
            visiblePageCount: 1,
            primarySpacing: visibleUnit.primarySpacing,
            chromeGutterWidth: 0,
            currentUnitIndex: visibleUnit.currentUnitIndex,
            leadingPageIndex: focusedPageIndex,
            trailingPageIndex: nil,
            hasLeadingSingleton: false,
            hasTrailingSingleton: false
        )
    }

    private var resolvedScenePhase: String? {
#if os(iOS)
        switch scenePhase {
        case .active:
            return "active"
        case .inactive:
            return "inactive"
        case .background:
            return "background"
        @unknown default:
            return "unknown"
        }
#else
        return nil
#endif
    }

    private var resolvedHorizontalSizeClass: String? {
#if os(iOS)
        switch horizontalSizeClass {
        case .compact:
            return "compact"
        case .regular:
            return "regular"
        case nil:
            return nil
        @unknown default:
            return "unknown"
        }
#else
        return nil
#endif
    }

    private var resolvedVerticalSizeClass: String? {
#if os(iOS)
        switch verticalSizeClass {
        case .compact:
            return "compact"
        case .regular:
            return "regular"
        case nil:
            return nil
        @unknown default:
            return "unknown"
        }
#else
        return nil
#endif
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
        let paginationPageLabelPolicy = readerViewModel.state.paginationState?.pageLabelPolicy
        let explicitDisplayMode = ReaderResolvedPagination.pageLabelDisplayMode(
            bridgePageLabelDisplayMode: bridge.pageLabelDisplayMode,
            paginationPageLabelPolicy: paginationPageLabelPolicy
        )
        return PageTurnPageLabelPolicy(
            displayMode: explicitDisplayMode,
            usesPhysicalPageLabels: ReaderResolvedPagination.usesPhysicalPageLabels(
                bridgeCurrentPhysicalPageLabel: bridge.currentPhysicalPageLabel,
                paginationPageLabelPolicy: paginationPageLabelPolicy
            ),
            allowsMultipleLabelsInMultiUnitLayout: ReaderResolvedPagination.allowsMultipleLabelsInMultiUnitLayout(
                bridgeAllowsMultipleLabelsInMultiUnitLayout: bridge.allowsMultipleLabelsInMultiUnitLayout,
                paginationPageLabelPolicy: paginationPageLabelPolicy
            )
        ).adjusted(for: visibleUnit)
    }

    private func resolvedCurrentPageDisplayLabel() -> String? {
        ReaderResolvedPagination.currentPageDisplayLabel(
            bridgeLabel: bridge.currentPageDisplayLabel,
            paginationState: readerViewModel.state.paginationState
        )
    }

    private func resolvedCurrentPhysicalPageLabel() -> String? {
        ReaderResolvedPagination.currentPhysicalPageLabel(
            bridgeLabel: bridge.currentPhysicalPageLabel,
            paginationState: readerViewModel.state.paginationState
        )
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
            chromeGutterWidth: max(0, visibleUnit.chromeGutterWidth),
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

    private func resolvedExplicitChromeGutterWidth() -> CGFloat? {
        if let chromeGutterWidth = bridge.layoutChromeGutterWidth {
            return max(0, CGFloat(chromeGutterWidth))
        }
        if let chromeGutterWidth = readerViewModel.state.paginationState?.visibleUnit?.chromeGutterWidth {
            return max(0, chromeGutterWidth)
        }
        return nil
    }

    private func resolvedChromeGutterWidth(
        explicit: CGFloat?,
        visiblePageCount: Int,
        primarySpacing: CGFloat
    ) -> CGFloat {
        guard visiblePageCount > 1 else { return 0 }
        if let explicit, explicit > 0 {
            return explicit
        }
        return min(max(primarySpacing, 12), 48)
    }

    private func resolvedPageNumberHUDWidth(for visibleUnit: PageTurnVisibleUnit) -> CGFloat {
        let contentWidth = layoutModel.inputs.contentRect.width
        let readableWidth = controller.visualState.readableFrame.pageContentWidthWithinMargins
            ?? controller.visualState.readableFrame.maxContentWidth
            ?? contentWidth
        let gutterWidth = resolvedChromeGutterWidth(for: visibleUnit)
        let candidateWidth = min(contentWidth, max(readableWidth, contentWidth - gutterWidth))
        return max(0, candidateWidth)
    }

    private func resolvedChromeGutterWidth() -> CGFloat {
        resolvedChromeGutterWidth(
            explicit: resolvedExplicitChromeGutterWidth(),
            visiblePageCount: max(1, bridge.layoutVisiblePageCount ?? bridge.layoutColumnCount ?? 1),
            primarySpacing: resolvedPrimarySpacing()
        )
    }

    private func resolvedChromeGutterWidth(for visibleUnit: PageTurnVisibleUnit) -> CGFloat {
        resolvedChromeGutterWidth(
            explicit: max(0, visibleUnit.chromeGutterWidth),
            visiblePageCount: visibleUnit.visiblePageCount,
            primarySpacing: resolvedPrimarySpacing()
        )
    }

    private func resolvedChromeGutterWidth(for probe: ReaderPageTurnNavigationProbe) -> CGFloat {
        resolvedChromeGutterWidth(
            explicit: probe.layoutChromeGutterWidth.map { CGFloat($0) },
            visiblePageCount: max(1, probe.layoutVisiblePageCount ?? probe.layoutColumnCount ?? 1),
            primarySpacing: CGFloat(probe.layoutPrimarySpacing ?? Double(resolvedPrimarySpacing()))
        )
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
            chromeGutterWidth: max(0, visibleUnit.chromeGutterWidth),
            currentUnitIndex: visibleUnit.currentUnitIndex,
            leadingPageIndex: visibleUnit.leadingPageIndex,
            trailingPageIndex: visibleUnit.trailingPageIndex,
            hasLeadingSingleton: visibleUnit.hasLeadingSingleton,
            hasTrailingSingleton: visibleUnit.hasTrailingSingleton,
            spreadPagesAllowedForViewport: spreadPagesAllowedForViewport
        )
    }

    private func resolvedWebViewCurrentSpread(from visibleUnit: PageTurnVisibleUnit) -> WebViewPaginationSpread? {
        let slots: [WebViewPaginationSpreadSlot]
        switch visibleUnit.kind {
        case .singlePage:
            let pageIndex = visibleUnit.leadingPageIndex ?? visibleUnit.currentUnitIndex
            guard let pageIndex else { return nil }
            slots = [.init(kind: .page, pageIndex: pageIndex)]
        case .pageSpread:
            if visibleUnit.hasLeadingSingleton {
                guard let trailing = visibleUnit.trailingPageIndex ?? visibleUnit.leadingPageIndex else { return nil }
                slots = [
                    .init(kind: .blank),
                    .init(kind: .page, pageIndex: trailing),
                ]
            } else if visibleUnit.hasTrailingSingleton {
                guard let leading = visibleUnit.leadingPageIndex ?? visibleUnit.trailingPageIndex else { return nil }
                slots = [
                    .init(kind: .page, pageIndex: leading),
                    .init(kind: .blank),
                ]
            } else {
                let indices = [visibleUnit.leadingPageIndex, visibleUnit.trailingPageIndex].compactMap { $0 }
                guard !indices.isEmpty else { return nil }
                slots = indices.map { .init(kind: .page, pageIndex: $0) }
            }
        case .paginatedRowSet:
            let indices = [visibleUnit.leadingPageIndex, visibleUnit.trailingPageIndex].compactMap { $0 }
            guard !indices.isEmpty else { return nil }
            slots = indices.map { .init(kind: .page, pageIndex: $0) }
        }
        return WebViewPaginationSpread(index: visibleUnit.currentUnitIndex, slots: slots)
    }

    private func resolvedWebViewPageLabelPolicy(from pageLabelPolicy: PageTurnPageLabelPolicy) -> WebViewPaginationPageLabelPolicy {
        let displayMode: WebViewPaginationPageLabelDisplayMode = switch pageLabelPolicy.displayMode {
        case .singleLabel: .singleLabel
        case .multipleLabels: .multipleLabels
        }
        return WebViewPaginationPageLabelPolicy(
            displayMode: displayMode,
            usesPhysicalPageLabels: pageLabelPolicy.usesPhysicalPageLabels,
            allowsMultipleLabelsInMultiUnitLayout: pageLabelPolicy.allowsMultipleLabelsInMultiUnitLayout
        )
    }

    private func effectiveRequestedLocationState(
        _ requestedLocation: ReaderPageTurnRequestedLocationState?,
        currentSpread: WebViewPaginationSpread?
    ) -> ReaderPageTurnRequestedLocationState? {
        guard let requestedLocation else { return nil }
        let context = resolvedPaginationContext()
        return isRequestedLocationAlreadyVisible(
            requestedLocation,
            currentSpread: currentSpread,
            pageOffsetsDisplayed: ReaderResolvedPagination.livePageOffsetsDisplayed(
                bridgePageOffsetsDisplayed: context.bridgePageOffsetsDisplayed,
                paginationPageOffsetsDisplayed: context.paginationState?.pageOffsetsDisplayed,
                resolvedCurrentSpread: currentSpread,
                resolvedGraph: context.resolvedGraph
            ),
            pageCount: context.pageCount,
            currentPage: context.currentPageIndex,
            currentSectionHref: bridge.currentSectionHref,
            layoutLeadingPageIndex: bridge.layoutLeadingPageIndex,
            layoutTrailingPageIndex: bridge.layoutTrailingPageIndex,
            layoutVisiblePageCount: bridge.layoutVisiblePageCount
        )
            ? nil
            : requestedLocation
    }

    private func isRequestedLocationAlreadyVisible(
        _ requestedLocation: ReaderPageTurnRequestedLocationState,
        currentSpread: WebViewPaginationSpread?,
        pageOffsetsDisplayed: [Int]?,
        pageCount: Int?,
        currentPage: Int?,
        currentSectionHref: String?,
        layoutLeadingPageIndex: Int?,
        layoutTrailingPageIndex: Int?,
        layoutVisiblePageCount: Int?
    ) -> Bool {
        let paginationContext = resolvedPaginationContext()
        let resolvedGraph = ReaderPageTurnSpreadGraph(
            currentSpread: currentSpread,
            destinationSpread: paginationContext.destinationSpread(direction: nil),
            pageOffsetsDisplayed: pageOffsetsDisplayed,
            pageCount: pageCount,
            layoutLeadingPageIndex: layoutLeadingPageIndex,
            currentPage: currentPage,
            layoutTrailingPageIndex: layoutTrailingPageIndex,
            layoutVisiblePageCount: layoutVisiblePageCount
        ).resolvedGraph
        return resolvedGraph.contains(
            requestedLocation,
            currentSectionHref: currentSectionHref
        )
    }

    private func makeProbeSnapshot() async -> ReaderPageTurnProbeSnapshot {
        let liveWebViewIdentifier = await navigator.withAttachedWebView { webView in
            String(describing: ObjectIdentifier(webView))
        } ?? nil
        let paginationState = readerViewModel.state.paginationState
        let paginationContext = resolvedPaginationContext(paginationState: paginationState)
        let interaction = controller.lastInteractionEvent
        let resolvedSnapshotGraph = paginationContext.resolvedGraph
        let resolvedCurrentSpread = paginationContext.currentSpread
        let resolvedDestinationSpread = paginationContext.destinationSpread(direction: interaction?.direction)
        let pageLabelPolicy = resolvedPageLabelPolicy(visibleUnit: resolvedVisibleUnit())
        let chromeVisibility = resolvedChromeVisibility()
        let resolvedCanMoveForward = paginationContext.canMoveForward ?? false
        let resolvedCanMoveBackward = paginationContext.canMoveBackward ?? false
        let resolvedForwardDestinationAvailability = paginationContext.destinationAvailability(for: .forward)
            ?? resolvedSnapshotGraph.forwardDestinationAvailability
        let resolvedBackwardDestinationAvailability = paginationContext.destinationAvailability(for: .backward)
            ?? resolvedSnapshotGraph.backwardDestinationAvailability
        let requestedLocationState = effectiveRequestedLocationState(
            readerViewModel.pageTurnRequestedLocationState,
            currentSpread: resolvedCurrentSpread
        )
        let readingProgressState = readerViewModel.pageTurnReadingProgressState
        return ReaderPageTurnProbeSnapshot(
            pageURL: readerViewModel.state.pageURL.absoluteString,
            requestedEnabled: requestedEnabled,
            structurallyEligible: isStructurallyEligibleForActiveTurns,
            activeEnabled: isActivePageTurnEnabled,
            supportsActivePageTurn: bridge.supportsActivePageTurn,
            gestureCaptureEnabled: isGestureCaptureEnabled,
            gestureCaptureBlockReason: interactionContext.blockingReason,
            hideNavigationDueToScroll: hideNavigationDueToScroll,
            showTitleChrome: bridge.showTitleChrome ?? chromeVisibility.showTitle,
            showHeaderChrome: bridge.showHeaderChrome ?? chromeVisibility.showHeader,
            pageProgressionDirection: bridge.pageProgressionDirection.rawValue,
            phase: controller.phase.rawValue,
            navigationStyle: bridge.pageNavigationStyle.rawValue,
            transitionFamily: bridge.transitionFamily.rawValue,
            movementKind: controller.visualState.movementKind?.rawValue ?? bridge.movementKind?.rawValue,
            layoutState: bridge.layoutState.rawValue,
            updateReason: bridge.updateReason?.rawValue,
            navigationEvent: bridge.lastNavigationEvent?.kind.rawValue,
            contentHostState: bridge.contentHostState.rawValue,
            contentHostSequenceMountedHostIdentifier: bridge.contentHostSequence.mountedHostIdentifier,
            contentHostSequenceAppliedHostIdentifier: bridge.contentHostSequence.appliedHostIdentifier,
            contentHostSequenceIsAppliedToMountedHost: bridge.contentHostSequence.isAppliedToMountedHost,
            contentHostSequenceIsStable: bridge.contentHostSequence.isStable,
            contentHostSequenceSerial: bridge.contentHostSequence.serial,
            preloadStrategy: bridge.preloadStrategy.rawValue,
            currentContentLocation: paginationContext.currentContentLocation.rawValue,
            contentLoadingClass: controller.visualState.loadingTracks.content.rawValue,
            snapshotLoadingClass: controller.visualState.loadingTracks.snapshot.rawValue,
            mountedHostIdentifier: paginationState?.mountedHostIdentifier,
            appliedHostIdentifier: paginationState?.appliedHostIdentifier,
            liveWebViewIdentifier: liveWebViewIdentifier,
            pageOffsetsDisplayed: paginationContext.pageOffsetsDisplayed
                ?? resolvedSnapshotGraph.currentVisiblePageIndices,
            currentSpreadSlots: serializedSpreadSlots(
                resolvedCurrentSpread,
                fallbackSpread: resolvedSnapshotGraph.spreadSequence.current?.spread,
                fallbackPageIndices: resolvedSnapshotGraph.spreadSequence.current?.pageIndices
                    ?? resolvedSnapshotGraph.currentVisiblePageIndices
            ),
            destinationSpreadSlots: serializedSpreadSlots(
                resolvedDestinationSpread,
                fallbackSpread: ReaderResolvedPagination.destinationSpread(
                    direction: interaction?.direction,
                    resolvedGraph: resolvedSnapshotGraph
                ),
                fallbackPageIndices: interaction?.direction.flatMap { direction in
                    resolvedSnapshotGraph.spreadSequence.node(for: direction)?.pageIndices
                        ?? resolvedSnapshotGraph.destinationPageIndices(for: direction)
                }
            ),
            requestedLocationKind: controller.visualState.requestedLocation?.kind.rawValue ?? requestedLocationState?.kind,
            requestedLocationValue: controller.visualState.requestedLocation?.value ?? requestedLocationState?.value,
            requestedLocationSource: requestedLocationState?.source.rawValue,
            requestedLocationSurroundingContext: controller.visualState.requestedLocation?.surroundingContext ?? requestedLocationState?.surroundingContext,
            requestedLocationIsPageChange: controller.visualState.requestedLocation?.isRequestedPageChange ?? requestedLocationState?.isRequestedPageChange,
            requestedLocationFractionalCompletion: requestedLocationState?.fractionalCompletion.map(Double.init),
            readingProgressCFI: readingProgressState?.cfi,
            readingProgressFractionalCompletion: readingProgressState?.fractionalCompletion.map(Double.init),
            readingProgressHighWaterMarkFractionalCompletion: readingProgressState?.highWaterMarkFractionalCompletion.map(Double.init),
            readingProgressSuppressionReason: readerViewModel.pageTurnReadingProgressSuppressionReason,
            readingProgressReason: readingProgressState?.reason,
            readingProgressSectionIndex: readingProgressState?.sectionIndex,
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
            currentPage: paginationContext.currentPageIndex,
            livePageIndex: bridge.livePageIndex,
            liveChunkPageIndex: bridge.liveChunkPageIndex,
            viewportCenterChunkPageIndex: bridge.viewportCenterChunkPageIndex,
            pageCount: paginationContext.pageCount,
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
            layoutChromeGutterWidth: Double(resolvedChromeGutterWidth()),
            layoutReadableFrameWidth: Double(controller.visualState.readableFrame.pageContentWidthWithinMargins ?? 0),
            layoutMaxContentWidth: Double(controller.visualState.readableFrame.maxContentWidth ?? 0),
            layoutSemanticSideInset: Double(controller.visualState.readableFrame.semanticSideInset),
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
            currentPageDisplayLabel: resolvedCurrentPageDisplayLabel(),
            currentPhysicalPageLabel: resolvedCurrentPhysicalPageLabel(),
            progressScrubberVisible: bridge.progressScrubberVisible,
            progressScrubberActive: bridge.progressScrubberActive,
            historyCanGoBack: bridge.historyCanGoBack,
            historyCanGoForward: bridge.historyCanGoForward,
            historyDepth: bridge.historyDepth,
            historyCurrentIndex: bridge.historyCurrentIndex,
            historyPendingReplaceStateSuppressionCount: bridge.historyPendingReplaceStateSuppressionCount,
            historySuppressedReplaceStateCount: bridge.historySuppressedReplaceStateCount,
            historyLastSuppressedReplaceStateReason: bridge.historyLastSuppressedReplaceStateReason,
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
            forwardDestinationAvailability: resolvedForwardDestinationAvailability.rawValue,
            backwardDestinationAvailability: resolvedBackwardDestinationAvailability.rawValue,
            paginationComplete: paginationContext.metadataPaginationComplete,
            configurationKey: paginationContext.metadataConfigurationKey,
            publicationSource: paginationContext.metadataPublicationSource?.rawValue,
            pageLabelDisplayMode: pageLabelPolicy.displayMode.rawValue,
            pageNumberMode: paginationContext.metadataPageNumberMode?.rawValue,
            usesPhysicalPageLabels: pageLabelPolicy.usesPhysicalPageLabels,
            allowsMultipleColumns: paginationContext.metadataAllowsMultipleColumns,
            allowsMultipleLabelsInMultiUnitLayout: pageLabelPolicy.allowsMultipleLabelsInMultiUnitLayout,
            visiblePageIndices: ReaderResolvedPagination.visiblePageIndices(
                bridgeVisiblePageIndices: controller.visualState.visiblePagesState.visiblePageIndices.isEmpty
                    ? nil
                    : controller.visualState.visiblePagesState.visiblePageIndices,
                resolvedGraph: resolvedSnapshotGraph
            ),
            pageScrollerAnimationIsRunning: controller.visualState.visiblePagesState.pageScrollerAnimationIsRunning,
            liveResizeActive: controller.visualState.visiblePagesState.liveResizeActive,
            canForward: resolvedCanMoveForward,
            canBackward: resolvedCanMoveBackward,
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

    private func resolvedProbeSnapshotGraph(
        paginationState: WebViewPaginationState?
    ) -> ReaderPageTurnResolvedGraph {
        resolvedPaginationContext(paginationState: paginationState).resolvedGraph
    }

    private func serializedSpreadSlots(
        _ spread: WebViewPaginationSpread?,
        fallbackSpread: WebViewPaginationSpread? = nil,
        fallbackPageIndices: [Int]? = nil
    ) -> [String]? {
        if let spread {
            return spread.slots.map { "\($0.kind.rawValue):\($0.pageIndex.map(String.init) ?? "nil")" }
        }
        if let fallbackSpread {
            return fallbackSpread.slots.map { "\($0.kind.rawValue):\($0.pageIndex.map(String.init) ?? "nil")" }
        }
        guard let fallbackPageIndices, !fallbackPageIndices.isEmpty else {
            return nil
        }
        return fallbackPageIndices.map { "page:\($0)" }
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
            bridge.publishAttemptedPastEndForDiagnostics(direction: direction)
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
        let centerTapAreaLength = readerPageTurnInteractionContext.centerTapAreaLength.map { String($0) } ?? "nil"
        return [
            pageTurnProbeModel.snapshot?.summary ?? "pageTurnProbe=nil",
            "lastCommandResult=\(pageTurnProbeModel.lastCommandResult ?? "nil")",
            "lookupPresented=\(readerPageTurnInteractionContext.lookupPresented)",
            "mediaPresented=\(readerPageTurnInteractionContext.mediaPresented)",
            "hasSelection=\(readerPageTurnInteractionContext.hasSelection)",
            "ignorePageTurns=\(readerPageTurnInteractionContext.ignorePageTurns)",
            "lineGuideEnabled=\(readerPageTurnInteractionContext.lineGuideEnabled)",
            "requiresEdgeTouch=\(readerPageTurnInteractionContext.requiresEdgeTouch)",
            "centerTapAreaLength=\(centerTapAreaLength)",
            "bothMarginsAdvancePage=\(readerPageTurnInteractionContext.allowsBothMarginsAdvancePage)",
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
