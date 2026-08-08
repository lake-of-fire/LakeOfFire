import { explicitRelocateHistoryMutationFromIntent } from './ebook-restore-coordination.js'

export const LOCKED_PAGE_TURN_DUPLICATE_SUPPRESSION_MS = 180
export const POST_PAGE_TURN_DUPLICATE_SUPPRESSION_MS = 240
export const ENABLE_SINGLE_MEDIA_PAGE_NORMALIZATION = true
export const PAGINATOR_LAYOUT_BOOTSTRAP_STYLE_ID = 'mnb-paginator-layout-bootstrap'

export const paginatorDestroyedPageTurnResult = pageTurnAttemptID => ({
    ignored: true,
    moved: false,
    reason: 'paginatorDestroyed',
    ...(typeof pageTurnAttemptID === 'string' && pageTurnAttemptID.length > 0
        ? { pageTurnAttemptID }
        : {}),
})

export const paginatorSupersededNavigationResult = () => ({
    superseded: true,
    moved: false,
    reason: 'paginatorNavigationSuperseded',
})

export const paginatorContentIndex = ({ viewIndex, fallbackIndex } = {}) =>
    Number.isInteger(viewIndex) && viewIndex >= 0 ? viewIndex : fallbackIndex

export const paginatorPageMetricsContextIsCurrent = ({
    lifecycleCurrent = true,
    scheduledIndex,
    currentIndex,
    scheduledViewGeneration,
    currentViewGeneration,
    scheduledMetricsGeneration,
    currentMetricsGeneration,
} = {}) => lifecycleCurrent === true
    && Number.isInteger(scheduledIndex)
    && scheduledIndex === currentIndex
    && Number.isInteger(scheduledViewGeneration)
    && scheduledViewGeneration === currentViewGeneration
    && Number.isInteger(scheduledMetricsGeneration)
    && scheduledMetricsGeneration === currentMetricsGeneration

export const paginatorDeferredCorrectionIsCurrent = ({
    lifecycleCurrent = true,
    sameView = true,
    sameIndex = true,
    scheduledRelocationGeneration,
    currentRelocationGeneration,
} = {}) => lifecycleCurrent === true
    && sameView === true
    && sameIndex === true
    && Number.isInteger(scheduledRelocationGeneration)
    && scheduledRelocationGeneration === currentRelocationGeneration

export const paginatorDirectNavigationRejection = ({
    lifecycleCurrent = true,
    locked = false,
    pageTurnChainActive = false,
    indexValid = true,
    alreadyAtTarget = false,
} = {}) => {
    if (!lifecycleCurrent) return paginatorDestroyedPageTurnResult(null)
    if (locked || pageTurnChainActive) {
        return {
            ignored: true,
            moved: false,
            reason: 'paginatorPageTurnInFlight',
        }
    }
    if (!indexValid) {
        return {
            failed: true,
            moved: false,
            reason: 'invalidPaginatorTarget',
        }
    }
    if (alreadyAtTarget) {
        return {
            ignored: true,
            moved: false,
            targetSatisfied: true,
            reason: 'alreadyAtPaginatorTarget',
        }
    }
    return null
}

export const revealPaginatorDocument = doc => {
    const bootstrapStyle = doc?.getElementById?.(PAGINATOR_LAYOUT_BOOTSTRAP_STYLE_ID)
    if (!bootstrapStyle) return false
    bootstrapStyle.remove()
    return true
}

export const normalizeReaderLoadPath = value => {
    if (value == null) return null
    let path = String(value)
    try {
        path = decodeURIComponent(path)
    } catch (_error) {}
    return path
        .split('#')[0]
        .split('?')[0]
        .replace(/^\.?\//, '')
        .replace(/\/{2,}/g, '/')
}

export const readerLoadPathsMatch = (lhs, rhs) => {
    const left = normalizeReaderLoadPath(lhs)
    const right = normalizeReaderLoadPath(rhs)
    return left != null && right != null && left === right
}

const normalizeFrameDocumentURL = value => {
    if (value == null) return null
    try {
        const url = new URL(String(value))
        url.hash = ''
        return url.href
    } catch (_error) {
        const text = String(value)
        return text ? text.split('#')[0] : null
    }
}

export const frameDocumentMatchesExpectedSource = (loadedHref, expectedHref) => {
    const loaded = normalizeFrameDocumentURL(loadedHref)
    const expected = normalizeFrameDocumentURL(expectedHref)
    return loaded != null && expected != null && loaded === expected
}

export const mapScrolledProgressionRect = ({
    rect,
    viewSize,
    leadingMargin = 0,
    trailingMargin = leadingMargin,
    vertical = false,
    verticalRTL = false,
} = {}) => {
    if (!rect) return { left: 0, right: 0 }
    if (!vertical) {
        return {
            left: Number(rect.top) + leadingMargin,
            right: Number(rect.bottom) + trailingMargin,
        }
    }
    if (verticalRTL) {
        return {
            left: Number(viewSize) - Number(rect.right) - leadingMargin,
            right: Number(viewSize) - Number(rect.left) - trailingMargin,
        }
    }
    return {
        left: Number(rect.left) + leadingMargin,
        right: Number(rect.right) + trailingMargin,
    }
}

export const physicalScrolledOffset = ({
    offset,
    vertical = false,
    verticalRTL = false,
} = {}) => vertical && verticalRTL ? -offset : offset

export const pageOffsetForScrollMode = ({
    size,
    page,
    scrolled = false,
    rtl = false,
} = {}) => Number(size) * (!scrolled && rtl ? -Number(page) : Number(page))

export const preparePaginatorLayoutMeasurement = ({
    top,
    vertical,
    flow,
    invalidateSizes,
    enableColumnizationOptimizations = true,
} = {}) => {
    const usesVerticalPaginatedLayout =
        enableColumnizationOptimizations && vertical === true && flow !== 'scrolled'
    const hadVerticalPaginatedLayout = top?.classList?.contains?.('mnb-vertical-paginated') === true
    if (hadVerticalPaginatedLayout !== usesVerticalPaginatedLayout) {
        top?.classList?.toggle?.('mnb-vertical-paginated', usesVerticalPaginatedLayout)
        invalidateSizes?.()
    }
    return usesVerticalPaginatedLayout
}

export const pageSummaryIsVisiblyBlank = summary =>
    !!summary
    && (summary.textCharCount ?? 0) === 0
    && (summary.mediaCount ?? 0) === 0

export const resolveBlankPageTarget = ({ page, pages, direction = 0, summariesByPage = null } = {}) => {
    if (!Number.isFinite(page) || !Number.isFinite(pages) || !Number.isFinite(direction) || direction === 0) {
        return page
    }
    const minPage = 1
    const maxPage = Math.max(minPage, pages - 2)
    let target = Math.max(minPage, Math.min(maxPage, Math.trunc(page)))
    const step = direction > 0 ? 1 : -1
    const summaryForPage = candidatePage => summariesByPage instanceof Map
        ? (summariesByPage.get(candidatePage) ?? null)
        : (summariesByPage?.[candidatePage] ?? null)
    while (target >= minPage
        && target <= maxPage
        && pageSummaryIsVisiblyBlank(summaryForPage(target))) {
        const nextTarget = target + step
        if (nextTarget < minPage || nextTarget > maxPage) break
        target = nextTarget
    }
    return target
}

export const paginatorRenderSignature = ({ layout, vertical, verticalRTL, rtl }) => JSON.stringify({
    flow: layout?.flow ?? null,
    width: Math.round(Number(layout?.width) || 0),
    height: Math.round(Number(layout?.height) || 0),
    gap: Number((Number(layout?.gap) || 0).toFixed(2)),
    columnWidth: Number((Number(layout?.columnWidth) || 0).toFixed(2)),
    divisor: Number(layout?.divisor) || 0,
    vertical: !!vertical,
    verticalRTL: !!verticalRTL,
    rtl: !!rtl,
    typography: layout?.typographySignature ?? null,
})

export const lockedPageTurnQueueDecision = ({
    pendingQueueAllowed,
    pendingRequestedPage,
    pendingPageCount,
    pendingDirection,
    queuedDirection,
    queuedStep,
    lockedElapsedMs,
    distance,
}) => {
    const sameDirectionAsPending = pendingDirection === queuedDirection
    if (sameDirectionAsPending
        && lockedElapsedMs != null
        && lockedElapsedMs < LOCKED_PAGE_TURN_DUPLICATE_SUPPRESSION_MS
        && distance == null) {
        return { shouldQueue: false, reason: 'pageTurnDuplicateDuringLock' }
    }
    if (!pendingQueueAllowed) return { shouldQueue: false, reason: 'pageTurnQueueOutsideSection' }
    if (!Number.isFinite(pendingRequestedPage)
        || !Number.isFinite(pendingPageCount)
        || !Number.isFinite(queuedStep)) {
        return { shouldQueue: false, reason: 'pageTurnQueueUnknownSection' }
    }
    const projectedQueuedPage = pendingRequestedPage + queuedStep
    const crossesSection = queuedStep < 0
        ? projectedQueuedPage <= 0
        : projectedQueuedPage >= pendingPageCount - 1
    return crossesSection
        ? { shouldQueue: false, reason: 'pageTurnQueueWouldCrossSection', projectedQueuedPage }
        : { shouldQueue: true, reason: 'pageTurnQueueWithinSection', projectedQueuedPage }
}

export const scrolledPageTurnDecision = ({ canScrollWithinSection, adjacentIndex } = {}) => ({
    shouldScrollWithinSection: canScrollWithinSection === true,
    shouldGoToAdjacentSection:
        canScrollWithinSection !== true && Number.isInteger(adjacentIndex),
    isTerminal:
        canScrollWithinSection !== true && !Number.isInteger(adjacentIndex),
})

export const paginatorPageTurnMovementResult = ({
    indexChanged = false,
    pageChanged = false,
    startChanged = false,
    hasComparablePosition = false,
    shouldGoToAdjacentSection = false,
    attemptedMovement = false,
    authoritativeNoMove = false,
    finalMetricsAvailable = true,
} = {}) => {
    if (authoritativeNoMove) return false
    if (
        indexChanged === true
        || pageChanged === true
        || startChanged === true
        || (hasComparablePosition !== true && shouldGoToAdjacentSection === true)
    ) return true
    if (attemptedMovement === true && finalMetricsAvailable !== true) {
        return {
            movementDisposition: 'unknown',
            reason: 'pageTurnFinalMetricsUnavailable',
        }
    }
    return false
}

export const scrolledPageTurnBoundaryDecision = ({
    remainingScrollDistance,
    adjacentIndex,
    boundaryTolerance = 0,
} = {}) => {
    const tolerance = Number.isFinite(boundaryTolerance)
        ? Math.max(0, boundaryTolerance)
        : 0
    const shouldScrollWithinSection = Number.isFinite(remainingScrollDistance)
        && remainingScrollDistance > tolerance
    const shouldGoToAdjacentSection = !shouldScrollWithinSection && adjacentIndex != null
    return {
        shouldScrollWithinSection,
        shouldGoToAdjacentSection,
        terminal: !shouldScrollWithinSection && !shouldGoToAdjacentSection,
    }
}

export const pageTurnBoundaryDecision = ({ currentPage, pageCount, step, adjacentIndex }) => {
    const requestedPage = Number.isFinite(currentPage) && Number.isFinite(step)
        ? currentPage + step
        : null
    const crossesSection = Number.isFinite(requestedPage) && Number.isFinite(pageCount)
        ? (step < 0 ? requestedPage <= 0 : requestedPage >= pageCount - 1)
        : false
    const hasAdjacentSection = adjacentIndex != null
    return {
        requestedPage,
        crossesSection,
        hasAdjacentSection,
        shouldGoToAdjacentSection: crossesSection && hasAdjacentSection,
        shouldScrollWithinSection: !(crossesSection && hasAdjacentSection),
    }
}

export const shouldSuppressPostPageTurnDuplicate = ({
    lastDirection,
    direction,
    distance = null,
    navigationSource = null,
    elapsedMs,
} = {}) => {
    if (distance != null || navigationSource != null) return false
    if (lastDirection == null || direction == null || lastDirection !== direction) return false
    return Number.isFinite(elapsedMs)
        && elapsedMs >= 0
        && elapsedMs < POST_PAGE_TURN_DUPLICATE_SUPPRESSION_MS
}

export const normalizeSingleMediaPageTarget = ({ page, pages, isSingleMedia = false } = {}) => {
    if (!ENABLE_SINGLE_MEDIA_PAGE_NORMALIZATION || !isSingleMedia || !Number.isFinite(page) || pages !== 3) {
        return page
    }
    return 1
}

export const paginatorAnchorForLocalPage = ({ localPage, textPageCount } = {}) => {
    const normalizedTextPageCount = Number.isFinite(textPageCount)
        ? Math.max(1, Math.round(textPageCount))
        : 1
    const normalizedLocalPage = Number.isFinite(localPage)
        ? Math.max(0, Math.round(localPage))
        : 0
    const targetLocalPage = Math.min(normalizedTextPageCount - 1, normalizedLocalPage)
    return normalizedTextPageCount > 1
        ? Math.max(0, Math.min(1, targetLocalPage / (normalizedTextPageCount - 1)))
        : 0
}


export const createForegroundPageTurnRequest = metadata => {
    let responded = false
    let responsePromise = null
    return {
        detail: {
            ...metadata,
            respondWith(value) {
                if (responded) return false
                responded = true
                responsePromise = Promise.resolve(value)
                return true
            },
        },
        response: () => responsePromise,
        responded: () => responded,
    }
}

export const resolvePageTurnQueuePolicy = ({ options = {}, navigationIntent = null } = {}) => ({
    navigationSource: options.navigationSource ?? navigationIntent?.source ?? null,
    pageTurnAttemptID: options.pageTurnAttemptID ?? navigationIntent?.pageTurnAttemptID ?? null,
    rejectRendererQueue:
        options.rejectRendererQueue === true
        || navigationIntent?.rejectRendererQueue === true
        || navigationIntent?.lookupOwnedPageTurn === true
        || navigationIntent?.nativeLookupSuppressionOwned === true,
})

export const displayFailureRollbackDecision = ({
    previousView = null,
    attemptedView = null,
    currentView = null,
} = {}) => {
    const attemptedIsCurrent = attemptedView != null && currentView === attemptedView
    const previousIsCurrent = currentView === previousView
    const ownsCurrentDisplay = attemptedIsCurrent || previousIsCurrent
    return {
        ownsCurrentDisplay,
        nextView: attemptedIsCurrent ? (previousView ?? null) : currentView,
        shouldDiscardAttemptedView:
            ownsCurrentDisplay
            && attemptedView != null
            && attemptedView !== previousView,
    }
}

export const shouldDispatchProgrammaticScrollRelocation = ({
    pageTurnAttemptID = null,
    pageTurnSourceIndex = null,
    afterIndex = null,
    beforeStart = null,
    afterStart = null,
    beforePage = null,
    afterPage = null,
} = {}) => {
    // Non-page-turn callers retain Foliate's existing relocation behavior: an
    // explicit navigation/anchor/snap operation may need to refresh location
    // state even when its requested position resolves to the current one.
    if (typeof pageTurnAttemptID !== 'string' || pageTurnAttemptID.length === 0) {
        return true
    }
    const sectionChanged = Number.isFinite(pageTurnSourceIndex)
        && Number.isFinite(afterIndex)
        && pageTurnSourceIndex !== afterIndex
    const pageChanged = Number.isFinite(beforePage)
        && Number.isFinite(afterPage)
        && beforePage !== afterPage
    const startChanged = Number.isFinite(beforeStart)
        && Number.isFinite(afterStart)
        && Math.abs(afterStart - beforeStart) >= 1
    // A page-turn relocation is the reader's destructive commit receipt. Fail
    // closed unless the measured renderer position actually changed; a desired
    // target or successful property assignment is not proof that WebKit moved.
    return sectionChanged || pageChanged || startChanged
}

export const capturePageTurnRelocationContext = ({
    pageTurnAttemptID = null,
    pageTurnDirection = null,
    pageTurnStep = null,
    pageTurnSourceIndex = null,
    navigationIntent = null,
} = {}) => {
    const historyMutation = explicitRelocateHistoryMutationFromIntent(navigationIntent)
    return Object.freeze({
        pageTurnAttemptID: typeof pageTurnAttemptID === 'string' && pageTurnAttemptID.length > 0
            ? pageTurnAttemptID
            : null,
        pageTurnDirection: pageTurnDirection === 'forward' || pageTurnDirection === 'backward'
            ? pageTurnDirection
            : null,
        pageTurnStep: Number.isFinite(pageTurnStep) ? pageTurnStep : null,
        pageTurnSourceIndex: Number.isFinite(pageTurnSourceIndex) ? pageTurnSourceIndex : null,
        ...(Number.isFinite(navigationIntent?.motionStartedAtMs)
            ? { motionStartedAtMs: navigationIntent.motionStartedAtMs }
            : {}),
        ...(historyMutation
            ? {
                explicitRelocateHistorySource: historyMutation.source,
                explicitRelocateHistoryMutationID: historyMutation.mutationID,
                ...(historyMutation.requestGeneration == null
                    ? {}
                    : {
                        explicitRelocateHistoryRequestGeneration:
                            historyMutation.requestGeneration,
                    }),
            }
            : {}),
    })
}

export const rawScrollRelocationDecision = ({
    record = null,
    scrollProp = null,
    currentStart = null,
} = {}) => {
    if (!record) {
        return { suppressRawRelocate: false, discardRecord: false, relocationContext: null }
    }
    if (record.scrollProp !== scrollProp) {
        return { suppressRawRelocate: false, discardRecord: true, relocationContext: null }
    }
    if (record.active === true) {
        return {
            suppressRawRelocate: true,
            discardRecord: false,
            relocationContext: record.relocationContext ?? null,
        }
    }
    if (!Number.isFinite(currentStart)
        || !Number.isFinite(record.targetStart)
        || Math.abs(currentStart - record.targetStart) >= 1) {
        return { suppressRawRelocate: false, discardRecord: true, relocationContext: null }
    }
    return {
        suppressRawRelocate: true,
        discardRecord: false,
        relocationContext: record.relocationContext ?? null,
    }
}

export const captureRawScrollRelocationSnapshot = ({
    generation = null,
    index = null,
    relocationContext = null,
    motionStartedAtMs = null,
} = {}) => Object.freeze({
    generation,
    index,
    relocationContext,
    motionStartedAtMs: Number.isFinite(motionStartedAtMs) ? motionStartedAtMs : null,
})

export const rawScrollRelocationSnapshotIsCurrent = ({
    snapshot = null,
    generation = null,
    currentIndex = null,
} = {}) => Boolean(
    snapshot
    && Number.isInteger(snapshot.generation)
    && snapshot.generation === generation
    && Number.isInteger(snapshot.index)
    && snapshot.index === currentIndex
)
