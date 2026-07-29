const normalizedString = value => (
    typeof value === 'string' && value.length > 0 ? value : null
)

export const normalizeReaderPresentationState = (settings = null) => {
    if (!settings || typeof settings !== 'object') return null
    const readerFontSize = Number(settings.readerFontSize)
    const resolvedFontSize = Number.isFinite(readerFontSize) && readerFontSize > 0
        ? readerFontSize
        : null
    const readerContentRTSize = Number(settings.readerContentRTSize)
    const resolvedRTSize = Number.isFinite(readerContentRTSize) && readerContentRTSize > 0
        ? readerContentRTSize
        : (resolvedFontSize ? resolvedFontSize * 0.46 : null)
    const writingDirection = ['original', 'horizontal', 'vertical'].includes(settings.writingDirection)
        ? settings.writingDirection
        : 'original'

    return {
        colorScheme: settings.colorScheme === 'dark' || settings.colorScheme === 'light'
            ? settings.colorScheme
            : null,
        lightModeTheme: normalizedString(settings.lightModeTheme),
        darkModeTheme: normalizedString(settings.darkModeTheme),
        readerFontSize: resolvedFontSize,
        readerContentRTSize: resolvedRTSize,
        readerFontSizeCSS: resolvedFontSize ? `${resolvedFontSize}px` : null,
        readerContentRTSizeCSS: resolvedRTSize ? `${resolvedRTSize}px` : null,
        readerBoldText: settings.readerBoldText === true,
        maxWidthOverride: normalizedString(settings.maxWidthOverride),
        writingDirection,
    }
}

export const applyReaderPresentationStateToDocument = (
    doc,
    settings,
    reason = 'unknown',
) => {
    const normalized = normalizeReaderPresentationState(settings)
    const body = doc?.body
    if (!normalized || !body) return false
    const root = doc.documentElement
    const signature = JSON.stringify(normalized)
    if (body.dataset.mnbReaderPresentationStateSignature === signature) {
        return false
    }

    if (normalized.colorScheme) {
        body.dataset.mnbColorScheme = normalized.colorScheme
        root?.style?.setProperty?.('color-scheme', normalized.colorScheme)
        body.style?.setProperty?.('color-scheme', normalized.colorScheme)
    }
    if (normalized.lightModeTheme) {
        body.dataset.mnbLightTheme = normalized.lightModeTheme
    }
    if (normalized.darkModeTheme) {
        body.dataset.mnbDarkTheme = normalized.darkModeTheme
    }
    if (normalized.readerFontSizeCSS) {
        body.style.setProperty('font-size', normalized.readerFontSizeCSS)
        body.style.setProperty('--mnb-reader-content-font-size', normalized.readerFontSizeCSS)
        root?.style?.setProperty?.('--mnb-reader-content-font-size', normalized.readerFontSizeCSS)
    }
    if (normalized.readerContentRTSizeCSS) {
        body.style.setProperty('--mnb-reader-content-rt-size', normalized.readerContentRTSizeCSS)
        root?.style?.setProperty?.('--mnb-reader-content-rt-size', normalized.readerContentRTSizeCSS)
    }
    if (normalized.readerBoldText) {
        body.style.setProperty('font-weight', '600')
    } else {
        body.style.removeProperty('font-weight')
    }
    if (normalized.maxWidthOverride) {
        body.style.setProperty('--mnb-reader-max-width-override', normalized.maxWidthOverride)
        root?.style?.setProperty?.('--mnb-reader-max-width-override', normalized.maxWidthOverride)
    }
    body.dataset.mnbReaderPresentationStateSignature = signature
    body.dataset.mnbReaderPresentationStateReason = reason
    return true
}

export const installReaderPresentationState = (
    globalObject,
    doc,
    settings,
    reason = 'unknown',
) => {
    const normalized = normalizeReaderPresentationState(settings)
    if (!normalized) return null
    globalObject.__manabiReaderPresentationState = normalized
    if (normalized.colorScheme) globalObject.manabiReaderColorScheme = normalized.colorScheme
    if (normalized.lightModeTheme) globalObject.manabiReaderLightModeTheme = normalized.lightModeTheme
    if (normalized.darkModeTheme) globalObject.manabiReaderDarkModeTheme = normalized.darkModeTheme
    if (normalized.readerFontSizeCSS) globalObject.manabiReaderFontSizeCSS = normalized.readerFontSizeCSS
    if (normalized.maxWidthOverride) globalObject.manabiReaderMaxWidthOverride = normalized.maxWidthOverride
    globalObject.manabiEbookViewerWritingDirection = normalized.writingDirection
    applyReaderPresentationStateToDocument(doc, normalized, reason)
    return normalized
}
