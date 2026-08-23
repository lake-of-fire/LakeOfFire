const defaultRequestID = () => {
    if (typeof globalThis.crypto?.randomUUID === 'function') {
        return globalThis.crypto.randomUUID()
    }
    return `mark-${Date.now()}-${Math.random().toString(36).slice(2)}`
}

const nonEmptyExactString = value => (
    typeof value === 'string'
    && value.length > 0
    && value.trim() === value
)

const defaultMaximumRequestIDAttempts = 32
const maximumRequestIDLength = 128
const maximumSectionIDLength = 512

const boundedRequestString = (value, maximumLength) => (
    nonEmptyExactString(value) && value.length <= maximumLength
)

/**
 * Owns the request/reply lifetime for a native mark-read transaction.
 * Visible read state may be published only after the returned promise succeeds.
 */
export const createNativeMarkReadRequestCoordinator = ({
    postMessage,
    isOwnerCurrent = () => true,
    makeRequestID = defaultRequestID,
    timeoutMilliseconds = 15_000,
    scheduleTimeout = globalThis.setTimeout,
    cancelTimeout = globalThis.clearTimeout,
    maximumRequestIDAttempts = defaultMaximumRequestIDAttempts,
} = {}) => {
    if (typeof postMessage !== 'function') {
        throw new TypeError('postMessage must be a function')
    }
    if (typeof isOwnerCurrent !== 'function') {
        throw new TypeError('isOwnerCurrent must be a function')
    }
    if (typeof makeRequestID !== 'function') {
        throw new TypeError('makeRequestID must be a function')
    }
    if (typeof scheduleTimeout !== 'function' || typeof cancelTimeout !== 'function') {
        throw new TypeError('timeout hooks must be functions')
    }
    if (!Number.isFinite(timeoutMilliseconds) || timeoutMilliseconds <= 0) {
        throw new TypeError('timeoutMilliseconds must be positive and finite')
    }
    if (!Number.isSafeInteger(maximumRequestIDAttempts) || maximumRequestIDAttempts <= 0) {
        throw new TypeError('maximumRequestIDAttempts must be a positive safe integer')
    }

    const pendingByRequestID = new Map()

    const ownerIsCurrent = owner => {
        try {
            return isOwnerCurrent(owner) === true
        } catch {
            return false
        }
    }

    const finish = (requestID, outcome) => {
        const pending = pendingByRequestID.get(requestID)
        if (!pending) return false
        pendingByRequestID.delete(requestID)
        if (pending.timeoutHandle != null) {
            try {
                cancelTimeout(pending.timeoutHandle)
            } catch {
                // The request is already retired; timer cleanup cannot restore ownership.
            }
        }
        pending.resolve({
            requestID,
            context: pending.context,
            ...outcome,
        })
        return true
    }

    const nextRequestID = () => {
        for (let attempt = 0; attempt < maximumRequestIDAttempts; attempt += 1) {
            const requestID = makeRequestID()
            if (boundedRequestString(requestID, maximumRequestIDLength)
                && !pendingByRequestID.has(requestID)) {
                return requestID
            }
        }
        return null
    }

    const request = ({
        sectionID,
        message,
        owner = null,
        context = null,
    }) => {
        if (!boundedRequestString(sectionID, maximumSectionIDLength)) {
            return Promise.resolve({
                requestID: null,
                context,
                success: false,
                stale: false,
                errorCode: 'invalidSectionID',
            })
        }
        if (!message || typeof message !== 'object' || Array.isArray(message)) {
            return Promise.resolve({
                requestID: null,
                context,
                success: false,
                stale: false,
                errorCode: 'invalidMessage',
            })
        }

        const requestID = nextRequestID()
        if (!requestID) {
            return Promise.resolve({
                requestID: null,
                context,
                success: false,
                stale: false,
                errorCode: 'requestIDUnavailable',
            })
        }

        return new Promise(resolve => {
            const pending = {
                sectionID,
                owner,
                context,
                resolve,
                timeoutHandle: null,
            }
            pendingByRequestID.set(requestID, pending)

            try {
                const timeoutHandle = scheduleTimeout(() => {
                    finish(requestID, {
                        success: false,
                        stale: !ownerIsCurrent(owner),
                        errorCode: 'nativeCommitTimeout',
                    })
                }, timeoutMilliseconds)
                if (pendingByRequestID.get(requestID) === pending) {
                    pending.timeoutHandle = timeoutHandle
                }
            } catch {
                finish(requestID, {
                    success: false,
                    stale: !ownerIsCurrent(owner),
                    errorCode: 'nativeTimeoutUnavailable',
                })
                return
            }

            if (!pendingByRequestID.has(requestID)) return
            try {
                postMessage({
                    ...message,
                    requestID,
                    sectionId: sectionID,
                })
            } catch (error) {
                finish(requestID, {
                    success: false,
                    stale: !ownerIsCurrent(owner),
                    errorCode: String(error?.message || error || 'nativePostFailed'),
                })
            }
        })
    }

    const settle = result => {
        const requestID = boundedRequestString(result?.requestID, maximumRequestIDLength)
            ? result.requestID
            : null
        if (!requestID) return false
        const pending = pendingByRequestID.get(requestID)
        if (!pending) return false

        const sectionMatches = result?.sectionId === pending.sectionID
        const current = ownerIsCurrent(pending.owner)
        const success = result?.success === true && sectionMatches && current

        return finish(requestID, {
            success,
            stale: !current,
            errorCode: success
                ? null
                : (!sectionMatches
                    ? 'sectionMismatch'
                    : (!current
                        ? 'staleReaderLifecycle'
                        : (result?.errorCode || 'nativeCommitFailed'))),
            nativeResult: result,
        })
    }

    const cancelAll = (errorCode = 'readerClosed') => {
        for (const requestID of [...pendingByRequestID.keys()]) {
            finish(requestID, {
                success: false,
                stale: true,
                errorCode,
            })
        }
    }

    return {
        request,
        settle,
        cancelAll,
        get pendingCount() {
            return pendingByRequestID.size
        },
    }
}
