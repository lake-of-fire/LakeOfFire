const historyActionKind = 'ebook-history-action-v1'

// The native controls retain this value between a HUD publication and a tap.
// Never lend a replacement load's token to an old or not-yet-installed HUD.
export const captureEbookHistoryActionContext = (host, reader, navHUD) => {
    if (!reader || host?.reader !== reader || reader.isClosed === true
        || !navHUD || reader.navHUD !== navHUD || navHUD.destroyed === true
        || !reader.view?.renderer) return null

    const loadToken = host.manabiLoadEBookToken
    const loadURL = host.manabiLoadEBookURL
    if (!Number.isSafeInteger(loadToken) || loadToken <= 0
        || typeof loadURL !== 'string' || loadURL.length === 0) return null

    return Object.freeze({
        kind: historyActionKind,
        loadToken: String(loadToken),
        loadURL,
    })
}

export const ebookHistoryActionContextIsCurrent = (expected, host, reader, navHUD) => {
    if (!expected || typeof expected !== 'object' || Array.isArray(expected)) return false
    const current = captureEbookHistoryActionContext(host, reader, navHUD)
    return current !== null
        && expected.kind === current.kind
        && expected.loadToken === current.loadToken
        && expected.loadURL === current.loadURL
}
