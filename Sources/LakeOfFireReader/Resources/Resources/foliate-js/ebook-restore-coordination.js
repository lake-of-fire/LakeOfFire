const RESTORE_LOCATOR_PREFIX = 'mnb-loc-v1:'

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
