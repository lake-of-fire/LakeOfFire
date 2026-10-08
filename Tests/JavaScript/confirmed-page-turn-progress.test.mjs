import test from 'node:test'
import assert from 'node:assert/strict'

import {
    confirmedPageTurnProgressDecision,
    shouldRequestConfirmedPageTurnProgress,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/confirmed-page-turn-progress.js'
import { PAGE_TURN_MOVEMENT_DISPOSITION } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/page-turn-coordination.js'

const eligible = overrides => confirmedPageTurnProgressDecision({
    hasLoadedLastPosition: true,
    location: {
        fraction: 0.75,
        cfi: 'epubcfi(/6/4!/4/2)',
        sectionIndex: 1,
        reason: 'page',
    },
    currentDocumentURL: 'ebook://fixture/chapter-2.xhtml',
    currentSectionIndex: 1,
    rendererLocalName: 'foliate-paginator',
    localSectionIndex: 2,
    rendererTotal: 5,
    ...overrides,
})

test('only a confirmed moved page turn requests fallback persistence', () => {
    assert.equal(
        shouldRequestConfirmedPageTurnProgress(PAGE_TURN_MOVEMENT_DISPOSITION.moved),
        true
    )
    for (const disposition of [
        PAGE_TURN_MOVEMENT_DISPOSITION.noMove,
        PAGE_TURN_MOVEMENT_DISPOSITION.notOwned,
        PAGE_TURN_MOVEMENT_DISPOSITION.unknown,
    ]) {
        assert.equal(shouldRequestConfirmedPageTurnProgress(disposition), false)
    }
})

test('restore, user-input, anchor, and current-section fences suppress persistence', () => {
    assert.equal(eligible({ restoreInProgress: true }).reason, 'restore-in-progress')
    assert.equal(eligible({ requiresUserInput: true }).reason, 'requires-user-input')
    assert.equal(eligible({ location: {
        fraction: 0.75,
        cfi: 'epubcfi(/6/4!/4/2)',
        sectionIndex: 1,
        reason: 'anchor',
    } }).reason, 'anchor')
    assert.equal(eligible({ currentSectionIndex: 2 }).reason, 'section-mismatch')
})

test('eligible canonical progress retains a stable CFI and its identity fences', () => {
    const decision = eligible()
    assert.equal(decision.shouldPost, true)
    assert.equal(decision.persistedLocator, 'epubcfi(/6/4!/4/2)')
    assert.deepEqual(decision.nextObservation, {
        cfi: 'epubcfi(/6/4!/4/2)',
        sectionIndex: 1,
        localSectionIndex: 2,
        rendererTotal: 5,
    })
})

test('section-base and cross-page unstable CFIs use a synthetic restore locator', () => {
    const sectionBase = eligible({ sectionBaseCFI: 'epubcfi(/6/4!/4/2)' })
    assert.equal(sectionBase.shouldPost, true)
    assert.notEqual(sectionBase.persistedLocator, sectionBase.cfi)

    const unstable = eligible({
        priorObservation: {
            cfi: 'epubcfi(/6/4!/4/2)',
            sectionIndex: 1,
            localSectionIndex: 1,
            rendererTotal: 5,
        },
    })
    assert.equal(unstable.markCFIUnstable, true)
    assert.notEqual(unstable.persistedLocator, unstable.cfi)
})

test('closed reader and stale locator values never post', () => {
    assert.equal(eligible({ closed: true }).reason, 'closed')
    assert.equal(eligible({ location: {
        fraction: Number.NaN,
        cfi: 'epubcfi(/6/4!/4/2)',
        sectionIndex: 1,
    } }).reason, 'invalid-fraction')
    assert.equal(eligible({ location: {
        fraction: 0.75,
        cfi: '',
        sectionIndex: 1,
    } }).reason, 'invalid-cfi')
})
