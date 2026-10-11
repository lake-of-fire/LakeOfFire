import assert from 'node:assert/strict'
import test from 'node:test'

import {
    captureReaderArticleProducerOwner,
    carryReaderArticleProducerOwner,
    readerArticleProducerOwnersMatch,
    observeReaderArticleProducerReadiness,
    readerArticleProducerOwnerIsCurrent,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/reader-producer-evidence.js'

const owner = (token, frameURL = 'ebook://book/chapter.xhtml', documentStartedAtMs = 42) =>
    Object.freeze({ token, frameURL, documentStartedAtMs })

test('generic LakeOfFire host keeps the historical unfenced message path', () => {
    const captured = captureReaderArticleProducerOwner({ producer: null })
    const message = { action: 'progress' }
    assert.deepEqual(captured, { required: false })
    assert.strictEqual(
        carryReaderArticleProducerOwner(message, captured, { producer: null }),
        message
    )
    assert.equal(Object.hasOwn(message, 'readerArticleProducer'), false)
})

const readinessFixture = () => {
    const target = new EventTarget()
    let selected = null, setupRequests = 0
    const observers = new Map(), retained = []
    const producer = {
        capture() { if (!selected) throw new Error('cold'); return selected },
        captureIfReady() { ++setupRequests; return selected },
        isCurrent(value) { return value === selected && value !== null },
        onInvalidated(value, callback) {
            observers.set(callback, value)
            retained.push(callback)
            if (!this.isCurrent(value)) callback()
            return () => observers.delete(callback)
        },
    }
    const invalidate = () => {
        selected = null
        for (const [callback, value] of [...observers]) {
            if (!producer.isCurrent(value)) callback()
        }
    }
    const install = token => {
        selected = owner(token)
        target.dispatchEvent(new Event('manabi-article-producer-ready'))
        return selected
    }
    return { target, producer, observers, retained, invalidate, install,
        get setupRequests() { return setupRequests } }
}

test('readiness is cold without starting setup, then follows exact installation', () => {
    const fixture = readinessFixture(), changes = []
    const observation = observeReaderArticleProducerReadiness({
        target: fixture.target, getProducer: () => fixture.producer,
        onChange: ready => changes.push(ready),
    })
    assert.equal(observation.ready, false)
    assert.equal(fixture.setupRequests, 0)
    const first = fixture.install('first')
    assert.equal(observation.ready, true)
    fixture.invalidate()
    assert.equal(observation.ready, false)
    assert.equal(readerArticleProducerOwnerIsCurrent(first, { producer: fixture.producer }), false)
    fixture.install('second')
    fixture.retained[0]() // An already retired installation cannot clear second.
    assert.equal(observation.ready, true)
    assert.deepEqual(changes, [false, true, false, true])
    observation.close()
    assert.equal(fixture.observers.size, 0)
    fixture.install('after-close')
    fixture.retained.at(-1)()
    assert.equal(observation.ready, false)
    assert.deepEqual(changes, [false, true, false, true])
})

test('readiness invalidation reentry cannot clear a synchronously installed successor', () => {
    const fixture = readinessFixture()
    fixture.install('first')
    let replaceOnWithdrawal = false
    const changes = []
    const observation = observeReaderArticleProducerReadiness({
        target: fixture.target, getProducer: () => fixture.producer,
        onChange: ready => {
            changes.push(ready)
            if (!ready && replaceOnWithdrawal) {
                replaceOnWithdrawal = false
                fixture.install('successor')
            }
        },
    })
    replaceOnWithdrawal = true
    fixture.invalidate()
    assert.equal(observation.ready, true)
    assert.deepEqual(changes, [true, false, true])
    assert.equal(fixture.observers.size, 1)
    observation.close()
})

test('an observation retired during subscription releases its late cleanup', () => {
    const fixture = readinessFixture()
    fixture.install('first')
    const subscribe = fixture.producer.onInvalidated
    let reenter = true
    fixture.producer.onInvalidated = function(value, callback) {
        const cleanup = subscribe.call(this, value, callback)
        if (reenter) {
            reenter = false
            fixture.install('successor')
        }
        return cleanup
    }
    const observation = observeReaderArticleProducerReadiness({
        target: fixture.target, getProducer: () => fixture.producer,
    })
    assert.equal(observation.ready, true)
    assert.equal(fixture.observers.size, 1)
    fixture.retained[0]()
    assert.equal(observation.ready, true)
    observation.close()
    assert.equal(fixture.observers.size, 0)
})

test('non-Manabi readiness stays compatible and an outgoing host cannot notify', () => {
    const target = new EventTarget(), changes = []
    let current = true
    const observation = observeReaderArticleProducerReadiness({
        target, getProducer: () => null, isCurrent: () => current,
        onChange: ready => changes.push(ready),
    })
    assert.equal(observation.ready, true)
    current = false
    target.dispatchEvent(new Event('manabi-article-producer-ready'))
    assert.equal(observation.ready, false)
    assert.deepEqual(changes, [true])
    observation.close()
})

test('installed but malformed producer contract fails closed', () => {
    const captured = captureReaderArticleProducerOwner({ producer: {} })
    assert.equal(captured, null)
    assert.equal(carryReaderArticleProducerOwner({}, captured, { producer: {} }), null)
})

test('cold setup coalesces without retaining the event until a token exists', () => {
    let setupRequests = 0
    const producer = {
        captureIfReady() {
            setupRequests += 1
            return null
        },
    }
    assert.equal(captureReaderArticleProducerOwner({ producer }), null)
    assert.equal(setupRequests, 1)
})

test('held work is rejected after same-URL frame replacement', () => {
    const held = owner('token-a', 'ebook://book/chapter.xhtml')
    const replacement = owner('token-b', 'ebook://book/chapter.xhtml')
    assert.equal(readerArticleProducerOwnersMatch(held, replacement), false)
})

test('two same-URL frames retain independent producer ownership', () => {
    const first = owner('token-a', 'ebook://book/chapter.xhtml')
    const second = owner('token-b', 'ebook://book/chapter.xhtml')
    assert.notEqual(first.token, second.token)
    assert.equal(readerArticleProducerOwnersMatch(first, second), false)
})

test('a replacement document lifetime cannot reuse a held producer ticket', () => {
    const held = owner('token-a', 'ebook://book/chapter.xhtml', 42)
    const replacement = owner('token-a', 'ebook://book/chapter.xhtml', 84)
    assert.equal(readerArticleProducerOwnersMatch(held, replacement), false)
})

test('Mark All batching and sequential retry carry the original ticket unchanged', () => {
    const captured = owner('token-batch')
    const producer = {
        own(message, capturedOwner) {
            assert.strictEqual(capturedOwner, captured)
            Object.defineProperty(message, 'readerArticleProducer', {
                value: Object.freeze({ ...capturedOwner }),
                enumerable: true,
                writable: false,
            })
            return message
        },
    }
    const batch = carryReaderArticleProducerOwner({ sectionID: 'one' }, captured, { producer })
    const retry = carryReaderArticleProducerOwner({ sectionID: 'two' }, captured, { producer })
    assert.deepEqual(batch.readerArticleProducer, retry.readerArticleProducer)
    assert.equal(batch.readerArticleProducer.token, 'token-batch')
})

test('stale callback cannot replay a replacement producer token', () => {
    const original = owner('original')
    const replacement = owner('replacement')
    const heldMessage = carryReaderArticleProducerOwner({ action: 'progress' }, original)
    const replacementMessage = carryReaderArticleProducerOwner({ action: 'progress' }, replacement)
    assert.equal(
        readerArticleProducerOwnersMatch(
            heldMessage.readerArticleProducer,
            replacementMessage.readerArticleProducer
        ),
        false
    )
    assert.equal(heldMessage.readerArticleProducer.token, 'original')
})

test('Core ticket capture preserves the original owner through delayed setup', () => {
    const capturedOwner = owner('token-a')
    let captureCount = 0
    const producer = {
        captureIfReady() {
            captureCount += 1
            return capturedOwner
        },
        own(message, receivedOwner) {
            assert.strictEqual(receivedOwner, capturedOwner)
            Object.defineProperty(message, 'readerArticleProducer', {
                value: Object.freeze({ ...receivedOwner }),
                enumerable: true,
            })
            return message
        },
    }
    const captured = captureReaderArticleProducerOwner({ producer })
    const message = carryReaderArticleProducerOwner({ sectionID: 'one' }, captured, { producer })
    assert.equal(captureCount, 1)
    assert.deepEqual(message.readerArticleProducer, capturedOwner)
})
