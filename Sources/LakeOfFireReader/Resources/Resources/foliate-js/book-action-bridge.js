// Transport attempts are distinct from the one immutable semantic operation.
// Recovery NEVER issues another epoch mutation.
import {
    captureReaderArticleProducerOwner,
    carryReaderArticleProducerOwner,
} from './reader-producer-evidence.js'

import { compareBookAccountPresentation } from './book-reading-state.js'

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
    captureProducerOwner = captureReaderArticleProducerOwner,
    carryProducerOwner = carryReaderArticleProducerOwner,
}) => {
    let closed = false, preparing = false, current = null, accountPresentation = null
    const deliveries = new Map(), completed = new Map()
    const clearDeliveryTimer = timer => {
        if (timer != null) {
            try { clearTimer(timer) } catch (_) {} // Optional cleanup cannot change outcome truth.
        }
    }
    const settle = (delivery, result, error) => {
        if (delivery.settled) return
        delivery.settled = true
        const timer = delivery.timer
        delivery.timer = null
        clearDeliveryTimer(timer)
        if (error) delivery.reject(error)
        else delivery.resolve(result)
    }
    const ownsRequest = request => !closed && request.accountPresentation === accountPresentation
        && (current === request || completed.get(request.requestID) === request)
    const unknown = (request, error = null) => {
        let message = 'The action was not acknowledged. Check its status before trying again.'
        try { if (typeof error?.message === 'string' && error.message) message = error.message } catch (_) {}
        return new BookActionUnacknowledgedError(message, request)
    }
    const requestProducerReadiness = () => {
        try { globalThis.manabiArticleProducer?.ready?.().catch?.(() => {}) } catch (_) {}
    }
    const deliver = (request, kind) => {
        if (closed) return Promise.reject(new Error('Reader closed'))
        if (!ownsRequest(request)) return Promise.reject(unknown(request))
        if (request.active && !request.active.settled) return request.active.promise
        if (kind === 'status' && request.result) return Promise.resolve(copy(request.result))
        const previousDelivery = request.active, previousResult = request.result
        let producerOwner
        try {
            // Recovery is a new non-mutating delivery; commands keep the
            // original producer captured with their immutable Book context.
            producerOwner = kind === 'command' ? request.producerOwner : captureProducerOwner?.()
        } catch (error) { return Promise.reject(unknown(request, error)) }
        if (!ownsRequest(request)) return Promise.reject(unknown(request))
        // Producer capture can synchronously start or complete another delivery.
        // Join its promise rather than replacing it or navigating stale state.
        if (request.active !== previousDelivery || request.result !== previousResult) {
            if (request.active && !request.active.settled) return request.active.promise
            if (kind === 'status' && request.result) return Promise.resolve(copy(request.result))
            return Promise.reject(unknown(request))
        }
        if (!producerOwner) {
            requestProducerReadiness()
            return Promise.reject(unknown(request))
        }
        // Once navigation recovery starts, status must query native rather
        // than replay the cached failure from before that navigation attempt.
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
        const mayPost = () => ownsRequest(request) && !delivery.settled
            && request.active === delivery && deliveries.get(deliveryID) === delivery
        try {
            const timer = setTimer(() => settle(delivery, null, new BookActionUnacknowledgedError(
                'The action has not been acknowledged. Check its status before starting another reading pass.', request)), timeoutMilliseconds)
            // Installation can synchronously acknowledge, time out or retire
            // the delivery. Its late returned handle must not become an orphan.
            if (!mayPost()) { clearDeliveryTimer(timer); return promise }
            delivery.timer = timer
            const payload = carryProducerOwner({
                protocolVersion: 2, kind, action: request.action,
                requestID: request.requestID, deliveryID,
                context: copy(request.context), topWindowURL, documentStartedAtMs,
            }, producerOwner)
            if (!mayPost()) return promise
            if (!payload) throw new Error('Native producer ownership is unavailable.')
            postMessage(payload)
        } catch (error) {
            // Preserve a terminal reply received synchronously before a wrapper
            // throws. Otherwise retain the original status-only recovery path.
            settle(delivery, null, unknown(request, error))
        }
        return promise
    }
    return {
        setAccountPresentation(stamp) {
            if (closed || compareBookAccountPresentation(stamp, accountPresentation) !== 1) return false
            accountPresentation = stamp
            // Withdraw old presentation, never report an unobserved write as
            // failed or replay it under the successor account's producer.
            const old = Array.from(deliveries.values())
            deliveries.clear(); completed.clear(); current = null
            for (const delivery of old) {
                const error = new BookActionUnacknowledgedError(
                    'The account changed. The previous account action is no longer displayed.', delivery.request)
                error.presentationSuperseded = true
                settle(delivery, null, error)
            }
            return true
        },
        get recoveryInfo() { return current ? { requestID: current.requestID, action: current.action,
            kind: current.result?.navigation?.status === 'failed' ? 'navigate' : 'status' } : null },
        perform(action, expectedContext = null) {
            if (closed) return Promise.reject(new Error('Reader closed'))
            if (!actions.has(action)) return Promise.reject(new Error('Unsupported book action'))
            if (current) return Promise.reject(new BookActionUnacknowledgedError('Resolve the previous book action first.', current))
            // Preparation is synchronous, but injected capture/serialization
            // callbacks can reenter. Reserve this preparation without inventing
            // an unacknowledged native command for a rejected nested activation.
            if (preparing) return Promise.reject(new Error('Another book action is being prepared.'))
            const account = accountPresentation
            const preparationIsCurrent = () => !closed && accountPresentation === account && current === null
            let request
            preparing = true
            try {
                const context = captureContext?.(expectedContext)
                if (!context || !preparationIsCurrent()) throw new Error('The current chapter changed. Reopen Book Actions.')
                const producerOwner = captureProducerOwner?.()
                if (!preparationIsCurrent()) throw new Error('The reader changed before the action was prepared.')
                if (!producerOwner) {
                    requestProducerReadiness()
                    throw new Error('The reader is still obtaining native ownership.')
                }
                const requestID = makeRequestID()
                if (!preparationIsCurrent() || typeof requestID !== 'string'
                    || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(requestID)) {
                    throw new Error('Invalid or superseded action identifier')
                }
                const preparedContext = copy(context)
                if (!preparedContext || typeof preparedContext !== 'object' || Array.isArray(preparedContext)) {
                    throw new Error('The current chapter has no valid Book Actions context.')
                }
                if (!preparationIsCurrent()) throw new Error('The reader changed before the action was prepared.')
                request = { requestID, action, context: preparedContext, producerOwner, accountPresentation: account,
                    sequence: 0, active: null, result: null }
            } catch (error) { return Promise.reject(error) }
            finally { preparing = false }
            current = request
            return deliver(request, 'command')
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
            if (!delivery || !result) return false
            const request = delivery.request
            const mayAccept = () => ownsRequest(request) && deliveries.get(deliveryID) === delivery
            if (!mayAccept()) return false
            let payload, terminal, settlements
            try {
                // Copy and validate before consuming the reply. A failed copy
                // remains retryable; serializers cannot change its correlation
                // or command truth after validation of the original object.
                payload = copy(result)
                if (!payload || typeof payload !== 'object' || Array.isArray(payload)
                    || payload.requestID !== request.requestID
                    || (payload.accountPresentation ?? null) !== request.accountPresentation
                    || (payload.ok === true && payload.committed !== true)
                    || (payload.pending !== true && payload.outcomeUnknown !== true
                        && typeof payload.ok !== 'boolean')) return false
                payload.action = request.action
                if (payload.ok === true && request.action !== 'finishBook'
                    && !['completed', 'failed', 'superseded'].includes(payload.navigation?.status)) {
                    payload.pending = true
                }
                terminal = payload.pending !== true && payload.outcomeUnknown !== true
                const recipients = terminal
                    ? [...deliveries.values()].filter(other => other.request === request) : [delivery]
                // The retained cache and each delivery own separate data. A
                // consumer mutating its result cannot rewrite future recovery.
                settlements = recipients.map(other => ({ delivery: other, result: copy(payload) }))
                if (!mayAccept() || settlements.some(item =>
                    deliveries.get(item.delivery.deliveryID) !== item.delivery)) return false
            } catch (_) { return false }
            // Commit all private result/index changes before optional timer
            // cleanup can close, switch account or admit the next command.
            request.result = terminal ? payload : null
            for (const item of settlements) deliveries.delete(item.delivery.deliveryID)
            if (terminal) {
                completed.set(request.requestID, request)
                while (completed.size > 32) completed.delete(completed.keys().next().value)
                if (current === request && (payload.ok !== true || payload.navigation?.status !== 'failed')) current = null
            }
            for (const item of settlements) settle(item.delivery, item.result)
            return true
        },
        close() {
            if (closed) return
            closed = true
            const old = [...deliveries.values()]
            deliveries.clear(); completed.clear(); current = null
            for (const delivery of old) settle(delivery, null, new BookActionUnacknowledgedError('Reader closed', delivery.request))
        },
    }
}
