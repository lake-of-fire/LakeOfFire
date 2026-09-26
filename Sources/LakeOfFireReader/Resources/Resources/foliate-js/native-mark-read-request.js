import { carryReaderArticleProducerOwner } from './reader-producer-evidence.js'

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
    lifecycleTarget = globalThis,
} = {}) => {
    if (typeof postMessage !== 'function') throw new TypeError('postMessage must be a function')
    if (typeof postControlMessage !== 'function') throw new TypeError('postControlMessage must be a function')
    const pendingByRequestID = new Map()
    const issuedRequestIDs = new Set()
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
        catch (error) { pending.lastPresentationError = String(error) }
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
        cancel: () => cancel(pending.requestID),
    }))
    const postControl = pending => {
        try {
            postControlMessage({
                requestID: pending.requestID,
                manualReadPendingProtocol: 1,
                manualReadPendingObservationToken: pending.message.manualReadPendingObservationToken,
                manualReadPendingOperation: pending.cancelling ? 'cancel' : 'status',
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
            if (pendingByRequestID.get(pending.requestID) !== pending) return
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
        detachLifecycle()
        if (pending.timeoutHandle != null) cancelTimeout?.(pending.timeoutHandle)
        try {
            present(pending, () => onPending({ requestID: pending.requestID,
                phase: 'finished', context: pending.context }))
        } finally {
            pending.resolve({ requestID: pending.requestID, context: pending.context, ...outcome })
        }
        return true
    }
    const cancel = requestID => {
        const pending = pendingByRequestID.get(requestID)
        if (!pending) return false
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
        if (!observing || pendingByRequestID.size >= 32 || issuedRequestIDs.size >= 2048) {
            return Promise.resolve({ requestID: null, context, success: false,
                stale: false, errorCode: 'pendingCapacityExceeded', presentationAllowed: false })
        }
        let requestID
        for (let attempts = 0; attempts < 32; attempts += 1) {
            const candidate = makeRequestID()
            if (typeof candidate === 'string' && candidate && !issuedRequestIDs.has(candidate)) {
                requestID = candidate
                break
            }
        }
        if (!requestID) throw new Error('Could not allocate a unique native request identity')
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
            cancelling: false, slow: false }
        issuedRequestIDs.add(requestID)
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
            if (result.manualReadPendingState === 'cancelling') pending.cancelling = true
            if (pending.slow) notify(pending)
            return false
        }
        if (result.manualReadPendingState !== 'finished' || typeof result?.success !== 'boolean') return false
        const sectionMatches = result.manualReadPendingOutcomeOnly === true
            || result.sectionId === pending.sectionID
        if (!sectionMatches) return false
        const ownerIsCurrent = ownerCurrent(pending)
        const success = result.success === true
        return finish(pending, {
            success,
            stale: !ownerIsCurrent,
            presentationAllowed: ownerIsCurrent && sectionMatches
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
        for (const pending of pendingByRequestID.values()) {
            if (pending.timeoutHandle != null) cancelTimeout?.(pending.timeoutHandle)
            pending.timeoutHandle = null
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
    notice.firstElementChild.textContent = state.phase === 'cancelling'
        ? 'Cancelling reading change. Waiting for its outcome. '
        : 'Still saving reading change. '
    notice.lastElementChild.disabled = state.phase === 'cancelling'
}
