import { cryptographicUUID } from './cryptographic-uuid.js'
// An ordered native projection, never an epoch writer or a DOM-derived read model.
const clone = value => JSON.parse(JSON.stringify(value))
const accountPresentationValue = value => {
    if (typeof value !== 'string' || !/^(0|[1-9][0-9]{0,19}):[01]$/.test(value)) return null
    const [generation, phase] = value.split(':')
    const integer = BigInt(generation)
    return integer <= 18446744073709551615n ? [integer, Number(phase)] : null
}
// This stamp only orders presentation. It grants no producer or write authority.
export const compareBookAccountPresentation = (next, current) => {
    const value = accountPresentationValue(next)
    if (!value) return null
    if (current === null) return 1
    const prior = accountPresentationValue(current)
    if (!prior) return null
    return value[0] === prior[0] ? Math.sign(value[1] - prior[1]) : value[0] > prior[0] ? 1 : -1
}
const sameLocation = (a, b) => !!a && !!b && a.sectionURL === b.sectionURL && a.isEndPage === b.isEndPage
export const bookScopeKey = scope => scope ? JSON.stringify([
    scope.articleProgressID, scope.articleEpochID, scope.chapterKey, scope.chapterEpochID,
]) : null
const nullableID = value => value === null || (typeof value === 'string' && value.length > 0)
const validScope = scope => scope && typeof scope.articleProgressID === 'string'
    && nullableID(scope.articleEpochID) && nullableID(scope.chapterEpochID)
    && typeof scope.chapterKey === 'string' && /^[0-9a-f]{64}$/.test(scope.chapterKey)
const recoveryObservation = value => {
    try {
        const copy = clone(value)
        return copy && Object.keys(copy).length === 2
            && typeof copy.requestID === 'string' && copy.requestID.length > 0
            && typeof copy.observationToken === 'string' && copy.observationToken.length > 0
            ? Object.freeze(copy) : null
    } catch (_) { return null }
}
const sameRecoveryObservation = (a, b) => !!a && !!b
    && a.requestID === b.requestID && a.observationToken === b.observationToken
export class BookReadingStateController {
    #location = null; #revision = 0; #pending = null; #state = null; #context = null
    #closed = false; #lastSnapshotSequence = 0; #accountPresentation = null
    #historyRecovery = null
    #acknowledgedHistoryRecovery = null
    constructor({ postMessage, documentStartedAtMs, topWindowURL,
        onState = () => {}, onInvalidate = () => {}, onAccountChange = () => {},
        requiresAccountPresentation = false, isLocationCurrent = () => true, makeRequestID = cryptographicUUID }) {
        Object.assign(this, { postMessage, documentStartedAtMs, topWindowURL, onState, onInvalidate, onAccountChange,
            requiresAccountPresentation, isLocationCurrent, makeRequestID })
    }
    // The projection and pending request have different lifetimes: queuing a
    // refresh does not withdraw an accepted display, but it supersedes another
    // request's preparation or failure cleanup. Reuse their existing identities.
    #captureProjection() {
        const location = this.#location, revision = this.#revision
        const account = this.#accountPresentation, sequence = this.#lastSnapshotSequence
        const state = this.#state, context = this.#context
        const recovery = this.#historyRecovery
        return () => !this.#closed && this.#location === location && this.#revision === revision
            && this.#accountPresentation === account && this.#lastSnapshotSequence === sequence
            && this.#state === state && this.#context === context && this.#historyRecovery === recovery
    }
    #captureAdmission() {
        const projectionIsCurrent = this.#captureProjection(), pending = this.#pending
        // A failed/restarted read can keep the same recovery object and empty
        // request slot. Its predecessor must not dispatch under that new phase.
        const recovery = this.#historyRecovery
        const completion = recovery?.promise, requested = recovery?.requested
        return () => projectionIsCurrent() && this.#pending === pending
            && recovery?.promise === completion && recovery?.requested === requested
    }
    #locationIsCurrent(isCurrent) {
        if (!isCurrent()) return false
        const check = this.isLocationCurrent
        return isCurrent() && typeof check === 'function'
            && Reflect.apply(check, this, []) === true && isCurrent()
    }
    #notify(property, args, isCurrent) {
        if (!isCurrent()) return false
        const callback = this[property]
        if (!isCurrent() || typeof callback !== 'function') return false
        Reflect.apply(callback, this, args)
        return isCurrent()
    }
    get accountPresentation() { return this.#accountPresentation }
    #retireHistoryRecovery() {
        const recovery = this.#historyRecovery
        this.#historyRecovery = null
        this.#acknowledgedHistoryRecovery = null
        recovery?.resolve?.(false)
    }
    // Receipt invalidation is local display cleanup. It does not move the
    // renderer or create a native visit, action epoch, or reading mutation.
    beginHistoryReadingStatusRecovery(observation, expectedScope, isCurrent = () => true) {
        const ownsPreparation = this.#captureAdmission()
        if (this.#closed || !this.#location || !isCurrent() || !ownsPreparation()) return false
        const proof = recoveryObservation(observation)
        let scopeKey
        try { scopeKey = bookScopeKey(expectedScope) } catch (_) { return false }
        if (!proof || !scopeKey || !isCurrent() || !this.#locationIsCurrent(ownsPreparation)) return false
        if (this.#context && bookScopeKey(this.#context.scope) !== scopeKey) return false
        this.#retireHistoryRecovery()
        this.#historyRecovery = { proof, scopeKey, account: this.#accountPresentation,
            isCurrent, requested: false, promise: null, resolve: null }
        this.#pending = null; this.#context = null; this.#state = null
        const ownsRecovery = this.#captureAdmission()
        this.#notify('onInvalidate', [], ownsRecovery)
        return this.#locationIsCurrent(ownsRecovery) && isCurrent()
    }
    // Native is the sole automatic-attempt owner. Merely receiving a terminal
    // outcome cannot authorize this query; native admits its exact running proof.
    recoverHistoryReadingStatus(observation) {
        const recovery = this.#historyRecovery
        const ownsRecovery = this.#captureAdmission()
        const proof = recoveryObservation(observation)
        if (!recovery || !proof || !sameRecoveryObservation(proof, recovery.proof)
            || !recovery.isCurrent() || !this.#locationIsCurrent(ownsRecovery)
            || this.#accountPresentation !== recovery.account) return Promise.resolve(false)
        if (recovery.promise) return recovery.promise
        recovery.promise = new Promise(resolve => { recovery.resolve = resolve })
        const completion = recovery.promise, resolve = recovery.resolve
        recovery.requested = true
        try {
            if (this.refresh()) return completion
        } catch (_) {} // Failed invalidation is not an unresolved native read.
        // Cleanup may already have retired this observer or admitted another
        // recovery. Settle the original promise, never its replacement, even
        // when an optional callback threw after releasing the stored resolver.
        if (this.#historyRecovery === recovery && recovery.promise === completion) {
            recovery.requested = false
            recovery.resolve = null; recovery.promise = null
        }
        resolve(false)
        return completion
    }
    reacknowledgeHistoryReadingStatus(observation) {
        const acknowledged = this.#acknowledgedHistoryRecovery
        const proof = recoveryObservation(observation)
        return !!acknowledged && sameRecoveryObservation(proof, acknowledged.proof)
            && acknowledged.isCurrent() && this.ready && acknowledged.isCurrent()
    }
    failHistoryReadingStatusRecovery(observation) {
        let ownsFailure = this.#captureAdmission()
        let recovery = this.#historyRecovery
        const acknowledged = this.#acknowledgedHistoryRecovery
        const proof = recoveryObservation(observation)
        if (!ownsFailure()) return false
        if (!recovery) {
            if (!proof || !acknowledged || !sameRecoveryObservation(proof, acknowledged.proof)
                || !acknowledged.isCurrent() || !this.ready || !acknowledged.isCurrent()) return false
            const location = this.#location, revision = this.#revision, account = this.#accountPresentation
            const scopeKey = bookScopeKey(this.#context.scope)
            const isCurrent = () => !this.#closed && this.#location === location
                && this.#revision === revision && this.#accountPresentation === account
            recovery = this.#historyRecovery = { proof, scopeKey, account, isCurrent,
                requested: false, promise: null, resolve: null }
            this.#acknowledgedHistoryRecovery = null
            this.#pending = null; this.#context = null; this.#state = null
            ownsFailure = this.#captureAdmission()
            this.#notify('onInvalidate', [], ownsFailure)
            if (!this.#locationIsCurrent(ownsFailure)) return false
        }
        if (this.#historyRecovery !== recovery || !recovery
            || !sameRecoveryObservation(proof, recovery.proof) || !recovery.isCurrent()
            || !ownsFailure()) return false
        this.#pending = null; recovery.requested = false
        recovery.resolve?.(false); recovery.resolve = null; recovery.promise = null
        return true
    }
    setAccountPresentation(stamp) {
        const order = compareBookAccountPresentation(stamp, this.#accountPresentation)
        if (this.#closed || order !== 1) return false
        this.#accountPresentation = stamp
        this.#retireHistoryRecovery()
        this.#pending = null; this.#state = null; this.#context = null; this.#lastSnapshotSequence = 0
        const isCurrent = this.#captureProjection()
        if (!this.#notify('onAccountChange', [stamp], isCurrent)) return false
        // A queued sample still needs old-frame invalidation. A callback that
        // already published a successor must not have its scopes retired again.
        if (!this.#notify('onInvalidate', [], isCurrent)) return false
        return isCurrent() && this.#pending === null
    }
    get ready() { return this.#context !== null && this.#locationIsCurrent(this.#captureProjection()) }
    get locationRevision() { return this.#revision }
    get location() { return this.#location ? clone(this.#location) : null }
    get state() { return this.#state ? clone(this.#state) : null }
    get context() { return this.#context ? clone(this.#context) : null }
    relocate({ sectionURL = null, isEndPage = false }, { moved = false, replaced = false } = {}) {
        if (this.#closed || typeof isEndPage !== 'boolean' || (!isEndPage && (typeof sectionURL !== 'string' || !sectionURL))) return false
        const next = { sectionURL: isEndPage ? null : sectionURL, isEndPage }
        const changed = !sameLocation(next, this.#location)
        if (!changed && !moved && !replaced) return false
        if (this.#revision >= Number.MAX_SAFE_INTEGER) { this.close(); return false }
        this.#revision++; this.#location = next; this.#pending = null
        this.#retireHistoryRecovery()
        if (changed || replaced) { this.#context = null; this.#state = null }
        const isCurrent = this.#captureAdmission()
        if (changed || replaced) this.#notify('onInvalidate', [], isCurrent)
        // A nested relocation/refresh already requested its own sample.
        if (isCurrent()) this.refresh()
        return true
    }
    refresh() {
        if (this.#closed || !this.#location) return false
        const preparationIsCurrent = this.#captureAdmission()
        const recovery = this.#historyRecovery
        if (recovery && (!recovery.requested || !recovery.isCurrent()
            || recovery.account !== this.#accountPresentation)) return false
        if (!preparationIsCurrent()) return false
        if (recovery && this.#pending) return true
        let request = null, projectionIsCurrent = null
        try {
            const makeRequestID = this.makeRequestID
            if (!preparationIsCurrent()) return false
            const requestID = Reflect.apply(makeRequestID, this, [])
            if (!preparationIsCurrent() || typeof requestID !== 'string' || !requestID) return false
            const payload = { requestID, topWindowURL: this.topWindowURL,
                documentStartedAtMs: this.documentStartedAtMs,
                locationRevision: this.#revision, ...this.#location,
                ...(recovery ? { historyRecoveryObservation: { ...recovery.proof },
                    historyRecoveryAccountPresentation: recovery.account } : {}) }
            if (!preparationIsCurrent()) return false
            // Keep the existing wire ID, but distinguish local requests even
            // when a compatibility request-ID provider repeats the same value.
            request = this.#pending = { requestID }
            projectionIsCurrent = this.#captureProjection()
            const requestIsCurrent = this.#captureAdmission()
            const postMessage = this.postMessage
            if (!requestIsCurrent()) {
                if (this.#pending === request) this.#pending = null
                return false
            }
            Reflect.apply(postMessage, this, [payload])
            return true
        } catch (_) {
            // Posting may synchronously publish a result or start a replacement
            // before throwing. Only this exact unconsumed request owns cleanup.
            if (request !== null && this.#pending === request) {
                this.#pending = null
                // Releasing the failed read's slot must not invalidate newer
                // display facts or consume another request's reply capability.
                if (projectionIsCurrent()) {
                    this.#context = null
                    this.#notify('onInvalidate', [], this.#captureProjection())
                }
            }
            return false
        }
    }
    apply(requestID, result) {
        const recovery = this.#historyRecovery, pending = this.#pending
        const completion = recovery?.promise, resolve = recovery?.resolve
        const ownsReply = this.#captureAdmission()
        let acknowledgesRecovery = false, accepted = false
        try {
            acknowledgesRecovery = !!recovery && !!pending && requestID === pending.requestID
                && sameRecoveryObservation(recoveryObservation(result?.historyRecoveryObservation), recovery.proof)
                && this.#historyRecovery === recovery && this.#pending === pending
            if (!ownsReply()) return false
            accepted = this.#apply(requestID, result)
            return accepted
        } finally {
            if (acknowledgesRecovery && !accepted) {
                // Reply callbacks can reject this attempt and explicitly start
                // another on the same recovery. Only the original completion
                // owns failure cleanup; a newer read still needs its own reply.
                if (this.#historyRecovery === recovery && recovery.promise === completion) {
                    recovery.requested = false
                    if (this.#pending === pending) this.#pending = null
                    recovery.resolve = null; recovery.promise = null
                }
                resolve?.(false)
            }
        }
    }
    #apply(requestID, result) {
        let admissionIsCurrent = this.#captureAdmission()
        if (!this.#location || !result || !this.#locationIsCurrent(admissionIsCurrent)) return false
        const location = this.#location, revision = this.#revision
        const nativeRefresh = result.nativeRefresh === true
        const responsePending = this.#pending
        const recovery = this.#historyRecovery
        if (recovery) {
            const proof = recoveryObservation(result.historyRecoveryObservation)
            if (!admissionIsCurrent() || nativeRefresh || !sameRecoveryObservation(proof, recovery.proof)
                || !sameLocation(result.location, location) || result.location.locationRevision !== revision
                || result.accountPresentation !== recovery.account || !recovery.isCurrent()
                || !admissionIsCurrent()) return false
        }
        if (nativeRefresh) {
            if (!sameLocation(result.location, location) || result.location.locationRevision !== revision) return false
        } else if (!responsePending || requestID !== responsePending.requestID) return false
        const stamp = result.accountPresentation
        const needsAccount = stamp !== undefined || this.requiresAccountPresentation || this.#accountPresentation !== null
        if (!this.#locationIsCurrent(admissionIsCurrent)) return false
        if (needsAccount) {
            const order = compareBookAccountPresentation(stamp, this.#accountPresentation)
            if (order === null || order < 0) return false
            if (order > 0) {
                const setAccountPresentation = this.setAccountPresentation
                if (!admissionIsCurrent() || typeof setAccountPresentation !== 'function') return false
                if (!Reflect.apply(setAccountPresentation, this, [stamp])) return false
                // The account transition withdraws the old display, but this
                // already-correlated reply still owns its preparation slot.
                // Preserve it until copying commits so a failed copy is retryable.
                // A callback-selected request/publication makes the transition
                // return false above and cannot be replaced by this old slot.
                if (!nativeRefresh) this.#pending = responsePending
                admissionIsCurrent = this.#captureAdmission()
            }
            if (this.#accountPresentation !== stamp) return false
        }
        if (this.#location !== location || this.#revision !== revision
            || !this.#locationIsCurrent(admissionIsCurrent)) return false
        const ok = result.ok
        if (!admissionIsCurrent()) return false
        if (ok !== true) {
            this.#pending = null; this.#context = null
            this.#notify('onInvalidate', [], this.#captureProjection())
            return false
        }
        let prepared, notification
        try {
            // Prepare both values before consuming the request or sequence.
            // Validate the actual copied data, not properties that toJSON can
            // replace. A malformed copy leaves the original response retryable.
            prepared = clone({ state: result.state, context: result.context })
            const { state, context } = prepared
            if (recovery && bookScopeKey(state?.scope) !== recovery.scopeKey) return false
            if (!state || !context || !Number.isSafeInteger(state.revision) || state.revision <= 0
                || state.revision < this.#lastSnapshotSequence || typeof context.contextID !== 'string' || !context.contextID
                || context.isEndPage !== location.isEndPage || state.articleProgressID !== context.articleProgressID
                || state.articleEpochID !== context.articleEpochID || !nullableID(state.articleEpochID)
                || typeof state.finished !== 'boolean'
                || !['present', 'empty', 'unknown'].includes(state.bookReadPresence)
                || !['present', 'empty', 'unknown'].includes(state.chapterReadPresence)
                || !Array.isArray(state.readSegmentIdentifiers) || !state.readSegmentIdentifiers.every(x => typeof x === 'string')
                || !Array.isArray(state.sentenceIdentifiersRead) || !state.sentenceIdentifiersRead.every(x => typeof x === 'string')) return false
            if (context.isEndPage) {
                if (state.scope !== null || context.scope !== null || context.sectionLocation !== null) return false
            } else if (!validScope(state.scope) || bookScopeKey(state.scope) !== bookScopeKey(context.scope)
                || state.scope.articleProgressID !== state.articleProgressID || state.scope.articleEpochID !== state.articleEpochID) return false
            notification = clone(prepared)
        } catch (_) { return false }
        if (!this.#locationIsCurrent(admissionIsCurrent)) return false
        const passChanged = bookScopeKey(this.#state?.scope) !== bookScopeKey(prepared.state.scope)
            || this.#state?.articleEpochID !== prepared.state.articleEpochID
        const onState = this.onState
        if (typeof onState !== 'function' || !this.#locationIsCurrent(admissionIsCurrent)) return false
        // All callback-bearing preparation is complete. Publish both copies and
        // their ordering marker together, without an external call between them.
        this.#pending = null; this.#lastSnapshotSequence = prepared.state.revision
        this.#acknowledgedHistoryRecovery = null
        if (recovery) this.#historyRecovery = null
        this.#state = prepared.state; this.#context = prepared.context
        const ownsPublication = this.#captureProjection()
        const publicationIsCurrent = () => this.#locationIsCurrent(ownsPublication)
        let accepted
        try {
            Reflect.apply(onState, this, [notification.state, notification.context, { passChanged }, publicationIsCurrent])
            accepted = publicationIsCurrent()
        } catch (error) {
            if (!recovery) throw error
            // A failed recovery callback cannot leave authoring authority live
            // without either its barrier or an acknowledged publication. Use
            // private identities so external checks cannot obstruct cleanup,
            // and retain any successor installed by a reentrant callback.
            // A queued refresh is not a published successor. Withdraw its
            // request together with the failed projection and restore the barrier.
            if (ownsPublication()) {
                this.#pending = null; this.#state = null; this.#context = null
                this.#historyRecovery = recovery
                recovery.requested = false
                try { this.#notify('onInvalidate', [], this.#captureAdmission()) } catch (_) {}
            }
            return false
        }
        if (accepted && recovery) this.#acknowledgedHistoryRecovery = {
            proof: recovery.proof, isCurrent: publicationIsCurrent,
        }
        recovery?.resolve?.(accepted)
        return accepted
    }
    captureContext(expected = null) {
        const isCurrent = this.#captureProjection()
        if (!this.#context || !this.#locationIsCurrent(isCurrent)) {
            throw new Error('The current chapter is still loading its book actions.')
        }
        // Caller data may run a getter that closes or publishes a successor.
        // Return only the projection that admitted this call, never that successor.
        const expectedID = expected ? expected.contextID : null
        if (!isCurrent() || (expected && expectedID !== this.#context.contextID)) {
            throw new Error('The chapter changed. Reopen Book Actions.')
        }
        const context = clone(this.#context)
        if (!this.#locationIsCurrent(isCurrent)) throw new Error('The chapter changed. Reopen Book Actions.')
        return { ...context, locationRevision: this.#revision }
    }
    captureScope(sectionURL) {
        const isCurrent = this.#captureProjection()
        if (!this.#context || !this.#locationIsCurrent(isCurrent) || this.#location?.isEndPage
            || sectionURL !== this.#location?.sectionURL) return null
        const scope = clone(this.#context.scope)
        return this.#locationIsCurrent(isCurrent) ? scope : null
    }
    noteManualReadSnapshot(sequence) {
        if (this.#closed || !Number.isSafeInteger(sequence) || sequence <= 0 || sequence < this.#lastSnapshotSequence) return false
        this.#lastSnapshotSequence = sequence
        return true
    }
    admitsNavigation(target) {
        const isCurrent = this.#captureProjection(), context = this.#context
        if (!context || !target || !this.#locationIsCurrent(isCurrent)) return false
        const revision = this.#revision
        const locationRevision = target.locationRevision
        const articleProgressID = target.articleProgressID, articleEpochID = target.articleEpochID
        const action = target.action
        if (!isCurrent() || locationRevision !== revision
            || articleProgressID !== context.articleProgressID || articleEpochID !== context.articleEpochID) return false
        if (action === 'startBookOver') return this.#locationIsCurrent(isCurrent)
        if (action !== 'startChapterOver' || context.isEndPage) return false
        const sectionLocation = target.sectionLocation, chapterEpochID = target.chapterEpochID
        return sectionLocation === context.sectionLocation && chapterEpochID === context.scope?.chapterEpochID
            && this.#locationIsCurrent(isCurrent)
    }
    close() {
        if (this.#closed) return
        this.#closed = true; this.#pending = null; this.#context = null; this.#state = null
        this.#retireHistoryRecovery()
        this.onInvalidate()
    }
}
