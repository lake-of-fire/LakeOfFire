import assert from 'node:assert/strict'
import test from 'node:test'

import {
    makeSyntheticRestoreLocator,
    parseSyntheticRestoreLocator,
    runRequiredRestoreNavigation,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-restore-coordination.js'

test('synthetic restore locators round trip normalized section state', () => {
    const locator = makeSyntheticRestoreLocator({ sectionIndex: 7, localSectionIndex: 2, rendererTotal: 5 })
    assert.equal(locator, 'mnb-loc-v1:7:2:5')
    assert.deepEqual(parseSyntheticRestoreLocator(locator), {
        sectionIndex: 7,
        localSectionIndex: 2,
        rendererTotal: 5,
        fractionInSection: 0.5,
    })
})

test('synthetic restore locators reject malformed values and clamp coordinates', () => {
    assert.equal(makeSyntheticRestoreLocator({ sectionIndex: -2, localSectionIndex: 99, rendererTotal: 4 }), 'mnb-loc-v1:0:3:4')
    assert.equal(makeSyntheticRestoreLocator({ sectionIndex: 1, localSectionIndex: 0 }), null)
    assert.equal(parseSyntheticRestoreLocator('epubcfi(/6/14!)'), null)
})

test('required restore navigation preserves a terminal failure', async () => {
    const failure = new Error('saved locator is invalid')
    const result = await runRequiredRestoreNavigation(async () => {
        throw failure
    })

    assert.equal(result.ok, false)
    assert.equal(result.value, null)
    assert.equal(result.error, failure)
})

test('required restore navigation returns its terminal value', async () => {
    const value = { sectionIndex: 4, fraction: 0.5 }

    assert.deepEqual(await runRequiredRestoreNavigation(async () => value), {
        ok: true,
        value,
        error: null,
    })
})
