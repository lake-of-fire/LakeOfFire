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
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/paginator-decisions.js'

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
