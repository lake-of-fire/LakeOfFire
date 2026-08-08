import assert from 'node:assert/strict'
import test from 'node:test'

// view.js defines a custom element at module load. These minimal DOM shims keep
// the focused behavior tests independent of a browser runtime.
globalThis.HTMLElement ??= class extends EventTarget {
    attachShadow() {
        return { append() {} }
    }
}
globalThis.customElements ??= { define() {} }

const {
    View,
    destroyReaderBook,
    readerRelocationDetailWithNavigationIntent,
} = await import(
    '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/view.js'
)

test('reader relocation preserves renderer attempt and visibility metadata', async () => {
    const previousDocument = globalThis.document
    let renderer = null
    let view = null
    globalThis.document = {
        createElement() {
            renderer = new EventTarget()
            renderer.setAttribute = () => {}
            renderer.open = () => undefined
            renderer.destroy = () => {}
            renderer.remove = () => {}
            return renderer
        },
    }
    const rendererDetail = {
        index: 7,
        sectionIndex: 999,
        range: null,
        fraction: 0.5,
        size: 12,
        reason: 'page',
        pageTurnDirection: 'right',
        pageTurnAttemptID: 'attempt-a',
        visibleSentinelIDs: ['sentinel-7'],
        visibleRangeSource: 'renderer-snapshot',
        futureRendererReceipt: { committed: true },
        motionStartedAtMs: 1234,
        tocItem: 'stale-toc',
        cfi: 'stale-cfi',
    }

    try {
        view = new View()
        await view.open({
            metadata: {},
            rendition: { layout: 'pre-paginated' },
            sections: Array.from({ length: 8 }, (_, index) => ({
                cfi: `epubcfi(/6/${index * 2 + 2})`,
            })),
            destroy() {},
        })
        renderer.dispatchEvent(new CustomEvent('relocate', {
            detail: rendererDetail,
        }))
        const location = view.lastLocation

        assert.equal(location.pageTurnAttemptID, 'attempt-a')
        assert.deepEqual(location.visibleSentinelIDs, ['sentinel-7'])
        assert.equal(location.visibleRangeSource, 'renderer-snapshot')
        assert.deepEqual(location.futureRendererReceipt, { committed: true })
        assert.equal(location.motionStartedAtMs, 1234)
        assert.equal(location.index, 7)
        assert.equal(location.sectionIndex, 7)
        assert.equal(location.fraction, 0.5)
        assert.equal(location.cfi, 'epubcfi(/6/16)')
        assert.equal(rendererDetail.sectionIndex, 999)
        assert.equal(rendererDetail.tocItem, 'stale-toc')
        assert.equal(rendererDetail.cfi, 'stale-cfi')
    } finally {
        view?.close()
        globalThis.document = previousDocument
    }
})

test('book disposal is exception-contained and reports whether ownership was released', () => {
    let destroyed = 0
    assert.equal(destroyReaderBook({
        destroy() { destroyed += 1 },
    }), true)
    assert.equal(destroyed, 1)

    const originalConsoleError = console.error
    console.error = () => {}
    try {
        assert.equal(destroyReaderBook({
            destroy() { throw new Error('expected-test-failure') },
        }), false)
    } finally {
        console.error = originalConsoleError
    }
    assert.equal(destroyReaderBook(null), false)
})

test('closing a reader view disposes renderer and book exactly once', () => {
    const events = []
    const view = new View()
    view.renderer = {
        destroy() { events.push('renderer.destroy') },
        remove() { events.push('renderer.remove') },
    }
    view.book = {
        destroy() { events.push('book.destroy') },
    }

    view.close()
    view.close()

    assert.deepEqual(events, [
        'renderer.destroy',
        'renderer.remove',
        'book.destroy',
    ])
    assert.equal(view.renderer, null)
    assert.equal(view.book, null)
})


test('reader view releases ownership when a renderer rejects publication open', async () => {
    const previousDocument = globalThis.document
    const events = []
    globalThis.document = {
        createElement(name) {
            const renderer = new EventTarget()
            renderer.setAttribute = () => {}
            renderer.open = () => false
            renderer.destroy = () => events.push(['renderer.destroy', name])
            renderer.remove = () => events.push(['renderer.remove', name])
            return renderer
        },
    }
    const book = {
        metadata: {},
        rendition: { layout: 'pre-paginated' },
        sections: [],
        destroy() { events.push(['book.destroy']) },
    }

    try {
        const view = new View()
        await assert.rejects(
            view.open(book),
            error => error?.name === 'InvalidStateError'
        )
        assert.deepEqual(events, [
            ['renderer.destroy', 'foliate-fxl'],
            ['renderer.remove', 'foliate-fxl'],
            ['book.destroy'],
        ])
        assert.equal(view.renderer, null)
        assert.equal(view.book, null)
    } finally {
        globalThis.document = previousDocument
    }
})

test('reader relocation carries only causal renderer or explicitly supplied operation history', () => {
    const rendererDetail = { index: 4, reason: 'navigation' }
    const owned = readerRelocationDetailWithNavigationIntent({
        rendererDetail,
        navigationIntent: {
            source: 'goToPercent',
            explicitRelocateHistorySource: 'goToPercent',
            explicitRelocateHistoryMutationID: 'reader-navigation-9',
        },
    })
    assert.deepEqual(owned, {
        ...rendererDetail,
        explicitRelocateHistorySource: 'goToPercent',
        explicitRelocateHistoryMutationID: 'reader-navigation-9',
    })
    assert.deepEqual(rendererDetail, { index: 4, reason: 'navigation' })

    const rendererOwned = readerRelocationDetailWithNavigationIntent({
        rendererDetail: {
            ...rendererDetail,
            explicitRelocateHistorySource: 'relocate-button',
            explicitRelocateHistoryMutationID: 'renderer-owned',
        },
        navigationIntent: {
            explicitRelocateHistorySource: 'goToPercent',
            explicitRelocateHistoryMutationID: 'reader-navigation-10',
        },
    })
    assert.equal(rendererOwned.explicitRelocateHistorySource, 'relocate-button')
    assert.equal(rendererOwned.explicitRelocateHistoryMutationID, 'renderer-owned')

    const partialRenderer = readerRelocationDetailWithNavigationIntent({
        rendererDetail: {
            ...rendererDetail,
            explicitRelocateHistorySource: 'stale-renderer-half',
        },
        navigationIntent: {
            explicitRelocateHistorySource: 'goToPercent',
            explicitRelocateHistoryMutationID: 'reader-navigation-11',
            explicitRelocateHistoryRequestGeneration: 11,
        },
    })
    assert.equal(partialRenderer.explicitRelocateHistorySource, 'goToPercent')
    assert.equal(partialRenderer.explicitRelocateHistoryMutationID, 'reader-navigation-11')
    assert.equal(partialRenderer.explicitRelocateHistoryRequestGeneration, 11)

    const partialOnly = {
        ...rendererDetail,
        explicitRelocateHistorySource: 'partial-only',
    }
    assert.equal(readerRelocationDetailWithNavigationIntent({
        rendererDetail: partialOnly,
        navigationIntent: { explicitRelocateHistoryMutationID: 'partial-intent-only' },
    }), partialOnly)

    assert.equal(readerRelocationDetailWithNavigationIntent({
        rendererDetail,
        navigationIntent: { explicitRelocateHistorySource: 'goToPercent' },
    }), rendererDetail)
})

test('View records only destinations committed by the renderer for the current owner', async () => {
    const view = new View()
    const history = []
    view.book = {
        resolveHref: href => ({ index: href === 'chapter-b' ? 2 : 1 }),
    }
    view.history = {
        pushState: value => history.push(value),
        clear() {},
    }

    let receivedNavigationIntent = null
    view.renderer = {
        goTo: async (_target, options) => {
            receivedNavigationIntent = options?.navigationIntent ?? null
            return { ignored: true, moved: false }
        },
    }
    const causalIntent = {
        explicitRelocateHistorySource: 'goToHref',
        explicitRelocateHistoryMutationID: 'reader-navigation-1',
    }
    const rejectedNavigation = view.goTo('chapter-a', {
        returnMovementResult: true,
        navigationIntent: causalIntent,
    })
    causalIntent.explicitRelocateHistoryMutationID = 'mutated-after-call'
    assert.equal(await rejectedNavigation, false)
    assert.notEqual(receivedNavigationIntent, causalIntent)
    assert.deepEqual(receivedNavigationIntent, {
        explicitRelocateHistorySource: 'goToHref',
        explicitRelocateHistoryMutationID: 'reader-navigation-1',
    })
    assert.equal(Object.isFrozen(receivedNavigationIntent), true)
    assert.deepEqual(history, [])

    // Undefined remains the legacy successful receipt used by older renderers.
    view.renderer = {
        goTo: async () => undefined,
    }
    assert.deepEqual(await view.goTo('chapter-b'), { index: 2 })
    assert.deepEqual(history, ['chapter-b'])

    let releaseNavigation
    const navigationGate = new Promise(resolve => { releaseNavigation = resolve })
    let current = true
    view.renderer = {
        goTo: async () => {
            await navigationGate
            return true
        },
    }
    const superseded = view.goTo('chapter-a', {
        returnMovementResult: true,
        isCurrent: () => current,
    })
    current = false
    releaseNavigation()
    assert.equal(await superseded, false)
    assert.deepEqual(history, ['chapter-b'])
})


test('View preserves public navigation return values when the target is already satisfied', async () => {
    const view = new View()
    const history = []
    view.book = {
        resolveHref: () => ({ index: 2 }),
    }
    view.history = {
        pushState: value => history.push(value),
        clear() {},
    }
    const satisfiedReceipt = {
        ignored: true,
        moved: false,
        targetSatisfied: true,
        reason: 'alreadyAtVisibleRendererTarget',
    }
    view.renderer = {
        goTo: async () => satisfiedReceipt,
    }

    assert.deepEqual(await view.goTo('chapter-b'), { index: 2 })
    assert.deepEqual(await view.goTo('chapter-b', {
        returnMovementResult: true,
    }), satisfiedReceipt)
    assert.deepEqual(history, [])
})

test('View initial navigation seeds replaceable history and rolls it back on rejection', async () => {
    const view = new View()
    const events = []
    view.history = {
        pushState: value => events.push(['push', value]),
        clear: () => events.push(['clear']),
    }
    view.renderer = {
        next: async () => {
            events.push(['next'])
            return { moved: true }
        },
    }

    assert.equal(await view.init({ lastLocation: null, showTextStart: false }), true)
    assert.deepEqual(events, [['push', 0], ['next']])

    events.length = 0
    view.renderer = {
        next: async () => {
            events.push(['next'])
            return { ignored: true, moved: false }
        },
    }
    assert.equal(await view.init({ lastLocation: null, showTextStart: false }), false)
    assert.deepEqual(events, [['push', 0], ['next'], ['clear']])

    events.length = 0
    view.renderer = {
        next: async () => {
            events.push(['next'])
            throw new Error('initial navigation failed')
        },
    }
    await assert.rejects(
        view.init({ lastLocation: null, showTextStart: false }),
        /initial navigation failed/
    )
    assert.deepEqual(events, [['push', 0], ['next'], ['clear']])
})
