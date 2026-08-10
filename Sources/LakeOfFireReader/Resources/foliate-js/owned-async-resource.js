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

export class OwnedScheduledTask {
    #scheduleTask
    #cancelTask
    #handle = null
    #generation = 0
    #closed = false

    constructor({
        schedule = (callback, delay) => setTimeout(callback, delay),
        cancel = handle => clearTimeout(handle),
    } = {}) {
        this.#scheduleTask = schedule
        this.#cancelTask = cancel
    }

    schedule(callback, delay = 0) {
        if (this.#closed || typeof callback !== 'function') return false
        this.cancel()
        const generation = ++this.#generation
        this.#handle = this.#scheduleTask(() => {
            if (this.#closed || generation !== this.#generation) return
            this.#handle = null
            callback()
        }, delay)
        return true
    }

    cancel() {
        this.#generation += 1
        if (this.#handle == null) return false
        this.#cancelTask(this.#handle)
        this.#handle = null
        return true
    }

    close() {
        if (this.#closed) return false
        this.#closed = true
        this.cancel()
        return true
    }
}
