import assert from 'node:assert/strict'
import test from 'node:test'

import { EbookLoadResources } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-load-resources.js'

const makeFile = (blob, path) => ({ blob, path })
const makeFileSource = file => ({ kind: 'file', file })

test('native resources take precedence without retaining a remote blob', () => {
    const nativeSource = { kind: 'native', url: 'ebook://book' }
    const resources = new EbookLoadResources({ nativeSource, sourcePath: '/book.epub' })

    assert.equal(resources.setRemoteBlob({ bytes: 5 }), false)
    assert.equal(resources.makeReusableSource({ makeFile, makeFileSource }), nativeSource)
    assert.deepEqual(resources.diagnostics, {
        sourceKind: 'native',
        sourceURL: 'ebook://book',
        hasRemoteBlob: false,
    })
})

test('remote resources recreate an independent file source while live', () => {
    const blob = { bytes: 10 }
    const resources = new EbookLoadResources({ sourcePath: '/remote.epub' })

    assert.equal(resources.setRemoteBlob(blob), true)
    assert.deepEqual(resources.makeReusableSource({ makeFile, makeFileSource }), {
        kind: 'file',
        file: { blob, path: '/remote.epub' },
    })
})

test('close releases payloads and rejects a stale fetch completion', () => {
    const resources = new EbookLoadResources({ sourcePath: '/remote.epub' })
    resources.setRemoteBlob({ bytes: 10 })

    assert.equal(resources.close(), true)
    assert.equal(resources.close(), false)
    assert.equal(resources.setRemoteBlob({ bytes: 20 }), false)
    assert.equal(resources.makeReusableSource({ makeFile, makeFileSource }), null)
    assert.equal(resources.diagnostics.hasRemoteBlob, false)
})
