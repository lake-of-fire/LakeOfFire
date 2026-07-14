export const LOCKED_PAGE_TURN_DUPLICATE_SUPPRESSION_MS = 180
export const POST_PAGE_TURN_DUPLICATE_SUPPRESSION_MS = 240
export const ENABLE_SINGLE_MEDIA_PAGE_NORMALIZATION = true

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
