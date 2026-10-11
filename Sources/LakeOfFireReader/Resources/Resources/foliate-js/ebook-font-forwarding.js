const fontGeometryStates = new WeakMap()

export const copyCustomReaderFontStyleToDocument = (
    sourceFontStyle,
    doc,
    reason = 'unknown',
    fontFamilies = globalThis,
) => {
    if (!doc || !sourceFontStyle) return false

    let changed = false
    let targetFontStyle = doc.getElementById('mnb-custom-fonts-inline')
    const sourceTag = sourceFontStyle.tagName?.toLowerCase()
    const desiredTag = sourceTag === 'link' ? 'link' : 'style'
    if (targetFontStyle && targetFontStyle.tagName?.toLowerCase() !== desiredTag) {
        targetFontStyle.remove()
        targetFontStyle = null
        changed = true
    }
    if (!targetFontStyle) {
        targetFontStyle = doc.createElement(desiredTag)
        targetFontStyle.id = 'mnb-custom-fonts-inline'
        ;(doc.head || doc.documentElement).appendChild(targetFontStyle)
        changed = true
    }

    const writingDirection = doc.body?.dataset?.mnbWritingDirection
        || doc.body?.dataset?.mnbFoliateWritingDirection
        || null
    const isVerticalDocument = writingDirection === 'vertical'
        || doc.body?.classList?.contains?.('reader-vertical-writing') === true
    const directionalFamily = isVerticalDocument
        ? (fontFamilies.manabiVerticalFontFamilyName || sourceFontStyle.dataset?.mnbInjectedFontFamily)
        : (fontFamilies.manabiHorizontalFontFamilyName || sourceFontStyle.dataset?.mnbInjectedFontFamily)

    if (desiredTag === 'link') {
        const nextRel = sourceFontStyle.rel || 'stylesheet'
        if (targetFontStyle.rel !== nextRel) {
            targetFontStyle.rel = nextRel
            changed = true
        }
        if (targetFontStyle.href !== sourceFontStyle.href) {
            targetFontStyle.href = sourceFontStyle.href
            changed = true
        }
    } else {
        const nextText = sourceFontStyle.textContent || ''
        if (targetFontStyle.textContent !== nextText) {
            targetFontStyle.textContent = nextText
            changed = true
        }
    }

    for (const [key, value] of Object.entries(sourceFontStyle.dataset || {})) {
        const nextValue = key === 'mnbInjectedFontFamily' && directionalFamily
            ? directionalFamily
            : value
        if (targetFontStyle.dataset[key] !== nextValue) {
            targetFontStyle.dataset[key] = nextValue
            changed = true
        }
    }
    if (doc.documentElement && directionalFamily) {
        if (doc.documentElement.dataset.mnbInjectedFontFamily !== directionalFamily) {
            doc.documentElement.dataset.mnbInjectedFontFamily = directionalFamily
            changed = true
        }
        if (doc.documentElement.dataset.mnbFontInjected !== '1') {
            doc.documentElement.dataset.mnbFontInjected = '1'
            changed = true
        }
    }
    // The native selection resolves unavailable system faces to a temporary fallback.
    // Carry those CSS values into already loaded and newly opened EPUB documents.
    for (const [key, property] of [
        ['mnbHorizontalFontCSSValue', '--mnb-content-font'],
        ['mnbVerticalFontCSSValue', '--mnb-content-vertical-font'],
    ]) {
        const value = sourceFontStyle.dataset?.[key]
        if (!value) continue
        for (const element of [doc.documentElement, doc.body]) {
            if (!element?.style || element.style.getPropertyValue(property) === value) continue
            element.style.setProperty(property, value)
            changed = true
        }
    }
    if (changed && doc.defaultView) {
        const previousState = fontGeometryStates.get(doc)
        previousState?.fontStyle.removeEventListener?.('load', previousState.onLoad)
        const fontStyle = targetFontStyle
        const root = doc.documentElement
        const view = doc.defaultView
        const href = fontStyle.href
        const text = fontStyle.textContent
        const state = { fontStyle }
        fontGeometryStates.set(doc, state)
        const refreshGeometry = () => {
            if (fontGeometryStates.get(doc) !== state
                || doc.documentElement !== root || doc.defaultView !== view
                || doc.getElementById('mnb-custom-fonts-inline') !== fontStyle
                || (desiredTag === 'link' ? fontStyle.href !== href : fontStyle.textContent !== text)) return
            try { if (view.document && view.document !== doc) return } catch (_) { return }
            view.dispatchEvent(new view.Event('resize'))
        }
        const refreshAfterFontsReady = () => {
            if (fontGeometryStates.get(doc) !== state) return
            const ready = doc.fonts?.ready
            if (ready?.then) ready.then(refreshGeometry).catch(() => {})
        }
        // The new sheet may apply after the first resize and the current font-ready promise.
        state.onLoad = () => {
            refreshGeometry()
            refreshAfterFontsReady()
        }
        if (desiredTag === 'link') fontStyle.addEventListener?.('load', state.onLoad, { once: true })
        refreshGeometry()
        refreshAfterFontsReady()
    }
    return changed
}
