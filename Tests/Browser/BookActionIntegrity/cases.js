const check = (condition, message) => { if (!condition) throw new Error(message) }
const caseWithFixture = (name, run) => ({ name, async run() {
    const f = await makeBookActionSettlementFixture()
    try { await run(f) } finally { f.close() }
} })
window.bookStateTransactionCases = [
    caseWithFixture('committed-Finish-clears-real-disabled-button-even-when-timer-cleanup-throws', async f => {
        f.hooks.clear = () => { throw new Error('cleanup failed') }
        f.click()
        check(f.runtime.endcap.busy && f.runtime.endcap.button.disabled, 'Native action must initially own busy state')
        let accepted = false
        try { accepted = f.ack() } catch (_) {}
        await f.tick()
        check(accepted && !f.runtime.endcap.busy && !f.runtime.endcap.button.disabled, 'Committed result stranded the actual button')
        check(f.outcomes[0]?.ok && f.outcomes[0]?.value.committed, 'Committed Promise was not resolved')
    }),
    caseWithFixture('timer-installation-failure-keeps-status-only-recovery', async f => {
        f.hooks.install = () => { throw new Error('timeout unavailable') }
        f.click(); await f.tick()
        check(f.commands.length === 0, 'Failed timeout setup must retain the existing no-command policy')
        check(!f.runtime.endcap.busy && f.runtime.endcap.button.textContent === 'Check Status', 'Failed setup stranded the actual button')
        f.hooks.install = null
        f.click()
        check(f.commands.length === 1 && f.commands[0].kind === 'status', 'Recovery replayed an unsent mutation')
        f.ack(f.commands[0], { ok: false, committed: false }); await f.tick()
        check(!f.runtime.endcap.busy, 'Known status did not settle recovery')
    }),
    caseWithFixture('account-change-during-envelope-capture-cannot-send-a-retired-click', async f => {
        f.hooks.carry = body => { f.runtime.accountDidChange('2:1'); return body }
        f.click(); await f.tick()
        check(f.commands.length === 0, 'Retired account command was dispatched')
        check(f.runtime.bridge.recoveryInfo === null, 'Old request was restored in the new account')
        check(!f.runtime.endcap.busy && f.runtime.endcap.button.disabled, 'New account must wait for its own state')
    }),
    caseWithFixture('closing-during-timer-installation-cannot-send-an-orphaned-click', async f => {
        f.hooks.install = callback => { f.runtime.close(); return f.setNativeTimer(callback) }
        f.click(); await f.tick()
        check(f.commands.length === 0, 'Closed reader posted a native command')
        check(!f.runtime.endcap.element.isConnected, 'The endcap should be destroyed')
    }),
    caseWithFixture('failed-reply-copy-does-not-consume-the-real-button-request', async f => {
        f.click()
        const result = f.reply()
        result.self = result
        let accepted = false
        try { accepted = f.runtime.bridge.acknowledge(f.commands[0].deliveryID, result) } catch (_) {}
        check(!accepted && f.runtime.endcap.busy, 'Malformed copy must not settle the action')
        check(f.ack(), 'A subsequent valid reply no longer finds the original delivery')
        await f.tick()
        check(!f.runtime.endcap.busy && !f.runtime.endcap.button.disabled, 'Valid retry left real UI stuck')
    }),
    caseWithFixture('copied-native-rejection-must-still-match-request-identity', async f => {
        f.click()
        const result = f.reply()
        result.toJSON = () => ({ ...f.reply(), requestID: 'unrelated' })
        check(!f.runtime.bridge.acknowledge(f.commands[0].deliveryID, result), 'Serialized result changed request identity')
        check(f.ack(), 'Rejected copy consumed the request')
        await f.tick()
        check(f.outcomes[0]?.ok === true, 'Valid native result failed')
    }),
    caseWithFixture('nested-acknowledgement-owns-the-original-click-result', async f => {
        check(f.publish(true), 'The initial native Finished publication must be admitted')
        f.click()
        check(f.commands[0]?.action === 'startBookOver', 'The actual endcap must dispatch Start Book Over')
        const body = f.commands[0], result = f.reply(body, { navigation: { status: 'failed' } })
        result.toJSON = () => { f.ack(body); return f.reply(body, { navigation: { status: 'failed' } }) }
        check(!f.runtime.bridge.acknowledge(body.deliveryID, result), 'Outer reply superseded its accepted successor')
        await f.tick()
        check(f.outcomes[0]?.value.navigation.status === 'completed', 'Older copy replaced accepted navigation result')
        check(f.runtime.bridge.recoveryInfo === null, 'Older failure reintroduced navigation recovery')
    }),
    caseWithFixture('account-switch-during-copy-does-not-recreate-old-recovery', async f => {
        f.click()
        const body = f.commands[0], result = f.reply()
        result.toJSON = () => { f.runtime.accountDidChange('2:1'); return { ...result, toJSON: undefined } }
        check(!f.runtime.bridge.acknowledge(body.deliveryID, result), 'Retired reply reported an acknowledgement')
        await f.tick()
        check(f.runtime.bridge.recoveryInfo === null, 'Old reply recreated recovery state')
        check(f.outcomes[0]?.ok === false && !f.runtime.endcap.busy, 'Original action did not reject on retirement')
    }),
    caseWithFixture('reentrant-context-capture-does-not-dispatch-two-mutations', async f => {
        const capture = f.runtime.state.captureContext.bind(f.runtime.state)
        f.hooks.post = body => f.ack(body)
        f.runtime.state.captureContext = expected => {
            f.runtime.state.captureContext = capture
            f.runtime.bridge.perform('finishBook').catch(() => {})
            return capture(expected)
        }
        f.click(); await f.tick()
        check(f.commands.length === 1, 'Older preparation sent a second epoch command')
        check(f.runtime.bridge.recoveryInfo === null, 'Nested completed action left phantom recovery')
    }),
    caseWithFixture('unacknowledged-click-recovers-through-status-and-navigation-without-reset-replay', async f => {
        check(f.publish(true), 'The initial native Finished publication must be admitted')
        f.click()
        check(f.commands[0]?.action === 'startBookOver', 'The actual endcap must dispatch Start Book Over')
        await f.wait(110); await f.tick()
        check(f.runtime.endcap.button.textContent === 'Check Status', 'Timeout did not offer status-only recovery')
        f.click()
        check(f.commands.at(-1).kind === 'status', 'Status recovery replayed a command')
        f.ack(f.commands.at(-1), { navigation: { status: 'failed' } }); await f.tick()
        check(f.runtime.endcap.button.textContent === 'Go to Beginning', 'Committed navigation failure not recoverable')
        f.click()
        check(f.commands.at(-1).kind === 'navigate', 'Navigation recovery replayed a command')
        f.ack(); await f.tick()
        check(f.commands.filter(body => body.kind === 'command').length === 1, 'Recovery emitted another mutation')
        check(!f.runtime.endcap.busy && !f.runtime.endcap.button.disabled, 'Completed recovery left UI busy')
    }),
    caseWithFixture('late-command-acknowledgement-settles-status-before-cleanup-account-switch', async f => {
        f.click()
        const command = f.commands[0]
        await f.wait(110); await f.tick()
        f.click()
        check(f.commands.at(-1).kind === 'status', 'No status attempt exists')
        f.hooks.clear = () => f.runtime.accountDidChange('2:1')
        check(f.ack(command), 'Original native result was rejected')
        await f.tick()
        check(f.outcomes[1]?.ok === true && f.outcomes[1]?.value.committed, 'Cleanup changed committed result into account rejection')
        check(f.runtime.bridge.recoveryInfo === null, 'Old completion repopulated account state')
    }),
    caseWithFixture('ordinary-native-rejection-and-retry-preserve-one-command-per-click', async f => {
        f.click()
        f.ack(f.commands[0], { ok: false, committed: false, error: 'Chapter changed' }); await f.tick()
        check(!f.runtime.endcap.busy && !f.runtime.endcap.button.disabled, 'Rejected command left button busy')
        f.click()
        check(f.commands.length === 2 && f.commands[0].requestID !== f.commands[1].requestID, 'Deliberate fresh click was not admitted')
        f.ack(); await f.tick()
        check(f.runtime.bridge.recoveryInfo === null, 'Completed new action remains pending')
    }),
    caseWithFixture('producer-adapter-cannot-replace-a-clicked-Finish-with-reset', async f => {
        f.hooks.carry = body => ({ ...body, action: 'startBookOver' })
        f.click(); await f.tick()
        check(f.commands.length === 0, 'Producer adapter changed the user-selected mutation')
        check(!f.runtime.endcap.busy, 'Rejected send left the button busy')
    }),
    caseWithFixture('wire-serializer-cannot-retarget-the-current-chapter', async f => {
        f.hooks.carry = body => ({ ...body, toJSON: () => ({ ...body, context: { contextID: 'unrelated' } }) })
        f.click(); await f.tick()
        check(f.commands.length === 0, 'Serializer sent a different native context')
    }),
    caseWithFixture('producer-evidence-added-in-place-is-preserved', async f => {
        f.hooks.carry = (body, owner) => {
            Object.defineProperty(body, 'readerArticleProducer', { value: owner, enumerable: true })
            return body
        }
        f.click()
        check(f.commands.length === 1 && f.commands[0].readerArticleProducer.token === 'native-test-owner', 'Native evidence changed command equivalence')
        f.ack(); await f.tick()
        check(!f.runtime.endcap.busy && !f.runtime.endcap.button.disabled, 'Valid in-place evidence blocked completion')
    }),
    caseWithFixture('late-commit-bookkeeping-precedes-cleanup-admission-of-next-action', async f => {
        f.click()
        const command = f.commands[0]
        await f.wait(110); await f.tick()
        f.click()
        let successorResult
        f.hooks.clear = () => {
            f.hooks.clear = null
            f.hooks.post = body => f.ack(body)
            f.runtime.bridge.perform('finishBook').then(value => { successorResult = value }, () => {})
        }
        check(f.ack(command), 'Original native result was rejected')
        await f.tick()
        check(f.commands.length === 3, 'Already-committed action still blocked new deliberate admission')
        check(successorResult?.committed && f.runtime.bridge.recoveryInfo === null, 'Old bookkeeping clobbered its successor')
    }),
    caseWithFixture('consumer-decoration-cannot-change-cached-native-recovery-truth', async f => {
        check(f.publish(true), 'Finished state must be admitted')
        f.click()
        f.ack(f.commands[0], { navigation: { status: 'failed' } }); await f.tick()
        f.outcomes[0].value.committed = false
        f.outcomes[0].value.navigation.status = 'completed'
        const cached = await f.runtime.bridge.recover({ ...f.runtime.bridge.recoveryInfo, kind: 'status' })
        check(cached.committed === true && cached.navigation.status === 'failed', 'Resolved result alias changed native recovery truth')
        check(f.commands.length === 1, 'Read-only cached observation posted another command')
    }),
]
