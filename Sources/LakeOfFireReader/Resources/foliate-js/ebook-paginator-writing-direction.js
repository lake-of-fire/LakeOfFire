const sourceAttributesByDocument = new WeakMap()
const writingDirectionOverrideStyleByDocument = new WeakMap()
const writingDirectionOverrideStyleIdentifier = 'mnb-paginator-writing-direction-override'
const sourceDirectionAttributeNames = [
    'data-mnb-writing-direction',
    'data-mnb-foliate-writing-direction',
    'data-mnb-foliate-writing-mode',
]

export const normalizePaginatorWritingDirection = value => {
    if (value === 'horizontal' || value === 'vertical') return value
    return 'original'
}

export const applyPaginatorWritingDirectionOverride = (doc, value) => {
    const body = doc?.body
    if (!body) return 'original'
    if (!sourceAttributesByDocument.has(doc)) {
        sourceAttributesByDocument.set(
            doc,
            new Map(sourceDirectionAttributeNames.map(name => [
                name,
                body.getAttribute(name),
            ])),
        )
    }

    const writingDirection = normalizePaginatorWritingDirection(value)
    let overrideStyle = writingDirectionOverrideStyleByDocument.get(doc) ?? null
    if (writingDirection === 'original') {
        for (const [name, sourceValue] of sourceAttributesByDocument.get(doc)) {
            if (sourceValue == null) {
                body.removeAttribute(name)
            } else {
                body.setAttribute(name, sourceValue)
            }
        }
        overrideStyle?.remove?.()
        writingDirectionOverrideStyleByDocument.delete(doc)
    } else {
        body.setAttribute('data-mnb-writing-direction', writingDirection)
        if (!overrideStyle) {
            overrideStyle = doc.createElement?.('style') ?? null
            if (overrideStyle) {
                overrideStyle.id = writingDirectionOverrideStyleIdentifier
                const styleParent = doc.head ?? doc.documentElement
                styleParent?.appendChild?.(overrideStyle)
                writingDirectionOverrideStyleByDocument.set(doc, overrideStyle)
            }
        }
        if (overrideStyle) {
            const writingMode = writingDirection === 'vertical' ? 'vertical-rl' : 'horizontal-tb'
            overrideStyle.textContent =
                `html, body { writing-mode: ${writingMode} !important; }`
        }
    }
    return writingDirection
}

export const paginatorDirectionFromDocument = doc => {
    const body = doc?.body
    const documentElement = doc?.documentElement
    if (!body || !documentElement) return null

    const explicitDirection = (
        body.getAttribute('data-mnb-writing-direction')
        ?? body.getAttribute('data-mnb-foliate-writing-direction')
    )
        ?.trim?.()
        .toLowerCase?.() ?? null
    const hintedWritingMode = (
        body.getAttribute('data-mnb-writing-mode')
        ?? body.getAttribute('data-mnb-foliate-writing-mode')
    )
        ?.trim?.()
        .toLowerCase?.() ?? null
    const styleText = [
        body.getAttribute('style') ?? '',
        documentElement.getAttribute('style') ?? '',
        doc.getElementById?.('mnb-writing-direction-bootstrap')?.textContent ?? '',
    ].join(';')
    const writingModeMatch = styleText.match(/writing-mode\s*:\s*([^;]+)/i)
    const directionMatch = styleText.match(/(?:^|;)\s*direction\s*:\s*([^;]+)/i)
    let writingMode
    if (explicitDirection === 'horizontal') {
        writingMode = 'horizontal-tb'
    } else if (explicitDirection === 'vertical') {
        writingMode = hintedWritingMode === 'vertical-lr' ? 'vertical-lr' : 'vertical-rl'
    } else {
        writingMode = writingModeMatch?.[1]?.trim?.().toLowerCase?.() ?? null
        if (!writingMode && body.classList?.contains?.('reader-vertical-writing')) {
            writingMode = 'vertical-rl'
        }
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
