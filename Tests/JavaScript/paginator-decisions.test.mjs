import assert from 'node:assert/strict'
import test from 'node:test'

import {
    lockedPageTurnQueueDecision,
    normalizeSingleMediaPageTarget,
    pageSummaryIsVisiblyBlank,
    pageTurnBoundaryDecision,
    paginatorAnchorForLocalPage,
    resolveBlankPageTarget,
    shouldSuppressPostPageTurnDuplicate,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/paginator-decisions.js'

test('blank page resolution moves only to adjacent visible content', () => {
    const blank = { textCharCount: 0, mediaCount: 0 }
    const media = { textCharCount: 0, mediaCount: 1 }

    assert.equal(pageSummaryIsVisiblyBlank(blank), true)
    assert.equal(pageSummaryIsVisiblyBlank(media), false)
    assert.equal(resolveBlankPageTarget({
        page: 13,
        pages: 25,
        direction: 1,
        summariesByPage: { 13: blank, 14: media },
    }), 14)
    assert.equal(resolveBlankPageTarget({
        page: 13,
        pages: 25,
        direction: -1,
        summariesByPage: { 12: media, 13: blank },
    }), 12)
    assert.equal(resolveBlankPageTarget({
        page: 12,
        pages: 25,
        direction: 1,
        summariesByPage: { 12: media },
    }), 12)
})

test('local page anchors replay and clamp to the available text pages', () => {
    const textPageCount = 236
    const anchor = paginatorAnchorForLocalPage({ localPage: 1, textPageCount })
    const clampedAnchor = paginatorAnchorForLocalPage({ localPage: 999, textPageCount })

    assert.equal(anchor, 1 / 235)
    assert.equal(Math.round(anchor * (textPageCount - 1)) + 1, 2)
    assert.equal(Math.round(clampedAnchor * (textPageCount - 1)) + 1, 236)
})

test('locked page turns queue only within the pending section', () => {
    const decide = options => lockedPageTurnQueueDecision({
        pendingQueueAllowed: true,
        pendingRequestedPage: 2,
        pendingPageCount: 6,
        pendingDirection: 'forward',
        queuedDirection: 'backward',
        queuedStep: -1,
        lockedElapsedMs: 400,
        distance: null,
        ...options,
    }).shouldQueue

    assert.equal(decide({ queuedDirection: 'forward', queuedStep: 1 }), true)
    assert.equal(decide({ pendingQueueAllowed: false }), false)
    assert.equal(decide({ pendingRequestedPage: 3, pendingPageCount: 5, queuedDirection: 'forward', queuedStep: 1 }), false)
    assert.equal(decide({ pendingRequestedPage: 1, pendingPageCount: 5, queuedStep: -1 }), false)
    assert.equal(decide({ pendingRequestedPage: null, pendingPageCount: null }), false)
    assert.equal(decide({ queuedDirection: 'forward', queuedStep: 1, lockedElapsedMs: 50 }), false)
})

test('section-boundary decisions do not scroll into paginator sentinels', () => {
    const backward = pageTurnBoundaryDecision({ currentPage: 1, pageCount: 348, step: -1, adjacentIndex: 5 })
    const forward = pageTurnBoundaryDecision({ currentPage: 2, pageCount: 3, step: 1, adjacentIndex: 6 })
    const within = pageTurnBoundaryDecision({ currentPage: 2, pageCount: 6, step: 1, adjacentIndex: 6 })
    const bookStart = pageTurnBoundaryDecision({ currentPage: 1, pageCount: 3, step: -1, adjacentIndex: null })

    assert.deepEqual(
        [backward.requestedPage, backward.shouldGoToAdjacentSection, backward.shouldScrollWithinSection],
        [0, true, false]
    )
    assert.deepEqual(
        [forward.requestedPage, forward.shouldGoToAdjacentSection, forward.shouldScrollWithinSection],
        [3, true, false]
    )
    assert.deepEqual(
        [within.requestedPage, within.shouldGoToAdjacentSection, within.shouldScrollWithinSection],
        [3, false, true]
    )
    assert.deepEqual(
        [bookStart.shouldGoToAdjacentSection, bookStart.shouldScrollWithinSection],
        [false, true]
    )
})

test('single-media sections normalize sentinel pages to their content page', () => {
    assert.equal(normalizeSingleMediaPageTarget({ page: 0, pages: 3, isSingleMedia: true }), 1)
    assert.equal(normalizeSingleMediaPageTarget({ page: 1, pages: 3, isSingleMedia: true }), 1)
    assert.equal(normalizeSingleMediaPageTarget({ page: 2, pages: 3, isSingleMedia: true }), 1)
    assert.equal(normalizeSingleMediaPageTarget({ page: 0, pages: 3, isSingleMedia: false }), 0)
    assert.equal(normalizeSingleMediaPageTarget({ page: 2, pages: 5, isSingleMedia: true }), 2)
})

test('post-turn suppression applies only to anonymous same-direction duplicates', () => {
    const decide = options => shouldSuppressPostPageTurnDuplicate({
        lastDirection: 'backward',
        direction: 'backward',
        distance: null,
        navigationSource: null,
        elapsedMs: 80,
        ...options,
    })

    assert.equal(decide({}), true)
    assert.equal(decide({ navigationSource: 'pageTurn.keydown.ArrowRight' }), false)
    assert.equal(decide({ direction: 'forward' }), false)
    assert.equal(decide({ elapsedMs: 400 }), false)
    assert.equal(decide({ distance: 64 }), false)
})
