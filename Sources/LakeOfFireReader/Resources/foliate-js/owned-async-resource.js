export class OwnedAsyncResource {
    #dispose
    #generation = 0
    #activeToken = null
    #current = null
    #closed = false

    constructor(dispose) {
        this.#dispose = typeof dispose === 'function' ? dispose : () => {}
    }

    get current() {
        return this.#current
    }

    begin() {
        if (this.#closed) return null
        this.#releaseCurrent()
        const token = {
            generation: ++this.#generation,
            published: false,
        }
        this.#activeToken = token
        return token
    }

    isCurrent(token) {
        return !this.#closed && this.#activeToken === token
    }

    publish(token, value) {
        if (!this.isCurrent(token) || token.published) {
            this.#disposeValue(value)
            return false
        }
        token.published = true
        this.#current = value
        return true
    }

    close() {
        if (this.#closed) return false
        this.#closed = true
        this.#generation += 1
        this.#activeToken = null
        this.#releaseCurrent()
        return true
    }

    #releaseCurrent() {
        const current = this.#current
        this.#current = null
        if (current != null) this.#disposeValue(current)
    }

    #disposeValue(value) {
        try {
            this.#dispose(value)
        } catch (_error) {}
    }
}
