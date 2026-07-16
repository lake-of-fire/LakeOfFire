import test from 'node:test'
import assert from 'node:assert/strict'

import {
    nativeLookupPublicationIdentityForDocument,
    shouldRunNativeLookupRefresh,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-native-lookup-publication.js'

const makeDocument = (url, frameIdentifier = null) => ({
    URL: url,
    body: {
        dataset: frameIdentifier ? { swiftuiwebviewFrameUuid: frameIdentifier } : {},
    },
})

test('publication identity is stable for one document and distinct for same-URL frames', () => {
    const first = makeDocument('ebook://ebook/load/book/section.xhtml')
    const second = makeDocument('ebook://ebook/load/book/section.xhtml')

    const firstIdentity = nativeLookupPublicationIdentityForDocument(first)
    const repeatedIdentity = nativeLookupPublicationIdentityForDocument(first)
    const secondIdentity = nativeLookupPublicationIdentityForDocument(second)

    assert.deepEqual(repeatedIdentity, firstIdentity)
    assert.notEqual(secondIdentity.frameIdentifier, firstIdentity.frameIdentifier)
    assert.notEqual(secondIdentity.frameKey, firstIdentity.frameKey)
    assert.equal(first.body.dataset.swiftuiwebviewFrameUuid, firstIdentity.frameIdentifier)
})

test('publication identity preserves the content-script frame identifier', () => {
    const doc = makeDocument('ebook://ebook/load/book/chapter.xhtml', 'content-frame-7')

    assert.deepEqual(nativeLookupPublicationIdentityForDocument(doc), {
        documentURL: 'ebook://ebook/load/book/chapter.xhtml',
        frameIdentifier: 'content-frame-7',
        frameKey: 'ebook://ebook/load/book/chapter.xhtml|content-frame-7',
    })
})

test('scheduled refresh rejects superseded generations and detached explicit documents', () => {
    const current = makeDocument('ebook://ebook/load/book/current.xhtml')
    const detached = makeDocument('ebook://ebook/load/book/detached.xhtml')

    assert.equal(shouldRunNativeLookupRefresh({
        scheduledGeneration: 4,
        currentGeneration: 5,
        currentDocuments: [current],
    }), false)
    assert.equal(shouldRunNativeLookupRefresh({
        scheduledGeneration: 5,
        currentGeneration: 5,
        explicitDocument: detached,
        currentDocuments: [current],
    }), false)
    assert.equal(shouldRunNativeLookupRefresh({
        scheduledGeneration: 5,
        currentGeneration: 5,
        explicitDocument: current,
        currentDocuments: [current],
    }), true)
})
