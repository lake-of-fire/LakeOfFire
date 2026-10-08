const operations = new WeakMap()

export const finishOwnedElementOperation = element =>
    operations.get(element)?.finish?.() === true

export const beginOwnedElementOperation = (element, cleanup) => {
    if ((typeof element !== 'object' && typeof element !== 'function') || element === null) {
        throw new TypeError('An element object is required')
    }
    if (typeof cleanup !== 'function') {
        throw new TypeError('A cleanup function is required')
    }

    finishOwnedElementOperation(element)

    let active = true
    const operation = {
        get active() {
            return active
        },
        finish() {
            if (!active) return false
            active = false
            if (operations.get(element) === operation) {
                operations.delete(element)
            }
            try {
                cleanup()
            } catch (_error) {}
            return true
        },
    }
    operations.set(element, operation)
    return operation
}
