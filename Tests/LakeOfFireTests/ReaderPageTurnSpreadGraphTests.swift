import XCTest
@testable import LakeOfFireReader
import SwiftUIPageTurn
import SwiftUIWebView

final class ReaderPageTurnSpreadGraphTests: XCTestCase {
    func testResolvedSpreadStepPrefersPublishedDestinationSpreadWhenForward() {
        let currentSpread = WebViewPaginationSpread(
            index: 10,
            slots: [
                .init(kind: .page, pageIndex: 20),
                .init(kind: .page, pageIndex: 21),
            ]
        )
        let destinationSpread = WebViewPaginationSpread(
            index: 11,
            slots: [
                .init(kind: .page, pageIndex: 22),
                .init(kind: .page, pageIndex: 23),
            ]
        )

        let step = readerResolvedSpreadStep(
            direction: .forward,
            currentSpread: currentSpread,
            destinationSpread: destinationSpread,
            pageOffsetsDisplayed: nil,
            pageCount: 100,
            layoutLeadingPageIndex: nil,
            currentPage: nil,
            layoutTrailingPageIndex: nil,
            layoutVisiblePageCount: nil
        )

        XCTAssertEqual(step?.currentPageIndices, [20, 21])
        XCTAssertEqual(step?.destinationPageIndices, [22, 23])
        XCTAssertEqual(step?.destinationSpread, destinationSpread)
        XCTAssertEqual(readerResolvedDestinationAvailability(spreadStep: step!, pageCount: 100), .both)
    }

    func testResolvedDestinationAvailabilityUsesDestinationSpreadBlankSlots() {
        let destinationSpread = WebViewPaginationSpread(
            index: 4,
            slots: [
                .init(kind: .blank),
                .init(kind: .page, pageIndex: 8),
            ]
        )
        let step = ReaderResolvedSpreadStep(
            currentPageIndices: [6, 7],
            destinationPageIndices: [8],
            destinationSpread: destinationSpread
        )

        XCTAssertEqual(readerResolvedDestinationAvailability(spreadStep: step, pageCount: 100), .first)
    }

    func testSyntheticSpreadUsesLeadingBlankForFirstSingleton() {
        let spread = readerSyntheticSpread(
            spreadIndex: 0,
            pageIndices: [0],
            pageCount: 5
        )

        XCTAssertEqual(spread.index, 0)
        XCTAssertEqual(spread.slots, [
            .init(kind: .blank),
            .init(kind: .page, pageIndex: 0),
        ])
        XCTAssertEqual(readerSyntheticSpreadIndex(pageIndices: [0], pageCount: 5), 0)
    }

    func testSyntheticSpreadUsesTrailingBlankForLastSingleton() {
        let spread = readerSyntheticSpread(
            spreadIndex: 2,
            pageIndices: [4],
            pageCount: 5
        )

        XCTAssertEqual(spread.index, 2)
        XCTAssertEqual(spread.slots, [
            .init(kind: .page, pageIndex: 4),
            .init(kind: .blank),
        ])
        XCTAssertEqual(readerSyntheticSpreadIndex(pageIndices: [4], pageCount: 5), 2)
    }

    func testSyntheticSpreadIndexUsesPairLeadingPageWhenMetadataIsMissing() {
        XCTAssertEqual(readerSyntheticSpreadIndex(pageIndices: [1, 2], pageCount: 5), 1)
        XCTAssertEqual(readerSyntheticSpreadIndex(pageIndices: [3, 4], pageCount: 5), 2)
        XCTAssertEqual(readerSyntheticSpreadIndex(pageIndices: [4, 5], pageCount: 8), 2)
    }

    func testResolvedSpreadStepFallsBackToGeometryWhenSpreadDataMissing() {
        let step = readerResolvedSpreadStep(
            direction: .backward,
            currentSpread: nil,
            destinationSpread: nil,
            pageOffsetsDisplayed: nil,
            pageCount: 12,
            layoutLeadingPageIndex: 6,
            currentPage: 6,
            layoutTrailingPageIndex: 7,
            layoutVisiblePageCount: 2
        )

        XCTAssertEqual(step?.currentPageIndices, [6, 7])
        XCTAssertEqual(step?.destinationPageIndices, [4, 5])
        XCTAssertNil(step?.destinationSpread)
    }

    func testSpreadGraphContainsRequestedPageNumberWithinVisibleSpread() {
        let graph = ReaderPageTurnSpreadGraph(
            currentSpread: WebViewPaginationSpread(
                index: 2,
                slots: [
                    .init(kind: .page, pageIndex: 4),
                    .init(kind: .page, pageIndex: 5),
                ]
            ),
            destinationSpread: nil,
            pageOffsetsDisplayed: nil,
            pageCount: 20,
            layoutLeadingPageIndex: nil,
            currentPage: 4,
            layoutTrailingPageIndex: nil,
            layoutVisiblePageCount: nil
        )
        let request = ReaderPageTurnRequestedLocationState(
            source: .savedRestore,
            kind: PageTurnRequestedLocationKind.pageNumber.rawValue,
            value: "6"
        )

        XCTAssertTrue(graph.contains(request, currentSectionHref: nil))
    }

    func testSpreadGraphContainsRequestedHrefWhenSectionMatches() {
        let graph = ReaderPageTurnSpreadGraph(
            currentSpread: nil,
            destinationSpread: nil,
            pageOffsetsDisplayed: [2],
            pageCount: 20,
            layoutLeadingPageIndex: 2,
            currentPage: 2,
            layoutTrailingPageIndex: 2,
            layoutVisiblePageCount: 1
        )
        let request = ReaderPageTurnRequestedLocationState(
            source: .defaultRestore,
            kind: PageTurnRequestedLocationKind.href.rawValue,
            value: "chapter-2.xhtml"
        )

        XCTAssertTrue(graph.contains(request, currentSectionHref: "chapter-2.xhtml"))
        XCTAssertFalse(graph.contains(request, currentSectionHref: "chapter-3.xhtml"))
    }

    func testSpreadGraphContainsZeroProgressOnlyAtBeginning() {
        let graph = ReaderPageTurnSpreadGraph(
            currentSpread: nil,
            destinationSpread: nil,
            pageOffsetsDisplayed: [0],
            pageCount: 20,
            layoutLeadingPageIndex: 0,
            currentPage: 0,
            layoutTrailingPageIndex: 0,
            layoutVisiblePageCount: 1
        )
        let request = ReaderPageTurnRequestedLocationState(
            source: .defaultRestore,
            kind: PageTurnRequestedLocationKind.progress.rawValue,
            value: "0"
        )

        XCTAssertTrue(graph.contains(request, currentSectionHref: nil))
        let laterGraph = ReaderPageTurnSpreadGraph(
            currentSpread: nil,
            destinationSpread: nil,
            pageOffsetsDisplayed: [3],
            pageCount: 20,
            layoutLeadingPageIndex: 3,
            currentPage: 3,
            layoutTrailingPageIndex: 3,
            layoutVisiblePageCount: 1
        )
        XCTAssertFalse(laterGraph.contains(request, currentSectionHref: nil))
    }

    func testSpreadGraphDerivesPageOffsetRangeAndCenterLocationForSpread() {
        let graph = ReaderPageTurnSpreadGraph(
            currentSpread: WebViewPaginationSpread(
                index: 7,
                slots: [
                    .init(kind: .page, pageIndex: 14),
                    .init(kind: .page, pageIndex: 15),
                ]
            ),
            destinationSpread: nil,
            pageOffsetsDisplayed: nil,
            pageCount: 30,
            layoutLeadingPageIndex: nil,
            currentPage: 14,
            layoutTrailingPageIndex: nil,
            layoutVisiblePageCount: nil
        )

        XCTAssertEqual(graph.currentPageIndex, 14)
        XCTAssertEqual(graph.visiblePageCount, 2)
        XCTAssertEqual(graph.pageOffsetRange, .init(lowerBound: 14, upperBound: 15))
        XCTAssertEqual(graph.currentContentLocation, .center)
    }

    func testSpreadGraphDerivesTrailingLocationForLeadingSingleton() {
        let graph = ReaderPageTurnSpreadGraph(
            currentSpread: WebViewPaginationSpread(
                index: 0,
                slots: [
                    .init(kind: .blank, pageIndex: nil),
                    .init(kind: .page, pageIndex: 0),
                ]
            ),
            destinationSpread: nil,
            pageOffsetsDisplayed: nil,
            pageCount: 10,
            layoutLeadingPageIndex: nil,
            currentPage: 0,
            layoutTrailingPageIndex: nil,
            layoutVisiblePageCount: nil
        )

        XCTAssertEqual(graph.currentPageIndex, 0)
        XCTAssertEqual(graph.visiblePageCount, 1)
        XCTAssertEqual(graph.currentContentLocation, .trailing)
    }

    func testSpreadGraphDerivesLeadingLocationForTrailingSingleton() {
        let graph = ReaderPageTurnSpreadGraph(
            currentSpread: WebViewPaginationSpread(
                index: 4,
                slots: [
                    .init(kind: .page, pageIndex: 8),
                    .init(kind: .blank, pageIndex: nil),
                ]
            ),
            destinationSpread: nil,
            pageOffsetsDisplayed: nil,
            pageCount: 10,
            layoutLeadingPageIndex: nil,
            currentPage: 8,
            layoutTrailingPageIndex: nil,
            layoutVisiblePageCount: nil
        )

        XCTAssertEqual(graph.currentPageIndex, 8)
        XCTAssertEqual(graph.visiblePageCount, 1)
        XCTAssertEqual(graph.currentContentLocation, .leading)
    }

    func testDestinationAvailabilityIsUnavailableAtForwardEnd() {
        let graph = ReaderPageTurnSpreadGraph(
            currentSpread: nil,
            destinationSpread: nil,
            pageOffsetsDisplayed: [9],
            pageCount: 10,
            layoutLeadingPageIndex: 9,
            currentPage: 9,
            layoutTrailingPageIndex: 9,
            layoutVisiblePageCount: 1
        )

        XCTAssertEqual(graph.destinationAvailability(for: .forward), .unavailable)
        XCTAssertEqual(graph.destinationAvailability(for: .backward), .both)
    }

    func testDestinationAvailabilityIsUnavailableAtBackwardStart() {
        let graph = ReaderPageTurnSpreadGraph(
            currentSpread: nil,
            destinationSpread: nil,
            pageOffsetsDisplayed: [0],
            pageCount: 10,
            layoutLeadingPageIndex: 0,
            currentPage: 0,
            layoutTrailingPageIndex: 0,
            layoutVisiblePageCount: 1
        )

        XCTAssertEqual(graph.destinationAvailability(for: .backward), .unavailable)
        XCTAssertEqual(graph.destinationAvailability(for: .forward), .both)
    }

    func testResolvedNavigationEventKindIsNoPageChangeWhenVisiblePagesMatch() {
        let baseline = ReaderPageTurnSpreadGraph(
            currentSpread: nil,
            destinationSpread: nil,
            pageOffsetsDisplayed: [4, 5],
            pageCount: 20,
            layoutLeadingPageIndex: 4,
            currentPage: 4,
            layoutTrailingPageIndex: 5,
            layoutVisiblePageCount: 2
        )
        let after = ReaderPageTurnSpreadGraph(
            currentSpread: nil,
            destinationSpread: nil,
            pageOffsetsDisplayed: [4, 5],
            pageCount: 20,
            layoutLeadingPageIndex: 4,
            currentPage: 4,
            layoutTrailingPageIndex: 5,
            layoutVisiblePageCount: 2
        )

        XCTAssertEqual(after.resolvedNavigationEventKind(comparedTo: baseline, direction: .forward), .noPageChange)
    }

    func testResolvedNavigationEventKindTracksDirectionalMovement() {
        let baseline = ReaderPageTurnSpreadGraph(
            currentSpread: nil,
            destinationSpread: nil,
            pageOffsetsDisplayed: [4, 5],
            pageCount: 20,
            layoutLeadingPageIndex: 4,
            currentPage: 4,
            layoutTrailingPageIndex: 5,
            layoutVisiblePageCount: 2
        )
        let after = ReaderPageTurnSpreadGraph(
            currentSpread: nil,
            destinationSpread: nil,
            pageOffsetsDisplayed: [6, 7],
            pageCount: 20,
            layoutLeadingPageIndex: 6,
            currentPage: 6,
            layoutTrailingPageIndex: 7,
            layoutVisiblePageCount: 2
        )

        XCTAssertEqual(after.resolvedNavigationEventKind(comparedTo: baseline, direction: .forward), .nextPage)
        XCTAssertEqual(after.resolvedNavigationEventKind(comparedTo: baseline, direction: .backward), .previousPage)
    }

    func testResolvedSpreadSequenceSynthesizesSpreadEntitiesForSyntheticNodes() {
        let resolved = ReaderPageTurnSpreadGraph(
            currentSpread: WebViewPaginationSpread(
                index: 1,
                slots: [
                    .init(kind: .page, pageIndex: 1),
                    .init(kind: .page, pageIndex: 2),
                ]
            ),
            destinationSpread: nil,
            pageOffsetsDisplayed: [1, 2],
            pageCount: 5,
            layoutLeadingPageIndex: 1,
            currentPage: 1,
            layoutTrailingPageIndex: 2,
            layoutVisiblePageCount: 2
        ).resolvedGraph

        XCTAssertEqual(resolved.spreadSequence.backward?.spread.slots, [
            .init(kind: .blank),
            .init(kind: .page, pageIndex: 0),
        ])
        XCTAssertEqual(resolved.spreadSequence.forward?.spread.slots, [
            .init(kind: .page, pageIndex: 3),
            .init(kind: .page, pageIndex: 4),
        ])
        XCTAssertEqual(resolved.spreadSequence.current?.spreadIndex, 1)
        XCTAssertEqual(resolved.spreadSequence.backward?.spreadIndex, 0)
        XCTAssertEqual(resolved.spreadSequence.forward?.spreadIndex, 2)
    }

    func testResolvedGraphRelativeSpreadOffsetUsesBaselineSequence() {
        let baseline = ReaderPageTurnSpreadGraph(
            currentSpread: WebViewPaginationSpread(
                index: 10,
                slots: [
                    .init(kind: .page, pageIndex: 20),
                    .init(kind: .page, pageIndex: 21),
                ]
            ),
            destinationSpread: WebViewPaginationSpread(
                index: 11,
                slots: [
                    .init(kind: .page, pageIndex: 22),
                    .init(kind: .page, pageIndex: 23),
                ]
            ),
            pageOffsetsDisplayed: nil,
            pageCount: 40,
            layoutLeadingPageIndex: nil,
            currentPage: 20,
            layoutTrailingPageIndex: nil,
            layoutVisiblePageCount: nil
        ).resolvedGraph

        let after = ReaderPageTurnSpreadGraph(
            currentSpread: nil,
            destinationSpread: nil,
            pageOffsetsDisplayed: [22, 23],
            pageCount: 40,
            layoutLeadingPageIndex: 22,
            currentPage: 22,
            layoutTrailingPageIndex: 23,
            layoutVisiblePageCount: 2
        ).resolvedGraph

        XCTAssertEqual(after.relativeSpreadOffset(comparedTo: baseline), 1)
        XCTAssertEqual(after.resolvedNavigationEventKind(comparedTo: baseline, direction: .backward), .nextPage)
    }

    func testResolvedGraphRelativeSpreadOffsetUsesCurrentSequenceFallback() {
        let baseline = ReaderPageTurnSpreadGraph(
            currentSpread: nil,
            destinationSpread: nil,
            pageOffsetsDisplayed: [22, 23],
            pageCount: 40,
            layoutLeadingPageIndex: 22,
            currentPage: 22,
            layoutTrailingPageIndex: 23,
            layoutVisiblePageCount: 2
        ).resolvedGraph

        let after = ReaderPageTurnSpreadGraph(
            currentSpread: WebViewPaginationSpread(
                index: 10,
                slots: [
                    .init(kind: .page, pageIndex: 20),
                    .init(kind: .page, pageIndex: 21),
                ]
            ),
            destinationSpread: WebViewPaginationSpread(
                index: 11,
                slots: [
                    .init(kind: .page, pageIndex: 22),
                    .init(kind: .page, pageIndex: 23),
                ]
            ),
            pageOffsetsDisplayed: nil,
            pageCount: 40,
            layoutLeadingPageIndex: nil,
            currentPage: 20,
            layoutTrailingPageIndex: nil,
            layoutVisiblePageCount: nil
        ).resolvedGraph

        XCTAssertEqual(after.relativeSpreadOffset(comparedTo: baseline), -1)
        XCTAssertEqual(after.resolvedNavigationEventKind(comparedTo: baseline, direction: .forward), .previousPage)
    }

    func testMovementGraphPrecomputesDirectionalAvailability() {
        let graph = ReaderPageTurnSpreadGraph(
            currentSpread: nil,
            destinationSpread: nil,
            pageOffsetsDisplayed: [8, 9],
            pageCount: 10,
            layoutLeadingPageIndex: 8,
            currentPage: 8,
            layoutTrailingPageIndex: 9,
            layoutVisiblePageCount: 2
        ).movementGraph

        XCTAssertFalse(graph.canMoveForward)
        XCTAssertTrue(graph.canMoveBackward)
        XCTAssertEqual(graph.destinationAvailability(for: .forward), .unavailable)
        XCTAssertEqual(graph.destinationAvailability(for: .backward), .both)
    }

    func testResolvedGraphPrecomputesCurrentRangeAndDirectionalAvailability() {
        let resolved = ReaderPageTurnSpreadGraph(
            currentSpread: WebViewPaginationSpread(
                index: 3,
                slots: [
                    .init(kind: .page, pageIndex: 6),
                    .init(kind: .page, pageIndex: 7),
                ]
            ),
            destinationSpread: WebViewPaginationSpread(
                index: 4,
                slots: [
                    .init(kind: .page, pageIndex: 8),
                    .init(kind: .blank),
                ]
            ),
            pageOffsetsDisplayed: nil,
            pageCount: 10,
            layoutLeadingPageIndex: nil,
            currentPage: 6,
            layoutTrailingPageIndex: nil,
            layoutVisiblePageCount: nil
        ).resolvedGraph

        XCTAssertEqual(resolved.currentVisiblePageIndices, [6, 7])
        XCTAssertEqual(resolved.pageOffsetRange, .init(lowerBound: 6, upperBound: 7))
        XCTAssertEqual(resolved.currentContentLocation, .center)
        XCTAssertEqual(resolved.forwardDestinationAvailability, .second)
        XCTAssertEqual(resolved.backwardDestinationAvailability, .both)
        XCTAssertTrue(resolved.canMoveForward)
        XCTAssertTrue(resolved.canMoveBackward)
    }

    func testResolvedGraphPrecomputesSpreadSequence() {
        let resolved = ReaderPageTurnSpreadGraph(
            currentSpread: WebViewPaginationSpread(
                index: 10,
                slots: [
                    .init(kind: .page, pageIndex: 20),
                    .init(kind: .page, pageIndex: 21),
                ]
            ),
            destinationSpread: WebViewPaginationSpread(
                index: 11,
                slots: [
                    .init(kind: .page, pageIndex: 22),
                    .init(kind: .page, pageIndex: 23),
                ]
            ),
            pageOffsetsDisplayed: nil,
            pageCount: 40,
            layoutLeadingPageIndex: nil,
            currentPage: 20,
            layoutTrailingPageIndex: nil,
            layoutVisiblePageCount: nil
        ).resolvedGraph

        XCTAssertEqual(resolved.spreadSequence.current?.pageIndices, [20, 21])
        XCTAssertEqual(resolved.spreadSequence.current?.spreadIndex, 10)
        XCTAssertEqual(resolved.spreadSequence.forward?.pageIndices, [22, 23])
        XCTAssertEqual(resolved.spreadSequence.forward?.spreadIndex, 11)
        XCTAssertEqual(resolved.spreadSequence.backward?.pageIndices, [18, 19])
        XCTAssertEqual(resolved.spreadSequence.backward?.spreadIndex, 9)
        XCTAssertEqual(resolved.spreadSequence.nodes.first?.pageIndices, [0, 1])
        XCTAssertEqual(resolved.spreadSequence.nodes.first?.spreadIndex, 0)
        XCTAssertEqual(resolved.spreadSequence.nodes.last?.pageIndices, [38, 39])
        XCTAssertEqual(resolved.spreadSequence.nodes.last?.spreadIndex, 19)
        XCTAssertEqual(resolved.spreadSequence.nodes.count, 20)
        XCTAssertEqual(resolved.spreadSequence.currentIndex, 10)
        XCTAssertEqual(resolved.spreadSequence.node(relativeOffset: -10)?.pageIndices, [0, 1])
        XCTAssertEqual(resolved.spreadSequence.node(relativeOffset: -10)?.spreadIndex, 0)
        XCTAssertEqual(resolved.spreadSequence.node(relativeOffset: -1)?.pageIndices, [18, 19])
        XCTAssertEqual(resolved.spreadSequence.node(relativeOffset: -1)?.spreadIndex, 9)
        XCTAssertEqual(resolved.spreadSequence.node(relativeOffset: 0)?.pageIndices, [20, 21])
        XCTAssertEqual(resolved.spreadSequence.node(relativeOffset: 0)?.spreadIndex, 10)
        XCTAssertEqual(resolved.spreadSequence.node(relativeOffset: 1)?.pageIndices, [22, 23])
        XCTAssertEqual(resolved.spreadSequence.node(relativeOffset: 1)?.spreadIndex, 11)
        XCTAssertEqual(resolved.spreadSequence.node(relativeOffset: 9)?.pageIndices, [38, 39])
        XCTAssertEqual(resolved.spreadSequence.node(relativeOffset: 9)?.spreadIndex, 19)
        XCTAssertEqual(resolved.destinationPageIndices(for: .forward), [22, 23])
        XCTAssertEqual(resolved.destinationPageIndices(for: .backward), [18, 19])
    }

    func testResolvedGraphRelativeSpreadOffsetPrefersSpreadIndices() {
        let baseline = ReaderPageTurnSpreadGraph(
            currentSpread: WebViewPaginationSpread(
                index: 10,
                slots: [
                    .init(kind: .page, pageIndex: 20),
                    .init(kind: .page, pageIndex: 21),
                ]
            ),
            destinationSpread: WebViewPaginationSpread(
                index: 11,
                slots: [
                    .init(kind: .page, pageIndex: 22),
                    .init(kind: .page, pageIndex: 23),
                ]
            ),
            pageOffsetsDisplayed: nil,
            pageCount: 40,
            layoutLeadingPageIndex: nil,
            currentPage: 20,
            layoutTrailingPageIndex: nil,
            layoutVisiblePageCount: nil
        ).resolvedGraph

        let after = ReaderPageTurnSpreadGraph(
            currentSpread: WebViewPaginationSpread(
                index: 11,
                slots: [
                    .init(kind: .page, pageIndex: 22),
                    .init(kind: .page, pageIndex: 23),
                ]
            ),
            destinationSpread: nil,
            pageOffsetsDisplayed: [22, 23],
            pageCount: 40,
            layoutLeadingPageIndex: 22,
            currentPage: 22,
            layoutTrailingPageIndex: 23,
            layoutVisiblePageCount: 2
        ).resolvedGraph

        XCTAssertEqual(after.relativeSpreadOffset(comparedTo: baseline), 1)
    }

    func testResolvedSpreadSequenceRelativeOffsetFallsBackFromSpreadIndexToPageIndices() {
        let spread = WebViewPaginationSpread(
            index: 10,
            slots: [
                .init(kind: .page, pageIndex: 20),
                .init(kind: .page, pageIndex: 21),
            ]
        )
        let sequence = ReaderResolvedSpreadSequence(
            nodes: [
                .init(kind: .backward(1), spreadIndex: 9, pageIndices: [18, 19], spread: spread),
                .init(kind: .current, spreadIndex: 10, pageIndices: [20, 21], spread: spread),
                .init(kind: .forward(1), spreadIndex: 11, pageIndices: [22, 23], spread: spread),
            ],
            currentIndex: 1
        )
        let missingSpreadIndex: Int? = nil

        XCTAssertEqual(sequence.relativeOffset(toSpreadIndex: 11, pageIndices: [22, 23]), 1)
        XCTAssertEqual(sequence.relativeOffset(toSpreadIndex: missingSpreadIndex, pageIndices: [18, 19]), -1)
        XCTAssertNil(sequence.relativeOffset(toSpreadIndex: 10, pageIndices: [20, 21]))
    }

    func testResolvedSpreadSequencePreservesSingletonEdgeOrdinals() {
        let resolved = ReaderPageTurnSpreadGraph(
            currentSpread: WebViewPaginationSpread(
                index: 0,
                slots: [
                    .init(kind: .blank),
                    .init(kind: .page, pageIndex: 0),
                ]
            ),
            destinationSpread: WebViewPaginationSpread(
                index: 1,
                slots: [
                    .init(kind: .page, pageIndex: 1),
                    .init(kind: .page, pageIndex: 2),
                ]
            ),
            pageOffsetsDisplayed: nil,
            pageCount: 5,
            layoutLeadingPageIndex: nil,
            currentPage: 0,
            layoutTrailingPageIndex: nil,
            layoutVisiblePageCount: nil
        ).resolvedGraph

        XCTAssertEqual(resolved.spreadSequence.nodes.map(\.spreadIndex), [0, 1, 2])
        XCTAssertEqual(resolved.spreadSequence.nodes.map(\.pageIndices), [[0], [1, 2], [3, 4]])
        XCTAssertEqual(resolved.spreadSequence.current?.spreadIndex, 0)
        XCTAssertEqual(resolved.spreadSequence.forward?.spreadIndex, 1)
    }

    func testResolvedGraphRelativeSpreadOffsetFallsBackToPageIndicesWithoutSpreadMetadata() {
        let baseline = ReaderPageTurnSpreadGraph(
            currentSpread: nil,
            destinationSpread: nil,
            pageOffsetsDisplayed: [4, 5],
            pageCount: 20,
            layoutLeadingPageIndex: 4,
            currentPage: 4,
            layoutTrailingPageIndex: 5,
            layoutVisiblePageCount: 2
        ).resolvedGraph

        let after = ReaderPageTurnSpreadGraph(
            currentSpread: nil,
            destinationSpread: nil,
            pageOffsetsDisplayed: [6, 7],
            pageCount: 20,
            layoutLeadingPageIndex: 6,
            currentPage: 6,
            layoutTrailingPageIndex: 7,
            layoutVisiblePageCount: 2
        ).resolvedGraph

        XCTAssertEqual(after.relativeSpreadOffset(comparedTo: baseline), 1)
        XCTAssertEqual(after.resolvedNavigationEventKind(comparedTo: baseline, direction: .backward), .nextPage)
    }

    func testResolvedGraphUsesSpreadAwareSemanticsForMultiPageVisibleRange() {
        let resolved = ReaderPageTurnSpreadGraph(
            currentSpread: nil,
            destinationSpread: nil,
            pageOffsetsDisplayed: [6, 7],
            pageCount: 20,
            layoutLeadingPageIndex: 6,
            currentPage: 6,
            layoutTrailingPageIndex: 7,
            layoutVisiblePageCount: 2
        ).resolvedGraph

        XCTAssertTrue(resolved.usesSpreadAwareNavigationSemantics)
    }

    func testResolvedGraphUsesSpreadAwareSemanticsForSingletonCurrentSpread() {
        let resolved = ReaderPageTurnSpreadGraph(
            currentSpread: WebViewPaginationSpread(
                index: 0,
                slots: [
                    .init(kind: .blank),
                    .init(kind: .page, pageIndex: 0),
                ]
            ),
            destinationSpread: nil,
            pageOffsetsDisplayed: nil,
            pageCount: 20,
            layoutLeadingPageIndex: nil,
            currentPage: 0,
            layoutTrailingPageIndex: nil,
            layoutVisiblePageCount: nil
        ).resolvedGraph

        XCTAssertTrue(resolved.usesSpreadAwareNavigationSemantics)
    }

    func testResolvedRelativePageIndicesHandlesSingletonEdges() {
        XCTAssertEqual(
            readerResolvedRelativePageIndices(currentPageIndices: [0], relativeOffset: 1, pageCount: 5, preferredPageSpan: 2),
            [1, 2]
        )
        XCTAssertEqual(
            readerResolvedRelativePageIndices(currentPageIndices: [3, 4], relativeOffset: 1, pageCount: 5, preferredPageSpan: 2),
            nil
        )
        XCTAssertEqual(
            readerResolvedRelativePageIndices(currentPageIndices: [1, 2], relativeOffset: -1, pageCount: 5, preferredPageSpan: 2),
            [0]
        )
    }
}
