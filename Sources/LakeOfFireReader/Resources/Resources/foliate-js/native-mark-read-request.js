const defaultRequestID = () => {
    if (typeof globalThis.crypto?.randomUUID === 'function') {
        return globalThis.crypto.randomUUID()
    }
    return `mark-${Date.now()}-${Math.random().toString(36).slice(2)}`
}

/**
 * Owns the request/reply lifetime for a native Mark Read transaction.
 *
 * Visible read state is never published from `request()`. The caller may update
 * UI only after the returned promise resolves with `success === true`. Replies
 * are accepted exactly once and only while their captured reader/document owner
 * is still current.
 */
export const createNativeMarkReadRequestCoordinator = ({
    postMessage,
    isOwnerCurrent = () => true,
    makeRequestID = defaultRequestID,
    timeoutMilliseconds = 15_000,
    scheduleTimeout = globalThis.setTimeout,
    cancelTimeout = globalThis.clearTimeout,
} = {}) => {
    if (typeof postMessage !== 'function') {
        throw new TypeError('postMessage must be a function')
    }

    const pendingByRequestID = new Map()

    const finish = (requestID, outcome) => {
        const pending = pendingByRequestID.get(requestID)
        if (!pending) return false
        pendingByRequestID.delete(requestID)
        if (pending.timeoutHandle != null) {
            cancelTimeout?.(pending.timeoutHandle)
        }
        pending.resolve({
            requestID,
            context: pending.context,
            ...outcome,
        })
        return true
    }

    const request = ({
        sectionID,
        message,
        owner = null,
        context = null,
    }) => {
        if (typeof sectionID !== 'string' || sectionID.length === 0) {
            return Promise.resolve({
                requestID: null,
                context,
                success: false,
                stale: false,
                errorCode: 'invalidSectionID',
            })
        }
        if (!message || typeof message !== 'object') {
            return Promise.resolve({
                requestID: null,
                context,
                success: false,
                stale: false,
                errorCode: 'invalidMessage',
            })
        }

        let requestID = makeRequestID()
        while (
            typeof requestID !== 'string'
            || requestID.length === 0
            || pendingByRequestID.has(requestID)
        ) {
            requestID = makeRequestID()
        }

        return new Promise(resolve => {
            const timeoutHandle = scheduleTimeout?.(() => {
                finish(requestID, {
                    success: false,
                    stale: !isOwnerCurrent(owner),
                    errorCode: 'nativeCommitTimeout',
                })
            }, timeoutMilliseconds)

            pendingByRequestID.set(requestID, {
                sectionID,
                owner,
                context,
                resolve,
                timeoutHandle,
            })

            try {
                postMessage({
                    ...message,
                    requestID,
                    sectionId: sectionID,
                })
            } catch (error) {
                finish(requestID, {
                    success: false,
                    stale: !isOwnerCurrent(owner),
                    errorCode: String(error?.message || error || 'nativePostFailed'),
                })
            }
        })
    }

    const settle = result => {
        const requestID = typeof result?.requestID === 'string'
            ? result.requestID
            : ''
        if (!requestID) return false
        const pending = pendingByRequestID.get(requestID)
        if (!pending) return false

        const sectionMatches = !result?.sectionId
            || result.sectionId === pending.sectionID
        const ownerIsCurrent = isOwnerCurrent(pending.owner)
        const success = result?.success === true
            && sectionMatches
            && ownerIsCurrent

        return finish(requestID, {
            success,
            stale: !ownerIsCurrent,
            errorCode: success
                ? null
                : (!sectionMatches
                    ? 'sectionMismatch'
                    : (!ownerIsCurrent
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
