import test from 'node:test'
import assert from 'node:assert/strict'

import {
    nativeLookupFramePublicationTransition,
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

test('publication identity requires an owning document URL', () => {
    const doc = makeDocument('')

    assert.equal(nativeLookupPublicationIdentityForDocument(doc), null)
    assert.equal(doc.body.dataset.swiftuiwebviewFrameUuid, undefined)
})

test('fragment-only navigation retains one frame publication key', () => {
    const before = makeDocument('ebook://ebook/load/book/chapter.xhtml?edition=1#before', 'frame-1')
    const after = makeDocument('ebook://ebook/load/book/chapter.xhtml?edition=1#after', 'frame-1')
    const otherQuery = makeDocument('ebook://ebook/load/book/chapter.xhtml?edition=2#after', 'frame-1')

    assert.equal(
        nativeLookupPublicationIdentityForDocument(before).frameKey,
        nativeLookupPublicationIdentityForDocument(after).frameKey
    )
    assert.equal(
        nativeLookupPublicationIdentityForDocument(before).documentURL,
        'ebook://ebook/load/book/chapter.xhtml?edition=1'
    )
    assert.notEqual(
        nativeLookupPublicationIdentityForDocument(before).frameKey,
        nativeLookupPublicationIdentityForDocument(otherQuery).frameKey
    )
})

test('a newly displayed frame creates a destructive publication reset boundary', () => {
    const previous = makeDocument('ebook://ebook/load/book/chapter.xhtml', 'frame-1')
    const next = makeDocument('ebook://ebook/load/book/chapter.xhtml', 'frame-2')

    assert.deepEqual(nativeLookupFramePublicationTransition({
        previousFrameKey: nativeLookupPublicationIdentityForDocument(previous).frameKey,
        document: next,
    }), {
        frameKey: 'ebook://ebook/load/book/chapter.xhtml|frame-2',
        shouldResetPreviousTargets: true,
    })
    assert.deepEqual(nativeLookupFramePublicationTransition({
        previousFrameKey: nativeLookupPublicationIdentityForDocument(next).frameKey,
        document: next,
    }), {
        frameKey: 'ebook://ebook/load/book/chapter.xhtml|frame-2',
        shouldResetPreviousTargets: false,
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
