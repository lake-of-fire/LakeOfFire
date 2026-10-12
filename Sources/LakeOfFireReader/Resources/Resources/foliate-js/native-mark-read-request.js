import { carryReaderArticleProducerOwner } from './reader-producer-evidence.js'
import { bookScopeKey } from './book-reading-state.js'

/** Refresh displayed state, without treating an expired authoring receipt as
 * read-only authority. A prior recovery can revoke sibling receipts while
 * those commands are still joining under the same displayed chapter. */
export const refreshNativeMarkReadBookStateForRecovery = (runtime, originalScope, isCurrent = () => true) => {
    if (!runtime || !isCurrent()) return false
    const state = runtime.state
    const context = state.context
    const location = state.location
    if (context && bookScopeKey(context.scope) !== bookScopeKey(originalScope)) return false
    if (!location || state !== runtime.state || !isCurrent()) return false
    return state.relocate(location, { replaced: true })
}

const defaultRequestID = () => {
    if (typeof globalThis.crypto?.randomUUID === 'function') {
        return globalThis.crypto.randomUUID()
    }
    return `mark-${Date.now()}-${Math.random().toString(36).slice(2)}`
}

/**
 * Projects renderer-owned semantic facts onto the lightweight native command
 * boundary. Native reconstructs and validates those facts from its current
 * sidecar; the WebView sends only durable subject identifiers.
 */
export const nativeMarkReadCommandMessage = (payload, documentIdentity = {}) => {
    const { producerOwner = null, ...identity } = documentIdentity ?? {}
    const message = {
        stableIdentityVersion: payload?.stableIdentityVersion,
        nativeSidecarContentFingerprint:
            payload?.nativeSidecarContentFingerprint ?? null,
        stableSegmentIDs: Array.isArray(payload?.segments)
            ? payload.segments.map(segment => segment?.stableSegmentID)
            : [],
        sentenceIdentifiers: Array.isArray(payload?.sentenceIdentifiers)
            ? payload.sentenceIdentifiers
            : [],
        ...(payload?.desiredState != null
            ? { desiredState: payload.desiredState }
            : {}),
        ...(payload?.expectedManualSupportRevision != null
            ? { expectedManualSupportRevision: payload.expectedManualSupportRevision }
            : {}),
        ...identity,
        // Native pending admission and every later observation must name the
        // same document as the original producer ticket. Do not sample a new
        // renderer timestamp after capturing that ticket.
        ...(producerOwner && producerOwner.required !== false
            ? { documentStartedAtMs: producerOwner.documentStartedAtMs }
            : {}),
    }
    return producerOwner
        ? carryReaderArticleProducerOwner(message, producerOwner)
        : message
}

/** Own the intent until native reports its outcome; timers observe, never replay. */
export const createNativeMarkReadRequestCoordinator = ({
    postMessage,
    postControlMessage,
    isOwnerCurrent = () => true,
    makeRequestID = defaultRequestID,
    timeoutMilliseconds = 15_000,
    scheduleTimeout = globalThis.setTimeout,
    cancelTimeout = globalThis.clearTimeout,
    onPending = () => {},
    onRecovery = () => {},
    lifecycleTarget = globalThis,
} = {}) => {
    if (typeof postMessage !== 'function') throw new TypeError('postMessage must be a function')
    if (typeof postControlMessage !== 'function') throw new TypeError('postControlMessage must be a function')
    const pendingByRequestID = new Map()
    // A document-local namespace and increasing sequence keep request IDs
    // distinct without retaining every completed request for its lifetime.
    let requestNamespace
    for (let attempts = 0; attempts < 32; attempts += 1) {
        const candidate = makeRequestID()
        if (typeof candidate === 'string' && candidate
            && new TextEncoder().encode(candidate).length <= 480) {
            requestNamespace = candidate
            break
        }
    }
    if (!requestNamespace) throw new Error('Could not allocate a native request namespace')
    let requestSequence = 0
    let observing = true
    let listening = false
    const attachLifecycle = () => {
        if (listening || typeof lifecycleTarget?.addEventListener !== 'function') return
        listening = true
        lifecycleTarget.addEventListener('pagehide', pause)
        lifecycleTarget.addEventListener('pageshow', resume)
    }
    const detachLifecycle = () => {
        if (!listening || !observing || pendingByRequestID.size !== 0) return
        listening = false
        lifecycleTarget.removeEventListener?.('pagehide', pause)
        lifecycleTarget.removeEventListener?.('pageshow', resume)
    }
    const present = (pending, callback) => {
        try { return callback() }
        catch (error) {
            try { pending.lastPresentationError = String(error) }
            catch (_) { pending.lastPresentationError = 'Unprintable error' }
        }
    }
    const ownerCurrent = pending => present(pending, () => isOwnerCurrent(pending.owner)) === true
    const intentKey = message => {
        const { requestID, manualReadPendingProtocol,
            manualReadPendingObservationToken, ...intent } = message
        const canonical = value => Array.isArray(value) ? value.map(canonical)
            : value && typeof value === 'object'
                ? Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]))
                : value
        return JSON.stringify(canonical(JSON.parse(JSON.stringify(intent))))
    }
    const notify = pending => present(pending, () => onPending({
        requestID: pending.requestID, context: pending.context,
        phase: pending.cancelling ? 'cancelling' : 'pending',
        recoveryOnly: pending.recoveryOnly === true,
        cancel: () => cancel(pending.requestID),
    }))
    const postControl = pending => {
        if (!observing || pendingByRequestID.get(pending.requestID) !== pending) return
        try {
            postControlMessage({
                requestID: pending.requestID,
                manualReadPendingProtocol: 1,
                manualReadPendingObservationToken: pending.message.manualReadPendingObservationToken,
                manualReadPendingOperation: !pending.recoveryOnly && pending.cancelling ? 'cancel' : 'status',
                ...(pending.recoveryOnly ? { manualReadPendingHistoryRecovery: true } : {}),
                manualReadPendingKind: 'section',
                topWindowURL: pending.message.topWindowURL,
                documentStartedAtMs: pending.message.documentStartedAtMs,
            })
        } catch (error) { pending.lastTransportError = String(error) }
    }
    const observe = (pending, delay = 5000) => {
        if (pending.timeoutHandle != null) cancelTimeout?.(pending.timeoutHandle)
        if (!observing || pendingByRequestID.get(pending.requestID) !== pending) return
        pending.timeoutHandle = scheduleTimeout?.(() => {
            // A retained callback may fire after a terminal native result.
            // It must not resurrect polling, cancellation UI or transport.
            if (!observing || pendingByRequestID.get(pending.requestID) !== pending) return
            pending.timeoutHandle = null
            pending.slow = true
            notify(pending)
            postControl(pending)
            observe(pending)
        }, delay)
    }
    const finish = (pending, outcome) => {
        if (pendingByRequestID.get(pending.requestID) !== pending) return false
        pendingByRequestID.delete(pending.requestID)
        const timer = pending.timeoutHandle
        pending.timeoutHandle = null
        try {
            present(pending, detachLifecycle)
            if (timer != null) present(pending, () => cancelTimeout?.(timer))
            // Join before recovery callbacks. They can invalidate the current
            // chapter and issue its existing read-only state query, never replay
            // this mutation or consume a successor request's outcome.
            if (pending.recoveryOnly || pending.recoveryRequested) {
                outcome.presentationAllowed = false
                const deferToOrdinaryRequests = () => {
                    const ordinary = [...pendingByRequestID.values()].filter(value => !value.recoveryOnly)
                    for (const value of ordinary) value.recoveryRequested = true
                    return ordinary.length > 0
                }
                if (!deferToOrdinaryRequests()) {
                    present(pending, () => onRecovery({
                        requestID: pending.requestID, owner: pending.owner,
                        context: pending.context, ...outcome,
                        isCurrent: () => ![...pendingByRequestID.values()].some(value => !value.recoveryOnly),
                    }))
                    // A callback can admit a new ordinary owner. Carry the
                    // unfinished refresh on that existing request, never cancel it.
                    deferToOrdinaryRequests()
                }
            }
            present(pending, () => onPending({ requestID: pending.requestID,
                phase: 'finished', context: pending.context }))
        } finally {
            pending.resolve({ requestID: pending.requestID, context: pending.context, ...outcome })
        }
        return true
    }
    const cancel = requestID => {
        const pending = pendingByRequestID.get(requestID)
        if (!pending || !observing || pending.recoveryOnly) return false
        pending.cancelling = true
        notify(pending)
        postControl(pending)
        observe(pending)
        return true
    }
    const request = ({ sectionID, message, owner = null, context = null }) => {
        if (typeof sectionID !== 'string' || !sectionID || !message || typeof message !== 'object') {
            return Promise.resolve({ requestID: null, context, success: false,
                stale: false, errorCode: 'invalidMessage', presentationAllowed: false })
        }
        let fingerprint
        try { fingerprint = intentKey({ ...message, sectionId: sectionID }) }
        catch {
            return Promise.resolve({ requestID: null, context, success: false,
                stale: false, errorCode: 'invalidMessage', presentationAllowed: false })
        }
        for (const pending of pendingByRequestID.values()) {
            if (pending.sectionID !== sectionID) continue
            if (ownerCurrent(pending) && ownerCurrent({ owner }) && fingerprint === pending.fingerprint) {
                return pending.completion
            }
            // Do not silently absorb Unmark, a new book pass, or new subjects
            // into an older Mark promise. Cancellation must finish first.
            return Promise.resolve({ requestID: null, context, success: false,
                stale: false, errorCode: 'pendingTargetBusy', presentationAllowed: false })
        }
        if (!observing || pendingByRequestID.size >= 32) {
            return Promise.resolve({ requestID: null, context, success: false,
                stale: false, errorCode: 'pendingCapacityExceeded', presentationAllowed: false })
        }
        if (!Number.isSafeInteger(requestSequence + 1)) {
            throw new Error('Could not allocate a unique native request identity')
        }
        const requestID = `${requestNamespace}-${++requestSequence}`
        const bytes = new Uint8Array(16)
        globalThis.crypto.getRandomValues(bytes)
        const frozenMessage = JSON.parse(JSON.stringify({
            ...message, requestID, sectionId: sectionID,
            manualReadPendingProtocol: 1,
            manualReadPendingObservationToken: Array.from(bytes,
                byte => byte.toString(16).padStart(2, '0')).join(''),
        }))
        const freeze = value => {
            if (value && typeof value === 'object') {
                Object.values(value).forEach(freeze)
                Object.freeze(value)
            }
        }
        freeze(frozenMessage)
        let resolve
        const completion = new Promise(done => { resolve = done })
        const pending = { requestID, sectionID, message: frozenMessage, fingerprint,
            owner, context, resolve, completion, timeoutHandle: null,
            cancelling: false, slow: false, recoveryOnly: false }
        pendingByRequestID.set(requestID, pending)
        attachLifecycle()
        observe(pending, timeoutMilliseconds)
        try {
            postMessage(frozenMessage)
        } catch (error) {
            // A synchronous bridge throw proves the initial mutation was never
            // handed to native, so this outcome is not ambiguous/pending.
            finish(pending, {
                success: false,
                stale: !ownerCurrent(pending),
                presentationAllowed: false,
                errorCode: String(error?.message || error || 'nativePostFailed'),
            })
        }
        return completion
    }
    const settle = result => {
        const pending = pendingByRequestID.get(result?.requestID)
        if (!pending) return false
        if (result.manualReadPendingProtocol !== 1
            || result.manualReadPendingObservationToken !== pending.message.manualReadPendingObservationToken) return false
        if (['pending', 'cancelling', 'unknown'].includes(result?.manualReadPendingState)) {
            if (!pending.recoveryOnly && result.manualReadPendingState === 'cancelling') pending.cancelling = true
            if (pending.slow) notify(pending)
            return false
        }
        const isHistoryOutcome = result.manualReadPendingHistoryRecovery === true
            && result.manualReadPendingOutcomeOnly === true
            && result.manualReadPendingPresentationAllowed === false
        if (result.manualReadPendingState === 'unavailable') {
            const allowedKeys = new Set([
                'requestID', 'manualReadPendingProtocol', 'manualReadPendingObservationToken',
                'manualReadPendingState', 'manualReadPendingHistoryRecovery',
                'manualReadPendingOutcomeOnly', 'manualReadPendingPresentationAllowed', 'errorCode',
            ])
            if (!isHistoryOutcome || result.errorCode !== 'outcomeUnavailable'
                || !Object.keys(result).every(key => allowedKeys.has(key))) return false
            pending.recoveryOnly = true
            return finish(pending, { outcomeKnown: false, stale: !ownerCurrent(pending),
                presentationAllowed: false, errorCode: 'outcomeUnavailable', nativeResult: result })
        }
        if (result.manualReadPendingState !== 'finished' || typeof result?.success !== 'boolean') return false
        const sectionMatches = result.manualReadPendingOutcomeOnly === true
            || result.sectionId === pending.sectionID
        if (!sectionMatches) return false
        if (isHistoryOutcome) pending.recoveryOnly = true
        const ownerIsCurrent = ownerCurrent(pending)
        const success = result.success === true
        return finish(pending, {
            success,
            outcomeKnown: true,
            stale: !ownerIsCurrent,
            presentationAllowed: !pending.recoveryOnly && ownerIsCurrent && sectionMatches
                && result.manualReadPendingOutcomeOnly !== true
                && result.manualReadPendingPresentationAllowed !== false,
            errorCode: success ? null : (!sectionMatches ? 'sectionMismatch' : result.errorCode || 'nativeCommitFailed'),
            nativeResult: result,
        })
    }
    const cancelAll = () => {
        for (const requestID of pendingByRequestID.keys()) cancel(requestID)
    }
    const pause = () => {
        observing = false
        // Pagehide proves departure. Ordinary unknown does not: the original
        // command may still be waiting for native admission.
        for (const pending of pendingByRequestID.values()) pending.recoveryOnly = true
        for (const pending of pendingByRequestID.values()) {
            const timer = pending.timeoutHandle
            pending.timeoutHandle = null
            if (timer != null) cancelTimeout?.(timer)
            // Cleanup can finish this request or resume it with another timer.
            // Retain that successor handle and never resurrect terminal chrome.
            if (pendingByRequestID.get(pending.requestID) === pending) notify(pending)
        }
    }
    const resume = () => {
        observing = true
        for (const pending of pendingByRequestID.values()) observe(pending, 0)
        detachLifecycle()
    }
    return { request, settle, cancel, cancelAll, pause, resume,
        get pendingCount() { return pendingByRequestID.size } }
}

// The top-level EPUB viewer does not use the ordinary article button wiring.
// Its slow/cancel UI must therefore retain its own request-specific ownership.
const pendingNativeMarkNotices = new Map()
export const presentNativeMarkReadPending = state => {
    let notice = pendingNativeMarkNotices.get(state.requestID)
    if (state.phase === 'finished') {
        notice?.remove()
        pendingNativeMarkNotices.delete(state.requestID)
        return
    }
    const document = globalThis.document
    if (!document?.body) return
    if (!notice) {
        notice = document.createElement('div')
        notice.className = 'mnb-native-mark-pending'
        notice.setAttribute('role', 'status')
        notice.setAttribute('data-mnb-japanese-processing-skip', 'true')
        notice.setAttribute('data-mnb-content-stats-skip', 'true')
        const label = document.createElement('span')
        const button = document.createElement('button')
        button.type = 'button'
        button.textContent = 'Cancel'
        button.addEventListener('click', () => state.cancel())
        notice.append(label, button)
        document.body.append(notice)
        pendingNativeMarkNotices.set(state.requestID, notice)
    }
    notice.firstElementChild.textContent = state.recoveryOnly === true
        ? 'Recovering reading change. Waiting for its outcome. '
        : state.phase === 'cancelling'
        ? 'Cancelling reading change. Waiting for its outcome. '
        : 'Still saving reading change. '
    notice.lastElementChild.hidden = state.recoveryOnly === true
    notice.lastElementChild.disabled = state.recoveryOnly === true || state.phase === 'cancelling'
}
