import assert from 'node:assert/strict'
import test from 'node:test'

import { decodeEPUBTextBytes } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/ebook-text-decoding.js'
import { BlobReader, BlobWriter, ZipReader } from '../../Sources/LakeOfFireReader/Resources/Resources/foliate-js/vendor/zip.js'

const utf16Bytes = (text, littleEndian, bom = false) => {
    const bytes = []
    if (bom) bytes.push(...(littleEndian ? [0xFF, 0xFE] : [0xFE, 0xFF]))
    for (const character of text) {
        const codePoint = character.codePointAt(0)
        const units = codePoint <= 0xFFFF
            ? [codePoint]
            : [
                0xD800 + ((codePoint - 0x10000) >> 10),
                0xDC00 + ((codePoint - 0x10000) & 0x3FF),
            ]
        for (const unit of units) {
            if (littleEndian) bytes.push(unit & 0xFF, unit >> 8)
            else bytes.push(unit >> 8, unit & 0xFF)
        }
    }
    return Uint8Array.from(bytes)
}

test('EPUB text bytes decode UTF-8 and byte-order-marked UTF-16', () => {
    const text = '<package>日本語</package>'
    assert.equal(decodeEPUBTextBytes(new TextEncoder().encode(text)), text)
    assert.equal(
        decodeEPUBTextBytes(Uint8Array.from([0xEF, 0xBB, 0xBF, ...new TextEncoder().encode(text)])),
        text,
    )
    assert.equal(decodeEPUBTextBytes(utf16Bytes(text, true, true)), text)
    assert.equal(decodeEPUBTextBytes(utf16Bytes(text, false, true)), text)
})

test('EPUB text bytes detect ordinary BOM-less UTF-16 XML signatures', () => {
    const text = '<package>日本語</package>'
    assert.equal(decodeEPUBTextBytes(utf16Bytes(text, true)), text)
    assert.equal(decodeEPUBTextBytes(utf16Bytes(text, false)), text)
})

test('declared native-entry charset shares the decoder and accepts quoted labels', () => {
    const text = 'body::before { content: "日本語"; }'
    const bytes = utf16Bytes(text, false)
    assert.equal(
        decodeEPUBTextBytes(bytes, { declaredEncoding: ' "utf-16be" ' }),
        text,
    )
})

test('the raw-blob ZIP path preserves UTF-16 publication text', async () => {
    const fixture = Uint8Array.from(Buffer.from(
        'UEsDBBQAAAAAAAAAIVDk/Op+LgAAAC4AAAAWAAAATUVUQS1JTkYvY29udGFpbmVyLnhtbP/+PABwAGEAYwBrAGEAZwBlAD4A5WUsZ56KPAAvAHAAYQBjAGsAYQBnAGUAPgBQSwECFAMUAAAAAAAAACFQ5Pzqfi4AAAAuAAAAFgAAAAAAAAAAAAAAgAEAAAAATUVUQS1JTkYvY29udGFpbmVyLnhtbFBLBQYAAAAAAQABAEQAAABiAAAAAAA=',
        'base64',
    ))
    const reader = new ZipReader(new BlobReader(new Blob([fixture])))
    try {
        const entries = await reader.getEntries()
        const entry = entries.find(candidate => candidate.filename === 'META-INF/container.xml')
        assert.ok(entry)
        const blob = await entry.getData(new BlobWriter())
        assert.equal(
            decodeEPUBTextBytes(await blob.arrayBuffer()),
            '<package>日本語</package>',
        )
    } finally {
        await reader.close()
    }
})

test('the bundled ZIP reader aborts direct entry extraction through its signal option', async () => {
    const fixture = Uint8Array.from(Buffer.from(
        'UEsDBBQAAAAAAAAAIVDk/Op+LgAAAC4AAAAWAAAATUVUQS1JTkYvY29udGFpbmVyLnhtbP/+PABwAGEAYwBrAGEAZwBlAD4A5WUsZ56KPAAvAHAAYQBjAGsAYQBnAGUAPgBQSwECFAMUAAAAAAAAACFQ5Pzqfi4AAAAuAAAAFgAAAAAAAAAAAAAAgAEAAAAATUVUQS1JTkYvY29udGFpbmVyLnhtbFBLBQYAAAAAAQABAEQAAABiAAAAAAA=',
        'base64',
    ))
    const reader = new ZipReader(new BlobReader(new Blob([fixture])))
    try {
        const [entry] = await reader.getEntries()
        assert.ok(entry)
        const controller = new AbortController()
        controller.abort()
        await assert.rejects(
            entry.getData(new BlobWriter(), { signal: controller.signal }),
            error => error?.name === 'AbortError',
        )
    } finally {
        await reader.close()
    }
})
