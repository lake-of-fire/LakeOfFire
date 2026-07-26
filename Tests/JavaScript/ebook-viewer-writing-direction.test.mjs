import assert from 'node:assert/strict'
import test from 'node:test'

import {
    applyEbookViewerWritingDirection,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-viewer-writing-direction.js'

test('awaits paginator relayout before refreshing child presentation', async () => {
    const events = []
    let releaseRender
    const renderGate = new Promise(resolve => {
        releaseRender = resolve
    })
    const document = {
        defaultView: {
            manabiApplyVerticalWritingCheck: () => events.push('presentation'),
        },
    }
    const task = applyEbookViewerWritingDirection({
        renderer: {
            getContents: () => [{ doc: document }],
            setWritingDirectionOverride: async value => {
                events.push(`render-start:${value}`)
                await renderGate
                events.push('render-finish')
                return { rendered: true }
            },
        },
        value: 'horizontal',
        onNormalized: value => events.push(`normalized:${value}`),
    })

    await Promise.resolve()
    assert.deepEqual(events, ['normalized:horizontal', 'render-start:horizontal'])
    releaseRender()
    const result = await task
    assert.deepEqual(events, [
        'normalized:horizontal',
        'render-start:horizontal',
        'render-finish',
        'presentation',
    ])
    assert.deepEqual(result, {
        writingDirection: 'horizontal',
        renderResult: { rendered: true },
    })
})

test('normalizes invalid input and handles an unavailable renderer', async () => {
    let normalized
    const result = await applyEbookViewerWritingDirection({
        renderer: null,
        value: 'diagonal',
        onNormalized: value => {
            normalized = value
        },
    })

    assert.equal(normalized, 'original')
    assert.deepEqual(result, {
        writingDirection: 'original',
        renderResult: { rendered: false, reason: 'renderer-unavailable' },
    })
})
