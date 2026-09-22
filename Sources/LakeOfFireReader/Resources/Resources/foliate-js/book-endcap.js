// A terminal reader location, NOT an EPUB section. The publication's spine,
// CFI, page counts, TOC, and text geometry remain completely unchanged.
export class BookEndcap {
    #destroyed = false
    #generation = 0
    #busy = false
    #finished = false
    #visible = false
    #previousFocus = null
    #previousInert = false
    #previousAriaHidden = null
    #listeners = []
    #ready = false
    #recovery = null

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
        this.button.addEventListener('click', click)
        this.#listeners.push(() => this.button.removeEventListener('click', click))
    }

    get visible() { return this.#visible }
    get busy() { return this.#busy }
    get finished() { return this.#finished }

    enter() {
        if (this.#destroyed || this.#visible) return false
        this.#visible = true
        this.#previousFocus = this.document.activeElement
        this.#previousInert = this.publication.inert === true
        this.#previousAriaHidden = this.publication.getAttribute('aria-hidden')
        this.publication.inert = true
        this.publication.setAttribute('aria-hidden', 'true')
        // Visibility (not display:none) preserves the underlying paginator's size.
        this.publication.classList.add('manabi-endcap-publication-hidden')
        this.element.hidden = false
        this.#render()
        this.heading.focus({ preventScroll: true })
        this.onChange(true)
        return true
    }

    leave({ restoreFocus = true } = {}) {
        if (!this.#visible) return false
        this.#visible = false
        this.element.hidden = true
        this.publication.inert = this.#previousInert
        if (this.#previousAriaHidden === null) this.publication.removeAttribute('aria-hidden')
        else this.publication.setAttribute('aria-hidden', this.#previousAriaHidden)
        this.publication.classList.remove('manabi-endcap-publication-hidden')
        if (restoreFocus && this.#previousFocus?.isConnected) {
            this.#previousFocus.focus?.({ preventScroll: true })
        }
        this.#previousFocus = null
        // Leaving is navigation, not cancellation of an already committed write.
        this.onChange(false)
        return true
    }

    setReady(ready) {
        this.#ready = ready === true
        this.#render()
    }

    setFinished(finished) {
        if (this.#destroyed) return
        this.#finished = finished === true
        this.#render()
    }

    async activate() {
        if (this.#destroyed || !this.#visible || this.#busy || (!this.#ready && !this.#recovery)) return false
        const generation = this.#generation
        const action = this.#finished ? 'startBookOver' : 'finishBook'
        this.#busy = true
        this.error.hidden = true
        this.#render()
        try {
            const result = this.#recovery
                ? await this.recoverAction(this.#recovery) : await this.performAction(action)
            if (this.#destroyed || generation !== this.#generation) return false
            if (result?.pending || result?.outcomeUnknown) {
                const error = new Error(result.error || 'Check the original action status.')
                error.outcomeUnknown = true
                error.requestID = result.requestID
                error.action = result.action || action
                throw error
            }
            if (result?.ok !== true) throw new Error(result?.error || 'The book action could not be completed. Try again.')
            // Only ordered native publications change Finished. Command replies
            // acknowledge a historical operation; they cannot select current state.
            if (result.navigation?.status === 'failed') {
                this.#recovery = { requestID: result.requestID, action: result.action || action, kind: 'navigate' }
                this.error.textContent = result.navigation.message || 'The new pass was saved. Go to its beginning without restarting again.'
                this.error.hidden = false
            } else { this.#recovery = null }
            return true
        } catch (error) {
            if (this.#destroyed || generation !== this.#generation) return false
            if (error?.outcomeUnknown && error.requestID) {
                this.#recovery = { requestID: error.requestID, action: error.action || action, kind: 'status' }
            } else { this.#recovery = null }
            this.error.textContent = error?.message || 'The book action could not be completed. Try again.'
            this.error.hidden = false
            return false
        } finally {
            if (!this.#destroyed && generation === this.#generation) {
                this.#busy = false
                this.#render()
            }
        }
    }

    #render() {
        this.heading.textContent = this.#finished ? 'Finished' : 'End of Book'
        this.description.hidden = this.#finished
        this.button.textContent = this.#recovery
            ? (this.#recovery.kind === 'navigate' ? 'Go to Beginning' : 'Check Status')
            : this.#finished ? 'Start Book Over' : 'Finish Book'
        this.button.disabled = this.#busy || (!this.#ready && !this.#recovery)
        this.element.setAttribute('aria-busy', String(this.#busy))
    }

    destroy() {
        if (this.#destroyed) return
        this.leave({ restoreFocus: false })
        this.#destroyed = true
        this.#generation += 1
        this.#listeners.forEach(remove => remove())
        this.#listeners = []
        this.element.remove()
    }
}

// Separate from physical page movement: endcap entry/exit must never be used
// as evidence that a paragraph/page was read or as a new locator to persist.
export const endcapNavigationResult = () => ({
    authoritativeNoMove: true,
    endcapNavigation: true,
})

export { createBookActionBridge } from './book-action-bridge.js'
