export const rendererNavigationAccepted = result => result === true

export const rendererNavigationInFlight = renderer => {
    try {
        return renderer?.navigationInFlight === true
    } catch (_error) {
        // A renderer whose ownership state cannot be inspected is not safe to
        // enter from a second navigation boundary.
        return true
    }
}

export const rendererNavigationNotOwned = (reason = 'rendererNavigationInFlight') => ({
    ignored: true,
    reason,
})

export const runCurrentRendererNavigation = async ({
    operation,
    isCurrent = () => true,
    supersededReason = 'viewRendererSuperseded',
}) => {
    const notOwned = () => rendererNavigationNotOwned(supersededReason)
    if (!isCurrent()) return notOwned()
    try {
        const result = await operation()
        return isCurrent() ? result : notOwned()
    } catch (error) {
        if (!isCurrent()) return notOwned()
        throw error
    }
}

export const waitForCurrentRendererIndexChange = async ({
    originalIndex,
    getCurrentIndex,
    isCurrent = () => true,
    attempts = 80,
    intervalMs = 50,
    sleep = delay => new Promise(resolve => setTimeout(resolve, delay)),
}) => {
    if (!Number.isFinite(originalIndex) || typeof getCurrentIndex !== 'function') {
        return false
    }
    const attemptCount = Number.isInteger(attempts) && attempts > 0 ? attempts : 0
    for (let attempt = 0; attempt < attemptCount; attempt += 1) {
        if (!isCurrent()) return false
        const currentIndex = getCurrentIndex()
        if (!isCurrent()) return false
        if (Number.isFinite(currentIndex) && currentIndex !== originalIndex) {
            return true
        }
        if (attempt + 1 < attemptCount) {
            await sleep(Math.max(0, Number(intervalMs) || 0))
        }
    }
    return false
}

export const advanceCurrentRendererSection = async ({
    renderer,
    getCurrentIndex,
    isCurrent = () => true,
    waitForIndexChange = waitForCurrentRendererIndexChange,
}) => {
    if (!renderer || typeof renderer.nextSection !== 'function') return false
    if (typeof getCurrentIndex !== 'function' || !isCurrent()) return false

    const originalIndex = getCurrentIndex()
    if (!isCurrent() || !Number.isFinite(originalIndex)) return false

    const result = await runCurrentRendererNavigation({
        operation: () => renderer.nextSection(),
        isCurrent,
        supersededReason: 'readAloudRendererSuperseded',
    })
    if (!rendererNavigationAccepted(result)) return false

    return await waitForIndexChange({
        originalIndex,
        getCurrentIndex,
        isCurrent,
    })
}
