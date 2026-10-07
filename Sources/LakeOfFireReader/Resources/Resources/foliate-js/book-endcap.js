// A terminal reader location, NOT an EPUB section. The publication's spine,
// CFI, page counts, TOC, and text geometry remain completely unchanged.
// Error wording is optional presentation, not the command's outcome. Read it
// once without letting a failing formatter discard an admitted recovery.
const bookActionMessage = (source, property, fallback) => {
    try {
        const message = source?.[property]
        return typeof message === 'string' && message ? message : fallback
    } catch (_) { return fallback }
}

export class BookEndcap {
    #destroyed = false
    #generation = 0
    #busy = false
    #finished = false
    // One visit owns both visibility and the accessibility state it restores.
    // Reentering with equal values still creates a different visit.
    #visibility = { visible: false }
    #listeners = []
    #ready = false
    #recovery = null
    #message = null

    constructor({ document, host, publication, performAction, recoverAction = null, onChange = () => {} }) {
        this.document = document
        this.publication = publication
        this.performAction = performAction
        this.recoverAction = recoverAction
        this.onChange = onChange
        this.element = document.createElement('section')
        this.element.className = 'manabi-book-endcap'
        this.element.setAttribute('aria-label', 'End of Book')
        this.element.hidden = true
        // Only constant app-owned text goes into this page, never book markup.
        this.element.innerHTML = `
            <div class="manabi-book-endcap-content">
                <h1 tabindex="-1">End of Book</h1>
                <p class="manabi-book-endcap-description">Your reading history and skipped sections will stay unchanged.</p>
                <button type="button" class="manabi-book-endcap-action">Finish Book</button>
                <p class="manabi-book-endcap-error" role="alert" hidden></p>
            </div>`
        host.append(this.element)
        this.heading = this.element.querySelector('h1')
        this.description = this.element.querySelector('.manabi-book-endcap-description')
        this.button = this.element.querySelector('button')
        this.error = this.element.querySelector('[role="alert"]')
        const click = event => {
            // The shared native message layer separately requires trusted activation.
            event.stopPropagation()
            void this.activate()
        }
        const button = this.button
        button.addEventListener('click', click)
        this.#listeners.push(() => button.removeEventListener('click', click))
    }

    get visible() { return this.#visibility.visible }
    get busy() { return this.#busy }
    get finished() { return this.#finished }

    enter() {
        if (this.#destroyed || this.#visibility.visible) return false
        const previous = this.#visibility
        let visit
        try {
            visit = { visible: true, focus: this.document.activeElement,
                inert: this.publication.inert === true,
                ariaHidden: this.publication.getAttribute('aria-hidden') }
        } catch (_) { return false }
        if (this.#destroyed || this.#visibility !== previous) return false
        this.#visibility = visit
        const isCurrent = () => !this.#destroyed && this.#visibility === visit
        for (const show of [
            () => { this.publication.inert = true },
            () => this.publication.setAttribute('aria-hidden', 'true'),
            // Preserve the underlying paginator's size; do not use display:none.
            () => this.publication.classList.add('manabi-endcap-publication-hidden'),
            () => { this.element.hidden = false },
            () => this.#render(),
            () => this.heading.focus({ preventScroll: true }),
        ]) {
            if (!isCurrent()) return false
            try { show() } catch (_) {}
        }
        // Focus dispatches synchronous page events. Only this exact visit may
        // emit its notification, even after leave-and-return to equal values.
        if (!isCurrent()) return false
        try { this.onChange(true) } catch (_) {}
        return isCurrent()
    }

    leave({ restoreFocus = true } = {}) {
        const visit = this.#visibility
        if (!visit.visible) return false
        const departure = this.#visibility = { visible: false }
        const isCurrent = () => this.#visibility === departure
        // Detach the original restoration record before callbacks can enter
        // again. The successor's focus receipt belongs to its own visit.
        for (const restore of [
            () => { this.element.hidden = true },
            () => { this.publication.inert = visit.inert },
            () => visit.ariaHidden === null ? this.publication.removeAttribute('aria-hidden')
                : this.publication.setAttribute('aria-hidden', visit.ariaHidden),
            () => this.publication.classList.remove('manabi-endcap-publication-hidden'),
            () => { if (restoreFocus && visit.focus?.isConnected) visit.focus.focus?.({ preventScroll: true }) },
        ]) {
            if (!isCurrent()) return false
            try { restore() } catch (_) {} // One optional effect cannot strand the publication.
        }
        if (!isCurrent()) return false
        // Leaving is navigation, not cancellation of an already committed write.
        try { this.onChange(false) } catch (_) {}
        return isCurrent()
    }

    accountDidChange() {
        if (this.#destroyed) return
        this.#generation += 1
        this.#busy = false; this.#ready = false; this.#finished = false; this.#recovery = null
        this.#message = null
        this.#render()
    }

    setReady(ready) {
        if (this.#destroyed) return
        this.#ready = ready === true
        this.#render()
    }

    setFinished(finished) {
        if (this.#destroyed) return
        this.#finished = finished === true
        this.#render()
    }

    async activate() {
        if (this.#destroyed || !this.#visibility.visible || this.#busy || (!this.#ready && !this.#recovery)) return false
        const generation = this.#generation, finished = this.#finished
        const recovery = this.#recovery, visit = this.#visibility
        const action = recovery?.action || (finished ? 'startBookOver' : 'finishBook')
        const isCurrent = () => !this.#destroyed && generation === this.#generation
        const mayDispatch = () => isCurrent() && this.#busy && this.#visibility === visit
            && this.#recovery === recovery && (recovery !== null
                || (this.#ready && this.#finished === finished))
        this.#busy = true
        this.#message = null
        try {
            this.#render()
            // Busy rendering and replaceable callback lookup can retire the
            // activation. Never capture a new account's command from that click.
            if (!mayDispatch()) return false
            const perform = recovery ? this.recoverAction : this.performAction
            if (!mayDispatch()) return false
            if (typeof perform !== 'function') throw new Error('Book Actions are unavailable. Reopen the book and try again.')
            const result = await Reflect.apply(perform, this, [recovery ? { ...recovery } : action])
            if (!isCurrent()) return false
            if (result?.pending || result?.outcomeUnknown) {
                const requestID = recovery?.requestID || result.requestID
                const nextRecovery = requestID
                    ? { requestID, action: recovery?.action || result.action || action, kind: 'status' } : null
                const message = bookActionMessage(result, 'error', 'Check the original action status.')
                if (!isCurrent()) return false
                this.#recovery = nextRecovery
                this.#message = message
                return false
            }
            const ok = result?.ok
            if (ok !== true) {
                const message = bookActionMessage(result, 'error', 'The book action could not be completed. Try again.')
                if (!isCurrent()) return false
                // Only an explicit negative outcome ends known recovery. A
                // missing/failed wrapper response cannot authorize a new reset.
                this.#recovery = ok === false || !recovery ? null : { ...recovery, kind: 'status' }
                this.#message = message
                return false
            }
            // Prepare recovery before publishing any of it. Result accessors
            // may switch accounts just like the original asynchronous action.
            const navigation = result.navigation
            const nextRecovery = navigation?.status === 'failed'
                ? { requestID: result.requestID, action: result.action || action, kind: 'navigate' } : null
            const message = nextRecovery ? bookActionMessage(navigation, 'message',
                'The new pass was saved. Go to its beginning without restarting again.') : null
            if (!isCurrent()) return false
            // Only ordered native publications change Finished. Command replies
            // acknowledge a historical operation; they cannot select current state.
            this.#recovery = nextRecovery
            this.#message = message
            return true
        } catch (error) {
            if (!isCurrent()) return false
            // A recovery transport exception is not evidence that its original
            // reset failed. Keep that request and check status; never reissue it.
            let nextRecovery = recovery ? { ...recovery, kind: 'status' } : null
            try {
                const requestID = error?.requestID
                if (!recovery && error?.outcomeUnknown && requestID) {
                    nextRecovery = { requestID, action: error.action || action, kind: 'status' }
                }
            } catch (_) {} // Unreadable error metadata cannot replace known recovery.
            const message = bookActionMessage(error, 'message', 'The book action could not be completed. Try again.')
            if (!isCurrent()) return false
            this.#recovery = nextRecovery
            this.#message = message
            return false
        } finally {
            if (isCurrent()) {
                this.#busy = false
                this.#render()
            }
        }
    }

    #render() {
        const generation = this.#generation
        // Each effect reads the current private view state. Account replacement
        // retires the pass; a same-account update supplies the latest values.
        // Optional paint never escapes activate() or prevents promise settlement.
        for (const update of [
            () => { this.heading.textContent = this.#finished ? 'Finished' : 'End of Book' },
            () => { this.description.hidden = this.#finished },
            () => { this.button.textContent = this.#recovery
                ? (this.#recovery.kind === 'navigate' ? 'Go to Beginning' : 'Check Status')
                : this.#finished ? 'Start Book Over' : 'Finish Book' },
            () => { this.button.disabled = this.#busy || (!this.#ready && !this.#recovery) },
            () => this.element.setAttribute('aria-busy', String(this.#busy)),
            () => { this.error.hidden = this.#message === null },
            () => { if (this.#message !== null) this.error.textContent = this.#message },
        ]) {
            if (this.#destroyed || generation !== this.#generation) return
            try { update() } catch (_) {}
        }
    }

    destroy() {
        if (this.#destroyed) return
        // Retire before leave/focus/observer callbacks can reenter. Teardown
        // restores the publication but cannot authorize another activation.
        this.#destroyed = true
        this.#generation += 1
        this.#busy = false
        const listeners = this.#listeners
        this.#listeners = []
        this.leave({ restoreFocus: false })
        for (const remove of listeners) {
            try { remove() } catch (_) {}
        }
        try { this.element.remove() } catch (_) {}
    }
}

// Separate from physical page movement: endcap entry/exit must never be used
// as evidence that a paragraph/page was read or as a new locator to persist.
export const endcapNavigationResult = () => ({
    authoritativeNoMove: true,
    endcapNavigation: true,
})

export { createBookActionBridge } from './book-action-bridge.js'
