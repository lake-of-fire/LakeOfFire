// A logical book action has one immutable intent. Transport retries are read-only
// status queries or navigation-only recovery, never another epoch mutation.
const actions = new Set(['finishBook', 'startChapterOver', 'startBookOver'])
const copy = value => JSON.parse(JSON.stringify(value))
const uuid = () => globalThis.crypto.randomUUID().toLowerCase()

export class BookActionUnacknowledgedError extends Error {
    constructor(message, request) {
        super(message)
        this.name = 'BookActionUnacknowledgedError'
        this.outcomeUnknown = true
        this.requestID = request?.requestID ?? null
        this.action = request?.action ?? null
    }
}

export const createBookActionBridge = ({
    postMessage, documentStartedAtMs, topWindowURL,
    captureContext, makeRequestID = uuid,
    timeoutMilliseconds = 15_000,
    setTimer = globalThis.setTimeout, clearTimer = globalThis.clearTimeout,
}) => {
    let closed = false
    let current = null
    const deliveries = new Map()
    const recoveryInfo = () => current ? {
        requestID: current.requestID, action: current.action,
        kind: current.result?.navigation?.status === 'failed' ? 'navigate' : 'status',
    } : null
    const settle = (delivery, result, error) => {
        if (delivery.settled) return
        delivery.settled = true
        clearTimer(delivery.timer)
        if (error) delivery.reject(error)
        else delivery.resolve(result)
    }
    const deliver = (request, kind) => {
        if (closed) return Promise.reject(new Error('Reader closed'))
        // Do not issue overlapping deliveries for the same logical operation.
        if (request.active && !request.active.settled) return request.active.promise
        if (kind === 'status' && request.result) return Promise.resolve(copy(request.result))
        // Retain the original command for a late acknowledgement, but do not
        // accumulate an unbounded list of expired status checks.
        for (const [id, previous] of deliveries) {
            if (previous.request === request && previous.settled && previous.kind !== 'command') deliveries.delete(id)
        }
        const deliveryID = `${request.requestID}:${++request.sequence}`
        let resolve, reject
        const promise = new Promise((r, j) => { resolve = r; reject = j })
        const delivery = { request, kind, deliveryID, promise, resolve, reject, settled: false, timer: null }
        request.active = delivery
        deliveries.set(deliveryID, delivery)
        delivery.timer = setTimer(() => {
            settle(delivery, null, new BookActionUnacknowledgedError(
                'The action has not been acknowledged. Check its status before starting another reading pass.', request))
        }, timeoutMilliseconds)
        try {
            postMessage({
                protocolVersion: 2, kind, action: request.action,
                requestID: request.requestID, deliveryID,
                context: copy(request.context), topWindowURL, documentStartedAtMs,
            })
        } catch (error) {
            // A transport exception is not proof that the native write failed.
            settle(delivery, null, new BookActionUnacknowledgedError(
                error?.message || 'The book action could not be acknowledged.', request))
        }
        return promise
    }
    return {
        get recoveryInfo() { return recoveryInfo() },
        perform(action, expectedContext = null) {
            if (closed) return Promise.reject(new Error('Reader closed'))
            if (!actions.has(action)) return Promise.reject(new Error('Unsupported book action'))
            if (current) return Promise.reject(new BookActionUnacknowledgedError(
                'Resolve the previous book action before starting another reading pass.', current))
            let context
            try {
                context = captureContext?.(expectedContext)
                if (!context) throw new Error('Book actions are not ready. Wait for the current chapter to load.')
            } catch (error) { return Promise.reject(error) }
            const requestID = makeRequestID()
            if (!/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(requestID)) {
                return Promise.reject(new Error('Could not create a book action identifier'))
            }
            current = { requestID, action, context: copy(context), sequence: 0, active: null, result: null }
            return deliver(current, 'command')
        },
        recover({ requestID, action, kind = 'status' } = recoveryInfo() ?? {}) {
            if (closed) return Promise.reject(new Error('Reader closed'))
            if (!current || current.requestID !== requestID || current.action !== action) {
                return Promise.reject(new BookActionUnacknowledgedError(
                    'The original action is unavailable. Reopen the book to see its current reading pass.', current))
            }
            if (kind !== 'status' && kind !== 'navigate') return Promise.reject(new Error('Unsupported recovery'))
            if (kind === 'navigate' && current.result?.navigation?.status !== 'failed') {
                return Promise.reject(new Error('Navigation recovery requires a committed reading pass'))
            }
            return deliver(current, kind)
        },
        acknowledge(deliveryID, result) {
            const delivery = deliveries.get(deliveryID)
            if (closed || !delivery || delivery.request !== current || !result
                || result.requestID !== current.requestID) return false
            if (result.ok === true && result.committed !== true) return false
            if (result.pending !== true && result.outcomeUnknown !== true && typeof result.ok !== 'boolean') return false
            deliveries.delete(deliveryID)
            const request = current
            const payload = { ...copy(result), action: request.action }
            const terminal = payload.pending !== true && payload.outcomeUnknown !== true
            if (terminal) {
                // Any definitive result settles later status deliveries too.
                request.result = payload
                for (const [id, other] of deliveries) {
                    if (other.request !== request) continue
                    settle(other, copy(payload))
                    deliveries.delete(id)
                }
                if (payload.ok !== true || payload.navigation?.status !== 'failed') current = null
            }
            settle(delivery, payload)
            return true
        },
        close() {
            if (closed) return
            closed = true
            for (const delivery of deliveries.values()) {
                settle(delivery, null, new BookActionUnacknowledgedError('Reader closed', delivery.request))
            }
            deliveries.clear()
            current = null
        },
    }
}
