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

    constructor({ document, host, publication, performAction, onChange = () => {} }) {
        this.document = document
        this.publication = publication
        this.performAction = performAction
        this.onChange = onChange
        this.element = document.createElement('section')
        this.element.className = 'manabi-book-endcap'
        this.element.setAttribute('aria-label', 'End of Book')
        this.element.hidden = true
        // Only constant app-owned text goes into this page, never book markup.
        this.element.innerHTML = `
            <div class="manabi-book-endcap-content">
                <h1 tabindex="-1">End of Book</h1>
                <p class="manabi-book-endcap-description">Finish this book without changing any read markings.</p>
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

    setFinished(finished) {
        if (this.#destroyed) return
        this.#finished = finished === true
        this.#render()
    }

    async activate() {
        if (this.#destroyed || !this.#visible || this.#busy) return false
        const generation = this.#generation
        const action = this.#finished ? 'startBookOver' : 'finishBook'
        this.#busy = true
        this.error.hidden = true
        this.#render()
        try {
            const result = await this.performAction(action)
            if (this.#destroyed || generation !== this.#generation) return false
            if (result?.ok !== true) throw new Error(result?.error || 'The book action could not be completed. Try again.')
            this.#finished = result.finished === true
            if (action === 'startBookOver') this.leave()
            return true
        } catch (error) {
            if (this.#destroyed || generation !== this.#generation) return false
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
        this.button.textContent = this.#finished ? 'Start Book Over' : 'Finish Book'
        this.button.disabled = this.#busy
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

// All actions have an explicit native acknowledgement. No mark-all payload,
// optimistic Finished state, retry of a reset, or navigation before commit.
export const createBookActionBridge = ({ postMessage, documentStartedAtMs, topWindowURL }) => {
    const pending = new Map()
    let sequence = 0
    let closed = false
    const prefix = `${documentStartedAtMs}:${Math.random().toString(36).slice(2)}`
    return {
        perform(action) {
            if (closed) return Promise.reject(new Error('Reader closed'))
            if (!['finishBook', 'startBookOver'].includes(action)) {
                return Promise.reject(new Error('Unsupported book action'))
            }
            const requestID = `${prefix}:${++sequence}`
            return new Promise((resolve, reject) => {
                pending.set(requestID, { resolve, reject })
                try { postMessage({ action, requestID, topWindowURL, documentStartedAtMs }) }
                catch (error) { pending.delete(requestID); reject(error) }
            })
        },
        acknowledge(requestID, result) {
            const request = pending.get(requestID)
            if (!request) return false
            pending.delete(requestID)
            request.resolve(result)
            return true
        },
        close() {
            closed = true
            for (const request of pending.values()) request.reject(new Error('Reader closed'))
            pending.clear()
        },
    }
}
