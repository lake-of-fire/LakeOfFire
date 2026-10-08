const managedIntents = new WeakSet()
const activeIntents = new WeakSet()
const previousIntents = new WeakMap()

const nearestActivePreviousIntent = intent => {
    let candidate = previousIntents.get(intent) ?? null
    const visited = new Set()
    while (
        candidate
        && managedIntents.has(candidate)
        && !activeIntents.has(candidate)
    ) {
        if (visited.has(candidate)) return null
        visited.add(candidate)
        candidate = previousIntents.get(candidate) ?? null
    }
    return candidate
}

export const beginNavigationIntent = (intent = {}, target = globalThis) => {
    const activeIntent = {
        timestamp: Date.now(),
        ...intent,
    }
    const previousIntent = target.__manabiNavigationIntent ?? null
    managedIntents.add(activeIntent)
    activeIntents.add(activeIntent)
    previousIntents.set(activeIntent, previousIntent)
    target.__manabiNavigationIntent = activeIntent

    let released = false
    return {
        intent: activeIntent,
        release() {
            if (released) return false
            released = true
            activeIntents.delete(activeIntent)
            if (target.__manabiNavigationIntent === activeIntent) {
                target.__manabiNavigationIntent = nearestActivePreviousIntent(activeIntent)
            }
            return true
        },
    }
}
