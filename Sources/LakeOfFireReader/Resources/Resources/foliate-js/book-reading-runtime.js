import { BookEndcap } from './book-endcap.js'
import { createBookActionBridge } from './book-action-bridge.js'
import { BookReadingStateController, bookScopeKey } from './book-reading-state.js'
import { getPrimaryRendererContent, getPrimaryRendererContentIndex } from './renderer-content.js'

// The viewer owns this runtime; the publication itself remains unchanged.
export const installBookReadingRuntime = ({ reader, view, document, window,
    documentStartedAtMs, applyProjection, invalidateProjection, onVisibility }) => {
    const handlers = window.webkit?.messageHandlers
    if (!handlers?.ebookBookAction || !handlers?.ebookBookReadingState) return null
    const documentURL = () => {
        const content = getPrimaryRendererContent(view.renderer)
        const doc = content?.doc ?? content?.document
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
    let endcap
    const state = new BookReadingStateController({
        postMessage: body => handlers.ebookBookReadingState.postMessage(body),
        documentStartedAtMs, topWindowURL: window.location.href,
        onInvalidate: () => {
            clearDocumentScopes()
            endcap?.setReady(false)
            invalidateProjection()
        },
        onState: (projection, context, details) => {
            const activeURL = documentURL()
            for (const content of view.renderer?.getContents?.() ?? []) {
                const doc = content?.doc ?? content?.document
                if (!doc?.defaultView) continue
                if ((doc.location?.href ?? doc.URL) !== activeURL || context.isEndPage) {
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
    const updateLocation = (moved = false) => state.relocate({
        sectionURL: endcap?.visible ? null : documentURL(), isEndPage: endcap?.visible === true,
    }, { moved })
    endcap = new BookEndcap({ document, host: document.getElementById('reader-stage'), publication: view,
        performAction: action => bridge.perform(action), recoverAction: recovery => bridge.recover(recovery),
        onChange: visible => { updateLocation(); onVisibility(visible) },
    })
    view.renderer.bookEndcap = endcap
    return {
        state, bridge, endcap, updateLocation,
        captureScope: doc => state.captureScope(doc?.location?.href ?? doc?.URL),
        isScopeCurrent: (scope, doc) => !!scope && bookScopeKey(scope) === bookScopeKey(state.captureScope(doc?.location?.href ?? doc?.URL)),
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
            if (reader.view !== view || !view.renderer) return { status: 'superseded' }
            if (result !== true || getPrimaryRendererContentIndex(renderer) !== index) return { status: 'failed' }
            return { status: 'completed' }
        },
        close() { bridge.close(); endcap.destroy(); state.close(); clearDocumentScopes() },
    }
}
