import SwiftUIPageTurn
import SwiftUIWebView

public struct ReaderResolvedSpreadStep: Equatable {
    let currentPageIndices: [Int]
    let destinationPageIndices: [Int]?
    let destinationSpread: WebViewPaginationSpread?
}

public struct ReaderResolvedSpreadNode: Equatable {
    public enum Kind: Equatable {
        case current
        case backward(Int)
        case forward(Int)
    }

    let kind: Kind
    let spreadIndex: Int?
    let pageIndices: [Int]
    let spread: WebViewPaginationSpread
}

public struct ReaderResolvedSpreadSequence: Equatable {
    let nodes: [ReaderResolvedSpreadNode]
    let currentIndex: Int?

    init(nodes: [ReaderResolvedSpreadNode], currentIndex: Int?) {
        self.nodes = nodes
        self.currentIndex = currentIndex
    }

    init(
        current: ReaderResolvedSpreadNode?,
        backward: ReaderResolvedSpreadNode?,
        forward: ReaderResolvedSpreadNode?
    ) {
        var nodes: [ReaderResolvedSpreadNode] = []
        if let backward { nodes.append(backward) }
        let currentIndex = current.map { _ in nodes.count }
        if let current { nodes.append(current) }
        if let forward { nodes.append(forward) }
        self.nodes = nodes
        self.currentIndex = currentIndex
    }

    var current: ReaderResolvedSpreadNode? {
        guard let currentIndex, nodes.indices.contains(currentIndex) else { return nil }
        return nodes[currentIndex]
    }

    var backward: ReaderResolvedSpreadNode? {
        guard let currentIndex else { return nil }
        let index = currentIndex - 1
        guard nodes.indices.contains(index) else { return nil }
        return nodes[index]
    }

    var forward: ReaderResolvedSpreadNode? {
        guard let currentIndex else { return nil }
        let index = currentIndex + 1
        guard nodes.indices.contains(index) else { return nil }
        return nodes[index]
    }

    func node(for direction: PageTurnDirection) -> ReaderResolvedSpreadNode? {
        switch direction {
        case .forward:
            return forward
        case .backward:
            return backward
        }
    }

    func node(relativeOffset: Int) -> ReaderResolvedSpreadNode? {
        guard let currentIndex else { return nil }
        let index = currentIndex + relativeOffset
        guard nodes.indices.contains(index) else { return nil }
        return nodes[index]
    }

    func index(matchingSpreadIndex spreadIndex: Int?, pageIndices: [Int]?) -> Int? {
        if let spreadIndex,
           let index = nodes.firstIndex(where: { $0.spreadIndex == spreadIndex }) {
            return index
        }
        if let pageIndices,
           let index = nodes.firstIndex(where: { $0.pageIndices == pageIndices }) {
            return index
        }
        return nil
    }

    func relativeOffset(toSpreadIndex spreadIndex: Int?, pageIndices: [Int]?) -> Int? {
        guard let currentIndex,
              let targetIndex = index(matchingSpreadIndex: spreadIndex, pageIndices: pageIndices) else {
            return nil
        }
        let relativeOffset = targetIndex - currentIndex
        return relativeOffset == 0 ? nil : relativeOffset
    }
}

public struct ReaderPageTurnMovementGraph: Equatable {
    let spreadGraph: ReaderPageTurnSpreadGraph
    let forwardStep: ReaderResolvedSpreadStep?
    let backwardStep: ReaderResolvedSpreadStep?

    init(spreadGraph: ReaderPageTurnSpreadGraph) {
        self.spreadGraph = spreadGraph
        self.forwardStep = spreadGraph.step(for: .forward)
        self.backwardStep = spreadGraph.step(for: .backward)
    }

    func step(for direction: PageTurnDirection) -> ReaderResolvedSpreadStep? {
        switch direction {
        case .forward:
            return forwardStep
        case .backward:
            return backwardStep
        }
    }

    func destinationAvailability(for direction: PageTurnDirection) -> PageTurnDestinationAvailability {
        guard let step = step(for: direction) else {
            return .unavailable
        }
        return readerResolvedDestinationAvailability(spreadStep: step, pageCount: spreadGraph.pageCount)
    }

    var canMoveForward: Bool {
        destinationAvailability(for: .forward) != .unavailable
    }

    var canMoveBackward: Bool {
        destinationAvailability(for: .backward) != .unavailable
    }
}

public struct ReaderPageTurnResolvedGraph: Equatable {
    let spreadGraph: ReaderPageTurnSpreadGraph
    let movementGraph: ReaderPageTurnMovementGraph
    let spreadSequence: ReaderResolvedSpreadSequence
    let currentVisiblePageIndices: [Int]?
    let currentPageIndex: Int?
    let visiblePageCount: Int
    let pageOffsetRange: WebViewPaginationPageOffsetRange?
    let currentContentLocation: PageTurnCurrentContentLocation
    let forwardDestinationAvailability: PageTurnDestinationAvailability
    let backwardDestinationAvailability: PageTurnDestinationAvailability

    init(
        spreadGraph: ReaderPageTurnSpreadGraph,
        runtimeSpreadSequence: WebViewPaginationSpreadSequence? = nil
    ) {
        self.spreadGraph = spreadGraph
        self.movementGraph = spreadGraph.movementGraph
        let fallbackSequence = readerResolvedSpreadSequence(
            currentPageIndices: spreadGraph.currentVisiblePageIndices,
            currentSpread: spreadGraph.currentSpread,
            pageCount: spreadGraph.pageCount,
            backwardStep: movementGraph.backwardStep,
            forwardStep: movementGraph.forwardStep
        )
        let resolvedSequence = readerResolvedSpreadSequence(runtimeSpreadSequence: runtimeSpreadSequence) ?? fallbackSequence
        self.spreadSequence = resolvedSequence
        self.currentVisiblePageIndices = resolvedSequence.current?.pageIndices ?? spreadGraph.currentVisiblePageIndices
        self.currentPageIndex = resolvedSequence.current?.pageIndices.first ?? spreadGraph.currentPageIndex
        self.visiblePageCount = resolvedSequence.current?.pageIndices.count ?? spreadGraph.visiblePageCount
        if let currentVisiblePageIndices,
           let lowerBound = currentVisiblePageIndices.min(),
           let upperBound = currentVisiblePageIndices.max() {
            self.pageOffsetRange = WebViewPaginationPageOffsetRange(lowerBound: lowerBound, upperBound: upperBound)
        } else {
            self.pageOffsetRange = spreadGraph.pageOffsetRange
        }
        self.currentContentLocation = (currentVisiblePageIndices?.count ?? 0) > 1 ? .center : spreadGraph.currentContentLocation
        let forwardAvailabilityFallback: PageTurnDestinationAvailability =
            runtimeSpreadSequence == nil ? movementGraph.destinationAvailability(for: .forward) : .unavailable
        let backwardAvailabilityFallback: PageTurnDestinationAvailability =
            runtimeSpreadSequence == nil ? movementGraph.destinationAvailability(for: .backward) : .unavailable
        if runtimeSpreadSequence != nil, resolvedSequence.forward == nil {
            self.forwardDestinationAvailability = .unavailable
        } else {
            self.forwardDestinationAvailability = readerResolvedDestinationAvailability(
                spread: resolvedSequence.forward?.spread,
                pageCount: spreadGraph.pageCount,
                fallback: forwardAvailabilityFallback
            )
        }
        if runtimeSpreadSequence != nil, resolvedSequence.backward == nil {
            self.backwardDestinationAvailability = .unavailable
        } else {
            self.backwardDestinationAvailability = readerResolvedDestinationAvailability(
                spread: resolvedSequence.backward?.spread,
                pageCount: spreadGraph.pageCount,
                fallback: backwardAvailabilityFallback
            )
        }
    }

    func destinationPageIndices(for direction: PageTurnDirection) -> [Int]? {
        spreadSequence.node(for: direction)?.pageIndices
    }

    func destinationAvailability(for direction: PageTurnDirection) -> PageTurnDestinationAvailability {
        switch direction {
        case .forward:
            return forwardDestinationAvailability
        case .backward:
            return backwardDestinationAvailability
        }
    }

    var canMoveForward: Bool {
        forwardDestinationAvailability != .unavailable
    }

    var canMoveBackward: Bool {
        backwardDestinationAvailability != .unavailable
    }

    var usesSpreadAwareNavigationSemantics: Bool {
        (currentVisiblePageIndices?.count ?? 0) > 1
            || spreadGraph.currentSpread != nil
    }

    func contains(_ requestedLocation: ReaderPageTurnRequestedLocationState, currentSectionHref: String?) -> Bool {
        spreadGraph.contains(requestedLocation, currentSectionHref: currentSectionHref)
    }

    func hasMeaningfulNavigationChange(comparedTo baseline: Self) -> Bool {
        spreadGraph.hasMeaningfulNavigationChange(comparedTo: baseline.spreadGraph)
    }

    func relativeSpreadOffset(comparedTo baseline: Self) -> Int? {
        if let baselineRelativeOffset = baseline.spreadSequence.relativeOffset(
            toSpreadIndex: spreadSequence.current?.spreadIndex,
            pageIndices: currentVisiblePageIndices
        ) {
            return baselineRelativeOffset
        }

        if let currentRelativeOffset = spreadSequence.relativeOffset(
            toSpreadIndex: baseline.spreadSequence.current?.spreadIndex,
            pageIndices: baseline.currentVisiblePageIndices
        ) {
            return -currentRelativeOffset
        }

        return nil
    }

    func resolvedNavigationEventKind(
        comparedTo baseline: Self,
        direction: PageTurnDirection
    ) -> ReaderPageTurnNavigationEventKind {
        if let relativeOffset = relativeSpreadOffset(comparedTo: baseline) {
            return relativeOffset > 0 ? .nextPage : .previousPage
        }
        return spreadGraph.resolvedNavigationEventKind(comparedTo: baseline.spreadGraph, direction: direction)
    }
}

func readerResolvedRelativePageIndices(
    currentPageIndices: [Int],
    relativeOffset: Int,
    pageCount: Int?,
    preferredPageSpan: Int? = nil
) -> [Int]? {
    guard !currentPageIndices.isEmpty, relativeOffset != 0 else {
        return relativeOffset == 0 ? currentPageIndices : nil
    }
    let totalPages = pageCount ?? 0
    guard totalPages > 0 else { return nil }

    let pageSpan = max(1, preferredPageSpan ?? currentPageIndices.count)
    let leading = currentPageIndices.first ?? 0
    let trailing = currentPageIndices.last ?? leading

    if relativeOffset > 0 {
        let targetLeading = trailing + 1 + ((relativeOffset - 1) * pageSpan)
        guard targetLeading < totalPages else { return nil }
        let targetTrailing = min(totalPages - 1, targetLeading + pageSpan - 1)
        return targetTrailing > targetLeading ? [targetLeading, targetTrailing] : [targetLeading]
    } else {
        let magnitude = abs(relativeOffset)
        let targetTrailing = leading - 1 - ((magnitude - 1) * pageSpan)
        guard targetTrailing >= 0 else { return nil }
        let targetLeading = max(0, targetTrailing - (pageSpan - 1))
        return targetTrailing > targetLeading ? [targetLeading, targetTrailing] : [targetTrailing]
    }
}

func readerResolvedSpreadSequence(
    runtimeSpreadSequence: WebViewPaginationSpreadSequence?
) -> ReaderResolvedSpreadSequence? {
    guard let runtimeSpreadSequence, !runtimeSpreadSequence.spreads.isEmpty else {
        return nil
    }
    let nodes = runtimeSpreadSequence.spreads.enumerated().map { index, spread in
        let kind: ReaderResolvedSpreadNode.Kind
        if index == runtimeSpreadSequence.currentIndex {
            kind = .current
        } else if let currentIndex = runtimeSpreadSequence.currentIndex, index < currentIndex {
            kind = .backward(currentIndex - index)
        } else if let currentIndex = runtimeSpreadSequence.currentIndex, index > currentIndex {
            kind = .forward(index - currentIndex)
        } else {
            kind = .current
        }
        return ReaderResolvedSpreadNode(
            kind: kind,
            spreadIndex: spread.index,
            pageIndices: spread.pageIndices,
            spread: spread
        )
    }
    return ReaderResolvedSpreadSequence(
        nodes: nodes,
        currentIndex: runtimeSpreadSequence.currentIndex
    )
}

func readerResolvedSpreadSequence(
    currentPageIndices: [Int]?,
    currentSpread: WebViewPaginationSpread?,
    pageCount: Int?,
    backwardStep: ReaderResolvedSpreadStep?,
    forwardStep: ReaderResolvedSpreadStep?
) -> ReaderResolvedSpreadSequence {
    guard let currentPageIndices else {
        return ReaderResolvedSpreadSequence(current: nil, backward: nil, forward: nil)
    }

    let currentNode = ReaderResolvedSpreadNode(
        kind: .current,
        spreadIndex: currentSpread?.index ?? readerSyntheticSpreadIndex(
            pageIndices: currentPageIndices,
            pageCount: pageCount
        ),
        pageIndices: currentPageIndices,
        spread: currentSpread ?? readerSyntheticSpread(
            spreadIndex: currentSpread?.index ?? readerSyntheticSpreadIndex(
                pageIndices: currentPageIndices,
                pageCount: pageCount
            ),
            pageIndices: currentPageIndices,
            pageCount: pageCount
        )
    )
    let syntheticPageSpan = max(
        currentPageIndices.count,
        currentSpread?.pageIndices.count ?? 0,
        backwardStep?.destinationPageIndices?.count ?? 0,
        forwardStep?.destinationPageIndices?.count ?? 0
    )

    var backwardNodes: [ReaderResolvedSpreadNode] = []
    var backwardMagnitude = 1
    while true {
        let pageIndices: [Int]?
        let spread: WebViewPaginationSpread?
        if backwardMagnitude == 1,
           let backwardStep,
           let destinationPageIndices = backwardStep.destinationPageIndices {
            pageIndices = destinationPageIndices
            spread = backwardStep.destinationSpread
        } else {
            pageIndices = readerResolvedRelativePageIndices(
                currentPageIndices: currentPageIndices,
                relativeOffset: -backwardMagnitude,
                pageCount: pageCount,
                preferredPageSpan: syntheticPageSpan
            )
            spread = nil
        }
        guard let pageIndices else { break }
        backwardNodes.insert(
            .init(
                kind: .backward(backwardMagnitude),
                spreadIndex: spread?.index
                    ?? currentSpread?.index.map { $0 - backwardMagnitude }
                    ?? readerSyntheticSpreadIndex(pageIndices: pageIndices, pageCount: pageCount),
                pageIndices: pageIndices,
                spread: spread ?? readerSyntheticSpread(
                    spreadIndex: currentSpread?.index.map { $0 - backwardMagnitude }
                        ?? readerSyntheticSpreadIndex(pageIndices: pageIndices, pageCount: pageCount),
                    pageIndices: pageIndices,
                    pageCount: pageCount
                )
            ),
            at: 0
        )
        backwardMagnitude += 1
    }

    var forwardNodes: [ReaderResolvedSpreadNode] = []
    var forwardMagnitude = 1
    while true {
        let pageIndices: [Int]?
        let spread: WebViewPaginationSpread?
        if forwardMagnitude == 1,
           let forwardStep,
           let destinationPageIndices = forwardStep.destinationPageIndices {
            pageIndices = destinationPageIndices
            spread = forwardStep.destinationSpread
        } else {
            pageIndices = readerResolvedRelativePageIndices(
                currentPageIndices: currentPageIndices,
                relativeOffset: forwardMagnitude,
                pageCount: pageCount,
                preferredPageSpan: syntheticPageSpan
            )
            spread = nil
        }
        guard let pageIndices else { break }
        forwardNodes.append(
            .init(
                kind: .forward(forwardMagnitude),
                spreadIndex: spread?.index
                    ?? currentSpread?.index.map { $0 + forwardMagnitude }
                    ?? readerSyntheticSpreadIndex(pageIndices: pageIndices, pageCount: pageCount),
                pageIndices: pageIndices,
                spread: spread ?? readerSyntheticSpread(
                    spreadIndex: currentSpread?.index.map { $0 + forwardMagnitude }
                        ?? readerSyntheticSpreadIndex(pageIndices: pageIndices, pageCount: pageCount),
                    pageIndices: pageIndices,
                    pageCount: pageCount
                )
            )
        )
        forwardMagnitude += 1
    }

    let nodes = backwardNodes + [currentNode] + forwardNodes
    return ReaderResolvedSpreadSequence(
        nodes: nodes,
        currentIndex: backwardNodes.count
    )
}

func readerResolvedDestinationAvailability(
    spread: WebViewPaginationSpread?,
    pageCount: Int?,
    fallback: PageTurnDestinationAvailability
) -> PageTurnDestinationAvailability {
    guard let spread else { return fallback }
    let step = ReaderResolvedSpreadStep(
        currentPageIndices: [],
        destinationPageIndices: spread.pageIndices,
        destinationSpread: spread
    )
    let resolved = readerResolvedDestinationAvailability(spreadStep: step, pageCount: pageCount)
    return resolved == .unavailable ? fallback : resolved
}

func readerSyntheticSpreadIndex(
    pageIndices: [Int],
    pageCount: Int?
) -> Int? {
    guard let leadingPageIndex = pageIndices.first else { return nil }
    if leadingPageIndex == 0 {
        return 0
    }
    if let pageCount,
       let trailingPageIndex = pageIndices.last,
       trailingPageIndex == max(0, pageCount - 1),
       pageIndices.count == 1 {
        return leadingPageIndex / 2
    }
    return (leadingPageIndex + 1) / 2
}

func readerSyntheticSpread(
    spreadIndex: Int?,
    pageIndices: [Int],
    pageCount: Int?
) -> WebViewPaginationSpread {
    let slots: [WebViewPaginationSpreadSlot]
    switch pageIndices.count {
    case 0:
        slots = []
    case 1:
        let pageIndex = pageIndices[0]
        if pageIndex == 0 {
            slots = [
                .init(kind: .blank),
                .init(kind: .page, pageIndex: pageIndex),
            ]
        } else if let pageCount, pageIndex == max(0, pageCount - 1) {
            slots = [
                .init(kind: .page, pageIndex: pageIndex),
                .init(kind: .blank),
            ]
        } else {
            slots = [
                .init(kind: .page, pageIndex: pageIndex),
            ]
        }
    default:
        slots = pageIndices.map { .init(kind: .page, pageIndex: $0) }
    }
    return WebViewPaginationSpread(index: spreadIndex, slots: slots)
}

struct ReaderPageTurnSpreadGraph: Equatable {
    let currentSpread: WebViewPaginationSpread?
    let destinationSpread: WebViewPaginationSpread?
    let pageOffsetsDisplayed: [Int]?
    let pageCount: Int?
    let layoutLeadingPageIndex: Int?
    let currentPage: Int?
    let layoutTrailingPageIndex: Int?
    let layoutVisiblePageCount: Int?

    var currentVisiblePageIndices: [Int]? {
        readerNormalizedVisiblePageIndices(
            currentSpread: currentSpread,
            pageOffsetsDisplayed: pageOffsetsDisplayed,
            pageCount: pageCount,
            layoutLeadingPageIndex: layoutLeadingPageIndex,
            currentPage: currentPage,
            layoutTrailingPageIndex: layoutTrailingPageIndex,
            layoutVisiblePageCount: layoutVisiblePageCount
        )
    }

    var currentPageIndex: Int? {
        currentVisiblePageIndices?.first ?? currentPage
    }

    var visiblePageCount: Int {
        currentVisiblePageIndices?.count ?? 0
    }

    var pageOffsetRange: WebViewPaginationPageOffsetRange? {
        guard let currentVisiblePageIndices,
              let lowerBound = currentVisiblePageIndices.min(),
              let upperBound = currentVisiblePageIndices.max() else {
            return nil
        }
        return WebViewPaginationPageOffsetRange(lowerBound: lowerBound, upperBound: upperBound)
    }

    var currentContentLocation: PageTurnCurrentContentLocation {
        if visiblePageCount > 1 {
            return .center
        }
        if currentSpread?.slots.first?.kind == .blank {
            return .trailing
        }
        return .leading
    }

    var movementGraph: ReaderPageTurnMovementGraph {
        ReaderPageTurnMovementGraph(spreadGraph: self)
    }

    var resolvedGraph: ReaderPageTurnResolvedGraph {
        ReaderPageTurnResolvedGraph(spreadGraph: self)
    }

    func resolvedGraph(runtimeSpreadSequence: WebViewPaginationSpreadSequence?) -> ReaderPageTurnResolvedGraph {
        ReaderPageTurnResolvedGraph(
            spreadGraph: self,
            runtimeSpreadSequence: runtimeSpreadSequence
        )
    }

    func hasMeaningfulNavigationChange(comparedTo baseline: Self) -> Bool {
        currentVisiblePageIndices != baseline.currentVisiblePageIndices
            || currentPageIndex != baseline.currentPageIndex
            || pageOffsetRange != baseline.pageOffsetRange
    }

    func resolvedNavigationEventKind(
        comparedTo baseline: Self,
        direction: PageTurnDirection
    ) -> ReaderPageTurnNavigationEventKind {
        guard hasMeaningfulNavigationChange(comparedTo: baseline) else {
            return .noPageChange
        }
        switch direction {
        case .forward:
            return .nextPage
        case .backward:
            return .previousPage
        }
    }

    func step(for direction: PageTurnDirection) -> ReaderResolvedSpreadStep? {
        readerResolvedSpreadStep(
            direction: direction,
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

    func destinationPageIndices(for direction: PageTurnDirection) -> [Int]? {
        step(for: direction)?.destinationPageIndices
    }

    func destinationAvailability(for direction: PageTurnDirection) -> PageTurnDestinationAvailability {
        movementGraph.destinationAvailability(for: direction)
    }

    func contains(_ requestedLocation: ReaderPageTurnRequestedLocationState, currentSectionHref: String?) -> Bool {
        let visiblePageIndices = currentVisiblePageIndices ?? [currentPage].compactMap { $0 }
        switch requestedLocation.kind {
        case PageTurnRequestedLocationKind.pageNumber.rawValue:
            guard let requestedPageNumber = Int(requestedLocation.value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return false
            }
            return visiblePageIndices.contains(max(0, requestedPageNumber - 1))

        case PageTurnRequestedLocationKind.href.rawValue:
            let requestedHref = requestedLocation.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let currentHref = currentSectionHref?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !requestedHref.isEmpty && requestedHref == currentHref

        case PageTurnRequestedLocationKind.progress.rawValue:
            guard let requestedProgress = Double(requestedLocation.value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return false
            }
            let currentLeadingPageIndex = visiblePageIndices.min() ?? currentPage
            return requestedProgress <= 0 && currentLeadingPageIndex == 0

        default:
            return false
        }
    }
}

func readerResolvedSpreadPageIndices(_ spread: WebViewPaginationSpread?) -> [Int]? {
    guard let spread else { return nil }
    let indices = spread.pageIndices
    return indices.isEmpty ? nil : indices
}

func readerResolvedDestinationSpreadPageIndices(
    direction: PageTurnDirection,
    currentSpread: WebViewPaginationSpread?,
    destinationSpread: WebViewPaginationSpread?,
    currentVisiblePageIndices: [Int]?
) -> [Int]? {
    guard let destinationIndices = readerResolvedSpreadPageIndices(destinationSpread) else {
        return nil
    }

    if let currentSpread,
       let destinationSpread,
       let currentSpreadIndex = currentSpread.index,
       let destinationSpreadIndex = destinationSpread.index {
        switch direction {
        case .forward where destinationSpreadIndex > currentSpreadIndex:
            return destinationIndices
        case .backward where destinationSpreadIndex < currentSpreadIndex:
            return destinationIndices
        default:
            break
        }
    }

    if let currentVisiblePageIndices,
       let currentLeading = currentVisiblePageIndices.first,
       let currentTrailing = currentVisiblePageIndices.last,
       let destinationLeading = destinationIndices.first,
       let destinationTrailing = destinationIndices.last {
        switch direction {
        case .forward where destinationLeading > currentTrailing:
            return destinationIndices
        case .backward where destinationTrailing < currentLeading:
            return destinationIndices
        default:
            break
        }
    } else {
        return destinationIndices
    }

    return nil
}

func readerNormalizedVisiblePageIndices(
    currentSpread: WebViewPaginationSpread?,
    pageOffsetsDisplayed: [Int]?,
    pageCount: Int?,
    layoutLeadingPageIndex: Int?,
    currentPage: Int?,
    layoutTrailingPageIndex: Int?,
    layoutVisiblePageCount: Int?
) -> [Int]? {
    if let spreadIndices = readerResolvedSpreadPageIndices(currentSpread) {
        let leading = spreadIndices.first ?? 0
        let trailing = spreadIndices.last ?? leading
        return trailing > leading ? [leading, trailing] : [leading]
    }

    if let pageOffsetsDisplayed, !pageOffsetsDisplayed.isEmpty {
        let leading = pageOffsetsDisplayed.first ?? 0
        let trailing = pageOffsetsDisplayed.last ?? leading
        return trailing > leading ? [leading, trailing] : [leading]
    }

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
    return trailing > leading ? [leading, trailing] : [leading]
}

func readerResolvedSpreadStep(
    direction: PageTurnDirection,
    currentSpread: WebViewPaginationSpread?,
    destinationSpread: WebViewPaginationSpread?,
    pageOffsetsDisplayed: [Int]?,
    pageCount: Int?,
    layoutLeadingPageIndex: Int?,
    currentPage: Int?,
    layoutTrailingPageIndex: Int?,
    layoutVisiblePageCount: Int?
) -> ReaderResolvedSpreadStep? {
    guard let currentPageIndices = readerNormalizedVisiblePageIndices(
        currentSpread: currentSpread,
        pageOffsetsDisplayed: pageOffsetsDisplayed,
        pageCount: pageCount,
        layoutLeadingPageIndex: layoutLeadingPageIndex,
        currentPage: currentPage,
        layoutTrailingPageIndex: layoutTrailingPageIndex,
        layoutVisiblePageCount: layoutVisiblePageCount
    ) else {
        return nil
    }

    let totalPages = pageCount ?? 0
    guard totalPages > 0 else {
        return ReaderResolvedSpreadStep(
            currentPageIndices: currentPageIndices,
            destinationPageIndices: nil,
            destinationSpread: nil
        )
    }

    if let destinationIndices = readerResolvedDestinationSpreadPageIndices(
        direction: direction,
        currentSpread: currentSpread,
        destinationSpread: destinationSpread,
        currentVisiblePageIndices: currentPageIndices
    ) {
        return ReaderResolvedSpreadStep(
            currentPageIndices: currentPageIndices,
            destinationPageIndices: destinationIndices,
            destinationSpread: destinationSpread
        )
    }

    let leading = currentPageIndices.first ?? 0
    let trailing = currentPageIndices.last ?? leading
    let destinationPageIndices: [Int]?
    switch direction {
    case .forward:
        let targetLeading = trailing + 1
        guard targetLeading < totalPages else { return nil }
        if targetLeading == totalPages - 1 {
            destinationPageIndices = [targetLeading]
        } else {
            destinationPageIndices = [targetLeading, min(totalPages - 1, targetLeading + 1)]
        }
    case .backward:
        let targetTrailing = leading - 1
        guard targetTrailing >= 0 else { return nil }
        if targetTrailing == 0 {
            destinationPageIndices = [0]
        } else {
            destinationPageIndices = [max(0, targetTrailing - 1), targetTrailing]
        }
    }

    return ReaderResolvedSpreadStep(
        currentPageIndices: currentPageIndices,
        destinationPageIndices: destinationPageIndices,
        destinationSpread: nil
    )
}

func readerResolvedDestinationAvailability(
    spreadStep: ReaderResolvedSpreadStep,
    pageCount: Int?
) -> PageTurnDestinationAvailability {
    if let destinationSpread = spreadStep.destinationSpread, destinationSpread.slots.count >= 2 {
        let leadingBlank = destinationSpread.slots.first?.kind == .blank
        let trailingBlank = destinationSpread.slots.last?.kind == .blank
        switch (leadingBlank, trailingBlank) {
        case (true, false):
            return .first
        case (false, true):
            return .second
        default:
            break
        }
    }

    guard let destinationPageIndices = spreadStep.destinationPageIndices else {
        return .unavailable
    }
    if destinationPageIndices.count > 1 {
        return .both
    }
    guard let destinationPageIndex = destinationPageIndices.first else {
        return .unavailable
    }
    if destinationPageIndex == 0 {
        return .first
    }
    if let totalPages = pageCount, destinationPageIndex == max(0, totalPages - 1) {
        return .second
    }
    return .both
}
