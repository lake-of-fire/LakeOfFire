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

export const restoreLocatorKind = ({ cfi, fractionalCompletion }) => {
    if (parseSyntheticRestoreLocator(cfi)) return 'synthetic'
    if (typeof cfi === 'string' && cfi.length > 0) return 'cfi'
    return Number.isFinite(fractionalCompletion) && fractionalCompletion >= 0
        && fractionalCompletion <= 1 ? 'fraction' : 'none'
}

export const normalizeInitialRestoreRequest = value => {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return null
    if (value.cfi != null && typeof value.cfi !== 'string') return null
    if (value.fractionalCompletion != null && !(Number.isFinite(value.fractionalCompletion)
        && value.fractionalCompletion >= 0 && value.fractionalCompletion <= 1)) return null

    const requestID = typeof value.requestID === 'string' ? value.requestID.trim() : ''
    const cfi = typeof value.cfi === 'string' ? value.cfi : ''
    const fractionalCompletion = Number.isFinite(value.fractionalCompletion)
        && value.fractionalCompletion >= 0
        && value.fractionalCompletion <= 1
        ? value.fractionalCompletion
        : null
    const requestedLocator = cfi.length > 0 ? 'cfi' : (fractionalCompletion != null ? 'fraction' : 'none')

    if (requestID.length === 0 || requestedLocator === 'none') return null
    return {
        requestID,
        requestedLocator,
        cfi,
        fractionalCompletion,
    }
}

// Adapted from Core v3-hotfix EBookInitialRestoreCoordinator. Preserve the
// request-correlated main protocol instead of adding a second restore owner.
export const restoreFractionValidationTolerance = 0.003

const validFraction = value => Number.isFinite(value) && value >= 0 && value <= 1

const restoredPositionMatches = (request, snapshot) => {
    if (!request) return false
    // Positive fractions follow the hotfix contract. An explicit fraction-zero
    // request also validates zero, for callers using the newer zero-locator API.
    const hasSavedFraction = validFraction(request.fractionalCompletion)
        && (request.fractionalCompletion > 0 || request.requestedLocator === 'fraction')
    if (hasSavedFraction) {
        return [snapshot.handledFractionalCompletion, snapshot.currentFractionalCompletion]
            .every(value => validFraction(value)
                && Math.abs(value - request.fractionalCompletion) <= restoreFractionValidationTolerance)
    }
    return typeof request.cfi === 'string' && request.cfi.length > 0
        && snapshot.handledCFI === request.cfi
}

export const makeInitialRestoreTerminalResult = ({ request, snapshot, error = null }) => {
    const navigationOk = error == null
    const currentFractionalCompletion = validFraction(snapshot?.currentFractionalCompletion)
        ? snapshot.currentFractionalCompletion
        : null
    const handledFractionalCompletion = validFraction(snapshot?.handledFractionalCompletion)
        ? snapshot.handledFractionalCompletion
        : null
    const handledCFI = typeof snapshot?.handledCFI === 'string' && snapshot.handledCFI.length > 0
        ? snapshot.handledCFI
        : null

    const restoreSatisfied = navigationOk && restoredPositionMatches(request, {
        handledFractionalCompletion,
        currentFractionalCompletion,
        handledCFI,
    })
    const validationError = request && navigationOk && !restoreSatisfied
        ? 'Saved restore position was not reached'
        : null

    return {
        requestID: request?.requestID ?? null,
        requestedLocator: request?.requestedLocator ?? 'none',
        terminalState: request ? (restoreSatisfied ? 'satisfied' : 'failed') : 'noTarget',
        navigationOk,
        restoreSatisfied,
        handledFractionalCompletion,
        currentFractionalCompletion,
        handledCFI,
        error: error == null ? validationError : String(error?.message ?? error),
    }
}

export const shouldSkipScheduledReaderFractionGoTo = ({
    requiresUserInputBeforePositionSave,
    restoreSettlingMs,
}) => requiresUserInputBeforePositionSave === true
    && Number.isFinite(restoreSettlingMs)
    && restoreSettlingMs > 0

export const runRequiredRestoreNavigation = async operation => {
    try {
        const value = await operation()
        // View.goTo returns null when resolution failed or its renderer/command
        // was superseded. A fulfilled Promise alone is not a restore receipt.
        // Keep void success valid for existing renderer implementations.
        if (value === null || value === false || value?.ignored === true) {
            throw new Error('Required restore navigation was not applied')
        }
        return {
            ok: true,
            value,
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
