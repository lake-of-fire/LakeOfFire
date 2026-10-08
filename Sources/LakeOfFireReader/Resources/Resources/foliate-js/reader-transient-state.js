const readerTransientDefaults = Object.freeze({
    __manabiPreserveHiddenNavigationThroughNextDisplay: false,
    __manabiIgnoreNextIncomingHideNavigationCount: 0,
    __manabiIgnoreNextIncomingRevealNavigationCount: 0,
    __manabiLastForwardPageTurnHideAtMs: 0,
    __manabiLastBackwardPageTurnRevealAtMs: 0,
    __manabiLastExplicitNavigationRevealAtMs: 0,
    __manabiPendingContentDocumentBlankNavigationEcho: null,
    __manabiObservedBookWritingDirection: null,
    __manabiObservedBookWritingMode: null,
})

export const resetReaderTransientState = (
    target = globalThis,
    { owner = null, currentOwner = owner } = {},
) => {
    if (!target || (owner && currentOwner !== owner)) return false
    for (const [key, value] of Object.entries(readerTransientDefaults)) {
        target[key] = value
    }
    return true
}
