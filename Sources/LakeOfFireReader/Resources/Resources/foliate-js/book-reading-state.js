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
export class BookReadingStateController {
    #location = null; #revision = 0; #pending = null; #state = null; #context = null
    #closed = false; #lastSnapshotSequence = 0; #accountPresentation = null
    constructor({ postMessage, documentStartedAtMs, topWindowURL,
        onState = () => {}, onInvalidate = () => {}, onAccountChange = () => {},
        requiresAccountPresentation = false, isLocationCurrent = () => true, makeRequestID = () => globalThis.crypto.randomUUID().toLowerCase() }) {
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
        return () => !this.#closed && this.#location === location && this.#revision === revision
            && this.#accountPresentation === account && this.#lastSnapshotSequence === sequence
            && this.#state === state && this.#context === context
    }
    #captureAdmission() {
        const projectionIsCurrent = this.#captureProjection(), pending = this.#pending
        return () => projectionIsCurrent() && this.#pending === pending
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
    setAccountPresentation(stamp) {
        const order = compareBookAccountPresentation(stamp, this.#accountPresentation)
        if (this.#closed || order !== 1) return false
        this.#accountPresentation = stamp
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
        let request = null, projectionIsCurrent = null
        try {
            const makeRequestID = this.makeRequestID
            if (!preparationIsCurrent()) return false
            const requestID = Reflect.apply(makeRequestID, this, [])
            if (!preparationIsCurrent() || typeof requestID !== 'string' || !requestID) return false
            const payload = { requestID, topWindowURL: this.topWindowURL,
                documentStartedAtMs: this.documentStartedAtMs,
                locationRevision: this.#revision, ...this.#location }
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
        let admissionIsCurrent = this.#captureAdmission()
        if (!this.#location || !result || !this.#locationIsCurrent(admissionIsCurrent)) return false
        const location = this.#location, revision = this.#revision
        if (result.nativeRefresh === true) {
            if (!sameLocation(result.location, location) || result.location.locationRevision !== revision) return false
        } else if (!this.#pending || requestID !== this.#pending.requestID) return false
        const stamp = result.accountPresentation
        const needsAccount = stamp !== undefined || this.requiresAccountPresentation || this.#accountPresentation !== null
        if (!this.#locationIsCurrent(admissionIsCurrent)) return false
        if (needsAccount) {
            const order = compareBookAccountPresentation(stamp, this.#accountPresentation)
            if (order === null || order < 0) return false
            if (order > 0) {
                if (!this.setAccountPresentation(stamp)) return false
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
        this.#state = prepared.state; this.#context = prepared.context
        const ownsPublication = this.#captureProjection()
        const publicationIsCurrent = () => this.#locationIsCurrent(ownsPublication)
        Reflect.apply(onState, this, [notification.state, notification.context, { passChanged }, publicationIsCurrent])
        return publicationIsCurrent()
    }
    captureContext(expected = null) {
        if (!this.ready || this.#closed) throw new Error('The current chapter is still loading its book actions.')
        if (expected && expected.contextID !== this.#context.contextID) throw new Error('The chapter changed. Reopen Book Actions.')
        return { ...this.context, locationRevision: this.#revision }
    }
    captureScope(sectionURL) {
        if (this.#closed || !this.ready || this.#location?.isEndPage || sectionURL !== this.#location?.sectionURL) return null
        return clone(this.#context.scope)
    }
    noteManualReadSnapshot(sequence) {
        if (this.#closed || !Number.isSafeInteger(sequence) || sequence <= 0 || sequence < this.#lastSnapshotSequence) return false
        this.#lastSnapshotSequence = sequence
        return true
    }
    admitsNavigation(target) {
        if (!this.ready || target.locationRevision !== this.#revision
            || target.articleProgressID !== this.#context.articleProgressID || target.articleEpochID !== this.#context.articleEpochID) return false
        if (target.action === 'startBookOver') return true
        return target.action === 'startChapterOver' && !this.#context.isEndPage
            && target.sectionLocation === this.#context.sectionLocation && target.chapterEpochID === this.#context.scope?.chapterEpochID
    }
    close() {
        if (this.#closed) return
        this.#closed = true; this.#pending = null; this.#context = null; this.#state = null
        this.onInvalidate()
    }
}
