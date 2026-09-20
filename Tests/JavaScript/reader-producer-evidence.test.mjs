import assert from 'node:assert/strict'
import test from 'node:test'

import {
    captureReaderArticleProducerOwner,
    carryReaderArticleProducerOwner,
    readerArticleProducerOwnersMatch,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/reader-producer-evidence.js'

const owner = (token, frameURL = 'ebook://book/chapter.xhtml', documentStartedAtMs = 42) =>
    Object.freeze({ token, frameURL, documentStartedAtMs })

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

