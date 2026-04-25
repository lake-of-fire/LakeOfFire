import CoreGraphics
import SwiftUIPageTurn
import SwiftUIWebView
import WebKit

struct ReaderNativePaginationPagePosition {
    let pageIndex: Int
    let pageCount: Int
    let offset: CGPoint
}

enum ReaderNativePaginationAxis {
    case horizontal
    case vertical
}

enum ReaderNativePaginationTurnTarget {
    case page(Int)
    case semanticFallback
    case boundary(Int)
}

enum ReaderNativePaginationSupport {
    static func resolvedPageCount(_ candidates: [Int?]) -> Int? {
        candidates.compactMap { $0 }.filter { $0 > 0 }.max()
    }

    static func turnTarget(
        direction: PageTurnDirection,
        currentPage: Int,
        pageCount: Int,
        canNext: Bool,
        canPrev: Bool
    ) -> ReaderNativePaginationTurnTarget {
        let delta = direction == .forward ? 1 : -1
        let targetPageIndex = max(0, min(pageCount - 1, currentPage + delta))
        guard targetPageIndex != currentPage else {
            if direction == .forward, canNext {
                return .semanticFallback
            }
            if direction == .backward, canPrev {
                return .semanticFallback
            }
            return .boundary(targetPageIndex)
        }
        return .page(targetPageIndex)
    }

    static func canMoveForward(currentPageIndex: Int?, pageCount: Int?, canNext: Bool, fallback: Bool) -> Bool {
        guard let currentPageIndex, let pageCount else { return fallback }
        return currentPageIndex + 1 < pageCount || canNext
    }

    static func canMoveBackward(currentPageIndex: Int?, canPrev: Bool, fallback: Bool) -> Bool {
        guard let currentPageIndex else { return fallback }
        return currentPageIndex > 0 || canPrev
    }

    static func destinationAvailability(
        for direction: PageTurnDirection,
        currentPageIndex: Int?,
        pageCount: Int?,
        canNext: Bool,
        canPrev: Bool,
        fallbackForward: Bool,
        fallbackBackward: Bool
    ) -> String {
        switch direction {
        case .forward:
            return canMoveForward(
                currentPageIndex: currentPageIndex,
                pageCount: pageCount,
                canNext: canNext,
                fallback: fallbackForward
            ) ? "second" : "unavailable"
        case .backward:
            return canMoveBackward(
                currentPageIndex: currentPageIndex,
                canPrev: canPrev,
                fallback: fallbackBackward
            ) ? "first" : "unavailable"
        }
    }

    static func displayLabel(currentPageIndex: Int?, pageCount: Int?) -> String? {
        guard let currentPageIndex, let pageCount, pageCount > 0 else { return nil }
        return "Page \(currentPageIndex + 1) of \(pageCount)"
    }

    static func setPage(
        _ pageIndex: Int,
        pageCount: Int,
        paginationState: WebViewPaginationState,
        navigator: WebViewNavigator,
        reportedCurrentPage: Int?
    ) async -> ReaderNativePaginationPagePosition? {
        #if os(iOS)
        let position = await navigator.withAttachedWebView { webView in
            let scrollView = webView.scrollView
            scrollView.layoutIfNeeded()
            webView.layoutIfNeeded()

            let mode = paginationState.appliedConfiguration?.mode
                ?? paginationState.desiredConfiguration.mode
            let axis: ReaderNativePaginationAxis = switch mode {
            case .topToBottom, .bottomToTop:
                .vertical
            case .leftToRight, .rightToLeft, .unpaginated:
                .horizontal
            }
            let viewportLength = axis == .horizontal
                ? max(1, scrollView.bounds.width)
                : max(1, scrollView.bounds.height)
            let contentLength = axis == .horizontal
                ? max(viewportLength, scrollView.contentSize.width)
                : max(viewportLength, scrollView.contentSize.height)
            let maxOffset = max(0, contentLength - viewportLength)
            let configuredStride = max(
                1,
                (paginationState.appliedConfiguration?.effectivePageLength ?? 0)
                    + (paginationState.appliedConfiguration?.gapBetweenPages ?? paginationState.desiredConfiguration.gapBetweenPages)
            )
            let fittedStride = pageCount > 1 && maxOffset > 0
                ? max(1, maxOffset / CGFloat(pageCount - 1))
                : configuredStride
            let currentOffset = axis == .horizontal
                ? scrollView.contentOffset.x
                : scrollView.contentOffset.y
            let forwardMappedIndex = Int(round(currentOffset / fittedStride))
            let reverseMappedIndex = Int(round((maxOffset - currentOffset) / fittedStride))
            let usesReversePhysicalMapping = reportedCurrentPage == reverseMappedIndex
                && reportedCurrentPage != forwardMappedIndex
            let rawTargetOffset = usesReversePhysicalMapping
                ? maxOffset - (CGFloat(pageIndex) * fittedStride)
                : CGFloat(pageIndex) * fittedStride
            let targetOffset = max(0, min(maxOffset, rawTargetOffset))
            var nextOffset = scrollView.contentOffset
            switch axis {
            case .horizontal:
                nextOffset.x = targetOffset
            case .vertical:
                nextOffset.y = targetOffset
            }
            scrollView.setContentOffset(nextOffset, animated: false)
            scrollView.layoutIfNeeded()
            webView.layoutIfNeeded()
            return ReaderNativePaginationPagePosition(
                pageIndex: pageIndex,
                pageCount: pageCount,
                offset: nextOffset
            )
        }
        return position
        #else
        _ = pageIndex
        _ = pageCount
        _ = paginationState
        _ = navigator
        _ = reportedCurrentPage
        return nil
        #endif
    }
}
