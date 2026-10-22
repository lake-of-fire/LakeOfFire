import assert from 'node:assert/strict'
import test from 'node:test'

globalThis.document = { getElementById: () => null }
globalThis.requestAnimationFrame = callback => { callback(); return 0 }
globalThis.cancelAnimationFrame = () => {}

const { NavigationHUD } = await import(
    '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-viewer-nav.js'
)

const historyHUD = onJumpRequest => {
    const hud = new NavigationHUD({ onJumpRequest })
    // Leave location and history transitions real; this fixture has no chrome.
    hud._applyPageTurnNavigationVisibility = () => {}
    hud._updatePrimaryLine = () => {}
    hud._toggleCompletionStack = () => {}
    hud._updateSectionProgress = async () => {}
    hud._updateRelocateButtons = () => {}
    hud._updateRendererSnapshotFromDetail = () => null
    hud._refreshRendererSnapshot = async () => null
    return hud
}

test('a relocation awaiting its snapshot cannot confirm a later failed history jump', async () => {
    let releaseSnapshot
    let snapshotStarted
    const started = new Promise(resolve => { snapshotStarted = resolve })
    const snapshot = new Promise(resolve => { releaseSnapshot = resolve })
    let finishJump
    const jumpResult = new Promise(resolve => { finishJump = resolve })
    const hud = historyHUD(() => jumpResult)
    const origin = { sectionIndex: 0, fraction: 0.1, cfi: 'origin' }
    hud.relocateStacks.back.push(origin)
    hud.currentLocationDescriptor = { sectionIndex: 2, fraction: 0.8, cfi: 'current' }
    hud._updateRendererSnapshotFromDetail = () => null
    hud._refreshRendererSnapshot = async () => {
        snapshotStarted()
        await snapshot
    }

    const olderRelocation = hud.handleRelocate({
        sectionIndex: 2, fraction: 0.81, cfi: 'current-adjusted', reason: 'anchor',
    })
    await started
    const jump = hud._handleRelocateJump('back')
    const pending = hud.pendingRelocateJump
    try {
        releaseSnapshot()
        await olderRelocation
        assert.equal(hud.pendingRelocateJump, pending)
        assert.deepEqual(hud.relocateStacks.back, [origin])
        assert.deepEqual(hud.relocateStacks.forward, [])
    } finally {
        finishJump(false)
        await jump
    }
    assert.equal(hud.pendingRelocateJump, null)
    assert.deepEqual(hud.relocateStacks.back, [origin])
    assert.deepEqual(hud.relocateStacks.forward, [])
})

for (const direction of ['back', 'forward']) {
    test(`${direction} history commits only the matching relocation receipt`, async () => {
        let finishJump
        let relocationID
        const jumpResult = new Promise(resolve => { finishJump = resolve })
        const hud = historyHUD((_descriptor, options) => {
            relocationID = options.relocationID
            return jumpResult
        })
        const target = { sectionIndex: 0, fraction: 0.1, cfi: 'target' }
        const current = { sectionIndex: 2, fraction: 0.8, cfi: 'current' }
        hud.relocateStacks[direction].push(target)
        hud.currentLocationDescriptor = current
        const jump = hud._handleRelocateJump(direction)
        const pending = hud.pendingRelocateJump
        try {
            for (const receipt of [undefined, 'unrelated-relocation']) {
                await hud.handleRelocate({
                    ...target, reason: 'anchor', relocationID: receipt,
                })
                assert.equal(hud.pendingRelocateJump, pending)
                assert.deepEqual(hud.relocateStacks[direction], [target])
                assert.deepEqual(hud.relocateStacks[direction === 'back' ? 'forward' : 'back'], [])
            }
            await hud.handleRelocate({
                ...target, reason: 'navigation', relocationID,
            })
            assert.equal(hud.pendingRelocateJump, null)
            assert.equal(hud.isProcessingRelocateJump, false)
            assert.deepEqual(hud.relocateStacks[direction], [])
            const opposite = hud.relocateStacks[direction === 'back' ? 'forward' : 'back']
            assert.equal(opposite.length, 1)
            assert.equal(opposite[0].fraction, current.fraction)
            assert.equal(hud.currentLocationDescriptor.fraction, target.fraction)
        } finally {
            finishJump(true)
            await jump
        }
    })
}

test('RTL paginator progress uses logical reading-order page numbers', () => {
    const hud = new NavigationHUD({
        getRenderer: () => ({ scrolled: false, bookDir: 'rtl' }),
    })
    hud.setIsRTL(true)
    const normalized = hud._normalizeRendererPageInfo(9, 13, {
        scrolled: false,
        bookDir: 'rtl',
    })
    hud.rendererPageSnapshot = normalized

    assert.equal(normalized.current, 3)
    assert.equal(normalized.total, 11)
    assert.equal(normalized.rawCurrent, 9)
    assert.equal(hud._fractionForPercent({ fraction: 0.8 }), 0.8)
})

test('location descriptors use the shared conservative renderer index policy', () => {
    const renderer = {
        currentIndex: 0,
        getContents() {
            return [{ index: 7 }]
        },
    }
    const hud = new NavigationHUD({ getRenderer: () => renderer })
    Object.defineProperty(renderer, 'currentIndex', {
        configurable: true,
        get() {
            throw new Error('transient renderer index failure')
        },
    })

    assert.equal(hud._makeLocationDescriptor({ fraction: 0.25 }).sectionIndex, 7)

    Object.defineProperty(renderer, 'currentIndex', {
        configurable: true,
        value: Number.NaN,
    })
    renderer.getContents = () => [{ index: 4 }]
    assert.equal(hud._makeLocationDescriptor({ fraction: 0.5 }).sectionIndex, 4)

    hud.getRenderer = () => { throw new Error('renderer unavailable') }
    hud.lastSectionIndexSeen = 9
    assert.equal(hud._makeLocationDescriptor({ fraction: 0.75 }).sectionIndex, 9)
})

test('explicit relocation ownership requires the exact relocation receipt', () => {
    const hud = new NavigationHUD()
    const visibilityUpdates = []
    hud.setHideNavigationDueToScroll = (hidden, source, details) => {
        visibilityUpdates.push({ hidden, source, details })
    }
    globalThis.window = {
        webkit: {
            messageHandlers: {
                ebookNavigationVisibility: { postMessage() {} },
            },
        },
    }

    const first = hud.requestExplicitRelocateHistoryMutation(
        'goToHref',
        'relocate-first'
    )
    const second = hud.requestExplicitRelocateHistoryMutation(
        'goToPercent',
        'relocate-second'
    )

    assert.equal(hud.cancelExplicitRelocateHistoryMutation(first), true)
    hud._applyPageTurnNavigationVisibility({
        reason: 'navigation',
        relocationID: first.relocationID,
    })
    hud._applyPageTurnNavigationVisibility({ reason: 'navigation' })
    assert.equal(visibilityUpdates.length, 0)

    hud._applyPageTurnNavigationVisibility({
        reason: 'navigation',
        relocationID: second.relocationID,
    })
    assert.equal(visibilityUpdates.length, 1)
    assert.equal(visibilityUpdates[0].details.explicitRelocateSource, 'goToPercent')

    assert.equal(hud.cancelExplicitRelocateHistoryMutation(second), true)
    hud._applyPageTurnNavigationVisibility({
        reason: 'navigation',
        relocationID: second.relocationID,
    })
    assert.equal(visibilityUpdates.length, 1)
    assert.equal(hud._explicitRelocateHistoryMutations.size, 0)
})

test('a refused newer relocation does not erase an older in-flight owner', () => {
    const hud = new NavigationHUD()
    const visibilityUpdates = []
    hud.setHideNavigationDueToScroll = (_hidden, _source, details) => {
        visibilityUpdates.push(details.explicitRelocateSource)
    }
    globalThis.window = {
        webkit: {
            messageHandlers: {
                ebookNavigationVisibility: { postMessage() {} },
            },
        },
    }

    const older = hud.requestExplicitRelocateHistoryMutation(
        'goToHref',
        'relocate-older'
    )
    const newer = hud.requestExplicitRelocateHistoryMutation(
        'goToPercent',
        'relocate-newer'
    )

    assert.equal(hud.cancelExplicitRelocateHistoryMutation(newer), true)
    hud._applyPageTurnNavigationVisibility({
        reason: 'navigation',
        relocationID: older.relocationID,
    })

    assert.deepEqual(visibilityUpdates, ['goToHref'])
    assert.equal(hud.cancelExplicitRelocateHistoryMutation(older), true)
    assert.equal(hud._explicitRelocateHistoryMutations.size, 0)
})

test('an older asynchronous relocate cannot publish after a newer relocate', async () => {
    let resolveFirstRefresh
    let markFirstRefreshStarted
    const firstRefreshStarted = new Promise(resolve => {
        markFirstRefreshStarted = resolve
    })
    const firstRefresh = new Promise(resolve => {
        resolveFirstRefresh = resolve
    })
    let refreshCount = 0
    const applied = []
    const hud = new NavigationHUD({ getRenderer: () => ({ currentIndex: 0 }) })
    hud._updateRendererSnapshotFromDetail = () => null
    hud._refreshRendererSnapshot = async () => {
        refreshCount += 1
        if (refreshCount === 1) {
            markFirstRefreshStarted()
            await firstRefresh
        }
    }
    hud._applyPageTurnNavigationVisibility = detail => applied.push([
        'visibility',
        detail.index,
    ])
    hud._handleRelocateHistory = detail => applied.push(['history', detail.index])
    hud._updatePrimaryLine = detail => applied.push(['label', detail.index])
    hud._toggleCompletionStack = () => {}
    hud._updateSectionProgress = async () => {}
    hud._updateRelocateButtons = () => {}
    hud._pruneBackStackIfReturnedToOrigin = () => {}

    hud.requestExplicitRelocateHistoryMutation('goToHref', 'relocate-older')
    hud.requestExplicitRelocateHistoryMutation('goToPercent', 'relocate-newer')
    const older = hud.handleRelocate({
        index: 1,
        reason: 'navigation',
        relocationID: 'relocate-older',
    })
    await firstRefreshStarted
    await hud.handleRelocate({
        index: 2,
        reason: 'navigation',
        relocationID: 'relocate-newer',
    })
    resolveFirstRefresh()
    await older

    assert.deepEqual(applied, [
        ['visibility', 2],
        ['history', 2],
        ['label', 2],
    ])
    assert.equal(hud.lastRelocateDetail.index, 2)
    assert.equal(hud._explicitRelocateHistoryMutations.size, 0)
})

test('a newer relocate invalidates older section progress before awaiting its snapshot', async () => {
    let resolveOlderCalculation
    let markOlderCalculationStarted
    const olderCalculationStarted = new Promise(resolve => {
        markOlderCalculationStarted = resolve
    })
    const olderCalculation = new Promise(resolve => {
        resolveOlderCalculation = resolve
    })
    let resolveNewerSnapshot
    let markNewerSnapshotStarted
    const newerSnapshotStarted = new Promise(resolve => {
        markNewerSnapshotStarted = resolve
    })
    const newerSnapshot = new Promise(resolve => {
        resolveNewerSnapshot = resolve
    })

    const labels = []
    let calculationCount = 0
    const hud = new NavigationHUD({ getRenderer: () => ({ currentIndex: 1 }) })
    hud.navSectionProgress = {
        leading: { hidden: false },
        trailing: { hidden: false },
    }
    hud.lastRelocateDetail = { index: 1, sectionIndex: 1, reason: 'navigation' }
    hud._calculatePagesLeftInSection = async () => {
        calculationCount += 1
        if (calculationCount === 1) {
            markOlderCalculationStarted()
            return await olderCalculation
        }
        return {
            pagesLeft: 2,
            currentPageNumber: 1,
            totalPages: 3,
            source: 'newer',
        }
    }
    hud._updateTitleLocationLabel = value => labels.push(value)
    hud._isLastLinearSection = () => false
    hud._updateRendererSnapshotFromDetail = () => null
    hud._refreshRendererSnapshot = async () => {
        markNewerSnapshotStarted()
        await newerSnapshot
    }
    hud._applyPageTurnNavigationVisibility = () => {}
    hud._handleRelocateHistory = () => {}
    hud._updatePrimaryLine = () => {}
    hud._toggleCompletionStack = () => {}
    hud._updateRelocateButtons = () => {}
    hud._pruneBackStackIfReturnedToOrigin = () => {}

    const older = hud._updateSectionProgress({
        refreshSnapshot: false,
        source: 'older',
    })
    await olderCalculationStarted

    const newer = hud.handleRelocate({
        index: 2,
        sectionIndex: 2,
        reason: 'navigation',
    })
    await newerSnapshotStarted

    resolveOlderCalculation({
        pagesLeft: 8,
        currentPageNumber: 1,
        totalPages: 9,
        source: 'older',
    })
    await older
    assert.deepEqual(labels, [])

    resolveNewerSnapshot()
    await newer
    assert.equal(labels.length, 1)
    assert.equal(labels[0].pagesLeftLabel, '2 pages left in chapter')
    assert.equal(hud.lastRelocateDetail.sectionIndex, 2)
})

test('an older renderer snapshot request cannot overwrite a newer snapshot', async () => {
    let resolveOlderMetrics
    let markOlderMetricsStarted
    const olderMetricsStarted = new Promise(resolve => {
        markOlderMetricsStarted = resolve
    })
    const olderMetrics = new Promise(resolve => {
        resolveOlderMetrics = resolve
    })
    let metricsCallCount = 0
    const renderer = {
        scrolled: true,
        page() {},
        pages() {},
        async pageMetrics() {
            metricsCallCount += 1
            if (metricsCallCount === 1) {
                markOlderMetricsStarted()
                return await olderMetrics
            }
            return { page: 8, pages: 10 }
        },
    }
    const hud = new NavigationHUD({ getRenderer: () => renderer })

    const olderRefresh = hud._refreshRendererSnapshot()
    await olderMetricsStarted
    const newerSnapshot = await hud._refreshRendererSnapshot()

    assert.equal(newerSnapshot.current, 8)
    assert.equal(hud.rendererPageSnapshot.current, 8)
    assert.equal(hud.nativeOverlayPageSnapshot.current, 8)

    resolveOlderMetrics({ page: 2, pages: 10 })
    assert.equal(await olderRefresh, null)
    assert.equal(hud.rendererPageSnapshot.current, 8)
    assert.equal(hud.nativeOverlayPageSnapshot.current, 8)
})

test('destroy invalidates pending navigation HUD publication and owned work', async () => {
    let resolveRefresh
    let markRefreshStarted
    const refreshStarted = new Promise(resolve => {
        markRefreshStarted = resolve
    })
    const refresh = new Promise(resolve => {
        resolveRefresh = resolve
    })
    const applied = []
    const hud = new NavigationHUD({ getRenderer: () => ({ currentIndex: 0 }) })
    hud._updateRendererSnapshotFromDetail = () => null
    hud._refreshRendererSnapshot = async () => {
        markRefreshStarted()
        await refresh
    }
    hud._applyPageTurnNavigationVisibility = () => applied.push('visibility')
    hud._handleRelocateHistory = () => applied.push('history')
    hud._updatePrimaryLine = () => applied.push('label')
    hud._toggleCompletionStack = () => {}
    hud._updateSectionProgress = async () => {}
    hud._updateRelocateButtons = () => {}
    hud._pruneBackStackIfReturnedToOrigin = () => {}

    hud.requestExplicitRelocateHistoryMutation('goToHref', 'relocate-pending')
    const pendingRelocate = hud.handleRelocate({
        index: 1,
        reason: 'navigation',
        relocationID: 'relocate-pending',
    })
    await refreshStarted

    assert.equal(hud.destroy(), true)
    assert.equal(hud.destroy(), false)
    assert.equal(hud.getRenderer, null)
    assert.equal(hud.onJumpRequest, null)
    assert.equal(hud._explicitRelocateHistoryMutations.size, 0)

    resolveRefresh()
    await pendingRelocate

    assert.deepEqual(applied, [])
    assert.equal(hud.lastRelocateDetail, null)
})
