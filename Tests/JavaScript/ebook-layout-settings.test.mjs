import test from 'node:test'
import assert from 'node:assert/strict'

import {
    applyLayoutSettingsToEbookDocument,
    ebookLayoutSettingDatasetKeys,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-layout-settings.js'

const makeDocument = dataset => ({ body: { dataset: { ...dataset } } })

test('copies only geometry-affecting reader settings to an ebook child', () => {
    const source = makeDocument({
        mnbFuriganaEnabled: 'true',
        mnbFuriganaOriginalOnly: 'false',
        mnbRomajiModeEnabled: 'true',
        mnbFamiliarFuriganaEnabled: 'false',
        mnbLearningFuriganaEnabled: 'true',
        mnbKnownFuriganaEnabled: 'false',
        mnbColorScheme: 'dark',
    })
    const target = makeDocument({ mnbColorScheme: 'light' })

    assert.equal(applyLayoutSettingsToEbookDocument(source, target), true)
    assert.deepEqual(
        Object.fromEntries(ebookLayoutSettingDatasetKeys.map(key => [key, target.body.dataset[key]])),
        Object.fromEntries(ebookLayoutSettingDatasetKeys.map(key => [key, source.body.dataset[key]])),
    )
    assert.equal(target.body.dataset.mnbColorScheme, 'light')
})

test('repeated application is a no-op and preserves absent target settings', () => {
    const source = makeDocument({ mnbFuriganaEnabled: 'true' })
    const target = makeDocument({
        mnbFuriganaEnabled: 'true',
        mnbKnownFuriganaEnabled: 'target-only',
    })

    assert.equal(applyLayoutSettingsToEbookDocument(source, target), false)
    assert.equal(target.body.dataset.mnbKnownFuriganaEnabled, 'target-only')
})

test('rejects missing bodies and the outer document itself', () => {
    const document = makeDocument({ mnbFuriganaEnabled: 'true' })

    assert.equal(applyLayoutSettingsToEbookDocument(document, document), false)
    assert.equal(applyLayoutSettingsToEbookDocument({}, makeDocument({})), false)
    assert.equal(applyLayoutSettingsToEbookDocument(document, {}), false)
})
