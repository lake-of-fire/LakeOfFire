export const PAGE_TURN_MOVEMENT_DISPOSITION = Object.freeze({
    moved: 'moved',
    noMove: 'no-move',
    notOwned: 'not-owned',
    unknown: 'unknown',
})

const validDispositions = new Set(Object.values(PAGE_TURN_MOVEMENT_DISPOSITION))
const validDisposition = value => validDispositions.has(value)

export const pageTurnMovementDisposition = result => {
    const explicitDisposition = result?.movementDisposition
    if (validDisposition(explicitDisposition)) return explicitDisposition
    if (result === true || result?.moved === true) {
        return PAGE_TURN_MOVEMENT_DISPOSITION.moved
    }
    if (result === false || result?.authoritativeNoMove === true) {
        return PAGE_TURN_MOVEMENT_DISPOSITION.noMove
    }
    if (result?.ignored === true || result?.superseded === true) {
        return PAGE_TURN_MOVEMENT_DISPOSITION.notOwned
    }
    return PAGE_TURN_MOVEMENT_DISPOSITION.unknown
}

export const observedPageTurnMovementDisposition = ({
    moveResult,
    immediatePositionChanged = null,
    settledPositionChanged = null,
} = {}) => {
    const receiptDisposition = pageTurnMovementDisposition(moveResult)
    if (receiptDisposition !== PAGE_TURN_MOVEMENT_DISPOSITION.unknown) {
        return receiptDisposition
    }
    return immediatePositionChanged === true || settledPositionChanged === true
        ? PAGE_TURN_MOVEMENT_DISPOSITION.moved
        : PAGE_TURN_MOVEMENT_DISPOSITION.unknown
}
