export const paginatorDirectionFromDocument = doc => {
    const body = doc?.body
    const documentElement = doc?.documentElement
    if (!body || !documentElement) return null

    const explicitDirection = body
        .getAttribute('data-mnb-writing-direction')
        ?.trim?.()
        .toLowerCase?.() ?? null
    const styleText = [
        body.getAttribute('style') ?? '',
        documentElement.getAttribute('style') ?? '',
        doc.getElementById?.('mnb-writing-direction-bootstrap')?.textContent ?? '',
    ].join(';')
    const writingModeMatch = styleText.match(/writing-mode\s*:\s*([^;]+)/i)
    const directionMatch = styleText.match(/(?:^|;)\s*direction\s*:\s*([^;]+)/i)
    let writingMode = writingModeMatch?.[1]?.trim?.().toLowerCase?.() ?? null
    if (!writingMode && (
        explicitDirection === 'vertical'
        || body.classList?.contains?.('reader-vertical-writing')
    )) {
        writingMode = 'vertical-rl'
    }
    if (!writingMode && explicitDirection === 'horizontal') {
        writingMode = 'horizontal-tb'
    }
    if (!writingMode) return null

    const direction = directionMatch?.[1]?.trim?.().toLowerCase?.() ?? null
    const vertical = writingMode === 'vertical-rl' || writingMode === 'vertical-lr'
    const verticalRTL = writingMode === 'vertical-rl'
    const rtl =
        body.dir === 'rtl'
        || documentElement.dir === 'rtl'
        || direction === 'rtl'
    return { vertical, verticalRTL, rtl, writingMode, direction }
}
