import assert from 'node:assert/strict'
import test from 'node:test'
import { bookRecoverySetupFailureCases } from './book-recovery-setup-failure-cases.mjs'
import { bookReadingDeliveryCases } from './book-reading-delivery-cases.mjs'

const cases = [...bookRecoverySetupFailureCases, ...bookReadingDeliveryCases]
assert.ok(cases.length > 0)
assert.equal(new Set(cases.map(([name]) => name)).size, cases.length)
for (const [name, run] of cases) test(name, { timeout: 5000 }, run)
