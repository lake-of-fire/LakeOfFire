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
    return Number.isFinite(fractionalCompletion) && fractionalCompletion > 0 ? 'fraction' : 'none'
}

export const normalizeInitialRestoreRequest = value => {
    if (!value || typeof value !== 'object') return null

    const requestID = typeof value.requestID === 'string' ? value.requestID.trim() : ''
    const cfi = typeof value.cfi === 'string' ? value.cfi : ''
    const fractionalCompletion = Number.isFinite(value.fractionalCompletion)
        && value.fractionalCompletion > 0
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

export const makeInitialRestoreTerminalResult = ({ request, snapshot, error = null }) => {
    const navigationOk = error == null
    const currentFractionalCompletion = Number.isFinite(snapshot?.currentFractionalCompletion)
        ? snapshot.currentFractionalCompletion
        : null
    const handledFractionalCompletion = Number.isFinite(snapshot?.handledFractionalCompletion)
        ? snapshot.handledFractionalCompletion
        : null
    const handledCFI = typeof snapshot?.handledCFI === 'string' && snapshot.handledCFI.length > 0
        ? snapshot.handledCFI
        : null

    return {
        requestID: request?.requestID ?? null,
        requestedLocator: request?.requestedLocator ?? 'none',
        terminalState: request ? (navigationOk ? 'satisfied' : 'failed') : 'noTarget',
        navigationOk,
        restoreSatisfied: request != null && navigationOk,
        handledFractionalCompletion,
        currentFractionalCompletion,
        handledCFI,
        error: error == null ? null : String(error?.message ?? error),
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
