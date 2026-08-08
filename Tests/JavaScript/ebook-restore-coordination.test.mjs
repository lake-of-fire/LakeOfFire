import assert from 'node:assert/strict'
import test from 'node:test'

import {
    LatestRestoreTransactionCoordinator,
    PendingInitialRestoreMailbox,
    isRestoreTransactionSupersededError,
    AsyncTaskBarrier,
    LatestSerialOperationCoordinator,
    LifecycleGenerationCoordinator,
    NavigationIntentCoordinator,
    PageTurnAttemptCoordinator,
    PageTurnInvalidationCoordinator,
    SectionResourceLease,
    SinglePublicationRendererLifetime,
    activeRendererContents,
    authoritativeNativeLookupTargetCount,
    classifyPageTurnMovement,
    isReaderOperationCurrent,
    makeReaderPageTurnAttemptID,
    makeOwnedNavigationIntent,
    makeSyntheticRestoreLocator,
    mapContentRectToReaderViewport,
    nativeLookupTargetPostNeedsRetry,
    nativeLookupTargetResultsNeedRetry,
    nativeLookupViewportGeometrySignature,
    parseSyntheticRestoreLocator,
    runAcceptedRestoreNavigation,
    runRequiredRestoreNavigation,
    commitAfterMatchingRestoreTransactionsSettle,
    readerNavigationResultReachedTarget,
    readerNavigationResultWasCommitted,
    readerVisibleRendererNavigationRejection,
    readerPhysicalPagePositionChanged,
    readerRelocationDetailForCurrentOwnedNavigation,
    readerRelocationDetailWithNavigationIntent,
    resolveReaderFrameScale,
    scheduleTask,
    snapshotReaderNavigationIntent,
    shouldInvalidateVisibleSegmentGeometryForReason,
    shouldRejectReaderPageTurnQueue,
    shouldRunDelayedReaderPageAdvance,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-restore-coordination.js'

const deferred = () => {
    let resolve
    let reject
    const promise = new Promise((resolveValue, rejectValue) => {
        resolve = resolveValue
        reject = rejectValue
    })
    return { promise, resolve, reject }
}

test('page-turn attempt IDs use UUIDs when available and remain unique without Web Crypto', () => {
    const uuid = makeReaderPageTurnAttemptID({
        crypto: { randomUUID: () => 'page-turn-uuid' },
    })
    assert.equal(uuid, 'page-turn-uuid')

    const fallbackOptions = {
        crypto: null,
        now: () => 1234,
        random: () => 0.25,
    }
    const firstFallback = makeReaderPageTurnAttemptID(fallbackOptions)
    const secondFallback = makeReaderPageTurnAttemptID(fallbackOptions)
    assert.match(firstFallback, /^mnb-turn-[a-z0-9]+-[a-z0-9]+-[a-z0-9]+$/)
    assert.notEqual(secondFallback, firstFallback)

    const thrownFallback = makeReaderPageTurnAttemptID({
        crypto: { randomUUID: () => { throw new Error('unavailable') } },
        now: () => Number.NaN,
        random: () => Number.NaN,
    })
    assert.match(thrownFallback, /^mnb-turn-0-[a-z0-9]+-0$/)
})

test('navigation intent snapshots are immutable and detached from mutable callers', () => {
    const mutable = { source: 'goToHref', nested: { retained: true } }
    const snapshot = snapshotReaderNavigationIntent(mutable)
    mutable.source = 'mutated'

    assert.notEqual(snapshot, mutable)
    assert.equal(snapshot.source, 'goToHref')
    assert.equal(snapshot.nested, mutable.nested)
    assert.equal(Object.isFrozen(snapshot), true)
    assert.equal(snapshotReaderNavigationIntent(snapshot), snapshot)
    assert.equal(snapshotReaderNavigationIntent(null), null)
})


test('exact navigation motion time follows the causal renderer relocation', () => {
    const intent = Object.freeze({
        source: 'goToHref',
        motionStartedAtMs: 1234.5,
    })
    const inherited = readerRelocationDetailWithNavigationIntent({
        rendererDetail: { reason: 'navigation', index: 3 },
        navigationIntent: intent,
    })
    assert.deepEqual(inherited, {
        reason: 'navigation',
        index: 3,
        motionStartedAtMs: 1234.5,
    })

    const rendererOwned = {
        reason: 'navigation',
        index: 4,
        motionStartedAtMs: 2345.5,
    }
    assert.equal(readerRelocationDetailWithNavigationIntent({
        rendererDetail: rendererOwned,
        navigationIntent: intent,
    }), rendererOwned)
    assert.equal(readerRelocationDetailWithNavigationIntent({
        rendererDetail: { reason: 'scroll' },
        navigationIntent: { motionStartedAtMs: Number.NaN },
    }).motionStartedAtMs, undefined)
})

test('reader operations require exact reader, load, and optional operation ownership', () => {
    const reader = {}
    const renderer = {}
    const common = {
        activeReader: reader,
        expectedReader: reader,
        activeLoadToken: 7,
        expectedLoadToken: 7,
        activeRenderer: renderer,
        expectedRenderer: renderer,
    }
    assert.equal(isReaderOperationCurrent(common), true)
    assert.equal(isReaderOperationCurrent({ ...common, activeReader: {} }), false)
    assert.equal(isReaderOperationCurrent({ ...common, activeLoadToken: 8 }), false)
    assert.equal(isReaderOperationCurrent({ ...common, activeRenderer: {} }), false)
    assert.equal(isReaderOperationCurrent({
        ...common,
        activeOperationGeneration: 3,
        expectedOperationGeneration: 3,
    }), true)
    assert.equal(isReaderOperationCurrent({
        ...common,
        activeOperationGeneration: 4,
        expectedOperationGeneration: 3,
    }), false)
})

test('reader lifecycle generations abort and reject superseded asynchronous work', async () => {
    const lifecycle = new LifecycleGenerationCoordinator()
    const first = lifecycle.begin()
    let firstAbortCount = 0
    first.signal.addEventListener('abort', () => firstAbortCount += 1)

    const second = lifecycle.begin()
    assert.equal(firstAbortCount, 1)
    assert.equal(first.signal.aborted, true)
    assert.equal(lifecycle.isCurrent(first), false)
    assert.equal(lifecycle.isCurrent(second), true)

    await Promise.resolve()
    assert.equal(lifecycle.isCurrent(first), false)
    assert.equal(lifecycle.isCurrent(second), true)
})

test('reader lifecycle invalidation aborts the current generation exactly once', () => {
    const lifecycle = new LifecycleGenerationCoordinator()
    const current = lifecycle.begin()
    let abortCount = 0
    current.signal.addEventListener('abort', () => abortCount += 1)

    lifecycle.invalidate()
    lifecycle.invalidate()

    assert.equal(abortCount, 1)
    assert.equal(current.signal.aborted, true)
    assert.equal(lifecycle.isCurrent(current), false)
})

test('renderer publication lifetime permits one open and remains terminal after destroy', () => {
    const lifetime = new SinglePublicationRendererLifetime()

    assert.equal(lifetime.isOpen, false)
    assert.equal(lifetime.isDestroyed, false)
    assert.equal(lifetime.claimOpen(), true)
    assert.equal(lifetime.isOpen, true)
    assert.equal(lifetime.claimOpen(), false)

    assert.equal(lifetime.destroy(), true)
    assert.equal(lifetime.isOpen, false)
    assert.equal(lifetime.isDestroyed, true)
    assert.equal(lifetime.destroy(), false)
    assert.equal(lifetime.claimOpen(), false)
})

test('renderer publication lifetime can be terminalized before open', () => {
    const lifetime = new SinglePublicationRendererLifetime()

    assert.equal(lifetime.destroy(), true)
    assert.equal(lifetime.claimOpen(), false)
    assert.equal(lifetime.isDestroyed, true)
})

test('latest serial operations never overlap and coalesce queued destinations', async () => {
    const coordinator = new LatestSerialOperationCoordinator()
    const firstGate = deferred()
    const thirdGate = deferred()
    const events = []
    let activeCount = 0
    let maximumActiveCount = 0
    const operation = (name, gate) => async () => {
        activeCount += 1
        maximumActiveCount = Math.max(maximumActiveCount, activeCount)
        events.push(`${name}:start`)
        await gate.promise
        events.push(`${name}:finish`)
        activeCount -= 1
        return name
    }

    const first = coordinator.run(operation('first', firstGate))
    const second = coordinator.run(async () => 'second')
    const third = coordinator.run(operation('third', thirdGate))

    assert.equal(coordinator.busy, true)
    assert.deepEqual(await second, {
        executed: false,
        cancelled: true,
        reason: 'superseded',
        operationID: 2,
    })

    firstGate.resolve()
    assert.deepEqual(await first, {
        executed: true,
        cancelled: false,
        operationID: 1,
        value: 'first',
    })

    thirdGate.resolve()
    assert.deepEqual(await third, {
        executed: true,
        cancelled: false,
        operationID: 3,
        value: 'third',
    })
    assert.deepEqual(events, [
        'first:start',
        'first:finish',
        'third:start',
        'third:finish',
    ])
    assert.equal(maximumActiveCount, 1)
    assert.equal(coordinator.busy, false)
})

test('latest serial operation cancellation drains queued work and masks a late active result', async () => {
    const coordinator = new LatestSerialOperationCoordinator()
    const gate = deferred()
    const active = coordinator.run(async () => {
        await gate.promise
        return 'late-value'
    })
    const queued = coordinator.run(async () => 'never-runs')

    coordinator.cancel('readerDisposed')
    assert.deepEqual(await queued, {
        executed: false,
        cancelled: true,
        reason: 'readerDisposed',
        operationID: 2,
    })
    gate.resolve()
    assert.deepEqual(await active, {
        executed: false,
        cancelled: true,
        reason: 'readerDisposed',
        operationID: 1,
    })
    assert.equal(coordinator.busy, false)
})

test('latest serial operations continue with queued work after an active rejection', async () => {
    const coordinator = new LatestSerialOperationCoordinator()
    const gate = deferred()
    const active = coordinator.run(async () => {
        await gate.promise
        throw new Error('active failed')
    })
    const queued = coordinator.run(async () => 'recovered')

    gate.resolve()
    await assert.rejects(active, /active failed/)
    assert.deepEqual(await queued, {
        executed: true,
        cancelled: false,
        operationID: 2,
        value: 'recovered',
    })
    assert.equal(coordinator.busy, false)
})

test('reader lifecycle invalidation removes signal-owned global listeners', () => {
    const lifecycle = new LifecycleGenerationCoordinator()
    const current = lifecycle.begin()
    const target = new EventTarget()
    let calls = 0
    target.addEventListener('resize', () => calls += 1, { signal: current.signal })

    target.dispatchEvent(new Event('resize'))
    lifecycle.invalidate()
    target.dispatchEvent(new Event('resize'))

    assert.equal(calls, 1)
})

test('delayed mark-read auto-advance fails closed after any intervening movement or navigation owner', () => {
    const base = { index: 2, sectionIndex: 2, page: 4, start: 120 }
    assert.equal(readerPhysicalPagePositionChanged(base, { ...base }), false)
    assert.equal(readerPhysicalPagePositionChanged(base, { ...base, page: 5 }), true)
    assert.equal(readerPhysicalPagePositionChanged(base, { ...base, start: 121 }), true)
    assert.equal(readerPhysicalPagePositionChanged(null, base), null)

    assert.equal(shouldRunDelayedReaderPageAdvance({ before: base, after: { ...base } }), true)
    assert.equal(shouldRunDelayedReaderPageAdvance({
        before: base,
        after: { ...base, sectionIndex: 3 },
    }), false)
    assert.equal(shouldRunDelayedReaderPageAdvance({
        before: base,
        after: { ...base },
        pageTurnInFlight: true,
    }), false)
    assert.equal(shouldRunDelayedReaderPageAdvance({
        before: base,
        after: { ...base },
        ownedNavigationInFlight: true,
    }), false)
})

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


test('accepted restore navigation requires a literal renderer acceptance receipt', async () => {
    assert.deepEqual(await runAcceptedRestoreNavigation(async () => true), {
        ok: true,
        value: true,
        error: null,
    })

    for (const receipt of [false, undefined, null, { ignored: true }, { moved: false }]) {
        const result = await runAcceptedRestoreNavigation(async () => receipt)
        assert.equal(result.ok, false)
        assert.equal(result.value, receipt)
        assert.equal(result.error?.code, 'restore-navigation-not-accepted')
        assert.equal(result.error?.receipt, receipt ?? null)
    }
})


test('latest restore transaction supersedes an older suspended operation promptly', async () => {
    const coordinator = new LatestRestoreTransactionCoordinator()
    const older = coordinator.begin({ label: 'older' })
    let resolveOlder = null
    const olderResult = coordinator.wait(older, () => new Promise(resolve => {
        resolveOlder = resolve
    })).then(
        value => ({ value }),
        error => ({ error })
    )

    const newer = coordinator.begin({ label: 'newer' })
    const settledOlder = await olderResult

    assert.equal(isRestoreTransactionSupersededError(settledOlder.error), true)
    assert.equal(settledOlder.error.reason, 'superseded-by-newer-restore')
    assert.equal(coordinator.isCurrent(older), false)
    assert.equal(coordinator.isCurrent(newer), true)

    resolveOlder?.('late-value')
    assert.equal(coordinator.finish(older), false)
    assert.equal(coordinator.finish(newer), true)
})

test('supersession before the scheduled operation starts prevents its side effect', async () => {
    const coordinator = new LatestRestoreTransactionCoordinator()
    const older = coordinator.begin()
    let started = false
    const result = coordinator.wait(older, () => {
        started = true
        return 'unexpected'
    }).then(
        value => ({ value }),
        error => ({ error })
    )

    const newer = coordinator.begin()
    const settled = await result

    assert.equal(started, false)
    assert.equal(isRestoreTransactionSupersededError(settled.error), true)
    assert.equal(coordinator.isCurrent(newer), true)
    assert.equal(coordinator.finish(newer), true)
})

test('a cancelled restore absorbs a late operation rejection without affecting the newer owner', async () => {
    const coordinator = new LatestRestoreTransactionCoordinator()
    const older = coordinator.begin({ label: 'older' })
    let rejectOlder = null
    const olderResult = coordinator.wait(older, () => new Promise((_, reject) => {
        rejectOlder = reject
    })).then(
        value => ({ value }),
        error => ({ error })
    )

    const newer = coordinator.begin({ label: 'newer' })
    const settledOlder = await olderResult
    assert.equal(isRestoreTransactionSupersededError(settledOlder.error), true)

    rejectOlder?.(new Error('late navigation failure'))
    await new Promise(resolve => setImmediate(resolve))

    assert.equal(coordinator.isCurrent(newer), true)
    assert.equal(coordinator.finish(newer), true)
})

test('cancelling an exact restore owner does not finish a newer owner', async () => {
    const coordinator = new LatestRestoreTransactionCoordinator()
    const older = coordinator.begin()
    const newer = coordinator.begin()

    assert.equal(coordinator.cancel(older, 'late-cancel'), false)
    assert.equal(coordinator.isCurrent(newer), true)
    assert.equal(coordinator.finish(older), false)
    assert.equal(coordinator.finish(newer), true)
})

test('restore transaction wait preserves owned failures', async () => {
    const coordinator = new LatestRestoreTransactionCoordinator()
    const owner = coordinator.begin()
    const failure = new Error('navigation failed')

    await assert.rejects(
        coordinator.wait(owner, async () => {
            throw failure
        }),
        error => error === failure
    )
    assert.equal(coordinator.isCurrent(owner), true)
    assert.equal(coordinator.finish(owner), true)
})

test('matching restore settlement waits for the exact active owner and follows replacement owners', async () => {
    const coordinator = new LatestRestoreTransactionCoordinator()
    const first = coordinator.begin({ reader: 'reader-a', loadToken: 1 })
    let currentLoad = true
    let resolved = false
    const waiting = commitAfterMatchingRestoreTransactionsSettle({
        coordinator,
        matches: owner => owner.context.reader === 'reader-a' && owner.context.loadToken === 1,
        isCurrent: () => currentLoad,
        commit: () => true,
    }).then(value => {
        resolved = true
        return value
    })

    await Promise.resolve()
    assert.equal(resolved, false)

    const second = coordinator.begin({ reader: 'reader-a', loadToken: 1 })
    await first.settled
    await Promise.resolve()
    assert.equal(resolved, false)

    assert.equal(coordinator.finish(second), true)
    assert.equal(await waiting, true)
})

test('matching restore settlement exits when its enclosing load is superseded', async () => {
    const coordinator = new LatestRestoreTransactionCoordinator()
    const owner = coordinator.begin({ reader: 'reader-a', loadToken: 1 })
    let currentLoad = true
    const waiting = commitAfterMatchingRestoreTransactionsSettle({
        coordinator,
        matches: candidate => candidate === owner,
        isCurrent: () => currentLoad,
        commit: () => true,
    })

    currentLoad = false
    assert.equal(coordinator.cancel(owner, 'load-superseded'), true)
    assert.equal(await waiting, false)
})


test('matching restore settlement commits without an asynchronous gap after the final owner check', async () => {
    const coordinator = new LatestRestoreTransactionCoordinator()
    const order = []

    queueMicrotask(() => {
        order.push('replacement-started')
        coordinator.begin({ reader: 'reader-a', loadToken: 1 })
    })

    const committed = await commitAfterMatchingRestoreTransactionsSettle({
        coordinator,
        matches: owner => owner.context.reader === 'reader-a' && owner.context.loadToken === 1,
        commit: () => {
            order.push('ready-committed')
            assert.equal(coordinator.current, null)
            return true
        },
    })

    assert.equal(committed, true)
    assert.deepEqual(order, ['ready-committed', 'replacement-started'])
    coordinator.cancelCurrent('test-cleanup')
})

test('pending initial restore mailbox is exact-load, latest-value, and close owned', () => {
    const mailbox = new PendingInitialRestoreMailbox({ loadToken: 7, url: 'book-a.epub' })
    const first = { cfi: 'first' }
    const latest = { cfi: 'latest' }

    assert.equal(mailbox.matches({ loadToken: 7, url: 'book-a.epub' }), true)
    assert.equal(mailbox.matches({ loadToken: 8, url: 'book-a.epub' }), false)
    assert.equal(mailbox.matches({ loadToken: 7, url: 'book-b.epub' }), false)
    assert.equal(mailbox.queue(first), true)
    assert.equal(mailbox.queue(latest), true)
    assert.equal(mailbox.hasPending, true)
    assert.equal(mailbox.take(), latest)
    assert.equal(mailbox.hasPending, false)
    assert.equal(mailbox.queue(first), true)
    assert.equal(mailbox.closeAndTake(), first)
    assert.equal(mailbox.queue(latest), false)
    assert.equal(mailbox.take(), null)
    assert.equal(mailbox.closeAndTake(), null)
    assert.equal(mailbox.close(), false)
})


test('mailbox close-and-take atomically owns the final queued restore', () => {
    const mailbox = new PendingInitialRestoreMailbox({ loadToken: 3, url: 'book.epub' })
    const finalRestore = { cfi: 'final' }

    assert.equal(mailbox.queue(finalRestore), true)
    assert.equal(mailbox.closeAndTake(), finalRestore)
    assert.equal(mailbox.isClosed, true)
    assert.equal(mailbox.hasPending, false)
    assert.equal(mailbox.queue({ cfi: 'late' }), false)
    assert.equal(mailbox.closeAndTake(), null)
})

test('lookup, native-owned, and renderer gestures reject the reader-level turn queue', () => {
    assert.equal(shouldRejectReaderPageTurnQueue(), false)
    assert.equal(shouldRejectReaderPageTurnQueue({ ignoreIfPageTurnInFlight: true }), true)
    assert.equal(shouldRejectReaderPageTurnQueue({
        details: { lookupOwnedPageTurn: true },
    }), true)
    assert.equal(shouldRejectReaderPageTurnQueue({
        details: { nativeLookupSuppressionOwned: true },
    }), true)
    assert.equal(shouldRejectReaderPageTurnQueue({
        details: { rendererGestureOwnedPageTurn: true },
    }), true)
    assert.equal(shouldRejectReaderPageTurnQueue({
        details: { rejectReaderQueue: true },
    }), true)
})

test('active renderer contents preserve every explicitly visible fixed-layout page', () => {
    const left = { index: 4, isVisible: true }
    const right = { index: 5, isVisible: true }
    const hidden = { index: 6, isVisible: false }
    assert.deepEqual(activeRendererContents({
        contents: [left, right, hidden],
        currentIndex: 4,
    }), [left, right])
})

test('active renderer contents fall back to current index for legacy renderers', () => {
    const current = { index: 4 }
    const adjacent = { index: 5 }
    const unindexed = { id: 'overlay' }
    assert.deepEqual(activeRendererContents({
        contents: [current, adjacent, unindexed],
        currentIndex: 4,
    }), [current, unindexed])
})

test('native lookup target publication requires settled viewport geometry and a complete target set', () => {
    assert.equal(authoritativeNativeLookupTargetCount({ visibleSegmentCount: 0, targetCount: 0 }), null)
    assert.equal(authoritativeNativeLookupTargetCount({
        hasUsableViewportGeometry: false,
        visibleSegmentCount: 0,
        targetCount: 0,
    }), null)
    assert.equal(authoritativeNativeLookupTargetCount({
        hasUsableViewportGeometry: true,
        visibleSegmentCount: 0,
        targetCount: 0,
    }), 0)
    assert.equal(authoritativeNativeLookupTargetCount({
        hasUsableViewportGeometry: true,
        visibleSegmentCount: 3,
        targetCount: 3,
    }), 3)
    assert.equal(authoritativeNativeLookupTargetCount({
        hasUsableViewportGeometry: true,
        visibleSegmentCount: 3,
        targetCount: 0,
    }), null)
    assert.equal(authoritativeNativeLookupTargetCount({
        hasUsableViewportGeometry: true,
        visibleSegmentCount: 3,
        targetCount: 2,
    }), null)
    assert.equal(authoritativeNativeLookupTargetCount({
        hasUsableViewportGeometry: true,
        visibleSegmentCount: -1,
        targetCount: 0,
    }), null)
    assert.equal(authoritativeNativeLookupTargetCount({
        hasUsableViewportGeometry: true,
        visibleSegmentCount: 0,
        targetCount: -1,
    }), null)
})

test('reader frame scale requires an independent local viewport basis', () => {
    assert.deepEqual(resolveReaderFrameScale({
        frameWidth: 500,
        frameHeight: 250,
        localViewportWidth: 1000,
        localViewportHeight: 1000,
    }), {
        scaleX: 0.5,
        scaleY: 0.25,
    })
    assert.equal(resolveReaderFrameScale({
        frameWidth: 500,
        frameHeight: 250,
        localViewportWidth: 0,
        localViewportHeight: 0,
    }), null)
    assert.equal(resolveReaderFrameScale({
        frameWidth: 500,
        frameHeight: 250,
    }), null)
})

test('native lookup viewport geometry identity changes with frame scale and placement', () => {
    const baseline = {
        hasUsableViewportGeometry: true,
        hasExpectedPaginatorContainer: false,
        viewportLeft: 20,
        viewportTop: 40,
        viewportWidth: 500,
        viewportHeight: 250,
        localViewportWidth: 1000,
        localViewportHeight: 1000,
        frameScaleX: 0.5,
        frameScaleY: 0.25,
        frameRect: { left: 20, top: 40, width: 500, height: 250 },
        visibleBounds: { left: 0, top: 0, right: 1000, bottom: 1000 },
    }
    const signature = nativeLookupViewportGeometrySignature(baseline)
    assert.equal(nativeLookupViewportGeometrySignature({ ...baseline }), signature)
    assert.notEqual(nativeLookupViewportGeometrySignature({
        ...baseline,
        frameScaleX: 0.4,
        frameRect: { ...baseline.frameRect, width: 400 },
    }), signature)
    assert.notEqual(nativeLookupViewportGeometrySignature({
        ...baseline,
        viewportLeft: 30,
        frameRect: { ...baseline.frameRect, left: 30 },
    }), signature)
    assert.notEqual(nativeLookupViewportGeometrySignature({
        ...baseline,
        hasUsableViewportGeometry: false,
    }), signature)
})

test('native lookup rects map transformed fixed-layout coordinates into the reader viewport', () => {
    assert.deepEqual(mapContentRectToReaderViewport({
        rect: { left: 40, top: 80, width: 120, height: 60 },
        frameLeft: 200,
        frameTop: 100,
        frameScaleX: 0.5,
        frameScaleY: 0.25,
    }), {
        left: 220,
        top: 120,
        width: 60,
        height: 15,
    })
    assert.equal(mapContentRectToReaderViewport({
        rect: { left: 0, top: 0, width: 10, height: 10 },
        frameScaleX: 0,
        frameScaleY: 1,
    }), null)
})

test('reader geometry invalidation recognizes resize and orientation events with explicit reasons', () => {
    for (const reason of [
        'window-resize',
        'visual-viewport-resize',
        'screen-orientation-change',
        'renderer.relocate',
        'page-turn-start',
    ]) {
        assert.equal(shouldInvalidateVisibleSegmentGeometryForReason(reason), true, reason)
    }
    assert.equal(shouldInvalidateVisibleSegmentGeometryForReason('status-hydration'), false)
    assert.equal(shouldInvalidateVisibleSegmentGeometryForReason(), false)
})

test('native lookup target readiness distinguishes authoritative empty publication from unavailable posting', () => {
    assert.equal(nativeLookupTargetPostNeedsRetry(null), true)
    assert.equal(nativeLookupTargetPostNeedsRetry({}), true)
    assert.equal(nativeLookupTargetPostNeedsRetry({ nativeLookupTargetCount: -1 }), true)
    assert.equal(nativeLookupTargetPostNeedsRetry({ nativeLookupTargetCount: 0 }), false)
    assert.equal(nativeLookupTargetPostNeedsRetry({ nativeLookupTargetCount: 4 }), false)
})

test('all active documents must publish authoritative native lookup targets before a turn settles', () => {
    assert.equal(nativeLookupTargetResultsNeedRetry(), true)
    assert.equal(nativeLookupTargetResultsNeedRetry([]), true)
    assert.equal(nativeLookupTargetResultsNeedRetry([
        { nativeLookupTargetCount: 0 },
        { nativeLookupTargetCount: 4 },
    ]), false)
    assert.equal(nativeLookupTargetResultsNeedRetry([
        { nativeLookupTargetCount: 4 },
        null,
    ]), true)
})

test('page-turn movement receipts treat explicit ignored and failed results as authoritative no-move', () => {
    assert.deepEqual(classifyPageTurnMovement(true), { moved: true, authoritative: true })
    assert.deepEqual(classifyPageTurnMovement({ moved: true }), { moved: true, authoritative: true })
    for (const result of [false, { moved: false }, { ignored: true }, { failed: true }, { superseded: true }]) {
        assert.deepEqual(classifyPageTurnMovement(result), { moved: false, authoritative: true })
    }
    assert.deepEqual(classifyPageTurnMovement(undefined), { moved: null, authoritative: false })
})

test('page-turn invalidations can only be consumed by their exact generation and owner', () => {
    const coordinator = new PageTurnInvalidationCoordinator()
    const first = coordinator.begin('swipe', { snapshot: 'first' })
    const second = coordinator.begin('lookup', { snapshot: 'second' })

    assert.equal(coordinator.has({ generation: first.generation, owner: first.owner }), false)
    assert.deepEqual(coordinator.settle(first), { snapshot: 'first' })
    assert.equal(coordinator.settle(first), null)
    assert.deepEqual(coordinator.commit(second), { snapshot: 'second' })
    assert.equal(coordinator.size, 0)
})

test('page-turn attempts are adopted before an ignored busy-chain completion', () => {
    const coordinator = new PageTurnAttemptCoordinator()
    coordinator.adopt('attempt-a', {
        lookupNavigationToken: 'token-a',
        motionStartedAtMs: 101.25,
    })
    coordinator.adopt('attempt-a', {
        lookupNavigationToken: 'replacement-token',
        motionStartedAtMs: 202.5,
        ignored: true,
    })

    assert.deepEqual(coordinator.complete('attempt-a'), {
        attemptID: 'attempt-a',
        lookupNavigationToken: 'token-a',
        motionStartedAtMs: 101.25,
        ignored: true,
    })
    assert.equal(coordinator.has('attempt-a'), false)
})

test('page-turn attempt disposal drains every adopted owner exactly once', () => {
    const coordinator = new PageTurnAttemptCoordinator()
    coordinator.adopt('attempt-a', { lookupNavigationToken: 'token-a' })
    coordinator.adopt('attempt-b', { lookupNavigationToken: 'token-b' })

    assert.deepEqual(coordinator.drain(), [
        {
            attemptID: 'attempt-a',
            lookupNavigationToken: 'token-a',
        },
        {
            attemptID: 'attempt-b',
            lookupNavigationToken: 'token-b',
        },
    ])
    assert.deepEqual(coordinator.drain(), [])
    assert.equal(coordinator.has('attempt-a'), false)
    assert.equal(coordinator.has('attempt-b'), false)
})

test('async task barrier drains work appended while an earlier task settles', async () => {
    const barrier = new AsyncTaskBarrier()
    const events = []
    barrier.add(Promise.resolve().then(() => {
        events.push('first')
        barrier.add(Promise.resolve().then(() => events.push('second')))
    }))

    await barrier.wait()
    assert.deepEqual(events, ['first', 'second'])
    assert.equal(barrier.size, 0)
})

test('async task barrier absorbs rejected relocation work while awaiting the chain', async () => {
    const barrier = new AsyncTaskBarrier()
    barrier.add(Promise.reject(new Error('relocation failed')))
    await barrier.wait()
    assert.equal(barrier.size, 0)
})

test('scheduled target readiness remains pending until its scheduler runs', async () => {
    const barrier = new AsyncTaskBarrier()
    const events = []
    let runScheduledTask = null
    barrier.add(scheduleTask(
        callback => { runScheduledTask = callback },
        () => { events.push('targets-ready') }
    ))
    const settled = barrier.wait().then(() => events.push('display-ready'))

    await Promise.resolve()
    assert.deepEqual(events, [])
    assert.equal(typeof runScheduledTask, 'function')

    runScheduledTask()
    await settled
    assert.deepEqual(events, ['targets-ready', 'display-ready'])
})

test('scheduled target readiness reports errors and still releases the barrier', async () => {
    const errors = []
    await scheduleTask(
        callback => callback(),
        () => { throw new Error('target collection failed') },
        error => errors.push(error.message)
    )
    assert.deepEqual(errors, ['target collection failed'])

    await scheduleTask(
        () => { throw new Error('scheduler failed') },
        () => assert.fail('task should not run'),
        error => errors.push(error.message)
    )
    assert.deepEqual(errors, ['target collection failed', 'scheduler failed'])
})


test('navigation intents cannot resurrect an older operation that completed first', () => {
    const coordinator = new NavigationIntentCoordinator()
    const mutableIntent = { source: 'first' }
    const first = coordinator.begin(mutableIntent)
    mutableIntent.source = 'mutated-after-begin'
    const second = coordinator.begin({ source: 'second' })

    assert.equal(Object.isFrozen(first.intent), true)
    assert.deepEqual(first.intent, { source: 'first' })
    assert.equal(coordinator.has(first), true)
    assert.equal(coordinator.has(second), true)
    assert.deepEqual(coordinator.current, { source: 'second' })
    assert.equal(coordinator.end(first), true)
    assert.equal(coordinator.has(first), false)
    assert.deepEqual(coordinator.current, { source: 'second' })
    assert.equal(coordinator.end(second), true)
    assert.equal(coordinator.has(second), false)
    assert.equal(coordinator.current, null)
    assert.equal(coordinator.size, 0)
})

test('navigation intents restore an outer operation only while it remains active', () => {
    const coordinator = new NavigationIntentCoordinator()
    const outer = coordinator.begin({ source: 'outer' })
    const inner = coordinator.begin({ source: 'inner' })

    assert.equal(coordinator.end(inner), true)
    assert.deepEqual(coordinator.current, { source: 'outer' })
    assert.equal(coordinator.end(inner), false)
    assert.equal(coordinator.end(outer), true)
    assert.equal(coordinator.current, null)
})


test('explicit relocate history ownership is attached only to the executing Reader navigation', () => {
    const baseIntent = { source: 'goToPercent', target: 'view.goToFraction' }
    const owned = makeOwnedNavigationIntent({
        intent: baseIntent,
        requestGeneration: 17,
        explicitRelocateHistorySource: 'goToPercent',
    })

    assert.deepEqual(owned, {
        ...baseIntent,
        explicitRelocateHistorySource: 'goToPercent',
        explicitRelocateHistoryMutationID: 'reader-navigation-17',
        explicitRelocateHistoryRequestGeneration: 17,
    })
    assert.equal(Object.isFrozen(owned), true)
    assert.deepEqual(baseIntent, { source: 'goToPercent', target: 'view.goToFraction' })
    assert.equal(makeOwnedNavigationIntent({
        intent: baseIntent,
        requestGeneration: 18,
    }), baseIntent)
    assert.equal(makeOwnedNavigationIntent({
        intent: baseIntent,
        requestGeneration: 0,
        explicitRelocateHistorySource: 'goToPercent',
    }), baseIntent)

    assert.deepEqual(makeOwnedNavigationIntent({
        intent: baseIntent,
        requestGeneration: 19,
        explicitRelocateHistorySource: 'relocate-button',
        explicitRelocateHistoryMutationID: 'navigation-hud-relocate-4',
    }), {
        ...baseIntent,
        explicitRelocateHistorySource: 'relocate-button',
        explicitRelocateHistoryMutationID: 'navigation-hud-relocate-4',
        explicitRelocateHistoryRequestGeneration: 19,
    })
})


test('stale Reader-owned relocation cannot mutate current navigation history', () => {
    const stale = {
        reason: 'navigation',
        index: 3,
        explicitRelocateHistorySource: 'goToHref',
        explicitRelocateHistoryMutationID: 'reader-navigation-7',
        explicitRelocateHistoryRequestGeneration: 7,
    }
    const stripped = readerRelocationDetailForCurrentOwnedNavigation({
        detail: stale,
        currentRequestGeneration: 8,
    })
    assert.deepEqual(stripped, { reason: 'navigation', index: 3 })
    assert.notEqual(stripped, stale)
    assert.equal(readerRelocationDetailForCurrentOwnedNavigation({
        detail: stale,
        currentRequestGeneration: 7,
    }), stale)
    const rendererOwned = {
        reason: 'navigation',
        explicitRelocateHistorySource: 'renderer-owned',
        explicitRelocateHistoryMutationID: 'renderer-owned-1',
    }
    assert.equal(readerRelocationDetailForCurrentOwnedNavigation({
        detail: rendererOwned,
        currentRequestGeneration: 99,
    }), rendererOwned)
})


test('restore target satisfaction remains distinct from physical movement', () => {
    const alreadyVisible = {
        ignored: true,
        moved: false,
        targetSatisfied: true,
        reason: 'alreadyAtVisibleRendererTarget',
    }

    assert.equal(readerNavigationResultReachedTarget(undefined), true)
    assert.equal(readerNavigationResultReachedTarget(true), true)
    assert.equal(readerNavigationResultReachedTarget({ moved: true }), true)
    assert.equal(readerNavigationResultReachedTarget(alreadyVisible), true)
    assert.equal(readerNavigationResultWasCommitted(alreadyVisible), false)

    for (const rejected of [
        false,
        null,
        {},
        { moved: false },
        { ignored: true, moved: false },
        { targetSatisfied: true, failed: true },
        { targetSatisfied: true, aborted: true },
        { targetSatisfied: true, cancelled: true },
        { targetSatisfied: true, superseded: true },
        { targetSatisfied: true, destroyed: true },
        { targetSatisfied: true, committed: false },
        { targetSatisfied: true, executed: false },
        { targetSatisfied: true, ok: false },
        { targetSatisfied: true, succeeded: false },
    ]) {
        assert.equal(readerNavigationResultReachedTarget(rejected), false)
    }
})

test('direct Reader navigation accepts legacy success but rejects explicit uncommitted receipts', () => {
    assert.equal(readerNavigationResultWasCommitted(undefined), true)
    assert.equal(readerNavigationResultWasCommitted(true), true)
    assert.equal(readerNavigationResultWasCommitted({ moved: true }), true)
    assert.equal(readerNavigationResultWasCommitted({}), false)
    assert.equal(readerNavigationResultWasCommitted({ committed: true }), true)
    assert.equal(readerNavigationResultWasCommitted(false), false)
    assert.equal(readerNavigationResultWasCommitted(null), false)
    assert.equal(readerNavigationResultWasCommitted(0), false)
    assert.equal(readerNavigationResultWasCommitted('success'), false)
    assert.equal(readerNavigationResultWasCommitted({ moved: false }), false)
    assert.equal(readerNavigationResultWasCommitted({ ok: false }), false)
    assert.equal(readerNavigationResultWasCommitted({ succeeded: false }), false)
    assert.equal(readerNavigationResultWasCommitted({ aborted: true }), false)
    assert.equal(readerNavigationResultWasCommitted({ canceled: true }), false)
    assert.equal(readerNavigationResultWasCommitted({ ignored: true }), false)
    assert.equal(readerNavigationResultWasCommitted({ superseded: true }), false)
    assert.equal(readerNavigationResultWasCommitted({ destroyed: true }), false)
    assert.equal(readerNavigationResultWasCommitted({ committed: false }), false)
    assert.equal(readerNavigationResultWasCommitted({ failureReason: 'malformedReceipt' }), false)
    assert.equal(readerNavigationResultWasCommitted({}), false)
})


test('visible renderer guard rejects index-only duplicates with an explicit no-move receipt', () => {
    const alreadyVisible = {
        ignored: true,
        moved: false,
        targetSatisfied: true,
        reason: 'alreadyAtVisibleRendererTarget',
    }
    assert.deepEqual(readerVisibleRendererNavigationRejection({
        target: { index: 2 },
        currentIndex: 2,
    }), alreadyVisible)
    assert.equal(readerNavigationResultWasCommitted(alreadyVisible), false)
    assert.equal(readerVisibleRendererNavigationRejection({
        target: { index: 3 },
        currentIndex: 2,
    }), null)
})

test('visible renderer guard rejects a superseded owner before considering target visibility', () => {
    const expected = {
        superseded: true,
        moved: false,
        reason: 'readerNavigationSuperseded',
    }
    assert.deepEqual(readerVisibleRendererNavigationRejection({
        target: { index: 2 },
        currentIndex: 2,
        navigationIsCurrent: () => false,
    }), expected)
    assert.deepEqual(readerVisibleRendererNavigationRejection({
        target: { index: 3 },
        currentIndex: 2,
        navigationIsCurrent: () => false,
    }), expected)
})

test('visible renderer guard never suppresses positional, selection, or renderer-specific navigation', () => {
    const fragmentAnchor = () => ({})
    for (const target of [
        { index: 2, anchor: 0.5 },
        { index: 2, anchor: fragmentAnchor },
        { index: 2, anchor: { type: 'renderer-anchor' } },
        { index: 2, localPage: 2 },
        { index: 2, select: true },
        { index: 2, side: 'right' },
        { index: 2, rendererPosition: { page: 3 } },
        { index: 2, reason: 'restore' },
        { index: 1.6 },
        { index: -1 },
    ]) {
        assert.equal(readerVisibleRendererNavigationRejection({
            target,
            currentIndex: 2,
        }), null)
    }
})

test('section resource lease releases a held load exactly once after early teardown', () => {
    let unloadCount = 0
    const lease = new SectionResourceLease({
        unload() { unloadCount += 1 },
    })

    assert.equal(lease.release(), false)
    assert.equal(unloadCount, 0)
    assert.equal(lease.markLoaded(), true)
    assert.equal(unloadCount, 1)
    assert.equal(lease.release(), false)
    assert.equal(lease.markLoaded(), false)
    assert.equal(unloadCount, 1)
})

test('section resource lease distinguishes a failed acquisition from an acquired resource', () => {
    let unloadCount = 0
    const failedLease = new SectionResourceLease({
        unload() { unloadCount += 1 },
    })
    assert.equal(failedLease.release(), false)
    assert.equal(failedLease.markFailed(), true)
    assert.equal(failedLease.release(), false)

    const loadedLease = new SectionResourceLease({
        unload() { unloadCount += 1 },
    })
    assert.equal(loadedLease.markLoaded(), true)
    assert.equal(loadedLease.release(), true)
    assert.equal(loadedLease.release(), false)
    assert.equal(unloadCount, 1)
})
