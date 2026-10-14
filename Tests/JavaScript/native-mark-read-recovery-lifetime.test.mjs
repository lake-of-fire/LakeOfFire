import assert from 'node:assert/strict'
import test from 'node:test'
import { recoveryLifetimeCases } from './native-mark-read-recovery-lifetime-cases.mjs'

assert.ok(recoveryLifetimeCases.length > 0, 'Recovery lifetime cases must not be empty')
assert.equal(new Set(recoveryLifetimeCases.map(([name]) => name)).size, recoveryLifetimeCases.length,
    'Recovery lifetime case names must be unique')
for (const [name, run] of recoveryLifetimeCases) test(name, { timeout: 5000 }, run)
