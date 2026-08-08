const RESTORE_LOCATOR_PREFIX = 'mnb-loc-v1:'
let readerPageTurnAttemptSequence = 0

export const makeReaderPageTurnAttemptID = ({
    crypto = globalThis.crypto,
    now = Date.now,
    random = Math.random,
} = {}) => {
    try {
        const uuid = crypto?.randomUUID?.()
        if (typeof uuid === 'string' && uuid.length > 0) return uuid
    } catch (_error) {}
    readerPageTurnAttemptSequence = readerPageTurnAttemptSequence >= Number.MAX_SAFE_INTEGER
        ? 1
        : readerPageTurnAttemptSequence + 1
    const timestamp = Number(now?.())
    const randomValue = Number(random?.())
    const timePart = Number.isFinite(timestamp)
        ? Math.max(0, Math.trunc(timestamp)).toString(36)
        : '0'
    const randomPart = Number.isFinite(randomValue)
        ? Math.abs(randomValue).toString(36).replace(/^0\./, '').slice(0, 12)
        : '0'
    return `mnb-turn-${timePart}-${readerPageTurnAttemptSequence.toString(36)}-${randomPart}`
}

export const makeSyntheticRestoreLocator = ({ sectionIndex, localSectionIndex, rendererTotal }) => {
    if (![sectionIndex, localSectionIndex, rendererTotal].every(Number.isFinite)) return null
    const normalizedSectionIndex = Math.max(0, Math.round(sectionIndex))
    const normalizedRendererTotal = Math.max(1, Math.round(rendererTotal))
    const normalizedLocalSectionIndex = Math.max(
        0,
        Math.min(normalizedRendererTotal - 1, Math.round(localSectionIndex))
    )
    return `${RESTORE_LOCATOR_PREFIX}${normalizedSectionIndex}:${normalizedLocalSectionIndex}:${normalizedRendererTotal}`
}

export const parseSyntheticRestoreLocator = value => {
    if (typeof value !== 'string' || !value.startsWith(RESTORE_LOCATOR_PREFIX)) return null
    const parts = value.slice(RESTORE_LOCATOR_PREFIX.length).split(':')
    if (parts.length !== 3) return null
    const [sectionIndexRaw, localSectionIndexRaw, rendererTotalRaw] = parts.map(Number)
    if (![sectionIndexRaw, localSectionIndexRaw, rendererTotalRaw].every(Number.isFinite)) return null
    const sectionIndex = Math.max(0, Math.round(sectionIndexRaw))
    const rendererTotal = Math.max(1, Math.round(rendererTotalRaw))
    const localSectionIndex = Math.max(0, Math.min(rendererTotal - 1, Math.round(localSectionIndexRaw)))
    return {
        sectionIndex,
        localSectionIndex,
        rendererTotal,
        fractionInSection: rendererTotal > 1 ? localSectionIndex / (rendererTotal - 1) : 0,
    }
}

export const runRequiredRestoreNavigation = async operation => {
    try {
        return {
            ok: true,
            value: await operation(),
            error: null,
        }
    } catch (error) {
        return {
            ok: false,
            value: null,
            error,
        }
    }
}

const RESTORE_NAVIGATION_NOT_ACCEPTED_CODE = 'restore-navigation-not-accepted'

export const runAcceptedRestoreNavigation = async operation => {
    const result = await runRequiredRestoreNavigation(operation)
    if (!result.ok || result.value === true) return result

    const error = new Error('Restore navigation was not accepted by the renderer')
    error.code = RESTORE_NAVIGATION_NOT_ACCEPTED_CODE
    error.receipt = result.value ?? null
    return {
        ok: false,
        value: result.value,
        error,
    }
}

const RESTORE_TRANSACTION_SUPERSEDED_CODE = 'restore-transaction-superseded'

export const makeRestoreTransactionSupersededError = reason => {
    const normalizedReason = typeof reason === 'string' && reason.length > 0
        ? reason
        : 'superseded'
    const error = new Error(`Restore transaction was superseded: ${normalizedReason}`)
    error.code = RESTORE_TRANSACTION_SUPERSEDED_CODE
    error.reason = normalizedReason
    return error
}

export const isRestoreTransactionSupersededError = error => (
    error?.code === RESTORE_TRANSACTION_SUPERSEDED_CODE
)

export class LatestRestoreTransactionCoordinator {
    #sequence = 0
    #current = null

    get current() {
        return this.#current
    }

    begin(context = {}) {
        this.cancelCurrent('superseded-by-newer-restore')

        let resolveCancellation = null
        let resolveSettled = null
        const cancellation = new Promise(resolve => {
            resolveCancellation = resolve
        })
        const settled = new Promise(resolve => {
            resolveSettled = resolve
        })
        const owner = {
            id: ++this.#sequence,
            context,
            cancellation,
            settled,
            cancelled: false,
            cancelReason: null,
            finished: false,
            resolveCancellation,
            resolveSettled,
        }
        this.#current = owner
        return owner
    }

    isCurrent(owner) {
        return !!owner
            && this.#current === owner
            && owner.cancelled !== true
            && owner.finished !== true
    }

    cancel(owner, reason = 'cancelled') {
        if (!owner || owner.cancelled === true || owner.finished === true) return false
        owner.cancelled = true
        owner.cancelReason = reason
        owner.resolveCancellation?.(reason)
        owner.resolveCancellation = null
        owner.resolveSettled?.({ reason, cancelled: true })
        owner.resolveSettled = null
        if (this.#current === owner) {
            this.#current = null
        }
        return true
    }

    cancelCurrent(reason = 'cancelled') {
        return this.cancel(this.#current, reason)
    }

    finish(owner) {
        if (!this.isCurrent(owner)) return false
        owner.finished = true
        owner.resolveCancellation = null
        owner.resolveSettled?.({ reason: 'finished', cancelled: false })
        owner.resolveSettled = null
        this.#current = null
        return true
    }

    async wait(owner, operation) {
        if (!this.isCurrent(owner)) {
            throw makeRestoreTransactionSupersededError(owner?.cancelReason)
        }

        const operationPromise = Promise.resolve().then(() => {
            if (!this.isCurrent(owner)) {
                throw makeRestoreTransactionSupersededError(owner?.cancelReason)
            }
            return typeof operation === 'function' ? operation() : operation
        })
        const outcome = await Promise.race([
            operationPromise.then(
                value => ({ type: 'value', value }),
                error => ({ type: 'error', error })
            ),
            owner.cancellation.then(reason => ({ type: 'cancelled', reason })),
        ])

        if (outcome.type === 'cancelled') {
            throw makeRestoreTransactionSupersededError(outcome.reason)
        }
        if (outcome.type === 'error') {
            throw outcome.error
        }
        if (!this.isCurrent(owner)) {
            throw makeRestoreTransactionSupersededError(owner?.cancelReason)
        }
        return outcome.value
    }
}

export const commitAfterMatchingRestoreTransactionsSettle = async ({
    coordinator,
    matches,
    isCurrent = () => true,
    commit = () => true,
} = {}) => {
    if (!coordinator || typeof matches !== 'function' || typeof commit !== 'function') {
        return false
    }
    while (isCurrent()) {
        const owner = coordinator.current
        if (!owner || !matches(owner)) {
            if (!isCurrent()) return false
            return commit() !== false
        }
        await owner.settled
    }
    return false
}

export class PendingInitialRestoreMailbox {
    #pending = null
    #closed = false

    constructor({ loadToken, url } = {}) {
        this.loadToken = loadToken ?? null
        this.url = typeof url === 'string' ? url : ''
    }

    get isClosed() {
        return this.#closed
    }

    get hasPending() {
        return !this.#closed && this.#pending != null
    }

    matches({ loadToken, url } = {}) {
        return !this.#closed
            && this.loadToken === (loadToken ?? null)
            && this.url === (typeof url === 'string' ? url : '')
    }

    queue(restore) {
        if (this.#closed || restore == null) return false
        this.#pending = restore
        return true
    }

    take() {
        if (this.#closed) return null
        const pending = this.#pending
        this.#pending = null
        return pending
    }

    closeAndTake() {
        if (this.#closed) return null
        const pending = this.#pending
        this.#pending = null
        this.#closed = true
        return pending
    }

    close() {
        if (this.#closed) return false
        this.closeAndTake()
        return true
    }
}

// Renderer navigation APIs historically returned undefined on success, while
// newer paths return booleans or structured receipts. Preserve the one legacy
// success value, but require structured receipts to prove a committed move so
// malformed bridge values cannot record a destination that never became visible.
export const readerNavigationResultWasCommitted = result => {
    // Undefined is Foliate's legacy success receipt. Every other primitive is
    // fail-closed so malformed bridge values cannot create history for a move
    // the renderer did not prove or preserve.
    if (result === undefined || result === true) return true
    if (result == null || result === false || typeof result !== 'object') return false
    const rejected = result.committed === false
        || result.executed === false
        || result.ok === false
        || result.succeeded === false
        || result.cancelled === true
        || result.canceled === true
        || result.aborted === true
        || result.ignored === true
        || result.failed === true
        || result.destroyed === true
        || result.superseded === true
        || result.moved === false
    if (rejected) return false
    return result.committed === true
        || result.executed === true
        || result.ok === true
        || result.succeeded === true
        || result.moved === true
}

// Restore and idempotent direct-navigation callers need to distinguish an
// explicit rejection from a renderer proving that the requested destination is
// already visible. `targetSatisfied` is deliberately separate from movement:
// it must never create history or close a lookup as though a relocation occurred.
export const readerNavigationResultReachedTarget = result => {
    if (readerNavigationResultWasCommitted(result)) return true
    if (!result || typeof result !== 'object' || result.targetSatisfied !== true) {
        return false
    }
    return result.committed !== false
        && result.executed !== false
        && result.ok !== false
        && result.succeeded !== false
        && result.cancelled !== true
        && result.canceled !== true
        && result.aborted !== true
        && result.failed !== true
        && result.destroyed !== true
        && result.superseded !== true
}


const ALREADY_VISIBLE_READER_NAVIGATION_RESULT = Object.freeze({
    ignored: true,
    moved: false,
    targetSatisfied: true,
    reason: 'alreadyAtVisibleRendererTarget',
})

// The Reader wraps renderer.goTo() to avoid a destructive duplicate section
// navigation. Keep that optimization deliberately narrow: only an index-only
// request is provably already satisfied synchronously. Anchors, local pages,
// selections, and renderer-specific position data must reach the renderer.
export const readerVisibleRendererNavigationRejection = ({
    target = null,
    currentIndex = null,
    navigationIsCurrent = null,
} = {}) => {
    if (
        typeof navigationIsCurrent === 'function'
        && navigationIsCurrent() !== true
    ) {
        return {
            superseded: true,
            moved: false,
            reason: 'readerNavigationSuperseded',
        }
    }
    if (!target || typeof target !== 'object') return null
    const targetKeys = Object.keys(target)
    if (targetKeys.length !== 1 || targetKeys[0] !== 'index') return null
    if (
        !Number.isInteger(target.index)
        || target.index < 0
        || !Number.isInteger(currentIndex)
        || currentIndex < 0
        || target.index !== currentIndex
    ) return null
    return ALREADY_VISIBLE_READER_NAVIGATION_RESULT
}

export const snapshotReaderNavigationIntent = candidate => {
    if (!candidate || typeof candidate !== 'object') return null
    return Object.isFrozen(candidate)
        ? candidate
        : Object.freeze({ ...candidate })
}

export const explicitRelocateHistoryMutationFromIntent = candidate => {
    const source = typeof candidate?.explicitRelocateHistorySource === 'string'
        ? candidate.explicitRelocateHistorySource.trim()
        : ''
    const mutationID = typeof candidate?.explicitRelocateHistoryMutationID === 'string'
        ? candidate.explicitRelocateHistoryMutationID.trim()
        : ''
    if (!source || !mutationID) return null
    const requestGeneration = Number.isInteger(
        candidate?.explicitRelocateHistoryRequestGeneration
    )
        ? candidate.explicitRelocateHistoryRequestGeneration
        : null
    return Object.freeze({ source, mutationID, requestGeneration })
}

export const readerRelocationDetailWithNavigationIntent = ({
    rendererDetail = null,
    navigationIntent = null,
} = {}) => {
    const detail = rendererDetail && typeof rendererDetail === 'object'
        ? rendererDetail
        : {}
    // Renderer-owned metadata is causal and therefore always wins. The intent
    // argument is useful only when the caller passes the exact immutable intent
    // that initiated this renderer operation; ambient global state is unsafe.
    const historyMutation = explicitRelocateHistoryMutationFromIntent(detail)
        ?? explicitRelocateHistoryMutationFromIntent(navigationIntent)
    const motionStartedAtMs = Number.isFinite(detail.motionStartedAtMs)
        ? detail.motionStartedAtMs
        : (Number.isFinite(navigationIntent?.motionStartedAtMs)
            ? navigationIntent.motionStartedAtMs
            : null)
    const needsMotionStartedAtMs = Number.isFinite(motionStartedAtMs)
        && !Number.isFinite(detail.motionStartedAtMs)
    if (!historyMutation && !needsMotionStartedAtMs) return detail
    const ownedDetail = needsMotionStartedAtMs
        ? { ...detail, motionStartedAtMs }
        : { ...detail }
    if (!historyMutation) return ownedDetail
    const { source, mutationID, requestGeneration } = historyMutation
    if (
        ownedDetail.explicitRelocateHistorySource === source
        && ownedDetail.explicitRelocateHistoryMutationID === mutationID
        && (
            requestGeneration == null
            || ownedDetail.explicitRelocateHistoryRequestGeneration === requestGeneration
        )
    ) {
        return ownedDetail
    }
    return {
        ...ownedDetail,
        explicitRelocateHistorySource: source,
        explicitRelocateHistoryMutationID: mutationID,
        ...(requestGeneration == null
            ? {}
            : { explicitRelocateHistoryRequestGeneration: requestGeneration }),
    }
}

export const isReaderOperationCurrent = ({
    activeReader = null,
    expectedReader = null,
    activeLoadToken = null,
    expectedLoadToken = null,
    activeOperationGeneration = null,
    expectedOperationGeneration = null,
    activeRenderer = undefined,
    expectedRenderer = undefined,
} = {}) => {
    if (!expectedReader || activeReader !== expectedReader) return false
    if (activeLoadToken !== expectedLoadToken) return false
    if (expectedRenderer !== undefined && activeRenderer !== expectedRenderer) return false
    return expectedOperationGeneration == null
        || activeOperationGeneration === expectedOperationGeneration
}


export const shouldRejectReaderPageTurnQueue = ({
    ignoreIfPageTurnInFlight = false,
    details = {},
} = {}) => (
    ignoreIfPageTurnInFlight === true
    || details.rejectReaderQueue === true
    || details.lookupOwnedPageTurn === true
    || details.nativeLookupSuppressionOwned === true
    || details.rendererGestureOwnedPageTurn === true
)

export const readerPhysicalPagePositionChanged = (before, after) => {
    if (!before || !after) return null
    const comparablePairs = [
        [before.index, after.index],
        [before.sectionIndex, after.sectionIndex],
        [before.page, after.page],
    ].filter(([first, second]) => Number.isFinite(first) && Number.isFinite(second))
    if (comparablePairs.some(([first, second]) => first !== second)) return true
    if (Number.isFinite(before.start) && Number.isFinite(after.start)) {
        return Math.abs(after.start - before.start) >= 1
    }
    return comparablePairs.length > 0 ? false : null
}

export const shouldRunDelayedReaderPageAdvance = ({
    before = null,
    after = null,
    pageTurnInFlight = false,
    ownedNavigationInFlight = false,
} = {}) => (
    pageTurnInFlight !== true
    && ownedNavigationInFlight !== true
    && readerPhysicalPagePositionChanged(before, after) === false
)

const finitePositiveNumber = value => {
    const number = Number(value)
    return Number.isFinite(number) && number > 0 ? number : null
}

export const resolveReaderFrameScale = ({
    frameWidth = null,
    frameHeight = null,
    localViewportWidth = null,
    localViewportHeight = null,
} = {}) => {
    const resolvedFrameWidth = finitePositiveNumber(frameWidth)
    const resolvedFrameHeight = finitePositiveNumber(frameHeight)
    const resolvedLocalWidth = finitePositiveNumber(localViewportWidth)
    const resolvedLocalHeight = finitePositiveNumber(localViewportHeight)
    if (
        resolvedFrameWidth === null
        || resolvedFrameHeight === null
        || resolvedLocalWidth === null
        || resolvedLocalHeight === null
    ) {
        return null
    }
    const scaleX = resolvedFrameWidth / resolvedLocalWidth
    const scaleY = resolvedFrameHeight / resolvedLocalHeight
    if (!Number.isFinite(scaleX) || !Number.isFinite(scaleY) || scaleX <= 0 || scaleY <= 0) {
        return null
    }
    return { scaleX, scaleY }
}

const geometrySignatureNumber = value => {
    const number = Number(value)
    return Number.isFinite(number) ? Math.round(number * 1000) / 1000 : 'nil'
}

export const nativeLookupViewportGeometrySignature = (geometry = {}) => {
    const rectValues = rect => [
        rect?.left,
        rect?.top,
        rect?.width,
        rect?.height,
    ].map(geometrySignatureNumber)
    const boundsValues = bounds => [
        bounds?.left,
        bounds?.top,
        bounds?.right,
        bounds?.bottom,
    ].map(geometrySignatureNumber)
    return [
        geometry.hasUsableViewportGeometry === true ? 'ready' : 'unavailable',
        geometry.hasExpectedPaginatorContainer === true ? 'paginator' : 'frame',
        geometrySignatureNumber(geometry.viewportLeft),
        geometrySignatureNumber(geometry.viewportTop),
        geometrySignatureNumber(geometry.viewportWidth),
        geometrySignatureNumber(geometry.viewportHeight),
        geometrySignatureNumber(geometry.localViewportWidth),
        geometrySignatureNumber(geometry.localViewportHeight),
        geometrySignatureNumber(geometry.frameScaleX),
        geometrySignatureNumber(geometry.frameScaleY),
        ...rectValues(geometry.frameRect),
        ...rectValues(geometry.containerRect),
        ...boundsValues(geometry.visibleBounds),
    ].join(':')
}

export const activeRendererContents = ({ contents = [], currentIndex = null } = {}) => {
    const normalizedContents = Array.isArray(contents) ? contents.filter(Boolean) : []
    const hasExplicitVisibility = normalizedContents.some(
        content => typeof content?.isVisible === 'boolean'
    )
    if (hasExplicitVisibility) {
        return normalizedContents.filter(content => content?.isVisible === true)
    }
    return Number.isFinite(currentIndex)
        ? normalizedContents.filter(content =>
            !Number.isFinite(content?.index) || content.index === currentIndex)
        : normalizedContents
}

export const authoritativeNativeLookupTargetCount = ({
    hasUsableViewportGeometry = false,
    visibleSegmentCount,
    targetCount,
} = {}) => {
    // Zero visible segments is authoritative only after the destination frame
    // has a measurable viewport. Before layout, the same 0/0 shape means
    // "not collected yet", not "this page has no lookup targets".
    if (hasUsableViewportGeometry !== true) return null
    if (!Number.isInteger(visibleSegmentCount) || visibleSegmentCount < 0) return null
    if (!Number.isInteger(targetCount) || targetCount < 0) return null
    return targetCount === visibleSegmentCount ? targetCount : null
}

export const mapContentRectToReaderViewport = ({
    rect = null,
    frameLeft = 0,
    frameTop = 0,
    frameScaleX = 1,
    frameScaleY = 1,
} = {}) => {
    const values = [
        rect?.left,
        rect?.top,
        rect?.width,
        rect?.height,
        frameLeft,
        frameTop,
        frameScaleX,
        frameScaleY,
    ]
    if (!values.every(Number.isFinite) || rect.width <= 0 || rect.height <= 0) return null
    if (frameScaleX <= 0 || frameScaleY <= 0) return null
    return {
        left: frameLeft + rect.left * frameScaleX,
        top: frameTop + rect.top * frameScaleY,
        width: rect.width * frameScaleX,
        height: rect.height * frameScaleY,
    }
}

export const nativeLookupTargetPostNeedsRetry = result => (
    !Number.isInteger(result?.nativeLookupTargetCount)
    || result.nativeLookupTargetCount < 0
)

export const nativeLookupTargetResultsNeedRetry = results => {
    const normalizedResults = Array.isArray(results) ? results : []
    return normalizedResults.length === 0
        || normalizedResults.some(nativeLookupTargetPostNeedsRetry)
}

export const shouldInvalidateVisibleSegmentGeometryForReason = (sourceReason = 'unspecified') => {
    const reason = String(sourceReason || 'unspecified')
    return reason === 'page-turn-start'
        || reason === 'page-turn-swipe-intent'
        || reason === 'document-load'
        || reason === 'font-family-change'
        || reason === 'font-family-change-child'
        || reason === 'font-size-change'
        || reason === 'font-size-change-child'
        || reason === 'layout-change'
        || reason === 'writing-direction-change'
        || reason.includes('resize')
        || reason.includes('orientation')
        || reason.includes('renderer.goTo')
        || reason.includes('renderer.relocate')
        || reason.includes('navigation')
}

export const classifyPageTurnMovement = result => {
    if (result === true || result?.moved === true) {
        return { moved: true, authoritative: true }
    }
    if (
        result === false
        || result?.moved === false
        || result?.ignored === true
        || result?.failed === true
        || result?.superseded === true
    ) {
        return { moved: false, authoritative: true }
    }
    return { moved: null, authoritative: false }
}

export const makeOwnedNavigationIntent = ({
    intent = {},
    requestGeneration = null,
    explicitRelocateHistorySource = null,
    explicitRelocateHistoryMutationID = null,
} = {}) => {
    const baseIntent = intent && typeof intent === 'object' ? intent : {}
    const source = typeof explicitRelocateHistorySource === 'string'
        ? explicitRelocateHistorySource.trim()
        : ''
    if (!source || !Number.isInteger(requestGeneration) || requestGeneration < 1) {
        return baseIntent
    }
    const requestedMutationID = typeof explicitRelocateHistoryMutationID === 'string'
        ? explicitRelocateHistoryMutationID.trim()
        : ''
    return Object.freeze({
        ...baseIntent,
        explicitRelocateHistorySource: source,
        explicitRelocateHistoryMutationID: requestedMutationID
            || `reader-navigation-${requestGeneration}`,
        explicitRelocateHistoryRequestGeneration: requestGeneration,
    })
}

export const readerRelocationDetailForCurrentOwnedNavigation = ({
    detail = null,
    currentRequestGeneration = null,
} = {}) => {
    if (!detail || typeof detail !== 'object') return detail
    const requestGeneration = detail.explicitRelocateHistoryRequestGeneration
    if (!Number.isInteger(requestGeneration)) return detail
    if (requestGeneration === currentRequestGeneration) return detail
    const currentDetail = { ...detail }
    delete currentDetail.explicitRelocateHistorySource
    delete currentDetail.explicitRelocateHistoryMutationID
    delete currentDetail.explicitRelocateHistoryRequestGeneration
    return currentDetail
}

export class NavigationIntentCoordinator {
    #active = []

    begin(intent) {
        const entry = Object.freeze({
            intent: snapshotReaderNavigationIntent(intent) ?? Object.freeze({}),
            token: Object.freeze({}),
        })
        this.#active.push(entry)
        return entry
    }

    has(entry) {
        return this.#active.includes(entry)
    }

    end(entry) {
        const index = this.#active.indexOf(entry)
        if (index < 0) return false
        this.#active.splice(index, 1)
        return true
    }

    get current() {
        return this.#active.at(-1)?.intent ?? null
    }

    get size() {
        return this.#active.length
    }
}

export class PageTurnInvalidationCoordinator {
    #nextGeneration = 0
    #pending = new Map()

    begin(owner, payload = null) {
        const token = Object.freeze({
            generation: ++this.#nextGeneration,
            owner: String(owner ?? 'unknown'),
        })
        this.#pending.set(token.generation, { token, payload })
        return token
    }

    has(token) {
        const entry = token && this.#pending.get(token.generation)
        return entry?.token === token && entry.token.owner === token.owner
    }

    commit(token) {
        if (!this.has(token)) return null
        const entry = this.#pending.get(token.generation)
        this.#pending.delete(token.generation)
        return entry?.payload ?? null
    }

    settle(token) {
        return this.commit(token)
    }

    get size() {
        return this.#pending.size
    }
}

export class PageTurnAttemptCoordinator {
    #attempts = new Map()

    adopt(attemptID, metadata = {}) {
        const normalizedID = typeof attemptID === 'string' && attemptID.length > 0
            ? attemptID
            : null
        if (!normalizedID) return null
        const existing = this.#attempts.get(normalizedID)
        const hasExistingToken = existing
            && Object.hasOwn(existing, 'lookupNavigationToken')
        const hasIncomingToken = Object.hasOwn(metadata, 'lookupNavigationToken')
        const motionStartedAtMs = Number.isFinite(existing?.motionStartedAtMs)
            ? existing.motionStartedAtMs
            : metadata.motionStartedAtMs
        const next = {
            ...(existing ?? {}),
            ...metadata,
            // Ownership and causality are fixed by the first adoption. Later
            // stages may add status fields such as `ignored`, but they must not
            // rebind an in-flight attempt to whichever lookup/token is current
            // when a duplicate callback arrives.
            attemptID: normalizedID,
        }
        if (hasExistingToken || hasIncomingToken) {
            next.lookupNavigationToken = hasExistingToken
                ? existing.lookupNavigationToken
                : metadata.lookupNavigationToken
        }
        if (Number.isFinite(motionStartedAtMs)) {
            next.motionStartedAtMs = motionStartedAtMs
        } else {
            delete next.motionStartedAtMs
        }
        this.#attempts.set(normalizedID, next)
        return next
    }

    has(attemptID) {
        return this.#attempts.has(attemptID)
    }

    metadata(attemptID) {
        return this.#attempts.get(attemptID) ?? null
    }

    complete(attemptID) {
        const entry = this.#attempts.get(attemptID) ?? null
        if (entry) this.#attempts.delete(attemptID)
        return entry
    }

    drain() {
        const entries = [...this.#attempts.values()]
        this.#attempts.clear()
        return entries
    }

}

// Reader and renderer work routinely crosses animation frames, iframe loads,
// and native bridge callbacks. A monotonically increasing generation provides
// one inexpensive ownership check for every delayed continuation. Invalidating
// a lifecycle also aborts work that is still waiting on an explicit signal.
export class LifecycleGenerationCoordinator {
    #generation = 0
    #controller = null

    begin() {
        this.#controller?.abort()
        this.#controller = new AbortController()
        return Object.freeze({
            generation: ++this.#generation,
            signal: this.#controller.signal,
        })
    }

    invalidate() {
        this.#controller?.abort()
        this.#controller = null
        this.#generation += 1
    }

    isCurrent(token) {
        return Number.isInteger(token?.generation)
            && token.generation === this.#generation
            && token.signal?.aborted !== true
    }

    get generation() {
        return this.#generation
    }
}

// A renderer instance owns at most one publication. Reader/View teardown may
// leave delayed callbacks or diagnostic code holding the renderer object, so a
// destroyed instance must never create a fresh lifecycle and acquire section
// resources again. Keeping this tiny state machine shared also prevents the
// paginator and fixed-layout renderers from drifting to different contracts.
export class SinglePublicationRendererLifetime {
    #state = 'idle'

    claimOpen() {
        if (this.#state !== 'idle') return false
        this.#state = 'open'
        return true
    }

    destroy() {
        if (this.#state === 'destroyed') return false
        this.#state = 'destroyed'
        return true
    }

    get isOpen() {
        return this.#state === 'open'
    }

    get isDestroyed() {
        return this.#state === 'destroyed'
    }
}

// Section loads acquire archive/blob resources asynchronously. The owning renderer
// may be destroyed before the load resolves, so cleanup must follow the exact
// acquisition rather than consulting a mutable spine index. This lease records
// an early release request and performs the matching unload exactly once when
// the acquisition eventually succeeds.
export class SectionResourceLease {
    #section
    #state = 'pending'
    #releaseRequested = false

    constructor(section) {
        this.#section = section ?? null
    }

    markLoaded() {
        if (this.#state !== 'pending') return false
        this.#state = 'loaded'
        if (this.#releaseRequested) this.#releaseLoadedSection()
        return true
    }

    markFailed() {
        if (this.#state !== 'pending') return false
        this.#state = 'failed'
        this.#section = null
        return true
    }

    release() {
        if (this.#state === 'released' || this.#state === 'failed') return false
        if (this.#state === 'pending') {
            this.#releaseRequested = true
            return false
        }
        return this.#releaseLoadedSection()
    }

    #releaseLoadedSection() {
        if (this.#state !== 'loaded') return false
        this.#state = 'released'
        const section = this.#section
        this.#section = null
        try {
            section?.unload?.()
        } catch (error) {
            console.error(error)
        }
        return true
    }
}

// Renderer navigation mutates shared section, view, resource, and location
// state. Allow one operation to own that state at a time, while coalescing a
// burst of waiting requests to the most recent destination. The active
// operation is not force-cancelled here; its owning lifecycle remains
// responsible for aborting source work safely.
export class LatestSerialOperationCoordinator {
    #active = null
    #queued = null
    #nextID = 0

    #cancelledResult(entry, reason) {
        return {
            executed: false,
            cancelled: true,
            reason: String(reason ?? 'cancelled'),
            operationID: entry?.operationID ?? null,
        }
    }

    #resolveQueuedAsCancelled(reason) {
        const queued = this.#queued
        this.#queued = null
        if (!queued) return false
        queued.cancelled = true
        queued.cancelReason = String(reason ?? 'cancelled')
        queued.resolve(this.#cancelledResult(queued, queued.cancelReason))
        return true
    }

    #finish(entry) {
        if (this.#active === entry) this.#active = null
        const queued = this.#queued
        this.#queued = null
        if (queued) this.#start(queued)
    }

    #start(entry) {
        this.#active = entry
        void Promise.resolve()
            .then(entry.operation)
            .then(
                value => {
                    const result = entry.cancelled
                        ? this.#cancelledResult(entry, entry.cancelReason)
                        : {
                            executed: true,
                            cancelled: false,
                            operationID: entry.operationID,
                            value,
                        }
                    this.#finish(entry)
                    entry.resolve(result)
                },
                error => {
                    const cancelled = entry.cancelled
                    const result = cancelled
                        ? this.#cancelledResult(entry, entry.cancelReason)
                        : null
                    this.#finish(entry)
                    if (cancelled) entry.resolve(result)
                    else entry.reject(error)
                },
            )
    }

    run(operation) {
        if (typeof operation !== 'function') {
            return Promise.resolve({
                executed: false,
                cancelled: false,
                reason: 'missingOperation',
                operationID: null,
            })
        }
        return new Promise((resolve, reject) => {
            const entry = {
                operationID: ++this.#nextID,
                operation,
                resolve,
                reject,
                cancelled: false,
                cancelReason: null,
            }
            if (this.#active) {
                this.#resolveQueuedAsCancelled('superseded')
                this.#queued = entry
                return
            }
            this.#start(entry)
        })
    }

    cancel(reason = 'cancelled') {
        const normalizedReason = String(reason ?? 'cancelled')
        this.#resolveQueuedAsCancelled(normalizedReason)
        if (this.#active) {
            this.#active.cancelled = true
            this.#active.cancelReason = normalizedReason
        }
    }

    get busy() {
        return this.#active !== null || this.#queued !== null
    }
}

export const scheduleTask = (schedule, task, onError = null) => new Promise((resolve) => {
    let invoked = false
    let settled = false
    const settle = () => {
        if (settled) return
        settled = true
        resolve()
    }
    const report = error => {
        if (typeof onError !== 'function') return
        try {
            onError(error)
        } catch (_) {}
    }
    const run = () => {
        if (invoked) return
        invoked = true
        Promise.resolve()
            .then(task)
            .catch(report)
            .finally(settle)
    }
    try {
        schedule(run)
    } catch (error) {
        report(error)
        if (!invoked) settle()
    }
})

export class AsyncTaskBarrier {
    #pending = new Set()

    add(task) {
        const promise = Promise.resolve(task)
        this.#pending.add(promise)
        promise.finally(() => this.#pending.delete(promise)).catch(() => {})
        return promise
    }

    async wait() {
        // Tasks may enqueue more tasks while settling. Drain to a fixed point.
        while (this.#pending.size > 0) {
            await Promise.allSettled([...this.#pending])
        }
    }

    get size() {
        return this.#pending.size
    }
}
