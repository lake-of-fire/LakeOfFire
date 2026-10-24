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
            const operation = { controller, promise: null }
            // Every waiter joins the entire settlement, including retention
            // failures and owned cleanup, rather than only the factory result.
            operation.promise = Promise.resolve()
                .then(() => {
                    // clear() can retire this entry before its first microtask.
                    // Do not start work whose abort event has already fired.
                    if (inFlightValues.get(key) !== operation) {
                        throw controller?.signal.reason ?? Object.assign(
                            new Error('The cache was cleared before work began.'), { name: 'AbortError' })
                    }
                    return createValue(controller?.signal ?? null)
                })
                .then(value => {
                    if (inFlightValues.get(key) === operation
                        && shouldRemember(value, key)
                        // The retention callback (or a result getter it reads)
                        // may clear the cache and start a replacement producer.
                        && inFlightValues.get(key) === operation) {
                        remember(key, value)
                    }
                    // Clearing retires cache publication, not the original
                    // callers' result if their producer ignores cancellation.
                    return value
                })
                .finally(() => {
                    if (inFlightValues.get(key) === operation) {
                        inFlightValues.delete(key)
                    }
                })
            inFlightValues.set(key, operation)
            return await operation.promise
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
