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
    maximumDeliveryAttempts = 2,
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
    if (!Number.isSafeInteger(maximumDeliveryAttempts) || maximumDeliveryAttempts <= 0) {
        throw new TypeError('maximumDeliveryAttempts must be a positive safe integer')
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

    const postPendingRequest = (requestID, pending) => {
        pending.deliveryAttempts += 1
        try {
            postMessage({
                ...pending.message,
                requestID,
                sectionId: pending.sectionID,
            })
            return true
        } catch (error) {
            finish(requestID, {
                success: false,
                stale: !ownerIsCurrent(pending.owner),
                errorCode: String(error?.message || error || 'nativePostFailed'),
            })
            return false
        }
    }

    const schedulePendingTimeout = (requestID, pending) => {
        try {
            const timeoutHandle = scheduleTimeout(() => {
                if (pendingByRequestID.get(requestID) !== pending) return
                pending.timeoutHandle = null
                if (ownerIsCurrent(pending.owner)
                    && pending.deliveryAttempts < maximumDeliveryAttempts) {
                    if (schedulePendingTimeout(requestID, pending)) {
                        postPendingRequest(requestID, pending)
                    }
                    return
                }
                finish(requestID, {
                    success: false,
                    stale: !ownerIsCurrent(pending.owner),
                    errorCode: 'nativeCommitTimeout',
                })
            }, timeoutMilliseconds)
            if (pendingByRequestID.get(requestID) === pending) {
                pending.timeoutHandle = timeoutHandle
                return true
            }
            try {
                cancelTimeout(timeoutHandle)
            } catch {
                // The request already settled while the timer was installed.
            }
            return false
        } catch {
            finish(requestID, {
                success: false,
                stale: !ownerIsCurrent(pending.owner),
                errorCode: 'nativeTimeoutUnavailable',
            })
            return false
        }
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
        let capturedMessage
        try {
            capturedMessage = JSON.parse(JSON.stringify(message))
        } catch {
            return Promise.resolve({
                requestID: null,
                context,
                success: false,
                stale: false,
                errorCode: 'invalidMessage',
            })
        }
        if (!capturedMessage || typeof capturedMessage !== 'object'
            || Array.isArray(capturedMessage)) {
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
                message: capturedMessage,
                resolve,
                timeoutHandle: null,
                deliveryAttempts: 0,
            }
            pendingByRequestID.set(requestID, pending)

            if (schedulePendingTimeout(requestID, pending)) {
                postPendingRequest(requestID, pending)
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
