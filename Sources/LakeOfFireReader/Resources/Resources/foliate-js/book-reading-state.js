// An ordered native projection, never an epoch writer or a DOM-derived read model.
const clone = value => JSON.parse(JSON.stringify(value))
const sameLocation = (a, b) => !!a && !!b && a.sectionURL === b.sectionURL && a.isEndPage === b.isEndPage
export const bookScopeKey = scope => scope ? JSON.stringify([
    scope.articleProgressID, scope.articleEpochID, scope.chapterKey, scope.chapterEpochID,
]) : null
const nullableID = value => value === null || (typeof value === 'string' && value.length > 0)
const validScope = scope => scope && typeof scope.articleProgressID === 'string'
    && nullableID(scope.articleEpochID) && nullableID(scope.chapterEpochID)
    && typeof scope.chapterKey === 'string' && /^[0-9a-f]{64}$/.test(scope.chapterKey)
export class BookReadingStateController {
    #location = null; #revision = 0; #pendingID = null; #state = null; #context = null
    #closed = false; #lastSnapshotSequence = 0
    constructor({ postMessage, documentStartedAtMs, topWindowURL,
        onState = () => {}, onInvalidate = () => {}, isLocationCurrent = () => true, makeRequestID = () => globalThis.crypto.randomUUID().toLowerCase() }) {
        Object.assign(this, { postMessage, documentStartedAtMs, topWindowURL, onState, onInvalidate, isLocationCurrent, makeRequestID })
    }
    get ready() { return this.#context !== null && this.isLocationCurrent() }
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
        this.#revision++; this.#location = next; this.#pendingID = null
        if (changed || replaced) { this.#context = null; this.#state = null; this.onInvalidate() }
        this.refresh()
        return true
    }
    refresh() {
        if (this.#closed || !this.#location) return false
        const requestID = this.makeRequestID()
        this.#pendingID = requestID
        try { this.postMessage({ requestID, topWindowURL: this.topWindowURL,
            documentStartedAtMs: this.documentStartedAtMs, locationRevision: this.#revision, ...this.#location }) }
        catch (_) { this.#pendingID = null; this.#context = null; this.onInvalidate(); return false }
        return true
    }
    apply(requestID, result) {
        if (this.#closed || !this.#location || !result || !this.isLocationCurrent()) return false
        if (result.nativeRefresh === true) {
            if (!sameLocation(result.location, this.#location) || result.location.locationRevision !== this.#revision) return false
        } else if (requestID !== this.#pendingID) return false
        if (result.ok !== true) { this.#pendingID = null; this.#context = null; this.onInvalidate(); return false }
        const state = result.state, context = result.context
        if (!state || !context || !Number.isSafeInteger(state.revision) || state.revision <= 0
            || state.revision < this.#lastSnapshotSequence || typeof context.contextID !== 'string' || !context.contextID
            || context.isEndPage !== this.#location.isEndPage || state.articleProgressID !== context.articleProgressID
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
        const previousScope = bookScopeKey(this.#state?.scope), previousArticle = this.#state?.articleEpochID
        this.#pendingID = null; this.#lastSnapshotSequence = state.revision
        this.#state = clone(state); this.#context = clone(context)
        this.onState(this.state, this.context, { passChanged: previousScope !== bookScopeKey(state.scope) || previousArticle !== state.articleEpochID })
        return true
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
        if (!Number.isSafeInteger(sequence) || sequence <= 0 || sequence < this.#lastSnapshotSequence) return false
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
        this.#closed = true; this.#pendingID = null; this.#context = null; this.#state = null
        this.onInvalidate()
    }
}
