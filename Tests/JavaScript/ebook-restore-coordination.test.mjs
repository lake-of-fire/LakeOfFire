import assert from 'node:assert/strict'
import test from 'node:test'

import {
    LatestRestoreTransactionCoordinator,
    PendingInitialRestoreMailbox,
    isRestoreTransactionSupersededError,
    makeSyntheticRestoreLocator,
    parseSyntheticRestoreLocator,
    runAcceptedRestoreNavigation,
    runRequiredRestoreNavigation,
    commitAfterMatchingRestoreTransactionsSettle,
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
