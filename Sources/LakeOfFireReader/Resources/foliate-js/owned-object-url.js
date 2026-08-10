export class OwnedObjectURL {
    #create
    #revoke
    #current = null

    constructor({
        create = blob => URL.createObjectURL(blob),
        revoke = url => URL.revokeObjectURL(url),
    } = {}) {
        this.#create = create
        this.#revoke = revoke
    }

    get current() {
        return this.#current
    }

    replace(blob) {
        if (blob == null) return null
        const next = this.#create(blob)
        this.clear()
        this.#current = next
        return next
    }

    clear() {
        if (this.#current == null) return false
        const current = this.#current
        this.#current = null
        this.#revoke(current)
        return true
    }
}
