import assert from 'node:assert/strict'
import test from 'node:test'

import { OwnedObjectURL } from '../../Sources/LakeOfFireReader/Resources/foliate-js/owned-object-url.js'

test('replacement revokes the previous object URL exactly once', () => {
    const revoked = []
    let sequence = 0
    const owner = new OwnedObjectURL({
        create: () => `blob:${++sequence}`,
        revoke: url => revoked.push(url),
    })

    assert.equal(owner.replace({}), 'blob:1')
    assert.equal(owner.replace({}), 'blob:2')
    assert.deepEqual(revoked, ['blob:1'])
    assert.equal(owner.current, 'blob:2')
})

test('clear releases the current URL and is idempotent', () => {
    const revoked = []
    const owner = new OwnedObjectURL({
        create: () => 'blob:cover',
        revoke: url => revoked.push(url),
    })
    owner.replace({})

    assert.equal(owner.clear(), true)
    assert.equal(owner.clear(), false)
    assert.deepEqual(revoked, ['blob:cover'])
    assert.equal(owner.current, null)
})
