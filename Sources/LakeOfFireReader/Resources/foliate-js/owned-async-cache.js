export const createOwnedAsyncCache = ({
    limit = Infinity,
    shouldRemember = () => true,
} = {}) => {
    const normalizedLimit = Number.isFinite(limit)
        ? Math.max(0, Math.floor(limit))
        : Infinity
    const resolvedValues = new Map()
    const inFlightValues = new Map()

    const remember = (key, value) => {
        if (normalizedLimit === 0) return
        resolvedValues.delete(key)
        resolvedValues.set(key, value)
        while (resolvedValues.size > normalizedLimit) {
            resolvedValues.delete(resolvedValues.keys().next().value)
        }
    }

    return {
        async getOrCreate(key, createValue) {
            if (resolvedValues.has(key)) {
                const value = resolvedValues.get(key)
                resolvedValues.delete(key)
                resolvedValues.set(key, value)
                return value
            }
            const inFlight = inFlightValues.get(key)
            if (inFlight) return await inFlight.promise

            const controller = typeof AbortController === 'function'
                ? new AbortController()
                : null
            const promise = Promise.resolve().then(() => createValue(controller?.signal ?? null))
            const operation = { promise, controller }
            inFlightValues.set(key, operation)
            try {
                const value = await promise
                if (inFlightValues.get(key) === operation && shouldRemember(value, key)) {
                    remember(key, value)
                }
                return value
            } finally {
                if (inFlightValues.get(key) === operation) {
                    inFlightValues.delete(key)
                }
            }
        },
        clear() {
            resolvedValues.clear()
            const operations = Array.from(inFlightValues.values())
            inFlightValues.clear()
            for (const operation of operations) {
                try {
                    operation.controller?.abort()
                } catch (_error) {}
            }
        },
    }
}
