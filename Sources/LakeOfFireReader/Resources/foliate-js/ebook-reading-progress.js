const clampedFiniteFraction = value => {
    if (typeof value !== 'number' || !Number.isFinite(value)) return null
    return Math.max(0, Math.min(1, value))
}

export const ebookProgressFractionForRelocate = ({
    relocateFraction,
    authoritativeFraction,
}) => clampedFiniteFraction(relocateFraction) ?? clampedFiniteFraction(authoritativeFraction)

// Shared by the actual Reader relocation path and its navigation regressions.
// Completing an attempt alone never authorizes position persistence.
export const ebookRelocatePersistenceDecision = ({
    hasLoadedLastPosition,
    restoreInProgress,
    suppressNextRestoreRelocateSave,
    requireUserInputBeforePositionSave,
    reason,
}) => {
    const canAttempt = !!hasLoadedLastPosition && !restoreInProgress
    const normalizedReason = typeof reason === 'string' ? reason.trim().toLowerCase() : ''
    const clearSuppression = canAttempt && suppressNextRestoreRelocateSave === true
        && normalizedReason === 'page'
    return {
        clearSuppression,
        shouldPersist: canAttempt && normalizedReason !== 'anchor' && !clearSuppression
            && requireUserInputBeforePositionSave !== true,
    }
}

// Retain the producer's exact relocation across HUD work and delayed native
// delivery. A later position on this same View is a different publication.
export const captureEbookRelocatePublication = ({ reader, view, detail, getCurrentReader }) => {
    const renderer = view?.renderer
    const book = view?.book
    const isCurrent = () => !!reader && reader.isClosed !== true
        && getCurrentReader() === reader && reader.view === view
        && view?.renderer === renderer && view?.book === book
        && view?.lastLocation === detail
    if (!renderer || !detail || !isCurrent()) return null
    return Object.freeze({
        renderer,
        isCurrent,
        publishIfCurrent(operation) {
            if (!isCurrent()) return false
            operation()
            return true
        },
    })
}
