import assert from 'node:assert/strict'
import test from 'node:test'

import {
    LOCKED_PAGE_TURN_DUPLICATE_SUPPRESSION_MS,
    PAGINATOR_LAYOUT_BOOTSTRAP_STYLE_ID,
    capturePageTurnRelocationContext,
    captureRawScrollRelocationSnapshot,
    createForegroundPageTurnRequest,
    displayFailureRollbackDecision,
    frameDocumentMatchesExpectedSource,
    lockedPageTurnQueueDecision,
    mapScrolledProgressionRect,
    normalizeReaderLoadPath,
    normalizeSingleMediaPageTarget,
    pageSummaryIsVisiblyBlank,
    pageOffsetForScrollMode,
    pageTurnBoundaryDecision,
    paginatorAnchorForLocalPage,
    paginatorPageTurnMovementResult,
    paginatorContentIndex,
    paginatorDeferredCorrectionIsCurrent,
    paginatorPageMetricsContextIsCurrent,
    paginatorDestroyedPageTurnResult,
    paginatorDirectNavigationRejection,
    paginatorRenderSignature,
    paginatorSupersededNavigationResult,
    physicalScrolledOffset,
    preparePaginatorLayoutMeasurement,
    rawScrollRelocationDecision,
    rawScrollRelocationSnapshotIsCurrent,
    readerLoadPathsMatch,
    revealPaginatorDocument,
    scrolledPageTurnDecision,
    resolvePageTurnQueuePolicy,
    scrolledPageTurnBoundaryDecision,
    shouldDispatchProgrammaticScrollRelocation,
    shouldSuppressPostPageTurnDuplicate,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/paginator-decisions.js'

test('legacy paginator decision exports retain their safe classification and normalization semantics', () => {
    assert.equal(LOCKED_PAGE_TURN_DUPLICATE_SUPPRESSION_MS, 180)
    assert.equal(PAGINATOR_LAYOUT_BOOTSTRAP_STYLE_ID, 'mnb-paginator-layout-bootstrap')
    assert.equal(normalizeReaderLoadPath('./OPS%2Fchapter.xhtml?query=1#fragment'), 'OPS/chapter.xhtml')
    assert.equal(pageSummaryIsVisiblyBlank({ textCharCount: 0, mediaCount: 0 }), true)
    assert.equal(pageSummaryIsVisiblyBlank({ textCharCount: 1, mediaCount: 0 }), false)
    assert.equal(pageSummaryIsVisiblyBlank(null), false)
})

test('destroyed paginator results terminate queued turns without claiming movement', () => {
    assert.deepEqual(paginatorDestroyedPageTurnResult('attempt-a'), {
        ignored: true,
        moved: false,
        reason: 'paginatorDestroyed',
        pageTurnAttemptID: 'attempt-a',
    })
    assert.deepEqual(paginatorDestroyedPageTurnResult(null), {
        ignored: true,
        moved: false,
        reason: 'paginatorDestroyed',
    })
})

test('superseded paginator navigation has one explicit authoritative receipt', () => {
    assert.deepEqual(paginatorSupersededNavigationResult(), {
        superseded: true,
        moved: false,
        reason: 'paginatorNavigationSuperseded',
    })
})


test('paginator public content identity remains attached to the owned view during a staged section swap', () => {
    assert.equal(paginatorContentIndex({
        viewIndex: 3,
        fallbackIndex: 4,
    }), 3)
    assert.equal(paginatorContentIndex({
        viewIndex: -1,
        fallbackIndex: 4,
    }), 4)
    assert.equal(paginatorContentIndex({
        viewIndex: null,
        fallbackIndex: 4,
    }), 4)
})

test('paginator page metrics publish only for the exact view and invalidation generation', () => {
    const current = {
        lifecycleCurrent: true,
        scheduledIndex: 4,
        currentIndex: 4,
        scheduledViewGeneration: 8,
        currentViewGeneration: 8,
        scheduledMetricsGeneration: 12,
        currentMetricsGeneration: 12,
    }
    assert.equal(paginatorPageMetricsContextIsCurrent(current), true)
    assert.equal(paginatorPageMetricsContextIsCurrent({
        ...current,
        currentIndex: 5,
    }), false)
    assert.equal(paginatorPageMetricsContextIsCurrent({
        ...current,
        currentViewGeneration: 9,
    }), false)
    assert.equal(paginatorPageMetricsContextIsCurrent({
        ...current,
        currentMetricsGeneration: 13,
    }), false)
    assert.equal(paginatorPageMetricsContextIsCurrent({
        ...current,
        lifecycleCurrent: false,
    }), false)
})

test('deferred past-content correction is fenced to the exact navigation generation', () => {
    const current = {
        lifecycleCurrent: true,
        sameView: true,
        sameIndex: true,
        scheduledRelocationGeneration: 7,
        currentRelocationGeneration: 7,
    }
    assert.equal(paginatorDeferredCorrectionIsCurrent(current), true)
    assert.equal(paginatorDeferredCorrectionIsCurrent({
        ...current,
        lifecycleCurrent: false,
    }), false)
    assert.equal(paginatorDeferredCorrectionIsCurrent({
        ...current,
        sameView: false,
    }), false)
    assert.equal(paginatorDeferredCorrectionIsCurrent({
        ...current,
        sameIndex: false,
    }), false)
    assert.equal(paginatorDeferredCorrectionIsCurrent({
        ...current,
        currentRelocationGeneration: 8,
    }), false)
    assert.equal(paginatorDeferredCorrectionIsCurrent({
        ...current,
        scheduledRelocationGeneration: null,
        currentRelocationGeneration: null,
    }), false)
})

test('direct paginator navigation fails explicitly when private turn ownership blocks execution', () => {
    assert.deepEqual(paginatorDirectNavigationRejection({ locked: true }), {
        ignored: true,
        moved: false,
        reason: 'paginatorPageTurnInFlight',
    })
    assert.deepEqual(paginatorDirectNavigationRejection({ pageTurnChainActive: true }), {
        ignored: true,
        moved: false,
        reason: 'paginatorPageTurnInFlight',
    })
    assert.deepEqual(paginatorDirectNavigationRejection({ lifecycleCurrent: false }), {
        ignored: true,
        moved: false,
        reason: 'paginatorDestroyed',
    })
    assert.deepEqual(paginatorDirectNavigationRejection({ indexValid: false }), {
        failed: true,
        moved: false,
        reason: 'invalidPaginatorTarget',
    })
    assert.deepEqual(paginatorDirectNavigationRejection({ alreadyAtTarget: true }), {
        ignored: true,
        moved: false,
        targetSatisfied: true,
        reason: 'alreadyAtPaginatorTarget',
    })
    assert.equal(paginatorDirectNavigationRejection(), null)
})

test('reveals a document by removing its one-shot layout bootstrap', () => {
    let removalCount = 0
    const bootstrap = { remove: () => { removalCount += 1 } }
    const document = {
        getElementById: () => removalCount === 0 ? bootstrap : null,
    }

    assert.equal(revealPaginatorDocument(document), true)
    assert.equal(revealPaginatorDocument(document), false)
    assert.equal(removalCount, 1)
})

test('paginator iframe ownership preserves query identity and ignores fragments', () => {
    const expected = 'ebook://ebook/processed-section?subpath=OPS%2Fchapter-1.xhtml#target'
    assert.equal(frameDocumentMatchesExpectedSource(
        'ebook://ebook/processed-section?subpath=OPS%2Fchapter-1.xhtml#other',
        expected,
    ), true)
    assert.equal(frameDocumentMatchesExpectedSource(
        'ebook://ebook/processed-section?subpath=OPS%2Fchapter-2.xhtml',
        expected,
    ), false)
    assert.equal(frameDocumentMatchesExpectedSource('about:blank', expected), false)
    assert.equal(frameDocumentMatchesExpectedSource(null, expected), false)
})

test('scrolled progression geometry distinguishes vertical-rl from vertical-lr', () => {
    const rect = { left: 120, right: 180, top: 40, bottom: 100 }

    assert.deepEqual(mapScrolledProgressionRect({
        rect,
        viewSize: 1000,
        leadingMargin: 20,
        trailingMargin: 30,
        vertical: true,
        verticalRTL: true,
    }), { left: 800, right: 850 })
    assert.deepEqual(mapScrolledProgressionRect({
        rect,
        viewSize: 1000,
        leadingMargin: 20,
        trailingMargin: 30,
        vertical: true,
        verticalRTL: false,
    }), { left: 140, right: 210 })
    assert.deepEqual(mapScrolledProgressionRect({
        rect,
        viewSize: 1000,
        leadingMargin: 20,
        trailingMargin: 30,
        vertical: false,
        verticalRTL: false,
    }), { left: 60, right: 130 })

    assert.equal(physicalScrolledOffset({
        offset: 250,
        vertical: true,
        verticalRTL: true,
    }), -250)
    assert.equal(physicalScrolledOffset({
        offset: 250,
        vertical: true,
        verticalRTL: false,
    }), 250)
    assert.equal(physicalScrolledOffset({
        offset: 250,
        vertical: false,
        verticalRTL: true,
    }), 250)

    assert.equal(pageOffsetForScrollMode({
        size: 100,
        page: 3,
        scrolled: true,
        rtl: true,
    }), 300)
    assert.equal(pageOffsetForScrollMode({
        size: 100,
        page: 3,
        scrolled: false,
        rtl: true,
    }), -300)
    assert.equal(pageOffsetForScrollMode({
        size: 100,
        page: 3,
        scrolled: false,
        rtl: false,
    }), 300)
})

test('reader-load path matching normalizes encoding, queries, and relative prefixes', () => {
    assert.equal(readerLoadPathsMatch('item/xhtml/p-003.xhtml', 'item/xhtml/p-003.xhtml'), true)
    assert.equal(readerLoadPathsMatch('item%2Fxhtml%2Fp-003.xhtml', 'item/xhtml/p-003.xhtml'), true)
    assert.equal(readerLoadPathsMatch('item/xhtml/p-003.xhtml?cache=1#frag', 'item/xhtml/p-003.xhtml'), true)
    assert.equal(readerLoadPathsMatch('./item/xhtml/p-003.xhtml', 'item/xhtml/p-003.xhtml'), true)
    assert.equal(readerLoadPathsMatch('item/xhtml/p-003.xhtml', 'item/xhtml/p-004.xhtml'), false)
    assert.equal(readerLoadPathsMatch(null, 'item/xhtml/p-003.xhtml'), false)
})

test('vertical paginated layout is applied before measurement and invalidated once', () => {
    const classes = new Set()
    const top = {
        classList: {
            contains: value => classes.has(value),
            toggle(value, enabled) { enabled ? classes.add(value) : classes.delete(value) },
        },
        measuredHeight: () => classes.has('mnb-vertical-paginated') ? 747 : 711,
    }
    let invalidationCount = 0
    const before = top.measuredHeight()
    assert.equal(preparePaginatorLayoutMeasurement({
        top,
        vertical: true,
        flow: null,
        invalidateSizes: () => { invalidationCount += 1 },
    }), true)
    const after = top.measuredHeight()
    preparePaginatorLayoutMeasurement({
        top,
        vertical: true,
        flow: null,
        invalidateSizes: () => { invalidationCount += 1 },
    })

    assert.equal(before, 711)
    assert.equal(after, 747)
    assert.equal(invalidationCount, 1)
    assert.equal(preparePaginatorLayoutMeasurement({ top, vertical: true, flow: 'scrolled' }), false)
})

test('render signatures are stable for identical layout inputs', () => {
    const input = {
        layout: {
            flow: 'paginated', width: 390, height: 844, gap: 12,
            columnWidth: 390, divisor: 1, typographySignature: 'book-css-v1',
        },
        vertical: false,
        rtl: false,
    }
    assert.equal(paginatorRenderSignature(input), paginatorRenderSignature(input))
    assert.notEqual(
        paginatorRenderSignature(input),
        paginatorRenderSignature({ ...input, vertical: true }),
    )
    assert.notEqual(
        paginatorRenderSignature({ ...input, vertical: true, verticalRTL: false }),
        paginatorRenderSignature({ ...input, vertical: true, verticalRTL: true }),
    )
})

test('local anchors round-trip and clamp to available text pages', () => {
    const anchor = paginatorAnchorForLocalPage({ localPage: 1, textPageCount: 236 })
    assert.equal(anchor, 1 / 235)
    assert.equal(paginatorAnchorForLocalPage({ localPage: 999, textPageCount: 236 }), 1)
})

test('locked and boundary decisions do not queue across sections', () => {
    assert.equal(lockedPageTurnQueueDecision({
        pendingQueueAllowed: true,
        pendingRequestedPage: 3,
        pendingPageCount: 5,
        pendingDirection: 'forward',
        queuedDirection: 'forward',
        queuedStep: 1,
        lockedElapsedMs: 400,
        distance: null,
    }).shouldQueue, false)

    const boundary = pageTurnBoundaryDecision({ currentPage: 1, pageCount: 348, step: -1, adjacentIndex: 5 })
    assert.equal(boundary.shouldGoToAdjacentSection, true)
    assert.equal(boundary.shouldScrollWithinSection, false)
})

test('scrolled page turns distinguish within-section movement, adjacent sections, and terminal edges', () => {
    assert.deepEqual(scrolledPageTurnBoundaryDecision({
        remainingScrollDistance: 120,
        adjacentIndex: null,
    }), {
        shouldScrollWithinSection: true,
        shouldGoToAdjacentSection: false,
        terminal: false,
    })
    assert.deepEqual(scrolledPageTurnBoundaryDecision({
        remainingScrollDistance: 0,
        adjacentIndex: 4,
    }), {
        shouldScrollWithinSection: false,
        shouldGoToAdjacentSection: true,
        terminal: false,
    })
    assert.deepEqual(scrolledPageTurnBoundaryDecision({
        remainingScrollDistance: 0,
        adjacentIndex: null,
    }), {
        shouldScrollWithinSection: false,
        shouldGoToAdjacentSection: false,
        terminal: true,
    })
    assert.equal(scrolledPageTurnBoundaryDecision({
        remainingScrollDistance: 1.5,
        adjacentIndex: null,
        boundaryTolerance: 2,
    }).terminal, true)
})

test('single-media and duplicate-turn decisions preserve hotfix policy', () => {
    assert.equal(normalizeSingleMediaPageTarget({ page: 0, pages: 3, isSingleMedia: true }), 1)
    assert.equal(normalizeSingleMediaPageTarget({ page: 2, pages: 5, isSingleMedia: true }), 2)
    assert.equal(shouldSuppressPostPageTurnDuplicate({
        lastDirection: 'backward',
        direction: 'backward',
        elapsedMs: 80,
    }), true)
    assert.equal(shouldSuppressPostPageTurnDuplicate({
        lastDirection: 'backward',
        direction: 'backward',
        navigationSource: 'keyboard',
        elapsedMs: 80,
    }), false)
})


test('scrolled page-turn decisions distinguish internal scroll, adjacent section, and terminal edge', () => {
    assert.deepEqual(scrolledPageTurnDecision({
        canScrollWithinSection: true,
        adjacentIndex: null,
    }), {
        shouldScrollWithinSection: true,
        shouldGoToAdjacentSection: false,
        isTerminal: false,
    })
    assert.deepEqual(scrolledPageTurnDecision({
        canScrollWithinSection: false,
        adjacentIndex: 4,
    }), {
        shouldScrollWithinSection: false,
        shouldGoToAdjacentSection: true,
        isTerminal: false,
    })
    assert.deepEqual(scrolledPageTurnDecision({
        canScrollWithinSection: false,
        adjacentIndex: null,
    }), {
        shouldScrollWithinSection: false,
        shouldGoToAdjacentSection: false,
        isTerminal: true,
    })
})


test('page-turn movement results preserve uncertainty after attempted motion loses final metrics', () => {
    assert.equal(paginatorPageTurnMovementResult({
        indexChanged: true,
        attemptedMovement: true,
        finalMetricsAvailable: false,
    }), true)
    assert.equal(paginatorPageTurnMovementResult({
        pageChanged: true,
        attemptedMovement: true,
        finalMetricsAvailable: true,
    }), true)
    assert.equal(paginatorPageTurnMovementResult({
        startChanged: true,
        attemptedMovement: true,
        finalMetricsAvailable: true,
    }), true)
    assert.equal(paginatorPageTurnMovementResult({
        authoritativeNoMove: true,
        attemptedMovement: false,
        finalMetricsAvailable: false,
    }), false)
    assert.deepEqual(paginatorPageTurnMovementResult({
        attemptedMovement: true,
        hasComparablePosition: true,
        finalMetricsAvailable: false,
    }), {
        movementDisposition: 'unknown',
        reason: 'pageTurnFinalMetricsUnavailable',
    })
    assert.equal(paginatorPageTurnMovementResult({
        attemptedMovement: true,
        hasComparablePosition: true,
        finalMetricsAvailable: true,
    }), false)
})

test('foreground page-turn delegation is claimed once and preserves the delegated result', async () => {
    const request = createForegroundPageTurnRequest({
        method: 'next',
        source: 'paginator.touchmove',
    })

    assert.equal(request.responded(), false)
    assert.equal(request.detail.respondWith(Promise.resolve({ moved: false, ignored: true })), true)
    assert.equal(request.detail.respondWith(Promise.resolve({ moved: true })), false)
    assert.equal(request.responded(), true)
    assert.deepEqual(await request.response(), { moved: false, ignored: true })
})

test('page-turn queue policy is captured from the originating request', () => {
    const policy = resolvePageTurnQueuePolicy({
        options: {
            navigationSource: 'lookup-chevron',
            pageTurnAttemptID: 'attempt-a',
            rejectRendererQueue: true,
        },
        navigationIntent: {
            navigationSource: 'later-global-intent',
            pageTurnAttemptID: 'attempt-b',
            rejectRendererQueue: false,
        },
    })
    assert.deepEqual(policy, {
        navigationSource: 'lookup-chevron',
        pageTurnAttemptID: 'attempt-a',
        rejectRendererQueue: true,
    })
})

test('lookup-owned global intent rejects renderer-private queueing', () => {
    assert.deepEqual(resolvePageTurnQueuePolicy({
        navigationIntent: {
            source: 'lookup-navigation',
            pageTurnAttemptID: 'attempt-a',
            lookupOwnedPageTurn: true,
        },
    }), {
        navigationSource: 'lookup-navigation',
        pageTurnAttemptID: 'attempt-a',
        rejectRendererQueue: true,
    })
})


test('relocation context snapshots do not borrow a later turn identity', () => {
    const mutableTurn = {
        pageTurnAttemptID: 'attempt-a',
        pageTurnDirection: 'forward',
        pageTurnStep: 1,
        pageTurnSourceIndex: 4,
        navigationIntent: {
            explicitRelocateHistorySource: 'goToPercent',
            explicitRelocateHistoryMutationID: 'reader-navigation-7',
            explicitRelocateHistoryRequestGeneration: 7,
            motionStartedAtMs: 1234.5,
        },
    }
    const snapshot = capturePageTurnRelocationContext(mutableTurn)
    mutableTurn.pageTurnAttemptID = 'attempt-b'
    mutableTurn.pageTurnDirection = 'backward'
    mutableTurn.pageTurnStep = -1
    mutableTurn.pageTurnSourceIndex = 9
    mutableTurn.navigationIntent.explicitRelocateHistoryMutationID = 'reader-navigation-8'
    mutableTurn.navigationIntent.explicitRelocateHistoryRequestGeneration = 8
    mutableTurn.navigationIntent.motionStartedAtMs = 2345.5

    assert.deepEqual(snapshot, {
        pageTurnAttemptID: 'attempt-a',
        pageTurnDirection: 'forward',
        pageTurnStep: 1,
        pageTurnSourceIndex: 4,
        motionStartedAtMs: 1234.5,
        explicitRelocateHistorySource: 'goToPercent',
        explicitRelocateHistoryMutationID: 'reader-navigation-7',
        explicitRelocateHistoryRequestGeneration: 7,
    })
    assert.deepEqual(capturePageTurnRelocationContext({
        pageTurnAttemptID: '',
        pageTurnDirection: 'sideways',
        pageTurnStep: Number.NaN,
        pageTurnSourceIndex: Number.NaN,
    }), {
        pageTurnAttemptID: null,
        pageTurnDirection: null,
        pageTurnStep: null,
        pageTurnSourceIndex: null,
    })
    assert.deepEqual(capturePageTurnRelocationContext({
        navigationIntent: {
            explicitRelocateHistorySource: 'partial-only',
        },
    }), {
        pageTurnAttemptID: null,
        pageTurnDirection: null,
        pageTurnStep: null,
        pageTurnSourceIndex: null,
    })
})

test('programmatic raw scroll identity remains relevant until the renderer leaves its settled position', () => {
    const relocationContext = capturePageTurnRelocationContext({
        pageTurnAttemptID: 'attempt-a',
        pageTurnDirection: 'forward',
        pageTurnStep: 1,
        pageTurnSourceIndex: 4,
    })
    const activeRecord = {
        active: true,
        scrollProp: 'scrollLeft',
        targetStart: 400,
        relocationContext,
    }

    assert.equal(rawScrollRelocationDecision({
        record: activeRecord,
        scrollProp: 'scrollLeft',
        currentStart: 120,
    }).relocationContext, relocationContext)

    const settledRecord = { ...activeRecord, active: false }
    assert.equal(rawScrollRelocationDecision({
        record: settledRecord,
        scrollProp: 'scrollLeft',
        currentStart: 400.4,
    }).relocationContext, relocationContext)
    assert.equal(rawScrollRelocationDecision({
        record: settledRecord,
        scrollProp: 'scrollLeft',
        currentStart: 360,
    }).relocationContext, null)
    assert.equal(rawScrollRelocationDecision({
        record: settledRecord,
        scrollProp: 'scrollTop',
        currentStart: 400,
    }).relocationContext, null)
})


test('programmatic raw-scroll echoes are suppressed even without a page-turn owner', () => {
    const ownerlessRecord = {
        active: true,
        scrollProp: 'scrollLeft',
        targetStart: 120,
        relocationContext: null,
    }
    assert.deepEqual(rawScrollRelocationDecision({
        record: ownerlessRecord,
        scrollProp: 'scrollLeft',
        currentStart: 0,
    }), {
        suppressRawRelocate: true,
        discardRecord: false,
        relocationContext: null,
    })

    ownerlessRecord.active = false
    assert.equal(rawScrollRelocationDecision({
        record: ownerlessRecord,
        scrollProp: 'scrollLeft',
        currentStart: 120.2,
    }).suppressRawRelocate, true)

    assert.deepEqual(rawScrollRelocationDecision({
        record: ownerlessRecord,
        scrollProp: 'scrollLeft',
        currentStart: 130,
    }), {
        suppressRawRelocate: false,
        discardRecord: true,
        relocationContext: null,
    })
})


test('failed paginator display restores only the transaction that still owns the active view', () => {
    const previous = { id: 'previous' }
    const attempted = { id: 'attempted' }
    const newer = { id: 'newer' }

    assert.deepEqual(displayFailureRollbackDecision({
        previousView: previous,
        attemptedView: attempted,
        currentView: attempted,
    }), {
        ownsCurrentDisplay: true,
        nextView: previous,
        shouldDiscardAttemptedView: true,
    })
    assert.deepEqual(displayFailureRollbackDecision({
        previousView: null,
        attemptedView: attempted,
        currentView: attempted,
    }), {
        ownsCurrentDisplay: true,
        nextView: null,
        shouldDiscardAttemptedView: true,
    })
    assert.deepEqual(displayFailureRollbackDecision({
        previousView: previous,
        attemptedView: attempted,
        currentView: previous,
    }), {
        ownsCurrentDisplay: true,
        nextView: previous,
        shouldDiscardAttemptedView: true,
    })
    assert.deepEqual(displayFailureRollbackDecision({
        previousView: previous,
        attemptedView: attempted,
        currentView: newer,
    }), {
        ownsCurrentDisplay: false,
        nextView: newer,
        shouldDiscardAttemptedView: false,
    })
})

test('page-turn relocation requires a measured physical scroll commit', () => {
    assert.equal(shouldDispatchProgrammaticScrollRelocation({
        pageTurnAttemptID: 'attempt-a',
        beforeStart: 120,
        afterStart: 120,
        beforePage: 2,
        afterPage: 2,
    }), false)
    assert.equal(shouldDispatchProgrammaticScrollRelocation({
        pageTurnAttemptID: 'attempt-a',
        beforeStart: 120,
        afterStart: 120.4,
        beforePage: 2,
        afterPage: 2,
    }), false)
    assert.equal(shouldDispatchProgrammaticScrollRelocation({
        pageTurnAttemptID: 'attempt-a',
        beforeStart: 120,
        afterStart: 360,
        beforePage: 2,
        afterPage: 3,
    }), true)
    assert.equal(shouldDispatchProgrammaticScrollRelocation({
        pageTurnAttemptID: 'attempt-a',
        beforeStart: 120,
        afterStart: 120,
        beforePage: 2,
        afterPage: 3,
    }), true)
    assert.equal(shouldDispatchProgrammaticScrollRelocation({
        pageTurnAttemptID: 'attempt-a',
        beforeStart: null,
        afterStart: null,
        beforePage: null,
        afterPage: null,
    }), false)
})

test('cross-section page turns commit relocation even when the destination starts at the same local position', () => {
    assert.equal(shouldDispatchProgrammaticScrollRelocation({
        pageTurnAttemptID: 'attempt-a',
        pageTurnSourceIndex: 4,
        afterIndex: 5,
        beforeStart: 100,
        afterStart: 100,
        beforePage: 1,
        afterPage: 1,
    }), true)
})

test('same-section page turns still require measured local movement', () => {
    assert.equal(shouldDispatchProgrammaticScrollRelocation({
        pageTurnAttemptID: 'attempt-a',
        pageTurnSourceIndex: 4,
        afterIndex: 4,
        beforeStart: 100,
        afterStart: 100,
        beforePage: 1,
        afterPage: 1,
    }), false)
})

test('non-page-turn navigation keeps relocation refresh semantics at the same position', () => {
    assert.equal(shouldDispatchProgrammaticScrollRelocation({
        pageTurnAttemptID: null,
        beforeStart: 120,
        afterStart: 120,
        beforePage: 2,
        afterPage: 2,
    }), true)
})

test('clamped programmatic scroll echoes are suppressed at their measured settled position', () => {
    const relocationContext = capturePageTurnRelocationContext({
        pageTurnAttemptID: 'attempt-a',
        pageTurnDirection: 'forward',
        pageTurnStep: 1,
        pageTurnSourceIndex: 4,
    })
    const record = {
        active: false,
        scrollProp: 'scrollLeft',
        // `#finishProgrammaticScrollRelocation` records WebKit's actual position,
        // not the uncommitted requested offset.
        targetStart: 380,
        relocationContext,
    }
    assert.deepEqual(rawScrollRelocationDecision({
        record,
        scrollProp: 'scrollLeft',
        currentStart: 380.2,
    }), {
        suppressRawRelocate: true,
        discardRecord: false,
        relocationContext,
    })
})

test('raw scroll callbacks retain the physical event timestamp with generation and source section', () => {
    const snapshot = captureRawScrollRelocationSnapshot({
        generation: 8,
        index: 3,
        relocationContext: capturePageTurnRelocationContext({}),
        motionStartedAtMs: 1234,
    })
    assert.equal(snapshot.motionStartedAtMs, 1234)
    assert.equal(Object.isFrozen(snapshot), true)
    assert.equal(rawScrollRelocationSnapshotIsCurrent({
        snapshot,
        generation: 8,
        currentIndex: 3,
    }), true)
    assert.equal(rawScrollRelocationSnapshotIsCurrent({
        snapshot,
        generation: 9,
        currentIndex: 3,
    }), false)
    assert.equal(rawScrollRelocationSnapshotIsCurrent({
        snapshot,
        generation: 8,
        currentIndex: 4,
    }), false)
})
