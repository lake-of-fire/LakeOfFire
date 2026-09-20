import { BookEndcap } from './book-endcap.js'
import { createBookActionBridge } from './book-action-bridge.js'
import { BookReadingStateController, bookScopeKey } from './book-reading-state.js'
import { getPrimaryRendererContent, getPrimaryRendererContentIndex } from './renderer-content.js'

// The viewer owns this runtime; the publication itself remains unchanged.
export const installBookReadingRuntime = ({ reader, view, document, window,
    documentStartedAtMs, applyProjection, invalidateProjection, onVisibility }) => {
    const handlers = window.webkit?.messageHandlers
    if (!handlers?.ebookBookAction || !handlers?.ebookBookReadingState) return null
    // A URL identifies a resource, not a displayed Document. Preloaded or
    // detached frames can use the very same URL as the current chapter.
    let closed = false
    const primaryDocument = () => {
        if (closed || reader.view !== view) return null
        const content = getPrimaryRendererContent(view.renderer)
        return content?.doc ?? content?.document ?? null
    }
    const isPrimaryDocument = doc => !!doc && doc === primaryDocument()
    const documentURL = () => {
        const doc = primaryDocument()
        return doc?.location?.href ?? doc?.URL ?? null
    }
    const clearDocumentScope = doc => {
        const frame = doc?.defaultView
        if (!frame) return
        if (typeof frame.manabi_invalidateBookReadingScope === 'function') {
            frame.manabi_invalidateBookReadingScope()
        } else {
            frame.manabi_bookReadingScope = null
        }
    }
    const clearDocumentScopes = () => {
        for (const content of view.renderer?.getContents?.() ?? []) {
            clearDocumentScope(content?.doc ?? content?.document)
        }
    }
    let endcap, observedDocument = null, observedRenderer = null
    const state = new BookReadingStateController({
        postMessage: body => handlers.ebookBookReadingState.postMessage(body),
        documentStartedAtMs, topWindowURL: window.location.href,
        isLocationCurrent: () => !closed && reader.view === view
            && view.renderer === observedRenderer && primaryDocument() === observedDocument,
        onInvalidate: () => {
            clearDocumentScopes()
            endcap?.setReady(false)
            invalidateProjection()
        },
        onState: (projection, context, details) => {
            const activeDocument = primaryDocument()
            for (const content of view.renderer?.getContents?.() ?? []) {
                const doc = content?.doc ?? content?.document
                if (!doc?.defaultView) continue
                if (doc !== activeDocument || context.isEndPage) {
                    clearDocumentScope(doc)
                    continue
                }
                // Do not transiently invalidate the visible document on an
                // ordinary same-pass refresh. Hidden/terminal frames lose
                // both their token and the cached presentation behind it.
                doc.defaultView.manabi_bookReadingScope = projection.scope
                doc.defaultView.manabi_applyBookReadingPresentation?.(projection)
            }
            endcap?.setFinished(projection.finished)
            endcap?.setReady(context.isEndPage)
            applyProjection(projection, details)
        },
    })
    const bridge = createBookActionBridge({
        postMessage: payload => handlers.ebookBookAction.postMessage(payload),
        documentStartedAtMs, topWindowURL: window.location.href,
        captureContext: expected => state.captureContext(expected),
    })
    const updateLocation = (moved = false) => {
        if (closed) return false
        const doc = primaryDocument(), renderer = view.renderer
        const replaced = doc !== observedDocument || renderer !== observedRenderer
        if (replaced) clearDocumentScope(observedDocument)
        observedDocument = doc; observedRenderer = renderer
        return state.relocate({ sectionURL: endcap?.visible ? null : documentURL(),
            isEndPage: endcap?.visible === true }, { moved, replaced })
    }
    const captureScope = doc => isPrimaryDocument(doc) && doc === observedDocument
        && view.renderer === observedRenderer ? state.captureScope(doc.location?.href ?? doc.URL) : null
    const isScopeCurrent = (scope, doc) => !!scope && bookScopeKey(scope) === bookScopeKey(captureScope(doc))
    endcap = new BookEndcap({ document, host: document.getElementById('reader-stage'), publication: view,
        performAction: action => bridge.perform(action), recoverAction: recovery => bridge.recover(recovery),
        onChange: visible => { if (!closed) { updateLocation(); onVisibility(visible) } },
    })
    view.renderer.bookEndcap = endcap
    return {
        state, bridge, endcap, updateLocation,
        captureScope, isScopeCurrent,
        // Capture before a timer, promise or layout wait. A later same-URL
        // document, renderer, position or pass cannot adopt this event.
        captureEvent(doc) {
            const scope = captureScope(doc)
            return scope ? Object.freeze({ document: doc, renderer: view.renderer,
                locationRevision: state.locationRevision, scope: Object.freeze(scope) }) : null
        },
        isEventCurrent(event) {
            return !!event && event.renderer === view.renderer
                && event.locationRevision === state.locationRevision
                && isScopeCurrent(event.scope, event.document)
        },
        async navigate(target) {
            if (reader.view !== view || !view.renderer || target.locationRevision !== state.locationRevision) {
                return { status: 'superseded' }
            }
            // Native already committed this pass. An unavailable or still-old
            // projection is recoverable, not proof the user navigated away.
            // Native revalidates the actual selector before every retry.
            if (!state.admitsNavigation(target)) return { status: 'failed' }
            const sections = view.book?.sections ?? []
            const index = target.action === 'startBookOver'
                ? sections.findIndex(section => section.linear !== 'no')
                : sections.findIndex(section => section.id === target.sectionLocation || section.href === target.sectionLocation)
            if (index < 0) return { status: 'failed' }
            const renderer = view.renderer
            const result = await renderer.goTo({ index, anchor: 0, bookAction: true })
            if (reader.view !== view || view.renderer !== renderer) return { status: 'superseded' }
            if (result !== true || getPrimaryRendererContentIndex(renderer) !== index) return { status: 'failed' }
            return { status: 'completed' }
        },
        close() {
            if (closed) return
            closed = true
            bridge.close(); state.close(); endcap.destroy(); clearDocumentScopes()
            clearDocumentScope(observedDocument)
        },
    }
}
