// Transport attempts are distinct from the one immutable semantic operation.
// Recovery NEVER issues another epoch mutation.
const actions = new Set(['finishBook', 'startChapterOver', 'startBookOver'])
const copy = value => JSON.parse(JSON.stringify(value))
export class BookActionUnacknowledgedError extends Error {
    constructor(message, request) {
        super(message)
        this.name = 'BookActionUnacknowledgedError'
        this.outcomeUnknown = true
        this.requestID = request?.requestID ?? null
        this.action = request?.action ?? null
    }
}
export const createBookActionBridge = ({ postMessage, documentStartedAtMs, topWindowURL,
    captureContext, makeRequestID = () => globalThis.crypto.randomUUID().toLowerCase(),
    timeoutMilliseconds = 15_000, setTimer = globalThis.setTimeout, clearTimer = globalThis.clearTimeout,
}) => {
    let closed = false, current = null
    const deliveries = new Map(), completed = new Map()
    const settle = (delivery, result, error) => {
        if (delivery.settled) return
        delivery.settled = true
        clearTimer(delivery.timer)
        if (error) delivery.reject(error)
        else delivery.resolve(result)
    }
    const deliver = (request, kind) => {
        if (closed) return Promise.reject(new Error('Reader closed'))
        if (request.active && !request.active.settled) return request.active.promise
        if (kind === 'status' && request.result) return Promise.resolve(copy(request.result))
        // Once navigation recovery starts, its previous failure is no longer
        // the current result. A timeout must query native status, not replay
        // that cached failure and offer another navigation attempt.
        if (kind === 'navigate') request.result = null
        for (const [id, previous] of deliveries) {
            if (previous.request === request && previous.settled && previous.kind !== 'command') deliveries.delete(id)
        }
        const deliveryID = `${request.requestID}:${++request.sequence}`
        let resolve, reject
        const promise = new Promise((r, j) => { resolve = r; reject = j })
        const delivery = { request, kind, deliveryID, promise, resolve, reject, settled: false, timer: null }
        request.active = delivery
        deliveries.set(deliveryID, delivery)
        delivery.timer = setTimer(() => settle(delivery, null, new BookActionUnacknowledgedError(
            'The action has not been acknowledged. Check its status before starting another reading pass.', request)), timeoutMilliseconds)
        try {
            postMessage({ protocolVersion: 2, kind, action: request.action, requestID: request.requestID,
                deliveryID, context: copy(request.context), topWindowURL, documentStartedAtMs })
        } catch (error) {
            settle(delivery, null, new BookActionUnacknowledgedError(error?.message || 'The action was not acknowledged.', request))
        }
        return promise
    }
    return {
        get recoveryInfo() { return current ? { requestID: current.requestID, action: current.action,
            kind: current.result?.navigation?.status === 'failed' ? 'navigate' : 'status' } : null },
        perform(action, expectedContext = null) {
            if (closed) return Promise.reject(new Error('Reader closed'))
            if (!actions.has(action)) return Promise.reject(new BookActionUnacknowledgedError('Unsupported book action', current))
            if (current) return Promise.reject(new BookActionUnacknowledgedError('Resolve the previous book action first.', current))
            let context
            try {
                context = captureContext?.(expectedContext)
                if (!context) throw new Error('The current chapter is still loading its book actions.')
            } catch (error) { return Promise.reject(error) }
            const requestID = makeRequestID()
            if (!/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(requestID)) return Promise.reject(new Error('Invalid action identifier'))
            current = { requestID, action, context: copy(context), sequence: 0, active: null, result: null }
            return deliver(current, 'command')
        },
        recover(recovery) {
            if (closed) return Promise.reject(new Error('Reader closed'))
            const { requestID, action, kind = 'status' } = recovery ?? this.recoveryInfo ?? {}
            const request = current?.requestID === requestID ? current : completed.get(requestID)
            if (!request || request.action !== action) return Promise.reject(new BookActionUnacknowledgedError(
                'The original action is unavailable. Reopen the book to see its current reading pass.', current))
            if (!['status', 'navigate'].includes(kind)) return Promise.reject(new Error('Unsupported recovery'))
            if (request.active && !request.active.settled) return request.active.promise
            if (kind === 'navigate' && request.result?.navigation?.status !== 'failed') return Promise.reject(new Error('Navigation is not pending'))
            return deliver(request, kind)
        },
        acknowledge(deliveryID, result) {
            const delivery = deliveries.get(deliveryID)
            if (closed || !delivery || !result || result.requestID !== delivery.request.requestID) return false
            if (result.ok === true && result.committed !== true) return false
            if (result.pending !== true && result.outcomeUnknown !== true && typeof result.ok !== 'boolean') return false
            deliveries.delete(deliveryID)
            const request = delivery.request
            const payload = { ...copy(result), action: request.action }
            // A reset has two outcomes: the mutation and its navigation. A
            // committed but unfinished navigation is never terminal success.
            if (payload.ok === true && request.action !== 'finishBook'
                && !['completed', 'failed', 'superseded'].includes(payload.navigation?.status)) {
                payload.pending = true
            }
            if (payload.pending === true || payload.outcomeUnknown === true) request.result = null
            if (payload.pending !== true && payload.outcomeUnknown !== true) {
                request.result = payload
                for (const [id, other] of deliveries) {
                    if (other.request === request) { settle(other, copy(payload)); deliveries.delete(id) }
                }
                completed.set(request.requestID, request)
                while (completed.size > 32) completed.delete(completed.keys().next().value)
                if (current === request && (payload.ok !== true || payload.navigation?.status !== 'failed')) current = null
            }
            settle(delivery, payload)
            return true
        },
        close() {
            if (closed) return
            closed = true
            for (const delivery of deliveries.values()) settle(delivery, null, new BookActionUnacknowledgedError('Reader closed', delivery.request))
            deliveries.clear(); completed.clear(); current = null
        },
    }
}
