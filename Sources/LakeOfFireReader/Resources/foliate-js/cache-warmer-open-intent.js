export class CacheWarmerOpenIntent {
    #closed = false
    #requested = false

    get requested() {
        return this.#requested
    }

    request() {
        if (this.#closed) return false
        this.#requested = true
        return true
    }

    consume() {
        if (this.#closed || !this.#requested) return false
        this.#requested = false
        return true
    }

    close() {
        if (this.#closed) return false
        this.#closed = true
        this.#requested = false
        return true
    }
}
