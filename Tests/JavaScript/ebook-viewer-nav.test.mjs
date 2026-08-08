import assert from 'node:assert/strict'
import test from 'node:test'

globalThis.document = { getElementById: () => null }
globalThis.requestAnimationFrame = callback => { callback(); return 0 }
globalThis.cancelAnimationFrame = () => {}

const { NavigationHUD } = await import(
    '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-viewer-nav.js'
)


test('spine and page-target identity preserves non-ASCII edge whitespace', () => {
    const exactHref = 'OPS/chapter.xhtml\u00A0'
    const trimmedSiblingHref = 'OPS/chapter.xhtml'
    const hud = new NavigationHUD({ getRenderer: () => null })

    hud.setNavContext({
        sections: [
            { href: exactHref, linear: true },
            { href: trimmedSiblingHref, linear: true },
        ],
    })

    assert.equal(
        hud._resolveSectionIndex({ tocItem: { href: exactHref } }).index,
        0,
    )
    assert.equal(
        hud._resolveSectionIndex({ tocItem: { href: trimmedSiblingHref } }).index,
        1,
    )
    assert.equal(
        hud._resolveSectionIndex({ tocItem: { href: ` \t${trimmedSiblingHref}\r\n` } }).index,
        1,
    )
})

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

test('disposed navigation HUD rejects a relocation that resumes after asynchronous renderer work', async () => {
    let releaseSnapshot
    const snapshotGate = new Promise(resolve => { releaseSnapshot = resolve })
    const hud = new NavigationHUD({
        getRenderer: () => ({ currentIndex: 0, scrolled: false, bookDir: 'ltr' }),
    })
    hud._updateRendererSnapshotFromDetail = () => null
    hud._refreshRendererSnapshot = async () => {
        await snapshotGate
        return { current: 1, total: 1 }
    }

    const relocate = hud.handleRelocate({
        sectionIndex: 0,
        location: { current: 0, total: 1 },
    })
    hud.dispose()
    releaseSnapshot()
    await relocate

    assert.equal(hud.disposed, true)
    assert.equal(hud.lastRelocateDetail, null)
    assert.equal(hud.pendingRelocateJump, null)
    assert.equal(hud.onJumpRequest, null)
})

test('a newer relocation owns HUD state when an older snapshot request resolves late', async () => {
    let releaseOlderMetrics
    let markOlderMetricsStarted
    const olderMetricsGate = new Promise(resolve => { releaseOlderMetrics = resolve })
    const olderMetricsStarted = new Promise(resolve => { markOlderMetricsStarted = resolve })
    const renderer = {
        currentIndex: 0,
        scrolled: false,
        bookDir: 'ltr',
        page: async () => 1,
        pages: async () => 12,
        pageMetrics: async () => {
            markOlderMetricsStarted()
            await olderMetricsGate
            return { page: 2, pages: 12 }
        },
    }
    const hud = new NavigationHUD({ getRenderer: () => renderer })
    const history = []
    hud._scheduleRendererSnapshotRefresh = () => {}
    hud._applyPageTurnNavigationVisibility = () => {}
    hud._handleRelocateHistory = detail => history.push(detail.id)
    hud._updatePrimaryLine = () => {}
    hud._toggleCompletionStack = () => {}
    hud._updateSectionProgress = async () => {}
    hud._updateRelocateButtons = () => {}
    hud._pruneBackStackIfReturnedToOrigin = () => {}

    const older = {
        id: 'older',
        sectionIndex: 0,
        location: { current: 0.1, total: 1 },
    }
    const newer = {
        id: 'newer',
        sectionIndex: 1,
        scrolled: false,
        pageNumber: 8,
        pageCount: 12,
        location: { current: 0.8, total: 1 },
    }

    const olderRelocate = hud.handleRelocate(older)
    await olderMetricsStarted

    await hud.handleRelocate(newer)
    const newerSnapshot = { ...hud.rendererPageSnapshot }
    releaseOlderMetrics()
    await olderRelocate

    assert.equal(hud.lastRelocateDetail, newer)
    assert.deepEqual(hud.rendererPageSnapshot, newerSnapshot)
    assert.deepEqual(history, ['newer'])
})


test('explicit relocation history is causal, validated, and consumed once per navigation', () => {
    const hud = new NavigationHUD({
        getRenderer: () => ({ currentIndex: 0, scrolled: false, bookDir: 'ltr' }),
    })
    hud.rendererPageSnapshot = null
    hud.currentLocationDescriptor = {
        cfi: null,
        fraction: 0.1,
        sectionIndex: 0,
        localSectionIndex: 0,
        rendererTotal: 10,
        pageItemKey: null,
        pageLabel: null,
        location: { current: 1, total: 10 },
        locationTotalHint: 10,
    }

    hud._handleRelocateHistory({
        reason: 'navigation',
        index: 0,
        sectionIndex: 0,
        fraction: 0.2,
        location: { current: 2, total: 10 },
    })
    assert.equal(hud.relocateStacks.back.length, 0)

    hud._handleRelocateHistory({
        reason: 'navigation',
        index: 0,
        sectionIndex: 0,
        fraction: 0.25,
        location: { current: 2.5, total: 10 },
        explicitRelocateHistorySource: 'untrusted-source',
        explicitRelocateHistoryMutationID: 'navigation-b',
    })
    assert.equal(hud.relocateStacks.back.length, 0)

    hud._handleRelocateHistory({
        reason: 'navigation',
        index: 0,
        sectionIndex: 0,
        fraction: 0.3,
        location: { current: 3, total: 10 },
        explicitRelocateHistorySource: 'goToPercent',
        explicitRelocateHistoryMutationID: 'navigation-c',
    })
    assert.equal(hud.relocateStacks.back.length, 1)

    hud._handleRelocateHistory({
        reason: 'navigation',
        index: 0,
        sectionIndex: 0,
        fraction: 0.4,
        location: { current: 4, total: 10 },
        explicitRelocateHistorySource: 'goToPercent',
        explicitRelocateHistoryMutationID: 'navigation-c',
    })
    assert.equal(hud.relocateStacks.back.length, 1)

    hud._handleRelocateHistory({
        reason: 'navigation',
        index: 0,
        sectionIndex: 0,
        fraction: 0.5,
        location: { current: 5, total: 10 },
        explicitRelocateHistorySource: 'goToHref',
        explicitRelocateHistoryMutationID: 'navigation-d',
    })
    assert.equal(hud.relocateStacks.back.length, 2)
})

test('a pending relocate-stack jump ignores an older turn and finalizes only its causal relocation', async () => {
    let acceptJump
    let ownedMutationID = null
    const jumpGate = new Promise(resolve => { acceptJump = resolve })
    const hud = new NavigationHUD({
        getRenderer: () => ({ currentIndex: 0, scrolled: false, bookDir: 'ltr' }),
        onJumpRequest: async (_descriptor, options) => {
            ownedMutationID = options?.explicitRelocateHistoryMutationID ?? null
            await jumpGate
            return true
        },
    })
    hud._updateRelocateButtons = () => {}
    hud.currentLocationDescriptor = {
        fraction: 0.8,
        sectionIndex: 2,
        localSectionIndex: 4,
        rendererTotal: 8,
    }
    hud.relocateStacks.back.push({
        fraction: 0.3,
        sectionIndex: 1,
        localSectionIndex: 2,
        rendererTotal: 8,
    })

    const request = hud._handleRelocateJump('back')
    assert.ok(hud.pendingRelocateJump)
    assert.equal(hud.pendingRelocateJump.mutationID, ownedMutationID)
    assert.equal(ownedMutationID, 'navigation-hud-relocate-1')

    hud.rendererPageSnapshot = { current: 6, total: 8, scrolled: false }
    const settledTurnOrigin = {
        reason: 'page',
        fraction: 0.9,
        index: 2,
        sectionIndex: 2,
        localSectionIndex: 5,
        rendererTotal: 8,
    }
    hud._handleRelocateHistory(settledTurnOrigin)
    assert.ok(hud.pendingRelocateJump)
    assert.equal(hud.relocateStacks.back.length, 1)
    assert.equal(hud.currentLocationDescriptor.localSectionIndex, 5)
    assert.equal(hud.pendingRelocateJump.preJumpDescriptor.localSectionIndex, 5)

    acceptJump()
    await request
    assert.ok(hud.pendingRelocateJump)

    hud.rendererPageSnapshot = { current: 4, total: 8, scrolled: false }
    hud._handleRelocateHistory({
        reason: 'navigation',
        fraction: 0.6,
        index: 2,
        sectionIndex: 2,
        localSectionIndex: 3,
        rendererTotal: 8,
        explicitRelocateHistorySource: 'relocate-button',
        explicitRelocateHistoryMutationID: 'stale-relocate-button-mutation',
    })
    assert.ok(hud.pendingRelocateJump)
    assert.equal(hud.relocateStacks.back.length, 1)
    assert.equal(hud.pendingRelocateJump.preJumpDescriptor.localSectionIndex, 3)

    hud._handleRelocateHistory({
        reason: 'navigation',
        fraction: 0.3,
        index: 1,
        sectionIndex: 1,
        localSectionIndex: 2,
        rendererTotal: 8,
        explicitRelocateHistorySource: 'relocate-button',
        explicitRelocateHistoryMutationID: ownedMutationID,
    })

    assert.equal(hud.pendingRelocateJump, null)
    assert.equal(hud.isProcessingRelocateJump, false)
    assert.equal(hud.relocateStacks.back.length, 0)
    assert.equal(hud.relocateStacks.forward.length, 1)
    assert.equal(hud.relocateStacks.forward[0].localSectionIndex, 3)
})

test('a newer explicit destination supersedes pending relocate-stack ownership and records history', async () => {
    let finishPendingRequest
    const pendingRequest = new Promise(resolve => { finishPendingRequest = resolve })
    const hud = new NavigationHUD({
        getRenderer: () => ({ currentIndex: 0, scrolled: false, bookDir: 'ltr' }),
        onJumpRequest: async () => await pendingRequest,
    })
    hud._updateRelocateButtons = () => {}
    hud.currentLocationDescriptor = {
        fraction: 0.8,
        sectionIndex: 2,
        localSectionIndex: 4,
        rendererTotal: 8,
    }
    hud.relocateStacks.back.push({
        fraction: 0.3,
        sectionIndex: 1,
        localSectionIndex: 2,
        rendererTotal: 8,
    })

    const olderRequest = hud._handleRelocateJump('back')
    assert.ok(hud.pendingRelocateJump)

    hud._handleRelocateHistory({
        reason: 'navigation',
        fraction: 0.95,
        index: 3,
        sectionIndex: 3,
        localSectionIndex: 6,
        rendererTotal: 8,
        explicitRelocateHistorySource: 'goToHref',
        explicitRelocateHistoryMutationID: 'reader-navigation-99',
    })

    assert.equal(hud.pendingRelocateJump, null)
    assert.equal(hud.isProcessingRelocateJump, false)
    assert.equal(hud.currentLocationDescriptor.sectionIndex, 3)
    assert.equal(hud.relocateStacks.back.length, 2)
    assert.equal(hud.relocateStacks.back.at(-1).sectionIndex, 2)

    finishPendingRequest(false)
    await olderRequest
    assert.equal(hud.currentLocationDescriptor.sectionIndex, 3)
    assert.equal(hud.relocateStacks.back.length, 2)
})

test('relocate-stack mutation IDs remain monotonic across completed jumps', async () => {
    const mutationIDs = []
    const hud = new NavigationHUD({
        getRenderer: () => ({ currentIndex: 0, scrolled: false, bookDir: 'ltr' }),
        onJumpRequest: async (_descriptor, options) => {
            mutationIDs.push(options?.explicitRelocateHistoryMutationID ?? null)
            return true
        },
    })
    hud._updateRelocateButtons = () => {}
    hud.currentLocationDescriptor = {
        fraction: 0.8,
        sectionIndex: 2,
        localSectionIndex: 4,
        rendererTotal: 8,
    }
    hud.relocateStacks.back.push({
        fraction: 0.3,
        sectionIndex: 1,
        localSectionIndex: 2,
        rendererTotal: 8,
    })

    await hud._handleRelocateJump('back')
    const firstMutationID = hud.pendingRelocateJump?.mutationID ?? null
    hud._handleRelocateHistory({
        reason: 'navigation',
        fraction: 0.3,
        index: 1,
        sectionIndex: 1,
        localSectionIndex: 2,
        rendererTotal: 8,
        explicitRelocateHistorySource: 'relocate-button',
        explicitRelocateHistoryMutationID: firstMutationID,
    })
    assert.equal(hud.pendingRelocateJump, null)

    hud.relocateStacks.back.push({
        fraction: 0.1,
        sectionIndex: 0,
        localSectionIndex: 1,
        rendererTotal: 8,
    })
    await hud._handleRelocateJump('back')

    assert.deepEqual(mutationIDs, [
        'navigation-hud-relocate-1',
        'navigation-hud-relocate-2',
    ])
    assert.equal(hud.pendingRelocateJump?.mutationID, 'navigation-hud-relocate-2')
})

test('late cleanup from an older relocate request cannot cancel a newer jump', async () => {
    let finishFirstRequest
    let requestCount = 0
    const firstRequest = new Promise(resolve => { finishFirstRequest = resolve })
    const hud = new NavigationHUD({
        getRenderer: () => ({ currentIndex: 0, scrolled: false, bookDir: 'ltr' }),
        onJumpRequest: async () => {
            requestCount += 1
            return requestCount === 1 ? await firstRequest : true
        },
    })
    hud._updateRelocateButtons = () => {}
    hud.currentLocationDescriptor = {
        fraction: 0.8,
        sectionIndex: 2,
        localSectionIndex: 4,
        rendererTotal: 8,
    }
    hud.relocateStacks.back.push({
        fraction: 0.3,
        sectionIndex: 1,
        localSectionIndex: 2,
        rendererTotal: 8,
    })

    const olderRequest = hud._handleRelocateJump('back')
    const olderMutationID = hud.pendingRelocateJump?.mutationID ?? null
    hud._handleRelocateHistory({
        reason: 'navigation',
        fraction: 0.3,
        index: 1,
        sectionIndex: 1,
        localSectionIndex: 2,
        rendererTotal: 8,
        explicitRelocateHistorySource: 'relocate-button',
        explicitRelocateHistoryMutationID: olderMutationID,
    })
    assert.equal(hud.pendingRelocateJump, null)

    hud.relocateStacks.back.push({
        fraction: 0.1,
        sectionIndex: 0,
        localSectionIndex: 1,
        rendererTotal: 8,
    })
    await hud._handleRelocateJump('back')
    const newerMutationID = hud.pendingRelocateJump?.mutationID ?? null
    assert.equal(newerMutationID, 'navigation-hud-relocate-2')

    finishFirstRequest(false)
    await olderRequest

    assert.equal(hud.pendingRelocateJump?.mutationID, newerMutationID)
    assert.equal(hud.isProcessingRelocateJump, true)
})

test('a superseded relocate-stack request releases pending jump ownership', async () => {
    const hud = new NavigationHUD({
        getRenderer: () => ({ currentIndex: 0, scrolled: false, bookDir: 'ltr' }),
        onJumpRequest: async () => false,
    })
    hud._updateRelocateButtons = () => {}
    hud.currentLocationDescriptor = {
        fraction: 0.8,
        sectionIndex: 2,
        localSectionIndex: 4,
        rendererTotal: 8,
    }
    hud.relocateStacks.back.push({
        fraction: 0.3,
        sectionIndex: 1,
        localSectionIndex: 2,
        rendererTotal: 8,
    })

    await hud._handleRelocateJump('back')

    assert.equal(hud.pendingRelocateJump, null)
    assert.equal(hud.isProcessingRelocateJump, false)
    assert.equal(hud.relocateStacks.back.length, 1)
})
