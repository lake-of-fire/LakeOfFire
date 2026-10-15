import assert from 'node:assert/strict'
import test from 'node:test'
import { bookRecoverySetupFailureCases } from './book-recovery-setup-failure-cases.mjs'

assert.ok(bookRecoverySetupFailureCases.length > 0)
assert.equal(new Set(bookRecoverySetupFailureCases.map(([name]) => name)).size, bookRecoverySetupFailureCases.length)
for (const [name, run] of bookRecoverySetupFailureCases) test(name, { timeout: 5000 }, run)
