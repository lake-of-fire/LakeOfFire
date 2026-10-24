import { getCurrentRendererDocument } from './renderer-content.js'

const fontGeometryStates = new WeakMap()

export const copyCustomReaderFontStyleToDocument = (
    sourceFontStyle,
    doc,
    reason = 'unknown',
    fontFamilies = globalThis,
    geometryOwner = null,
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
        const isCurrent = () => {
            if (fontGeometryStates.get(doc) !== state
                || doc.documentElement !== root || doc.defaultView !== view
                || doc.getElementById('mnb-custom-fonts-inline') !== fontStyle
                || (desiredTag === 'link' ? fontStyle.href !== href : fontStyle.textContent !== text)) return false
            try {
                if (view.document && view.document !== doc) return false
                if (root?.isConnected === false || view.frameElement?.isConnected === false) return false
                return !geometryOwner || geometryOwner.isCurrent(doc)
            } catch (_) { return false }
        }
        const refreshGeometry = () => {
            if (!isCurrent()) return
            view.dispatchEvent(new view.Event('resize'))
            // Chapter resize events do not reach the outer viewer. Its snapshot may
            // already have been rebuilt while this replacement sheet was loading.
            // Recheck after dispatch, which can synchronously retire this document.
            if (isCurrent()) geometryOwner?.invalidate()
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

// Capture the existing viewer binding rather than look up a successor owner when
// delayed stylesheet/font callbacks run. Reader teardown removes this binding.
export const forwardCustomReaderFontStyleToDocuments = (
    sourceFontStyle,
    docs,
    reason = 'unknown',
    viewer = globalThis,
) => {
    const reader = viewer.reader
    const renderer = reader?.view?.renderer
    const invalidate = viewer.manabiInvalidateVisiblePageSegmentSnapshot
    const ownsViewer = () => viewer.reader === reader
        && reader.isClosed !== true
        && reader.view?.renderer === renderer
        && viewer.manabiInvalidateVisiblePageSegmentSnapshot === invalidate
    const geometryOwner = reader && renderer && typeof invalidate === 'function' ? {
        isCurrent: doc => {
            if (!ownsViewer()) return false
            const currentDocument = getCurrentRendererDocument(renderer, doc)
            return currentDocument === doc && ownsViewer()
        },
        invalidate: () => invalidate.call(viewer, 'font-family-change-child'),
    } : null
    let forwardedCount = 0
    for (const doc of docs) {
        if (copyCustomReaderFontStyleToDocument(sourceFontStyle, doc, reason, viewer, geometryOwner)) {
            forwardedCount++
        }
    }
    return forwardedCount
}
