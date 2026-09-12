const defaultRequestID = () => {
    if (typeof globalThis.crypto?.randomUUID === 'function') {
        return globalThis.crypto.randomUUID()
    }
    return `mark-${Date.now()}-${Math.random().toString(36).slice(2)}`
}

/**
 * Owns the request/reply lifetime for a native Mark Read transaction.
 *
 * Visible read state is never published from `request()`. Success reports the
 * known native commit, not permission to repaint or move the reader. The actual
 * viewer checks owner liveness, native permissions and cancellation again at
 * repaint and after its delayed page-turn wait. Replies settle exactly once.
 */
export const createNativeMarkReadRequestCoordinator = ({
    postMessage,
    isOwnerCurrent = () => true,
    makeRequestID = defaultRequestID,
    // Native classification expires at 12 seconds, leaving three seconds for
    // final validation, synchronous commit, and bridge delivery before this
    // request/reply owner fails closed at the UI's 15-second deadline.
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
        onRequestID = null,
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
                // Publish the original presentation identity before native code
                // can reply or cancel, including while request() is still running.
                onRequestID?.(requestID)
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
        // Persistence success is not presentation permission. The real viewer
        // separately checks stale owner, native permissions and cancellation.
        const success = result?.success === true && sectionMatches

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
