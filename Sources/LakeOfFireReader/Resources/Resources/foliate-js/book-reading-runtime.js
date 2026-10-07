import { BookEndcap } from './book-endcap.js'
import { createBookActionBridge } from './book-action-bridge.js'
import { BookReadingStateController, bookScopeKey } from './book-reading-state.js'
import { getPrimaryRendererContent, getPrimaryRendererContentIndex, rendererContents } from './renderer-content.js'
import { pageTurnMovementDisposition } from './page-turn-coordination.js'

// The viewer owns this runtime; the publication itself remains unchanged.
export const installBookReadingRuntime = ({ reader, view, document, window,
    documentStartedAtMs, applyProjection, invalidateProjection, onVisibility }) => {
    const handlers = window.webkit?.messageHandlers
    if (!handlers?.ebookBookAction || !handlers?.ebookBookReadingState) return null
    // A URL identifies a resource, not a displayed Document. Preloaded or
    // detached frames can use the very same URL as the current chapter.
    let closed = false
    let scopeAccounts = new WeakMap()
    const primaryDocument = (renderer = view.renderer) => {
        if (closed || reader.view !== view || view.renderer !== renderer) return null
        const content = getPrimaryRendererContent(renderer)
        return content?.doc ?? content?.document ?? null
    }
    const isPrimaryDocument = doc => !!doc && doc === primaryDocument()
    const clearDocumentScope = (doc, isCurrent = () => true) => {
        let frame, scope
        const ownsScope = () => !!frame && isCurrent()
            && frame.manabi_bookReadingScope === scope && isCurrent()
        try {
            if (!isCurrent()) return
            frame = doc?.defaultView
            scope = frame?.manabi_bookReadingScope
            const invalidate = frame?.manabi_invalidateBookReadingScope
            // A frame's callback lookup can already publish a successor.
            if (!frame || !ownsScope()) return
            if (typeof invalidate === 'function') Reflect.apply(invalidate, frame, [])
            else frame.manabi_bookReadingScope = null
        } catch (_) {
            // A broken outgoing frame must not prevent sibling/host cleanup.
            // Withdraw only the still-owned token, never a recovered scope.
            try { if (ownsScope()) frame.manabi_bookReadingScope = null } catch (_) {}
        }
    }
    const clearDocumentScopes = (isCurrent = () => true) => {
        for (const content of rendererContents(view.renderer)) {
            if (!isCurrent()) return
            try { clearDocumentScope(content?.doc ?? content?.document, isCurrent) } catch (_) {}
        }
    }
    // One observation identifies the displayed document and its renderer.
    // Equal-valued replacement followed by restoration is still a new observation.
    let endcap, bridge, observed = { document: null, renderer: null }
    const state = new BookReadingStateController({
        postMessage: body => handlers.ebookBookReadingState.postMessage(body),
        documentStartedAtMs, topWindowURL: window.location.href,
        requiresAccountPresentation: true,
        onAccountChange: stamp => {
            bridge?.setAccountPresentation(stamp)
            endcap?.accountDidChange()
        },
        isLocationCurrent: () => !closed && reader.view === view
            && view.renderer === observed.renderer && primaryDocument() === observed.document
            && (observed.document !== null || endcap?.visible === true),
        onInvalidate: () => {
            // Recovery may restore the same account/pass/location values.
            // Retire the captured identities before invoking frame callbacks;
            // previously queued work must not acquire the recovered display.
            const invalidation = scopeAccounts = new WeakMap()
            // close owns a captured cleanup roster; this callback must not
            // enumerate a renderer installed during an earlier close phase.
            if (closed) return
            const isCurrent = () => scopeAccounts === invalidation && state.context === null
            clearDocumentScopes(isCurrent)
            if (!isCurrent()) return
            endcap?.setReady(false)
            if (!isCurrent()) return
            invalidateProjection()
        },
        onState: (projection, context, details, isCurrent) => {
            const activeDocument = primaryDocument()
            for (const content of rendererContents(view.renderer)) {
                if (!isCurrent()) return
                const doc = content?.doc ?? content?.document
                const frame = doc?.defaultView
                if (!frame || !isCurrent()) continue
                if (doc !== activeDocument || context.isEndPage) {
                    clearDocumentScope(doc, isCurrent)
                    continue
                }
                // Do not transiently invalidate the visible document on an
                // ordinary same-pass refresh. Hidden/terminal frames lose
                // both their token and the cached presentation behind it.
                frame.manabi_bookReadingScope = projection.scope
                if (!isCurrent()) return
                const project = frame.manabi_applyBookReadingPresentation
                if (!isCurrent()) return
                if (project != null) Reflect.apply(project, frame, [projection])
            }
            if (!isCurrent()) return
            endcap?.setFinished(projection.finished)
            if (!isCurrent()) return
            endcap?.setReady(context.isEndPage)
            if (!isCurrent()) return
            applyProjection(projection, details)
        },
    })
    bridge = createBookActionBridge({
        postMessage: payload => handlers.ebookBookAction.postMessage(payload),
        documentStartedAtMs, topWindowURL: window.location.href,
        captureContext: expected => state.captureContext(expected),
    })
    const updateLocation = (moved = false) => {
        if (closed) return false
        const previous = observed, revision = state.locationRevision
        const renderer = view.renderer, doc = primaryDocument(renderer)
        const isEndPage = endcap?.visible === true
        const sectionURL = isEndPage ? null : doc?.location?.href ?? doc?.URL ?? null
        const ownsSelection = () => !closed && reader.view === view && view.renderer === renderer
            && primaryDocument(renderer) === doc && (endcap?.visible === true) === isEndPage
            && state.locationRevision === revision
        if (!ownsSelection() || observed !== previous) return false
        const replaced = doc !== previous.document || renderer !== previous.renderer
        const selection = observed = replaced ? { document: doc, renderer } : previous
        const isCurrent = () => observed === selection && ownsSelection() && observed === selection
        // Publish the observation before outgoing callbacks. A nested relocation
        // owns its own sample; an older continuation must not invalidate it again.
        if (replaced) clearDocumentScope(previous.document, isCurrent)
        if (!isCurrent()) return false
        return state.relocate({ sectionURL, isEndPage }, { moved, replaced })
    }
    const captureScope = doc => {
        const accounts = scopeAccounts, location = observed
        const account = state.accountPresentation, revision = state.locationRevision
        const isCurrent = () => !closed && scopeAccounts === accounts && observed === location
            && state.accountPresentation === account && state.locationRevision === revision
        if (doc !== location.document || view.renderer !== location.renderer
            || !isPrimaryDocument(doc) || !isCurrent()) return null
        const scope = state.captureScope(doc.location?.href ?? doc.URL)
        // Renderer/URL lookups may synchronously recover equal pass IDs. Such
        // a capture needs a fresh originating event, not its predecessor's call.
        if (!scope || !isCurrent()) return null
        accounts.set(scope, account)
        return scope
    }
    const isScopeCurrent = (scope, doc) => {
        const accounts = scopeAccounts, revision = state.locationRevision
        const ownsReceipt = () => !!scope && scopeAccounts === accounts && accounts.has(scope)
            && accounts.get(scope) === state.accountPresentation && state.locationRevision === revision
        if (!ownsReceipt()) return false
        const matches = bookScopeKey(scope) === bookScopeKey(captureScope(doc))
        // Recheck AFTER renderer callbacks; equal recovered values cannot revive
        // a receipt whose map was retired during the comparison.
        return ownsReceipt() && matches
    }
    endcap = new BookEndcap({ document, host: document.getElementById('reader-stage'), publication: view,
        performAction: action => bridge.perform(action), recoverAction: recovery => bridge.recover(recovery),
        onChange: visible => { if (!closed) { updateLocation(); onVisibility(visible) } },
    })
    view.renderer.bookEndcap = endcap
    return {
        state, bridge, endcap, updateLocation,
        accountDidChange(stamp) {
            if (!state.setAccountPresentation(stamp)) return false
            // Native withdrew its old account bind. Request a new account-owned
            // book snapshot even when the chapter/document did not change.
            state.refresh()
            return true
        },
        captureScope, isScopeCurrent,
        // Capture before a timer, promise or layout wait. A later same-URL
        // document, renderer, position or pass cannot adopt this event.
        captureEvent(doc) {
            const accounts = scopeAccounts, account = state.accountPresentation
            const revision = state.locationRevision, renderer = view.renderer
            const scope = captureScope(doc)
            return scope && renderer === view.renderer && revision === state.locationRevision
                && accounts === scopeAccounts && account === state.accountPresentation
                ? Object.freeze({ document: doc, renderer,
                    locationRevision: revision, scope: Object.freeze(scope) }) : null
        },
        isEventCurrent(event) {
            const ownsLocation = () => !!event && event.renderer === view.renderer
                && event.locationRevision === state.locationRevision
            return ownsLocation() && isScopeCurrent(event.scope, event.document) && ownsLocation()
        },
        async navigate(target) {
            const accountPresentation = state.accountPresentation
            if (accountPresentation === null) return { status: 'failed' }
            const renderer = view.renderer, book = view.book
            const revision = state.locationRevision
            const ownsHost = () => !closed && state.accountPresentation === accountPresentation
                && target.accountPresentation === accountPresentation && reader.view === view
                && view.renderer === renderer && view.book === book
            const mayDispatch = () => ownsHost() && target.locationRevision === revision
                && state.locationRevision === revision
            if (!renderer || !mayDispatch()) return { status: 'superseded' }
            // Native already committed this pass. An unavailable or still-old
            // projection is recoverable, not proof the user navigated away.
            if (!state.admitsNavigation(target)) return { status: 'failed' }
            const sections = book?.sections ?? []
            const index = target.action === 'startBookOver'
                ? sections.findIndex(section => section.linear !== 'no')
                : sections.findIndex(section => section.id === target.sectionLocation || section.href === target.sectionLocation)
            if (!mayDispatch()) return { status: 'superseded' }
            if (index < 0) return { status: 'failed' }
            const goTo = renderer.goTo
            if (!mayDispatch()) return { status: 'superseded' }
            if (typeof goTo !== 'function' || !state.admitsNavigation(target)) return { status: 'failed' }
            if (!mayDispatch()) return { status: 'superseded' }
            const result = await Reflect.apply(goTo, renderer, [{ index, anchor: 0, bookAction: true }])
            if (!ownsHost()) return { status: 'superseded' }
            // The renderer can explicitly report that another navigation owns
            // the movement. That is not a retryable failure of this old action.
            const disposition = pageTurnMovementDisposition(result)
            const displayedIndex = getPrimaryRendererContentIndex(renderer)
            if (!ownsHost() || disposition === 'not-owned') return { status: 'superseded' }
            if (result !== true || displayedIndex !== index) return { status: 'failed' }
            return { status: 'completed' }
        },
        close() {
            if (closed) return
            closed = true
            scopeAccounts = new WeakMap()
            // Capture the retiring renderer's frames and exact tokens before any
            // teardown observer can install a successor. The observed document
            // remains a fallback when renderer enumeration is unavailable.
            const renderer = observed.renderer, docs = new Set([observed.document])
            for (const content of rendererContents(renderer)) {
                try { docs.add(content?.doc ?? content?.document) } catch (_) {}
            }
            const frames = []
            for (const doc of docs) {
                try {
                    const frame = doc?.defaultView, scope = frame?.manabi_bookReadingScope
                    if (frame) frames.push({ doc, frame, scope })
                } catch (_) {}
            }
            // Cleanup phases remain independent. Neither a replacement renderer
            // nor a newer token in a reused frame belongs to this closure.
            for (const cleanup of [() => bridge.close(), () => state.close(), () => endcap.destroy(),
                ...frames.map(({ doc, frame, scope }) => () => clearDocumentScope(doc,
                    () => frame.manabi_bookReadingScope === scope))]) {
                try { cleanup() } catch (_) {}
            }
        },
    }
}
