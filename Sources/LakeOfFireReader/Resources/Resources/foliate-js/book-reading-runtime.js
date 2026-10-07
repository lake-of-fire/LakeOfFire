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
    let scopeReceipts = new WeakMap()
    const primaryDocument = (renderer = view.renderer) => {
        if (closed || reader.view !== view || view.renderer !== renderer) return null
        try {
            const content = getPrimaryRendererContent(renderer)
            return content?.doc ?? content?.document ?? null
        } catch (_) { return null }
    }
    const isPrimaryDocument = doc => !!doc && doc === primaryDocument()
    const clearDocumentScope = (doc, isCurrent = () => true, capturedFrame = null) => {
        let frame, scope, captured = false
        const ownsScope = () => captured && !!frame && isCurrent()
            && frame.manabi_bookReadingScope === scope && isCurrent()
        try {
            if (!isCurrent()) return
            // Teardown supplies its captured frame; page code must not redirect
            // a later document lookup into a successor's cleanup.
            frame = capturedFrame ?? doc?.defaultView
            if (!frame || !isCurrent()) return
            scope = frame.manabi_bookReadingScope
            captured = true
            const invalidate = frame.manabi_invalidateBookReadingScope
            // A frame's callback lookup can already publish a successor.
            if (!ownsScope()) return
            if (typeof invalidate === 'function') Reflect.apply(invalidate, frame, [])
            else frame.manabi_bookReadingScope = null
        } catch (_) {
            // A broken outgoing frame must not prevent sibling/host cleanup.
            // Withdraw only the unchanged exposed scope, never recovered state.
            try {
                if (ownsScope()) frame.manabi_bookReadingScope = null
            } catch (_) {}
        }
    }
    const clearDocumentScopes = (isCurrent = () => true) => {
        const cleared = new Set()
        for (const content of rendererContents(view.renderer)) {
            if (!isCurrent()) return
            try {
                const doc = content?.doc ?? content?.document
                if (cleared.has(doc)) continue
                cleared.add(doc)
                clearDocumentScope(doc, isCurrent)
            } catch (_) {}
        }
        // A renderer may discard its old frame before cleanup. Preserve the
        // original observation as a cleanup target without touching successors.
        if (isCurrent() && !cleared.has(observed.document)) {
            clearDocumentScope(observed.document, isCurrent)
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
        },
        isLocationCurrent: () => !closed && reader.view === view
            && view.renderer === observed.renderer && primaryDocument() === observed.document
            && (observed.document !== null || endcap?.visible === true),
        onInvalidate: () => {
            // Recovery may restore the same account/pass/location values.
            // Retire the captured identities before invoking frame callbacks;
            // previously queued work must not acquire the recovered display.
            const invalidation = scopeReceipts = new WeakMap()
            // close owns a captured roster and must not enumerate a replacement.
            if (closed) return
            const isCurrent = () => scopeReceipts === invalidation && state.context === null
            clearDocumentScopes(isCurrent)
            if (!isCurrent()) return
            try { endcap?.setReady(false) } catch (_) {}
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
                const project = frame.manabi_applyBookReadingPresentation
                // Frame adapters may retain or edit their input. Keep their
                // projection and scope independent from shell/native state.
                const frameProjection = { ...projection, scope: projection.scope ? { ...projection.scope } : null,
                    readSegmentIdentifiers: [...projection.readSegmentIdentifiers],
                    sentenceIdentifiersRead: [...projection.sentenceIdentifiersRead] }
                if (!isCurrent()) return
                frame.manabi_bookReadingScope = projection.scope ? { ...projection.scope } : null
                if (!isCurrent()) return
                if (project != null) Reflect.apply(project, frame, [frameProjection])
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
        // Both owners change before timer cleanup may synchronously publish a
        // fresh account sample. It must not be disabled by an older reset.
        onAccountChange: () => endcap?.accountDidChange(),
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
        const accounts = scopeReceipts, location = observed
        const account = state.accountPresentation, revision = state.locationRevision
        const isCurrent = () => !closed && scopeReceipts === accounts && observed === location
            && state.accountPresentation === account && state.locationRevision === revision
        if (doc !== location.document || view.renderer !== location.renderer
            || !isPrimaryDocument(doc) || !isCurrent()) return null
        const scope = state.captureScope(doc.location?.href ?? doc.URL)
        // Renderer/URL lookups may synchronously recover equal pass IDs. Such
        // a capture needs a fresh originating event, not its predecessor's call.
        if (!scope || !isCurrent()) return null
        accounts.set(scope, { account, key: bookScopeKey(scope) })
        return scope
    }
    const isScopeCurrent = (scope, doc) => {
        const accounts = scopeReceipts, revision = state.locationRevision
        const receipt = accounts.get(scope)
        const ownsReceipt = () => !!scope && scopeReceipts === accounts && accounts.get(scope) === receipt
            && receipt?.account === state.accountPresentation && state.locationRevision === revision
        if (!ownsReceipt()) return false
        let key, selectedKey
        try {
            key = bookScopeKey(scope)
            selectedKey = bookScopeKey(captureScope(doc))
        } catch (_) { return false }
        // Recheck AFTER renderer callbacks; equal recovered values cannot revive
        // a retired receipt, and mutating its defensive copy cannot retarget it.
        return ownsReceipt() && receipt.key === key && key === selectedKey
    }
    endcap = new BookEndcap({ document, host: document.getElementById('reader-stage'), publication: view,
        performAction: action => bridge.perform(action), recoverAction: recovery => bridge.recover(recovery),
        onChange: visible => {
            if (closed) return
            updateLocation()
            if (!closed && reader.view === view && endcap.visible === visible) onVisibility(visible)
        },
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
            const accounts = scopeReceipts, account = state.accountPresentation
            const revision = state.locationRevision, renderer = view.renderer
            const scope = captureScope(doc)
            return scope && renderer === view.renderer && revision === state.locationRevision
                && accounts === scopeReceipts && account === state.accountPresentation
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
            scopeReceipts = new WeakMap()
            // Retain outgoing frame/token identities before teardown callbacks.
            // The observation remains a fallback after renderer discard.
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
            // One failure cannot stop sibling cleanup; a replacement renderer
            // or a newer scope in a reused frame never belongs to this close.
            for (const cleanup of [() => bridge.close(), () => state.close(), () => endcap.destroy(),
                ...frames.map(({ doc, frame, scope }) => () => clearDocumentScope(doc,
                    () => frame.manabi_bookReadingScope === scope, frame))]) {
                try { cleanup() } catch (_) {}
            }
        },
    }
}
