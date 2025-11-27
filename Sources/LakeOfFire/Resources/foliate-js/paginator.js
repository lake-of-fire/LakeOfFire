// TODO: "prevent spread" for column mode: https://github.com/johnfactotum/foliate-js/commit/b7ff640943449e924da11abc9efa2ce6b0fead6d

const CSS_DEFAULTS = {
    gapPct: 5,
    minGapPx: 36,
    topMarginPx: 4,
    bottomMarginPx: 69,
    sideMarginPx: 32,
    maxInlineSizePx: 720,
    maxBlockSizePx: 1440,
    maxColumnCount: 2,
    maxColumnCountPortrait: 1,
};

const wait = ms => new Promise(resolve => setTimeout(resolve, ms))

// https://learnersbucket.com/examples/interview/debouncing-with-leading-and-trailing-options/
const debounce = (fn, delay) => {
    let timeout;
    let isLeadingInvoked = false;

    return function (...args) {
        const context = this;

        if (!timeout) {
            fn.apply(context, args);
            isLeadingInvoked = true;

            timeout = setTimeout(() => {
                timeout = null;
                if (!isLeadingInvoked) {
                    fn.apply(context, args);
                }
            }, delay);
        } else {
            isLeadingInvoked = false;
        }
    }
};

const lerp = (min, max, x) => x * (max - min) + min
const easeOutQuad = x => 1 - (1 - x) * (1 - x)
const animate = (a, b, duration, ease, render) => new Promise(resolve => {
    let start
    const step = now => {
        start ??= now
        const fraction = Math.min(1, (now - start) / duration)
        render(lerp(a, b, ease(fraction)))
        if (fraction < 1) requestAnimationFrame(step)
        else resolve()
    }
    requestAnimationFrame(step)
})

const nextFrame = () => new Promise(resolve => requestAnimationFrame(resolve))

const requestTrackingSizeCache = (payload) => new Promise(resolve => {
    try {
        const handler = globalThis.webkit?.messageHandlers?.[MANABI_TRACKING_CACHE_HANDLER]
        if (!handler?.postMessage) return resolve(null)

        const requestId = `cache-${Date.now()}-${trackingSizeCacheRequestCounter++}`
        trackingSizeCacheResolvers.set(requestId, resolve)
        handler.postMessage({ requestId, ...payload })
    } catch (error) {
        resolve(null)
    }
})

globalThis.manabiResolveTrackingSizeCache = function (requestId, entries) {
    const resolver = trackingSizeCacheResolvers.get(requestId)
    if (resolver) {
        trackingSizeCacheResolvers.delete(requestId)
        resolver(entries)
    }
}

const MANABI_TRACKING_SECTION_CLASS = 'manabi-tracking-section'
const MANABI_TRACKING_SECTION_SELECTOR = `.${MANABI_TRACKING_SECTION_CLASS}`
const MANABI_TRACKING_SECTION_VISIBLE_CLASS = 'manabi-tracking-section-visible'
const MANABI_TRACKING_PREBAKE_HIDDEN_CLASS = 'manabi-prebake-hidden'
const MANABI_TRACKING_PREBAKE_HIDE_ENABLED = true
// Geometry bake disabled: keep constants for compatibility, but no-op the workflow below.
const MANABI_TRACKING_SIZE_BAKED_ATTR = 'data-manabi-size-baked'
const MANABI_TRACKING_SIZE_BAKE_ENABLED = true
const MANABI_TRACKING_SIZE_BAKE_BATCH_SIZE = 5
const MANABI_TRACKING_SIZE_BAKING_OPTIMIZED = true
const MANABI_TRACKING_SIZE_RESIZE_TRIGGERS_ENABLED = true
const MANABI_TRACKING_SIZE_BAKING_BODY_CLASS = 'manabi-tracking-size-baking'
const MANABI_TRACKING_FORCE_VISIBLE_CLASS = 'manabi-tracking-force-visible'
const MANABI_TRACKING_SECTION_BAKING_CLASS = 'manabi-tracking-section-baking'
const MANABI_TRACKING_SECTION_HIDDEN_CLASS = 'manabi-tracking-section-hidden'
const MANABI_TRACKING_SECTION_BAKED_CLASS = 'manabi-tracking-section-baked'
const MANABI_TRACKING_SIZE_BAKE_STYLE_ID = 'manabi-tracking-size-bake-style'
const MANABI_TRACKING_SIZE_STABLE_MAX_EVENTS = 120
const MANABI_TRACKING_SIZE_STABLE_REQUIRED_STREAK = 2
const MANABI_TRACKING_DOC_STABLE_MAX_EVENTS = 180
const MANABI_TRACKING_DOC_STABLE_REQUIRED_STREAK = 2
const MANABI_TRACKING_CACHE_HANDLER = 'trackingSizeCache'
const MANABI_TRACKING_CACHE_VERSION = 'v1'
const MANABI_SENTINEL_ROOT_MARGIN_PX = 64

const trackingSizeCacheResolvers = new Map()
let trackingSizeCacheRequestCounter = 0

// General logger disabled for noise reduction
const logEBook = () => {}

// Focused pagination diagnostics for tricky resume/relocate cases.
// pagination logger disabled for noise reduction
const logEBookPagination = () => {}

// Perf logger for targeted instrumentation
const logEBookPerf = (event, detail = {}) => {
    const ts = (typeof performance !== 'undefined' && typeof performance.now === 'function')
        ? performance.now()
        : Date.now()
    const payload = { event, ts, ...detail }
    const line = `# EBOOKPERF ${event} ${JSON.stringify(payload)}`
    try { window.webkit?.messageHandlers?.print?.postMessage?.(line) } catch {}
    try { console.debug?.(line) } catch {}
    return payload
}

const summarizeAnchor = anchor => {
    if (anchor == null) return 'null'
    if (typeof anchor === 'number') return `fraction:${Number(anchor).toFixed(6)}`
    if (typeof anchor === 'function') return 'function'
    if (anchor?.startContainer) return 'range'
    if (anchor?.nodeType === Node.ELEMENT_NODE) return `element:${anchor.tagName ?? 'unknown'}`
    if (anchor?.nodeType) return `nodeType:${anchor.nodeType}`
    return typeof anchor
}

// Geometry bake disabled: indicator is a no-op wrapper.
const geometryLoadingIndicator = {
    async run(fn) {
        return await fn()
    }
}

const snapshotInlineStyleProperty = (element, property) => {
    if (!(element instanceof HTMLElement)) return null
    const value = element.style.getPropertyValue(property)
    if (!value) return null
    const priority = element.style.getPropertyPriority(property)
    return {
        value,
        priority
    }
}

const restoreInlineStyleProperty = (element, property, snapshot) => {
    if (!(element instanceof HTMLElement)) return
    if (snapshot) element.style.setProperty(property, snapshot.value, snapshot.priority)
    else element.style.removeProperty(property)
}

const preBakeDisplaySnapshots = new WeakMap()

const hideDocumentContentForPreBake = doc => {
    if (!MANABI_TRACKING_PREBAKE_HIDE_ENABLED) return null
    const target = doc?.getElementById?.('reader-content') || doc?.body
    if (!(target instanceof HTMLElement)) return null
    if (preBakeDisplaySnapshots.has(doc)) return target

    const snapshot = snapshotInlineStyleProperty(target, 'display')
    preBakeDisplaySnapshots.set(doc, { target, snapshot })
    target.classList.add(MANABI_TRACKING_PREBAKE_HIDDEN_CLASS)
    target.style.setProperty('display', 'none', 'important')
    logEBookPerf('prebake-hide', {
        url: doc?.URL || null,
        targetId: target.id || null,
    })
    return target
}

const revealDocumentContentForBake = doc => {
    if (!MANABI_TRACKING_PREBAKE_HIDE_ENABLED) return
    if (!doc) return
    const entry = preBakeDisplaySnapshots.get(doc)
    if (!entry) return

    const { target, snapshot } = entry
    if (target instanceof HTMLElement) {
        target.classList.remove(MANABI_TRACKING_PREBAKE_HIDDEN_CLASS)
        restoreInlineStyleProperty(target, 'display', snapshot)
    }
    logEBookPerf('prebake-reveal', {
        url: doc?.URL || null,
        targetId: target?.id || null,
    })
    preBakeDisplaySnapshots.delete(doc)
}

const formatPx = value => {
    if (!Number.isFinite(value)) return '0px'
    const rounded = Math.max(0, Math.round(value * 1000) / 1000)
    return `${rounded}px`
}

const ensureTrackingSizeBakeStyles = doc => {
    if (!MANABI_TRACKING_SIZE_BAKING_OPTIMIZED) return
    if (!doc?.head) return
    if (doc.getElementById(MANABI_TRACKING_SIZE_BAKE_STYLE_ID)) return

    const style = doc.createElement('style')
    style.id = MANABI_TRACKING_SIZE_BAKE_STYLE_ID
    // Hidden trailing sections while baking to avoid layout thrash.
    style.textContent = `body.${MANABI_TRACKING_SIZE_BAKING_BODY_CLASS} { visibility: hidden !important; }
.${MANABI_TRACKING_SECTION_CLASS} { contain: paint style !important; }
.${MANABI_TRACKING_SECTION_HIDDEN_CLASS} { display: none !important; }
${MANABI_TRACKING_SECTION_SELECTOR}.${MANABI_TRACKING_SECTION_BAKED_CLASS} { contain: layout style !important; }
body:not(.${MANABI_TRACKING_SIZE_BAKING_BODY_CLASS}):not(.${MANABI_TRACKING_FORCE_VISIBLE_CLASS}) ${MANABI_TRACKING_SECTION_SELECTOR}:not(.${MANABI_TRACKING_SECTION_VISIBLE_CLASS}) { display: none !important; }
body.${MANABI_TRACKING_FORCE_VISIBLE_CLASS} ${MANABI_TRACKING_SECTION_SELECTOR} { display: block !important; visibility: visible !important; }`
    doc.head.append(style)
}

const logTrackingVisibility = (doc, { reason = 'unknown', container = null } = {}) => {
    if (!doc) return
    const sections = Array.from(doc.querySelectorAll(MANABI_TRACKING_SECTION_SELECTOR))
    const counts = {
        total: sections.length,
        visibleClass: 0,
        bakingClass: 0,
        bakedClass: 0,
        displayNone: 0,
    }
    for (const el of sections) {
        if (!el || el.nodeType !== 1) continue
        if (el.classList.contains(MANABI_TRACKING_SECTION_VISIBLE_CLASS)) counts.visibleClass++
        if (el.classList.contains(MANABI_TRACKING_SECTION_BAKING_CLASS)) counts.bakingClass++
        if (el.classList.contains(MANABI_TRACKING_SECTION_BAKED_CLASS)) counts.bakedClass++
        try {
            const disp = doc.defaultView?.getComputedStyle?.(el)?.display
            if (disp === 'none') counts.displayNone++
        } catch {}
    }

    // visibility logging suppressed
}

// tracking rect samples logging removed for noise reduction
const logTrackingRectSamples = () => {}

const findNextTrackingSectionSibling = section => {
    if (!section) return null
    let cursor = section.nextElementSibling
    while (cursor) {
        if (cursor.classList?.contains?.(MANABI_TRACKING_SECTION_CLASS)) return cursor
        cursor = cursor.nextElementSibling
    }
    return null
}

const findPrevTrackingSectionSibling = section => {
    if (!section) return null
    let cursor = section.previousElementSibling
    while (cursor) {
        if (cursor.classList?.contains?.(MANABI_TRACKING_SECTION_CLASS)) return cursor
        cursor = cursor.previousElementSibling
    }
    return null
}

const applySentinelVisibilityToTrackingSections = (doc, {
    visibleSentinels = [],
    container = null,
    sectionsCache = null,
} = {}) => {
    if (!doc) return
    const sections = Array.isArray(sectionsCache) && sectionsCache.length
        ? sectionsCache
        : Array.from(doc.querySelectorAll(MANABI_TRACKING_SECTION_SELECTOR))
    if (sections.length === 0) return

    const visibleSections = new Set()
    const visibleCount = visibleSentinels instanceof Set
        ? visibleSentinels.size
        : (Array.isArray(visibleSentinels) ? visibleSentinels.length : 0)
    const markSectionVisible = (section, { includeBuffer = true } = {}) => {
        if (!section?.classList?.contains?.(MANABI_TRACKING_SECTION_CLASS)) return
        visibleSections.add(section)
        if (includeBuffer) {
            const buffer = findNextTrackingSectionSibling(section)
            if (buffer) visibleSections.add(buffer)
            const prevBuffer = findPrevTrackingSectionSibling(section)
            if (prevBuffer) visibleSections.add(prevBuffer)
        }
    }

    for (const sentinel of visibleSentinels) {
        const section = sentinel?.closest?.(MANABI_TRACKING_SECTION_SELECTOR)
        markSectionVisible(section, { includeBuffer: true })
    }

    // Fallback: if intersections were reported but none mapped to a section,
    // ensure we still have an anchor section to avoid getting stuck in force-visible.
    if (visibleSections.size === 0 && visibleCount > 0) {
        const fallback = sections[0]
        markSectionVisible(fallback, { includeBuffer: true })
    }

    if (visibleSections.size === 0) {
        let seeded = 0
        for (let i = 0; i < Math.min(3, sections.length); i++) {
            markSectionVisible(sections[i], { includeBuffer: false })
            seeded++
        }
        const appliedForceVisible = !doc.body?.classList?.contains?.(MANABI_TRACKING_FORCE_VISIBLE_CLASS)
        if (appliedForceVisible) {
            doc.body.classList.add(MANABI_TRACKING_FORCE_VISIBLE_CLASS)
        }
    } else if (doc.body?.classList?.contains?.(MANABI_TRACKING_FORCE_VISIBLE_CLASS)) {
        doc.body.classList.remove(MANABI_TRACKING_FORCE_VISIBLE_CLASS)
    }

    for (const section of sections) {
        if (visibleSections.has(section)) section.classList.add(MANABI_TRACKING_SECTION_VISIBLE_CLASS)
        else section.classList.remove(MANABI_TRACKING_SECTION_VISIBLE_CLASS)
    }

    // Disabled noisy tracking-visibility logs

}

const waitForStableSectionSize = (section, {
    maxEvents = MANABI_TRACKING_SIZE_STABLE_MAX_EVENTS,
    requiredStreak = MANABI_TRACKING_SIZE_STABLE_REQUIRED_STREAK,
} = {}) => new Promise(resolve => {
    if (!(section instanceof Element)) return resolve(null)

    let lastRect = null
    let stableCount = 0
    let events = 0
    let finished = false

    const finish = rect => {
        if (finished) return
        finished = true
        resizeObserver.disconnect()
        resolve(rect ?? lastRect)
    }

    const resizeObserver = new ResizeObserver(entries => {
        if (finished) return
        events++
        const rect = entries?.[0]?.contentRect
        if (!rect) return
        const roundedRect = {
            width: Math.round(rect.width * 1000) / 1000,
            height: Math.round(rect.height * 1000) / 1000,
        }
        const unchanged =
            lastRect &&
            roundedRect.width === lastRect.width &&
            roundedRect.height === lastRect.height

        lastRect = roundedRect
        stableCount = unchanged ? stableCount + 1 : 1

        if (stableCount >= requiredStreak || events >= maxEvents) finish(roundedRect)
    })

    const initialRect = section.getBoundingClientRect?.()
    if (initialRect) {
        logEBookPerf('RECT.wait-stable-section-initial', {
            id: section?.id || null,
            width: Math.round(initialRect.width * 1000) / 1000,
            height: Math.round(initialRect.height * 1000) / 1000,
        })
    }
    if (initialRect) {
        lastRect = {
            width: Math.round(initialRect.width * 1000) / 1000,
            height: Math.round(initialRect.height * 1000) / 1000,
        }
    }

    resizeObserver.observe(section)

    // safety: if no events fire, resolve on next frame with the last known rect
    requestAnimationFrame(() => {
        if (!finished && lastRect) finish(lastRect)
    })
})

const waitForStableDocumentSize = (doc, {
    maxEvents = MANABI_TRACKING_DOC_STABLE_MAX_EVENTS,
    requiredStreak = MANABI_TRACKING_DOC_STABLE_REQUIRED_STREAK,
} = {}) => new Promise(resolve => {
    const body = doc?.body
    if (!body) return resolve(null)

    let lastRect = null
    let stableCount = 0
    let events = 0
    let finished = false

    const finish = rect => {
        if (finished) return
        finished = true
        resizeObserver.disconnect()
        resolve(rect ?? lastRect)
    }

    const resizeObserver = new ResizeObserver(entries => {
        if (finished) return
        events++
        const rect = entries?.[0]?.contentRect
        if (!rect) return
        const roundedRect = {
            width: Math.round(rect.width * 1000) / 1000,
            height: Math.round(rect.height * 1000) / 1000,
        }
        const unchanged =
            lastRect &&
            roundedRect.width === lastRect.width &&
            roundedRect.height === lastRect.height

        lastRect = roundedRect
        stableCount = unchanged ? stableCount + 1 : 1

        if (stableCount >= requiredStreak || events >= maxEvents) finish(roundedRect)
    })

    const initialRect = body.getBoundingClientRect?.()
    if (initialRect) {
        logEBookPerf('RECT.wait-stable-doc-initial', {
            width: Math.round(initialRect.width * 1000) / 1000,
            height: Math.round(initialRect.height * 1000) / 1000,
        })
    }
    if (initialRect) {
        lastRect = {
            width: Math.round(initialRect.width * 1000) / 1000,
            height: Math.round(initialRect.height * 1000) / 1000,
        }
    }

    resizeObserver.observe(body)

    requestAnimationFrame(() => {
        if (!finished && lastRect) finish(lastRect)
    })
})


const serializeElementTag = element => {
    // iframe elements come from a different global, so avoid instanceof checks.
    if (!element || element.nodeType !== 1) return ''
    const safeEscape = v => String(v ?? '').replace(/"/g, '&quot;')
    try {
        const shallow = element.cloneNode(false)
        const html = shallow?.outerHTML
        if (html && html.length > 0) return html
    } catch (error) {
        // swallow and fall through
    }

    const tag = (element.tagName || element.nodeName || 'div').toLowerCase()
    const attrs = Array.from(element.attributes ?? [], ({ name, value }) =>
        value === '' ? name : `${name}="${safeEscape(value)}"`)
    const attrString = attrs.length ? ` ${attrs.join(' ')}` : ''
    return `<${tag}${attrString}></${tag}>`
}

const inlineBlockSizesForWritingMode = (rect, vertical) => {
    const inlineSize = vertical ? rect.height : rect.width
    const blockSize = vertical ? rect.width : rect.height
    return {
        inlineSize,
        blockSize
    }
}

const measureSectionSizes = (el, vertical) => {
    logEBookPerf('RECT.before-measure', {
        id: el?.id || null,
        baked: el?.hasAttribute?.(MANABI_TRACKING_SIZE_BAKED_ATTR) || false,
    })
    const rects = Array.from(el.getClientRects?.() ?? []).filter(r => r && (r.width || r.height))
    if (rects.length === 0) return null

    // Column gap (px); fall back to 0 if unavailable
    let gap = 0
    try {
        const cs = el.ownerDocument?.defaultView?.getComputedStyle?.(el)
        gap = parseFloat(cs?.columnGap) || 0
    } catch {}

    // Axis-aware aggregation:
    // Horizontal writing: inline = max column width; block = sum of column heights + gaps.
    // Vertical writing:   inline = max column height; block = sum of column widths + gaps.
    const inlineLengths = rects.map(r => vertical ? r.height : r.width)
    const blockLengths = rects.map(r => vertical ? r.width : r.height)
    const inlineSize = Math.max(...inlineLengths)
    const blockSize = blockLengths.reduce((acc, v) => acc + v, 0) + gap * Math.max(0, rects.length - 1)

    // Minimal diagnostics
    return {
        inlineSize,
        blockSize,
        multiColumn: rects.length > 1,
    }
}

const measureElementLogicalSize = (el, vertical) => {
    if (!(el instanceof Element)) return null
    logEBookPerf('RECT.getBoundingClientRect', {
        id: el?.id || null,
        baked: el?.hasAttribute?.(MANABI_TRACKING_SIZE_BAKED_ATTR) || false,
    })
    const rect = el.getBoundingClientRect?.()
    if (!rect) return null
    return inlineBlockSizesForWritingMode(rect, vertical)
}

const bakeTrackingSectionSizes = async (doc, {
    vertical,
    batchSize = MANABI_TRACKING_SIZE_BAKE_BATCH_SIZE,
    reason = 'unspecified',
    sectionIndex = null,
    bookId = null,
    sectionHref = null,
} = {}) => {
    if (!doc) return
    if (!MANABI_TRACKING_SIZE_BAKE_ENABLED) return

    const body = doc.body
    if (!body) return

    revealDocumentContentForBake(doc)

    ensureTrackingSizeBakeStyles(doc)

    // Wait for fonts to settle to reduce post-bake growth
    try { await doc.fonts?.ready } catch {}

    const sections = Array.from(doc.querySelectorAll(MANABI_TRACKING_SECTION_SELECTOR))
    if (sections.length === 0) return

    const viewport = {
        width: Math.round(doc.documentElement?.clientWidth ?? 0),
        height: Math.round(doc.documentElement?.clientHeight ?? 0),
        dpr: Math.round((doc.defaultView?.devicePixelRatio ?? 1) * 1000) / 1000,
        safeTop: Math.round((globalThis.manabiSafeAreaInsets?.top ?? 0) * 1000) / 1000,
        safeBottom: Math.round((globalThis.manabiSafeAreaInsets?.bottom ?? 0) * 1000) / 1000,
        safeLeft: Math.round((globalThis.manabiSafeAreaInsets?.left ?? 0) * 1000) / 1000,
        safeRight: Math.round((globalThis.manabiSafeAreaInsets?.right ?? 0) * 1000) / 1000,
    }
    const initialViewportBlockTarget = vertical
        ? Math.max(1, viewport.width + viewport.safeLeft + viewport.safeRight)
        : Math.max(1, viewport.height + viewport.safeTop + viewport.safeBottom)
    let settingsKey = globalThis.paginationTrackingSettingsKey ?? ''
    if (!settingsKey) {
        try {
            const cs = doc?.defaultView?.getComputedStyle?.(doc.body)
            const fontSize = cs?.fontSize || '0'
            const fontFamily = (cs?.fontFamily || '').split(',')[0]?.trim?.() || 'unknown'
            settingsKey = `fallback|font:${fontSize}|family:${fontFamily}`
        } catch {}
    }
    const writingModeKey = globalThis.manabiTrackingWritingMode || (vertical ? 'vertical-rl' : 'horizontal-ltr')
    const cacheKey = [
        MANABI_TRACKING_CACHE_VERSION,
        settingsKey || 'no-settings',
        writingModeKey,
        `rtl:${globalThis.manabiTrackingRTL ? 1 : 0}`,
        `vw:${viewport.width}`,
        `vh:${viewport.height}`,
        `dpr:${viewport.dpr}`,
        `safe:${viewport.safeTop},${viewport.safeRight},${viewport.safeBottom},${viewport.safeLeft}`,
        `sect:${sectionIndex ?? -1}`,
        `book:${globalThis.paginationTrackingBookKey || bookId || ''}`,
        `href:${sectionHref || ''}`,
    ].join('|')


    // Try to hydrate from cache first
    const cachedEntries = await requestTrackingSizeCache({ command: 'get', key: cacheKey })
    logEBookPerf('tracking-size-cache-fetched', {
        key: cacheKey,
        status: cachedEntries === null || cachedEntries === undefined ? 'miss' : 'hit',
        entries: Array.isArray(cachedEntries) ? cachedEntries.length : null,
    })
    if (cachedEntries === null || cachedEntries === undefined) {
        // treat null as miss, but avoid logging miss twice
    }

    // Ensure the document layout has settled before hiding/baking sections.
    await waitForStableDocumentSize(doc)

    const bakedTags = []
    const bakedEntryMap = new Map()
    const startTs = performance?.now?.() ?? Date.now()
    const addedBodyClass = MANABI_TRACKING_SIZE_BAKING_OPTIMIZED && !body.classList.contains(MANABI_TRACKING_SIZE_BAKING_BODY_CLASS)

    // Reset any previous bake markers so we always measure fresh sizes.
    for (const el of sections) {
        el.removeAttribute(MANABI_TRACKING_SIZE_BAKED_ATTR)
        el.classList.remove(MANABI_TRACKING_SECTION_BAKED_CLASS)
        if (MANABI_TRACKING_SIZE_BAKING_OPTIMIZED) el.classList.remove(MANABI_TRACKING_SECTION_BAKING_CLASS)
        el.classList.remove(MANABI_TRACKING_SECTION_HIDDEN_CLASS)
        el.style.removeProperty('block-size')
        el.style.removeProperty('inline-size')
        el.style.removeProperty('position')
        el.style.removeProperty('top')
        el.style.removeProperty('left')
        el.style.removeProperty('right')
        el.style.removeProperty('bottom')
    }

    const blockStartProp = vertical
        ? (globalThis.manabiTrackingVerticalRTL ? 'right' : 'left')
        : 'top'
    const crossProp = vertical ? 'top' : 'left'

    const applyCachedEntries = (cached, container) => {
        if (!Array.isArray(cached)) return 0
        let applied = 0
        for (const entry of cached) {
            const el = doc.getElementById(entry?.id)
            if (!el) continue
            const inlineSize = Number(entry.inlineSize)
            const blockSize = Number(entry.blockSize)
            if (!Number.isFinite(inlineSize) || !Number.isFinite(blockSize)) continue
            logEBookPerf('RECT.cache-apply', {
                id: el.id || null,
                inlineSize,
                blockSize,
            })
            el.style.setProperty('inline-size', formatPx(inlineSize), 'important')
            el.style.setProperty('block-size', formatPx(blockSize), 'important')
            el.setAttribute(MANABI_TRACKING_SIZE_BAKED_ATTR, 'true')
            el.classList.add(MANABI_TRACKING_SECTION_BAKED_CLASS)
            el.classList.remove(MANABI_TRACKING_SECTION_HIDDEN_CLASS)
            bakedEntryMap.set(entry.id, {
                id: entry.id,
                inlineSize,
                blockSize,
                blockStart: entry.blockStart ?? null,
            })
            applied++
        }

        const containerEntry = cached.find(e => e?.id === '__container__')
        if (containerEntry && container instanceof HTMLElement) {
            const inlineSize = Number(containerEntry.inlineSize)
            const blockSize = Number(containerEntry.blockSize)
            if (Number.isFinite(inlineSize) && Number.isFinite(blockSize)) {
                if (vertical) {
                    container.style.setProperty('width', formatPx(blockSize), 'important')
                    container.style.setProperty('height', formatPx(inlineSize), 'important')
                } else {
                    container.style.setProperty('height', formatPx(blockSize), 'important')
                    container.style.setProperty('width', formatPx(inlineSize), 'important')
                }
            }
            bakedEntryMap.set('__container__', {
                id: '__container__',
                inlineSize,
                blockSize,
                blockStart: 0,
            })
        }
        if (applied > 0) {
            globalThis.manabiTrackingAppliedFromCache = true
        } else {
            globalThis.manabiTrackingAppliedFromCache = false
        }
        return applied
    }

    const container = sections[0]?.parentElement
    const appliedFromCache = applyCachedEntries(cachedEntries, container)
    logEBookPerf('tracking-size-cache-apply', {
        key: cacheKey,
        applied: appliedFromCache,
        total: sections.length,
        missing: Math.max(0, sections.length - appliedFromCache),
    })

    if (appliedFromCache !== sections.length) {
        const missingIds = sections
            .filter(el => !bakedEntryMap.has(el.id))
            .map(el => el.id || '')
    }

    const hasContainerCache = bakedEntryMap.has('__container__')
        if (appliedFromCache === sections.length) {
            applyAbsoluteLayout()
            seedInitialVisibility()
            // tracking visibility logs removed for noise reduction
            const handler = globalThis.webkit?.messageHandlers?.[MANABI_TRACKING_CACHE_HANDLER]
            try { doc.manabiTrackingSectionIOApply?.(doc.manabiTrackingSectionIO?.takeRecords?.() ?? []) } catch {}
        return
    }

    if (addedBodyClass) body.classList.add(MANABI_TRACKING_SIZE_BAKING_BODY_CLASS)
    // logging removed

    let bakedCount = 0
    let multiColumnCount = 0
    let coverageBlock = 0
    let coverageCursor = 0
    let initialViewportReleased = !addedBodyClass // if we never hid body, consider it already released

    const hideTrailing = startIndex => {
        for (let t = startIndex; t < sections.length; t++) {
            const el = sections[t]
            if (!el.getAttribute(MANABI_TRACKING_SIZE_BAKED_ATTR)) {
                el.classList.add(MANABI_TRACKING_SECTION_HIDDEN_CLASS)
            }
        }
    }

    const unhideWindow = (startIndex, count) => {
        for (let t = startIndex; t < Math.min(sections.length, startIndex + count); t++) {
            sections[t].classList.remove(MANABI_TRACKING_SECTION_HIDDEN_CLASS)
        }
    }

    const bakeSection = async section => {
        if (!section || section.nodeType !== 1) return null
        const el = section
        if (el.hasAttribute(MANABI_TRACKING_SIZE_BAKED_ATTR)) {
            logEBookPerf('tracking-size-measure-skip', {
                id: el.id || null,
                reason: 'already-baked',
            })
            return null
        }
        if (MANABI_TRACKING_SIZE_BAKING_OPTIMIZED) el.classList.add(MANABI_TRACKING_SECTION_BAKING_CLASS)

        try {
            await waitForStableSectionSize(el)
            const sizes = measureSectionSizes(el, vertical)
            if (!sizes) return null
            const { inlineSize, blockSize, multiColumn } = sizes
            if (!Number.isFinite(blockSize) || blockSize <= 0) return null
            if (!Number.isFinite(inlineSize) || inlineSize <= 0) return null

            el.style.setProperty('block-size', formatPx(blockSize), 'important')
            el.style.setProperty('inline-size', formatPx(inlineSize), 'important')
            el.setAttribute(MANABI_TRACKING_SIZE_BAKED_ATTR, 'true')
            el.classList.add(MANABI_TRACKING_SECTION_BAKED_CLASS)
            el.classList.remove(MANABI_TRACKING_SECTION_HIDDEN_CLASS)

            bakedTags.push(serializeElementTag(el))
            if (multiColumn) multiColumnCount++
            bakedCount++
            const entry = { id: el.id || '', inlineSize, blockSize }
            bakedEntryMap.set(entry.id, entry)
            logEBookPerf('tracking-size-measured', {
                id: entry.id,
                inlineSize,
                blockSize,
                multiColumn,
            })
            return sizes
        } finally {
            if (MANABI_TRACKING_SIZE_BAKING_OPTIMIZED) el.classList.remove(MANABI_TRACKING_SECTION_BAKING_CLASS)
        }
    }

    const tryAdvanceInitialViewport = () => {
        while (coverageCursor < sections.length) {
            const el = sections[coverageCursor]
            if (!el?.hasAttribute?.(MANABI_TRACKING_SIZE_BAKED_ATTR)) break

            const entry = bakedEntryMap.get(el.id || '')
            let blockSize = entry?.blockSize
            if (!Number.isFinite(blockSize)) {
                const styleBlock = parseFloat(el.style?.getPropertyValue?.('block-size')) || null
                if (Number.isFinite(styleBlock)) blockSize = styleBlock
            }
            if (!Number.isFinite(blockSize)) break

            coverageBlock += blockSize
            coverageCursor++
            if (coverageBlock >= initialViewportBlockTarget) break
        }

        if (!initialViewportReleased && bakedCount > 0 && coverageBlock >= initialViewportBlockTarget) {
            initialViewportReleased = true
            if (addedBodyClass && body.classList.contains(MANABI_TRACKING_SIZE_BAKING_BODY_CLASS)) {
                body.classList.remove(MANABI_TRACKING_SIZE_BAKING_BODY_CLASS)
            }
            seedInitialVisibility()
            logEBookPerf('tracking-size-bake-viewport-ready', {
                reason,
                sectionIndex,
                bakedCount,
                coverageBlock,
                target: initialViewportBlockTarget,
                batchSize,
            })
        }
    }

    // Batching previously used windowed slices; keep the code here for easy re-enable if needed.
    // const windowSize = vertical ? Math.max(3, batchSize) : batchSize
    // for (let i = 0; i < sections.length; i += windowSize) {
    //     hideTrailing(i + windowSize)
    //     unhideWindow(i, windowSize)
    //     const windowSections = sections.slice(i, i + windowSize)
    //     const results = await Promise.all(windowSections.map(bakeSection))
    //     tryAdvanceInitialViewport()
    // }
    try {
        await Promise.all(sections.map(bakeSection))
        tryAdvanceInitialViewport()
    } finally {
        // unhide everything at end
        for (const el of sections) el.classList.remove(MANABI_TRACKING_SECTION_HIDDEN_CLASS)
        if (addedBodyClass) body.classList.remove(MANABI_TRACKING_SIZE_BAKING_BODY_CLASS)
    }

    function seedInitialVisibility() {
        // Seed a few items as visible so the page isn't blank before IO fires.
        let seeded = 0
        for (const el of sections) {
            if (!el || el.nodeType !== 1) continue
            el.classList.remove(MANABI_TRACKING_SECTION_HIDDEN_CLASS)
            if (seeded < 3) {
                el.classList.add(MANABI_TRACKING_SECTION_VISIBLE_CLASS)
                seeded++
            } else {
                el.classList.remove(MANABI_TRACKING_SECTION_VISIBLE_CLASS)
            }
        }
    }

    // After all sizes are known, clear any stale absolute positioning and refresh cached sizes.
    function applyAbsoluteLayout() {
        if (!container) {
            return null
        }
        const siblings = Array.from(container.children ?? []).filter(el =>
            el.classList?.contains?.(MANABI_TRACKING_SECTION_CLASS)
        )
        if (siblings.length === 0) {
            return null
        }

        container.style.removeProperty('position')

        let blockCursor = 0
        let maxInline = 0

        const getMarginAfter = el => {
            try {
                const cs = doc.defaultView?.getComputedStyle?.(el)
                if (!cs) return 0
                if (vertical) {
                    return parseFloat(cs[globalThis.manabiTrackingVerticalRTL ? 'marginLeft' : 'marginRight']) || 0
                }
                return parseFloat(cs.marginBottom) || 0
            } catch { return 0 }
        }

        for (const el of siblings) {
            if (!el || el.nodeType !== 1) continue
            const id = el.id || ''
            const bakedSize = bakedEntryMap.get(id)
            const logical = bakedSize ?? measureElementLogicalSize(el, vertical)
            let inlineSize = Number(logical?.inlineSize)
            let blockSize = Number(logical?.blockSize)

            // Fallback to a fresh measurement if cached values aren't finite.
            if (!Number.isFinite(inlineSize) || !Number.isFinite(blockSize)) {
                const measured = measureElementLogicalSize(el, vertical)
                inlineSize = Number(measured?.inlineSize)
                blockSize = Number(measured?.blockSize)
            }

            // Fallback again to inline/block-size styles if still non-finite.
            if (!Number.isFinite(inlineSize) || !Number.isFinite(blockSize)) {
                const styleInline = parseFloat(el.style.getPropertyValue('inline-size'))
                const styleBlock = parseFloat(el.style.getPropertyValue('block-size'))
                if (Number.isFinite(styleInline) && Number.isFinite(styleBlock)) {
                    inlineSize = styleInline
                    blockSize = styleBlock
                }
            }

            if (!Number.isFinite(inlineSize) || !Number.isFinite(blockSize)) {
                continue
            }

            maxInline = Math.max(maxInline, inlineSize)

            const blockProp = vertical ? (globalThis.manabiTrackingVerticalRTL ? 'right' : 'left') : 'top'
            const crossProp = vertical ? 'top' : 'left'
            el.style.removeProperty('position')
            el.style.removeProperty(blockProp)
            el.style.removeProperty(crossProp)

            const entry = bakedEntryMap.get(id)
            if (entry) entry.blockStart = blockCursor

            blockCursor += blockSize + getMarginAfter(el)
        }

        if (vertical) {
            container.style.removeProperty('width')
            container.style.removeProperty('height')
            bakedEntryMap.set('__container__', { id: '__container__', inlineSize: maxInline, blockSize: blockCursor, blockStart: 0 })
        } else {
            container.style.removeProperty('height')
            container.style.removeProperty('width')
            bakedEntryMap.set('__container__', { id: '__container__', inlineSize: maxInline, blockSize: blockCursor, blockStart: 0 })
        }

    }

    applyAbsoluteLayout()
    seedInitialVisibility()
    // tracking visibility logs removed for noise reduction

    const durationMs = (performance?.now?.() ?? Date.now()) - startTs

        try {
            const handler = globalThis.webkit?.messageHandlers?.[MANABI_TRACKING_CACHE_HANDLER]
            const entriesForCache = Array.from(bakedEntryMap.values())
            if (handler?.postMessage && entriesForCache.length > 0) {
                handler.postMessage({
                    command: 'set',
                    key: cacheKey,
                    entries: entriesForCache,
                    reason,
                })
            }
        } catch (error) {
            // ignore cache store errors
        }

}

// Geometry measurement disabled: keep signature for compatibility, do nothing.
const measureTrackingSection = _element => {}

const bakeTrackingSectionGeometries = async (_doc, { reason = 'unknown' } = {}) => {
    return { sections: 0, durationMs: 0, success: true, skipped: 'disabled' }
}

// collapsed range doesn't return client rects sometimes (or always?)
// try make get a non-collapsed range or element
const uncollapse = range => {
    if (!range?.collapsed) return range
    const {
        endOffset,
        endContainer
    } = range
    if (endContainer.nodeType === 1) {
        const node = endContainer.childNodes[endOffset]
        if (node?.nodeType === 1) return node
        return endContainer
    }
    if (endOffset + 1 < endContainer.length) range.setEnd(endContainer, endOffset + 1)
    else if (endOffset > 1) range.setStart(endContainer, endOffset - 1)
    else return endContainer.parentNode
    return range
}

const NF = globalThis.NodeFilter ?? {}
const {
    SHOW_ELEMENT,
    SHOW_TEXT,
    SHOW_CDATA_SECTION,
    FILTER_ACCEPT,
    FILTER_REJECT,
    FILTER_SKIP
} = NF

/**
 * Creates a hidden iframe with a cloned document (head and empty body) to compute computed style.
 * @param {Document} sourceDoc - The source document to clone.
 * @returns {Promise<{cs: CSSStyleDeclaration, doc: Document}>} - Computed style and iframe document.
 */
async function getBodylessComputedStyle(sourceDoc) {
    // 1. Clone a minimal document
    const cloneDoc = document.implementation.createHTMLDocument();

    // 2. Deep-clone the <head>, stripping unwanted styles/scripts
    const clonedHead = sourceDoc.head.cloneNode(true);
    ['manabi-font-data', 'manabi-custom-fonts'].forEach(id => {
        const el = clonedHead.querySelector(`#${id}`);
        if (el) el.remove();
    });
    // Refresh blob-based CSS
    for (const link of clonedHead.querySelectorAll('link[rel="stylesheet"][href^="blob:"]')) {
        try {
            const css = await fetch(link.href).then(r => r.text());
            const blobUrl = URL.createObjectURL(new Blob([css], {
                type: 'text/css'
            }));
            link.href = blobUrl;
        } catch {
            link.remove();
        }
    }
    clonedHead.querySelectorAll('script').forEach(el => el.remove());
    cloneDoc.head.replaceWith(clonedHead);

    // 3. Shallow-clone the <body> (to preserve dir, but empty)
    const bodyClone = sourceDoc.body.cloneNode(false);
    cloneDoc.body.replaceWith(bodyClone);
    // Copy all attributes from the source <html> (e.g. xmlns, xml:lang, class, lang)
    for (const { name, value } of sourceDoc.documentElement.attributes) {
        cloneDoc.documentElement.setAttribute(name, value);
    }
    // Override or add the 'dir' attribute explicitly
    cloneDoc.documentElement.setAttribute(
        'dir',
        sourceDoc.documentElement.getAttribute('dir') || ''
    );

    // 4. Serialize the cloneDoc to HTML and create a Blob URL
    const html = '<!doctype html>' + cloneDoc.documentElement.outerHTML;
    const blob = new Blob([html], {
        type: 'text/html'
    });
    const blobUrl = URL.createObjectURL(blob);

    // 5. Create a hidden iframe, append, and wait for load
    const iframe = document.createElement('iframe');
    iframe.style.cssText = 'position:fixed;visibility:hidden;width:0;height:0;border:0;contain:strict;';
    document.documentElement.appendChild(iframe);
    await new Promise(resolve => {
        iframe.onload = resolve;
        iframe.src = blobUrl;
    });

    // wait a frame for CSS to apply before measuring
    await new Promise(r => requestAnimationFrame(r));

    // 6. Get computed style and doc
    const bodylessDoc = iframe.contentDocument;
    const bodylessStyle = iframe.contentWindow.getComputedStyle(bodylessDoc.body);

    // 7. Cleanup
    URL.revokeObjectURL(blobUrl);
    iframe.remove();

    return { bodylessStyle, bodylessDoc };
}

/**
 * Determines writing mode and directionality (vertical, verticalRTL, rtl) by using a computed style from a cloned iframe.
 * @param {Document} sourceDoc - The source document to analyze.
 * @returns {Promise<{vertical: boolean, verticalRTL: boolean, rtl: boolean}>}
 */
async function getDirection({ bodylessStyle, bodylessDoc }) {
    const writingMode = bodylessStyle.writingMode;
    const direction = bodylessStyle.direction;
    const vertical = writingMode === 'vertical-rl' || writingMode === 'vertical-lr';
    const verticalRTL = writingMode === 'vertical-rl';
    const rtl =
        bodylessDoc.body.dir === 'rtl' ||
        direction === 'rtl' ||
        bodylessDoc.documentElement.dir === 'rtl';
    return { vertical, verticalRTL, rtl };
}

const makeMarginals = (length, part) => Array.from({
    length
}, () => {
    const div = document.createElement('div')
    const child = document.createElement('div')
    div.append(child)
    child.setAttribute('part', part)
    return div
})

const setStylesImportant = (el, styles) => {
    const {
        style
    } = el
    for (const [k, v] of Object.entries(styles)) style.setProperty(k, v, 'important')
}

class View {
    #wait = ms => new Promise(resolve => setTimeout(resolve, ms))
    #debouncedExpand
    #inExpand = false
    #hasResizerObserverTriggered = false
    #lastResizerRect = null
    #lastBodyRect = null
    #lastContainerRect = null
    #resizeEventSeq = 0
    #resizeObserverFrame = null
    #pendingResizeRect = null
    #resizeObserver = null
    #styleCache = new WeakMap()
    #isCacheWarmer = false
    cachedViewSize = null
    getLastBodyRect() {
        // Rounded body rect captured by the resize observer; avoids forcing layout reads elsewhere.
        return this.#lastBodyRect
    }
    #handleResize(newSize) {
        if (!newSize) return
        // Skip resize work while an expand is actively adjusting iframe dimensions; those
        // resizes are expected and immediately followed by the real layout pass.
        if (this.#inExpand) return
        const roundRect = r => r ? {
            width: Math.round(r.width),
            height: Math.round(r.height),
            top: Math.round(r.top),
            left: Math.round(r.left),
        } : null
        const bodyRect = roundRect(this.document?.body?.getBoundingClientRect?.())
        const containerRect = roundRect(this.container?.getBoundingClientRect?.())
        logEBookPerf('RECT.resize-read', {
            body: bodyRect,
            container: containerRect,
            seq: this.#resizeEventSeq,
        })
        ++this.#resizeEventSeq

        if (!this.#hasResizerObserverTriggered) {
            this.#hasResizerObserverTriggered = true;
            this.#lastResizerRect = newSize;
            this.#lastBodyRect = bodyRect;
            this.#lastContainerRect = containerRect;
            return;
        }

        const old = this.#lastResizerRect;
        const oldBody = this.#lastBodyRect;
        const oldContainer = this.#lastContainerRect;
        const changedContent =
            !old ||
            newSize.width !== old.width ||
            newSize.height !== old.height ||
            newSize.top !== old.top ||
            newSize.left !== old.left;
        const eps = 1; // px tolerance
        const sameRect = (a, b) =>
            a && b &&
            Math.abs(a.width - b.width) <= eps &&
            Math.abs(a.height - b.height) <= eps &&
            Math.abs(a.top - b.top) <= eps &&
            Math.abs(a.left - b.left) <= eps;
        const changedBody = !sameRect(bodyRect, oldBody);
        const changedContainer = !sameRect(containerRect, oldContainer);

        if (changedContent) {
            this.#lastResizerRect = newSize
            this.#lastBodyRect = bodyRect;
            this.#lastContainerRect = containerRect;

            if (!changedBody && !changedContainer) {
                return
            }

            this.cachedViewSize = null

            // Only trigger size/geometry bake after the new size stays stable for one more frame.
            requestAnimationFrame(() => {
        const bodyRect = this.document?.body?.getBoundingClientRect?.()
                if (!bodyRect) return
                const stableSize = {
                    width: Math.round(bodyRect.width),
                    height: Math.round(bodyRect.height),
                    top: Math.round(bodyRect.top),
                    left: Math.round(bodyRect.left),
                }
                logEBookPerf('RECT.resize-stable-check', {
                    stableSize,
                    lastResizer: this.#lastResizerRect,
                })
                const still =
                    stableSize.width === this.#lastResizerRect?.width &&
                    stableSize.height === this.#lastResizerRect?.height &&
                    stableSize.top === this.#lastResizerRect?.top &&
                    stableSize.left === this.#lastResizerRect?.left

                if (!still) {
                    return
                }

                logEBookPerf('EXPAND.callsite', {
                    source: 'view-resize-stable',
                    suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
                    ready: this.container?.trackingSizeBakeReadyPublic ?? null,
                })
                this.container?.requestTrackingSectionGeometryBake?.({
                    reason: 'iframe-resize',
                    restoreLocation: true
                })
                if (MANABI_TRACKING_SIZE_BAKING_OPTIMIZED && MANABI_TRACKING_SIZE_RESIZE_TRIGGERS_ENABLED) {
                    this.container?.requestTrackingSectionSizeBake?.({
                        reason: 'iframe-resize',
                        rect: stableSize,
                    })
                }
            })
        }
    }
    #element = document.createElement('div')
    #iframe = document.createElement('iframe')
    #contentRange = document.createRange()
    #overlayer
    #vertical = null
    #verticalRTL = null
    #rtl = null
    #directionReadyResolve = null;
    #directionReady = new Promise(r => (this.#directionReadyResolve = r));
    #column = true
    #size
    layout = {}
    constructor({
        container,
        onBeforeExpand,
        onExpand,
        isCacheWarmer
    }) {
        this.container = container
        this.#isCacheWarmer = isCacheWarmer
        this.#debouncedExpand = debounce(this.expand.bind(this), 999)
        this.onBeforeExpand = onBeforeExpand
        this.onExpand = onExpand
        //        this.#iframe.setAttribute('part', 'filter')
        this.#element.append(this.#iframe)
        Object.assign(this.#element.style, {
            boxSizing: 'content-box',
            position: 'relative',
            overflow: 'hidden',
            flex: '0 0 auto',
            width: '100%',
            height: '100%',
            display: 'flex',
            justifyContent: 'center',
            alignItems: 'center',
        })
        Object.assign(this.#iframe.style, {
            overflow: 'hidden',
            border: '0',
            //            display: 'none',
            display: 'block',
            width: '100%',
            height: '100%',
        })
        // `allow-scripts` is needed for events because of WebKit bug
        // https://bugs.webkit.org/show_bug.cgi?id=218086
        //        this.#iframe.setAttribute('sandbox', 'allow-scripts allow-same-origin allow-popups allow-downloads')
        //this.#iframe.setAttribute('sandbox', 'allow-same-origin allow-scripts') // Breaks font-src data: blobs...
        this.#iframe.setAttribute('scrolling', 'no')

        this.#resizeObserver = new ResizeObserver(entries => {
            if (this.#isCacheWarmer) return;
            const entry = entries[0];
            if (!entry) return;
            const rect = entry.contentRect;
            this.#pendingResizeRect = {
                width: Math.round(rect.width),
                height: Math.round(rect.height),
                top: Math.round(rect.top),
                left: Math.round(rect.left),
            }
            if (this.#resizeObserverFrame !== null) cancelAnimationFrame(this.#resizeObserverFrame)
            this.#resizeObserverFrame = requestAnimationFrame(() => {
                this.#resizeObserverFrame = null
                this.#handleResize(this.#pendingResizeRect)
            })
        })
    }

    revealIframeForBake(reason) {
        if (this.#iframe?.style?.display === 'none') {
            this.#iframe.style.display = 'block'
            logEBookPerf('iframe-display-set', { state: 'shown-for-bake', reason })
        }
    }
    get element() {
        return this.#element
    }
    get document() {
        return this.#iframe.contentDocument
    }
    async load(src, afterLoad, beforeRender, sectionIndex = null) {
        if (typeof src !== 'string') throw new Error(`${src} is not string`)
        // Reset direction flags and promise before loading a new section
        this.#vertical = this.#verticalRTL = this.#rtl = null;
        this.#directionReady = new Promise(r => (this.#directionReadyResolve = r));
        // Hide iframe completely until we intentionally reveal for baking to avoid initial layout/paint cost.
        this.#iframe.style.display = 'none'
        logEBookPerf('iframe-display-set', { state: 'hidden-before-src', src })
        return new Promise(async (resolve) => {
            if (this.#isCacheWarmer) {
                console.log("Don't create View for cache warmers")
                resolve()
            } else {
                this.#iframe.addEventListener('load', async () => {
                    try { await globalThis.manabiWaitForFontCSS?.() } catch {}
                    const doc = this.document

                    try { globalThis.manabiEnsureCustomFonts?.(doc) } catch {}

                    await afterLoad?.(doc)

                    //                    this.#iframe.style.display = 'none'

                    const { bodylessStyle, bodylessDoc } = await getBodylessComputedStyle(doc)
                    const direction = await getDirection({ bodylessStyle, bodylessDoc });
                    this.#vertical = direction.vertical;
                    this.#verticalRTL = direction.verticalRTL;
                    this.#rtl = direction.rtl;
                    globalThis.manabiTrackingVertical = this.#vertical
                    globalThis.manabiTrackingVerticalRTL = this.#verticalRTL
                    globalThis.manabiTrackingRTL = this.#rtl
                    globalThis.manabiTrackingWritingMode = this.#vertical
                        ? (this.#verticalRTL ? 'vertical-rl' : 'vertical-lr')
                        : (this.#rtl ? 'horizontal-rtl' : 'horizontal-ltr')
                    this.#directionReadyResolve?.();

                    this.#contentRange.selectNodeContents(doc.body)

                    const layout = await beforeRender?.({
                        vertical: this.#vertical,
                        rtl: this.#rtl,
                    })

                    // Allow layout/expand only when we're ready to bake: reveal iframe + document, render without expanding, bake, then expand.
                    this.revealIframeForBake('initial-load')
                    revealDocumentContentForBake(doc)

                    // First bake happens before any expand/page sizing.
                    await this.container?.performInitialBakeFromView?.(sectionIndex ?? this.container?.currentIndex, layout)

                    this.#resizeObserver.observe(doc.body)

                    resolve()
                }, {
                    once: true
                })
                this.#iframe.src = src
            }
        })
    }
    async render(layout, { skipExpand = false, source = 'unknown' } = {}) {
        //        console.log("render(layout)...")
        if (!layout) {
            //            console.log("render(layout)... return")
            return
        }
        const suppressingEarlyExpand = (this.container?.suppressBakeOnExpandPublic && !this.container?.trackingSizeBakeReadyPublic)
        if (source === 'unknown' && suppressingEarlyExpand) {
            logEBookPerf('EXPAND.render-skip', {
                reason: 'suppressing-early-render',
                source,
                skipExpand,
                suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
                ready: this.container?.trackingSizeBakeReadyPublic ?? null,
                inExpand: this.#inExpand || false,
            })
            return
        }
        logEBookPerf('render-start', {
            flow: layout.flow,
            column: layout.flow !== 'scrolled',
            vertical: this.#vertical,
            isCacheWarmer: this.#isCacheWarmer,
        })
        logEBookPerf('EXPAND.render-start', {
            flow: layout.flow,
            skipExpand,
            source,
            suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
            ready: this.container?.trackingSizeBakeReadyPublic ?? null,
            inExpand: this.#inExpand || false,
        })
        layout.usePaginate = false // disable Paginate integration for now
        this.#column = layout.flow !== 'scrolled'
        this.layout = layout

        if (this.#vertical) {
            this.document.body?.classList.add('reader-vertical-writing')
        }

        if (this.#column) {
            //            console.log("render(layout)... await columnize(layout)")
            await this.columnize(layout, { skipExpand })
            //            console.log("render(layout)... await'd columnize(layout)")
        } else {
            //            console.log("render(layout)... await scrolled")
            await this.scrolled(layout, { skipExpand })
            //            console.log("render(layout)... await'd scrolled")
        }
        logEBookPerf('render-complete', {
            flow: layout.flow,
            column: this.#column,
            vertical: this.#vertical,
        })
        logEBookPerf('EXPAND.render-complete', {
            flow: layout.flow,
            skipExpand,
            source,
            suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
            ready: this.container?.trackingSizeBakeReadyPublic ?? null,
            inExpand: this.#inExpand || false,
        })
    }
    async scrolled({
        gap,
        columnWidth
    }, { skipExpand = false } = {}) {
        await this.#awaitDirection();
        const vertical = this.#vertical
        const doc = this.document
        const bottomMarginPx = CSS_DEFAULTS.bottomMarginPx;
        logEBookPerf('EXPAND.scrolled-entry', {
            skipExpand,
            suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
            ready: this.container?.trackingSizeBakeReadyPublic ?? null,
        })
        setStylesImportant(doc.documentElement, {
            'box-sizing': 'border-box',
            'padding': vertical ? `${gap}px 0` : `0 ${gap}px`,
            //            border: `${gap}px solid transparent`,
            //            borderWidth: vertical ? `${gap}px 0` : `0 ${gap}px`,
            'column-width': 'auto',
            'height': 'auto',
            'width': 'auto',

            //            // columnize parity
            // columnGap: '0',
            '--paginator-column-gap': `${gap}px`,
            'column-gap': `${gap}px`,
            'column-fill': 'auto',
            'overflow': 'hidden',
            // force wrap long words
            'overflow-wrap': 'anywhere',
            // reset some potentially problematic props
            'position': 'static',
            'border': '0',
            'margin': '0',
            'max-height': 'none',
            'max-width': 'none',
            'min-height': 'none',
            'min-width': 'none',
            // fix glyph clipping in WebKit
            '-webkit-line-box-contain': 'block glyphs replaced',

            // columnize parity
            '--paginator-margin': `${bottomMarginPx}px`,
        })
        // columnize parity
        setStylesImportant(doc.body, {
            [vertical ? 'max-height' : 'max-width']: `${columnWidth}px`,
            'margin': 'auto',
        })
        const canExpand = !skipExpand && !(this.container?.suppressBakeOnExpandPublic && !this.container?.trackingSizeBakeReadyPublic)
        if (canExpand) {
            this.#debouncedExpand()
        } else if (!skipExpand) {
            logEBookPerf('EXPAND.expand-skip', {
                source: 'scrolled',
                suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
                ready: this.container?.trackingSizeBakeReadyPublic ?? null,
            })
        }
        //        await this.expand()
    }
    async columnize({
        width,
        height,
        gap,
        columnWidth,
        divisor,
    }, { skipExpand = false } = {}) {
        //        console.log("columnize...")
        await this.#awaitDirection();
        //        console.log("columnize... await'd direction")
        const vertical = this.#vertical
        this.#size = vertical ? height : width
        logEBookPerf('EXPAND.columnize-entry', {
            skipExpand,
            size: this.#size,
            width,
            height,
            suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
            ready: this.container?.trackingSizeBakeReadyPublic ?? null,
        })
        //        console.log("columnize #size = ", this.#size)

        const doc = this.document
        setStylesImportant(doc.documentElement, {
            'box-sizing': 'border-box',
            'column-width': `${Math.trunc(columnWidth)}px`,
            '--paginator-column-gap': `${gap}px`,
            'column-gap': `${gap}px`,
            'column-fill': 'auto',
            ...(vertical ? {
                'width': `${width}px`
            } : {
                'height': `${height}px`
            }),
            'padding': vertical ? `${gap / 2}px 0` : `0 ${gap / 2}px`,
            'overflow': 'hidden',
            // force wrap long words
            'overflow-wrap': 'break-word', // TODO: anywhere, for japanese?
            // reset some potentially problematic props
            'position': 'static',
            'border': '0',
            'margin': '0',
            'max-height': 'none',
            'max-width': 'none',
            'min-height': 'none',
            'min-width': 'none',
            // fix glyph clipping in WebKit
            '-webkit-line-box-contain': 'block glyphs replaced',
        })
        const bottomMarginPx = CSS_DEFAULTS.bottomMarginPx;
        doc.documentElement.style.setProperty('--paginator-margin', `${bottomMarginPx}px`)
        setStylesImportant(doc.body, {
            'max-height': 'none',
            'max-width': 'none',
            'margin': '0',
        })
        // Don't infinite loop.
        //        if (!this.needsRenderForMutation) {
        //        console.log("columnize... await expand")
        const canExpand = !skipExpand && !(this.container?.suppressBakeOnExpandPublic && !this.container?.trackingSizeBakeReadyPublic)
        if (canExpand) {
            await this.expand()
        } else if (!skipExpand) {
            logEBookPerf('EXPAND.expand-skip', {
                source: 'columnize',
                suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
                ready: this.container?.trackingSizeBakeReadyPublic ?? null,
            })
        }
        //        console.log("columnize... await'd expand")
        //            //            this.#debouncedExpand()
        //        }
    }
    async #awaitDirection() {
        if (this.#vertical === null) await this.#directionReady;
    }
    async expand() {
        logEBookPerf('expand-request', {
            column: this.#column,
            vertical: this.#vertical,
            size: this.#size,
            cacheWarmer: this.#isCacheWarmer,
        })
        logEBookPerf('EXPAND.expand-entry', {
            suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
            trackingReady: this.container?.trackingSizeBakeReadyPublic ?? null,
            pendingReason: this.container?.pendingTrackingSizeBakeReasonPublic ?? null,
            inExpand: this.#inExpand || false,
        })
        this.#inExpand = true
        try {
            await this.onBeforeExpand()
        } catch (error) {
            this.#inExpand = false
            throw error
        }
        //        console.log("expand...")
        return new Promise(resolve => {
            requestAnimationFrame(async () => {
                try {
                    //                console.log("expand... inside 0")
                    const documentElement = this.document?.documentElement
                    const side = this.#vertical ? 'height' : 'width'
                    const otherSide = this.#vertical ? 'width' : 'height'
                    const scrollProp = side === 'width' ? 'scrollWidth' : 'scrollHeight'
                    //                let contentSize = documentElement?.[scrollProp] ?? 0;

                    if (this.#column) {
                        const contentRect = this.#contentRange.getBoundingClientRect()
                        const rootRect = documentElement.getBoundingClientRect()
                        logEBookPerf('RECT.expand-content', {
                            contentRect: { width: contentRect?.width ?? null, height: contentRect?.height ?? null, left: contentRect?.left ?? null, right: contentRect?.right ?? null },
                            rootRect: { width: rootRect?.width ?? null, height: rootRect?.height ?? null, left: rootRect?.left ?? null, right: rootRect?.right ?? null },
                        })
                        // offset caused by column break at the start of the page
                        // which seem to be supported only by WebKit and only for horizontal writing
                        const contentStart = this.#vertical ? 0
                            : this.#rtl ? rootRect.right - contentRect.right : contentRect.left - rootRect.left
                        const contentSize = contentStart + contentRect[side]
                        const pageCount = Math.ceil(contentSize / this.#size)
                        logEBookPerf('EXPAND.metrics', {
                            mode: 'column',
                            side,
                            size: this.#size,
                            contentSize,
                            pageCount,
                            suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
                            ready: this.container?.trackingSizeBakeReadyPublic ?? null,
                        })
                        const expandedSize = pageCount * this.#size

                        this.#element.style.padding = '0'
                        this.#iframe.style[side] = `${expandedSize}px`
                        this.#element.style[side] = `${expandedSize + this.#size * 2}px`
                        this.#iframe.style[otherSide] = '100%'
                        this.#element.style[otherSide] = '100%'
                        if (documentElement) {
                            documentElement.style[side] = `${this.#size}px`
                        }
                        if (this.#overlayer) {
                            this.#overlayer.element.style.margin = '0'
                            this.#overlayer.element.style.left = this.#vertical ? '0' : `${this.#size}px`
                            this.#overlayer.element.style.top = this.#vertical ? `${this.#size}px` : '0'
                            this.#overlayer.element.style[side] = `${expandedSize}px`
                            this.#overlayer.redraw()
                        }
                    } else {
                        const docRect = documentElement.getBoundingClientRect()
                        logEBookPerf('RECT.expand-doc', {
                            width: docRect?.width ?? null,
                            height: docRect?.height ?? null,
                        })
                        const contentSize = docRect[side]
                        const expandedSize = contentSize
                        const {
                            topMargin,
                            bottomMargin
                        } = this.layout
                        logEBookPerf('EXPAND.metrics', {
                            mode: 'scrolled',
                            side,
                            size: this.#size,
                            contentSize,
                            suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
                            ready: this.container?.trackingSizeBakeReadyPublic ?? null,
                        })
                        //                    const paddingTop = `${marginTop}px`
                        //                    const paddingBottom = `${marginBottom}px`
                        const paddingTop = `${topMargin}px`
                        const paddingBottom = `${bottomMargin}px`
                        if (this.#vertical) {
                            this.#element.style.paddingLeft = paddingTop
                            this.#element.style.paddingRight = paddingBottom
                            this.#element.style.paddingTop = '0'
                            this.#element.style.paddingBottom = '0'
                        } else {
                            this.#element.style.paddingLeft = '0'
                            this.#element.style.paddingRight = '0'
                            this.#element.style.paddingTop = paddingTop
                            this.#element.style.paddingBottom = paddingBottom
                        }
                        this.#iframe.style[side] = `${expandedSize}px`
                        this.#element.style[side] = `${expandedSize}px`
                        this.#iframe.style[otherSide] = '100%'
                        this.#element.style[otherSide] = '100%'
                        if (this.#overlayer) {
                            if (this.#vertical) {
                                this.#overlayer.element.style.marginLeft = paddingTop
                                this.#overlayer.element.style.marginRight = paddingBottom
                                this.#overlayer.element.style.marginTop = '0'
                                this.#overlayer.element.style.marginBottom = '0'
                            } else {
                                this.#overlayer.element.style.marginLeft = '0'
                                this.#overlayer.element.style.marginRight = '0'
                                this.#overlayer.element.style.marginTop = paddingTop
                                this.#overlayer.element.style.marginBottom = paddingBottom
                            }
                            this.#overlayer.element.style.left = '0'
                            this.#overlayer.element.style.top = '0'
                            this.#overlayer.element.style[side] = `${expandedSize}px`
                            this.#overlayer.redraw()
                        }
                    }
                    //                console.log("expand... call onexpand")
                    logEBookPerf('expand-before-onexpand', {
                        column: this.#column,
                        vertical: this.#vertical,
                        side,
                        expandedSize: this.#iframe?.style?.[side] || null,
                    })
                await this.onExpand()
                logEBookPerf('expand-complete', {
                    column: this.#column,
                    vertical: this.#vertical,
                    size: this.#size,
                })
                logEBookPerf('EXPAND.expand-complete', {
                    suppressBakeOnExpand: this.container?.suppressBakeOnExpandPublic ?? null,
                    trackingReady: this.container?.trackingSizeBakeReadyPublic ?? null,
                    pendingReason: this.container?.pendingTrackingSizeBakeReasonPublic ?? null,
                    inExpand: this.#inExpand || false,
                })
                    //                console.log("expand... call'd onexpand")
                } finally {
                    this.#inExpand = false
                    resolve()
                }
            })
        })
    }
    set overlayer(overlayer) {
        this.#overlayer = overlayer
        if (overlayer?.element) {
            this.#element.append(overlayer.element)
        }
    }
    get overlayer() {
        return this.#overlayer
    }
    destroy() {
        if (this.document) this.#resizeObserver.unobserve(this.document.body)
        //        if (this.document) this.#mutationObserver.disconnect()
    }
}

// NOTE: everything here assumes the so-called "negative scroll type" for RTL
export class Paginator extends HTMLElement {
    static observedAttributes = [
        'flow', 'gap', 'marginTop', 'marginBottom',
        'max-inline-size', 'max-block-size', 'max-column-count',
    ]
    #root = this.attachShadow({
        mode: 'closed'
    })
    #debouncedRender = debounce(() => {
        if (!this.layout) return
        // Explicit source so diagnostics can attribute resize-triggered renders.
        this.render(this.layout, { source: 'resize' })
    }, 333)
    #lastResizerRect = null
    #resizeObserverFrame = null
    #pendingResizeRect = null
    #resizeObserver = new ResizeObserver(entries => {
        if (this.#isCacheWarmer) return;
        const entry = entries[0];
        if (!entry) return;
        const rect = entry.contentRect;
        this.#pendingResizeRect = {
            width: Math.round(rect.width),
            height: Math.round(rect.height),
            top: Math.round(rect.top),
            left: Math.round(rect.left),
        }
        if (this.#resizeObserverFrame !== null) cancelAnimationFrame(this.#resizeObserverFrame)
        this.#resizeObserverFrame = requestAnimationFrame(() => {
            this.#resizeObserverFrame = null
            this.#handleContainerResize(this.#pendingResizeRect)
        })
    })
    #suppressBakeOnExpand = false
    #handleContainerResize(newSize) {
        if (!newSize) return
        const old = this.#lastResizerRect
        const changed =
            !old ||
            newSize.width !== old.width ||
            newSize.height !== old.height ||
            newSize.top !== old.top ||
            newSize.left !== old.left

        if (!changed) return

        this.#lastResizerRect = newSize
        this.#cachedSizes = null
        this.#cachedStart = null

        this.#debouncedRender();

        // Wait one frame to ensure the container size has settled before rebaking sizes.
        if (MANABI_TRACKING_SIZE_BAKING_OPTIMIZED && MANABI_TRACKING_SIZE_RESIZE_TRIGGERS_ENABLED) {
            requestAnimationFrame(() => {
                const r = this.#container?.getBoundingClientRect?.()
                logEBookPerf('RECT.container-resize-check', {
                    rect: r ? {
                        width: Math.round(r.width),
                        height: Math.round(r.height),
                        top: Math.round(r.top),
                        left: Math.round(r.left),
                    } : null,
                    last: this.#lastResizerRect,
                })
                if (!r) return
                const stable = {
                    width: Math.round(r.width),
                    height: Math.round(r.height),
                    top: Math.round(r.top),
                    left: Math.round(r.left),
                }
                const still =
                    stable.width === this.#lastResizerRect?.width &&
                    stable.height === this.#lastResizerRect?.height &&
                    stable.top === this.#lastResizerRect?.top &&
                    stable.left === this.#lastResizerRect?.left

                if (!still) return

                this.requestTrackingSectionGeometryBake({
                    reason: 'container-resize',
                    restoreLocation: true
                })
                this.requestTrackingSectionSizeBake({
                    reason: 'container-resize',
                    rect: stable,
                })
            })
        } else {
            this.requestTrackingSectionGeometryBake({
                reason: 'container-resize',
                restoreLocation: true
            })
        }
    }
    #top
    #transitioning = false;
    //    #background
    #container
    #header
    #footer
    #view
    #vertical = null
    #verticalRTL = null
    #rtl = null
    #directionReadyResolve = null;
    #directionReady = new Promise(r => (this.#directionReadyResolve = r));
    #column = true
    #topMargin = 0
    #bottomMargin = 0
    #index = -1
    get currentIndex() { return this.#index }
    #anchor = 0 // anchor view to a fraction (0-1), Range, or Element
    #justAnchored = false
    #isLoading = false
    #locked = false // while true, prevent any further navigation
    #styles
    #styleMap = new WeakMap()
    #scrollBounds
    #touchState
    #touchScrolled
    #isCacheWarmer = false
    #prefetchTimer = null
    #prefetchCache = new Map()
    #skipTouchEndOpacity = false
    #isAdjustingSelectionHandle = false
    #trackingGeometryRebakeTimer = null
    #trackingGeometryPendingReason = null
    #trackingGeometryPendingRestoreLocation = false
    #trackingGeometryBakeInFlight = null
    #trackingGeometryBakeNeedsRerun = false
    #trackingGeometryBakeQueuedRestoreLocation = false
    #trackingGeometryBakeQueuedReason = null
    #wheelArmed = true // Hysteresis-based horizontal wheel paging
    #scrolledToAnchorOnLoad = false
    #trackingSizeBakeTimer = null
    #trackingSizeBakeInFlight = null
    #trackingSizeBakeNeedsRerun = false
    #trackingSizeBakeQueuedReason = null
    #trackingSizeBakeReady = false
    #trackingSizeLastObservedRect = null
    #pendingTrackingSizeBakeReason = null
    #lastTrackingSizeBakedRect = null

    // Expose selected private state for logging/debug from View.
    get trackingSizeBakeReadyPublic() { return this.#trackingSizeBakeReady }
    get suppressBakeOnExpandPublic() { return this.#suppressBakeOnExpand }
    get pendingTrackingSizeBakeReasonPublic() { return this.#pendingTrackingSizeBakeReason }

    #cachedSizes = null
    #cachedStart = null

    #cachedSentinelDoc = null
    #cachedSentinelElements = []
    #cachedTrackingSections = []
    #cachedTrackingContainer = null
    #sentinelGroups = []
    #sentinelGroupsDoc = null
    #sentinelGroupsTotal = 0
    #sentinelGroupSize = 50
    #visibleSentinelElements = new Set()
    #sentinelElementIndex = new WeakMap()
    #activeSentinelGroupRange = {
        start: null,
        end: null,
    }
    #sentinelsInitialized = false

    #elementVisibilityObserver = null
    #elementMutationObserver = null

    constructor() {
        super()
        // narrowing gap + margin broke images, rendered too tall & scroll mode drifted (worse than usual...)
        const {
            gapPct,
            topMarginPx,
            bottomMarginPx,
            sideMarginPx,
            maxInlineSizePx,
            maxBlockSizePx,
            maxColumnCount,
            maxColumnCountPortrait
        } = CSS_DEFAULTS;
        this.#root.innerHTML = `<style>
            :host {
                display: block;
                container-type: size;
            }
            :host, #top {
                box-sizing: border-box;
                position: relative;
                overflow: hidden;
                width: 100%;
                height: 100%;
            }
            #top {
                contain: strict;
        
                --_gap: ${gapPct}%;
                --_top-margin: ${topMarginPx}px;
                --_bottom-margin: ${bottomMarginPx}px;
                --_side-margin: var(--side-nav-width, ${sideMarginPx}px);
                --_max-inline-size: ${maxInlineSizePx}px;
                --_max-block-size: ${maxBlockSizePx}px;
                --_max-column-count: ${maxColumnCount};
                --_max-column-count-portrait: ${maxColumnCountPortrait};
                --_max-column-count-spread: var(--_max-column-count);
                --_half-gap: calc(var(--_gap) / 2);
                --_max-width: calc(var(--_max-inline-size) * var(--_max-column-count-spread));
                --_max-height: var(--_max-block-size);
                display: grid;
                grid-template-columns:
                    /*
                    minmax(var(--_half-gap), 1fr)
                    var(--_half-gap)
                    minmax(0, calc(var(--_max-width) - var(--_gap)))
                    var(--_half-gap)
                    minmax(var(--_half-gap), 1fr);
                    */
                    var(--_side-margin)
                    1fr
                    minmax(0, calc(var(--_max-width) - var(--_gap)))
                    1fr
                    var(--_side-margin); 
                grid-template-rows:
                    minmax(var(--_top-margin), 1fr)
                    minmax(0, var(--_max-height))
                    minmax(var(--_bottom-margin), 1fr);
                &.vertical {
                    --_max-column-count-spread: var(--_max-column-count-portrait);
                    --_max-width: var(--_max-block-size);
                    --_max-height: calc(var(--_max-inline-size) * var(--_max-column-count-spread));
                }
                @container (orientation: portrait) {
                    & {
                        --_max-column-count-spread: var(--_max-column-count-portrait);
                    }
                    &.vertical {
                        --_max-column-count-spread: var(--_max-column-count);
                    }
                }
            }
            #top.reader-loading {
                opacity: 0;
                pointer-events: none;
            }
            /*#background {
                grid-column: 1 / -1;
                grid-row: 1 / -1;
            }*/
            #container {
                grid-column: 2 / 5;
                grid-row: 2;
                overflow: hidden;
        
                contain: strict;
                will-change: transform;
                transform: translateZ(0);
            }
            :host([flow="scrolled"]) #container {
                grid-column: 1 / -1;
                grid-row: 1 / -1;
                overflow: auto;
            }
            #header {
                grid-column: 3 / 4;
                grid-row: 1;
            }
            #footer {
                grid-column: 3 / 4;
                grid-row: 3;
                align-self: end;
            }
            #header, #footer {
                display: grid;
            }
            #header {
                height: var(--_top-margin);
            }
            #footer {
                height: var(--_bottom-margin);
            }
            :is(#header, #footer) > * {
                display: flex;
                align-items: center;
                min-width: 0;
            }
            :is(#header, #footer) > * > * {
                width: 100%;
                overflow: hidden;
                white-space: nowrap;
                text-overflow: ellipsis;
                text-align: center;
                font-size: .75em;
                opacity: .6;
            }        
            /* For page-turning */
            .view-fade {
                opacity: 0.45;
                /*transition: opacity 0.85s ease-out;*/
            }
            .view-faded {
                opacity: 0.45;
            }
        </style>
        <div id="top">
            <!-- <div id="background" part="filter"></div> -->
            <div id="header"></div>
            <div id="container"></div>
            <div id="footer"></div>
        </div>
        `

        this.#top = this.#root.getElementById('top')
        //        this.#background = this.#root.getElementById('background')
        this.#container = this.#root.getElementById('container')
        this.#header = this.#root.getElementById('header')
        this.#footer = this.#root.getElementById('footer')

        this.#resizeObserver.observe(this.#container)

        this.#container.addEventListener('scroll', () => this.dispatchEvent(new Event('scroll')))

        // Continuously fire relocate during scroll
        this.#container.addEventListener('scroll', debounce(async () => {
            if (this.#view.isLoading) return;
            if (this.scrolled && !this.#isCacheWarmer) {
                const range = await this.#getVisibleRange();
                const index = this.#index;
                let fraction = 0;
                if (this.scrolled) {
                    fraction = (await this.start()) / (await this.viewSize());
                } else if ((await this.pages()) > 0) {
                    const {
                        page,
                        pages
                    } = this;
                    fraction = (page - 1) / (pages - 2);
                }
                // Don't include all details, just enough for the slider
                this.dispatchEvent(new CustomEvent('relocate', {
                    detail: {
                        reason: 'live-scroll',
                        range,
                        index,
                        fraction
                    }
                }));
            }
        }, 450));

        this.#container.addEventListener('scroll', debounce(async () => {
            if (this.scrolled) {
                if (this.#justAnchored) {
                    this.#justAnchored = false
                } else {
                    await this.#afterScroll('scroll')
                }
            }
        }, 450))
    }

    // NOTE: In this foliate-js fork, currently paginator can only open a book once
    open(book, isCacheWarmer) {
        // hide the view until final relocate needs
        this.style.display = 'none'

        this.#isCacheWarmer = isCacheWarmer
        this.bookDir = book.dir
        this.sections = book.sections

        if (!this.#isCacheWarmer) {
            const opts = {
                passive: false
            }
            this.addEventListener('touchstart', this.#onTouchStart.bind(this), opts)
            this.addEventListener('touchmove', this.#onTouchMove.bind(this), opts)
            this.addEventListener('touchend', this.#onTouchEnd.bind(this))
            this.addEventListener('load', ({
                detail: {
                    doc
                }
            }) => {
                doc.addEventListener('touchstart', this.#onTouchStart.bind(this), opts)
                doc.addEventListener('touchmove', this.#onTouchMove.bind(this), opts)
                doc.addEventListener('touchend', this.#onTouchEnd.bind(this))
            })
            this.addEventListener('wheel', this.#onWheel.bind(this), opts);
        }
    }
    setSideNavWidth(widthPx) {
        this.#top?.style?.setProperty('--side-nav-width', typeof widthPx === 'number' ? `${widthPx}px` : widthPx);
    }
    #createView() {
        this.#cancelTrackingGeometryBakeSchedule()
        this.#resetTrackingSectionSizeState()
        if (this.#view) {
            this.#view.destroy()
            this.#container.removeChild(this.#view.element)
        }
        this.#view = new View({
            container: this,
            onBeforeExpand: this.#onBeforeExpand.bind(this),
            onExpand: this.#onExpand.bind(this),
            isCacheWarmer: this.#isCacheWarmer,
            //            onExpand: debounce(() => this.#onExpand.bind(this), 500),
        })
        this.#container.append(this.#view.element)
        return this.#view
    }
    #setLoading(isLoading) {
        this.#isLoading = isLoading;
        if (isLoading) {
            this.#top.classList.add('reader-loading');
        } else {
            this.#top.classList.remove('reader-loading');
        }
    }

    requestTrackingSectionGeometryBake({
        reason = 'unspecified',
        restoreLocation = false,
        immediate = false,
    } = {}) {
        // Geometry bake disabled
        return
    }

    requestTrackingSectionSizeBake({
        reason = 'unspecified',
        rect = null,
        sectionIndex = null,
        skipPostBakeRefresh = false,
    } = {}) {
        if (reason === 'styles-applied' && !this.#trackingSizeBakeReady) {
            logEBookPerf('tracking-size-bake-request', {
                reason,
                sectionIndex: sectionIndex ?? this.#index,
                status: 'skip-not-ready-styles-applied'
            })
            return false
        }
        const ctxBase = {
            reason,
            sectionIndex: sectionIndex ?? this.#index,
            hasDoc: !!this.#view?.document,
            ready: this.#trackingSizeBakeReady,
            inFlight: !!this.#trackingSizeBakeInFlight,
            pendingReason: this.#pendingTrackingSizeBakeReason || null,
        }
        if (!MANABI_TRACKING_SIZE_BAKE_ENABLED) {
            logEBookPerf('tracking-size-bake-request', { ...ctxBase, status: 'disabled' })
            this.#setLoading(false)
            return false
        }
        if (this.#isCacheWarmer) return false
        if (!this.#view?.document) {
            logEBookPerf('tracking-size-bake-request', { ...ctxBase, status: 'no-document' })
            this.#pendingTrackingSizeBakeReason = reason
            return false
        }
        if (!this.#trackingSizeBakeReady) {
            logEBookPerf('tracking-size-bake-request', { ...ctxBase, status: 'not-ready' })
            this.#pendingTrackingSizeBakeReason = reason
            return false
        }

        if (rect) {
            const last = this.#trackingSizeLastObservedRect
            const unchanged =
                last &&
                rect.width === last.width &&
                rect.height === last.height &&
                rect.top === last.top &&
                rect.left === last.left
            if (unchanged) {
                logEBookPerf('tracking-size-bake-request', { ...ctxBase, status: 'unchanged-rect' })
                return false
            }
            this.#trackingSizeLastObservedRect = rect
        } else {
            // Only respond to rects captured elsewhere (e.g., resize observer cache); avoid new layout reads here.
            const cachedBodyRect = this.#view?.getLastBodyRect?.()
            if (!cachedBodyRect) {
                logEBookPerf('tracking-size-bake-request', { ...ctxBase, status: 'no-cached-rect' })
                return false
            }
            const derived = {
                width: Math.round(cachedBodyRect.width),
                height: Math.round(cachedBodyRect.height),
                top: Math.round(cachedBodyRect.top),
                left: Math.round(cachedBodyRect.left),
            }
            const lastBaked = this.#lastTrackingSizeBakedRect
            if (lastBaked &&
                derived.width === lastBaked.width &&
                derived.height === lastBaked.height &&
                derived.top === lastBaked.top &&
                derived.left === lastBaked.left) {
                logEBookPerf('tracking-size-bake-request', { ...ctxBase, status: 'unchanged-derived' })
                return false
            }
            this.#trackingSizeLastObservedRect = derived
        }

        if (this.#trackingSizeBakeInFlight) {
            this.#trackingSizeBakeNeedsRerun = true
            this.#trackingSizeBakeQueuedReason = reason
            logEBookPerf('tracking-size-bake-request', { ...ctxBase, status: 'queued-rerun' })
            return true
        }

        this.#trackingSizeBakeQueuedReason = null
        this.#trackingSizeBakeNeedsRerun = false

        logEBookPerf('tracking-size-bake-request', { ...ctxBase, status: 'start' })
        this.#trackingSizeBakeInFlight = this.#performTrackingSectionSizeBake({
            reason,
            sectionIndex: sectionIndex ?? this.#index,
            skipPostBakeRefresh,
        }).catch(error => {
            // swallow bake errors after reporting if needed
            console.error('tracking size bake error', error)
        }).finally(() => {
            this.#trackingSizeBakeInFlight = null
            if (this.#trackingSizeBakeNeedsRerun) {
                const queuedReason = this.#trackingSizeBakeQueuedReason || 'rerun'
                this.#trackingSizeBakeNeedsRerun = false
                this.requestTrackingSectionSizeBake({ reason: queuedReason })
            }
        })

        return true
    }

    #resetTrackingSectionSizeState() {
        if (this.#trackingSizeBakeTimer) {
            clearTimeout(this.#trackingSizeBakeTimer)
            this.#trackingSizeBakeTimer = null
        }
        this.#trackingSizeBakeInFlight = null
        this.#trackingSizeBakeNeedsRerun = false
        this.#trackingSizeBakeQueuedReason = null
        this.#trackingSizeLastObservedRect = null
        this.#pendingTrackingSizeBakeReason = null
        this.#trackingSizeBakeReady = false
        this.#lastTrackingSizeBakedRect = null

        this.#cachedSentinelDoc = null
        this.#cachedSentinelElements = []
        this.#cachedTrackingSections = []
    }

    #revealPreBakeContent() {
        if (!this.#view?.document) return
        revealDocumentContentForBake(this.#view.document)
    }

    // Public helper for View to force an initial size bake before first expand.
    async performInitialBakeFromView(sectionIndex, layout) {
        // Lock expands and reset readiness before pre-bake render.
        this.#suppressBakeOnExpand = true
        this.#trackingSizeBakeReady = false

        // Apply layout styles (without expanding) so bake measures correct flow.
        await this.#view?.render(layout, { skipExpand: true, source: 'initial-bake-pre-render' })
        logEBookPerf('tracking-size-bake-initial-from-view', {
            sectionIndex,
            ready: this.#trackingSizeBakeReady,
        })
        logEBookPerf('EXPAND.callsite', {
            source: 'initial-bake-start',
            suppressBakeOnExpand: this.#suppressBakeOnExpand,
            ready: this.#trackingSizeBakeReady,
        })
        try {
            await this.#performTrackingSectionSizeBake({
                reason: 'initial-load',
                sectionIndex,
                skipPostBakeRefresh: true,
            })
        } finally {
            // Keep suppressBakeOnExpand true through the first post-bake render/expand
            // to avoid a redundant bake loop. It will be unset after that expand.
        }

        logEBookPerf('EXPAND.callsite', {
            source: 'initial-bake-after-bake',
            suppressBakeOnExpand: this.#suppressBakeOnExpand,
            ready: this.#trackingSizeBakeReady,
            bodyHidden: this.view?.document?.body?.classList?.contains?.(MANABI_TRACKING_SIZE_BAKING_BODY_CLASS) ?? null,
        })

        // Post-bake render/expand with fresh measurements; allow expand to bake if needed.
        this.#suppressBakeOnExpand = false
        await this.#view?.render(layout, { source: 'initial-bake-post-render' })
        logEBookPerf('EXPAND.callsite', {
            source: 'initial-bake-after-render',
            suppressBakeOnExpand: this.#suppressBakeOnExpand,
            ready: this.#trackingSizeBakeReady,
            bodyHidden: this.view?.document?.body?.classList?.contains?.(MANABI_TRACKING_SIZE_BAKING_BODY_CLASS) ?? null,
        })
    }

    async #performTrackingSectionSizeBake({
        reason = 'unspecified',
        sectionIndex = null,
        skipPostBakeRefresh = false,
    } = {}) {
        const perfStart = performance?.now?.() ?? null
        const doc = this.#view?.document
        if (!doc) {
            logEBookPerf('tracking-size-bake-begin', {
                reason,
                sectionIndex,
                status: 'no-doc',
            })
            this.#setLoading(false)
            return
        }

        // Reveal iframe itself right as we begin baking; body stays hidden until reveal step below.
        this.#view?.revealIframeForBake(reason)

        logEBookPerf('tracking-size-bake-begin', {
            reason,
            sectionIndex,
            isCacheWarmer: this.#isCacheWarmer,
            hasDoc: !!doc,
        })

        const activeView = this.#view

        this.#setLoading(true)
        hideDocumentContentForPreBake(doc)
        this.#trackingSizeBakeReady = false
        try {
            await nextFrame()
            await bakeTrackingSectionSizes(doc, {
                vertical: this.#vertical,
                reason,
                sectionIndex,
                bookId: this.bookDir,
                sectionHref: this.sections?.[this.#index]?.href || this.sections?.[this.#index]?.url || null,
            })
            try {
                await this.#getSentinelVisibilities()
            } catch (error) {
            }
            const cachedBodyRect = this.#view?.getLastBodyRect?.()
            if (cachedBodyRect) {
                this.#lastTrackingSizeBakedRect = {
                    width: Math.round(cachedBodyRect.width),
                    height: Math.round(cachedBodyRect.height),
                    top: Math.round(cachedBodyRect.top),
                    left: Math.round(cachedBodyRect.left),
                }
            }

            // After bake completes, refresh layout & relocate once the full layout is known.
            // Guard against races where the user navigated away.
            if (!skipPostBakeRefresh && !this.#isCacheWarmer && this.#view === activeView && sectionIndex === this.#index) {
                try {
                    // Re-render (columnize + expand) with the newly baked sizes without
                    // kicking off another bake loop from onExpand.
                    logEBookPerf('EXPAND.callsite', {
                        source: 'post-bake-refresh',
                        suppressBakeOnExpand: this.#suppressBakeOnExpand,
                        ready: this.#trackingSizeBakeReady,
                    })
                    this.#suppressBakeOnExpand = true
                    if (typeof this.render === 'function') {
                        await this.render(this.layout, { source: 'post-bake-refresh' })
                    } else {
                    }
                    this.#suppressBakeOnExpand = false

                    // Now recompute pagination/nav state.
                    await this.#afterScroll('bake')
                } catch (error) {
                    this.#suppressBakeOnExpand = false
                }
            }
        } finally {
            this.#revealPreBakeContent()
            if (this.#view === activeView) {
                this.#setLoading(false)
            }
            const durationMs = perfStart !== null && typeof performance !== 'undefined' && typeof performance.now === 'function'
                ? performance.now() - perfStart
                : null
            logEBookPerf('tracking-size-bake-complete', {
                reason,
                sectionIndex,
                durationMs,
                stillActiveView: this.#view === activeView,
            })
            // Ready flag must be explicitly re-enabled by callers after bake completes.
            logEBookPerf('tracking-size-bake-ready-reset', {
                reason,
                sectionIndex,
                ready: this.#trackingSizeBakeReady,
            })
            if (this.#view === activeView) {
                this.#trackingSizeBakeReady = true
                logEBookPerf('tracking-size-bake-ready-set', {
                    reason,
                    sectionIndex,
                    ready: this.#trackingSizeBakeReady,
                })
            }
        }
    }

    #cancelTrackingGeometryBakeSchedule() {
        if (this.#trackingGeometryRebakeTimer) {
            clearTimeout(this.#trackingGeometryRebakeTimer)
            this.#trackingGeometryRebakeTimer = null
        }
        this.#trackingGeometryPendingReason = null
        this.#trackingGeometryPendingRestoreLocation = false
    }

    async #performTrackingSectionGeometryBake({
        reason = 'unspecified',
        restoreLocation = false,
    } = {}) {
        // Geometry bake disabled
        return
    }

    async #safeCaptureVisibleRange() {
        try {
            const range = await this.#getVisibleRange()
            if (!range) return null
            if (typeof range.cloneRange === 'function') return range.cloneRange()
            return range
        } catch (error) {
            // ignore capture errors
            return null
        }
    }
    async #calculateSentinelGroupSize(totalSentinels) {
        const defaultSize = 50
        if (!Number.isFinite(totalSentinels) || totalSentinels <= 0) return defaultSize
        let pages = null
        try {
            pages = await this.pages()
        } catch {}
        const targetGroups = Math.max(1, Math.round((pages ?? 0) * 1.5))
        if (!Number.isFinite(targetGroups) || targetGroups <= 0) return defaultSize
        return Math.max(1, Math.ceil(totalSentinels / targetGroups))
    }
    #resetSentinelObservers() {
        for (const group of this.#sentinelGroups) {
            try {
                group?.observer?.disconnect?.()
            } catch {}
        }
        this.#sentinelGroups = []
        this.#sentinelGroupsDoc = null
        this.#sentinelGroupsTotal = 0
        this.#sentinelGroupSize = 50
        this.#visibleSentinelElements = new Set()
        this.#sentinelElementIndex = new WeakMap()
        this.#activeSentinelGroupRange = {
            start: null,
            end: null,
        }
        this.#sentinelsInitialized = false
    }
    #makeSentinelObserver(groupIndex) {
        return new IntersectionObserver(entries => {
            this.#handleSentinelIntersections(groupIndex, entries)
        }, {
            root: this.#container ?? null,
            rootMargin: `${MANABI_SENTINEL_ROOT_MARGIN_PX}px`,
            threshold: [0],
        })
    }
    #createSentinelGroup(groupIndex) {
        const visible = new Set()
        return {
            index: groupIndex,
            observer: null,
            elements: [],
            visible,
            startIndex: groupIndex * this.#sentinelGroupSize,
            endIndex: (groupIndex * this.#sentinelGroupSize) - 1,
            active: false,
        }
    }
    #handleSentinelIntersections(groupIndex, entries) {
        const group = this.#sentinelGroups?.[groupIndex]
        if (!group) return
        for (const entry of entries || []) {
            const el = entry.target
            if (!el) continue
            const isVisible = entry.isIntersecting || (entry.intersectionRatio ?? 0) > 0
            if (isVisible) {
                group.visible.add(el)
                this.#visibleSentinelElements.add(el)
            } else {
                group.visible.delete(el)
                this.#visibleSentinelElements.delete(el)
            }
        }
    }
    #deactivateSentinelGroup(group) {
        if (!group || !group.active) return
        for (const el of group.elements) {
            try {
                group.observer?.unobserve?.(el)
            } catch {}
            group.visible.delete(el)
            this.#visibleSentinelElements.delete(el)
        }
        group.active = false
    }
    #activateSentinelGroup(group) {
        if (!group || group.active) return
        if (!group.observer) {
            group.observer = this.#makeSentinelObserver(group.index ?? 0)
        }
        for (const el of group.elements) {
            group.observer.observe(el)
        }
        group.active = true
    }
    #syncSentinelGroups(doc, sentinelElements, groupSize) {
        const total = sentinelElements?.length ?? 0
        if (this.#sentinelGroupsDoc !== doc || this.#sentinelGroupsTotal !== total) {
            this.#resetSentinelObservers()
            this.#sentinelGroupsDoc = doc
            this.#sentinelGroupsTotal = total
        }

        if (!Number.isFinite(groupSize) || groupSize <= 0) groupSize = 50
        this.#sentinelGroupSize = groupSize

        const requiredGroups = Math.max(0, Math.ceil(total / this.#sentinelGroupSize))
        while (this.#sentinelGroups.length < requiredGroups) {
            this.#sentinelGroups.push(this.#createSentinelGroup(this.#sentinelGroups.length))
        }
        while (this.#sentinelGroups.length > requiredGroups) {
            const group = this.#sentinelGroups.pop()
            try {
                group?.observer?.disconnect?.()
            } catch {}
        }

        for (let groupIndex = 0; groupIndex < requiredGroups; groupIndex++) {
            const start = groupIndex * this.#sentinelGroupSize
            const end = Math.min(total, start + this.#sentinelGroupSize)
            const slice = sentinelElements.slice(start, end)
            const group = this.#sentinelGroups[groupIndex]

            const unchanged = group.elements.length === slice.length &&
                group.elements.every((el, idx) => el === slice[idx])

            if (!unchanged) {
                if (group.active) {
                    for (const el of group.elements) {
                        try {
                            group.observer?.unobserve?.(el)
                        } catch {}
                    }
                }
                for (const el of group.elements) {
                    group.visible.delete(el)
                    this.#visibleSentinelElements.delete(el)
                }
                group.elements = slice
                group.visible.clear()
                group.active = false
            }

            group.startIndex = start
            group.endIndex = end - 1
            slice.forEach((el, idx) => this.#sentinelElementIndex.set(el, start + idx))
        }
    }
    #updateSentinelGroupActivation(startGroup, endGroup) {
        if (!Array.isArray(this.#sentinelGroups) || this.#sentinelGroups.length === 0) return
        for (let i = 0; i < this.#sentinelGroups.length; i++) {
            const group = this.#sentinelGroups[i]
            const withinRange = startGroup !== null &&
                endGroup !== null &&
                i >= startGroup &&
                i <= endGroup
            if (withinRange) this.#activateSentinelGroup(group)
            else this.#deactivateSentinelGroup(group)
        }
        this.#activeSentinelGroupRange = {
            start: startGroup,
            end: endGroup,
        }
    }
    #flushSentinelRecords(startGroup = 0, endGroup = this.#sentinelGroups.length - 1) {
        if (!Array.isArray(this.#sentinelGroups) || this.#sentinelGroups.length === 0) return
        const start = Math.max(0, startGroup)
        const end = Math.min(this.#sentinelGroups.length - 1, endGroup)
        for (let i = start; i <= end; i++) {
            const group = this.#sentinelGroups[i]
            const records = group?.observer?.takeRecords?.() ?? []
            if (records.length) this.#handleSentinelIntersections(i, records)
        }
    }
    #collectVisibleSentinelSnapshot() {
        if (!this.#visibleSentinelElements || this.#visibleSentinelElements.size === 0) {
            return {
                visibleIds: [],
                minIndex: null,
                maxIndex: null,
            }
        }
        const indexed = []
        let minIndex = null
        let maxIndex = null
        for (const el of this.#visibleSentinelElements) {
            const idx = this.#sentinelElementIndex.get(el)
            if (typeof idx === 'number') {
                if (minIndex === null || idx < minIndex) minIndex = idx
                if (maxIndex === null || idx > maxIndex) maxIndex = idx
            }
            if (el?.id) indexed.push({
                id: el.id,
                idx: typeof idx === 'number' ? idx : Number.POSITIVE_INFINITY,
            })
        }
        indexed.sort((a, b) => (a.idx ?? 0) - (b.idx ?? 0))
        const visibleIds = indexed.map(item => item.id)
        return {
            visibleIds,
            minIndex,
            maxIndex,
        }
    }
    async #onBeforeExpand() {
//        console.log("#onBeforeExpand...", this.style.display)
        logEBookPerf('on-before-expand', {
            pendingBakeReason: this.#pendingTrackingSizeBakeReason || null,
            vertical: this.#vertical,
            column: this.#column,
        })
        this.#revealPreBakeContent()
        this.#view.cachedViewSize = null;
        this.#view.cachedSizes = null;
        this.#cachedStart = null;
        this.#setLoading(true)
        this.#cachedStart = null
        this.#trackingSizeBakeReady = false
        this.#trackingSizeLastObservedRect = null
    }
    async #onExpand() {
//        console.log("#onExpand...", this.style.display)
        this.#view.cachedViewSize = null;
        this.#view.cachedSizes = null;
        this.#cachedStart = null;

        if (this.#scrolledToAnchorOnLoad) {
            // wait a frame to ensure layout has settled before scrolling
            await new Promise(resolve => requestAnimationFrame(resolve));
            await this.#scrollToAnchor(this.#anchor);
        }

        this.#trackingSizeBakeReady = true
        const pendingReason = this.#pendingTrackingSizeBakeReason
        this.#pendingTrackingSizeBakeReason = null

        this.#setLoading(false)
        const shouldBake = !this.#suppressBakeOnExpand
        logEBookPerf('on-expand', {
            pendingReason: pendingReason || null,
            suppressBake: this.#suppressBakeOnExpand,
            hasDoc: !!this.#view?.document,
            vertical: this.#vertical,
            column: this.#column,
        })
        if (shouldBake) {
            this.requestTrackingSectionSizeBake({ reason: pendingReason || 'expand' })
        }
    }
    async #awaitDirection() {
        if (this.#vertical === null) await this.#directionReady;
    }
    async #getSentinelVisibilities({ allowRetry = true } = {}) {
        await nextFrame()

        const perfStart = typeof performance !== 'undefined' && typeof performance.now === 'function'
            ? performance.now()
            : null

        const doc = this.#view?.document
        if (!doc?.body) return []

        if (this.#cachedSentinelDoc !== doc) {
            this.#cachedSentinelDoc = doc
            this.#cachedSentinelElements = Array.from(doc.body.getElementsByTagName('reader-sentinel'))
            this.#cachedTrackingSections = Array.from(doc.querySelectorAll(MANABI_TRACKING_SECTION_SELECTOR))
            this.#sentinelsInitialized = false
        } else if (!Array.isArray(this.#cachedSentinelElements) || this.#cachedSentinelElements.length === 0) {
            this.#cachedSentinelElements = Array.from(doc.body.getElementsByTagName('reader-sentinel'))
        }

        const sentinelElements = this.#cachedSentinelElements

        const applyVisibility = reason => {
            if (this.#cachedTrackingSections.length === 0) return
            applySentinelVisibilityToTrackingSections(doc, {
                visibleSentinels: this.#visibleSentinelElements,
                logReason: reason,
                container: this.#container,
                sectionsCache: this.#cachedTrackingSections,
            })
        }

        const bodyClasses = Array.from(doc.body?.classList ?? [])
        const isBakingHidden = bodyClasses.includes(MANABI_TRACKING_SIZE_BAKING_BODY_CLASS) ||
            bodyClasses.includes(MANABI_TRACKING_PREBAKE_HIDDEN_CLASS)

        if (sentinelElements.length === 0) {
            if (isBakingHidden && allowRetry && this.#trackingSizeBakeInFlight) {
                try { await this.#trackingSizeBakeInFlight } catch {}
                // Retry once to avoid infinite loops
                return await this.#getSentinelVisibilities({ allowRetry: false })
            }
            applyVisibility('sentinel-visibility:none')
            this.#resetSentinelObservers()
            return []
        }

        // Clear any prior snapshot (in case a previous call bailed early).
        this.#visibleSentinelElements.clear?.()

        const docChanged = this.#sentinelGroupsDoc !== doc
        const needsSync = docChanged || !this.#sentinelsInitialized

        if (needsSync) {
            const groupSize = await this.#calculateSentinelGroupSize(sentinelElements.length)
            this.#syncSentinelGroups(doc, sentinelElements, groupSize)
            this.#sentinelsInitialized = true
        }

        const groupCount = this.#sentinelGroups.length
        if (groupCount === 0) {
            applyVisibility('sentinel-visibility:none')
            return []
        }

        // Hint group from scroll fraction (0–1), falling back to 0.
        let hintGroup = 0
        try {
            const viewSize = await this.viewSize()
            const start = await this.start()
            const fraction = viewSize > 0 ? Math.max(0, Math.min(1, start / viewSize)) : 0
            hintGroup = Math.round(fraction * Math.max(0, groupCount - 1))
        } catch {}

        // Build expansion order: g, g-1, g+1, g-2, g+2, ...
        const activationOrder = []
        for (let dist = 0; dist < groupCount; dist++) {
            const left = hintGroup - dist
            const right = hintGroup + dist
            if (dist === 0) {
                activationOrder.push(hintGroup)
                continue
            }
            if (left >= 0) activationOrder.push(left)
            if (right < groupCount) activationOrder.push(right)
        }

        let minActive = hintGroup
        let maxActive = hintGroup
        let snapshot = {
            visibleIds: [],
            minIndex: null,
            maxIndex: null,
        }
        let observedThisCall = 0

        for (let i = 0; i < activationOrder.length; i++) {
            const groupIndex = activationOrder[i]
            const group = this.#sentinelGroups[groupIndex]
            if (!group) continue

            this.#activateSentinelGroup(group)
            observedThisCall += group.elements.length
            this.#flushSentinelRecords(groupIndex, groupIndex)

            minActive = Math.min(minActive, groupIndex)
            maxActive = Math.max(maxActive, groupIndex)

            snapshot = this.#collectVisibleSentinelSnapshot()
            if (snapshot.visibleIds.length === 0) continue

            const minGroup = Math.floor(snapshot.minIndex / this.#sentinelGroupSize)
            const maxGroup = Math.floor(snapshot.maxIndex / this.#sentinelGroupSize)
            const minOnEdge = snapshot.minIndex === (this.#sentinelGroups[minGroup]?.startIndex ?? snapshot.minIndex + 1)
            const maxOnEdge = snapshot.maxIndex === (this.#sentinelGroups[maxGroup]?.endIndex ?? snapshot.maxIndex - 1)

            if (!minOnEdge && !maxOnEdge) break
        }

        // Ensure the observers reflect the final active window (ring span).
        this.#updateSentinelGroupActivation(minActive, maxActive)
        this.#flushSentinelRecords(minActive, maxActive)

        snapshot = this.#collectVisibleSentinelSnapshot()

        // Fallback: if still nothing, observe everything.
        if (snapshot.visibleIds.length === 0 && this.#sentinelGroups.length > 0) {
            this.#updateSentinelGroupActivation(0, this.#sentinelGroups.length - 1)
            observedThisCall = sentinelElements.length
            this.#flushSentinelRecords(0, this.#sentinelGroups.length - 1)
            snapshot = this.#collectVisibleSentinelSnapshot()
        }

        const { visibleIds, minIndex, maxIndex } = snapshot

        applyVisibility('sentinel-visibility')

        const logStart = snapshot.visibleIds.length > 0 ? minActive : 0
        const logEnd = snapshot.visibleIds.length > 0 ? maxActive : Math.max(0, groupCount - 1)

        // Stop observing after snapshot to avoid persistent overhead; groups will be reactivated on next call.
        this.#updateSentinelGroupActivation(null, null)
        this.#visibleSentinelElements.clear?.()

        return visibleIds
    }
    #disconnectElementVisibilityObserver() {
        if (this.#elementVisibilityObserver) {
            this.#elementVisibilityObserver.disconnect();
            this.#elementVisibilityObserver = null;
        }
        if (this.#elementMutationObserver) {
            this.#elementMutationObserver.disconnect();
            this.#elementMutationObserver = null;
        }
    }
    #isSingleMediaElementWithoutText() {
        const container = this.#view.document.getElementById('reader-content');
        if (!container) return false;
        const mediaTags = ['img', 'image', 'svg', 'video', 'picture', 'object', 'iframe', 'canvas', 'embed'];
        const selector = mediaTags.join(',');
        const mediaElements = container.querySelectorAll(selector);
        // Must have exactly one media element anywhere
        if (mediaElements.length !== 1) return false;
        // Must have no non-whitespace text nodes
        if (container.textContent.trim() !== '') return false;
        return true;
    }
    async #beforeRender({
        vertical,
        verticalRTL,
        rtl,
        //        background
    }) {
        this.#vertical = vertical
        this.#verticalRTL = verticalRTL
        this.#rtl = rtl
        this.#top.classList.toggle('vertical', vertical)
        this.#directionReady = new Promise(r => (this.#directionReadyResolve = r));

        // set background to `doc` background
        // this is needed because the iframe does not fill the whole element
        //        this.#background.style.background = background

        this.style.display = 'block'

        const {
            width,
            height
        } = await this.sizes()
        const size = vertical ? height : width

        // New:
        const {
            maxInlineSizePx,
            maxColumnCount,
            maxColumnCountPortrait,
            topMarginPx,
            bottomMarginPx,
            minGapPx,
            gapPct
        } = CSS_DEFAULTS;
        const maxInlineSize = maxInlineSizePx;
        const orientationPortrait = height > width;
        let maxColumnCountSpread;
        if (orientationPortrait) {
            // In portrait container: non-vertical uses portrait count, vertical uses standard
            maxColumnCountSpread = vertical
                ? maxColumnCount
                : maxColumnCountPortrait;
        } else {
            // In landscape container: non-vertical uses standard, vertical uses portrait count
            maxColumnCountSpread = vertical
                ? maxColumnCountPortrait
                : maxColumnCount;
        }
        const topMargin = topMarginPx;
        const bottomMargin = bottomMarginPx;

        // retro way:
        //                const style = getComputedStyle(this.#top)
        //                const maxInlineSize = parseFloat(style.getPropertyValue('--_max-inline-size'))
        //                const maxColumnCount = parseInt(style.getPropertyValue('--_max-column-count-spread'))
        //                const topMargin = parseFloat(style.getPropertyValue('--_top-margin'))
        //                const bottomMargin = parseFloat(style.getPropertyValue('--_bottom-margin'))
        //                console.log("max in", maxInlineSize, maxInlineSize)
        //                console.log("max col cnt", maxColumnCount, maxColumnCountSpread)
        //                console.log("top marg", topMargin, topMargin)
        //                console.log("bot marg", bottomMargin, bottomMargin)

        this.#topMargin = topMargin
        this.#bottomMargin = bottomMargin
        this.#view.document.documentElement.style.setProperty('--_max-inline-size', maxInlineSize)

        // retro way:
        //                        const g = parseFloat(style.getPropertyValue('--_gap')) / 100
        const g = gapPct / 100;
        //                console.log("gap", oldg, g)

        // The gap will be a percentage of the #container, not the whole view.
        // This means the outer padding will be bigger than the column gap. Let
        // `a` be the gap percentage. The actual percentage for the column gap
        // will be (1 - a) * a. Let us call this `b`.
        //
        // To make them the same, we start by shrinking the outer padding
        // setting to `b`, but keep the column gap setting the same at `a`. Then
        // the actual size for the column gap will be (1 - b) * a. Repeating the
        // process again and again, we get the sequence
        //     x₁ = (1 - b) * a
        //     x₂ = (1 - x₁) * a
        //     ...
        // which converges to x = (1 - x) * a. Solving for x, x = a / (1 + a).
        // So to make the spacing even, we must shrink the outer padding with
        //     f(x) = x / (1 + x).
        // But we want to keep the outer padding, and make the inner gap bigger.
        // So we apply the inverse, f⁻¹ = -x / (x - 1) to the column gap.
        const rawGap = -g / (g - 1) * size
        const gap = Math.max(rawGap, minGapPx)

        const flow = this.getAttribute('flow') || 'paginated'
        const writingMode = vertical ? (verticalRTL ? 'vertical-rl' : 'vertical-lr') : 'horizontal-tb'
        const resolvedDir = this.bookDir || (rtl ? 'rtl' : 'ltr')
        this.#column = flow !== 'scrolled'

        if (flow === 'scrolled') {
            // FIXME: vertical-rl only, not -lr
            //this.setAttribute('dir', vertical ? 'rtl' : 'ltr')
            this.#top.style.padding = '0'
            //            const columnWidth = maxInlineSize
            const columnWidth = maxInlineSize

            this.heads = null
            this.feet = null
            this.#header.replaceChildren()
            this.#footer.replaceChildren()

            return {
                flow,
                topMargin,
                bottomMargin,
                gap,
                columnWidth,
                usePaginate: false,
                writingMode,
                direction: resolvedDir,
            }
        }

        let divisor, columnWidth
        const isSingleMediaElementWithoutText = this.#isSingleMediaElementWithoutText()
        if (isSingleMediaElementWithoutText) {
            columnWidth = maxInlineSize
            this.#view.document.body?.classList.add('reader-is-single-media-element-without-text')
        } else {
            this.#view.document.body?.classList.remove('reader-is-single-media-element-without-text')
            // retro way:
            divisor = Math.min(maxColumnCount, Math.ceil(size / maxInlineSize))
            //                        divisor = Math.min(oldmaxColumnCount, Math.ceil(size / oldmaxInlineSize))
            //            divisor = Math.min(maxColumnCountSpread, Math.ceil(size / maxInlineSize))
            //            console.log("Divisor", Math.min(oldmaxColumnCount, Math.ceil(size / oldmaxInlineSize)), divisor)
            columnWidth = (size / divisor) - gap
        }

        this.setAttribute('dir', rtl ? 'rtl' : 'ltr')

        const marginalDivisor = vertical ?
            Math.min(2, Math.ceil(width / maxInlineSize)) :
            divisor
        const marginalStyle = {
            gridTemplateColumns: `repeat(${marginalDivisor}, 1fr)`,
            gap: `${gap}px`,
            direction: this.bookDir === 'rtl' ? 'rtl' : 'ltr',
        }
        Object.assign(this.#header.style, marginalStyle)
        Object.assign(this.#footer.style, marginalStyle)
        const heads = makeMarginals(marginalDivisor, 'head')
        const feet = makeMarginals(marginalDivisor, 'foot')
        this.heads = heads.map(el => el.children[0])
        this.feet = feet.map(el => el.children[0])
        this.#header.replaceChildren(...heads)
        this.#footer.replaceChildren(...feet)

        return {
            height,
            width,
            topMargin,
            bottomMargin,
            gap,
            columnWidth,
            divisor,
            usePaginate: false,
            writingMode,
            direction: resolvedDir,
        }
    }
    async render() {
        if (!this.#view) {
            return
        }

        // avoid unwanted triggers
        //        this.#hasResizeObserverTriggered = false
        //        this.#resizeObserver.observe(this.#container);

        await this.#view.render(await this.#beforeRender({
            vertical: this.#vertical,
            rtl: this.#rtl,
        }))
        //            await this.#scrollToAnchor(this.#anchor) // already called via render -> ... -> expand -> onExpand
    }

    get scrolled() {
        return this.getAttribute('flow') === 'scrolled'
    }
    async scrollProp() {
        await this.#awaitDirection();
        const {
            scrolled
        } = this
        return this.#vertical ? (scrolled ? 'scrollLeft' : 'scrollTop') :
            scrolled ? 'scrollTop' : 'scrollLeft'
    }
    async sideProp() {
        await this.#awaitDirection();
        const {
            scrolled
        } = this
        return this.#vertical ? (scrolled ? 'width' : 'height') :
            scrolled ? 'height' : 'width'
    }
    async sizes() {
        //        await this.#awaitDirection();

        if (this.#isCacheWarmer) return 0
        if (/*true || */this.#cachedSizes === null) {
            return new Promise(resolve => {
                requestAnimationFrame(async () => {
                    //                    const r = this.#container.getBoundingClientRect()
                    //                    this.#cachedSizes = {
                    //                        width: r.width,
                    //                        height: r.height,
                    //                    }
                    //                    resolve(this.#cachedSizes)
                    //                    return ;

                    this.#cachedSizes = {
                        width: this.#container.clientWidth,
                        height: this.#container.clientHeight,
                    }
                    resolve(this.#cachedSizes)
                })
            })
            //        } else {
            //                                const r = this.#container.getBoundingClientRect()
            //            console.log("sizes() cached/real", this.#cachedSizes, r)
            //            requestAnimationFrame(() => {
            //                                const r = this.#container.getBoundingClientRect()
            //            console.log("sizes() FRAME cached/real", this.#cachedSizes, r)
            //            })

        }
        return this.#cachedSizes
    }
    async size() {
        return (await this.sizes())[await this.sideProp()]
    }
    async viewSize() {
        if (this.#isCacheWarmer) return 0
        const view = this.#view
        if (!view || !view.element) return 0
        if (typeof view.cachedViewSize === 'undefined') {
            view.cachedViewSize = null
        }
        if (/*true ||*/ view.cachedViewSize === null) {
            return new Promise(resolve => {
                requestAnimationFrame(async () => {
                    const element = view.element
                    if (!element) {
                        view.cachedViewSize = {
                            width: 0,
                            height: 0,
                        }
                        resolve(0)
                        return
                    }
                    view.cachedViewSize = {
                        width: element.clientWidth,
                        height: element.clientHeight,
                    }
                    resolve(view.cachedViewSize[await this.sideProp()])
                })
            })
        }
        return view.cachedViewSize[await this.sideProp()]
    }
    async start() {
        if (this.#cachedStart === null) {
            //        return new Promise(resolve => {
            //            requestAnimationFrame(async () => {
            //                    this.#cachedStart = Math.abs(this.#container[await this.scrollProp()])
            const start = Math.abs(this.#container[await this.scrollProp()])
            this.#cachedStart = start
            //        return start
            //                resolve(start)
            //            })
            //        })
        }
        return this.#cachedStart
    }
    async end() {
        //        await this.#awaitDirection();
        return (await this.start()) + (await this.size())
    }
    async page() {
        return Math.floor(((await this.start() + await this.end()) / 2) / (await this.size()))
    }
    async pages() {
        return Math.round((await this.viewSize()) / (await this.size()))
    }
    async scrollBy(dx, dy) {
        await new Promise(resolve => {
            requestAnimationFrame(async () => {
                const delta = this.#vertical ? dy : dx
                const element = this.#container
                const scrollProp = await this.scrollProp()
                const [offset, a, b] = this.#scrollBounds
                const rtl = this.#rtl
                const min = rtl ? offset - b : offset - a
                const max = rtl ? offset + a : offset + b
                element[scrollProp] = Math.max(min, Math.min(max,
                    element[scrollProp] + delta))
                this.#cachedStart = null; // TODO: Needed here?
                resolve()
            })
        })
    }
    async snap(vx, vy) {
        const velocity = this.#vertical ? vy : vx
        const [offset, a, b] = this.#scrollBounds
        const start = await this.start()
        const end = await this.end()
        const pages = await this.pages()
        const size = await this.size()
        const min = Math.abs(offset) - a
        const max = Math.abs(offset) + b
        const d = velocity * (this.#rtl ? -size : size)
        const page = Math.floor(
            Math.max(min, Math.min(max, (start + end) / 2 +
                (isNaN(d) ? 0 : d))) / size)

        await this.#scrollToPage(page, 'snap').then(async () => {
            const dir = page <= 0 ? -1 : page >= pages - 1 ? 1 : null
            if (dir) return await this.#goTo({
                index: this.#adjacentIndex(dir),
                anchor: dir < 0 ? () => 1 : () => 0,
                reason: 'page',
            })
        })
    }
    #onTouchStart(e) {
        const touch = e.changedTouches[0];
        // Determine if touch began in host container or inside the iframe’s document
        const target = touch.target;
        const inHost = this.#container.contains(target);
        const inIframe = this.#view?.document && target.ownerDocument === this.#view.document;
        if (!inHost && !inIframe) {
            this.#touchState = null;
            return;
        }
        this.#touchState = {
            startX: touch?.screenX,
            startY: touch?.screenY,
            x: touch?.screenX,
            y: touch?.screenY,
            t: e.timeStamp,
            vx: 0,
            vy: 0,
            pinched: false,
            triggered: false,
        };
        // Only block in paginated mode (not 'scrolled')
        if (!this.scrolled) {
            const sel = this.#view?.document?.getSelection?.();
            if (sel && !sel.isCollapsed && sel.rangeCount) {
                const range = sel.getRangeAt(0);
                const rect = range.getBoundingClientRect();
                logEBookPerf('RECT.selection-range', {
                    width: rect?.width ?? null,
                    height: rect?.height ?? null,
                    left: rect?.left ?? null,
                    top: rect?.top ?? null,
                })
                const x = touch.clientX,
                    y = touch.clientY;
                const hitTolerance = 30;
                const nearStart = (
                    Math.abs(x - rect.left) <= hitTolerance &&
                    y >= rect.top - hitTolerance && y <= rect.bottom + hitTolerance
                );
                const nearEnd = (
                    Math.abs(x - rect.right) <= hitTolerance &&
                    y >= rect.top - hitTolerance && y <= rect.bottom + hitTolerance
                );
                if (nearStart || nearEnd) {
                    this.#isAdjustingSelectionHandle = true;
                    return;
                }
            }
        }
        this.#isAdjustingSelectionHandle = false;
    }
    async #onTouchMove(e) {
        // If touchStart was ignored or missing, do nothing
        if (!this.#touchState) return;
        if (this.#isAdjustingSelectionHandle) return;
        e.preventDefault();
        const touch = e.changedTouches[0];
        const state = this.#touchState;
        if (state.triggered) return;
        state.x = touch.screenX;
        state.y = touch.screenY;
        const dx = state.x - state.startX;
        const dy = state.y - state.startY;
        const minSwipe = 36; // px threshold

        this.#updateSwipeChevron(dx, minSwipe);

        if (!state.triggered && Math.abs(dx) > Math.abs(dy) && Math.abs(dx) > minSwipe) {
            state.triggered = true;

            if (dx < 0) {
                (this.bookDir === 'rtl') ? await this.prev() : await this.next();
            } else {
                (this.bookDir === 'rtl') ? await this.next() : await this.prev();
            }
            this.#updateSwipeChevron(dx, minSwipe)
        }
    }
    #onTouchEnd(e) {
        this.#touchState = null;
        // If we just loaded a new section, skip the opacity reset
        if (this.#skipTouchEndOpacity) {
            this.#skipTouchEndOpacity = false
            return
        }
        this.dispatchEvent(new CustomEvent('sideNavChevronOpacity', {
            bubbles: true,
            composed: true,
            detail: {
                leftOpacity: '',
                rightOpacity: ''
            }
        }))
    }
    // allows one to process rects as if they were LTR and horizontal
    async #getRectMapper() {
        await this.#awaitDirection();
        if (this.scrolled) {
            const size = await this.viewSize()
            const topMargin = this.#topMargin
            const bottomMargin = this.#bottomMargin
            return this.#vertical ?
                ({
                    left,
                    right
                }) =>
                ({
                    left: size - right - topMargin,
                    right: size - left - bottomMargin
                }) :
                ({
                    top,
                    bottom
                }) => ({
                    left: top + topMargin,
                    right: bottom + bottomMargin
                })
        }
        const pxSize = (await this.pages()) * (await this.size())
        return this.#rtl ?
            ({
                left,
                right
            }) =>
            ({
                left: pxSize - right,
                right: pxSize - left
            }) :
            this.#vertical ?
                ({
                    top,
                    bottom
                }) => ({
                    left: top,
                    right: bottom
                }) :
                f => f
    }
    #wheelCooldown = false;
    #lastWheelDeltaX = 0;
    async #onWheel(e) {
        if (this.scrolled) return;
        e.preventDefault();
        if (Math.abs(e.deltaX) < Math.abs(e.deltaY)) return;

        const TRIGGER_THRESHOLD = 12;
        const RESET_THRESHOLD = 3;
        const REVEAL_CHEVRON_THRESHOLD = 5;

        // Early exit for "momentum falling" (hide chevrons if armed, deltaX dropping, and below threshold)
        if (
            this.#wheelArmed &&
            Math.abs(e.deltaX) < Math.abs(this.#lastWheelDeltaX) &&
            Math.abs(e.deltaX) < TRIGGER_THRESHOLD
        ) {
            this.dispatchEvent(new CustomEvent('sideNavChevronOpacity', {
                bubbles: true,
                composed: true,
                detail: {
                    leftOpacity: '',
                    rightOpacity: ''
                }
            }));
            this.#lastWheelDeltaX = e.deltaX;
            return;
        }

        if (this.#wheelArmed) {
            if (Math.abs(e.deltaX) > REVEAL_CHEVRON_THRESHOLD) {
                this.#updateSwipeChevron(-e.deltaX, TRIGGER_THRESHOLD);
            } else {
                this.#updateSwipeChevron(0, TRIGGER_THRESHOLD);
            }
        }

        if (this.#wheelArmed && Math.abs(e.deltaX) > TRIGGER_THRESHOLD) {
            this.#wheelArmed = false;
            this.#wheelCooldown = true;
            if (e.deltaX > 0) {
                await this.prev();
            } else {
                await this.next();
            }
            this.#updateSwipeChevron(-e.deltaX, TRIGGER_THRESHOLD)
            setTimeout(() => {
                this.#wheelCooldown = false;
            }, 100);
        } else if (!this.#wheelArmed && !this.#wheelCooldown && Math.abs(e.deltaX) < RESET_THRESHOLD) {
            this.#wheelArmed = true;
        }
        this.#lastWheelDeltaX = e.deltaX;
    }
    async #scrollToRect(rect, reason) {
        if (this.scrolled) {
            const rectMapper = await this.#getRectMapper();
            const offset = rectMapper(rect).left - this.#topMargin
            return await this.#scrollTo(offset, reason)
        }
        const rectMapper = await this.#getRectMapper();
        const offset = rectMapper(rect).left
        return await this.#scrollToPage(Math.floor(offset / (await this.size())) + (this.#rtl ? -1 : 1), reason)
    }
    async #scrollTo(offset, reason, smooth) {
        await this.#awaitDirection();
        const scroll = async () => {
            this.#cachedStart = null;
            const element = this.#container
            const scrollProp = await this.scrollProp()
            const size = await this.size()
            const atStart = await this.atStart()
            const atEnd = await this.atEnd()
            if (element[scrollProp] === offset) {
                this.#scrollBounds = [offset, atStart ? 0 : size, atEnd ? 0 : size]
                await this.#afterScroll(reason)
                return
            }
            // FIXME: vertical-rl only, not -lr
            if (this.scrolled && this.#vertical) offset = -offset
            if ((reason === 'snap' || smooth) && this.hasAttribute('animated')) return animate(
                element[scrollProp], offset, 300, easeOutQuad,
                x => element[scrollProp] = x,
            ).then(async () => {
                this.#scrollBounds = [offset, atStart ? 0 : size, atEnd ? 0 : size]
                await this.#afterScroll(reason)
            })
            else {
                element[scrollProp] = offset
                this.#scrollBounds = [offset, atStart ? 0 : size, atEnd ? 0 : size]
                await this.#afterScroll(reason)
            }
        }

        //            // Prevent new transitions while one is running
        //            if (this.#transitioning) {
        //                await scroll();
        //                return;
        //            }

        //            if (
        //                !this.#view ||
        //                document.visibilityState !== 'visible' ||
        //                (reason === 'snap' || reason === 'anchor' || reason === 'selection') ||
        //                typeof document.startViewTransition !== 'function'
        //                ) {
        return new Promise(resolve => {
            requestAnimationFrame(async () => {
                if (reason === 'snap' || reason === 'anchor' || reason === 'selection' || reason === 'navigation') {
                    await scroll()
                } else {
                    this.#container.classList.add('view-fade')
                    // Allow the browser to paint the fade
                    /*await new Promise(r => setTimeout(r, 65));
                     this.#container.classList.add('view-faded')*/
                    await scroll()
                    this.#container.classList.remove('view-faded')
                    this.#container.classList.remove('view-fade')
                }
                resolve()
            })
        })
    }
    async #scrollToPage(page, reason, smooth) {
        const size = await this.size()
        const offset = size * (this.#rtl ? -page : page)
        return await this.#scrollTo(offset, reason, smooth)
    }
    async scrollToAnchor(anchor, select, reasonOverride) {
        //            await new Promise(resolve => requestAnimationFrame(resolve));
        const reason = reasonOverride || (select ? 'selection' : 'navigation');
        await this.#scrollToAnchor(anchor, reason)
    }
    // TODO: Fix newer way and stop using this one that calculates getClientRects
    async #scrollToAnchor(anchor, reason = 'anchor') {
        //        console.log('#scrollToAnchor0...', anchor)
        this.#anchor = anchor
        try {
        } catch (_error) {
            // diagnostics best-effort
        }
        const rects = uncollapse(anchor)?.getClientRects?.()
        // if anchor is an element or a range
        if (rects) {
            // when the start of the range is immediately after a hyphen in the
            // previous column, there is an extra zero width rect in that column
            const rect = Array.from(rects)
                .find(r => r.width > 0 && r.height > 0) || rects[0]
            if (!rect) return
            await this.#scrollToRect(rect, reason)
            return
        }
        // if anchor is a fraction
        if (this.scrolled) {
            await this.#scrollTo(anchor * (await this.viewSize()), reason)
            return
        }
        const { pages } = this
        if (!pages) return
        const textPages = await this.pages() - 2
        const newPage = Math.round(anchor * (textPages - 1))
        await this.#scrollToPage(newPage + 1, reason)
    }
    async #NscrollToAnchor(anchor, reason = 'anchor') {
        //        console.log("#scrollToAnchor...cached sizes:", this.#cachedSizes, "real sizes: ", await this.sizes())
        await this.#awaitDirection();

        return new Promise(resolve => {
            requestAnimationFrame(async () => {
                //                console.log("#scrollToAnchor...frames...cached sizes:", this.#cachedSizes, "real sizes: ", await this.sizes())
                this.#anchor = anchor;
                //                console.log('scrollToAnchor: anchor=', anchor);
                // Determine anchor target (could be Range or Element)
                const anchorNode = uncollapse(anchor);

                // OG slow path: use getClientRects for sanity check
                //                const rects = anchorNode?.getClientRects?.();
                ////                console.log('OG clientRects:', rects);
                //                if (rects && rects.length > 0) {
                //                    const ogRect = Array.from(rects).find(r => r.width > 0 && r.height > 0) || rects[0];
                ////                    console.log('OG rect chosen:', ogRect);
                //                    //                        await this.#scrollToRect(ogRect, reason);
                //                    //                        resolve();
                //                    //                        return;
                //                }
                //                console.log('anchorNode=', anchorNode);

                // Fast path: compute offset using offsetLeft/offsetTop chains
                let elNode = anchorNode;
                if (elNode && elNode.startContainer !== undefined) {
                    elNode = elNode.startContainer;
                }
                if (elNode && (elNode.nodeType === Node.ELEMENT_NODE || elNode.nodeType === Node.TEXT_NODE)) {
                    let el = elNode.nodeType === Node.TEXT_NODE ? elNode.parentElement : elNode;
                    if (el && el.nodeType === Node.ELEMENT_NODE) {
                        let left = el.offsetLeft, top = el.offsetTop;
                        const width = el.offsetWidth, height = el.offsetHeight;
                        //                        console.log('initial offsets:', { left, top, width, height });
                        let current = el;
                        let doc = el.ownerDocument;
                        // Traverse offsetParent chain (and iframe chain)
                        while (current && current !== this.#container) {
                            const parent = current.offsetParent;
                            if (!parent) {
                                const frame = doc?.defaultView?.frameElement;
                                if (frame) {
                                    left += frame.offsetLeft;
                                    top += frame.offsetTop;
                                    current = frame;
                                    doc = current.ownerDocument;
                                    continue;
                                }
                                break;
                            }
                            current = parent;
                            if (current !== this.#container) {
                                left += current.offsetLeft;
                                top += current.offsetTop;
                            }
                        }
                        //                        console.log('after traversal offsets:', { left, top });
                        // Re‑create a synthetic rect from the accumulated offsets and
                        // feed it to the normal scroll‑to‑rect path.  This avoids the
                        // heavyweight `getClientRects()` call but still lets the
                        // existing mapper logic figure out the correct offset for both
                        // page‑ and scroll‑modes.
                        const syntheticRect = {
                            left,
                            right: left + width,
                            top,
                            bottom: top + height,
                            width,
                            height
                        };
                        //                        console.log('syntheticRect=', syntheticRect);
                        const rectMapper = await this.#getRectMapper();
                        const mapped = rectMapper(syntheticRect);
                        //                        console.log('mappedRect=', mapped);
                        // Use the same helper that the slow path relies on so we keep
                        // consistent behaviour between modes.
                        await this.#scrollToRect(syntheticRect, reason);
                        resolve();
                        return;
                    }
                }
                // Fraction fallback
                if (this.scrolled) {
                    await this.#scrollTo(anchor * (await this.viewSize()), reason);
                    resolve();
                    return;
                }
                const _pages = await this.pages();
                if (!_pages) {
                    resolve();
                    return;
                }
                const textPages = _pages - 2;
                const newPage = Math.round(anchor * (textPages - 1));
                await this.#scrollToPage(newPage + 1, reason);
                resolve();
            });
        });
    }
    async #getVisibleRange() {
        //            console.log("getVisibleRange...")
        await this.#awaitDirection();
        //            console.log("getVisibleRange... await refreshElementVisibilityObserver..")
        const visibleSentinelIDs = await this.#getSentinelVisibilities()
        //            await new Promise(r => requestAnimationFrame(r));

        //            console.log("getVisibleRange... awaited refreshElementVisibilityObserver")
        //            console.log("getVisibleRange... sentinels", this.#visibleSentinelIDs.size)

        // Find the first and last visible content node, skipping <reader-sentinel> and manabi-* elements

        const doc = this.#view.document

        if (visibleSentinelIDs.length === 0) {
            const range = doc.createRange();
            range.selectNodeContents(doc.body);
            range.collapse(true);
            return range
        }

        const isValid = node => {
            return (node &&
                (node.nodeType === Node.TEXT_NODE ||
                    (node.nodeType === Node.ELEMENT_NODE &&
                        node.tagName !== 'reader-sentinel')))
        }

        const visibleSentinels = doc.querySelectorAll(
            visibleSentinelIDs
                .map(id => `#${CSS.escape(id)}`)
                .join(',')
        );
        const firstSentinel = visibleSentinels[0];
        const lastSentinel = visibleSentinels[visibleSentinels.length - 1];

        const findNext = el => {
            let node = el?.nextSibling;
            while (node && !isValid(node)) node = node.nextSibling;
            return node;
        };

        const findPrev = el => {
            let node = el?.previousSibling;
            while (node && !isValid(node)) node = node.previousSibling;
            return node;
        };

        const startNode = firstSentinel ? findNext(firstSentinel) : null;
        const endNode = lastSentinel ? findPrev(lastSentinel) : null;

        const range = doc.createRange();
        if (startNode && endNode) {
            range.setStartBefore(startNode);
            range.setEndAfter(endNode);
        } else {
            range.selectNodeContents(doc.body);
            range.collapse(true);
        }
        return range;
    }
    async #afterScroll(reason) {
        if (this.#isCacheWarmer) {
            return;
        }
        //            console.log("#afterScroll...")

        this.#cachedStart = null;

        const range = await this.#getVisibleRange()
        // don't set new anchor if relocation was to scroll to anchor
        if (reason !== 'selection' && reason !== 'navigation' && reason !== 'anchor')
            this.#anchor = range
        else this.#justAnchored = true

        const index = this.#index
        const detail = {
            reason,
            range,
            index
        }

        if (this.scrolled) {
            detail.fraction = (await this.start()) / (await this.viewSize())
        } else if ((await this.pages()) > 0) {
            const page = await this.page()
            const pages = await this.pages()
            this.#header.style.visibility = page > 1 ? 'visible' : 'hidden'
            detail.fraction = (page - 1) / (pages - 2)
            detail.size = 1 / (pages - 2)
        }

        this.dispatchEvent(new CustomEvent('relocate', {
            detail
        }))

        try {
            const [pageNumber, pageCount, startOffset, pageSize, viewSize] = await Promise.all([
                this.page(),
                this.pages(),
                this.start(),
                this.size(),
                this.viewSize(),
            ])
        } catch (_error) {
            // diagnostics best-effort
        }

        // Force chevron visible at start of sections (now handled here, not in ebook-viewer.js)
        if (await this.isAtSectionStart()) {
            this.#skipTouchEndOpacity = true
            this.dispatchEvent(new CustomEvent('sideNavChevronOpacity', {
                bubbles: true,
                composed: true,
                detail: {
                    leftOpacity: this.bookDir === 'rtl' ? 0.999 : 0,
                    rightOpacity: this.bookDir === 'rtl' ? 0 : 0.999,
                }
            }));
        }
    }

    #updateSwipeChevron(dx, minSwipe) {
        let leftOpacity = 0,
            rightOpacity = 0;
        if (dx > 0) leftOpacity = Math.min(1, dx / minSwipe);
        else if (dx < 0) rightOpacity = Math.min(1, -dx / minSwipe);
        this.dispatchEvent(new CustomEvent('sideNavChevronOpacity', {
            bubbles: true,
            composed: true,
            detail: {
                leftOpacity,
                rightOpacity
            }
        }));
        if (Math.abs(dx) > minSwipe) {
            // Enqueue the reset after meeting threshold
            this.dispatchEvent(new CustomEvent('sideNavChevronOpacity', {
                bubbles: true,
                composed: true,
                detail: {
                    leftOpacity: '',
                    rightOpacity: ''
                }
            }))
        }
    }
    async #display(promise) {
        //            console.log("#display...")
        this.#setLoading(true)
        const {
            index,
            src,
            anchor,
            onLoad,
            select,
            reason,
        } = await promise

        //            console.log("#display...awaited promise")
        this.#index = index
        if (src) {
            const afterLoad = async (doc) => {
                if (this.#isCacheWarmer) {
                    await onLoad?.({
                        location: src,
                    })
                } else {
                    hideDocumentContentForPreBake(doc)
                    if (doc.head) {
                        const $styleBefore = doc.createElement('style')
                        doc.head.prepend($styleBefore)
                        const $style = doc.createElement('style')
                        doc.head.append($style)
                        this.#styleMap.set(doc, [$styleBefore, $style])
                        ensureTrackingSizeBakeStyles(doc)
                    }
                    await onLoad?.({
                        doc,
                        location: doc.location.href,
                        index,
                    })
                    await this.#performTrackingSectionGeometryBake({
                        reason: 'initial-load',
                        restoreLocation: false,
                    })
                    //                    console.log("#display... awaited onLoad")
                }
            }

            if (this.#isCacheWarmer) {
                await fetch(src).then(r => r.text())
                await afterLoad()
            } else {
                this.#skipTouchEndOpacity = true
                const view = this.#createView()
                const beforeRender = this.#beforeRender.bind(this)

                this.#cachedSizes = null
                this.#cachedStart = null
                //                console.log("#display... scrolledToAnchorOnLoad = false")
                this.#scrolledToAnchorOnLoad = false

                //                console.log("#display... await load")
                await view.load(src, afterLoad, beforeRender, index)
                //                console.log("#display... awaited load")
                this.#view = view

                // Reset chevrons when loading new section
                document.dispatchEvent(new CustomEvent('resetSideNavChevrons'));
                //            this.dispatchEvent(new CustomEvent('create-overlayer', {
                //            this.dispatchEvent(new CustomEvent('create-overlayer', {
                //                detail: {
                //                    doc: view.document, index,
                //                    attach: overlayer => view.overlayer = overlayer,
                //                },
                //            }))
                //                this.style.display = 'block'
            }
        }

        //            console.log("#display... call scroll to anchor")

        await this.scrollToAnchor((typeof anchor === 'function' ?
            anchor(this.#view.document) : anchor) ?? 0, select, reason)
        // Diagnostics: capture initial pagination metrics after display
        let pageNumber = null
        let pageCount = null
        try {
            [pageNumber, pageCount] = await Promise.all([this.page(), this.pages()]);
            window.webkit?.messageHandlers?.print?.postMessage?.(`# EBOOKPAGE display ${JSON.stringify({ index, pageNumber, pageCount, reason })}`);
        } catch (_error) {
            // best-effort; do not fail display on logging issues
        }
        try {
            await Promise.all([
                this.start(),
                this.size(),
                this.viewSize(),
            ])
        } catch (_error) {
            // best-effort; keep display flow unhindered
        }
        //            console.log("#display... scrolledToAnchorOnLoad = true")
        this.#scrolledToAnchorOnLoad = true
        this.#setLoading(false)
        this.dispatchEvent(new CustomEvent('didDisplay', {}))
        //            console.log("#display... fin")
    }
    #canGoToIndex(index) {
        return index >= 0 && index <= this.sections.length - 1
    }
    async #goTo({
        index,
        anchor,
        select,
        reason,
    }) {
        //        console.log("#goTo...", this.style.display, index, anchor)
        const navigationReason = reason ?? (select ? 'selection' : 'navigation');
        const willLoadNewIndex = index !== this.#index;
        this.dispatchEvent(new CustomEvent('goTo', {
            willLoadNewIndex: willLoadNewIndex
        }))
        if (!willLoadNewIndex) {
            await this.#display({
                index,
                anchor,
                select,
                reason: navigationReason,
            })
        } else {
            // hide the view until final relocate needs
            this.style.display = 'none'
 
            const oldIndex = this.#index
            // Reset direction flags and promise before loading a new section
            this.#vertical = this.#verticalRTL = this.#rtl = null;
            this.#directionReady = new Promise(r => (this.#directionReadyResolve = r));
            const onLoad = async (detail) => {
                this.sections[oldIndex]?.unload?.()

                if (!this.#isCacheWarmer) {
                    this.setStyles(this.#styles)
                }

                this.dispatchEvent(new CustomEvent('load', {
                    detail
                }))
            }

            let loadPromise;
            if (this.#prefetchCache.has(index)) {
                loadPromise = this.#prefetchCache.get(index);
            } else {
                loadPromise = this.sections[index].load();
                this.#prefetchCache.set(index, loadPromise);
            }
            await this.#display(Promise.resolve(loadPromise)
                .then(src => ({
                    index,
                    src,
                    anchor,
                    onLoad,
                    select,
                    reason: navigationReason,
                }))
                .catch(error => {
                    console.error(error);
                    console.warn(new Error(`Failed to load section ${index}`));
                    return {};
                }));

            clearTimeout(this.#prefetchTimer);
            this.#prefetchTimer = setTimeout(() => {
                if (this.#index !== index) return; // bail if user has moved on

                const wanted = [index - 1, index + 1];
                // Keep any already cached of these two
                const keep = new Set(wanted.filter(i => this.#prefetchCache.has(i)));
                this.#prefetchCache = new Map(
                    [...this.#prefetchCache].filter(([i]) => keep.has(i))
                );

                // Now prefetch any neighbor not already cached
                wanted.forEach(i => {
                    if (
                        i >= 0 &&
                        i < this.sections.length &&
                        this.sections[i].linear !== 'no' &&
                        !this.#prefetchCache.has(i)
                    ) {
                        const p = this.sections[i].load().catch(() => { });
                        this.#prefetchCache.set(i, p);
                    }
                });
            }, 500);
        }
    }
    async goTo(target) {
        if (this.#locked) return
        const resolved = await target
        if (this.#canGoToIndex(resolved.index)) return await this.#goTo(resolved)
    }
    async #scrollPrev(distance) {
        if (!this.#view) return true
        if (this.scrolled) {
            const style = getComputedStyle(this.#container);
            const lineAdvance = this.#vertical ?
                parseFloat(style.fontSize) || 20 :
                parseFloat(style.lineHeight) || 20;
            const scrollDistance = distance ?? (this.size - lineAdvance);
            if ((await this.start()) > 0) {
                return await this.#scrollTo(Math.max(0, this.start - scrollDistance), null, true);
            }
            return true;
        }
        if (await this.atStart()) return
        const page = await this.page() - 1
        return await this.#scrollToPage(page, 'page', true).then(() => page <= 0)
    }
    async #scrollNext(distance) {
        if (!this.#view) return true
        if (this.scrolled) {
            const style = getComputedStyle(this.#container);
            const lineAdvance = this.#vertical ?
                parseFloat(style.fontSize) || 20 :
                parseFloat(style.lineHeight) || 20;
            const scrollDistance = distance ?? (this.size - lineAdvance);
            if ((await this.viewSize()) - (await this.end()) > 2) {
                return await this.#scrollTo(Math.min(await this.viewSize(), (await this.start()) + scrollDistance), null, true);
            }
            return true;
        }
        if (await this.atEnd()) return
        const page = await this.page() + 1
        const pages = await this.pages()
        return await this.#scrollToPage(page, 'page', true).then(() => page >= pages - 1)
    }
    async atStart() {
        return this.#adjacentIndex(-1) == null && (await this.page()) <= 1
    }
    async atEnd() {
        return this.#adjacentIndex(1) == null && (await this.page()) >= (await this.pages()) - 2
    }
    #adjacentIndex(dir) {
        for (let index = this.#index + dir; this.#canGoToIndex(index); index += dir)
            if (this.sections[index]?.linear !== 'no') return index
    }
    async #turnPage(dir, distance) {
        if (this.#locked) return

        this.#locked = true
        const prev = dir === -1
        const shouldGo = await (prev ? await this.#scrollPrev(distance) : await this.#scrollNext(distance))
        if (!shouldGo) {
        }
        if (shouldGo) await this.#goTo({
            index: this.#adjacentIndex(dir),
            anchor: prev ? () => 1 : () => 0,
            reason: 'page',
        })
        if (shouldGo || !this.hasAttribute('animated')) await wait(100)
        this.#locked = false
    }
    async prev(distance) {
        return await this.#turnPage(-1, distance)
    }
    async next(distance) {
        return await this.#turnPage(1, distance)
    }
    async prevSection() {
        return await this.goTo({
            index: this.#adjacentIndex(-1),
            reason: 'page',
        })
    }
    async nextSection() {
        return await this.goTo({
            index: this.#adjacentIndex(1),
            reason: 'page',
        })
    }
    async firstSection() {
        const index = this.sections.findIndex(section => section.linear !== 'no')
        return await this.goTo({
            index
        })
    }
    async lastSection() {
        const index = this.sections.findLastIndex(section => section.linear !== 'no')
        return await this.goTo({
            index
        })
    }
    getContents() {
        if (this.#view) return [{
            index: this.#index,
            overlayer: this.#view.overlayer,
            doc: this.#view.document,
        }]
        return []
    }
    setStyles(styles) {
        this.#styles = styles
        const $$styles = this.#styleMap.get(this.#view?.document)
        if (!$$styles) return
        const [$beforeStyle, $style] = $$styles
        if (Array.isArray(styles)) {
            const [beforeStyle, style] = styles
            $beforeStyle.textContent = beforeStyle
            $style.textContent = style
        } else $style.textContent = styles

        //        // NOTE: needs `requestAnimationFrame` in Chromium
        //        requestAnimationFrame(() =>
        //            this.#background.style.background = getBackground(this.#view.document))

        // needed because the resize observer doesn't work in Firefox
        //            this.#view?.document?.fonts?.ready?.then(async () => { await this.#view.expand() })

        this.requestTrackingSectionSizeBake({ reason: 'styles-applied' })
    }
    destroy() {
        this.#disconnectElementVisibilityObserver()
        this.#resizeObserver.unobserve(this)
        this.#resetTrackingSectionSizeState()
        this.#view.destroy()
        this.#view = null
        this.sections[this.#index]?.unload?.()
    }
    // Public navigation edge detection methods
    async canTurnPrev() {
        if (!this.#view) return false;
        if (this.scrolled) {
            return this.start > 0;
        }
        // If at the start page and no previous section, cannot turn
        if ((await this.page()) <= 1 && this.#adjacentIndex(-1) == null) return false;
        return true;
    }
    async canTurnNext() {
        if (!this.#view) return false;
        if (this.scrolled) {
            return this.viewSize - this.end > 2;
        }
        // If at the end page and no next section, cannot turn
        if ((await this.page()) >= (await this.pages()) - 2 && this.#adjacentIndex(1) == null) return false;
        return true;
    }

    // Public helpers for adjacent sections
    getHasPrevSection() {
        return this.#adjacentIndex(-1) != null;
    }
    getHasNextSection() {
        return this.#adjacentIndex(1) != null;
    }

    // Public: At first page of current section
    async isAtSectionStart() {
        return (await this.page()) <= 1;
    }
    // Public: At last page of current section
    async isAtSectionEnd() {
        return (await this.page()) >= (await this.pages()) - 2;
    }
}

customElements.define('foliate-paginator', Paginator)
