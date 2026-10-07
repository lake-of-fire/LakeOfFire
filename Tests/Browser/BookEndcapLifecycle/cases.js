// Complete Book runtime, controller, bridge and endcap. The shared fixture uses
// real DOM/iframe Documents and clicks, with controlled native/paginator leaves.
const expect = (value, message) => { if (!value) throw new Error(message) }
const make = async () => {
    const f = await makeBookActionSettlementFixture()
    f.activationErrors = []
    const activate = f.runtime.endcap.activate.bind(f.runtime.endcap)
    f.runtime.endcap.activate = () => {
        const promise = activate()
        // Observe the original promise, including a baseline rejection from
        // the void click listener; do not replace its result for awaiters.
        promise.catch(error => f.activationErrors.push(String(error)))
        return promise
    }
    return f
}
const onceDisabled = (button, callback) => {
    const descriptor = Object.getOwnPropertyDescriptor(HTMLButtonElement.prototype, 'disabled')
    Object.defineProperty(button, 'disabled', { configurable: true,
        get() { return descriptor.get.call(this) },
        set(value) {
            descriptor.set.call(this, value)
            delete this.disabled
            callback()
        },
    })
}
window.bookEndcapLifecycleCases = []
const add = (name, run) => bookEndcapLifecycleCases.push({ name, run })
for (const seam of ['busy-paint', 'action-lookup']) {
    for (const boundary of ['account', 'destroy', 'visit', 'readiness', 'finished']) {
        add(`clicked Finish ${seam} cannot acquire ${boundary} successor`, async () => {
            const f = await make(), cap = f.runtime.endcap
            try {
                const retire = () => {
                    if (boundary === 'account') { f.runtime.accountDidChange('2:1'); f.publish(false, '2:1') }
                    if (boundary === 'destroy') f.runtime.close()
                    if (boundary === 'visit') { cap.leave(); cap.enter(); f.publish() }
                    if (boundary === 'readiness') {
                        f.runtime.state.refresh()
                        f.runtime.state.apply(f.requests.at(-1).requestID, { ok: false, accountPresentation: '1:1' })
                    }
                    if (boundary === 'finished') f.publish(true)
                }
                if (seam === 'busy-paint') onceDisabled(cap.button, retire)
                else {
                    const perform = cap.performAction
                    Object.defineProperty(cap, 'performAction', { configurable: true, get() {
                        Object.defineProperty(cap, 'performAction', { configurable: true, writable: true, value: perform })
                        retire()
                        return perform
                    } })
                }
                f.click()
                await f.tick()
                expect(f.commands.length === 0, 'Retired click posted a native semantic command')
                expect(cap.busy === false, 'Retired activation retained busy state')
                expect(f.activationErrors.length === 0, 'Void click listener rejected unexpectedly')
            } finally { f.close() }
        })
    }
}
for (const node of ['heading', 'button', 'error']) {
    add(`throwing ${node} text cannot strand actual native completion`, async () => {
        const f = await make(), cap = f.runtime.endcap
        const target = cap[node]
        try {
            const text = Object.getOwnPropertyDescriptor(Node.prototype, 'textContent')
            Object.defineProperty(target, 'textContent', { configurable: true,
                get() { return text.get.call(this) }, set() { throw new Error('Optional paint failure') } })
            f.click()
            expect(f.commands.length === 1, 'A text failure suppressed dispatch')
            f.ack()
            await f.tick()
            expect(!cap.busy, 'Native result left the cap busy')
            expect(f.activationErrors.length === 0, 'Optional rendering rejected activation')
            delete target.textContent
            cap.setReady(true)
            expect(!cap.button.disabled, 'Recovered rendering could not restore the button')
        } finally { delete target.textContent; f.close() }
    })
}
add('recovery wrapper failure after accepted status never offers a second native reset', async () => {
    const f = await make(), cap = f.runtime.endcap
    try {
        f.click()
        f.ack(f.commands[0], { pending: true })
        await f.tick()
        expect(cap.button.textContent === 'Check Status', 'Fixture did not establish pending recovery')
        cap.recoverAction = async info => { await f.runtime.bridge.recover(info); throw new Error('Wrapper after native reply') }
        f.click()
        expect(f.commands[1].kind === 'status', 'Recovery did not send original status')
        f.ack(f.commands[1])
        f.publish(true)
        await f.tick()
        cap.recoverAction = info => f.runtime.bridge.recover(info)
        f.click()
        await f.tick()
        expect(f.commands.length === 2, 'Recovering an accepted action posted a second epoch command')
        expect(!cap.busy, 'Cached terminal status did not settle')
        expect(cap.button.textContent === 'Start Book Over', 'Only after recovered completion may the new action be offered')
    } finally { f.close() }
})
add('generic navigation recovery rejection preserves the original descriptor', async () => {
    const f = await make(), cap = f.runtime.endcap
    try {
        f.publish(true)
        f.click()
        f.ack(f.commands[0], { navigation: { status: 'failed' } })
        await f.tick()
        const original = f.commands[0].requestID
        cap.recoverAction = info => { info.requestID = 'changed'; throw new Error('Unavailable wrapper') }
        f.click()
        await f.tick()
        expect(cap.button.textContent === 'Check Status', 'A transport exception erased recovery')
        let descriptor
        cap.recoverAction = info => { descriptor = info; return f.runtime.bridge.recover(info) }
        f.click()
        await f.tick()
        expect(descriptor?.requestID === original && descriptor.kind === 'status', 'Recovery adopted caller-mutated identity')
        expect(f.commands.length === 1, 'Cached status must not replay the reset')
    } finally { f.close() }
})
add('destroy cannot reenter via its ordinary visibility callback', async () => {
    const f = await make(), cap = f.runtime.endcap
    try {
        const onChange = cap.onChange
        let entered
        cap.onChange = visible => {
            onChange(visible)
            if (!visible) { entered = cap.enter(); void cap.activate() }
        }
        cap.destroy()
        await f.tick()
        expect(entered === false, 'Teardown admitted another visit')
        expect(f.commands.length === 0, 'Teardown dispatched a semantic action')
        expect(!f.view.inert && !f.view.classList.contains('manabi-endcap-publication-hidden'), 'Publication remained inaccessible')
        expect(!cap.element.isConnected, 'Endcap was not removed')
    } finally { cap.onChange = () => {}; f.close() }
})
add('throwing visibility observer does not prevent actual DOM removal', async () => {
    const f = await make(), cap = f.runtime.endcap
    try {
        cap.onChange = () => { throw new Error('Visibility observer failed') }
        let thrown = null
        try { cap.destroy() } catch (error) { thrown = error }
        expect(thrown === null, 'Optional observer stopped teardown')
        expect(!cap.element.isConnected && !f.view.inert, 'Teardown did not restore the actual publication')
    } finally { cap.onChange = () => {}; f.close() }
})
add('real heading focus leave-and-return emits only current visit notifications', async () => {
    const f = await make(), cap = f.runtime.endcap
    try {
        cap.leave()
        const outside = document.createElement('button')
        outside.textContent = 'Outside'; document.body.append(outside); outside.focus()
        const notifications = [], notify = cap.onChange
        cap.onChange = visible => { notifications.push(visible); notify(visible) }
        cap.heading.addEventListener('focus', () => { cap.leave(); cap.enter() }, { once: true })
        cap.enter()
        expect(JSON.stringify(notifications) === '[false,true]', 'Old focus continuation emitted a duplicate enter')
        expect(cap.visible && f.view.inert, 'The successor visit was not retained')
    } finally { f.close() }
})
add('real restored focus reentry keeps the new restoration receipt', async () => {
    const f = await make(), cap = f.runtime.endcap
    try {
        cap.leave()
        const outside = document.createElement('button')
        outside.textContent = 'Outside'; document.body.append(outside); outside.focus()
        cap.enter()
        const notifications = [], notify = cap.onChange
        cap.onChange = visible => { notifications.push(visible); notify(visible) }
        outside.addEventListener('focus', () => cap.enter(), { once: true })
        cap.leave()
        expect(JSON.stringify(notifications) === '[true]', 'Old leave notified after focus opened a successor')
        cap.leave()
        expect(document.activeElement === outside, 'Old leave erased successor focus restoration')
        expect(!f.view.inert, 'Publication remained inert')
    } finally { f.close() }
})
add('actual accepted command survives navigation away and a return without replay', async () => {
    const f = await make(), cap = f.runtime.endcap
    try {
        f.click()
        cap.leave(); cap.enter(); f.publish()
        f.click()
        expect(f.commands.length === 1, 'A visit change reposted an already dispatched action')
        f.ack()
        await f.tick()
        expect(!cap.busy && !cap.button.disabled, 'Original result failed to settle in the same account')
    } finally { f.close() }
})
add('a negative native recovery ends recovery and retains native Finished', async () => {
    const f = await make(), cap = f.runtime.endcap
    try {
        f.publish(true)
        f.click(); f.ack(f.commands[0], { pending: true }); await f.tick()
        f.click()
        f.ack(f.commands[1], { ok: false, committed: false, error: 'Native rejected the original request' })
        await f.tick()
        expect(cap.button.textContent === 'Start Book Over', 'Explicit native rejection remained unknown')
        expect(cap.finished && !cap.busy && !cap.error.hidden, 'Recovery reply changed ordered native Finished state')
        expect(f.commands.map(x => x.kind).join(',') === 'command,status', 'Recovery issued a second mutation')
    } finally { f.close() }
})
add('normal native Finish and restart selection still follows ordered publication', async () => {
    const f = await make(), cap = f.runtime.endcap
    try {
        f.click(); f.ack(); await f.tick()
        expect(!cap.finished && cap.button.textContent === 'Finish Book', 'Command reply optimistically selected Finished')
        f.publish(true)
        expect(cap.finished && cap.button.textContent === 'Start Book Over', 'Native publication failed to select Finished')
        f.click()
        expect(f.commands[1].action === 'startBookOver', 'A new explicit restart chose the wrong action')
        f.ack(); f.publish(false); await f.tick()
        expect(!cap.busy && cap.button.textContent === 'Finish Book', 'Normal restart did not finish')
    } finally { f.close() }
})
