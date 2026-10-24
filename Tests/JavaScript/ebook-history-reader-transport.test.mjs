import assert from 'node:assert/strict'
import test from 'node:test'
import { readFile } from 'node:fs/promises'
import { createManualNavigationRunner, createNavigationIntentRunner } from '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-load-coordinator.js'

// Execute the shipping Reader adapter and its private runner method unchanged.
// Browser-only construction is outside this fixture; these method declarations
// are not copied, rewritten, or replaced by a test routing implementation.
const source = await readFile(new URL(
    '../../Sources/LakeOfFireReader/Resources/foliate-js/ebook-viewer.js', import.meta.url,
), 'utf8')
const start = source.indexOf('    async _goToDescriptor(descriptor) {')
const end = source.indexOf('    async goToHref(', start)
if (start < 0 || end <= start) throw new Error('Reader history adapter declarations were not found')
const declarations = source.slice(start, end)

function fixture(operation) {
    const calls = [], errors = [], admissions = []
    const receipt = Object.freeze({})
    const view = {
        renderer: { goTo() {} },
        isNavigationReceiptCurrent: value => value === receipt,
        goTo: (target, options) => {
            calls.push({ method: 'goTo', target, options })
            return operation ? operation(receipt) : receipt
        },
        goToFraction: (target, options) => {
            calls.push({ method: 'goToFraction', target, options })
            return operation ? operation(receipt) : receipt
        },
    }
    const host = {}
    const run = createManualNavigationRunner({
        host, runWithNavigationIntent: createNavigationIntentRunner(host),
        captureOwner: () => ({ isCurrent: () => true }),
        onAccepted: value => admissions.push(value),
    })
    const ReaderAdapter = new Function('runManualNavigation', 'console',
        'return class { constructor(view) { this.view = view; this.isClosed = false; }\n'
        + declarations + '\n}',
    )(run, { error: (...values) => { errors.push(values) } })
    const reader = new ReaderAdapter(view)
    host.reader = reader
    return { reader, view, host, receipt, calls, errors, admissions }
}

const paths = [
    {
        label: 'local page',
        descriptor: { sectionIndex: 1.2, localSectionIndex: 2.6, rendererTotal: 5 },
        method: 'goTo', target: 1,
        options: { requiresNavigationReceipt: true, localPage: 3, recordHistory: false },
    },
    {
        label: 'CFI',
        descriptor: { cfi: 'epubcfi(/6/2!/4/2/1:3)' },
        method: 'goTo', target: 'epubcfi(/6/2!/4/2/1:3)',
        options: { requiresNavigationReceipt: true },
    },
    {
        label: 'fraction',
        descriptor: { fraction: 0.75 },
        method: 'goToFraction', target: 0.75,
        options: { requiresNavigationReceipt: true },
    },
]
for (const path of paths) {
    test('Reader ' + path.label + ' transports the actual current command receipt to its HUD', async () => {
        const f = fixture()
        const result = await f.reader._goToDescriptor(path.descriptor)
        assert.equal(result, f.receipt)
        assert.equal(f.view.isNavigationReceiptCurrent(result), true)
        assert.deepEqual(f.calls, [{ method: path.method, target: path.target, options: path.options }])
        assert.equal(f.admissions.length, 1)
        assert.equal(f.admissions[0].reader, f.reader)
        assert.deepEqual(f.errors, [])
    })

    test('Reader ' + path.label + ' preserves denied completion as a non-successful result', async () => {
        const f = fixture(async () => null)
        assert.equal(await f.reader._goToDescriptor(path.descriptor), null)
        assert.equal(f.calls.length, 1)
        assert.deepEqual(f.admissions, [])
        assert.deepEqual(f.errors, [])
    })

    test('Reader ' + path.label + ' preserves its current exception policy without issuing success', async () => {
        const failure = new Error('failed history source')
        const f = fixture(async () => { throw failure })
        if (path.label === 'fraction') {
            await assert.rejects(f.reader._goToDescriptor(path.descriptor), error => error === failure)
            assert.deepEqual(f.errors, [])
        } else {
            assert.equal(await f.reader._goToDescriptor(path.descriptor), undefined)
            assert.deepEqual(f.errors, [[failure]])
        }
        assert.deepEqual(f.admissions, [])
    })
}

test('Reader adapter cannot return an old receipt after the installed Reader is replaced', async () => {
    let release
    const gate = new Promise(resolve => { release = resolve })
    const f = fixture(() => gate)
    const old = f.reader._goToDescriptor({ fraction: 0.5 })
    f.host.reader = { view: f.view }
    release(f.receipt)
    assert.equal(await old, null)
    assert.deepEqual(f.admissions, [])
})
