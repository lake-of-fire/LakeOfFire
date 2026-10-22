import assert from 'node:assert/strict'
import test from 'node:test'
import { createNativeMarkReadRequestCoordinator } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/native-mark-read-request.js'

function fixture(t) {
    const commands = [], controls = [], notices = [], timers = new Map()
    let timer = 0
    const effects = { notice: () => {}, control: () => {}, cleanup: () => {}, owner: () => {} }
    const coordinator = createNativeMarkReadRequestCoordinator({
        makeRequestID: () => 'cancel-sweep', lifecycleTarget: new EventTarget(),
        postMessage: value => commands.push(value),
        postControlMessage: value => { controls.push(value); effects.control(value) },
        onPending: value => { notices.push(value); effects.notice(value) },
        isOwnerCurrent: owner => { effects.owner(owner); return true },
        scheduleTimeout: callback => { timers.set(++timer, callback); return timer },
        cancelTimeout: id => { timers.delete(id); effects.cleanup(id) },
    })
    const clearEffects = () => {
        for (const key of Object.keys(effects)) effects[key] = () => {}
    }
    t.after(() => { clearEffects(); coordinator.close() })
    const start = (sectionID, desiredState = 'unmarked') => {
        const count = commands.length
        const completion = coordinator.request({ sectionID, message: { desiredState }, owner: {} })
        assert.equal(commands.length, count + 1, 'The fixture must submit a new native command')
        return { command: commands.at(-1), completion }
    }
    const settle = (entry, success = true) => coordinator.settle({
        requestID: entry.command.requestID, sectionId: entry.command.sectionId,
        manualReadPendingProtocol: 1,
        manualReadPendingObservationToken: entry.command.manualReadPendingObservationToken,
        manualReadPendingState: 'finished', success,
        ...(success ? {} : { errorCode: 'cancelled' }),
    })
    const cancelledIDs = () => controls.filter(value => value.manualReadPendingOperation === 'cancel')
        .map(value => value.requestID)
    return { coordinator, commands, controls, notices, timers, effects, clearEffects, start, settle, cancelledIDs }
}

for (const boundary of ['notice', 'control', 'cleanup', 'owner']) {
    test(`bulk cancellation cannot acquire a command admitted by its ${boundary} callback`, async t => {
        const f = fixture(t)
        const original = f.start('original')
        let replacement
        f.effects[boundary] = () => {
            f.effects[boundary] = () => {}
            replacement = f.start('newer', 'marked')
        }
        f.coordinator.cancelAll()
        assert.ok(replacement)
        assert.deepEqual(f.cancelledIDs(), [original.command.requestID],
            'One cancellation invocation owns only requests present at its entry')
        assert.equal(f.coordinator.pendingCount, 2, 'Cancellation does not invent native outcomes')
        assert.equal(f.notices.some(value => value.requestID === replacement.command.requestID
            && value.phase === 'cancelling'), false)
        f.clearEffects()
        f.settle(original, false)
        f.settle(replacement, true)
        const [oldOutcome, newOutcome] = await Promise.all([original.completion, replacement.completion])
        assert.equal(oldOutcome.success, false)
        assert.equal(newOutcome.success, true)
        assert.equal(newOutcome.presentationAllowed, true)
        assert.equal(f.commands.length, 2, 'The sweep must not replay either mutation')
        assert.equal(f.timers.size, 0)
    })
}

test('a cancellation reply can admit a same-section replacement without cancelling that replacement', async t => {
    const f = fixture(t)
    const original = f.start('same-section')
    let replacement
    f.effects.control = value => {
        if (value.requestID !== original.command.requestID) return
        f.effects.control = () => {}
        f.settle(original, false)
        replacement = f.start('same-section', 'marked')
    }
    f.coordinator.cancelAll()
    assert.ok(replacement)
    assert.notEqual(original.command.requestID, replacement.command.requestID)
    assert.deepEqual(f.cancelledIDs(), [original.command.requestID])
    assert.equal(f.coordinator.pendingCount, 1)
    assert.equal((await original.completion).success, false)
    f.settle(replacement)
    assert.equal((await replacement.completion).success, true)
    assert.equal(f.timers.size, 0)
})

test('settling an original sibling does not retarget the sweep to its same-section successor', async t => {
    const f = fixture(t)
    const first = f.start('first'), sibling = f.start('sibling'), last = f.start('last')
    let replacement
    f.effects.notice = value => {
        if (value.requestID !== first.command.requestID || value.phase !== 'cancelling') return
        f.effects.notice = () => {}
        f.settle(sibling)
        replacement = f.start('sibling', 'marked')
    }
    f.coordinator.cancelAll()
    assert.deepEqual(f.cancelledIDs(), [first.command.requestID, last.command.requestID])
    assert.equal((await sibling.completion).success, true, 'A native commit still wins its original outcome')
    assert.equal(f.coordinator.pendingCount, 3)
    for (const entry of [first, last]) f.settle(entry, false)
    f.settle(replacement)
    const outcomes = await Promise.all([first.completion, last.completion, replacement.completion])
    assert.deepEqual(outcomes.map(value => value.success), [false, false, true])
    assert.equal(f.timers.size, 0)
})

test('a later explicit sweep may cancel the newer command', async t => {
    const f = fixture(t)
    const original = f.start('original')
    let replacement
    f.effects.notice = () => {
        f.effects.notice = () => {}
        replacement = f.start('newer')
    }
    f.coordinator.cancelAll()
    assert.deepEqual(f.cancelledIDs(), [original.command.requestID])
    f.settle(original, false)
    f.coordinator.cancelAll()
    assert.deepEqual(f.cancelledIDs(), [original.command.requestID, replacement.command.requestID])
    f.settle(replacement, false)
    assert.deepEqual((await Promise.all([original.completion, replacement.completion]))
        .map(value => value.success), [false, false])
})

test('ordinary bulk cancellation still reaches every original live request and joins native truth', async t => {
    const f = fixture(t)
    const entries = [f.start('one', 'marked'), f.start('two'), f.start('three')]
    f.coordinator.cancelAll()
    assert.deepEqual(f.cancelledIDs(), entries.map(entry => entry.command.requestID))
    assert.equal(f.coordinator.pendingCount, 3)
    f.settle(entries[0], true)
    f.settle(entries[1], false)
    f.settle(entries[2], false)
    assert.deepEqual((await Promise.all(entries.map(entry => entry.completion)))
        .map(value => value.success), [true, false, false])
    assert.equal(f.coordinator.pendingCount, 0)
    assert.equal(f.timers.size, 0)
})

test('bulk cancellation does not restore a departed request cancellation capability', async t => {
    const f = fixture(t)
    const entry = f.start('departed')
    f.coordinator.pause()
    f.coordinator.cancelAll()
    assert.deepEqual(f.cancelledIDs(), [])
    assert.equal(f.coordinator.pendingCount, 1)
    f.settle(entry)
    assert.equal((await entry.completion).success, true)
    assert.equal(f.cancelledIDs().length, 0)
})

test('close during a cancellation callback retains close semantics without reviving the sweep', async t => {
    const f = fixture(t)
    const first = f.start('one'), second = f.start('two')
    f.effects.notice = value => {
        if (value.phase !== 'cancelling') return
        f.effects.notice = () => {}
        f.coordinator.close()
    }
    f.coordinator.cancelAll()
    await assert.rejects(first.completion, error => error.code === 'readerClosed' && error.outcomeUnknown)
    await assert.rejects(second.completion, error => error.code === 'readerClosed' && error.outcomeUnknown)
    assert.deepEqual(f.cancelledIDs(), [first.command.requestID, second.command.requestID])
    assert.equal(f.coordinator.pendingCount, 0)
    assert.equal(f.timers.size, 0)
    f.coordinator.cancelAll()
    assert.equal(f.controls.length, 2)
})
