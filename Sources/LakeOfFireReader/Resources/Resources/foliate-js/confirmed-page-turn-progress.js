import { makeSyntheticRestoreLocator } from './ebook-restore-coordination.js'
import { PAGE_TURN_MOVEMENT_DISPOSITION } from './page-turn-coordination.js'

export const shouldRequestConfirmedPageTurnProgress = movementDisposition =>
    movementDisposition === PAGE_TURN_MOVEMENT_DISPOSITION.moved

export const confirmedPageTurnProgressDecision = ({
    closed = false,
    hasLoadedLastPosition = false,
    restoreInProgress = false,
    requiresUserInput = false,
    location = null,
    currentDocumentURL = null,
    currentSectionIndex = null,
    sectionBaseCFI = null,
    rendererLocalName = null,
    localSectionIndex = null,
    rendererTotal = null,
    priorObservation = null,
    cfiAlreadyUnstable = false,
} = {}) => {
    if (closed) return { shouldPost: false, reason: 'closed' }
    if (!hasLoadedLastPosition) return { shouldPost: false, reason: 'position-not-loaded' }
    if (restoreInProgress) return { shouldPost: false, reason: 'restore-in-progress' }
    if (requiresUserInput) return { shouldPost: false, reason: 'requires-user-input' }

    const fraction = location?.fraction
    const cfi = location?.cfi
    const sectionIndex = typeof location?.sectionIndex === 'number'
        ? location.sectionIndex
        : (typeof location?.index === 'number' ? location.index : null)
    const progressReason = typeof location?.reason === 'string'
        ? location.reason
        : 'page'
    if (!Number.isFinite(fraction)) return { shouldPost: false, reason: 'invalid-fraction' }
    if (typeof cfi !== 'string' || cfi.length === 0) {
        return { shouldPost: false, reason: 'invalid-cfi' }
    }
    if (typeof sectionIndex !== 'number') {
        return { shouldPost: false, reason: 'invalid-section' }
    }
    if (progressReason.trim().toLowerCase() === 'anchor') {
        return { shouldPost: false, reason: 'anchor' }
    }
    if (typeof currentDocumentURL !== 'string' || currentDocumentURL.length === 0) {
        return { shouldPost: false, reason: 'missing-document' }
    }
    if (currentSectionIndex !== sectionIndex) {
        return { shouldPost: false, reason: 'section-mismatch' }
    }

    const hasPageScopedObservation = typeof localSectionIndex === 'number'
    const observedOnDifferentPage = hasPageScopedObservation
        && priorObservation?.cfi === cfi
        && (
            priorObservation.sectionIndex !== sectionIndex
            || priorObservation.localSectionIndex !== localSectionIndex
        )
    const cfiIsUnstableAcrossPages = cfiAlreadyUnstable || observedOnDifferentPage
    const nextObservation = hasPageScopedObservation
        ? { cfi, sectionIndex, localSectionIndex, rendererTotal }
        : null
    const syntheticRestoreLocator = makeSyntheticRestoreLocator({
        sectionIndex,
        localSectionIndex,
        rendererTotal,
    })
    const shouldPreferSyntheticRestoreLocator = !!syntheticRestoreLocator
        && rendererLocalName === 'foliate-paginator'
        && (cfi === sectionBaseCFI || cfiIsUnstableAcrossPages)

    return {
        shouldPost: true,
        fraction,
        cfi,
        sectionIndex,
        progressReason,
        currentDocumentURL,
        persistedLocator: shouldPreferSyntheticRestoreLocator
            ? syntheticRestoreLocator
            : cfi,
        nextObservation,
        markCFIUnstable: observedOnDifferentPage,
    }
}
