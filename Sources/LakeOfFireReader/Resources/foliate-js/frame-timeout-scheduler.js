export const FRAME_TIMEOUT_FALLBACK_MILLISECONDS = 250

export const scheduleFrameWithTimeoutFallback = ({
    callback,
    timeoutMilliseconds = FRAME_TIMEOUT_FALLBACK_MILLISECONDS,
    requestFrame = globalThis.requestAnimationFrame?.bind(globalThis),
    cancelFrame = globalThis.cancelAnimationFrame?.bind(globalThis),
    setTimer = globalThis.setTimeout.bind(globalThis),
    clearTimer = globalThis.clearTimeout.bind(globalThis),
}) => {
    let frameHandle = null
    let timeoutHandle = null
    let didFinish = false

    const cancel = () => {
        if (didFinish) return
        didFinish = true
        if (frameHandle != null && typeof cancelFrame === 'function') {
            cancelFrame(frameHandle)
        }
        if (timeoutHandle != null) {
            clearTimer(timeoutHandle)
        }
        frameHandle = null
        timeoutHandle = null
    }

    const runOnce = () => {
        if (didFinish) return
        if (frameHandle != null && typeof cancelFrame === 'function') {
            cancelFrame(frameHandle)
        }
        if (timeoutHandle != null) {
            clearTimer(timeoutHandle)
        }
        frameHandle = null
        timeoutHandle = null
        didFinish = true
        callback()
    }

    timeoutHandle = setTimer(runOnce, timeoutMilliseconds)
    if (typeof requestFrame === 'function') {
        frameHandle = requestFrame(runOnce)
    }

    return {
        get frameHandle() { return frameHandle },
        get timeoutHandle() { return timeoutHandle },
        cancel,
    }
}
