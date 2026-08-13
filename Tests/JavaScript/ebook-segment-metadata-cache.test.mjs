import assert from 'node:assert/strict'
import test from 'node:test'

import {
    createEbookSegmentMetadataDocumentCache,
    createEbookSegmentMetadataLookup,
    ebookSegmentSidecarRevision,
} from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-segment-metadata-cache.js'
import { compactEbookSegmentSidecarVersion } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-segment-identity.js'

globalThis.manabi_compactSegmentSidecarSchemaVersion = compactEbookSegmentSidecarVersion

const payload = (runtimeID, entryID, hash) => JSON.stringify({
    v: 10,
    t: {
        j: [[entryID]],
        n: [],
        s: [],
        ns: [],
        p: [],
        h: [hash],
        sid: ['sentence'],
        pid: ['paragraph'],
    },
    s: [[`!${runtimeID}`, 0, 0, null, null, null, null, null, null, 0, 0]],
})

const sidecar = (id, textContent) => ({
    id,
    textContent,
    hasAttribute: name => name === 'data-mnb-seg-meta',
})

const documentWithSidecars = sidecars => ({
    sidecars,
    getElementById(id) {
        return this.sidecars.find(candidate => candidate.id === id) ?? null
    },
    getElementsByTagName(tagName) {
        return tagName === 'script' ? this.sidecars : []
    },
})

const segmentNode = (id, ownerDocument) => ({ id, ownerDocument })

const elementWithAttributes = attributes => ({
    id: attributes.id ?? '',
    dataset: attributes.dataset ?? {},
    getAttribute: name => attributes[name] ?? null,
})

test('uses the transported pretransformed revision before reconstructed script metadata', () => {
    const marker = elementWithAttributes({
        name: 'mnb-pretransformed-ebook-sidecar',
        'data-mnb-sidecar-revision': 'transport-revision',
    })
    const canonical = elementWithAttributes({
        id: 'mnb-segment-metadata',
        'data-mnb-sidecar-revision': 'inline-revision',
    })
    const document = {
        getElementsByTagName(tagName) {
            if (tagName === 'meta') return [marker]
            if (tagName === 'script') return [canonical]
            return []
        },
    }

    assert.equal(ebookSegmentSidecarRevision(document), 'transport:transport-revision')
})

test('uses inline and external revisions when no transport marker exists', () => {
    const canonical = elementWithAttributes({
        id: 'mnb-segment-metadata',
        dataset: { mnbSidecarRevision: 'inline-revision' },
    })
    const inlineDocument = {
        getElementsByTagName: tagName => tagName === 'script' ? [canonical] : [],
    }
    const externalDocument = {
        getElementsByTagName: () => [],
        manabiExternalSegmentSidecar: { signature: 'sha256:10:abc' },
    }

    assert.equal(ebookSegmentSidecarRevision(inlineDocument), 'inline:inline-revision')
    assert.equal(ebookSegmentSidecarRevision(externalDocument), 'external:sha256:10:abc')
})

test('encodes ambiguous revision ownership instead of reusing a valid cache identity', () => {
    const marker = elementWithAttributes({
        name: 'mnb-pretransformed-ebook-sidecar',
        'data-mnb-sidecar-revision': 'same-revision',
    })
    const document = {
        getElementsByTagName: tagName => tagName === 'meta' ? [marker, marker] : [],
    }

    assert.equal(
        ebookSegmentSidecarRevision(document),
        'invalid-transport-owner-count:2',
    )
})

test('keeps viewer metadata caches isolated by document', () => {
    const cache = createEbookSegmentMetadataDocumentCache()
    const firstDocument = {}
    const secondDocument = {}

    const firstEntry = cache.entryForDocument(firstDocument)
    firstEntry.byRuntimeID.set('runtime-a', { i: 'runtime-a' })

    assert.equal(cache.entryForDocument(firstDocument), firstEntry)
    assert.equal(cache.entryForDocument(secondDocument).byRuntimeID.size, 0)
})

test('does not claim ReaderCore document cache fields', () => {
    const cache = createEbookSegmentMetadataDocumentCache()
    const document = {
        manabiSegmentMetadataByID: new Map([['stable-a', { i: 'runtime-a' }]]),
        manabiSegmentMetadataSidecarSignature: 'reader-core-signature',
    }

    cache.entryForDocument(document).sidecarSignature = 'viewer-signature'

    assert.equal(document.manabiSegmentMetadataByID.has('stable-a'), true)
    assert.equal(document.manabiSegmentMetadataSidecarSignature, 'reader-core-signature')
})

test('resolves canonical and dynamic sidecars in the same document', () => {
    const lookup = createEbookSegmentMetadataLookup()
    const document = documentWithSidecars([
        sidecar('mnb-segment-metadata', payload('runtime-a', 1001, 'hash-a')),
        sidecar('mnb-segment-metadata-dynamic', payload('runtime-b', 2001, 'hash-b')),
    ])

    assert.deepEqual(lookup.metadataForNode(segmentNode('runtime-a', document)).j, [1001])
    assert.deepEqual(lookup.metadataForNode(segmentNode('runtime-b', document)).j, [2001])
})

test('resolves external canonical metadata alongside inline dynamic sidecars', () => {
    const lookup = createEbookSegmentMetadataLookup()
    const canonicalSidecar = sidecar('external-canonical', payload('runtime-a', 1001, 'hash-a'))
    const document = documentWithSidecars([
        sidecar('mnb-segment-metadata-dynamic', payload('runtime-b', 2001, 'hash-b')),
    ])
    document.manabiExternalSegmentSidecar = {
        sidecar: canonicalSidecar,
        signature: 'canonical-signature',
    }

    assert.deepEqual(lookup.metadataForNode(segmentNode('runtime-a', document)).j, [1001])
    assert.deepEqual(lookup.metadataForNode(segmentNode('runtime-b', document)).j, [2001])
})

test('rejects one runtime ID published by multiple sidecars', () => {
    const lookup = createEbookSegmentMetadataLookup()
    const document = documentWithSidecars([
        sidecar('mnb-segment-metadata', payload('runtime', 1001, 'hash-a')),
        sidecar('mnb-segment-metadata-dynamic', payload('runtime', 2001, 'hash-b')),
    ])

    assert.equal(lookup.metadataForNode(segmentNode('runtime', document)), null)
})

test('invalidates a cached miss when the sidecar set changes', () => {
    const lookup = createEbookSegmentMetadataLookup()
    const document = documentWithSidecars([
        sidecar('mnb-segment-metadata', payload('runtime-a', 1001, 'hash-a')),
    ])
    const runtimeB = segmentNode('runtime-b', document)

    assert.equal(lookup.metadataForNode(runtimeB), null)
    document.sidecars.push(
        sidecar('mnb-segment-metadata-dynamic', payload('runtime-b', 2001, 'hash-b')),
    )

    assert.deepEqual(lookup.metadataForNode(runtimeB).j, [2001])
})

test('invalidates cached metadata when an existing sidecar text changes', () => {
    const lookup = createEbookSegmentMetadataLookup()
    const canonicalSidecar = sidecar(
        'mnb-segment-metadata',
        payload('runtime', 1001, 'hash-a'),
    )
    const document = documentWithSidecars([canonicalSidecar])
    const runtime = segmentNode('runtime', document)

    assert.deepEqual(lookup.metadataForNode(runtime).j, [1001])
    canonicalSidecar.textContent = payload('runtime', 2001, 'hash-b')
    assert.deepEqual(lookup.metadataForNode(runtime).j, [2001])
})

test('invalidates a cached miss when an external canonical sidecar arrives', () => {
    const lookup = createEbookSegmentMetadataLookup()
    const document = documentWithSidecars([])
    const runtime = segmentNode('runtime', document)

    assert.equal(lookup.metadataForNode(runtime), null)
    document.manabiExternalSegmentSidecar = {
        sidecar: sidecar('external-canonical', payload('runtime', 1001, 'hash-a')),
        signature: 'canonical-signature',
    }
    assert.deepEqual(lookup.metadataForNode(runtime).j, [1001])
})

test('inline canonical metadata suppresses an external canonical sidecar', () => {
    const lookup = createEbookSegmentMetadataLookup()
    const document = documentWithSidecars([
        sidecar('mnb-segment-metadata', payload('runtime', 1001, 'hash-inline')),
    ])
    document.manabiExternalSegmentSidecar = {
        sidecar: sidecar('external-canonical', payload('runtime', 2001, 'hash-external')),
        signature: 'external-signature',
    }

    assert.deepEqual(lookup.metadataForNode(segmentNode('runtime', document)).j, [1001])
})

test('rejects duplicate canonical ownership while preserving dynamic metadata', () => {
    const lookup = createEbookSegmentMetadataLookup()
    const document = documentWithSidecars([
        sidecar('mnb-segment-metadata', payload('canonical-a', 1001, 'hash-a')),
        sidecar('mnb-segment-metadata', payload('canonical-b', 2001, 'hash-b')),
        sidecar('mnb-segment-metadata-dynamic', payload('dynamic', 3001, 'hash-dynamic')),
    ])
    document.manabiExternalSegmentSidecar = {
        sidecar: sidecar('external-canonical', payload('external', 4001, 'hash-external')),
        signature: 'external-signature',
    }

    assert.equal(lookup.metadataForNode(segmentNode('canonical-a', document)), null)
    assert.equal(lookup.metadataForNode(segmentNode('canonical-b', document)), null)
    assert.equal(lookup.metadataForNode(segmentNode('external', document)), null)
    assert.deepEqual(lookup.metadataForNode(segmentNode('dynamic', document)).j, [3001])
})

test('ignores malformed payloads while preserving valid dynamic sidecars', () => {
    const lookup = createEbookSegmentMetadataLookup()
    const document = documentWithSidecars([
        sidecar('mnb-segment-metadata', '{not-json'),
        sidecar('mnb-segment-metadata-dynamic', payload('runtime', 1001, 'hash-dynamic')),
    ])

    assert.deepEqual(lookup.metadataForNode(segmentNode('runtime', document)).j, [1001])
})

test('rejects current payloads when native and parser schema versions disagree', () => {
    const lookup = createEbookSegmentMetadataLookup({ nativeSchemaVersion: 9 })
    const document = documentWithSidecars([
        sidecar('mnb-segment-metadata', payload('runtime', 1001, 'hash')),
    ])

    assert.deepEqual(lookup.schemaDiagnostics, {
        parserVersion: 10,
        nativeVersion: 9,
        nativeSchemaIsCompatible: false,
    })
    assert.equal(lookup.metadataForNode(segmentNode('runtime', document)), null)
})
