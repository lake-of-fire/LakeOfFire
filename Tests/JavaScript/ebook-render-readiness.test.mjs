import test from 'node:test'
import assert from 'node:assert/strict'

import {
    classifyEbookRenderReadiness,
    EbookRenderReadinessCoordinator,
    waitForEbookRenderReadinessSignal,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-render-readiness.js'

const makeDocument = ({
    readyState = 'complete',
    media = null,
    singleMedia = false,
} = {}) => ({
    readyState,
    body: {
        classList: { contains: className => singleMedia && className === 'reader-is-single-media-element-without-text' },
        querySelector: () => media,
    },
    defaultView: {
        getComputedStyle: element => element.style ?? { display: 'block', visibility: 'visible', opacity: '1' },
    },
})

const segmentResult = (...text) => ({
    totalSegmentCount: text.length,
    visibleSegments: text.map(value => ({ node: { textContent: value } })),
})

test('visible Yomitan text is immediately renderable', () => {
    const result = classifyEbookRenderReadiness(makeDocument(), segmentResult('', '本文'))

    assert.equal(result.outcome, 'ready')
    assert.equal(result.visibleSegmentCount, 1)
    assert.equal(result.hasVisibleSingleMedia, false)
})

test('a visible settled single-media document is renderable', () => {
    const media = {
        tagName: 'IMG',
        complete: true,
        getBoundingClientRect: () => ({ width: 320, height: 480 }),
        style: { display: 'block', visibility: 'visible', opacity: '1' },
    }
    const result = classifyEbookRenderReadiness(
        makeDocument({ media, singleMedia: true }),
        segmentResult()
    )

    assert.equal(result.outcome, 'ready')
    assert.equal(result.hasVisibleSingleMedia, true)
})

test('hidden and zero-sized media terminate as empty content', () => {
    for (const media of [
        {
            tagName: 'IMG', complete: true,
            getBoundingClientRect: () => ({ width: 320, height: 480 }),
            style: { display: 'none', visibility: 'visible', opacity: '1' },
        },
        {
            tagName: 'IMG', complete: true,
            getBoundingClientRect: () => ({ width: 0, height: 0 }),
            style: { display: 'block', visibility: 'visible', opacity: '1' },
        },
    ]) {
        assert.equal(
            classifyEbookRenderReadiness(makeDocument({ media, singleMedia: true }), segmentResult()).outcome,
            'empty'
        )
    }
})

test('loading and failed media remain distinct outcomes', () => {
    const loading = { tagName: 'IMG', complete: false }
    const failed = { tagName: 'IMG', complete: true, error: new Error('failed') }

    assert.equal(
        classifyEbookRenderReadiness(makeDocument({ media: loading, singleMedia: true }), segmentResult()).outcome,
        'pending'
    )
    assert.equal(
        classifyEbookRenderReadiness(makeDocument({ media: failed, singleMedia: true }), segmentResult()).outcome,
        'error'
    )
})

test('a complete chapter without visible Yomitan text or media is terminal empty', () => {
    const result = classifyEbookRenderReadiness(makeDocument(), segmentResult())

    assert.equal(result.outcome, 'empty')
    assert.equal(result.reason, 'no-visible-renderable-content')
})

test('readiness signal resolves from media events and removes listeners', async () => {
    const listeners = new Map()
    const media = {
        tagName: 'IMG',
        complete: false,
        addEventListener: (name, callback) => listeners.set(name, callback),
        removeEventListener: name => listeners.delete(name),
    }
    const promise = waitForEbookRenderReadinessSignal(makeDocument({ media }), 100)
    listeners.get('load')?.({ type: 'load' })

    assert.equal(await promise, 'load')
    assert.equal(listeners.size, 0)
})

test('readiness signal closes the event-registration race for already-settled media', async () => {
    const listeners = new Map()
    const media = {
        tagName: 'IMG',
        complete: true,
        addEventListener: (name, callback) => listeners.set(name, callback),
        removeEventListener: name => listeners.delete(name),
    }

    assert.equal(await waitForEbookRenderReadinessSignal(makeDocument({ media }), 100), 'already-settled')
    assert.equal(listeners.size, 0)
})

test('coordinator rejects stale and duplicate terminal results', () => {
    const coordinator = new EbookRenderReadinessCoordinator()
    const first = coordinator.begin(3)
    const second = coordinator.begin(4)

    assert.deepEqual(coordinator.settle(first, { outcome: 'ready' }, 3), {
        accepted: false,
        reason: 'stale-generation',
    })
    assert.equal(coordinator.settle(second, { outcome: 'ready' }, 3).reason, 'unexpected-identity')
    assert.equal(coordinator.settle(second, { outcome: 'pending' }, 4).reason, 'pending')
    assert.equal(coordinator.settle(second, { outcome: 'empty', reason: 'empty' }, 4).accepted, true)
    assert.equal(coordinator.settle(second, { outcome: 'ready' }, 4).reason, 'already-terminal')
})
