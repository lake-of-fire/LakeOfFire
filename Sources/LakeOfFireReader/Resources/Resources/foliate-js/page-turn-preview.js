// Paint-only helpers. The paginator retains navigation, resource ownership,
// cancellation and cache decisions; this module never admits a live document.

// These paint inputs are not preserved by importNode and can change without
// DOM mutations. Decline the optional copy rather than show missing/stale paint.
export const supportsPageTurnPreviewDocument = doc => !doc.adoptedStyleSheets?.length
    && !doc.querySelector('canvas, video, audio, iframe, object, embed')

export const pageTurnPreviewThemeAttributes = Object.freeze([
    'data-mnb-color-scheme', 'data-mnb-light-theme', 'data-mnb-dark-theme',
])

export const synchronizePageTurnPreviewTheme = (source, preview) => {
    if (!source?.body || !preview?.body) return
    for (const name of pageTurnPreviewThemeAttributes) {
        const value = source.body.getAttribute(name)
        if (value !== null && preview.body.getAttribute(name) !== value) {
            preview.body.setAttribute(name, value)
        }
    }
    for (const [from, to] of [
        [source.documentElement, preview.documentElement], [source.body, preview.body],
    ]) {
        const value = from.style.getPropertyValue('color-scheme')
        if (value && to.style.getPropertyValue('color-scheme') !== value) {
            to.style.setProperty('color-scheme', value)
        }
    }
}

export const parsePageTurnPreviewDocument = (text, contentType) => {
    // XHTML is standards-mode even without an HTML doctype. Match the document
    // the real navigation will load rather than parsing every chapter as HTML.
    const mediaType = contentType?.split(';')[0].trim().toLowerCase()
    const parseType = ['application/xhtml+xml', 'application/xml', 'text/xml', 'image/svg+xml'].includes(mediaType)
        ? mediaType : 'text/html'
    return new DOMParser().parseFromString(text, parseType)
}

const stylesheetNodes = root => Array.from(root.querySelectorAll('style, link[rel~="stylesheet"]'))
const snapshotStylesheet = (sheet, ancestors = new Set()) => {
    if (!sheet) return null
    const state = { disabled: sheet.disabled, media: sheet.media.mediaText, rules: null }
    if (ancestors.has(sheet)) return state
    ancestors.add(sheet)
    try {
        state.rules = Array.from(sheet.cssRules)
            .filter(rule => !unsupportedImport(rule))
            .map(rule => ({ text: rule.cssText, imported: rule.type === CSSRule.IMPORT_RULE
                ? snapshotStylesheet(rule.styleSheet, ancestors) : null }))
    }
    catch (error) {
        // Cross-origin publication sheets can paint without exposing CSSOM.
        if (error.name !== 'SecurityError') throw error
    }
    finally { ancestors.delete(sheet) }
    return state
}

// DOM mutation observation does not see CSSOM edits, media or disabled changes.
// Keep those live paint inputs in the cache identity as well as copying them.
export const pageTurnPreviewStylesheetKey = doc => JSON.stringify(stylesheetNodes(doc).map(node => [
    !!(node.disabled || node.sheet?.disabled),
    snapshotStylesheet(node.sheet) ?? (node.localName === 'style' ? node.textContent : null),
]))

const copyStylesheetState = (source, root) => {
    const copies = stylesheetNodes(root)
    const snapshots = []
    stylesheetNodes(source).forEach((node, index) => {
        const copy = copies[index]
        // Disabled inline sheets lose their state on importNode. Omit inactive
        // CSS from this inert copy, including the later direction-measurement
        // clone, rather than letting it briefly affect layout or fetch imports.
        if (node.disabled || node.sheet?.disabled) copy.remove()
        else {
            const state = snapshotStylesheet(node.sheet)
            if (node.localName === 'style') copy.textContent = state?.rules?.map(rule => rule.text).join('\n') ?? node.textContent
            if (state?.rules) snapshots.push({ node: copy, state })
        }
    })
    return snapshots
}

const restoreStylesheetState = async (snapshots, doc, waitForStylesheets, isCurrent) => {
    const changedRoots = new Set()
    let level = snapshots
    while (level.length) {
        for (const entry of level) {
            const sheet = entry.node ? entry.node.sheet : entry.sheet
            if (!sheet) throw new Error('pageTurnPreviewStylesheetUnavailable')
            entry.sheet = sheet
            entry.root ??= sheet
            if (sheet.disabled !== entry.state.disabled) {
                sheet.disabled = entry.state.disabled
                changedRoots.add(entry.root)
            }
            // CSSStyleSheet.media can diverge from its owner's media attribute.
            // Keep the markup intact and restore the live CSSOM condition too.
            if (sheet.media.mediaText !== entry.state.media) {
                sheet.media.mediaText = entry.state.media
                changedRoots.add(entry.root)
            }
            const { rules } = entry.state
            if (entry.state.disabled || !rules) continue
            const current = Array.from(sheet.cssRules, rule => rule.cssText)
            if (current.length === rules.length && current.every((text, index) => text === rules[index].text)) continue
            changedRoots.add(entry.root)
            // Edit each loaded sheet in place, preserving that sheet's href as
            // the base for relative images/fonts/imports at every import depth.
            while (sheet.cssRules.length) sheet.deleteRule(sheet.cssRules.length - 1)
            rules.forEach((rule, index) => sheet.insertRule(rule.text, index))
        }
        // Replacing a parent's imports can create new child sheets. Wait for
        // them before resolving their current CSSOM objects and restoring edits.
        await waitForStylesheets(doc)
        if (!isCurrent()) return false
        level = level.flatMap(({ sheet, state, root }) => {
            if (state.disabled || !state.rules) return []
            return state.rules.flatMap((rule, index) => rule.imported
                ? [{ sheet: sheet.cssRules[index]?.styleSheet, state: rule.imported, root }] : [])
        })
    }
    // Some engines expose a restored import's parsed rules before updating its
    // parent's cascade. Re-enable only changed roots once their children are
    // ready; the sheets and their loaded resources keep their existing identity.
    for (const sheet of changedRoots) {
        sheet.disabled = true
        sheet.disabled = false
    }
    return true
}

const unsupportedImport = rule => rule.type === CSSRule.IMPORT_RULE
    && rule.supportsText && !CSS.supports(`(${rule.supportsText})`)

const discardUnsupportedInlineImports = node => {
    if (node.localName !== 'style' || !node.sheet) return
    const rules = Array.from(node.sheet.cssRules)
    if (!rules.some(unsupportedImport)) return
    // Only the inert copy changes. Updating text as well as CSSOM keeps later
    // direction-measurement clones from restoring ignored imports whose fetch
    // can still delay a document's load in WebKit/Chromium.
    node.textContent = rules.filter(rule => !unsupportedImport(rule)).map(rule => rule.cssText).join('\n')
}

const stylesheetImportState = sheet => {
    const imports = []
    const visited = new Set()
    const visit = sheet => {
        if (!sheet) return false
        if (sheet.disabled) return true
        if (visited.has(sheet)) return true
        visited.add(sheet)
        let rules
        try { rules = sheet.cssRules } catch (error) {
            // Opaque publication CSS can paint without exposing its rules.
            if (error.name === 'SecurityError') return true
            throw error
        }
        let ready = true
        for (const rule of rules) {
            if (rule.type !== CSSRule.IMPORT_RULE) continue
            // A false condition contributes no paint. Its null styleSheet can
            // mean ignored CSS rather than pending CSS in sandboxed WebKit.
            if (unsupportedImport(rule)) continue
            imports.push(rule, rule.styleSheet, rule.styleSheet?.disabled)
            if (!visit(rule.styleSheet)) ready = false
        }
        return ready
    }
    return { sheet, ready: visit(sheet), imports }
}

const nextPreviewFrame = signal => new Promise(resolve => {
    if (signal?.aborted) { resolve(false); return }
    let frame, finished = false
    const finish = ready => {
        if (finished) return
        finished = true
        cancelAnimationFrame(frame)
        signal?.removeEventListener('abort', onAbort)
        resolve(ready)
    }
    const onAbort = () => finish(false)
    signal?.addEventListener('abort', onAbort, { once: true })
    frame = requestAnimationFrame(() => finish(true))
})

const createStylesheetReadiness = (isCurrent, signal) => {
    const readiness = new WeakMap()
    return root => Promise.all(Array.from(root.querySelectorAll('style, link[rel~="stylesheet"]'))
        // Inactive placeholders cannot contribute paint or reliably emit an
        // event: this includes blank links and styles in a non-CSS language.
        .filter(node => {
            if (node.disabled) return false
            if (node.localName !== 'style') return node.getAttribute('href')?.trim()
            const type = node.getAttribute('type')?.trim().toLowerCase()
            return !type || type === 'text/css'
        })
        .map(node => {
            const inline = node.localName === 'style'
            const readState = () => {
                discardUnsupportedInlineImports(node)
                return stylesheetImportState(node.sheet)
            }
            const state = readState()
            const identity = inline ? node.textContent : node.href
            const existing = readiness.get(node)
            // CSSOM insertRule/deleteRule do not update textContent. Include
            // the import graph and sheet identity when reusing a settled wait.
            if (existing?.identity === identity && existing.sheet === state.sheet
                && existing.disabled === node.disabled
                && existing.imports.length === state.imports.length
                && existing.imports.every((value, index) => value === state.imports[index])) return existing.promise
            // Retargeting can briefly leave the previous sheet associated with
            // a link. Inline CSS exposes its sheet before @imports finish, so
            // also inspect its import tree before accepting a frame probe.
            const previousSheet = !inline && existing?.identity !== identity ? existing?.sheet : null
            const hasCurrentSheet = state => state.sheet && state.sheet !== previousSheet && state.ready
            const entry = { identity, ...state, disabled: node.disabled, promise: null }
            if (hasCurrentSheet(state)) {
                entry.promise = Promise.resolve()
                readiness.set(node, entry)
                return entry.promise
            }
            entry.promise = new Promise((resolve, reject) => {
                let frame, finished = false
                const finish = (error = null, cancelled = false) => {
                    if (finished) return
                    finished = true
                    cancelAnimationFrame(frame)
                    node.removeEventListener('load', onLoad)
                    node.removeEventListener('error', onError)
                    signal?.removeEventListener('abort', onAbort)
                    if (error) { reject(error); return }
                    if (cancelled) { resolve(); return }
                    try {
                        Object.assign(entry, readState(), {
                            identity: inline ? node.textContent : node.href, disabled: node.disabled,
                        })
                        resolve()
                    } catch (error) { reject(error) }
                }
                const onLoad = () => {
                    try {
                        // A queued load for the previous import graph cannot
                        // authorize a new CSSOM resource that is still pending.
                        if (hasCurrentSheet(readState())) finish()
                    } catch (error) { finish(error) }
                }
                const onError = () => finish()
                const onAbort = () => finish(null, true)
                const check = () => {
                    // Sandboxed WebKit can expose an applied sheet without
                    // dispatching its load callback. Keep scripts prohibited;
                    // the paginator deadline still bounds unavailable sheets.
                    try {
                        if (!isCurrent()) finish(null, true)
                        else if (node.disabled || hasCurrentSheet(readState())) finish()
                        else frame = requestAnimationFrame(check)
                    } catch (error) { finish(error) }
                }
                node.addEventListener('load', onLoad)
                node.addEventListener('error', onError)
                signal?.addEventListener('abort', onAbort, { once: true })
                if (signal?.aborted) onAbort()
                else frame = requestAnimationFrame(check)
            })
            readiness.set(node, entry)
            return entry.promise
        }))
}

export const preparePageTurnPreviewDocument = async (doc, source, baseURL, isCurrent, afterLoad, signal = null) => {
    const current = () => !signal?.aborted && isCurrent()
    if (!current()) return false
    // An iframe's initial about:blank document uses quirks mode. Importing the
    // chapter root does not change it, so margins can jump on commit. Parse only
    // a blank shell in the source mode, then import the content once.
    const doctype = source.contentType === 'text/html' && source.doctype
        ? new XMLSerializer().serializeToString(source.doctype)
        : source.compatMode === 'BackCompat' ? '' : '<!doctype html>'
    doc.open()
    doc.write(`${doctype}<html><head></head><body></body></html>`)
    doc.close()
    const root = doc.importNode(source.documentElement, true)
    const stylesheetSnapshots = copyStylesheetState(source, root)
    // Give input/painting a turn between copying and laying out long chapters.
    if (!await nextPreviewFrame(signal) || !current()) return false
    root.querySelectorAll('script, iframe, object, embed, base, meta[http-equiv]').forEach(el => el.remove())
    const head = root.querySelector('head') ?? root.insertBefore(doc.createElement('head'), root.firstChild)
    const base = doc.createElement('base')
    base.href = baseURL
    const csp = doc.createElement('meta')
    csp.httpEquiv = 'Content-Security-Policy'
    // The containing iframe's sandbox and this CSP both prohibit scripts,
    // including inline handlers. No sidecars are bootstrapped in this document.
    csp.content = "script-src 'none'; object-src 'none'; frame-src 'none'"
    head.prepend(csp, base)

    const waitForStylesheets = createStylesheetReadiness(current, signal)
    // Install listeners before connecting publication CSS, including
    // cached stylesheets which can settle immediately on insertion.
    const stylesheets = waitForStylesheets(root)
    doc.replaceChild(root, doc.documentElement)
    await stylesheets
    if (!current()) return false
    if (!await restoreStylesheetState(stylesheetSnapshots, doc, waitForStylesheets, current)) return false
    // A newly restored import can expose CSSOM before its cascade invalidation
    // completes. Start reader paint hooks on the next frame, after that load turn.
    if (!await nextPreviewFrame(signal) || !current()) return false
    await afterLoad?.(doc)
    if (!current()) return false
    // Reader paint preparation can forward CSS absent from the cached chapter.
    // Reuse settled publication promises (including failures) and wait for new
    // or changed resources before measuring columns.
    await waitForStylesheets(doc)
    if (!await nextPreviewFrame(signal)) return false
    return current()
}

export const createPageTurnPreviewSurface = (top, content, head, foot) => {
    const sheet = top.cloneNode(false)
    sheet.classList.add('mnb-slide-sheet')
    sheet.classList.remove('reader-loading')
    sheet.style.visibility = 'hidden'
    sheet.setAttribute('aria-hidden', 'true')
    sheet.inert = true
    const container = content.cloneNode(false)
    const header = head.cloneNode(true)
    const footer = foot.cloneNode(true)
    const paper = document.createElement('div')
    paper.className = 'mnb-slide-paper'
    sheet.append(paper, header, container, footer)
    const shade = document.createElement('div')
    shade.className = 'mnb-slide-shade'
    shade.style.opacity = '0'
    const neighborShade = shade.cloneNode()
    sheet.append(neighborShade)
    return { sheet, container, header, footer, shade, neighborShade }
}

export const paintPageTurnPreview = (top, surface, pose, direction) => {
    top.style.transform = `translate3d(${pose.currentX}px,0,0)`
    surface.sheet.style.transform = `translate3d(${pose.neighborX}px,0,0)`
    top.style.zIndex = direction > 0 ? '2' : '1'
    surface.sheet.style.zIndex = direction > 0 ? '1' : '2'
    surface.shade.style.opacity = pose.currentShade
    surface.neighborShade.style.opacity = pose.neighborShade
    // The current page fully covers its neighbor at rest. Hiding the shaded
    // copy avoids an antialiased outline around the rounded corners.
    surface.sheet.style.visibility = pose.progress > 0 ? 'visible' : 'hidden'
}
