import assert from 'node:assert/strict'
import test from 'node:test'

import {
    lockedPageTurnQueueDecision,
    normalizeSingleMediaPageTarget,
    pageSummaryIsVisiblyBlank,
    pageTurnBoundaryDecision,
    paginatorAnchorForLocalPage,
    paginatorRenderSignature,
    preparePaginatorLayoutMeasurement,
    readerLoadPathsMatch,
    revealPaginatorDocument,
    resolveBlankPageTarget,
    shouldSuppressPostPageTurnDuplicate,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/paginator-decisions.js'

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
})

test('blank-page correction remains within content sentinels', () => {
    const blank = { textCharCount: 0, mediaCount: 0 }
    const media = { textCharCount: 0, mediaCount: 1 }
    assert.equal(pageSummaryIsVisiblyBlank(blank), true)
    assert.equal(resolveBlankPageTarget({
        page: 13,
        pages: 25,
        direction: 1,
        summariesByPage: { 13: blank, 14: media },
    }), 14)
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
