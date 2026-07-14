import assert from 'node:assert/strict'
import test from 'node:test'

import {
    makeSyntheticRestoreLocator,
    parseSyntheticRestoreLocator,
    restoreLocatorKind,
    shouldSkipScheduledReaderFractionGoTo,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-restore-coordination.js'

test('synthetic restore locators round trip normalized section state', () => {
    const locator = makeSyntheticRestoreLocator({
        sectionIndex: 7,
        localSectionIndex: 2,
        rendererTotal: 5,
    })

    assert.equal(locator, 'mnb-loc-v1:7:2:5')
    assert.deepEqual(parseSyntheticRestoreLocator(locator), {
        sectionIndex: 7,
        localSectionIndex: 2,
        rendererTotal: 5,
        fractionInSection: 0.5,
    })
    assert.equal(restoreLocatorKind({ cfi: locator, fractionalCompletion: 0.7 }), 'synthetic')
})

test('synthetic restore locators clamp persisted page coordinates', () => {
    const locator = makeSyntheticRestoreLocator({
        sectionIndex: -2,
        localSectionIndex: 99,
        rendererTotal: 4,
    })

    assert.equal(locator, 'mnb-loc-v1:0:3:4')
    assert.deepEqual(parseSyntheticRestoreLocator(locator), {
        sectionIndex: 0,
        localSectionIndex: 3,
        rendererTotal: 4,
        fractionInSection: 1,
    })
    assert.equal(parseSyntheticRestoreLocator('epubcfi(/6/14!)'), null)
    assert.equal(makeSyntheticRestoreLocator({ sectionIndex: 1, localSectionIndex: 0 }), null)
})

test('restore routing gives explicit locators priority over fractional completion', () => {
    assert.equal(restoreLocatorKind({ cfi: 'mnb-loc-v1:7:2:5', fractionalCompletion: 0.7 }), 'synthetic')
    assert.equal(restoreLocatorKind({ cfi: 'epubcfi(/6/14!)', fractionalCompletion: 0.7 }), 'cfi')
    assert.equal(restoreLocatorKind({ cfi: '', fractionalCompletion: 0.7 }), 'fraction')
    assert.equal(restoreLocatorKind({ cfi: '', fractionalCompletion: 0 }), 'none')
})

test('scheduled fractional navigation waits for restore settling until user input', () => {
    assert.equal(shouldSkipScheduledReaderFractionGoTo({
        requiresUserInputBeforePositionSave: true,
        restoreSettlingMs: 2_000,
    }), true)
    assert.equal(shouldSkipScheduledReaderFractionGoTo({
        requiresUserInputBeforePositionSave: false,
        restoreSettlingMs: 2_000,
    }), false)
    assert.equal(shouldSkipScheduledReaderFractionGoTo({
        requiresUserInputBeforePositionSave: true,
        restoreSettlingMs: 0,
    }), false)
})
