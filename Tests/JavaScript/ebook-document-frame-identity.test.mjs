import assert from 'node:assert/strict'
import test from 'node:test'

import {
    ebookDocumentFrameIdentity,
    shouldPublishForDocumentFrame,
} from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-document-frame-identity.js'

const documentWithIdentity = (url, frameIdentifier) => ({
    URL: url,
    body: { dataset: { swiftuiwebviewFrameUuid: frameIdentifier } },
})

test('same-URL documents retain distinct frame-owned publication keys', () => {
    const first = documentWithIdentity('ebook://book/chapter.xhtml', 'frame-1')
    const second = documentWithIdentity('ebook://book/chapter.xhtml', 'frame-2')

    assert.deepEqual(ebookDocumentFrameIdentity(first), {
        documentURL: 'ebook://book/chapter.xhtml',
        frameIdentifier: 'frame-1',
        frameKey: 'ebook://book/chapter.xhtml|frame-1',
    })
    assert.notEqual(
        ebookDocumentFrameIdentity(first).frameKey,
        ebookDocumentFrameIdentity(second).frameKey
    )
})

test('publication requires the content-script frame identity', () => {
    assert.equal(ebookDocumentFrameIdentity({ URL: 'ebook://book/chapter.xhtml', body: { dataset: {} } }), null)
})

test('scheduled publication rejects stale generations and detached documents', () => {
    const current = documentWithIdentity('ebook://book/current.xhtml', 'current')
    const detached = documentWithIdentity('ebook://book/detached.xhtml', 'detached')

    assert.equal(shouldPublishForDocumentFrame({
        scheduledGeneration: 2,
        currentGeneration: 3,
        currentDocuments: [current],
    }), false)
    assert.equal(shouldPublishForDocumentFrame({
        scheduledGeneration: 3,
        currentGeneration: 3,
        explicitDocument: detached,
        currentDocuments: [current],
    }), false)
    assert.equal(shouldPublishForDocumentFrame({
        scheduledGeneration: 3,
        currentGeneration: 3,
        explicitDocument: current,
        currentDocuments: [current],
    }), true)
})
