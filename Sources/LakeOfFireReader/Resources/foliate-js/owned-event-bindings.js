const bindingRecordsByTarget = new WeakMap()

const bindingRecords = target => {
    let records = bindingRecordsByTarget.get(target)
    if (!records) {
        records = new Map()
        bindingRecordsByTarget.set(target, records)
    }
    return records
}

const restoreOriginalBinding = (target, key, record) => {
    if (record.hadOwnProperty) {
        target[key] = record.originalValue
        return
    }
    try {
        delete target[key]
    } catch (_error) {
        target[key] = undefined
    }
}

export class OwnedEventBindings {
    #cleanups = new Set()
    #active = true

    listen(target, type, listener, options) {
        if (!this.#active
            || !target?.addEventListener
            || typeof type !== 'string'
            || type.length === 0
            || typeof listener !== 'function') {
            return false
        }

        target.addEventListener(type, listener, options)
        let active = true
        const cleanup = () => {
            if (!active) return false
            active = false
            this.#cleanups.delete(cleanup)
            target.removeEventListener?.(type, listener, options)
            return true
        }
        this.#cleanups.add(cleanup)
        return true
    }

    bind(target, key, value) {
        if (!this.#active
            || (typeof target !== 'object' && typeof target !== 'function')
            || target === null
            || typeof key !== 'string'
            || key.length === 0) {
            return false
        }

        const records = bindingRecords(target)
        let record = records.get(key)
        if (!record) {
            record = {
                hadOwnProperty: Object.prototype.hasOwnProperty.call(target, key),
                originalValue: target[key],
                claims: [],
            }
            records.set(key, record)
        }

        const claim = { value }
        record.claims.push(claim)
        target[key] = value

        let active = true
        const cleanup = () => {
            if (!active) return false
            active = false
            this.#cleanups.delete(cleanup)

            const claimIndex = record.claims.indexOf(claim)
            if (claimIndex < 0) return false
            const wasCurrentClaim = claimIndex === record.claims.length - 1
            record.claims.splice(claimIndex, 1)
            if (!wasCurrentClaim) return true
            if (target[key] !== value) {
                if (record.claims.length === 0) {
                    records.delete(key)
                    if (records.size === 0) bindingRecordsByTarget.delete(target)
                }
                return true
            }

            const currentClaim = record.claims.at(-1)
            if (currentClaim) {
                target[key] = currentClaim.value
            } else {
                restoreOriginalBinding(target, key, record)
                records.delete(key)
                if (records.size === 0) bindingRecordsByTarget.delete(target)
            }
            return true
        }
        this.#cleanups.add(cleanup)
        return true
    }

    addCleanup(cleanup) {
        if (!this.#active || typeof cleanup !== 'function') return false
        let active = true
        const ownedCleanup = () => {
            if (!active) return false
            active = false
            this.#cleanups.delete(ownedCleanup)
            cleanup()
            return true
        }
        this.#cleanups.add(ownedCleanup)
        return true
    }

    clear() {
        if (!this.#active) return false
        this.#active = false
        for (const cleanup of [...this.#cleanups]) {
            try {
                cleanup()
            } catch (_error) {}
        }
        this.#cleanups.clear()
        return true
    }
}

export class OwnedEventBindingScopes {
    #bindingsByOwner = new Map()
    #active = true

    begin(owner) {
        if (!this.#active || owner == null) return null
        this.release(owner)
        const bindings = new OwnedEventBindings()
        this.#bindingsByOwner.set(owner, bindings)
        return bindings
    }

    isCurrent(owner, bindings) {
        return this.#active && this.#bindingsByOwner.get(owner) === bindings
    }

    release(owner) {
        const bindings = this.#bindingsByOwner.get(owner)
        if (!bindings) return false
        this.#bindingsByOwner.delete(owner)
        bindings.clear()
        return true
    }

    clear() {
        if (!this.#active) return false
        this.#active = false
        for (const bindings of this.#bindingsByOwner.values()) bindings.clear()
        this.#bindingsByOwner.clear()
        return true
    }
}
